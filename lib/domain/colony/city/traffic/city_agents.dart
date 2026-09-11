// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's agents: the one facade the rest of the game talks to
/// (docs/plans/agent-traffic.md §0.1, §12.2, §5.7, §14).
///
/// `CitySim` owns one, as `CitySim.agents` (E2), and calls into it from
/// guarded one-line hooks: [advance] right after the routed model advances
/// (E3a), [holdTick] first thing in its own advance (E3b), [onLotsRenamed]
/// and [onLotCleared] from its rename and clear seams (E12–E14), [toJson]
/// and [restore] from its save (E15, E16); and everything that reads the
/// traffic reads [readout] through `CitySim.trafficReadout` (E37). Nothing
/// else in the colony changes.
///
/// One [advance] (§12.2, slice 1):
///
/// 1. Poll the network: if the road graph moved, refresh the node controls
///    (a junction override) or rebuild the lane graph and carry every live
///    route across by lineage — straight through a new junction, re-planned
///    only where the edit made the route impossible (§3.8, §3.9).
/// 2. Sync the building table when the plat, the buildings or the graph
///    moved (and every `buildingSyncS` of agent time).
/// 3. Run the sub-steps the tick's time pays for, each in the fixed order
///    of §5.2: demand on the whole second, the spawn queue, the path pump,
///    the vehicles, the congestion epoch, the frame.
///
/// Everything a result depends on is counted — sub-steps, expansions,
/// spawns — never timed, and runs in integer-id order, so two colonies fed
/// the same ticks make the same history ([digest]). The frame hold changes
/// only WHEN a tick runs, never what it computes (§5.7, D35).
///
/// The constructor allocates nothing: the tables are built the first time
/// an enabled colony advances, and dropped when it is disabled.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../city_sim.dart';
import 'agent_frame.dart';
import 'agent_kind.dart';
import 'agent_traffic_readout.dart';
import 'agents_codec.dart';
import 'building_table.dart';
import 'graph_lineage.dart';
import 'junction_arbiter.dart';
import 'lane_graph.dart';
import 'lane_graph_builder.dart';
import 'network_key.dart';
import 'path_search.dart';
import 'route_cost.dart';
import 'slot_pool.dart';
import 'traffic_metrics.dart';
import 'traffic_rng.dart';
import 'traffic_stats.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';
import 'trip_planner.dart';
import 'vehicle_mover.dart';
import 'vehicle_table.dart';

/// The `PathRequest.tag` of a vehicle on the road planning again from
/// where it is, after an edit made its route impossible (§3.9).
const int kReplanTag = 1;

/// The tag of an appended leg: a vehicle that arrived at a building gone,
/// re-targeted home from where it stopped (§4.7).
const int kRetargetTag = 2;

/// Salts of the RNG's sub-streams: each subsystem draws from its own, so a
/// draw added to one never shifts another's.
const int _demandSalt = 0x44454D41; // 'DEMA'
const int _spawnSalt = 0x5350574E; // 'SPWN'

/// Items of a large network's lane graph built per advance while the old
/// graph keeps running (§3.8).
const int _buildItemsPerAdvance = 4096;

/// A colony's agents. See the library comment.
class CityAgents {
  CityAgents(this.city);

  /// The colony they belong to.
  final CitySim city;

  bool _enabled = false;
  _Core? _core;
  TrafficStats? _idleStats;
  TrafficMetrics? _metrics;
  int _picturesBefore = 0;

  /// Whether this colony runs agents — and, with it, whether anything
  /// else reads them (E3a, E4, E37). Also off while the `agentsOn` A/B knob
  /// is. Turning it off drops every vehicle and table; turning it on starts
  /// afresh, spawn ramp and all.
  bool get enabled => _enabled && AgentTuning.agentsOn;
  set enabled(bool on) {
    if (on == _enabled) return;
    _enabled = on;
    if (!on) {
      _picturesBefore += _core?.stats.pictures ?? 0;
      _core = null;
    }
  }

  /// Readout pictures taken by this colony's agents, ever: the readout's
  /// `passes`, which must never go back — not even when the agents are
  /// switched off and on again and their tables start afresh.
  int get pictures => _picturesBefore + (_core?.stats.pictures ?? 0);

  /// Whether the colony's save carries an `'agents'` block (E15).
  bool get hasState => _enabled;

  /// Set by a host that caps the agent sub-steps per UI frame (§5.7, E26):
  /// every tick is then queued by [holdTick] and run by [endFrame].
  bool frameBudgeted = false;

  /// The world epoch the host is ticking at, stamped on every frame.
  double worldEpochS = 0;

  /// What [endFrame] replays a held tick through: the colony's own
  /// advance, unless a test stands in for it.
  void Function(double simDt)? replayTick;

  /// The colony's traffic readout (D46): what `CitySim.trafficReadout`
  /// returns when agents are enabled (E37).
  late final AgentTrafficReadout readout =
      AgentTrafficReadout(this, city.roadTraffic);

  /// What the agents measured: `stats.commuteEff` is staffing's (E4).
  TrafficStats get stats => _core?.stats ?? (_idleStats ??= TrafficStats());

  /// Wall-clock timings, for reporting.
  TrafficMetrics get metrics => _metrics ??= TrafficMetrics();

  // ---- What the tests, the wire and the tools read -----------------------------

  /// The agent clock, µs: the time of the last sub-step run.
  int get timeUs => _core?.clock.timeUs ?? 0;

  /// The lane graph the vehicles drive, once built.
  LaneGraph? get laneGraph => _core?.lg;

  /// Bumped whenever the lane graph is rebuilt, and whenever its controls
  /// are refreshed.
  int get graphRev => _core?.graphRev ?? 0;
  int get controlsRev => _core?.controlsRev ?? 0;

  VehicleTable? get vehicles => _core?.table;
  BuildingTable? get buildings => _core?.buildings;
  CommuteSynth? get commutes => _core?.commutes;
  TripPlanner? get planner => _core?.planner;
  PathQueue? get pathQueue => _core?.queue;
  VehicleMover? get mover => _core?.mover;

  /// Vehicles on the road.
  int get liveVehicles => _core?.table.liveCount ?? 0;

  /// The last frame published: new identity every sub-step.
  AgentFrame get frame => _core?.frames.latest ?? AgentFrame.empty;

  /// Where the route of the vehicle in [slot] leaves its first edge, travel
  /// metres.
  double originTOf(int slot) {
    final p = _core?.planner;
    return p == null || slot >= p.originT.length ? 0.0 : p.originT[slot];
  }

  // ---- The tick ----------------------------------------------------------------

  /// Advances the agents by [dt] seconds of colony time — the clamped dt
  /// `CitySim.advance` runs its own tick with (E3a).
  void advance(double dt) {
    if (!enabled) return;
    final m = metrics..beginTick();
    try {
      (_core ??= _Core(this)).advance(dt);
    } finally {
      m.endTick();
    }
  }

  // ---- The frame hold (§5.7, D35) ---------------------------------------------

  Float64List? _held;
  int _heldHead = 0, _heldLen = 0;
  double _heldS = 0;
  bool _replaying = false;

  /// Ticks held, and the colony seconds they carry.
  int get heldTicks => _heldLen;
  double get heldCityS => _heldS;

  /// First thing in `CitySim.advance` (E3b): true when the tick is queued
  /// whole for [endFrame] instead of run now. False — run it — unless the
  /// host set [frameBudgeted], or while [endFrame] itself replays it.
  bool holdTick(double simDt) {
    if (!frameBudgeted || _replaying || !enabled) return false;
    var q = _held ??= Float64List(64);
    if (_heldLen == q.length) {
      final grown = Float64List(q.length * 2);
      for (var i = 0; i < _heldLen; i++) {
        grown[i] = q[(_heldHead + i) % q.length];
      }
      _held = q = grown;
      _heldHead = 0;
    }
    q[(_heldHead + _heldLen) % q.length] = simDt;
    _heldLen++;
    _heldS += simDt;
    return true;
  }

  /// After the host's tick loop (E26): replays the held ticks, oldest
  /// first, while the frame's `maxAgentSubStepsPerFrame` sub-steps last —
  /// each tick priced exactly, from the agent clock's leftover, before it
  /// runs. At least one tick runs, so a tick dearer than the whole budget
  /// is never starved; and a queue past `maxHeldCityS` is drained whole,
  /// a hitch but never a lost tick.
  void endFrame() {
    final q = _held;
    if (q == null || _heldLen == 0) return;
    var budget = AgentTuning.maxAgentSubStepsPerFrame;
    final drainAll = _heldS > AgentTuning.maxHeldCityS;
    var ran = 0;
    _replaying = true;
    try {
      while (_heldLen > 0) {
        final simDt = q[_heldHead];
        final steps = _stepsFor(simDt);
        if (!drainAll && ran > 0 && steps > budget) break;
        _heldHead = (_heldHead + 1) % q.length;
        _heldLen--;
        _heldS = _heldLen == 0 ? 0 : _heldS - simDt;
        budget -= steps;
        ran++;
        final replay = replayTick;
        if (replay != null) {
          replay(simDt);
        } else {
          city.advance(simDt);
        }
      }
    } finally {
      _replaying = false;
    }
  }

  /// The sub-steps the held tick [simDt] will run: its dt as
  /// `CitySim.advance` will clamp it, counted from the clock's leftover.
  int _stepsFor(double simDt) {
    final core = _core;
    if (core == null || !enabled) return 0;
    final dt = (simDt * city.eventSimWarp).clamp(0.0, 0.5);
    return core.clock.stepsOnFeed(dt);
  }

  // ---- The colony's seams (E12–E16) -------------------------------------------

  /// A re-plat renamed lots, old id → new (E12, E13): their buildings, and
  /// every trip to and from them, carry across.
  void onLotsRenamed(Map<String, String> renamed) =>
      _core?.buildings.rename(renamed);

  /// The lot [siteId] was cleared (E14): its building is gone now. Trips on
  /// their way there drive on, and find it gone when they arrive (§4.7).
  void onLotCleared(String siteId) => _core?.buildings.clear(siteId);

  /// The `'agents'` save block (E15): slice 1 keeps only the flag.
  Map<String, Object?> toJson() => AgentsCodec.encode(enabled: _enabled);

  /// Restores the save block [json] (E16), after the colony itself is
  /// restored. No block, or one this build cannot read: agents off.
  void restore(Object? json) {
    enabled = AgentsCodec.enabledOf(json) ?? false;
  }

  // ---- Development hooks ------------------------------------------------------

  /// A car trip from site [fromSite] to [toSite], planned now and driven
  /// once — `ext.acro.citygame`'s `traffic=spawn` (E25) and the scenario
  /// tests' `forceTrip`. Returns its trip's handle; `SlotPool.none` when
  /// agents are off, a site has no building, or a cap deferred it.
  int forceTrip(String fromSite, String toSite,
      {AgentKind kind = AgentKind.car,
      TripPurpose purpose = TripPurpose.commute}) {
    if (!enabled) return SlotPool.none;
    final core = _core ??= _Core(this);
    core.prime();
    final from = core.buildings.handleOfSite(fromSite);
    final to = core.buildings.handleOfSite(toSite);
    if (from == null || to == null || from == to) return SlotPool.none;
    return core.commutes.force(from, to, kind: kind, purpose: purpose);
  }

  /// Stops vehicle [handle] where it stands, for good (§17's `stall`).
  void debugStall(int handle) => _core?.table.stall(handle);

  /// Vehicle [handle] for the inspector and `vehicle=` (§13.9): its kind,
  /// state, owner and purpose, the sites it drives between, its time
  /// against free flow, its stuck timer and its remaining route, lane by
  /// lane. Null for a handle no longer on the road.
  Map<String, Object?>? describe(int handle) => _core?.describe(handle);

  /// A hash of every column the agents' history lives in (§17.4): two
  /// colonies fed the same ticks agree on it to the bit.
  int digest() => _core?.digest() ?? kFnvOffset32;
}

/// Everything an enabled colony's agents hold, built at its first advance.
class _Core implements PathResolver, PathSink, VehicleSink {
  _Core(this.agents)
      : city = agents.city,
        source = CityNetSource(agents.city),
        rng = TrafficRng(fnv1a32(agents.city.id)),
        table = VehicleTable(capacity: AgentTuning.maxVehicles),
        epochUs = usOf(AgentTuning.congestionEpochS),
        windowUs = usOf(AgentTuning.congestionWindowS),
        syncUs = usOf(AgentTuning.buildingSyncS) {
    arbiter = JunctionArbiter(table);
    mover = VehicleMover(table, arbiter);
    queue.load = table;
    planner = TripPlanner(table, arbiter, rng.fork(_spawnSalt), stats);
    commutes = CommuteSynth(
      buildings: buildings,
      planner: planner,
      queue: queue,
      table: table,
      stats: stats,
      rng: rng.fork(_demandSalt),
    );
  }

  final CityAgents agents;
  final CitySim city;
  final CityNetSource source;
  final TrafficRng rng;
  final VehicleTable table;
  final int epochUs, windowUs, syncUs;

  final AgentClock clock = AgentClock();
  final TrafficNetWatch watch = TrafficNetWatch();
  final PathQueue queue = PathQueue();
  final BuildingTable buildings = BuildingTable();
  final TrafficStats stats = TrafficStats();
  final AgentFrameBuilder frames = AgentFrameBuilder();
  late final JunctionArbiter arbiter;
  late final VehicleMover mover;
  late final TripPlanner planner;
  late final CommuteSynth commutes;

  LaneGraph? lg;
  RouteCost? cost;
  LaneGraphBuilder? pending;
  int graphRev = 0, controlsRev = 0;

  // What the building table was last synced against.
  int _syncLayout = -1, _syncPlaced = -1, _syncGrown = -1;
  int _syncUtils = -1, _syncCells = -1;
  LaneGraph? _syncGraph;

  // The remap's scratch, by vehicle slot.
  Uint8List _rmOp = Uint8List(0);
  Int32List _rmElem = Int32List(0);
  Float64List _rmS = Float64List(0);
  final Int32List _one = Int32List(1);

  static const int _opNone = 0, _opPlace = 1, _opHold = 2;

  /// How far short of its lane's end a vehicle on a connector is taken to
  /// be when its route is carried across an edit from the lane it left.
  static const double _laneEndM = 0.01;

  static final int _driving = VehicleState.driving.index;
  static final int _hold = VehicleState.holdAtEdgeEnd.index;
  static final int _dwelling = VehicleState.dwelling.index;

  // ---- The tick ------------------------------------------------------------

  void advance(double dt) {
    prime();
    clock.feed(dt);
    while (clock.takeStep()) {
      _subStep();
    }
  }

  /// The network and the buildings brought up to the colony as it stands.
  void prime() {
    _poll();
    if (_buildingsMoved()) _syncBuildings();
  }

  /// One sub-step, in §5.2's order.
  void _subStep() {
    final now = clock.timeUs;
    commutes.nowUs = now;
    planner.beginStep(now);
    if (now % syncUs == 0) _syncBuildings();
    // 1. Wake: the demand, once per agent second.
    if (clock.onWholeSecond) commutes.wake(now);
    // 2. The spawn queue, then the path pump (whose paths spawn too).
    planner.spawnReady(now, commutes);
    if (pending == null) {
      queue.pump(AgentTuning.pathExpansionsPerStep, this, this);
    }
    // 3–5. The vehicles, their arrivals and despawns.
    mover.step(now, this);
    if (clock.onWholeSecond) table.compactRoutes();
    // 6. The congestion epoch, and the readout's picture.
    if (now % epochUs == 0) {
      stats.epoch(mover, windowEnd: now % windowUs == 0);
    }
    // 7. The frame.
    frames.publish(table,
        timeUs: now, worldEpochS: agents.worldEpochS, graphRev: graphRev);
  }

  // ---- The network (§3.8) -------------------------------------------------------

  void _poll() {
    final g = watch.poll(source);
    final p = pending;
    if (p != null) {
      final b = identical(p.graph, g) ? p : (pending = LaneGraphBuilder(g));
      if (b.step(_buildItemsPerAdvance)) {
        pending = null;
        _swap(b.result, rebuild: true);
      }
      return;
    }
    final built = lg;
    if (built != null && identical(built.graph, g)) return;
    final change = TrafficNetKey(g)
        .since(built == null ? null : TrafficNetKey(built.graph));
    if (change == NetChange.none) return;
    if (built != null && change == NetChange.controls) {
      final refreshed = LaneGraphBuilder.refresh(built, g);
      if (refreshed != null) {
        _swap(refreshed, rebuild: false);
        return;
      }
    }
    if (built != null && g.roadCount > AgentTuning.graphBuildInlineMaxRoads) {
      final b = pending = LaneGraphBuilder(g);
      if (b.step(_buildItemsPerAdvance)) {
        pending = null;
        _swap(b.result, rebuild: true);
      }
      return;
    }
    _swap(LaneGraphBuilder.build(g), rebuild: true);
  }

  /// Puts everything on [next]: a rebuilt graph carries every live route
  /// across by lineage first; a refreshed one keeps every id.
  void _swap(LaneGraph next, {required bool rebuild}) {
    final old = lg;
    if (rebuild && old != null && table.liveCount > 0) {
      _remapAll(old, next);
    } else {
      mover.bind(next);
    }
    lg = next;
    final c = cost = RouteCost(next);
    queue.bind(c);
    stats.bind(next);
    if (rebuild) {
      if (old != null) planner.replanWaiting(commutes);
      graphRev++;
    }
    controlsRev++;
  }

  /// §3.9 for every vehicle: remapped while the table still holds the old
  /// graph, then placed on the new one and relinked.
  void _remapAll(LaneGraph old, LaneGraph next) {
    final t = table;
    final hw = t.highWater;
    if (_rmOp.length < t.capacity) {
      _rmOp = Uint8List(t.capacity);
      _rmElem = Int32List(t.capacity);
      _rmS = Float64List(t.capacity);
    }
    final rm = RouteRemapper(EdgeLineage(old, next));
    final nOld = old.laneCount, nNew = next.laneCount;
    for (var sl = 0; sl < hw; sl++) {
      _rmOp[sl] = _opNone;
      if (!t.isSlotLive(sl)) continue;
      final el = t.elem[sl];
      final off = t.routeOff[sl], len = t.routeLen[sl], cur = t.routeCur[sl];
      final destS = t.destS[sl].toDouble();
      if (el < nOld) {
        final st = rm.remap(t.arena.data, off, len,
            at: cur, s: t.s[sl].toDouble(), destS: destS);
        _settleRemap(sl, rm, st, next);
        continue;
      }
      // On a connector: carried from the end of the lane it left, it keeps
      // its place on the same movement across the node — which, away from
      // the edit, is the same connector under a new number.
      final fromLane = old.conFromLane[el - nOld];
      if (cur >= 1) {
        final st = rm.remap(t.arena.data, off, len,
            at: cur - 1,
            s: math.max(0.0, old.laneLength(fromLane) - _laneEndM),
            destS: destS);
        if (st == RemapStatus.kept && rm.routeLength >= 2) {
          final nc = rm.route[1];
          t.setRoute(sl, rm.route, rm.routeLength,
              destS: rm.stopS, routeCur: 1);
          _rmOp[sl] = _opPlace;
          _rmElem[sl] = nNew + nc;
          final conLen = next.conLen[nc].toDouble();
          _rmS[sl] = math.max(0.0, math.min(t.s[sl].toDouble(), conLen - _laneEndM));
          planner.originT[sl] =
              next.edgeLaneS0[next.laneEdge[rm.lane]] + rm.laneS;
          continue;
        }
      }
      final st = rm.remap(t.arena.data, off, len,
          at: cur, onConnector: true, destS: destS);
      _settleRemap(sl, rm, st, next);
    }
    mover.bind(next);
    for (var sl = 0; sl < hw; sl++) {
      if (_rmOp[sl] == _opNone || !t.isSlotLive(sl)) continue;
      t.place(sl, _rmElem[sl], _rmS[sl]);
      _setV0(sl, next);
    }
    t.relinkAll();
    for (var sl = 0; sl < hw; sl++) {
      if (_rmOp[sl] == _opHold && t.isSlotLive(sl)) {
        stats.replans++;
        _ask(t.handleOf(sl), kReplanTag);
      }
    }
  }

  void _settleRemap(int sl, RouteRemapper rm, RemapStatus st, LaneGraph next) {
    final t = table;
    switch (st) {
      case RemapStatus.kept:
        t.setRoute(sl, rm.route, rm.routeLength, destS: rm.stopS);
        _rmOp[sl] = _opPlace;
        if (rm.lanesRepaired) stats.lanesRepaired++;
      case RemapStatus.replan:
        // It drives on to the end of the edge it is on and holds there,
        // its stuck timer frozen, while a fixed-start plan from its lane is
        // found (§3.9). One already waiting for a plan keeps its request.
        final waiting = t.state[sl] == _hold || t.state[sl] == _dwelling;
        _one[0] = rm.lane;
        t.setRoute(sl, _one, 1,
            destS: next.edgeLaneS1[next.laneEdge[rm.lane]].toDouble());
        if (t.state[sl] == _driving) t.state[sl] = _hold;
        _rmOp[sl] = waiting ? _opPlace : _opHold;
      case RemapStatus.despawn:
        mover.despawn(t.handleOf(sl), DespawnReason.edit, this);
        return;
    }
    _rmElem[sl] = rm.lane;
    _rmS[sl] = rm.laneS;
    planner.originT[sl] = next.edgeLaneS0[next.laneEdge[rm.lane]] + rm.laneS;
  }

  /// The desired speed of the element [sl] was just placed on.
  void _setV0(int sl, LaneGraph g) {
    final t = table;
    final el = t.elem[sl];
    final f = t.f[sl];
    if (el < g.laneCount) {
      t.v0[sl] = g.edgeLimit[g.laneEdge[el]] * f;
      return;
    }
    final c = el - g.laneCount;
    final a = g.edgeLimit[g.conFromEdge(c)], b = g.edgeLimit[g.conToEdge(c)];
    final v = (a < b ? a : b) * f;
    final cap = g.conVmax[c];
    t.v0[sl] = v < cap ? v : cap;
  }

  /// Asks for a fixed-start plan for vehicle [h] from where it is, to where
  /// its trip's leg now heads — its destination for a re-plan, home for an
  /// appended leg (the commuter has turned for home already).
  void _ask(int h, int tag) {
    final sl = SlotPool.slotOf(h);
    final dest = commutes.destOf(table.owner[sl]);
    if (dest < 0) {
      mover.despawn(h, DespawnReason.edit, this);
      return;
    }
    queue.enqueue(PathPriority.replan,
        requester: ~h,
        kind: AgentKind.values[table.kind[sl]],
        fixedStart: true,
        dest: dest,
        tag: tag);
  }

  // ---- Buildings (§2.6) -------------------------------------------------------------

  bool _buildingsMoved() =>
      city.layout.version != _syncLayout ||
      city.parcelBuildings.length != _syncPlaced ||
      city.grownParcels.length != _syncGrown ||
      city.utils.length != _syncUtils ||
      city.grown.length != _syncCells ||
      !identical(lg, _syncGraph);

  void _syncBuildings() {
    buildings.sync(city, lg);
    _syncLayout = city.layout.version;
    _syncPlaced = city.parcelBuildings.length;
    _syncGrown = city.grownParcels.length;
    _syncUtils = city.utils.length;
    _syncCells = city.grown.length;
    _syncGraph = lg;
  }

  // ---- The path queue's ends and results --------------------------------------

  @override
  bool resolve(PathRequest request, PathEnds ends) {
    final g = lg;
    if (g == null) return false;
    if (request.tag == kTripTag) {
      if (!buildings.addOrigins(request.origin, ends)) return false;
    } else {
      // A vehicle on the road: from the lane it is in, where it is now —
      // read at the moment the search starts, so a search restarted after
      // another edit starts from the vehicle's place on that network.
      final h = ~request.requester;
      if (!table.isLive(h)) return false;
      final sl = SlotPool.slotOf(h);
      final el = table.elem[sl];
      if (el < 0 || el >= g.laneCount) return false;
      final e = g.laneEdge[el];
      ends.addOrigin(e, g.edgeLaneS0[e] + table.s[sl], lane: el);
    }
    return buildings.addGoals(request.dest, ends);
  }

  @override
  void onPath(PathRequest request, PathOutcome outcome, PlannedRoute route) {
    if (request.tag == kTripTag) {
      commutes.onPath(request, outcome, route, clock.timeUs);
      return;
    }
    final h = ~request.requester;
    if (!table.isLive(h)) return;
    final sl = SlotPool.slotOf(h);
    final found = outcome == PathOutcome.found && route.length >= 1;
    final el = table.elem[sl];
    if (found && el != route.elems[0] && el < lg!.laneCount) {
      // It is on another lane than the search started from: ask again,
      // from there.
      _ask(h, request.tag);
      return;
    }
    if (found && el == route.elems[0]) {
      // Whatever it held at the line ahead was for the route it drops.
      arbiter.release(sl);
    }
    if (!found ||
        el != route.elems[0] ||
        !table.setRoute(sl, route.elems, route.length, destS: route.destT)) {
      if (request.tag == kRetargetTag) {
        // Nowhere to go from where it stopped: it leaves the road quietly.
        commutes.vanished(h);
        table.state[sl] = VehicleState.leaving.index;
      } else {
        mover.despawn(h, DespawnReason.edit, this);
      }
      return;
    }
    table.state[sl] = _driving;
    table.stuckUs[sl] = 0;
    table.movedM[sl] = 0;
    if (request.tag == kRetargetTag) {
      table.purpose[sl] = TripPurpose.homeward.index;
    }
    planner.originT[sl] = route.originT;
  }

  // ---- The vehicles' events -----------------------------------------------------

  @override
  void arrived(int handle) {
    stats.arrived++;
    final back = commutes.arrived(handle, clock.timeUs);
    if (back < 0) return;
    // An appended leg (§4.6): it waits at its stop, in its lane, while the
    // way on from there is found.
    table.state[SlotPool.slotOf(handle)] = _dwelling;
    stats.appendedLegs++;
    _ask(handle, kRetargetTag);
  }

  @override
  void despawned(int handle, DespawnReason reason) {
    switch (reason) {
      case DespawnReason.stuck:
        stats.despawnStuck++;
      case DespawnReason.wedge:
        stats.despawnWedge++;
      case DespawnReason.edit:
        stats.despawnEdit++;
    }
    queue.cancel(~handle);
    commutes.despawned(handle, clock.timeUs);
  }

  // ---- Inspection ---------------------------------------------------------------------

  Map<String, Object?>? describe(int handle) {
    final t = table, g = lg;
    if (g == null || !t.isLive(handle)) return null;
    final sl = SlotPool.slotOf(handle);
    final owner = t.owner[sl];
    final from = commutes.originOf(owner), to = commutes.destOf(owner);
    final route = <Map<String, Object?>>[];
    for (var i = t.routeCur[sl]; i < t.routeLen[sl]; i++) {
      final lane = t.laneOfRouteEdge(sl, i);
      final e = g.laneEdge[lane];
      route.add({
        'road': g.graph.roads[g.edgeRoad[e]].id,
        'forward': g.edgeForward[e] == 1,
        'lane': g.laneIdx[lane],
        if (i > 0) 'connector': t.connectorOfRouteEdge(sl, i),
      });
    }
    return {
      'handle': handle,
      'kind': AgentKind.values[t.kind[sl]].name,
      'state': VehicleState.values[t.state[sl]].name,
      'purpose': TripPurpose.values[t.purpose[sl]].name,
      'owner': owner,
      'from': from < 0 ? null : buildings.siteOf(from),
      'to': to < 0 ? null : buildings.siteOf(to),
      'tripS': secondsOf(clock.timeUs - t.tripT0Us[sl].toInt()),
      'freeFlowS': t.freeFlowS[sl].toDouble(),
      'stuckS': secondsOf(t.stuckUs[sl]),
      'element': t.elem[sl],
      's': t.s[sl].toDouble(),
      'v': t.v[sl].toDouble(),
      'route': route,
    };
  }

  int digest() {
    final t = table;
    var h = kFnvOffset32;
    h = fnv1aU32(h, clock.timeUs & 0xFFFFFFFF);
    h = fnv1aU32(h, clock.timeUs ~/ 0x100000000);
    h = fnv1aU32(h, clock.accumUs);
    h = fnv1aU32(h, t.highWater);
    final data = t.arena.data;
    for (var sl = 0; sl < t.highWater; sl++) {
      if (!t.isSlotLive(sl)) continue;
      h = fnv1aU32(h, t.handleOf(sl));
      h = fnv1aU32(h, t.kind[sl] | t.state[sl] << 8 | t.purpose[sl] << 16);
      h = fnv1aU32(h, t.variant[sl]);
      h = fnv1aU32(h, t.elem[sl]);
      h = fnv1aU32(h, t.routeCur[sl]);
      h = fnv1aU32(h, t.routeLen[sl]);
      final off = t.routeOff[sl];
      for (var i = 0; i < t.routeLen[sl]; i++) {
        h = fnv1aU32(h, data[off + i]);
      }
      h = fnv1aU32(h, (t.s[sl] * 1000).round());
      h = fnv1aU32(h, (t.v[sl] * 1000).round());
      h = fnv1aU32(h, (t.destS[sl] * 1000).round());
      h = fnv1aU32(h, t.stuckUs[sl]);
      h = fnv1aU32(h, t.waitUs[sl]);
      h = fnv1aU32(h, t.owner[sl]);
    }
    h = commutes.digest(h);
    h = buildings.digest(h);
    final spawn = planner.rng.toJson();
    for (var i = 0; i < spawn.length; i++) {
      h = fnv1aU32(h, spawn[i]);
    }
    h = fnv1aU32(h, stats.spawned);
    h = fnv1aU32(h, stats.arrived);
    h = fnv1aU32(h, stats.arrivedGone);
    h = fnv1aU32(h, stats.despawnStuck);
    h = fnv1aU32(h, stats.despawnWedge);
    h = fnv1aU32(h, stats.despawnEdit);
    h = fnv1aU32(h, stats.replans);
    h = fnv1aU32(h, stats.appendedLegs);
    h = fnv1aU32(h, stats.deferred);
    h = fnv1aU32(h, stats.noRoute);
    h = fnv1aU32(h, stats.pictures);
    h = fnv1aU32(h, (stats.congestionIndex * 1e6).round());
    h = fnv1aU32(h, (stats.tripRatio * 1e6).round());
    h = fnv1aU32(h, queue.length);
    h = fnv1aU32(h, planner.waiting);
    return h;
  }
}
