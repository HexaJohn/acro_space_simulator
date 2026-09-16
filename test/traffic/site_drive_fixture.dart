// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Cars driving into and out of synthetic sites, with no `CityAgents` in
/// sight (docs/plans/t4a-implementation.md §3 package C).
///
/// [SiteDrive] is the smallest thing that can exercise the site mover: a
/// [VehicleTable] on a real lane graph, the road mover and arbiter that go
/// with it, a [SiteTable] synced from [SiteWorld]'s synthetic plans, and a
/// [SiteMover] wired between them in exactly the order the facade wires them
/// (`events.beginStep()`, the road mover, the site mover, `sites.endStep()`).
///
/// It IS the facade for the purposes of these tests: it implements the three
/// sinks package E will implement, and does the smallest honest thing for
/// each — D17 step 1 on arrival (reserve a stall, hold at the gate), a
/// parked-car stand-in on a stall, and a tandem shuffle that moves the
/// blocker off its stall as a kerb slot would. What it will NOT do is any of
/// the mover's own work: every rule under test lives in `site_mover.dart`.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_points.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/junction_arbiter.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_stats.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/trip_planner.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'routing_fixture.dart';
import 'site_fixture.dart';

/// One access event as the log recorded it, kept for the whole run because
/// the log itself is emptied every sub-step.
class LoggedAccess {
  LoggedAccess(this.kind, this.handle, this.edge, this.t, this.lane, this.row,
      this.join, this.nowUs);

  final AccessEventKind kind;
  final int handle, edge, lane, row, join, nowUs;
  final double t;

  @override
  String toString() => '${kind.name} h$handle edge $edge T '
      '${t.toStringAsFixed(2)} lane $lane row $row join $join at '
      '${secondsOf(nowUs).toStringAsFixed(1)} s';
}

/// A colony of synthetic sites with cars driving in and out. See the
/// library comment.
class SiteDrive implements SiteSink, VehicleSink, SpawnSink {
  SiteDrive(Map<String, SyntheticTemplate> byLot,
      {CitySim? on, int capacity = 512, bool validate = true})
      : world = SiteWorld(byLot, on: on, validate: validate),
        table = VehicleTable(capacity: capacity),
        cols = SiteVehicles(capacity) {
    arbiter = JunctionArbiter(table);
    mover = VehicleMover(table, arbiter)..bind(world.lg);
    siteMover =
        SiteMover(table, cols, world.sites, arbiter, events, stats)
          ..bind(world.lg);
    mover.obstacles = siteMover;
    cost = RouteCost(world.lg);
    world.sync();
    siteMover.relink();
  }

  final SiteWorld world;
  final VehicleTable table;
  final SiteVehicles cols;
  late final JunctionArbiter arbiter;
  late final VehicleMover mover;
  late final SiteMover siteMover;
  late final RouteCost cost;

  final AccessEventLog events = AccessEventLog(capacity: 512);
  final SiteStats stats = SiteStats();

  LaneGraph get lg => world.lg;

  /// Agent time of the last sub-step run.
  int nowUs = 0;

  // ---- What the sinks were told -------------------------------------------

  /// Every access event of the run, in order.
  final List<LoggedAccess> log = [];

  /// Handles parked on a stall (`handle → stall`, −1 for garaged), handles
  /// that gave their stall up at the gate, and handles that reached the road.
  final Map<int, int> parked = {};
  final Map<int, int> parkedRow = {};
  final List<int> gaveUp = [];
  final List<int> leftSite = [];

  /// The road lane each gave-up car was still held in when the gate let it
  /// go, or −1 if it was no longer on the road at all.
  final Map<int, int> gaveUpOn = {};

  /// Why each car left the world, so a test can tell an ending the site
  /// rules chose from §5.6's despawn, which is a trip LOST.
  final Map<int, DespawnReason> despawns = {};

  /// Arrivals whose lot was full when they got there (D17 step 2 is D's).
  final List<int> lotFull = [];

  /// Stalls the shuffle moved a parked car off, as `(row, stall)`.
  final List<(int, int)> shuffled = [];

  /// A stand-in for `ParkedCarTable`: a car id per parked car, so the stall
  /// columns hold something a test can see.
  int _nextCar = 1;

  /// Per vehicle handle, where it is bound: the site row and the in-join it
  /// was planned to, so [arrived] can run D17 step 1.
  final Map<int, int> _boundRow = {};
  final Map<int, int> _boundJoin = {};

  // ---- The sub-step --------------------------------------------------------

  /// Called between the road mover and the site mover, which is exactly
  /// where the site mover makes its decisions: a test that wants to ask the
  /// arbiter the same question the gate or the throat asks must ask it here
  /// and nowhere else, or it reads the road as it was a sub-step ago.
  void Function()? probe;

  /// One sub-step, wired as `CityAgents._subStep` wires it (§2).
  void step() {
    nowUs += kStepUs;
    events.beginStep();
    mover.step(nowUs, this);
    probe?.call();
    siteMover.step(nowUs, this, this, this);
    for (var i = 0; i < events.count; i++) {
      log.add(LoggedAccess(
          AccessEventKind.values[events.kind[i]],
          events.handle[i],
          events.edge[i],
          events.t[i],
          events.lane[i],
          events.row[i],
          events.join[i],
          nowUs));
    }
    world.sites.endStep();
  }

  /// [seconds] of sub-steps, calling [each] after every one.
  void run(double seconds, [void Function()? each]) {
    final n = (seconds / kStepS).round();
    for (var i = 0; i < n; i++) {
      step();
      each?.call();
    }
  }

  // ---- Planning trips ------------------------------------------------------

  /// The access point of join [j] of [lotId]'s plan.
  AccessPoint access(String lotId, [int j = 0]) {
    final p = world.planOf(lotId);
    final a = AccessPoints.ofPlanJoin(lg, p, j);
    if (a == null) throw StateError('$lotId join $j resolves to no road');
    return a;
  }

  /// The plan of [lotId].
  SiteAccessPlan planOf(String lotId) => world.planOf(lotId);

  /// The site row of [lotId].
  int rowOf(String lotId) => world.rowOf(lotId);

  /// A car arriving at join [j] of [lotId] along [edge], starting [backM]
  /// travel metres upstream of the join. Returns its handle, or
  /// [SlotPool.none] when there was no room to pull out or no route.
  int arrival(String lotId,
      {int j = 0,
      required int edge,
      double backM = 150,
      AgentKind kind = AgentKind.car}) {
    final a = access(lotId, j);
    final destT = a.sOn(lg, edge);
    var fromT = destT - backM;
    final lo = lg.edgeLaneS0[edge] + 1.0;
    if (fromT < lo) fromT = lo;
    final h = roadTrip(edge, fromT, edge, destT,
        kind: kind, destMask: 1 << a.destLane(lg, edge));
    if (h == SlotPool.none) return h;
    _boundRow[h] = rowOf(lotId);
    _boundJoin[h] = j;
    return h;
  }

  /// A car that starts parked on [stall] of [lotId] and leaves by join [j],
  /// its road route running [toM] travel metres downstream along [edge].
  int departure(String lotId,
      {int j = 0,
      required int stall,
      required int edge,
      double toM = 150,
      AgentKind kind = AgentKind.car}) {
    final row = rowOf(lotId);
    final a = access(lotId, j);
    final originT = a.sOn(lg, edge);
    var toT = originT + toM;
    final hi = lg.edgeLaneS1[edge] - 1.0;
    if (toT > hi) toT = hi;
    final planned = planTrip(lg, edge, originT, edge, toT,
        cost: cost, load: table);
    if (planned == null) return SlotPool.none;
    final route = Int32List.fromList(planned.route);
    return siteMover.spawnFromStall(
      row: row,
      stall: stall,
      join: j,
      kind: kind,
      variant: 0,
      ownerKind: 0,
      owner: -1,
      route: route,
      n: route.length,
      originT: originT,
      destT: toT,
      nowUs: nowUs,
      speedFactor: 1.0,
      freeFlowS: 0,
    );
  }

  /// A plain road trip, planned the way the queue plans one.
  int roadTrip(int fromEdge, double fromT, int toEdge, double toT,
      {AgentKind kind = AgentKind.car,
      int destMask = kAllLanes,
      double speed = 0,
      bool checkRoom = true}) {
    final planned = planTrip(lg, fromEdge, fromT, toEdge, toT,
        destMask: destMask, cost: cost, load: table);
    if (planned == null) return SlotPool.none;
    final route = Int32List.fromList(planned.route);
    final lane = route[0];
    final at = fromT - lg.edgeLaneS0[lg.laneEdge[lane]];
    if (checkRoom &&
        !arbiter.canJoin(lane, at, VehicleKinds.lengthM[kind.index], kind)) {
      return SlotPool.none;
    }
    return table.spawn(
      kind: kind,
      route: route,
      routeLength: route.length,
      originT: fromT,
      destT: toT,
      nowUs: nowUs,
      speed: speed,
    );
  }

  /// A car standing in the street at travel arc [t] of [edge] and never
  /// moving again: a van at the kerb, a breakdown, a jam that will not clear
  /// — the permanent obstruction a gap rule can never see past. It is a
  /// `dwelling` vehicle, which the road mover holds where it stands and
  /// accrues no stuck time for (§5.6), so it is a body in the lane for as
  /// long as the test wants one. Returns its handle.
  int obstruct(int edge, double t) {
    final hi = lg.edgeLaneS1[edge] - 1.0;
    var to = t + 10;
    if (to > hi) to = hi;
    final h = roadTrip(edge, t, edge, to);
    if (h == SlotPool.none) return h;
    table.state[SlotPool.slotOf(h)] = VehicleState.dwelling.index;
    return h;
  }

  /// Takes [handle] out of the street again: the obstruction clears.
  void clear(int handle) => mover.despawn(handle, DespawnReason.edit, this);

  /// A stream of cars down [edge], one every [everyS] seconds while the run
  /// lasts: what a back-out or a left-in has to find a gap in. Call it from
  /// a `run`'s callback.
  void stream(int edge, {double everyS = 4, double speed = 8}) {
    if (nowUs % usOf(everyS) >= kStepUs) return;
    final t0 = lg.edgeLaneS0[edge] + 2.0;
    final t1 = lg.edgeLaneS1[edge] - 2.0;
    if (t1 <= t0) return;
    roadTrip(edge, t0, edge, t1, speed: speed);
  }

  // ---- The parked cars a site holds ----------------------------------------

  /// Parks a car on [stall] of [lotId] without any trip at all: what a save
  /// restores, and what a departure test starts from.
  int park(String lotId, int stall) {
    final row = rowOf(lotId);
    final car = _nextCar++;
    world.sites.occupy(row, stall, car);
    return car;
  }

  /// Whether [stall] of [lotId] holds a car or a reservation.
  bool taken(String lotId, int stall) =>
      world.sites.stallTaken(rowOf(lotId), stall);

  /// The events of [kind] logged so far.
  List<LoggedAccess> of(AccessEventKind kind) =>
      [for (final e in log) if (e.kind == kind) e];

  // ---- SiteSink ------------------------------------------------------------

  @override
  void parkedInStall(int handle, int row, int stall) {
    parked[handle] = stall;
    parkedRow[handle] = row;
    if (stall >= 0) {
      world.sites.occupy(row, stall, _nextCar++);
      stats.parkedLot++;
    } else {
      stats.garaged++;
    }
    table.free(handle);
    final sl = SlotPool.slotOf(handle);
    cols.clear(sl);
  }

  @override
  void gateGaveUp(int handle) {
    gaveUp.add(handle);
    // Where it stood when the gate let it go. D17 step 2 reserves a kerb
    // slot AHEAD on this very lane (§7.3 step 2), so a car handed over with
    // no lane under it has nowhere to go but a garage: what the mover owes
    // step 2 is a live car still on its arrival lane.
    gaveUpOn[handle] =
        table.isLive(handle) ? table.elem[SlotPool.slotOf(handle)] : -1;
    // D17 step 2 itself is package D's: here the car simply leaves the world.
    mover.despawn(handle, DespawnReason.edit, this);
  }

  @override
  void exited(int handle) => leftSite.add(handle);

  @override
  bool shuffleBlocker(int handle, int row, int blocker) {
    // The kerb slots are package D's; a shuffle here just takes the blocker
    // off its stall, which is what a relocation leaves behind.
    if (world.sites.stallCar[world.sites.stallBase[row] + blocker] < 0) {
      return false;
    }
    world.sites.vacate(row, blocker);
    shuffled.add((row, blocker));
    return true;
  }

  // ---- VehicleSink ---------------------------------------------------------

  /// Agent time each car was handed to the gate, so a test can measure how
  /// long it was refused.
  final Map<int, int> heldSince = {};

  @override
  void arrived(int handle) {
    final row = _boundRow[handle];
    final join = _boundJoin[handle];
    if (row == null || join == null) return;
    heldSince[handle] = nowUs;
    // D17 step 1 (§7.5): the destination's own stalls, reserved bindingly,
    // and the car held at the gate.
    final stall = world.sites.firstFreeStall(row, join);
    if (stall < 0) {
      lotFull.add(handle);
      return;
    }
    final sl = SlotPool.slotOf(handle);
    world.sites.reserve(row, stall, handle);
    table.state[sl] = VehicleState.parkingSearch.index;
    siteMover.holdAtGate(handle, row, join, stall);
  }

  @override
  void despawned(int handle, DespawnReason reason) => despawns[handle] = reason;

  // ---- SpawnSink -----------------------------------------------------------

  @override
  void spawned(int owner, int handle) {}

  /// Owners the mover handed their leg back to: a route it could not carry
  /// (§7.6), a home departure it gave up on (§7.5). Planning them again is
  /// package E's, so here they are only recorded.
  final List<int> replanned = [];

  @override
  void replanWaiting(int owner) => replanned.add(owner);
}

/// The starter lot each template stands on, with its serving edges: what a
/// site test names its roads by.
({int near, int far}) servingEdges(SiteDrive d, String lotId, [int j = 0]) {
  final a = d.access(lotId, j);
  // The NEAR edge is the one with the lot on its right (§7.4 target lane).
  final fwd = a.fwdEdge, bwd = a.bwdEdge;
  if (fwd >= 0 && a.rightOfTravel(d.lg, fwd)) return (near: fwd, far: bwd);
  if (bwd >= 0 && a.rightOfTravel(d.lg, bwd)) return (near: bwd, far: fwd);
  return (near: fwd >= 0 ? fwd : bwd, far: -1);
}

/// Where a vehicle's body lies on road lane [lane]: `[rear, front]` lane
/// metres, or null when it is not on that lane.
(double, double)? bodyOn(SiteDrive d, int handle, int lane) {
  if (!d.table.isLive(handle)) return null;
  final sl = SlotPool.slotOf(handle);
  if (d.table.elem[sl] != lane) return null;
  final s = d.table.s[sl].toDouble();
  return (s - d.table.len[sl], s);
}

/// Whatever is wrong with the SITE lists: a car listed where it is not, out
/// of order, or overlapping the one ahead of it on the same site lane. The
/// road half of this is `occupancyErrors` in `movement_fixture.dart`.
List<String> siteOccupancyErrors(SiteDrive d) {
  final errs = <String>[];
  final s = d.world.sites;
  final seen = <int>{};
  for (var el = 0; el < s.elemHead.length; el++) {
    var n = 0;
    var prev = -1;
    for (var sl = s.elemHead[el]; sl >= 0; sl = d.cols.sNext[sl]) {
      if (!d.table.isSlotLive(sl)) errs.add('dead slot $sl on site $el');
      final row = s.elemRow[el];
      if (d.cols.row[sl] != row) {
        errs.add('slot $sl listed on row $row, is on ${d.cols.row[sl]}');
      }
      if (d.cols.sPrev[sl] != prev) {
        errs.add('slot $sl: prev ${d.cols.sPrev[sl]}, not $prev');
      }
      if (prev >= 0) {
        if (d.table.s[sl] > d.table.s[prev]) {
          errs.add('site element $el out of order at $sl');
        }
        final gap = d.table.s[prev] - d.table.len[prev] - d.table.s[sl];
        if (gap < -1e-3) {
          errs.add('slot $sl overlaps $prev on site $el by ${-gap} m');
        }
      }
      if (!seen.add(sl)) {
        errs.add('slot $sl listed twice');
        break;
      }
      prev = sl;
      n++;
    }
    if (s.elemTail[el] != prev) {
      errs.add('site element $el: tail ${s.elemTail[el]}, not $prev');
    }
    if (s.elemCount[el] != n) {
      errs.add('site element $el: count ${s.elemCount[el]}, not $n');
    }
  }
  return errs;
}

/// Whatever is wrong with the `sharedSingle` claim units: a unit claimed by
/// nobody, held by both directions at once, or a direction with no claimer
/// (§7.4).
List<String> claimErrors(SiteDrive d) {
  final errs = <String>[];
  final s = d.world.sites;
  for (var r = 0; r < s.highWater; r++) {
    if (!s.isRowLive(r)) continue;
    for (var u = 0; u < s.unitCount[r]; u++) {
      final i = s.unitBase[r] + u;
      final h = s.unitClaimH[i], dir = s.unitClaimDir[i], n = s.unitClaimers[i];
      if (h < 0) {
        if (n != 0 || dir != 0) errs.add('unit $i free but dir $dir, $n held');
        continue;
      }
      if (dir != kUnitIn && dir != kUnitOut) {
        errs.add('unit $i held in direction $dir');
      }
      if (n <= 0) errs.add('unit $i claimed by $h with $n claimers');
    }
  }
  return errs;
}

/// Every vehicle whose body overlaps `[fromS, toS]` of road [lane].
List<int> bodiesIn(SiteDrive d, int lane, double fromS, double toS) {
  final out = <int>[];
  for (var sl = d.table.elemHead[lane]; sl >= 0; sl = d.table.next[sl]) {
    final s = d.table.s[sl].toDouble();
    if (s - d.table.len[sl] > toS || s < fromS) continue;
    out.add(d.table.handleOf(sl));
  }
  return out;
}

/// The starter lot [t] stands on, by id: what a test names its site by.
String starterLotOf(SyntheticTemplate t) => lotOf(t);
