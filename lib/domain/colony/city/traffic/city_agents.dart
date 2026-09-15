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
/// else in the colony changes. A world host asks [holdTick] too, before its
/// whole share of the tick for the colony, and [endFrame] replays that
/// share through [replayTick], so what the world writes into a held colony
/// keeps its place after the colony's own tick.
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
///    the vehicles, the edge delays — and at the congestion epoch a fresh
///    delay buffer, which every search begun from then on prices by (§4.2,
///    the user's spawn-time congestion) — the readout's picture, a budget of
///    the readout's pass (reach, noise, land value), the frame.
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
import '../parcel.dart';
import 'agent_frame.dart';
import 'agent_kind.dart';
import 'agent_traffic_readout.dart';
import 'agents_codec.dart';
import 'building_table.dart';
import 'edge_delay.dart';
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

/// The tag of an appended leg to the building a vehicle was driving to,
/// still standing, from a stop that is no longer its access (D36's
/// `siteRetarget`): the edit that carried the route re-cut the building's
/// lot, and its access moved on along the kerb or across a new street.
const int kSiteRetargetTag = 3;

/// How far from its building's access, as the table resolves it now, a
/// vehicle may stop and still have arrived there: a join window's reach
/// either side of its join (§5.5), well over the centimetres a split's
/// re-sampling moves a stop by.
const double kSiteRetargetM = 1.5;

/// Salts of the RNG's sub-streams: each subsystem draws from its own, so a
/// draw added to one never shifts another's.
const int _demandSalt = 0x44454D41; // 'DEMA'
const int _spawnSalt = 0x5350574E; // 'SPWN'

/// Items of a large network's lane graph built per advance while the old
/// graph keeps running (§3.8).
const int _buildItemsPerAdvance = 4096;

/// The frame hold works its backlog off at this many frames' pace, on top
/// of its budget (§5.7): slow enough that a catch-up frame stays near the
/// budget, and a host below the frame rate the budget was sized for holds
/// the colony a bounded way behind instead of an ever longer one.
const double _holdDrainFrames = 32;

/// The most sub-steps one held tick runs: `CitySim.advance` clamps a tick
/// to 0.5 s, which from any leftover on the agent clock is two 0.2 s
/// sub-steps or three. A frame of the hold runs its budget and never more
/// than one such tick past it (§5.7, D35), whatever it carried and however
/// long the backlog.
const int _maxTickSteps = 3;

/// A vehicle's own path requests — a re-plan, an appended leg — carry it as
/// `-(handle + 1)`: negative, so never a commuter's handle, and the same
/// number after a trip through the queue's `Int32List` on the web, where
/// `~handle` is not (dart2js reads it unsigned).
int _vehicleRequester(int handle) => -(handle + 1);
int _requesterVehicle(int requester) => -(requester + 1);

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
  int _laneSpeedRevBefore = 0;

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
      // One more, for the lane speeds dropped with the tables.
      _laneSpeedRevBefore += (_core?.delays.laneSpeedRev ?? 0) + 1;
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

  /// What [endFrame] replays a held tick of [city] through: the host's
  /// whole share of the tick for the colony when the world ticks it —
  /// `AdvanceSimulationTick.advanceCity`, which runs what the world writes
  /// into the colony (a shuttle's cargo, its terrain, its air) after its
  /// advance, as inline — else the colony's own advance; or a test's
  /// stand-in.
  void Function(CitySim city, double simDt)? replayTick;

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

  /// The measured delays new trips are priced by (§4.2), once built.
  EdgeDelayTable? get delays => _core?.delays;

  /// What the Lane speed view reads (§13.9): see [AgentLaneSpeeds].
  late final AgentLaneSpeeds laneSpeeds = AgentLaneSpeeds._(this);
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

  /// Each held tick: the simDt the host fed, which is what it is replayed
  /// with, and the colony µs it will run — `CitySim.advance`'s clamp, at
  /// the warp of the moment it was queued — which is what the hold budgets.
  Float64List? _held;
  Int32List? _heldRunUs;
  int _heldHead = 0, _heldLen = 0;
  int _heldCityUs = 0;

  /// Sub-steps of credit the last frame left unspent, while ticks wait.
  double _credit = 0;
  bool _replaying = false;

  /// Ticks held, and the colony seconds they will run.
  int get heldTicks => _heldLen;
  double get heldCityS => secondsOf(_heldCityUs);

  /// Before the host runs its share of a tick for the colony
  /// (`AdvanceSimulationTick`), and first thing in `CitySim.advance` (E3b):
  /// true when the tick is queued whole for [endFrame] instead of run now.
  /// False — run it — unless the host set [frameBudgeted], or while
  /// [endFrame] itself replays it.
  bool holdTick(double simDt) {
    if (!frameBudgeted || _replaying || !enabled) return false;
    var q = _held ??= Float64List(64);
    var run = _heldRunUs ??= Int32List(64);
    if (_heldLen == q.length) {
      final n = q.length * 2;
      final gq = Float64List(n), gr = Int32List(n);
      for (var i = 0; i < _heldLen; i++) {
        final k = (_heldHead + i) % q.length;
        gq[i] = q[k];
        gr[i] = run[k];
      }
      _held = q = gq;
      _heldRunUs = run = gr;
      _heldHead = 0;
    }
    final i = (_heldHead + _heldLen) % q.length;
    final dt = (simDt * city.eventSimWarp).clamp(0.0, 0.5);
    final us = dt > 0 && dt.isFinite ? usOf(dt) : 0;
    q[i] = simDt;
    run[i] = us;
    _heldLen++;
    _heldCityUs += us;
    return true;
  }

  /// After the host's tick loop (E26): replays held ticks, oldest first,
  /// each priced exactly in sub-steps, from the agent clock's leftover,
  /// before it runs, while the frame's credit lasts.
  ///
  /// The credit is `maxAgentSubStepsPerFrame` a frame plus what the last
  /// frame left of it (one budget at most) while ticks wait. Ticks are
  /// whole, so a budget spent a tick at a time must carry its remainder:
  /// kept per frame, two ticks that do not fit together would never run in
  /// one frame, and the hold would fall behind any host feeding more than
  /// a tick a frame. On top of it, a share of the backlog
  /// ([_holdDrainFrames]), so a queue that outgrows the budget — a host
  /// below the frame rate the budget was sized for — is worked off rather
  /// than left to grow. The carry and the share together never take a
  /// frame past its budget by more than one whole tick ([_maxTickSteps]):
  /// that, and not the backlog, is what bounds a catch-up frame, so a
  /// 25-tick hitch at 60 Hz is spread over the frames after it at no more
  /// than seven sub-steps a frame. On top of all that, whatever the queue
  /// holds past `maxHeldCityS`, so the colony is never further behind than
  /// that: a hitch, never a lost tick. At least one tick runs, so a tick
  /// dearer than the whole credit is never starved.
  void endFrame() {
    final q = _held;
    if (q == null || _heldLen == 0) {
      _credit = 0;
      return;
    }
    final budget = AgentTuning.maxAgentSubStepsPerFrame.toDouble();
    final pendingUs = _heldCityUs + (_core?.clock.accumUs ?? 0);
    var credit = math.min(
        math.min(_credit, budget) +
            budget +
            pendingUs / (kStepUs * _holdDrainFrames),
        budget + _maxTickSteps);
    final overUs = _heldCityUs - usOf(AgentTuning.maxHeldCityS);
    if (overUs > 0) credit += overUs / kStepUs;
    var ran = 0;
    _replaying = true;
    try {
      while (_heldLen > 0) {
        final steps = _stepsFor(q[_heldHead]);
        if (ran > 0 && steps > credit) break;
        credit -= steps;
        ran++;
        _replayHead();
      }
    } finally {
      _replaying = false;
    }
    // What is left carries to the next frame while ticks wait; a first
    // tick that overran the credit leaves no debt behind it.
    _credit = _heldLen == 0 || credit < 0 ? 0 : credit;
  }

  /// Replays every held tick now, whatever the budget: before a save — the
  /// save is the colony as of the clock it records, and a load replays
  /// nothing — or when the host that held the ticks lets the colony go.
  void flushHeld() {
    if (_heldLen == 0) return;
    _replaying = true;
    try {
      while (_heldLen > 0) {
        _replayHead();
      }
    } finally {
      _replaying = false;
    }
    _credit = 0;
  }

  /// Takes the oldest held tick off the queue and runs it, as the host
  /// would have (see [replayTick]).
  void _replayHead() {
    final q = _held!;
    final simDt = q[_heldHead];
    _heldCityUs -= _heldRunUs![_heldHead];
    _heldHead = (_heldHead + 1) % q.length;
    _heldLen--;
    final replay = replayTick;
    if (replay != null) {
      replay(city, simDt);
    } else {
      city.advance(simDt);
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

  /// Pins every edge's published delay at 0 from now on (§17's
  /// `freezeDelays`), for a test whose arithmetic assumes a known `D`, and
  /// publishes at once. Measuring goes on underneath; trips already planned
  /// keep their routes.
  void freezeDelays() {
    if (!enabled) return;
    final core = _core ??= _Core(this);
    core.prime();
    core.delays.freeze();
    core.publishDelays();
  }

  /// Pins lane-graph edge [edge]'s published delay at [seconds] (§17's
  /// `setDelay`), freezing the rest, and publishes at once: every search
  /// begun from now on prices it, and none already planned is touched.
  void setDelay(int edge, double seconds) {
    if (!enabled) return;
    final core = _core ??= _Core(this);
    core.prime();
    core.delays.setDelay(edge, seconds);
    core.publishDelays();
  }

  /// Vehicle [handle] for the inspector and `vehicle=` (§13.9): its kind,
  /// state, owner and purpose, the sites it drives between, its time
  /// against free flow, its stuck timer and its remaining route, lane by
  /// lane. Null for a handle no longer on the road.
  Map<String, Object?>? describe(int handle) => _core?.describe(handle);

  /// A hash of every column the agents' history lives in (§17.4) — the
  /// vehicles', the commuters', the buildings', the routes waiting to pull
  /// out, the junction rules' passes and queues, the path queue's requests:
  /// two colonies fed the same ticks agree on it to the bit.
  int digest() => _core?.digest() ?? kFnvOffset32;
}

/// What the Lane speed view reads (§13.9): a small, read-only window on the
/// agents' lane speeds for the road agent's Traffic tool, whose fourth
/// `TrafficInfoView` ('Lane speed') draws them, and which the V key and the
/// Flow chip open (§18 slice 2, agreed with the road side on 2026-09-15).
///
/// A view keys what it drew on [revision] and [graphRev]: when either moves
/// it reads [pct] afresh and rebuilds, at most once an epoch (2 s). Lane ids
/// index [laneGraph], whose lanes [laneLine] draws in colony metres; the
/// wire's `TrafficGeometry` carries the same lanes body-fixed. Nothing here
/// allocates but [laneLine], which a view calls only when it rebuilds.
class AgentLaneSpeeds {
  AgentLaneSpeeds._(this._agents);

  final CityAgents _agents;

  /// Per lane id of [laneGraph]: the lane's speed as a percentage of its
  /// limit, 0–100 — a 60 s EMA of the mean `v / limit` of the vehicles on
  /// it, sampled every sub-step, where a lane nothing stood on samples
  /// free. Null before the first congestion epoch on the lane graph running
  /// now: agents off, no roads yet, or a rebuild less than an epoch ago.
  ///
  /// A new identity every epoch, from a pool of three, so a buffer is not
  /// written again until three epochs (6 s) later: read it when [revision]
  /// moves, and do not keep it longer than that.
  Uint8List? get pct => _agents._core?.delays.laneSpeedPct;

  /// Moves whenever [pct] may have changed — every epoch, a rebuild of the
  /// lane graph, agents switched off or on — and never goes back.
  int get revision =>
      _agents._laneSpeedRevBefore + (_agents._core?.delays.laneSpeedRev ?? 0);

  /// The lane graph [pct] indexes, and its revision: bumped on every
  /// rebuild, when every lane id changes meaning.
  LaneGraph? get laneGraph => _agents.laneGraph;
  int get graphRev => _agents.graphRev;

  /// Lanes of [laneGraph]; 0 with none.
  int get laneCount => laneGraph?.laneCount ?? 0;

  /// The band §13.9 colours a lane of [percent] in: 2 green (70 and up), 1
  /// amber (40 up to 70), 0 red (below 40).
  static int band(int percent) => percent >= 70 ? 2 : (percent >= 40 ? 1 : 0);

  /// The id of the road lane [lane] runs along, or null for no such lane.
  String? roadOfLane(int lane) {
    final lg = laneGraph;
    if (lg == null || lane < 0 || lane >= lg.laneCount) return null;
    final e = lg.laneEdge[lane];
    if (e >= lg.roadEdgeCount) return null;
    return lg.graph.roads[lg.edgeRoad[e]].id;
  }

  /// The centreline of lane [lane] in colony-local metres (east, north),
  /// in travel order from the stop bar behind it to the one ahead: its
  /// road's own line shifted the lane's offset right of travel, a point at
  /// least every [stepM] metres and one at each end. Empty for no such lane.
  List<Vec2> laneLine(int lane, {double stepM = 6}) {
    final lg = laneGraph;
    if (lg == null || lane < 0 || lane >= lg.laneCount) return const [];
    final e = lg.laneEdge[lane];
    if (e >= lg.roadEdgeCount) return const [];
    final t0 = lg.edgeLaneS0[e].toDouble(), t1 = lg.edgeLaneS1[e].toDouble();
    final len = t1 - t0;
    final n = len > 0 && stepM > 0 ? math.max(1, (len / stepM).ceil()) : 1;
    final off = lg.laneOff[lane].toDouble();
    final pt = Float64List(4);
    final out = <Vec2>[];
    for (var i = 0; i <= n; i++) {
      final t = len > 0 ? t0 + len * i / n : t0;
      // The heading from a quarter metre on, or back where that runs off.
      final ahead = t + 0.25 <= lg.edgeLen[e];
      RouteCost.pointOn(lg, e, t, pt, 0);
      RouteCost.pointOn(lg, e, ahead ? t + 0.25 : t - 0.25, pt, 2);
      var de = pt[2] - pt[0], dn = pt[3] - pt[1];
      if (!ahead) {
        de = -de;
        dn = -dn;
      }
      final l = math.sqrt(de * de + dn * dn);
      out.add(l < 1e-9
          ? Vec2(pt[0], pt[1])
          : Vec2(pt[0] + dn / l * off, pt[1] - de / l * off));
    }
    return out;
  }
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
    delays.holders = queue;
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
  final EdgeDelayTable delays = EdgeDelayTable();
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

  // The remap's scratch, by vehicle slot; and a route one connector longer
  // than a remapped one.
  Uint8List _rmOp = Uint8List(0);
  Int32List _rmElem = Int32List(0);
  Float64List _rmS = Float64List(0);
  Int32List _rmRoute = Int32List(64);
  final Int32List _one = Int32List(1);

  static const int _opNone = 0, _opPlace = 1, _opHold = 2;

  /// How far short of its lane's end a vehicle on a connector is taken to
  /// be when its route is carried across an edit from the lane it left.
  static const double _laneEndM = 0.01;

  /// How far outside its new lane a vehicle must stand to be carried onto
  /// the connector through a new junction's box: the remapper's own
  /// "strictly inside" margin, so a vehicle exactly at a lane's end or
  /// start stays on the lane.
  static const double _boxEps = 1e-3;

  /// The least a rebuild leaves between a vehicle's front and the tail of
  /// the one ahead of it on its element: [kStopShortM], the gap a vehicle
  /// comes to rest at before a line.
  static const double _placeClearM = kStopShortM;

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

  /// A delay buffer published now, outside the epoch, and handed to the
  /// path queue for the searches that begin from here on.
  void publishDelays() {
    if (lg == null) return;
    delays.publishNow(table);
    queue.delays = delays.published;
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
    // 6. The edge delays: this sub-step's observations; and at the
    // congestion epoch the flow windows, the lane speeds and a fresh delay
    // buffer, which every search begun from now on prices by (§4.2) — then
    // the readout's picture.
    delays.absorb(mover);
    final picture = now % epochUs == 0;
    if (picture) {
      final windowEnd = now % windowUs == 0;
      delays.epoch(mover, table, windowEnd: windowEnd);
      queue.delays = delays.published;
      stats.epoch(mover, windowEnd: windowEnd);
    }
    // The readout's pass (§12.2 step 7): reach, noise and land value from
    // the pictured loads, a fixed budget of it every sub-step, published at
    // a picture. Here and nowhere else — never pumped by a question, whose
    // timing is the views' — so two colonies fed the same ticks publish the
    // same answers at the same sub-step (§17.4).
    agents.readout.tick(picture: picture);
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

  /// Puts everything on [next]. A rebuilt graph carries every route across
  /// by lineage first — those on the road, and those planned and still
  /// waiting to pull out, alike (§3.9, §4.6) — and publishes a frame on
  /// the new ids at once; a refreshed one keeps every id.
  void _swap(LaneGraph next, {required bool rebuild}) {
    final old = lg;
    final rm = rebuild &&
            old != null &&
            (table.liveCount > 0 || planner.waiting > 0)
        ? RouteRemapper(EdgeLineage(old, next))
        : null;
    if (rm != null && table.liveCount > 0) {
      _remapAll(rm, next);
    } else {
      mover.bind(next);
    }
    lg = next;
    final c = cost = RouteCost(next);
    queue.bind(c);
    stats.bind(next);
    // A refreshed graph keeps its measured delays; a rebuilt one starts
    // afresh, priced at D = 0 until its first epoch. Either way every search
    // restarts on the buffer the table holds now.
    delays.bind(next);
    queue.delays = delays.published;
    if (rm != null && planner.waiting > 0) planner.remapWaiting(rm, commutes);
    if (rebuild) {
      graphRev++;
      // The renderer's geometry follows the new graph at once, and it draws
      // a frame only over the graph that frame was published on: publish
      // one on the new ids now, rather than draw no car until the next
      // sub-step — most host ticks run none.
      frames.publish(table,
          timeUs: clock.timeUs,
          worldEpochS: agents.worldEpochS,
          graphRev: graphRev);
    }
    controlsRev++;
  }

  /// §3.9 for every vehicle, by [rm]: remapped while the table still holds
  /// the old graph, then placed on [next], relinked, and kept clear of one
  /// another.
  void _remapAll(RouteRemapper rm, LaneGraph next) {
    final old = rm.lineage.from;
    final t = table;
    final hw = t.highWater;
    if (_rmOp.length < t.capacity) {
      _rmOp = Uint8List(t.capacity);
      _rmElem = Int32List(t.capacity);
      _rmS = Float64List(t.capacity);
    }
    final nOld = old.laneCount, nNew = next.laneCount;
    for (var sl = 0; sl < hw; sl++) {
      _rmOp[sl] = _opNone;
      if (!t.isSlotLive(sl)) continue;
      final el = t.elem[sl];
      // Inside a site, off the road: it holds no element of the old graph
      // to be carried from, and stays unplaced here; the site mover remaps
      // its held road route (docs/plans/t4a-implementation.md §1.2, §2).
      if (el < 0) continue;
      final off = t.routeOff[sl], len = t.routeLen[sl], cur = t.routeCur[sl];
      final destS = t.destS[sl].toDouble();
      if (el < nOld) {
        final st = rm.remap(t.arena.data, off, len,
            at: cur, s: t.s[sl].toDouble(), destS: destS);
        _settleRemap(sl, rm, st, next, onLane: true);
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
      // Its time on the edge it was on is time on another edge now, of
      // another length: it observes nothing until it enters the next one
      // (§4.2).
      t.edgeEnterUs[sl] = -1;
    }
    t.relinkAll();
    _separate(next);
    for (var sl = 0; sl < hw; sl++) {
      if (_rmOp[sl] == _opHold && t.isSlotLive(sl)) {
        stats.replans++;
        _ask(t.handleOf(sl), kReplanTag);
      }
    }
  }

  /// Settles [sl] by the remap's outcome [st]: its new route and place, a
  /// hold for a re-plan, or off the road. [onLane]: it was on a lane of the
  /// old graph, not a connector.
  void _settleRemap(int sl, RouteRemapper rm, RemapStatus st, LaneGraph next,
      {bool onLane = false}) {
    final t = table;
    switch (st) {
      case RemapStatus.kept:
        _rmOp[sl] = _opPlace;
        if (rm.lanesRepaired) stats.lanesRepaired++;
        if (onLane && _carryThroughBox(sl, rm, next)) return;
        t.setRoute(sl, rm.route, rm.routeLength, destS: rm.stopS);
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

  /// A vehicle that stood where the edit put a junction's box on its road:
  /// past the new stop line on the piece behind the new node, or past the
  /// node and short of where the next piece's lane now begins. Clamped onto
  /// its lane it would be dragged up to the box's depth, onto the car
  /// behind it or ahead; instead it goes on the connector of its own
  /// movement straight through the box, as far through it as it stands.
  /// True when [sl] was placed so — its route, its element and place, its
  /// origin — and false to leave it to the lane.
  ///
  /// Only a vehicle on its way: one standing still for a plan it waits on
  /// (a re-plan's hold, an appended leg's dwell) is planned from the lane
  /// it is in (`resolve`), and keeps it.
  bool _carryThroughBox(int sl, RouteRemapper rm, LaneGraph next) {
    final t = table;
    final st = t.state[sl];
    if (st == _hold || st == _dwelling) return false;
    final lane = rm.lane;
    final e = next.laneEdge[lane];
    final s0 = next.edgeLaneS0[e].toDouble(), s1 = next.edgeLaneS1[e].toDouble();
    final at = rm.placeT;
    final nNew = next.laneCount;
    if (at > s1 + _boxEps) {
      // Past the stop line, onto the route's first connector. A route that
      // ends on this edge has its stop clamped to the lane's end, where the
      // lane places it, and it arrives there.
      if (rm.routeLength < 2 || rm.route[0] != lane) return false;
      if (!t.setRoute(sl, rm.route, rm.routeLength,
          destS: rm.stopS, routeCur: 1)) {
        return false;
      }
      final c = rm.route[1];
      _rmElem[sl] = nNew + c;
      _rmS[sl] = _intoConnector(next, c, at - s1);
      planner.originT[sl] = s1;
      return true;
    }
    if (at < s0 - _boxEps) {
      // Past the node, on the connector into its lane from the piece of its
      // road behind — none where the node is not on its road, and then the
      // lane has it.
      final c = rm.connectorBehind(lane);
      if (c < 0) return false;
      final n = rm.routeLength + 1;
      if (_rmRoute.length < n) _rmRoute = Int32List(2 * n);
      _rmRoute[0] = next.conFromLane[c];
      _rmRoute[1] = c;
      _rmRoute.setRange(2, n, rm.route, 1);
      if (!t.setRoute(sl, _rmRoute, n, destS: rm.stopS, routeCur: 1)) {
        return false;
      }
      _rmElem[sl] = nNew + c;
      _rmS[sl] = _intoConnector(next, c, next.conLen[c] - (s0 - at));
      planner.originT[sl] = next.edgeLaneS1[next.conFromEdge(c)];
      return true;
    }
    return false;
  }

  /// [s] metres along connector [c] of [g], kept on it: no further than
  /// [_laneEndM] short of its end, so the vehicle hands over by moving.
  static double _intoConnector(LaneGraph g, int c, double s) {
    final hi = g.conLen[c] - _laneEndM;
    return s > hi ? (hi > 0 ? hi : 0.0) : (s > 0 ? s : 0.0);
  }

  /// After a rebuild has placed and relinked every vehicle: no vehicle's
  /// front is left within [_placeClearM] of the tail of the one ahead of it
  /// on its element. Where the remap could not keep a vehicle where it was,
  /// the place it had instead may be on or against another; that vehicle —
  /// the one behind — is moved back until it clears, never behind the start
  /// of its element, and counted in `stats.remapNudges` (a vehicle that
  /// cannot clear even there stays at the start, counted too).
  ///
  /// Each element's list, head to tail, is its vehicles by descending
  /// place, and moving one back never takes it behind the next: the
  /// relinked order stands.
  ///
  /// It walks the lists, never a slot's element: a vehicle inside a site
  /// (element −1) is on no list, and is never met here.
  void _separate(LaneGraph next) {
    final t = table;
    final nEl = next.elementCount;
    for (var el = 0; el < nEl; el++) {
      final head = t.elemHead[el];
      if (head < 0) continue;
      for (var ahead = head, sl = t.next[head];
          sl >= 0;
          ahead = sl, sl = t.next[sl]) {
        final clear = t.s[ahead] - t.len[ahead] - _placeClearM;
        final s = t.s[sl].toDouble();
        if (s <= clear) continue;
        final to = clear > 0 ? clear : 0.0;
        final back = s - to;
        t.s[sl] = to;
        t.odo[sl] -= back;
        t.movedM[sl] -= back;
        stats.remapNudges++;
      }
    }
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
        requester: _vehicleRequester(h),
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
      final h = _requesterVehicle(request.requester);
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
    final h = _requesterVehicle(request.requester);
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
      } else if (request.tag == kSiteRetargetTag) {
        // No way on to where its building is met now: it has come as near
        // as its route could bring it, and arrives where it stopped.
        table.state[sl] = VehicleState.leaving.index;
        _arrive(h);
      } else {
        mover.despawn(h, DespawnReason.edit, this);
      }
      return;
    }
    table.state[sl] = _driving;
    table.stuckUs[sl] = 0;
    table.movedM[sl] = 0;
    // It stood on this edge waiting for the plan: that wait is no delay the
    // edge caused, so the edge is not observed (§4.2).
    table.edgeEnterUs[sl] = -1;
    if (request.tag == kRetargetTag) {
      table.purpose[sl] = TripPurpose.homeward.index;
    }
    planner.originT[sl] = route.originT;
  }

  // ---- The vehicles' events -----------------------------------------------------

  @override
  void arrived(int handle) {
    final sl = SlotPool.slotOf(handle);
    if (_accessMoved(sl, commutes.destOfVehicle(handle))) {
      // Its building stands, but is no longer met where the route stops
      // (D36's `siteRetarget`): an edit re-cut its lot while it drove, and
      // the route, locked, was carried to the old stop. An appended leg
      // takes it on, from its lane, to the access as it is now; it arrives
      // there. Not a re-plan: the route it drove was never edited.
      table.state[sl] = _dwelling;
      stats.appendedLegs++;
      _ask(handle, kSiteRetargetTag);
      return;
    }
    _arrive(handle);
  }

  /// [handle] has arrived where its route stopped: the trip's leg is done —
  /// or, its building found gone, an appended leg takes it home (§4.7).
  void _arrive(int handle) {
    stats.arrived++;
    final back = commutes.arrived(handle, clock.timeUs);
    if (back < 0) return;
    // An appended leg (§4.6): it waits at its stop, in its lane, while the
    // way on from there is found.
    table.state[SlotPool.slotOf(handle)] = _dwelling;
    stats.appendedLegs++;
    _ask(handle, kRetargetTag);
  }

  /// Whether the vehicle in [sl], at its stop, stopped short of or past
  /// building [dest]'s access: [dest] still stands and has access, on the
  /// lane graph of the last sync, but not on the edge the vehicle is on
  /// within [kSiteRetargetM] of its stop. False for no building (−1), one
  /// gone — that is §4.7's re-target — or one with no access left to go to.
  bool _accessMoved(int sl, int dest) {
    final g = lg;
    if (g == null || dest < 0 || !buildings.hasAccess(dest)) return false;
    final el = table.elem[sl];
    if (el < 0 || el >= g.laneCount) return false;
    return !buildings.meetsAt(
        dest, g.laneEdge[el], table.destS[sl].toDouble(), kSiteRetargetM);
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
    queue.cancel(_vehicleRequester(handle));
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
      h = fnv1aU32(h, t.variant[sl] | t.flags[sl] << 8 | t.grant[sl] << 16);
      h = fnv1aU32(h, t.elem[sl]);
      h = fnv1aU32(h, t.routeCur[sl]);
      h = fnv1aU32(h, t.routeLen[sl]);
      final off = t.routeOff[sl];
      for (var i = 0; i < t.routeLen[sl]; i++) {
        h = fnv1aU32(h, data[off + i]);
      }
      h = fnv1aU32(h, t.pass[sl]);
      h = fnv1aU32(h, t.owner[sl]);
      h = fnv1aU32(h, t.stuckUs[sl]);
      h = fnv1aU32(h, t.waitUs[sl]);
      // Places to the millimetre and speeds to the millimetre a second
      // (§17.4), every other real to its thousandth; the speed factor, a
      // draw, to its millionth.
      h = _milli(h, t.s[sl]);
      h = _milli(h, t.v[sl]);
      h = _milli(h, t.a[sl]);
      h = _milli(h, t.v0[sl]);
      h = fnv1aU32(h, (t.f[sl] * 1e6).round());
      h = _milli(h, t.destS[sl]);
      h = _milli(h, t.movedM[sl]);
      h = _milli(h, t.freeFlowS[sl]);
      h = _milli(h, t.odo[sl]);
      h = _wide(h, t.edgeEnterUs[sl].toInt());
      h = _wide(h, t.tripT0Us[sl].toInt());
      h = _milli(h, planner.originT[sl]);
    }
    h = commutes.digest(h);
    h = buildings.digest(h);
    h = planner.digest(h);
    h = arbiter.digest(h);
    h = queue.digest(h);
    h = delays.digest(h);
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
    h = fnv1aU32(h, stats.lanesRepaired);
    h = fnv1aU32(h, stats.remapNudges);
    h = fnv1aU32(h, (stats.congestionIndex * 1e6).round());
    h = fnv1aU32(h, (stats.tripRatio * 1e6).round());
    return h;
  }

  /// [hash] with [x] folded in to the thousandth.
  static int _milli(int hash, double x) => fnv1aU32(hash, (x * 1000).round());

  /// [hash] with [x] folded in whole, both halves of it: agent microseconds
  /// pass 2³² after an hour and a quarter.
  static int _wide(int hash, int x) =>
      fnv1aU32(fnv1aU32(hash, x & 0xFFFFFFFF), x ~/ 0x100000000);
}
