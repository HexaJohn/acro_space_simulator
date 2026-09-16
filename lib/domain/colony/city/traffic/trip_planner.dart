// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where trips come from, and how a planned trip gets onto the road
/// (docs/plans/agent-traffic.md §4.8, §5.2 step 2, §6.5, §6.7).
///
/// [TripPlanner] is the gate every car trip passes: the caps that DEFER a
/// trip rather than drop or teleport it (D9, D10), the per-sub-step spawn
/// cap and its warm-up ramp, and the queue of routes that are planned but
/// still waiting for a gap to pull out into (§5.5). A trip waits at its
/// origin until its path is ready; no vehicle slot is taken before then.
///
/// [CommuteSynth] is slice 1's demand, standing in until citizens exist
/// (slice 3 deletes it): every built, served home sends commuters to work
/// at the design's per-resident rate, to a job drawn by jobs, and brings
/// each home after a working dwell. Its trips name BUILDINGS, by handle, so
/// a lot a road edit renames keeps its trips (E12–E14), and a trip whose
/// destination was torn down while it drove finds that out on arrival and
/// is re-targeted home by an appended leg — its route is never edited
/// (§4.7).
///
/// **A trip starts from its own parked car** (site-access.md §7.4 Departure,
/// §7.5; t4a-implementation.md §2, item 6). A commuter leaving home takes a
/// car out of that home's pool ([ParkedCarTable.takePooled]), and the leg
/// home leaves the car it parked at work. Where that car STANDS decides how
/// it joins the road: a car on a lot stall is handed to the site mover,
/// which reverses it out and asks for its gap at the throat or backs it down
/// the drive ([StallDepartures]); a car at a kerb slot joins the lane from
/// the slot through the same `canJoin` every spawn asks; a garaged car
/// simply appears at the building's access, as §5.6 says it does.
///
/// Both run on agent time, in the sub-step, and allocate nothing once warm:
/// commuters are a [SlotPool] of typed columns, the waiting routes a
/// [RouteArena] of their own.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../site_access/site_access_plan.dart';
import 'agent_kind.dart';
import 'building_table.dart';
import 'graph_lineage.dart';
import 'junction_arbiter.dart';
import 'kerb_slots.dart';
import 'lane_graph.dart';
import 'node_control.dart';
import 'parked_cars.dart';
import 'path_search.dart';
import 'route_arena.dart';
import 'route_cost.dart';
import 'site_table.dart';
import 'slot_pool.dart';
import 'traffic_rng.dart';
import 'traffic_stats.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';
import 'vehicle_table.dart';

/// The `PathRequest.tag` of a trip from one building to another. The
/// facade's own requests — a re-plan, an appended leg — carry others.
const int kTripTag = 0;

/// What [TripPlanner.deliver] answers for a route the arena could not hold
/// (a sprawl-crossing trip longer than `RouteArena.maxBlock`; slice 8 splits
/// those into legs).
const int kRouteTooLong = -2;

/// At most this many trips a home may owe and not yet have sent: past it,
/// demand a cap deferred is shed rather than saved up for a burst.
const double kMaxOwedTrips = 3;

/// How near a route's origin arc a site's out-join must be for the departure
/// to be that join's (site-access.md §7.4 departure step 2). The origin came
/// from the very join column the match is against, so this is slack for the
/// clamp `AccessPoint.sOn` applies beside a junction, not a search radius;
/// V4 keeps two cuts on one edge at least 6 m apart, so it names one join.
const double kDepartJoinM = 1.5;

/// Puts a parked car on the road out of its site stall: the site mover's
/// `spawnFromStall` (site_mover.dart), behind an interface so this file does
/// not import the mover that imports it.
abstract interface class StallDepartures {
  /// See `SiteMover.spawnFromStall`.
  int spawnFromStall(
      {required int row,
      required int stall,
      required int join,
      required AgentKind kind,
      required int variant,
      required int ownerKind,
      required int owner,
      required Int32List route,
      required int n,
      required double originT,
      required double destT,
      required int nowUs,
      required double speedFactor,
      required double freeFlowS});
}

/// Told what became of a route that had to wait to pull out.
abstract interface class SpawnSink {
  /// [owner]'s vehicle is on the road now, as [handle].
  void spawned(int owner, int handle);

  /// [owner]'s route, planned and still waiting to pull out, was made
  /// impossible by a network edit (§3.9, [TripPlanner.remapWaiting]): plan
  /// it again, from its origin, on the new network.
  void replanWaiting(int owner);
}

/// The seconds [route] (`[firstLane, c₁, …]`, [n] elements) takes on an
/// empty network by a driver of desired-speed factor [f], from travel arc
/// [originT] of its first edge to [destT] of its last: every lane at the
/// limit, every connector at the slower of its limit and its bend
/// (§4.2's `free`), plus each node's expected control delay — the J the
/// cost already charges for a light or a stop. What an empty network costs
/// is then a trip ratio near 1, not a penalty for the stop signs.
double freeFlowSeconds(LaneGraph lg, Int32List route, int n, double originT,
    double destT, double f) {
  final ctl = lg.controls;
  var total = 0.0;
  var lane = route[0];
  for (var i = 0; i < n; i++) {
    if (i > 0) {
      final c = route[i];
      final from = lg.conFromEdge(c), to = lg.conToEdge(c);
      final lim = math.min(lg.edgeLimit[from], lg.edgeLimit[to]) * f;
      final v = math.min(lim, lg.conVmax[c].toDouble());
      if (v > 0) total += lg.conLen[c] / v;
      final kind = lg.kindOf(lg.conNode[c]);
      if (!isTurningPlace(kind)) {
        total += junctionPenaltyS(kind,
            stops: ctl.edgeStops[from] == 1, yields: ctl.edgeYields[from] == 1);
      }
      lane = lg.conToLane[c];
    }
    final e = lg.laneEdge[lane];
    final t0 = i == 0 ? originT : lg.edgeLaneS0[e].toDouble();
    final t1 = i == n - 1 ? destT : lg.edgeLaneS1[e].toDouble();
    final v = lg.edgeLimit[e] * f;
    if (t1 > t0 && v > 0) total += (t1 - t0) / v;
  }
  return total;
}

/// The gate between a planned route and a vehicle on the road.
class TripPlanner {
  TripPlanner(this.table, this.arbiter, this.rng, this.stats)
      : originT = Float32List(table.capacity);

  final VehicleTable table;
  final JunctionArbiter arbiter;

  /// The spawn draws — a car's speed factor, its variant byte — on a stream
  /// of their own.
  final TrafficRng rng;
  final TrafficStats stats;

  /// Per vehicle slot: the travel arc its route leaves its first edge at —
  /// where a drawn route starts (the readout's `TripRoute.polyline`).
  Float32List originT;

  /// Where a departing trip's own car stands, and what the departure takes
  /// from it: the parked cars, the synced sites (for the out-join a stall
  /// leaves by), the kerb slots and the site mover. All null until T4a's
  /// facade sets them, and then a colony with no plans simply never has a
  /// car to depart from.
  ParkedCarTable? cars;
  SiteTable? sites;
  KerbTable? kerbs;
  StallDepartures? stalls;

  final RouteArena _arena = RouteArena(4096);
  final Int32List _scratch = Int32List(RouteArena.maxBlock);
  Int32List _owner = Int32List(64), _off = Int32List(64), _len = Int32List(64);
  Uint8List _kind = Uint8List(64), _purpose = Uint8List(64);
  Uint8List _left = Uint8List(64);
  Float64List _fromT = Float64List(64), _toT = Float64List(64);

  /// Per waiting route: the parked car it departs from, or −1.
  Int32List _carOf = Int32List(64)..fillRange(0, 64, -1);
  int _waiting = 0;
  int _spawnsLeft = 0;

  /// Routes planned and waiting to pull out.
  int get waiting => _waiting;

  /// Every buffer the planner keeps from one sub-step to the next — the
  /// spawn columns, and the waiting routes' columns, arena and scratch —
  /// by name into [into], for the allocation test (§15.2): once warm, none
  /// is ever replaced. The waiting columns grow by doubling while the
  /// queue is new, and must not once it is warm.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.originT'] = originT;
    into['$name.arena'] = _arena.data;
    into['$name.scratch'] = _scratch;
    into['$name.owner'] = _owner;
    into['$name.off'] = _off;
    into['$name.len'] = _len;
    into['$name.kind'] = _kind;
    into['$name.purpose'] = _purpose;
    into['$name.left'] = _left;
    into['$name.fromT'] = _fromT;
    into['$name.toT'] = _toT;
    into['$name.carOf'] = _carOf;
  }

  /// Car trips may have this many vehicles on the road; the rest of
  /// `maxVehicles` is held back for service, transit and freight (§4.8).
  static int get carCap =>
      AgentTuning.maxVehicles -
      (AgentTuning.maxVehicles * AgentTuning.serviceReserveShare).ceil();

  /// Starts sub-step [nowUs]'s spawn budget: `maxSpawnsPerStep`, ramped up
  /// from nothing over the first `warmupS` of agent time, so a colony that
  /// has just enabled agents or been loaded does not spawn a burst (§5.7).
  void beginStep(int nowUs) {
    final w = AgentTuning.warmupS;
    final ramp = w <= 0 ? 1.0 : math.min(1.0, secondsOf(nowUs) / w);
    _spawnsLeft = (AgentTuning.maxSpawnsPerStep * ramp).floor();
  }

  /// Whether a new car trip may be asked for now: the car queue under its
  /// cap, and the car share of the vehicle table not taken — by vehicles
  /// on the road and by routes waiting to join them. Otherwise it is
  /// deferred: it waits at its origin (D10).
  bool carTripsOpen(PathQueue queue) =>
      queue.lengthOf(PathPriority.car) + _waiting < AgentTuning.maxQueuedPaths &&
      table.liveCount + _waiting < carCap;

  /// A route found for [owner]'s trip by a [kind] vehicle for [purpose]:
  /// on the road at once if nothing is waiting ahead of it and there is a
  /// gap, else queued to pull out when there is. [fromLeft]: the origin is
  /// on the left of travel along the first edge. [car] is the parked car the
  /// trip departs from (−1 for none), which decides where it joins the road
  /// (§7.4 Departure). Returns the vehicle's handle; `SlotPool.none` when it
  /// waits; [kRouteTooLong] when no route block can hold it.
  int deliver(int owner, AgentKind kind, TripPurpose purpose, PlannedRoute route,
      {required bool fromLeft, required int nowUs, int car = -1}) {
    final n = route.length;
    if (n < 1 || n > RouteArena.maxBlock) return kRouteTooLong;
    if (_waiting == 0) {
      final h = _spawn(owner, kind.index, purpose.index, fromLeft, route.elems,
          n, route.originT, route.destT, nowUs, car);
      if (h != SlotPool.none) return h;
    }
    if (_waiting == _owner.length) _growWaiting();
    final i = _waiting++;
    final off = _arena.alloc(n);
    _arena.data.setRange(off, off + n, route.elems);
    _owner[i] = owner;
    _off[i] = off;
    _len[i] = n;
    _kind[i] = kind.index;
    _purpose[i] = purpose.index;
    _left[i] = fromLeft ? 1 : 0;
    _fromT[i] = route.originT;
    _toT[i] = route.destT;
    _carOf[i] = car;
    return SlotPool.none;
  }

  /// Puts on the road every waiting route that has a gap to pull out into,
  /// oldest first, while the sub-step's spawn budget lasts; the rest keep
  /// their places in the queue.
  void spawnReady(int nowUs, SpawnSink sink) {
    var w = 0;
    for (var i = 0; i < _waiting; i++) {
      var h = SlotPool.none;
      if (_spawnsLeft > 0) {
        final n = _len[i];
        _scratch.setRange(0, n, _arena.data, _off[i]);
        h = _spawn(_owner[i], _kind[i], _purpose[i], _left[i] == 1, _scratch, n,
            _fromT[i], _toT[i], nowUs, _carOf[i]);
      }
      if (h != SlotPool.none) {
        _arena.free(_off[i], _len[i]);
        sink.spawned(_owner[i], h);
        continue;
      }
      if (w != i) _move(i, w);
      w++;
    }
    _waiting = w;
  }

  /// Carries every waiting route onto the network an edit just built
  /// (§3.9), as the routes on the road are carried: by lineage, from the
  /// place it will pull out at, straight through any junction the edit made
  /// and in the lanes it was planned in. A trip already planned never takes
  /// a new road (§4.6). Only a route the edit made impossible goes back to
  /// be planned again — counted in `stats.replans`, in the order it was
  /// waiting. Returns how many did.
  int remapWaiting(RouteRemapper rm, SpawnSink sink) {
    final from = rm.lineage.from;
    final data = _arena.data;
    final n = _waiting;
    var w = 0, replanned = 0;
    for (var i = 0; i < n; i++) {
      final off = _off[i], len = _len[i];
      final e0 = from.laneEdge[data[off]];
      final st = rm.remap(data, off, len,
          s: _fromT[i] - from.edgeLaneS0[e0], destS: _toT[i]);
      _arena.free(off, len);
      if (st != RemapStatus.kept) {
        // Still at its origin: it asks again, from there, on the new
        // network (its building resolves afresh).
        stats.replans++;
        replanned++;
        sink.replanWaiting(_owner[i]);
        continue;
      }
      if (rm.lanesRepaired) stats.lanesRepaired++;
      final m = rm.routeLength;
      final at = _arena.alloc(m);
      _arena.data.setRange(at, at + m, rm.route);
      if (w != i) _move(i, w);
      _off[w] = at;
      _len[w] = m;
      _fromT[w] = rm.placeT;
      _toT[w] = rm.stopS;
      w++;
    }
    _waiting = w;
    return replanned;
  }

  /// [hash] with every waiting route folded in, in queue order: for
  /// `CityAgents.digest`.
  int digest(int hash) {
    var h = fnv1aU32(hash, _waiting);
    final data = _arena.data;
    for (var i = 0; i < _waiting; i++) {
      h = fnv1aU32(h, _owner[i]);
      h = fnv1aU32(h, _kind[i] | _purpose[i] << 8 | _left[i] << 16);
      h = fnv1aU32(h, _len[i]);
      for (var k = 0; k < _len[i]; k++) {
        h = fnv1aU32(h, data[_off[i] + k]);
      }
      h = fnv1aU32(h, (_fromT[i] * 1000).round());
      h = fnv1aU32(h, (_toT[i] * 1000).round());
      // Only a route that HAS a car folds one, so a colony that parks
      // nothing digests exactly as it did before T4a.
      if (_carOf[i] >= 0) h = fnv1aU32(h, _carOf[i]);
    }
    return fnv1aU32(h, _spawnsLeft);
  }

  int _spawn(int owner, int kind, int purpose, bool left, Int32List route,
      int n, double fromT, double toT, int nowUs, int car) {
    if (_spawnsLeft <= 0 || table.liveCount >= carCap) return SlotPool.none;
    final lg = table.graph;
    final lane = route[0];
    final e = lg.laneEdge[lane];
    // Its own car, if it has one still standing: its kind and its variant are
    // the CAR's, never a fresh draw, because the thing that drives away is
    // the thing that was drawn parked there a moment ago (D42).
    final parked = cars;
    final i = car >= 0 && parked != null && parked.isLive(car)
        ? SlotPool.slotOf(car)
        : -1;
    final k = i >= 0 ? parked!.kind[i] : kind;
    final ak = AgentKind.values[k];
    // A car on a lot stall leaves through its site, by the out-join its route
    // starts at (§7.4 departure step 2). With no such join — a stale plan, a
    // route that starts somewhere else — it leaves from the access point, as
    // a garaged car does.
    var row = -1, stall = -1, join = -1;
    if (i >= 0 &&
        stalls != null &&
        parked!.where[i] == CarWhere.lot.index &&
        _canLeaveStall(parked.row[i], parked.stall[i])) {
      join = _outJoinOf(parked.row[i], e, fromT);
      if (join >= 0) {
        row = parked.row[i];
        stall = parked.stall[i];
      }
    }
    var at = fromT - lg.edgeLaneS0[e];
    final laneLen = lg.laneLength(lane);
    if (at < 0) at = 0;
    if (at > laneLen) at = laneLen;
    // Only a car that starts ON the road asks for its gap here: one leaving a
    // stall crosses the kerb under the site mover's own rules — the throat's
    // `canJoin`, or the home back-out's gap acceptance (§7.4).
    if (row < 0 &&
        !arbiter.canJoin(lane, at, VehicleKinds.lengthM[k], ak,
            fromLeft: left)) {
      return SlotPool.none;
    }
    // Both draws happen either way, so the spawn stream does not depend on
    // whether a trip found a car (§17.4).
    final f = VehicleKinds.drawFactor(ak, rng);
    final drawn = rng.nextU32() & 0xFF;
    final variant = i >= 0 ? parked!.variant[i] : drawn;
    final ff = freeFlowSeconds(lg, route, n, fromT, toT, f);
    final h = row >= 0
        ? stalls!.spawnFromStall(
            row: row,
            stall: stall,
            join: join,
            kind: ak,
            variant: variant,
            ownerKind: parked!.ownerKind[i],
            owner: owner,
            route: route,
            n: n,
            originT: fromT,
            destT: toT,
            nowUs: nowUs,
            speedFactor: f,
            freeFlowS: ff)
        : table.spawn(
            kind: ak,
            route: route,
            routeLength: n,
            originT: fromT,
            destT: toT,
            nowUs: nowUs,
            purpose: TripPurpose.values[purpose],
            variant: variant,
            owner: owner,
            speedFactor: f,
            freeFlowS: ff,
          );
    if (h == SlotPool.none) return h;
    _spawnsLeft--;
    stats.spawned++;
    final sl = SlotPool.slotOf(h);
    // `spawnDetached` knows nothing of purposes: a leg home that starts in a
    // stall is still a leg home.
    if (row >= 0) table.purpose[sl] = purpose;
    if (i >= 0) _leaveParking(parked!, car, i, fromStall: row >= 0);
    if (originT.length < table.capacity) {
      originT = Float32List(table.capacity)..setRange(0, originT.length, originT);
    }
    originT[sl] = fromT;
    return h;
  }

  /// Whether the site mover could take a car off [stall] of [row] at all:
  /// the row and stall still stand, and the stall has a lane to pull out
  /// onto — unless it is a home `inline` stall, which is left by reversing
  /// down the drive and needs none (§7.4 Home back-out).
  ///
  /// Asked BEFORE the spawn because a departure the site can never make
  /// would otherwise sit in the pull-out queue for the rest of the colony's
  /// life, holding a car nobody can drive. Where it cannot, the car leaves
  /// from the access point instead, as a garaged car does.
  bool _canLeaveStall(int row, int stall) {
    final s = sites;
    if (s == null || !s.isRowLive(row)) return false;
    final p = s.plan[row];
    if (p == null || stall < 0 || stall >= s.stallCount[row]) return false;
    if (p.program == SiteProgram.homeDriveway &&
        p.stallAngle(stall) == StallAngle.inline) {
      return true;
    }
    return s.laneOfTarget(row, s.stallTarget(row, stall)) >= 0;
  }

  /// The plan-local out-join of site [row] whose `(edge, T)` is the route
  /// origin [t] on [edge], or −1: which driveway this departure leaves by
  /// (§7.4 departure step 2, V4).
  int _outJoinOf(int row, int edge, double t) {
    final s = sites;
    if (s == null || !s.isRowLive(row)) return -1;
    final p = s.plan[row];
    if (p == null) return -1;
    final lg = table.graph;
    final g = lg.graph;
    var best = -1;
    var bestM = kDepartJoinM;
    for (var j = 0; j < p.joinCount; j++) {
      if (s.joinTarget(row, j) < 0) continue;
      final piece = p.joinPiece(j);
      if (piece < 0 || piece >= g.pieceCount) continue;
      if (g.pieceFwdEdge[piece] != edge && g.pieceBwdEdge[piece] != edge) {
        continue;
      }
      final d = (lg.travelArc(edge, p.joinRoadS(j)) - t).abs();
      if (d > bestM) continue;
      best = j;
      bestM = d;
    }
    return best;
  }

  /// The car [car] has become a vehicle: its row goes, and whatever it held
  /// goes with it — except the STALL it is still standing on, which the site
  /// mover releases when the car's rear clears the mouth line (§7.4
  /// departure step 3), and which would otherwise be handed to an arrival
  /// driving into the car reversing out of it.
  void _leaveParking(ParkedCarTable parked, int car, int i,
      {required bool fromStall}) {
    if (!fromStall && parked.where[i] == CarWhere.kerb.index) {
      final slot = parked.slot[i];
      if (slot >= 0) kerbs?.release(slot);
    }
    parked.remove(car);
  }

  void _move(int i, int w) {
    _owner[w] = _owner[i];
    _off[w] = _off[i];
    _len[w] = _len[i];
    _kind[w] = _kind[i];
    _purpose[w] = _purpose[i];
    _left[w] = _left[i];
    _fromT[w] = _fromT[i];
    _toT[w] = _toT[i];
    _carOf[w] = _carOf[i];
  }

  void _growWaiting() {
    final n = _owner.length * 2;
    _owner = Int32List(n)..setRange(0, _waiting, _owner);
    _off = Int32List(n)..setRange(0, _waiting, _off);
    _len = Int32List(n)..setRange(0, _waiting, _len);
    _kind = Uint8List(n)..setRange(0, _waiting, _kind);
    _purpose = Uint8List(n)..setRange(0, _waiting, _purpose);
    _left = Uint8List(n)..setRange(0, _waiting, _left);
    _fromT = Float64List(n)..setRange(0, _waiting, _fromT);
    _toT = Float64List(n)..setRange(0, _waiting, _toT);
    _carOf = Int32List(n)
      ..fillRange(0, n, -1)
      ..setRange(0, _waiting, _carOf);
  }
}

// ---- CommuteSynth -------------------------------------------------------------

/// A commuter's leg: out to work, or back home.
const int _toWork = 0;
const int _toHome = 1;

/// Where a commuter's current leg stands.
const int _stagePlanning = 0; // a path request is queued or searching
const int _stageWaiting = 1; // planned, waiting to pull out
const int _stageDriving = 2; // on the road
const int _stageAtWork = 3; // dwelling at work until [CommuteSynth.wakeUs]

/// Slice 1's synthetic demand (§6.7). See the library comment.
///
/// A commuter is a row: home and job (building handles), the leg it is on,
/// how far that leg has got, its vehicle while it drives, and when it
/// leaves work. A trip forced by a debug hook is a commuter that goes one
/// way and stops ([oneWay]).
class CommuteSynth implements SpawnSink {
  CommuteSynth({
    required this.buildings,
    required this.planner,
    required this.queue,
    required this.table,
    required this.stats,
    required this.rng,
    int capacity = 8192,
  })  : pool = SlotPool(capacity),
        home = Int32List(capacity),
        job = Int32List(capacity),
        vehicle = Int32List(capacity),
        leg = Uint8List(capacity),
        stage = Uint8List(capacity),
        oneWay = Uint8List(capacity),
        kind = Uint8List(capacity),
        purpose = Uint8List(capacity),
        wakeUs = Float64List(capacity),
        car = Int32List(capacity)..fillRange(0, capacity, -1);

  final BuildingTable buildings;
  final TripPlanner planner;
  final PathQueue queue;
  final VehicleTable table;
  final TrafficStats stats;

  /// The demand's draws — destinations, dwells — on a stream of their own.
  final TrafficRng rng;

  /// Commuters. A full pool defers new commutes like any other cap.
  final SlotPool pool;

  /// Building handles: where the commuter lives and works (or, for a forced
  /// trip, where it starts and where it stops).
  final Int32List home, job;

  /// The vehicle driving the current leg, or −1.
  final Int32List vehicle;

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

  /// Agent µs at which a commuter at work sets off home.
  final Float64List wakeUs;

  /// Agent time of the sub-step running now, set by the owner.
  int nowUs = 0;

  /// Commutes the demand has sent since the colony started (forced trips
  /// not counted).
  int sent = 0;

  int get liveCount => pool.liveCount;

  /// Commuters at work now, waiting for the end of their day.
  int get atWork {
    var n = 0;
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (pool.isSlotLive(sl) && stage[sl] == _stageAtWork) n++;
    }
    return n;
  }

  /// The building [commuter]'s current leg is heading for, or −1.
  int destOf(int commuter) {
    if (!pool.isLive(commuter)) return -1;
    final sl = SlotPool.slotOf(commuter);
    return leg[sl] == _toWork ? job[sl] : home[sl];
  }

  /// The building the leg vehicle [vehicleHandle] drives is heading for, or
  /// −1 for a vehicle no commuter's leg is driving.
  int destOfVehicle(int vehicleHandle) {
    final ch = _commuterOf(vehicleHandle);
    return ch < 0 ? -1 : destOf(ch);
  }

  /// The building [commuter]'s current leg set off from, or −1.
  int originOf(int commuter) {
    if (!pool.isLive(commuter)) return -1;
    final sl = SlotPool.slotOf(commuter);
    return leg[sl] == _toWork ? home[sl] : job[sl];
  }

  /// The vehicle of [commuter], or −1.
  int vehicleOf(int commuter) =>
      pool.isLive(commuter) ? vehicle[SlotPool.slotOf(commuter)] : -1;

  /// Whether [commuter] names a live row.
  bool isLive(int commuter) => pool.isLive(commuter);

  /// The parked car [commuter]'s current leg departs from, or −1.
  int carOf(int commuter) =>
      pool.isLive(commuter) ? car[SlotPool.slotOf(commuter)] : -1;

  /// The building [commuter] lives at (a forced trip: where it started), or
  /// −1: the opaque owner a car parked at work carries (§0 Q3).
  int homeOf(int commuter) =>
      pool.isLive(commuter) ? home[SlotPool.slotOf(commuter)] : -1;

  /// Gives [commuter] the car it has just parked, so its next leg departs
  /// from there (§7.4 Departure step 1).
  void setCar(int commuter, int car) {
    if (!pool.isLive(commuter)) return;
    this.car[SlotPool.slotOf(commuter)] = car;
  }

  /// A commuter restored at work with its car [car] parked there, on its way
  /// home within the return window (§0 Q3, §14.1): what a load makes of a
  /// `commuter`-owned car, since agents in flight are never saved (§14.3).
  /// Returns its handle, or `SlotPool.none` when the pool is full.
  int restoreAtWork(int home, int job, int car) {
    final h = pool.alloc();
    if (h == SlotPool.none) return h;
    final sl = SlotPool.slotOf(h);
    this.home[sl] = home;
    this.job[sl] = job;
    vehicle[sl] = -1;
    this.car[sl] = car;
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
  /// the commuter's handle, or `SlotPool.none` when a cap deferred it.
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

  /// Sends the commutes owed this second, and brings home whoever's day at
  /// work is over. Every building and commuter in slot order, so two runs
  /// ask for the same trips in the same order.
  void wake(int nowUs) {
    this.nowUs = nowUs;
    _emit();
    _returns(nowUs);
  }

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
      int car = -1}) {
    final h = pool.alloc();
    if (h == SlotPool.none) return h;
    final sl = SlotPool.slotOf(h);
    home[sl] = from;
    job[sl] = to;
    vehicle[sl] = -1;
    this.car[sl] = car;
    leg[sl] = _toWork;
    this.oneWay[sl] = oneWay ? 1 : 0;
    this.kind[sl] = kind.index;
    this.purpose[sl] = purpose.index;
    wakeUs[sl] = 0;
    return _request(h) ? h : SlotPool.none;
  }

  /// Asks for the path of [commuter]'s current leg, under [tag]. False, and
  /// the leg deferred, when the queue refused it.
  ///
  /// An outbound leg takes a car out of its home's pool here rather than at
  /// the spawn (§0 Q3): the car is promised to this trip from the moment it
  /// is asked for, so two commuters leaving one house in the same second
  /// never claim the same car — and the car keeps standing on its stall,
  /// where it still blocks whatever is behind it on a tandem pad.
  bool _request(int commuter, {int tag = kTripTag}) {
    final sl = SlotPool.slotOf(commuter);
    final out = leg[sl] == _toWork;
    stage[sl] = _stagePlanning;
    if (out && car[sl] < 0) {
      final parked = cars;
      if (parked != null && home[sl] >= 0) {
        car[sl] = parked.takePooled(SlotPool.slotOf(home[sl]));
      }
    }
    final ok = queue.enqueue(PathPriority.car,
        requester: commuter,
        kind: AgentKind.values[kind[sl]],
        origin: out ? home[sl] : job[sl],
        dest: out ? job[sl] : home[sl],
        tag: tag);
    if (ok) return true;
    stats.deferred++;
    if (out) {
      _dropCar(sl);
      pool.free(commuter);
    } else {
      // Still at work: it tries again next second.
      stage[sl] = _stageAtWork;
      leg[sl] = _toWork;
      wakeUs[sl] = nowUs.toDouble();
    }
    return false;
  }

  /// The trip that took [sl]'s car never ran: the car goes back in its
  /// pool, where it stood all along.
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

  /// The commuter driving vehicle [vehicleHandle], or −1.
  int _commuterOf(int vehicleHandle) {
    final ch = table.owner[SlotPool.slotOf(vehicleHandle)];
    if (!pool.isLive(ch)) return -1;
    return vehicle[SlotPool.slotOf(ch)] == vehicleHandle ? ch : -1;
  }

  /// [vehicleHandle] reached its stop at [nowUs]. Returns a building to
  /// re-target it to — home, when it drove to work and found the building
  /// gone — which the owner plans as an appended leg; else −1, and the
  /// vehicle leaves the road.
  int arrived(int vehicleHandle, int nowUs) {
    final ch = _commuterOf(vehicleHandle);
    if (ch < 0) return -1;
    final sl = SlotPool.slotOf(ch);
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
      pool.free(ch);
      return -1;
    }
    vehicle[sl] = -1;
    if (out && oneWay[sl] == 0) {
      _clockIn(sl, nowUs);
    } else {
      _dropCar(sl);
      pool.free(ch);
    }
    return -1;
  }

  /// [vehicleHandle] was taken off the road before it arrived: the leg
  /// failed. A commuter lost on the way to work is at work all the same —
  /// the design places a citizen at their destination (§5.6) — and comes
  /// home at the end of the day.
  void despawned(int vehicleHandle, int nowUs) {
    final ch = _commuterOf(vehicleHandle);
    if (ch < 0) return;
    final sl = SlotPool.slotOf(ch);
    stats.tripFailed();
    vehicle[sl] = -1;
    if (leg[sl] == _toWork && oneWay[sl] == 0) {
      _clockIn(sl, nowUs);
    } else {
      _dropCar(sl);
      pool.free(ch);
    }
  }

  /// [vehicleHandle] left the road with nowhere left to go — an appended
  /// leg that found no path: the trip ends there.
  void vanished(int vehicleHandle) {
    final ch = _commuterOf(vehicleHandle);
    if (ch < 0) return;
    stats.noRoute++;
    _dropCar(SlotPool.slotOf(ch));
    pool.free(ch);
  }

  void _clockIn(int sl, int nowUs) {
    stage[sl] = _stageAtWork;
    leg[sl] = _toWork;
    wakeUs[sl] = (nowUs +
            usOf(rng.nextBetween(
                AgentTuning.commuteReturnMinS, AgentTuning.commuteReturnMaxS)))
        .toDouble();
  }

  /// [hash] with every live commuter folded in, in slot order, and the
  /// demand stream's state: for `CityAgents.digest`.
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
