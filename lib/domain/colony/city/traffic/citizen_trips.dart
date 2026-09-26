// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a citizen does next, and what becomes of the trip it takes them on
/// (docs/plans/agent-traffic.md §6.1, §6.4, §6.5, §4.7, §4.9, §7.4;
/// docs/plans/slice3-implementation.md §1.5).
///
/// This file replaced `CommuteSynth` (§6.7), which stood in for citizens
/// through slices 1–2. It keeps that class's WHOLE public surface, because a
/// trip row is still what the path queue's requester names and what the
/// vehicle's `owner` points at: the fixtures, `destination_demolished_test`,
/// `rebuild_new_box_test` and the allocation gate read the same columns and
/// call the same methods as before.
///
/// A TRIP ROW is one leg's worth of state: where it came from and where it is
/// going (building handles, so a lot a road edit renames keeps its trips,
/// E12–E14), the stage it has reached, the vehicle driving it, and the parked
/// car it departs from. Two kinds of row share it:
///
/// - a CITIZEN's trip, `citizen >= 0`, begun by the activity loop below; and
/// - a FORCED trip, `citizen == -1`, one-way, from the development hooks and
///   the scenario tests ([CitizenTrips.force], `CityAgents.forceTrip`,
///   `debugDepart`) — and the one restored row a legacy commuter car makes
///   ([restoreAtWork]), which is the only citizen-less row that comes back.
///
/// **The activity loop** (§6.4) is [wake]. Demand is no longer a rate a
/// BUILDING owes: it is what the people due off `CitizenTable`'s wheel decide
/// to do, one row of §6.4's table each. A citizen at home with a job commutes
/// or runs an errand; one without a job runs an errand or stays in; one at
/// work goes home, or by way of an errand; one on an errand goes home; one
/// out of town comes back. Each of those ends in a DWELL — a draw inside the
/// row's own interval, scaled by `activityDwellScale`, and for the two rows
/// §6.4 marks, divided by [rush] — which is the wake that brings them back
/// here. A citizen is on at most one trip at a time, so the loop never has to
/// ask whether they are already out.
///
/// **The demand scale** (slice3 §0, Q1). `AgentTuning.commuteRatePerResident`
/// was the rate itself while the synthetic demand stood in. It is now the
/// scale against [kDesignCommuteRate]: `s = rate / kDesignCommuteRate`
/// multiplies the commute WAKE-UP RATE, which is a probability until that
/// saturates and a shorter dwell after it. At the default `s` is 1 and
/// nothing has moved; at 0 no citizen starts any trip at all, which is how
/// some thirty test files ask for a colony that stands still.
///
/// **A trip starts from its own parked car** (site-access.md §7.4, §7.5, and
/// §6.4's "a car trip needs the citizen's car at their current location"). A
/// citizen drives only when their own car — `CitizenTable.car` — stands at
/// the building they are standing at; otherwise they WALK, which before the
/// pedestrians of T4b is an instant placement, counted in [instantTrips]
/// (§4.9 "before the modes exist", slice3 §0 Q6). A forced trip still takes
/// a car out of its origin home's pool when the path is REQUESTED, not when
/// it departs, so two forced trips out of one house never claim one car.
///
/// **A citizen's trip row outlives its arrival by a moment.** The car a leg
/// parks is not known when the vehicle stops: the gate holds it, the mover
/// drives it in, the kerb leg finishes, and only then does the facade call
/// [setCar]. So an arriving citizen is settled into their next activity at
/// once — state, dwell and wheel — while the ROW stays live at
/// [_stageAtWork] until [setCar] hands the car over, or until the citizen's
/// own next wake, whichever comes first. Nothing else reads it meanwhile.
library;

import 'dart:typed_data';

// `agent_kind.dart` declares a [CitizenState] of its own, member for member
// the same as `citizen_table.dart`'s. The citizens' own table is the one
// whose column holds the index, so that is the one this file means.
import 'agent_kind.dart' hide CitizenState;
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

/// §6.4's errand weight: a candidate is drawn with weight
/// `1 / (1 + skim / kErrandSkimS)`, so three minutes away is half the pull of
/// next door and ten times as far is not ten times as unlikely.
const double kErrandSkimS = 180;

/// Agent seconds a citizen waits before asking again when a cap took the
/// trip they had decided on: they wait where they are (D10), and the wheel
/// is what brings them back, so the wait must be short beside every dwell.
const double kTripRetryS = 1;

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

  /// Who the trips belong to: the activity loop's people, and the wheel that
  /// says which of them are due. A forced trip names nobody in it.
  final CitizenTable citizens;

  final BuildingTable buildings;
  final TripPlanner planner;
  final PathQueue queue;
  final VehicleTable table;
  final TrafficStats stats;

  /// The demand's draws — the branch taken, the errand drawn, the dwell — on
  /// a stream of their own.
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
  /// taken when a forced trip is REQUESTED — it stands on its stall until
  /// the vehicle spawns — a citizen's own car, or, for a leg that has
  /// arrived, the car it has just parked.
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

  /// The colony's day phase, 0 ≤ φ < 1, as its owner last published it: what
  /// [rush] is read at when a dwell is set (§6.1). A colony that never sets
  /// it commutes at the flat rate all day, which is what every test that
  /// does not care about rush hour wants.
  double dayPhase = 0;

  /// Trips the demand has begun since the colony started, forced trips not
  /// counted: every leg a citizen set out on, of which [commutesSent] were
  /// outbound home→work and [instantTrips] were placed rather than driven.
  int sent = 0;
  int commutesSent = 0;

  /// Legs walked, in the interim sense §4.9 gives that word before the
  /// pedestrians land: the citizen appears at the far end in the sub-step
  /// they set off, because they own no car, theirs is somewhere else, or
  /// nothing on the network joins the two ends.
  int instantTrips = 0;

  int get liveCount => pool.liveCount;

  /// Trips dwelling at the far end now: a citizen settled in at their
  /// destination whose car has not finished parking, and a restored commuter
  /// row waiting out its return window.
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

  /// The building [trip] started from — for a citizen's leg, wherever they
  /// were standing; for a forced trip, where it was sent from — or −1: the
  /// opaque owner a car parked at work carries (§0 Q3).
  int homeOf(int trip) => pool.isLive(trip) ? home[SlotPool.slotOf(trip)] : -1;

  /// The citizen [trip] belongs to, or −1 for a forced trip.
  int citizenOf(int trip) =>
      pool.isLive(trip) ? citizen[SlotPool.slotOf(trip)] : -1;

  /// The live trip [citizen] is on, or −1. A citizen is on at most one trip
  /// at a time (§6.4), so this is a question with one answer, and [_tripAt]
  /// answers it without a scan.
  int tripOf(int citizen) {
    if (citizen < 0 || !citizens.isLive(citizen)) return SlotPool.none;
    final i = CitizenTable.slotOf(citizen);
    if (i >= _tripAt.length) return SlotPool.none;
    final t = _tripAt[i];
    if (t < 0 || !pool.isLive(t)) return SlotPool.none;
    return this.citizen[SlotPool.slotOf(t)] == citizen ? t : SlotPool.none;
  }

  /// The building slot [citizen] is standing at while they are `atErrand`,
  /// or −1: the destination §6.4's weights drew for them, which is what the
  /// leg home sets off from.
  ///
  /// It is not saved — §14.1's `cit` block carries a state and a wake, not a
  /// destination — so a citizen resumed mid-errand reads −1 here and walks
  /// home from nowhere in particular, which is the one thing a load cannot
  /// know and the cheapest honest answer to it.
  int errandOf(int citizen) {
    if (citizen < 0 || !citizens.isLive(citizen)) return -1;
    final i = CitizenTable.slotOf(citizen);
    if (i >= _errandAt.length) return -1;
    return citizens.state[i] == CitizenState.atErrand.index
        ? _errandAt[i]
        : -1;
  }

  /// Gives [trip] the car it has just parked, so its next leg departs from
  /// there (§7.4 Departure step 1).
  ///
  /// For a CITIZEN that is the end of the leg: the person is at their
  /// destination and their car is standing at it, which is the question
  /// [_carAt] asks of their next departure — so the car goes into their own
  /// column and the row, which was only waiting for this, goes.
  void setCar(int trip, int car) {
    if (!pool.isLive(trip)) return;
    final sl = SlotPool.slotOf(trip);
    this.car[sl] = car;
    final c = citizen[sl];
    if (c < 0) return;
    if (citizens.isLive(c)) citizens.car[CitizenTable.slotOf(c)] = car;
    if (stage[sl] == _stageAtWork) _release(trip);
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

  // ---- The activity loop (§6.4, §5.2 step 1) --------------------------------

  /// Serves the citizens due off the wheel at [nowUs], in wheel order, and
  /// brings home whatever restored row's window is over.
  ///
  /// At most `AgentTuning.maxSpawnsPerStep` wake-ups are served in one
  /// sub-step (§6.5). The rest ROLL OVER: they wait here, in the order the
  /// wheel gave them up, and are served first next time — not put back on
  /// the wheel, where a wake already due would be re-sorted into the
  /// cursor's bucket by slot and so leave its place in the queue. Each is
  /// counted once in `stats.deferred`, when it is first rolled.
  void wake(int nowUs) {
    this.nowUs = nowUs;
    _readDemand();
    _rooms();
    _wheelRoom();
    final cap = AgentTuning.maxSpawnsPerStep;
    final room = _due.length - _rolledCount;
    final n = room > 0 ? citizens.takeDue(nowUs, _due, room) : 0;
    var i = 0, j = 0, served = 0;
    while (served < cap) {
      final rolled = i < _rolledCount;
      if (!rolled && j >= n) break;
      final c = rolled ? _rolled[i] : _due[j];
      if (!citizens.isLive(c)) {
        // Dead since the wheel gave them up: not a wake, and not a deferral.
        if (rolled) {
          i++;
        } else {
          j++;
        }
        continue;
      }
      // A cap refused the trip this person had decided on, so they and
      // everyone behind them wait: the order they leave in is kept (D10).
      if (!_act(c, nowUs)) break;
      if (rolled) {
        i++;
      } else {
        j++;
      }
      served++;
    }
    _roll(i, j, n);
    _returns(nowUs);
  }

  /// §6.1's rush-hour multiplier for the wake-up rates: peaks at day phase
  /// 0.30 and 0.72, reads exactly 1 away from them, and integrates over a day
  /// to the flat rate, so a colony makes the same trips either way and only
  /// their timing moves.
  static double rush(double dayPhase) {
    if (!dayPhase.isFinite) return 1;
    final p = dayPhase - dayPhase.floorToDouble();
    return 1 + AgentTuning.rushAmp * (_bumpAt(p, 0.30) + _bumpAt(p, 0.72));
  }

  bool _open() => !pool.isFull && planner.carTripsOpen(queue);

  // ---- §6.4's rows ------------------------------------------------------------

  /// What [c] does now that their dwell is over. False when a cap refused
  /// the trip they chose and nothing about them was changed, so the wake can
  /// roll into the next sub-step untouched.
  bool _act(int c, int nowUs) {
    final i = CitizenTable.slotOf(c);
    _closeLastLeg(c, i);
    if (_silent) {
      // The colony was asked for no trips at all (`commuteRatePerResident`
      // 0): the wake is answered, so the wheel does not back up, and not a
      // draw is taken, so the demand's stream stands exactly where it was.
      citizens.schedule(
          c,
          nowUs +
              0.5 *
                  (AgentTuning.homeDwellMinS + AgentTuning.homeDwellMaxS) *
                  AgentTuning.activityDwellScale *
                  kUsPerSecond);
      return true;
    }
    switch (CitizenState.values[citizens.state[i]]) {
      case CitizenState.atHome:
        return _fromHome(c, i);
      case CitizenState.atWork:
        return _fromWork(c, i);
      case CitizenState.atErrand:
        return _fromErrand(c, i);
      case CitizenState.outOfTown:
        return _fromOutOfTown(c, i);
      case CitizenState.travelling:
      case CitizenState.riding:
      case CitizenState.movingIn:
      case CitizenState.leaving:
        // None of these is the wheel's to move: a traveller is woken by
        // their arrival, and the two moving states belong to §6.2's
        // realisation. Whatever put the wake here, they wait again.
        _dwellIn(c, i);
        return true;
    }
  }

  /// §6.4 row 1 and row 2: out of the house to work, on an errand, or not
  /// out at all.
  bool _fromHome(int c, int i) {
    final at = citizens.home[i];
    if (at < 0) {
      // Homeless: there is no house to leave and none to come back to, so
      // §6.3's re-housing is what moves them, not this.
      _dwellIn(c, i);
      return true;
    }
    final work = citizens.work[i];
    if (work >= 0 && buildings.isSlotLive(work)) {
      if (rng.nextUnit() < _pCommute) {
        return _go(c, i, at, work, TripPurpose.commute);
      }
      return _errand(c, i, at);
    }
    if (rng.nextUnit() < AgentTuning.errandFromIdle) return _errand(c, i, at);
    _dwell(c, AgentTuning.idleDwellMinS, AgentTuning.idleDwellMaxS,
        rushed: false);
    return true;
  }

  /// §6.4 row 3: home at the end of the day, or by way of an errand — which
  /// row 4 then sends home, so the errand is a detour and not a new day.
  bool _fromWork(int c, int i) {
    final at = citizens.work[i];
    if (rng.nextUnit() < AgentTuning.errandFromWork) return _errand(c, i, at);
    return _go(c, i, at, citizens.home[i], TripPurpose.homeward);
  }

  /// §6.4 row 4: an errand always ends at home.
  bool _fromErrand(int c, int i) =>
      _go(c, i, _whereIs(i), citizens.home[i], TripPurpose.homeward);

  /// §6.4 row 5: back from out of town. The stubs a car comes in by are
  /// slice 8's, so until they exist the traveller simply reappears at home
  /// (§4.9 "before the modes exist").
  bool _fromOutOfTown(int c, int i) {
    final home = citizens.home[i];
    if (home < 0 || !buildings.isSlotLive(home)) {
      _dwellIn(c, i);
      return true;
    }
    _place(c, i, home, TripPurpose.homeward);
    return true;
  }

  /// An errand out of building slot [from]: a destination drawn by §6.4's
  /// weights, or — when the town offers none — the dwell they were having.
  bool _errand(int c, int i, int from) {
    if (from < 0) {
      _dwellIn(c, i);
      return true;
    }
    final dest = _errandDest(i, from, _carAt(i, from) >= 0);
    if (dest < 0) {
      _dwellIn(c, i);
      return true;
    }
    return _go(c, i, from, dest, TripPurpose.errand);
  }

  /// Sets [c] off from building slot [from] to building slot [to] for [p].
  ///
  /// Mode is chosen here (§4.9, §6.4): the car ONLY when it is their own and
  /// it stands where they do, and only when a car can both leave [from] and
  /// reach [to]; otherwise they walk, which until T4b is an instant
  /// placement. False when a cap refused the car trip, and then nothing
  /// about them has changed.
  bool _go(int c, int i, int from, int to, TripPurpose p) {
    if (to < 0 || to == from || !buildings.isSlotLive(to)) {
      _dwellIn(c, i);
      return true;
    }
    final own = _carAt(i, from);
    if (own < 0 || !buildings.reachable(from) || !buildings.reachable(to)) {
      _place(c, i, to, p);
      return true;
    }
    if (!_open()) return false;
    final h = _start(buildings.handleOf(from), buildings.handleOf(to),
        oneWay: true,
        kind: AgentKind.car,
        purpose: p,
        car: own,
        citizen: c);
    if (h == SlotPool.none) {
      // The queue refused it after the caps said there was room: it has
      // been counted deferred already, and they ask again in a moment.
      citizens.schedule(c, nowUs + kTripRetryS * kUsPerSecond);
      return true;
    }
    _tripAt[i] = h;
    // Off the wheel for the whole leg: their arrival is what wakes them.
    citizens.unschedule(c);
    sent++;
    if (p == TripPurpose.commute) commutesSent++;
    return true;
  }

  /// The walk of §4.9's interim: [c] is at building slot [to] in this
  /// sub-step, with the dwell that goes with being there.
  void _place(int c, int i, int to, TripPurpose p) {
    sent++;
    instantTrips++;
    if (p == TripPurpose.commute) commutesSent++;
    _settle(c, i, to, p);
  }

  /// Where [c] now is, and until when: the far end of a leg, whether it was
  /// driven, walked, or ended early (§5.6).
  void _settle(int c, int i, int at, TripPurpose p) {
    _rooms();
    switch (p) {
      case TripPurpose.commute:
        citizens.state[i] = CitizenState.atWork.index;
        _errandAt[i] = -1;
        _dwell(c, AgentTuning.commuteReturnMinS, AgentTuning.commuteReturnMaxS,
            rushed: true);
      case TripPurpose.errand:
        citizens.state[i] = CitizenState.atErrand.index;
        _errandAt[i] = at;
        _dwell(c, AgentTuning.errandDwellMinS, AgentTuning.errandDwellMaxS,
            rushed: false);
      default:
        citizens.state[i] = CitizenState.atHome.index;
        _errandAt[i] = -1;
        _dwellAtHome(c, i);
    }
  }

  /// The building slot [c] is standing at, or −1: their home, their job, or
  /// the errand they are on. A citizen resumed from a save is at no errand
  /// anyone remembers (§14.1 saves no destination), and reads −1 here, which
  /// sends them home by the interim walk rather than nowhere at all.
  int _whereIs(int i) {
    switch (CitizenState.values[citizens.state[i]]) {
      case CitizenState.atWork:
        return citizens.work[i];
      case CitizenState.atErrand:
        return i < _errandAt.length ? _errandAt[i] : -1;
      default:
        return citizens.home[i];
    }
  }

  /// The car of the citizen in slot [i], when it is standing at building
  /// slot [at]; −1 otherwise — they own none, they are driving it, it is
  /// parked somewhere else, or its row has gone. §6.4: "a car trip needs the
  /// citizen's car at their current location"; §4.9 adds that one who walked
  /// or rode cannot use the car until they are home again, which is the same
  /// question asked of the same column.
  int _carAt(int i, int at) {
    final own = citizens.car[i];
    if (own < 0 || at < 0) return -1;
    final parked = cars;
    if (parked == null || !parked.isLive(own)) return -1;
    return parked.building[SlotPool.slotOf(own)] == at ? own : -1;
  }

  /// A building for an errand out of [from]: any reachable, served building
  /// that is neither this citizen's home nor their job, drawn with weight
  /// `1/(1 + skim/180)` on their own mode's skim (slice3 §0 Q7, §6.4). −1
  /// when the town has none — a one-lot colony, or a walker whose only
  /// candidates are off the network.
  ///
  /// Two passes and one draw, because the weights are cheap and an index
  /// would have to be rebuilt whenever a building appeared.
  int _errandDest(int i, int from, bool byCar) {
    final b = buildings;
    final home = citizens.home[i], work = citizens.work[i];
    var total = 0.0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!_errandOk(sl, from, home, work, byCar)) continue;
      total += _errandWeight(from, sl, byCar);
    }
    if (!(total > 0)) return -1;
    var r = rng.nextUnit() * total;
    var last = -1;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!_errandOk(sl, from, home, work, byCar)) continue;
      last = sl;
      r -= _errandWeight(from, sl, byCar);
      if (r < 0) return sl;
    }
    return last;
  }

  bool _errandOk(int sl, int from, int home, int work, bool byCar) {
    final b = buildings;
    if (sl == from || sl == home || sl == work) return false;
    if (!b.isSlotLive(sl) || b.served[sl] == 0) return false;
    // A walker is held only to the colony's own network, as §6.3's job match
    // holds them; a driver needs a building a car can reach and leave.
    return !byCar || b.reachable(sl);
  }

  double _errandWeight(int from, int to, bool byCar) {
    final s = byCar ? skims.carSkim(from, to) : skims.footSkim(from, to);
    return 1 / (1 + (s > 0 ? s : 0) / kErrandSkimS);
  }

  // ---- Dwells (§6.4's intervals) -------------------------------------------

  /// Schedules [c]'s next wake between [minS] and [maxS] agent seconds out,
  /// scaled by `activityDwellScale` — and, for the two rows §6.4 divides,
  /// by [rush] and by the demand scale, so that a rush hour and a raised
  /// `commuteRatePerResident` both shorten the wait rather than move anyone.
  void _dwell(int c, double minS, double maxS, {required bool rushed}) {
    var s = rng.nextBetween(minS, maxS) * AgentTuning.activityDwellScale;
    if (rushed) {
      // `rushAmp` is a knob, so the multiplier is not guaranteed positive
      // the way the shipped shape is: a divisor that went to zero or below
      // would make a dwell of nothing or of the far side of time.
      var r = rush(dayPhase) * _boost;
      if (!(r > _minRush)) r = _minRush;
      s /= r;
    }
    if (!(s > 0)) s = 0;
    citizens.schedule(c, nowUs + s * kUsPerSecond);
  }

  /// The dwell of whatever [c] is doing now: what a citizen who decided to
  /// stay put, or whose trip could not be planned, waits out.
  void _dwellIn(int c, int i) {
    switch (CitizenState.values[citizens.state[i]]) {
      case CitizenState.atWork:
        _dwell(c, AgentTuning.commuteReturnMinS, AgentTuning.commuteReturnMaxS,
            rushed: true);
      case CitizenState.atErrand:
        _dwell(c, AgentTuning.errandDwellMinS, AgentTuning.errandDwellMaxS,
            rushed: false);
      case CitizenState.outOfTown:
        _dwell(c, AgentTuning.outOfTownMinS, AgentTuning.outOfTownMaxS,
            rushed: false);
      default:
        _dwellAtHome(c, i);
    }
  }

  /// §6.4's first two rows differ only in their dwell: a citizen with a job
  /// waits U(150, 420) ÷ rush before leaving, one without waits U(200, 600).
  void _dwellAtHome(int c, int i) {
    final work = citizens.work[i];
    if (work >= 0 && buildings.isSlotLive(work)) {
      _dwell(c, AgentTuning.homeDwellMinS, AgentTuning.homeDwellMaxS,
          rushed: true);
      return;
    }
    _dwell(c, AgentTuning.idleDwellMinS, AgentTuning.idleDwellMaxS,
        rushed: false);
  }

  // ---- The demand scale (slice3 §0, Q1) ------------------------------------

  /// The chance a citizen at home with a job leaves for work rather than on
  /// an errand, and what the scale could not fit into it.
  double _pCommute = 1 - AgentTuning.errandFromHome;
  double _boost = 1;
  bool _silent = false;

  /// Reads `commuteRatePerResident` as §0's scale, once per sub-step.
  ///
  /// The scale multiplies the commute WAKE-UP RATE, which is `p / dwell`.
  /// Below saturation it is all probability, which is §0's sentence exactly;
  /// past it the probability is 1 and the rest divides the dwell, so the
  /// knob keeps meaning something above `1/(1 − errandFromHome)`. The travel
  /// time is the floor it cannot push through: a cycle is a dwell at home, a
  /// drive, a dwell at work and a drive back, and only the dwells are the
  /// demand's to shorten.
  void _readDemand() {
    final s = AgentTuning.commuteRatePerResident / kDesignCommuteRate;
    _silent = !(s > 0);
    final r = (1 - AgentTuning.errandFromHome) * s;
    _pCommute = r < 1 ? r : 1.0;
    _boost = r > 1 ? r : 1.0;
  }

  // ---- The wheel's overflow -------------------------------------------------

  /// Citizens the wheel gave up this sub-step, and those given up and not
  /// yet served. Both are the same length, so the second can hold everything
  /// the first could.
  Int32List _due = Int32List(0);
  Int32List _rolled = Int32List(0);
  int _rolledCount = 0;

  /// Per citizen slot: the live trip they are on (−1), and the building an
  /// `atErrand` citizen is standing at (−1 otherwise).
  Int32List _tripAt = Int32List(0);
  Int32List _errandAt = Int32List(0);

  /// The wake-ups one sub-step may take off the wheel, which is also the
  /// bound on the roll-over queue.
  ///
  /// Generously more than the spawn cap, because a wake TAKEN and not served
  /// is counted deferred while one still on the wheel is not, and the count
  /// is most useful when it names the whole backlog the moment it forms. A
  /// burst past even this waits on the wheel, in order, and is counted when
  /// a later call reaches it — so no wake is counted twice and none is
  /// missed, only some are counted late. Eight kilobytes at the floor.
  static const int _batchPerCap = 16;
  static const int _batchFloor = 256;

  /// The least [rush] × demand-scale a dwell may be divided by.
  static const double _minRush = 0.05;

  void _wheelRoom() {
    var want = AgentTuning.maxSpawnsPerStep * _batchPerCap;
    if (want < _batchFloor) want = _batchFloor;
    if (_due.length >= want) return;
    _due = Int32List(want);
    final was = _rolled;
    _rolled = Int32List(want);
    _rolled.setRange(0, was.length, was);
  }

  void _rooms() {
    final n = citizens.capacity;
    if (_tripAt.length >= n) return;
    final wasTrip = _tripAt, wasErrand = _errandAt;
    _tripAt = Int32List(n)..fillRange(0, n, -1);
    _tripAt.setRange(0, wasTrip.length, wasTrip);
    _errandAt = Int32List(n)..fillRange(0, n, -1);
    _errandAt.setRange(0, wasErrand.length, wasErrand);
  }

  /// Keeps what was not served: the rolled-over rows from [i] on, then the
  /// wheel's own from [j] to [n]. Only the second group is newly deferred —
  /// the first was counted when it was rolled — so nobody is counted twice
  /// and nobody is dropped.
  void _roll(int i, int j, int n) {
    final kept = _rolledCount - i;
    final newly = n - j;
    if (newly > 0) stats.deferred += newly;
    for (var k = 0; k < kept; k++) {
      _rolled[k] = _rolled[i + k];
    }
    for (var k = 0; k < newly; k++) {
      _rolled[kept + k] = _due[j + k];
    }
    _rolledCount = kept + newly;
  }

  // ---- Rows that have done their work --------------------------------------

  /// The row [c]'s last leg left dwelling, once they are awake again: it was
  /// only waiting for [setCar], and nothing came.
  void _closeLastLeg(int c, int i) {
    final t = tripOf(c);
    if (t < 0) return;
    final sl = SlotPool.slotOf(t);
    if (stage[sl] != _stageAtWork) return;
    if (car[sl] < 0 && citizens.car[i] == CitizenTable.carDriving) {
      // Their car left the world with the vehicle and nothing ever parked
      // it: the last resort of §7.5 D17 step 5 is a garage, and a garage
      // that could not be opened is a car the colony has lost. They own
      // none rather than one that is nowhere.
      citizens.car[i] = CitizenTable.carNone;
    }
    _release(t);
  }

  /// [trip] is over: its car, if it still holds one nobody drove, goes back
  /// where it stood, and the row is freed.
  void _release(int trip) {
    if (!pool.isLive(trip)) return;
    final sl = SlotPool.slotOf(trip);
    final c = citizen[sl];
    if (c >= 0) {
      final i = CitizenTable.slotOf(c);
      if (i < _tripAt.length && _tripAt[i] == trip) _tripAt[i] = -1;
    }
    _dropCar(sl);
    pool.free(trip);
  }

  /// The legacy restored rows only (`citizen == -1`): a commuter car a load
  /// put back at work drives home when its return window is up, and a row
  /// whose citizen has died goes.
  ///
  /// One pass a second over the trips, which is what `CommuteSynth`'s own
  /// return sweep cost, and it is where the rows nobody will wake are
  /// collected.
  void _returns(int nowUs) {
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl)) continue;
      final c = citizen[sl];
      if (c >= 0) {
        // A citizen's dwelling row is theirs to close, at their next wake
        // or at [setCar]; one whose person has gone belongs to nobody.
        if (stage[sl] == _stageAtWork &&
            (!citizens.isLive(c) || tripOf(c) != pool.handleOf(sl))) {
          _release(pool.handleOf(sl));
        }
        continue;
      }
      if (stage[sl] != _stageAtWork || wakeUs[sl] > nowUs) continue;
      if (!planner.carTripsOpen(queue)) {
        // Everyone after waits too: the order they leave in is kept.
        stats.deferred++;
        return;
      }
      leg[sl] = _toHome;
      _request(pool.handleOf(sl));
    }
  }

  // ---- Rows ------------------------------------------------------------------

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
  /// An outbound leg leaves from a parked car, taken here rather than at the
  /// spawn (§0 Q3): a citizen's is their own, and a forced trip's comes out
  /// of its origin home's pool, promised to this trip from the moment it is
  /// asked for — so two forced trips out of one house never claim the same
  /// car — and the car keeps standing on its stall, where it still blocks
  /// whatever is behind it on a tandem pad.
  bool _request(int trip, {int tag = kTripTag}) {
    final sl = SlotPool.slotOf(trip);
    final out = leg[sl] == _toWork;
    stage[sl] = _stagePlanning;
    if (out && car[sl] < 0) _takeCar(sl);
    final ok = queue.enqueue(PathPriority.car,
        requester: trip,
        kind: AgentKind.values[kind[sl]],
        origin: out ? home[sl] : job[sl],
        dest: out ? job[sl] : home[sl],
        tag: tag);
    if (ok) return true;
    stats.deferred++;
    if (out) {
      final c = citizen[sl];
      _release(trip);
      if (c >= 0 && citizens.isLive(c)) _dwellIn(c, CitizenTable.slotOf(c));
    } else {
      // Still at the far end: it tries again next second.
      stage[sl] = _stageAtWork;
      leg[sl] = _toWork;
      wakeUs[sl] = nowUs.toDouble();
    }
    return false;
  }

  /// The car [sl]'s outbound leg departs from: the citizen's own, or a car
  /// out of the origin home's pool for a trip that belongs to nobody.
  void _takeCar(int sl) {
    final parked = cars;
    if (parked == null) return;
    final c = citizen[sl];
    if (c < 0) {
      if (home[sl] >= 0) {
        car[sl] = parked.takePooled(SlotPool.slotOf(home[sl]));
      }
      return;
    }
    if (!citizens.isLive(c)) return;
    final own = citizens.car[CitizenTable.slotOf(c)];
    if (own >= 0 && parked.isLive(own)) car[sl] = own;
  }

  /// The trip that took [sl]'s car never ran: the car goes back in its pool,
  /// where it stood all along. A car nobody pooled — a citizen's own — is
  /// left exactly where it is.
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
      _giveUp(h, sl);
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
      _giveUp(h, sl);
    } else if (v != SlotPool.none) {
      spawned(h, v);
    } else {
      stage[sl] = _stageWaiting;
    }
  }

  /// [trip] never set off: its row goes, and its citizen — who never left —
  /// waits out the dwell they were having.
  void _giveUp(int trip, int sl) {
    final c = citizen[sl];
    _release(trip);
    if (c >= 0 && citizens.isLive(c)) _dwellIn(c, CitizenTable.slotOf(c));
  }

  @override
  void spawned(int owner, int handle) {
    if (!pool.isLive(owner)) return;
    final sl = SlotPool.slotOf(owner);
    vehicle[sl] = handle;
    stage[sl] = _stageDriving;
    // The car IS the vehicle now: its parked row went with the spawn.
    car[sl] = -1;
    final c = citizen[sl];
    if (c < 0 || !citizens.isLive(c)) return;
    final i = CitizenTable.slotOf(c);
    citizens.state[i] = CitizenState.travelling.index;
    citizens.car[i] = CitizenTable.carDriving;
    citizens.agent[i] = handle;
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
  /// starts from the site's out-joins again.
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
    final c = citizen[sl];
    if (!buildings.isLive(dest)) {
      stats.arrivedGone++;
      if (c >= 0) {
        // §4.7: their destination was torn down while they drove. A leg
        // home is appended — unless they were already going home, or home
        // has gone too, and then the leg simply ends where it stopped.
        final back = _legHome(sl, c);
        if (back >= 0) return back;
        _arriveCitizen(t, sl, nowUs, -1);
        return -1;
      }
      if (out && oneWay[sl] == 0 && buildings.isLive(home[sl])) {
        leg[sl] = _toHome;
        return home[sl];
      }
      _release(t);
      return -1;
    }
    if (c >= 0) {
      _arriveCitizen(t, sl, nowUs, dest);
      return -1;
    }
    vehicle[sl] = -1;
    if (out && oneWay[sl] == 0) {
      _clockIn(sl, nowUs);
    } else {
      _release(t);
    }
    return -1;
  }

  /// [vehicleHandle] was taken off the road before it arrived: the leg
  /// failed. Someone lost on the way to work is at work all the same — the
  /// design places a citizen at their destination (§5.6) — and their car is
  /// garaged there by the facade, which is why the row waits for [setCar]
  /// exactly as an arrival's does.
  void despawned(int vehicleHandle, int nowUs) {
    final t = _tripOfVehicle(vehicleHandle);
    if (t < 0) return;
    final sl = SlotPool.slotOf(t);
    stats.tripFailed();
    vehicle[sl] = -1;
    if (citizen[sl] >= 0) {
      _arriveCitizen(t, sl, nowUs, leg[sl] == _toWork ? job[sl] : home[sl]);
      return;
    }
    if (leg[sl] == _toWork && oneWay[sl] == 0) {
      _clockIn(sl, nowUs);
    } else {
      _release(t);
    }
  }

  /// [vehicleHandle] left the road with nowhere left to go — an appended
  /// leg that found no path: the trip ends there. Its citizen is put back
  /// home, because a person standing in the middle of a road is a person no
  /// row could ever wake.
  void vanished(int vehicleHandle) {
    final t = _tripOfVehicle(vehicleHandle);
    if (t < 0) return;
    stats.noRoute++;
    final sl = SlotPool.slotOf(t);
    final c = citizen[sl];
    if (c >= 0 && citizens.isLive(c)) {
      final i = CitizenTable.slotOf(c);
      citizens.agent[i] = -1;
      if (citizens.car[i] == CitizenTable.carDriving) {
        citizens.car[i] = CitizenTable.carNone;
      }
      _settle(c, i, citizens.home[i], TripPurpose.homeward);
    }
    _release(t);
  }

  /// [sl]'s citizen is at building [dest] (−1: wherever the leg stopped, and
  /// they are counted as home). They take up the activity that destination
  /// is for, at once; the ROW stays, dwelling, until the car it parked is
  /// handed over by [setCar] or their next wake closes it.
  void _arriveCitizen(int trip, int sl, int nowUs, int dest) {
    final c = citizen[sl];
    vehicle[sl] = -1;
    stage[sl] = _stageAtWork;
    leg[sl] = _toWork;
    wakeUs[sl] = nowUs.toDouble();
    if (!citizens.isLive(c)) {
      _release(trip);
      return;
    }
    final i = CitizenTable.slotOf(c);
    citizens.agent[i] = -1;
    final there = dest >= 0 && buildings.isLive(dest);
    _settle(c, i, there ? SlotPool.slotOf(dest) : -1,
        there ? TripPurpose.values[purpose[sl]] : TripPurpose.homeward);
  }

  /// Re-targets [sl] at its citizen's home and answers that handle, or −1
  /// when there is no leg home to append: they were already going there, or
  /// their home has gone as well.
  int _legHome(int sl, int c) {
    if (purpose[sl] == TripPurpose.homeward.index) return -1;
    if (!citizens.isLive(c)) return -1;
    final home = citizens.home[CitizenTable.slotOf(c)];
    if (home < 0 || !buildings.isSlotLive(home)) return -1;
    final h = buildings.handleOf(home);
    if (h == job[sl] || h == this.home[sl]) return -1;
    job[sl] = h;
    leg[sl] = _toWork;
    purpose[sl] = TripPurpose.homeward.index;
    return h;
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

  // ---- §6.1's rush-hour table -------------------------------------------------
  //
  // `bump` is a TABLE, not a function: `exp` is the platform's maths library
  // and is free to round differently from one build target to the next, so
  // neither the tick nor the class's initialisation may call it (D27). These
  // are its 64 samples, written out.
  //
  // The shape is §6.1's Gaussian of σ = 0.05, sampled over a quarter day
  // either side of the peak and ZERO beyond that, with a shallow trough
  // subtracted — a half-sine window, which leaves the peak itself at exactly
  // 1 — chosen so that the kernel integrates over the day to NOTHING. That
  // is what "normalised so that daily throughput is unchanged" has to mean
  // for a multiplier of the wake-up rate: a positive bump alone would make
  // 15% more trips a day rather than the same trips clustered. So rush hour
  // BORROWS its trips from the hours around it — the shoulders read below 1
  // — and reads exactly 1 everywhere outside the two supports, which
  // together cover [0.05, 0.55] and [0.47, 0.97] of the day.
  //
  // Generated once, to twelve decimal places, with the trough sample carrying
  // the rounding so that the trapezoid of the table below is zero to 1e-16.

  /// Half the support of one bump, in day phase.
  static const double _bumpWidth = 0.25;

  static final Float64List _bump = Float64List.fromList(const <double>[
    1.0, 0.995609947098, 0.982511368986, 0.96091703064, //
    0.931175033335, 0.893759337661, 0.849257046738, 0.798352964124, //
    0.741812038546, 0.68046037289, 0.615165505221, 0.546816664798, //
    0.476305667904, 0.404509050558, 0.332271943337, 0.260394083937, //
    0.189618243089, 0.120621216098, 0.054007412729, -0.009695031717, //
    -0.070035796277, -0.126641813931, -0.179214915717, -0.227528018793, //
    -0.271420211899, -0.310791086662, -0.345594642, -0.375833054685, //
    -0.401550565582, -0.422827681913, -0.43977584447, -0.452532658276, //
    -0.461257738159, -0.466129179208, -0.467340627308497, -0.465098897751, //
    -0.459622070309, -0.451137977069, -0.439882993757, -0.426101045663, //
    -0.410042744293, -0.391964579457, -0.372128102569, -0.350799049449, //
    -0.328246363941, -0.304741096504, -0.280555164, -0.25595996777, //
    -0.231224876493, -0.206615588158, -0.18239239167, -0.158808353251, //
    -0.136107455983, -0.114522722728, -0.094274353429, -0.075567907586, //
    -0.05859256178, -0.043519470469, -0.030500256291, -0.019665653621, //
    -0.011124326506, -0.004961879213, -0.001240074708, 0.000003726653, //
  ]);

  /// The bump centred at [centre], read at day phase [phase]: the table
  /// interpolated linearly at the circular distance between them, and 0
  /// beyond [_bumpWidth].
  static double _bumpAt(double phase, double centre) {
    var d = (phase - centre).abs();
    if (d > 0.5) d = 1 - d;
    if (!(d < _bumpWidth)) return 0;
    final last = _bump.length - 1;
    final f = d / _bumpWidth * last;
    final i = f.floor();
    if (i >= last) return _bump[last];
    final a = _bump[i];
    return a + (_bump[i + 1] - a) * (f - i);
  }
}
