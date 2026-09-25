// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The trips citizens make, and what becomes of each one
/// (docs/plans/agent-traffic.md §6.4, §6.5, §4.7, §7.4;
/// docs/plans/slice3-implementation.md §1.5).
///
/// This file replaces `CommuteSynth` (§6.7), which stood in for citizens
/// through slices 1–2 and is deleted with slice 3. It keeps that class's
/// WHOLE public surface, because a trip row is still what the path queue's
/// requester names and what the vehicle's `owner` points at: the fixtures,
/// `destination_demolished_test`, `rebuild_new_box_test` and the allocation
/// gate read the same columns and call the same methods as before.
///
/// A TRIP ROW is one leg's worth of state: where it came from and where it is
/// going (building handles, so a lot a road edit renames keeps its trips,
/// E12–E14), the stage it has reached, the vehicle driving it, and the parked
/// car it departs from. Two kinds of row share it:
///
/// - a CITIZEN's trip, `citizen >= 0`, woken off the activity wheel; and
/// - a FORCED trip, `citizen == -1`, one-way, from the development hooks and
///   the scenario tests ([CitizenTrips.force], `CityAgents.forceTrip`,
///   `debugDepart`).
///
/// **A trip starts from its own parked car** (site-access.md §7.4, §7.5). A
/// trip out of a home takes a car from that home's pool when the path is
/// REQUESTED, not when it departs — so two people leaving one house in one
/// second never claim the same car — and the car keeps standing on its stall
/// until the vehicle spawns, where it still blocks whatever is behind it on a
/// tandem pad. The leg back leaves the car it parked at the far end.
///
/// **What P0 landed, and what package C still owes.** The machinery below is
/// `CommuteSynth`'s, ported whole: the path request, the spawn, the arrival,
/// the appended leg home when a destination was torn down, and the wholly
/// synthetic demand of [CitizenTrips.wake] — every built, served home owing
/// `commuteRatePerResident · housing` trips a second. That keeps today's
/// behaviour, today's digests and a dozen T4a tests standing while the slice
/// is built. Package C replaces that body with §6.4's activity loop off
/// [CitizenTable]'s wheel, and [CitizenTrips.rush] with §6.1's 64-entry bump
/// table; the citizen-shaped accessors below answer honestly for a forced
/// trip already.
library;

import 'dart:typed_data';

import 'agent_kind.dart';
import 'building_table.dart';
import 'citizen_match.dart';
import 'citizen_table.dart';
import 'parked_cars.dart';
import 'path_search.dart';
import 'slot_pool.dart';
import 'traffic_rng.dart';
import 'traffic_stats.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';
import 'trip_planner.dart';
import 'vehicle_table.dart';

/// §6.5's design rate: outbound car commutes per resident per agent second,
/// from 60% employed × 75% with a car × 85% driving over a 915 s cycle.
///
/// `AgentTuning.commuteRatePerResident` is the DEMAND SCALE against it: the
/// activity loop multiplies its commute wake-up probability by
/// `commuteRatePerResident / kDesignCommuteRate`, so the default is unchanged
/// behaviour and 0 means no citizen trips at all (slice3 §0, Q1).
const double kDesignCommuteRate = 0.00042;

/// A trip's leg: out (to work, to an errand) or back home.
const int _toWork = 0;
const int _toHome = 1;

/// Where a trip's current leg stands.
const int _stagePlanning = 0; // a path request is queued or searching
const int _stageWaiting = 1; // planned, waiting to pull out
const int _stageDriving = 2; // on the road
const int _stageAtWork = 3; // dwelling at the far end until [wakeUs]

/// The citizens' trips. See the library comment.
class CitizenTrips implements SpawnSink {
  CitizenTrips({
    required this.citizens,
    required this.buildings,
    required this.planner,
    required this.queue,
    required this.table,
    required this.stats,
    required this.rng,
    int capacity = 8192,
  })  : pool = SlotPool(capacity),
        skims = StraightLineSkims(buildings),
        home = Int32List(capacity),
        job = Int32List(capacity),
        vehicle = Int32List(capacity),
        leg = Uint8List(capacity),
        stage = Uint8List(capacity),
        oneWay = Uint8List(capacity),
        kind = Uint8List(capacity),
        purpose = Uint8List(capacity),
        wakeUs = Float64List(capacity),
        car = Int32List(capacity)..fillRange(0, capacity, -1),
        citizen = Int32List(capacity)..fillRange(0, capacity, -1);

  /// Who the trips belong to. Read by package C's activity loop; a forced
  /// trip names nobody in it.
  final CitizenTable citizens;

  final BuildingTable buildings;
  final TripPlanner planner;
  final PathQueue queue;
  final VehicleTable table;
  final TrafficStats stats;

  /// The demand's draws — destinations, dwells — on a stream of their own.
  final TrafficRng rng;

  /// How long a trip would take by each mode: what §6.4's errand weights and
  /// §4.9's mode choice are built on. The straight-line stand-in until the
  /// zone skims land.
  TripSkims skims;

  /// Trip rows. A full pool defers new trips like any other cap.
  final SlotPool pool;

  /// Building handles: where the leg started and where it is going (for a
  /// citizen's commute, their home and their job).
  final Int32List home, job;

  /// The vehicle driving the current leg, or −1.
  final Int32List vehicle;

  /// The citizen this trip is for, or −1 for a forced trip.
  final Int32List citizen;

  /// The parked car this leg departs from, or −1 (§0 Q3): a home-pool car
  /// taken when the trip is REQUESTED — it stands on its stall until the
  /// vehicle spawns — or, on the leg home, the car parked at work.
  final Int32List car;

  /// Where those cars live; null while the owner keeps none, and then every
  /// trip departs from the access point as it did before T4a.
  ParkedCarTable? cars;

  /// Leg, stage, whether it is a one-way forced trip, the `AgentKind` and
  /// the outbound `TripPurpose` — indices.
  final Uint8List leg, stage, oneWay, kind, purpose;

  /// Agent µs at which a trip dwelling at the far end sets off home.
  final Float64List wakeUs;

  /// Agent time of the sub-step running now, set by the owner.
  int nowUs = 0;

  /// Trips the demand has sent since the colony started (forced trips not
  /// counted).
  int sent = 0;

  int get liveCount => pool.liveCount;

  /// Trips dwelling at the far end now, waiting for the end of the day.
  int get atWork {
    var n = 0;
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (pool.isSlotLive(sl) && stage[sl] == _stageAtWork) n++;
    }
    return n;
  }

  /// The building [trip]'s current leg is heading for, or −1.
  int destOf(int trip) {
    if (!pool.isLive(trip)) return -1;
    final sl = SlotPool.slotOf(trip);
    return leg[sl] == _toWork ? job[sl] : home[sl];
  }

  /// The building the leg vehicle [vehicleHandle] drives is heading for, or
  /// −1 for a vehicle no trip is driving.
  int destOfVehicle(int vehicleHandle) {
    final t = _tripOfVehicle(vehicleHandle);
    return t < 0 ? -1 : destOf(t);
  }

  /// The building [trip]'s current leg set off from, or −1.
  int originOf(int trip) {
    if (!pool.isLive(trip)) return -1;
    final sl = SlotPool.slotOf(trip);
    return leg[sl] == _toWork ? home[sl] : job[sl];
  }

  /// The vehicle of [trip], or −1.
  int vehicleOf(int trip) =>
      pool.isLive(trip) ? vehicle[SlotPool.slotOf(trip)] : -1;

  /// Whether [trip] names a live row.
  bool isLive(int trip) => pool.isLive(trip);

  /// The parked car [trip]'s current leg departs from, or −1.
  int carOf(int trip) => pool.isLive(trip) ? car[SlotPool.slotOf(trip)] : -1;

  /// The building [trip] started from — for a citizen's commute, their home;
  /// for a forced trip, where it was sent from — or −1: the opaque owner a
  /// car parked at work carries (§0 Q3).
  int homeOf(int trip) => pool.isLive(trip) ? home[SlotPool.slotOf(trip)] : -1;

  /// The citizen [trip] belongs to, or −1 for a forced trip.
  int citizenOf(int trip) =>
      pool.isLive(trip) ? citizen[SlotPool.slotOf(trip)] : -1;

  /// The live trip [citizen] is on, or −1. A citizen is on at most one trip
  /// at a time (§6.4), so this is a question with one answer; package C makes
  /// it O(1) through `CitizenTable.agent`.
  int tripOf(int citizen) {
    if (citizen < 0) return -1;
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (pool.isSlotLive(sl) && this.citizen[sl] == citizen) {
        return pool.handleOf(sl);
      }
    }
    return -1;
  }

  /// Gives [trip] the car it has just parked, so its next leg departs from
  /// there (§7.4 Departure step 1).
  void setCar(int trip, int car) {
    if (!pool.isLive(trip)) return;
    this.car[SlotPool.slotOf(trip)] = car;
  }

  /// A trip restored at work with its car [car] parked there, on its way
  /// home within the return window (§0 Q3, §14.1): what a load makes of a
  /// `commuter`-owned car, since agents in flight are never saved (§14.3).
  /// Returns its handle, or `SlotPool.none` when the pool is full.
  ///
  /// Package D turns this into §0's ADOPTION — the car is handed to a
  /// carless citizen of building [home], and keeps its legacy owner when
  /// there is none — which is why the facade's call site is still the one
  /// place a restored commuter car is answered for.
  int restoreAtWork(int home, int job, int car) {
    final h = pool.alloc();
    if (h == SlotPool.none) return h;
    final sl = SlotPool.slotOf(h);
    this.home[sl] = home;
    this.job[sl] = job;
    vehicle[sl] = -1;
    this.car[sl] = car;
    citizen[sl] = -1;
    oneWay[sl] = 0;
    kind[sl] = AgentKind.car.index;
    purpose[sl] = TripPurpose.commute.index;
    _clockIn(sl, nowUs);
    return h;
  }

  /// A trip from building [from] to [to] by a [kind] vehicle, planned now
  /// and driven once: what the development hooks' `traffic=spawn` and the
  /// scenario tests ask for. [car] departs from that parked car rather than
  /// from whatever the home pool offers (`CityAgents.debugDepart`). Returns
  /// the trip's handle, or `SlotPool.none` when a cap deferred it.
  int force(int from, int to,
      {AgentKind kind = AgentKind.car,
      TripPurpose purpose = TripPurpose.commute,
      int car = -1}) {
    if (!_open()) {
      stats.deferred++;
      return SlotPool.none;
    }
    return _start(from, to,
        oneWay: true, kind: kind, purpose: purpose, car: car);
  }

  // ---- Once per agent second (§5.2 step 1) ----------------------------------

  /// Sends the trips owed this second, and brings home whoever's dwell is
  /// over. Every building and trip in slot order, so two runs ask for the
  /// same trips in the same order.
  ///
  /// **P0's body is `CommuteSynth`'s** (§6.7): demand is per BUILDING, at
  /// `commuteRatePerResident · housing` a second, carried between seconds in
  /// `BuildingTable.commuteOwed`. Package C replaces it with §6.4's loop —
  /// the citizens due off the wheel, in wheel order, each choosing their own
  /// activity and mode — and the rate becomes the scale against
  /// [kDesignCommuteRate].
  void wake(int nowUs) {
    this.nowUs = nowUs;
    _emit();
    _returns(nowUs);
  }

  /// §6.1's rush-hour multiplier for the wake-up rates: peaks at day phase
  /// 0.30 and 0.72, and integrates over a day to the flat rate, so a colony
  /// makes the same trips either way and only their timing moves.
  static double rush(double dayPhase) =>
      throw UnimplementedError('slice 3 C: citizen_trips.rush');

  bool _open() => !pool.isFull && planner.carTripsOpen(queue);

  void _emit() {
    final b = buildings;
    final rate = AgentTuning.commuteRatePerResident;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl) || b.housing[sl] <= 0 || !b.reachable(sl)) continue;
      var owed = b.commuteOwed[sl] + rate * b.housing[sl];
      while (owed >= 1) {
        if (!_open()) {
          stats.deferred++;
          break;
        }
        owed -= 1;
        final to = b.drawJob(rng, except: sl);
        if (to < 0) continue;
        final h = _start(b.handleOf(sl), to,
            oneWay: false, kind: AgentKind.car, purpose: TripPurpose.commute);
        if (h != SlotPool.none) sent++;
      }
      b.commuteOwed[sl] = owed > kMaxOwedTrips ? kMaxOwedTrips : owed;
    }
  }

  void _returns(int nowUs) {
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl) || stage[sl] != _stageAtWork) continue;
      if (wakeUs[sl] > nowUs) continue;
      if (!planner.carTripsOpen(queue)) {
        // Everyone after waits too: the order they leave in is kept.
        stats.deferred++;
        return;
      }
      leg[sl] = _toHome;
      _request(pool.handleOf(sl));
    }
  }

  int _start(int from, int to,
      {required bool oneWay,
      required AgentKind kind,
      required TripPurpose purpose,
      int car = -1,
      int citizen = -1}) {
    final h = pool.alloc();
    if (h == SlotPool.none) return h;
    final sl = SlotPool.slotOf(h);
    home[sl] = from;
    job[sl] = to;
    vehicle[sl] = -1;
    this.car[sl] = car;
    this.citizen[sl] = citizen;
    leg[sl] = _toWork;
    this.oneWay[sl] = oneWay ? 1 : 0;
    this.kind[sl] = kind.index;
    this.purpose[sl] = purpose.index;
    wakeUs[sl] = 0;
    return _request(h) ? h : SlotPool.none;
  }

  /// Asks for the path of [trip]'s current leg, under [tag]. False, and the
  /// leg deferred, when the queue refused it.
  ///
  /// An outbound leg takes a car out of its home's pool here rather than at
  /// the spawn (§0 Q3): the car is promised to this trip from the moment it
  /// is asked for, so two people leaving one house in the same second never
  /// claim the same car — and the car keeps standing on its stall, where it
  /// still blocks whatever is behind it on a tandem pad.
  bool _request(int trip, {int tag = kTripTag}) {
    final sl = SlotPool.slotOf(trip);
    final out = leg[sl] == _toWork;
    stage[sl] = _stagePlanning;
    if (out && car[sl] < 0) {
      final parked = cars;
      if (parked != null && home[sl] >= 0) {
        car[sl] = parked.takePooled(SlotPool.slotOf(home[sl]));
      }
    }
    final ok = queue.enqueue(PathPriority.car,
        requester: trip,
        kind: AgentKind.values[kind[sl]],
        origin: out ? home[sl] : job[sl],
        dest: out ? job[sl] : home[sl],
        tag: tag);
    if (ok) return true;
    stats.deferred++;
    if (out) {
      _dropCar(sl);
      pool.free(trip);
    } else {
      // Still at the far end: it tries again next second.
      stage[sl] = _stageAtWork;
      leg[sl] = _toWork;
      wakeUs[sl] = nowUs.toDouble();
    }
    return false;
  }

  /// The trip that took [sl]'s car never ran: the car goes back in its pool,
  /// where it stood all along.
  void _dropCar(int sl) {
    final c = car[sl];
    car[sl] = -1;
    if (c >= 0) cars?.returnPooled(c);
  }

  // ---- Paths, spawns, arrivals ------------------------------------------------

  /// A path for [request] (a [kTripTag] request) came back.
  void onPath(PathRequest request, PathOutcome outcome, PlannedRoute route,
      int nowUs) {
    final h = request.requester;
    if (!pool.isLive(h)) return;
    final sl = SlotPool.slotOf(h);
    if (stage[sl] != _stagePlanning) return;
    if (outcome != PathOutcome.found) {
      stats.noRoute++;
      _dropCar(sl);
      pool.free(h);
      return;
    }
    final out = leg[sl] == _toWork;
    final from = out ? home[sl] : job[sl];
    final firstEdge = table.graph.laneEdge[route.elems[0]];
    final v = planner.deliver(
        h,
        AgentKind.values[kind[sl]],
        out ? TripPurpose.values[purpose[sl]] : TripPurpose.homeward,
        route,
        fromLeft: buildings.leftOf(from, firstEdge),
        nowUs: nowUs,
        car: car[sl]);
    if (v == kRouteTooLong) {
      stats.noRoute++;
      _dropCar(sl);
      pool.free(h);
    } else if (v != SlotPool.none) {
      spawned(h, v);
    } else {
      stage[sl] = _stageWaiting;
    }
  }

  @override
  void spawned(int owner, int handle) {
    if (!pool.isLive(owner)) return;
    final sl = SlotPool.slotOf(owner);
    vehicle[sl] = handle;
    stage[sl] = _stageDriving;
    // The car IS the vehicle now: its parked row went with the spawn.
    car[sl] = -1;
  }

  @override
  void replanWaiting(int owner) {
    if (!pool.isLive(owner)) return;
    if (stage[SlotPool.slotOf(owner)] != _stageWaiting) return;
    _request(owner);
  }

  /// [owner]'s leg, asked for again under [tag] because the route it held
  /// INSIDE a site could not be carried across a lane-graph rebuild (§7.6,
  /// `SiteMover.remapHeld`). Its car is back on a stall by now, so the leg
  /// starts from the site's out-joins again, and no pooled car is taken.
  void replanFromSite(int owner, int tag) {
    if (!pool.isLive(owner)) return;
    final sl = SlotPool.slotOf(owner);
    vehicle[sl] = -1;
    _request(owner, tag: tag);
  }

  /// The trip driving vehicle [vehicleHandle], or −1.
  int _tripOfVehicle(int vehicleHandle) {
    final t = table.owner[SlotPool.slotOf(vehicleHandle)];
    if (!pool.isLive(t)) return -1;
    return vehicle[SlotPool.slotOf(t)] == vehicleHandle ? t : -1;
  }

  /// [vehicleHandle] reached its stop at [nowUs]. Returns a building to
  /// re-target it to — home, when it drove out and found the building gone —
  /// which the owner plans as an appended leg; else −1, and the vehicle
  /// leaves the road.
  int arrived(int vehicleHandle, int nowUs) {
    final t = _tripOfVehicle(vehicleHandle);
    if (t < 0) return -1;
    final sl = SlotPool.slotOf(t);
    final vs = SlotPool.slotOf(vehicleHandle);
    stats.tripDone(
        secondsOf(nowUs - table.tripT0Us[vs].toInt()), table.freeFlowS[vs]);
    final out = leg[sl] == _toWork;
    final dest = out ? job[sl] : home[sl];
    if (!buildings.isLive(dest)) {
      stats.arrivedGone++;
      if (out && oneWay[sl] == 0 && buildings.isLive(home[sl])) {
        leg[sl] = _toHome;
        return home[sl];
      }
      _dropCar(sl);
      pool.free(t);
      return -1;
    }
    vehicle[sl] = -1;
    if (out && oneWay[sl] == 0) {
      _clockIn(sl, nowUs);
    } else {
      _dropCar(sl);
      pool.free(t);
    }
    return -1;
  }

  /// [vehicleHandle] was taken off the road before it arrived: the leg
  /// failed. Someone lost on the way to work is at work all the same — the
  /// design places a citizen at their destination (§5.6) — and comes home at
  /// the end of the day.
  void despawned(int vehicleHandle, int nowUs) {
    final t = _tripOfVehicle(vehicleHandle);
    if (t < 0) return;
    final sl = SlotPool.slotOf(t);
    stats.tripFailed();
    vehicle[sl] = -1;
    if (leg[sl] == _toWork && oneWay[sl] == 0) {
      _clockIn(sl, nowUs);
    } else {
      _dropCar(sl);
      pool.free(t);
    }
  }

  /// [vehicleHandle] left the road with nowhere left to go — an appended
  /// leg that found no path: the trip ends there.
  void vanished(int vehicleHandle) {
    final t = _tripOfVehicle(vehicleHandle);
    if (t < 0) return;
    stats.noRoute++;
    _dropCar(SlotPool.slotOf(t));
    pool.free(t);
  }

  void _clockIn(int sl, int nowUs) {
    stage[sl] = _stageAtWork;
    leg[sl] = _toWork;
    wakeUs[sl] = (nowUs +
            usOf(rng.nextBetween(
                AgentTuning.commuteReturnMinS, AgentTuning.commuteReturnMaxS)))
        .toDouble();
  }

  /// [hash] with every live trip folded in, in slot order, and the demand
  /// stream's state: for `CityAgents.digest`.
  ///
  /// The citizen column is folded only when a trip HAS a citizen, as the car
  /// column is, so a colony whose trips are all forced — every T4a test —
  /// digests exactly as it did before the port.
  int digest(int hash) {
    var h = fnv1aU32(hash, pool.highWater);
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl)) continue;
      h = fnv1aU32(h, pool.handleOf(sl));
      h = fnv1aU32(h, home[sl]);
      h = fnv1aU32(h, job[sl]);
      h = fnv1aU32(h, vehicle[sl]);
      h = fnv1aU32(h, leg[sl] | stage[sl] << 8 | oneWay[sl] << 16);
      // Only a leg that HAS a car folds one, so a colony that parks nothing
      // digests exactly as it did before T4a.
      if (car[sl] >= 0) h = fnv1aU32(h, car[sl]);
      if (citizen[sl] >= 0) h = fnv1aU32(h, citizen[sl]);
      final w = wakeUs[sl].toInt();
      h = fnv1aU32(h, w & 0xFFFFFFFF);
      h = fnv1aU32(h, w ~/ 0x100000000);
    }
    final s = rng.toJson();
    for (var i = 0; i < s.length; i++) {
      h = fnv1aU32(h, s[i]);
    }
    return h;
  }
}
