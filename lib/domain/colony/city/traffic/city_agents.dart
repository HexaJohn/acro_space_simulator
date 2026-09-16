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
/// **Sites** (T4a, site-access.md §7; docs/plans/t4a-implementation.md §2).
/// A colony's site plans are read through one [SitePlanSource] — the book's,
/// or a test's — and synced into a [SiteTable] whenever `sitesRev` or a
/// chunk moves, never on `graphRev` (D49). A trip that reaches a site with
/// stalls is held at its arrival gate, drives the site and parks
/// ([SiteMover]); what the gate cannot take goes to a kerb slot ahead
/// ([KerbTable]) and what nothing can place is garaged (D17 steps 1–2).
/// Parked cars are rows of their own ([ParkedCarTable]), saved by
/// `(siteId, stallKey)` and driven away again from where they stand.
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
import '../site_access/site_access_plan.dart';
import 'access_events.dart';
import 'agent_frame.dart';
import 'agent_kind.dart';
import 'agent_traffic_readout.dart';
import 'agents_codec.dart';
import 'building_table.dart';
import 'edge_delay.dart';
import 'graph_lineage.dart';
import 'junction_arbiter.dart';
import 'kerb_mask.dart';
import 'kerb_slots.dart';
import 'lane_graph.dart';
import 'lane_graph_builder.dart';
import 'network_key.dart';
import 'parked_cars.dart';
import 'path_search.dart';
import 'route_cost.dart';
import 'site_mover.dart';
import 'site_plan_source.dart';
import 'site_stats.dart';
import 'site_table.dart';
import 'site_vehicles.dart';
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

/// The tag of a leg asked for again because the road route a car held
/// INSIDE a site could not be carried across a lane-graph rebuild (§7.6,
/// `SiteMover.remapHeld`). Its origins are the site's out-joins, exactly as
/// a fresh departure's are: the car is back on a stall by then.
const int kSiteReplanTag = 4;

/// How far from its building's access, as the table resolves it now, a
/// vehicle may stop and still have arrived there: a join window's reach
/// either side of its join (§5.5), well over the centimetres a split's
/// re-sampling moves a stop by. It is also how near an arrival's stop a
/// plan join must be for the arrival to be THAT join's (§7.4 step 2).
const double kSiteRetargetM = 1.5;

/// How near a saved or displaced kerb car's pose a slot must be for the car
/// to be put back on it, and how far its heading may have turned (§14.1:
/// 12 m, 45°). Past either it is garaged.
const double kKerbSnapM = 12;
const double kKerbSnapCos = 0.7071067811865476;

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
  SiteStats? _idleSiteStats;
  TrafficMetrics? _metrics;
  int _picturesBefore = 0;
  int _laneSpeedRevBefore = 0;

  /// The colony's own book as a plan source, made once (§1.1). A new source
  /// object reads as new plans to `BuildingTable.sync`, so one rebuilt per
  /// sync would re-resolve every building's access every sync.
  SitePlanSource? _bookPlans;
  SitePlanSource? _debugPlans;

  /// The `'agents'` block a load handed over, waiting for the first advance
  /// to give it a lane graph and site rows to be placed against (§14.4's
  /// load order: `restore` only stores the JSON).
  SavedAgents? _saved;

  /// What [agentManaged] answers before there are any tables.
  static final Uint8List _noSites = Uint8List(0);

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

  // ---- The sites (T4a) ---------------------------------------------------------

  /// The site plans the agents read (§1.1): the colony's book, or whatever
  /// [debugPlans] put in its place.
  SitePlanSource get plans =>
      _debugPlans ?? (_bookPlans ??= BookPlanSource(city.siteAccess));

  /// Synthetic plans in place of the colony's book, for the site tests
  /// (`FixturePlanSource`). Setting it re-resolves every building's access
  /// and re-syncs the site rows at the next advance.
  set debugPlans(SitePlanSource? source) {
    if (identical(source, _debugPlans)) return;
    _debugPlans = source;
    _core?.plansReplaced();
  }

  /// The synced site networks, the parked cars, the kerb slots, this
  /// sub-step's access events and the site columns — what the site tests,
  /// the wire and the allocation gate read. Null before the tables exist.
  SiteTable? get sites => _core?.sites;
  ParkedCarTable? get parkedCars => _core?.parked;
  KerbTable? get kerbs => _core?.kerbs;
  AccessEventLog? get accessEvents => _core?.events;
  SiteVehicles? get siteVehicles => _core?.siteCols;
  SiteMover? get siteMover => _core?.siteMover;

  /// What the site traffic counted (§1.8). Like [stats], it survives the
  /// tables being dropped only as far as the idle instance: the counters are
  /// the running colony's.
  SiteStats get siteStats =>
      _core?.siteStats ?? (_idleSiteStats ??= SiteStats());

  /// E36 stage 1 (§0 Q4): 1 at the book slot of every site whose parking the
  /// agents manage, so the road side's baking skips its lot cars. A slot past
  /// the list's length reads 0, and so does every slot while the agents are
  /// off. [agentManagedRev] moves whenever the list may have changed and
  /// never goes back.
  Uint8List get agentManaged => _core?.agentManaged ?? _noSites;
  int get agentManagedRev => _core?.agentManagedRev ?? 0;

  /// Every buffer the site half keeps from one sub-step to the next, by name
  /// into [into], for the allocation gate (A13, §15.2): once warm, none of
  /// them is ever replaced. Nothing is added while the tables do not exist.
  void collectSiteBuffers(Map<String, Object> into) =>
      _core?.collectSiteBuffers(into);

  /// Sends parked car [car] away now: a one-way trip from the building it
  /// stands at to a job drawn on the demand stream, departing from THAT car
  /// (§17's hooks; A9's tandem shuffle). Returns the trip's handle, or
  /// `SlotPool.none` when the car is gone, its building is not one trips can
  /// leave, or a cap deferred it.
  int debugDepart(int car) => _core?.debugDepart(car) ?? SlotPool.none;

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

  /// The `'agents'` save block (E15): the flag, and from T4a the parked cars
  /// by `(siteId, stallKey)` (§14.1, §4 Q2). Vehicles in flight and stall
  /// reservations are never saved (§14.3), so a colony with nothing parked
  /// writes the bytes it wrote before T4a.
  ///
  /// It runs no held tick of its own: a save is the colony as of the moment
  /// it is taken, and running a tick half way through `CitySim.toJson` would
  /// move the colony under the fields already written. A host that holds
  /// ticks calls [flushHeld] before it saves (§5.7).
  Map<String, Object?> toJson() {
    final core = _core;
    if (core == null) return AgentsCodec.encode(enabled: _enabled);
    return AgentsCodec.encode(
        enabled: _enabled, cars: core.parked, world: core);
  }

  /// Restores the save block [json] (E16), after the colony itself is
  /// restored. No block, or one this build cannot read: agents off. The cars
  /// are only STORED here — lot ids and site plans exist from the first
  /// advance on, and that is where they are placed (§14.4's load order).
  void restore(Object? json) {
    final saved = AgentsCodec.decode(json);
    enabled = saved?.enabled ?? false;
    _saved = enabled && saved != null && saved.cars.count > 0 ? saved : null;
  }

  /// The cars a load is still holding, taken once: `null` after.
  SavedAgents? takeSaved() {
    final s = _saved;
    _saved = null;
    return s;
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
class _Core
    implements
        PathResolver,
        PathSink,
        VehicleSink,
        SpawnSink,
        SiteChangeSink,
        SiteSink,
        CarSaveSource,
        CarRestoreSink {
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
    siteMover = SiteMover(table, siteCols, sites, arbiter, events, siteStats);
    // A back-out's footprint is an obstacle to the road's own followers
    // (§7.4): bound once, and never asked while no back-out holds one.
    mover.obstacles = siteMover;
    // What stands behind what on a tandem pad is the PLAN's to know, so the
    // car table asks the sites (parked_cars.dart, §7.5).
    parked.tandem = _TandemPlan(sites);
    planner
      ..cars = parked
      ..sites = sites
      ..kerbs = kerbs
      ..stalls = _StallSpawns(siteMover);
    commutes.cars = parked;
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

  // ---- The sites (T4a) --------------------------------------------------------

  final SiteTable sites = SiteTable();
  final SiteVehicles siteCols = SiteVehicles(AgentTuning.maxVehicles);
  final AccessEventLog events = AccessEventLog();
  final SiteStats siteStats = SiteStats();
  final ParkedCarTable parked = ParkedCarTable();
  final KerbTable kerbs = KerbTable();
  late final SiteMover siteMover;

  /// Per site slot: 1 where the agents manage that site's parking (E36
  /// stage 1), and a revision that moves with it.
  Uint8List agentManaged = Uint8List(0);
  int agentManagedRev = 0;

  /// Whether this colony has any site state at all to fold into [digest]:
  /// a site row, a car parked anywhere, a kerb slot claimed, a vehicle with
  /// site business. Until it has, the digest is exactly what it was before
  /// T4a, so a colony without plans agrees with its own old history.
  bool _siteState = false;

  /// Per vehicle slot, for a car bound for a kerb slot ahead (D17 step 2):
  /// the building it is parking for. `SiteVehicles.row` is a SITE row and
  /// stays −1 for such a car, because a sync's snap and evacuate match on
  /// that column and would take a building slot for one of their own.
  Int32List _kerbFor = Int32List(0);

  /// Kerb cars caught by a rebuild, with the pose they had on the graph that
  /// is going: four doubles each (east, north, dirE, dirN). Re-snapped onto
  /// the new kerbs by §14.1's rule once they are laid.
  Int32List _movedCar = Int32List(0);
  Float64List _movedPose = Float64List(0);
  int _movedCount = 0;

  /// Owners whose held site route a rebuild could not carry (§7.6): asked
  /// for again AFTER the remap, because the mover puts their cars back on
  /// their stalls as it goes.
  Int32List _siteReplan = Int32List(16);
  int _siteReplanCount = 0;

  /// Cars the arrival gate gave up on this sub-step, four ints each: the
  /// handle, the building it was parking for, and the car's opaque owner and
  /// kind. See [gateGaveUp].
  Int32List _gaveUp = Int32List(0);
  int _gaveUpCount = 0;
  static const int _gaveUpStride = 4;

  /// The saved cars being placed now, so the codec's sink can read their
  /// columns; null outside a restore.
  SavedAgents? _restoring;

  /// Scratch: the two points a kerb pose is read from, and the pose itself.
  /// Nothing here is re-entered, so one of each is enough (§15.2).
  final Float64List _pt = Float64List(8);
  final Float64List _pose4 = Float64List(4);

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

  /// The network, the buildings and the site networks brought up to the
  /// colony as it stands, in that order: a building's access rows come from
  /// its plan's joins, and a site row hangs on a building slot (§2).
  void prime() {
    _ensureCols();
    _poll();
    if (_buildingsMoved()) _syncBuildings();
    if (sites.needsSync(agents.plans, lg)) _syncSites();
    // The cars a load is holding go down once there are rows to put them on,
    // and not before: taken only when there is a network to place them on,
    // so a colony primed without one keeps them for the advance that has one.
    if (lg != null) {
      final saved = agents.takeSaved();
      if (saved != null) _placeSavedCars(saved);
    }
  }

  /// A test put other plans in front of the book ([CityAgents.debugPlans]):
  /// every building resolves its access again at the next prime.
  void plansReplaced() => _syncGraph = null;

  // ---- The site networks (§7.6, D49) ------------------------------------------

  /// One site sync: the rows, then the mover relinked onto the renumbered
  /// site elements, then the kerb masks the new plans imply.
  void _syncSites() {
    sites.sync(agents.plans, buildings, lg, this);
    siteMover.relink();
    siteStats.limboRows = sites.rowsLimboed;
    if (sites.highWater > 0) _siteState = true;
    _publishManaged();
    _remask();
  }

  /// E36 stage 1: the book slot of every live, current site with stalls the
  /// agents park on. Rebuilt on a sync, and only published when it changed,
  /// so the road side re-bakes nothing it need not.
  void _publishManaged() {
    var top = -1;
    for (var r = 0; r < sites.highWater; r++) {
      if (!sites.isRowLive(r) || sites.lotCap[r] <= 0) continue;
      if (sites.bookSlot[r] > top) top = sites.bookSlot[r];
    }
    final n = top + 1;
    final to = Uint8List(n);
    for (var r = 0; r < sites.highWater; r++) {
      if (!sites.isRowLive(r) || sites.lotCap[r] <= 0) continue;
      final slot = sites.bookSlot[r];
      if (slot >= 0 && slot < n) to[slot] = 1;
    }
    final was = agentManaged;
    if (was.length == n) {
      var same = true;
      for (var i = 0; i < n && same; i++) {
        same = was[i] == to[i];
      }
      if (same) return;
    }
    agentManaged = to;
    agentManagedRev++;
  }

  /// The kerb slots' masks, taken from the road side's cuts over the plans
  /// running now (§0 Q1), and whatever that displaced. The colony keeps no
  /// graph history, so a site still resolved against an older graph
  /// contributes no cut — which is what `KerbCuts.canonicalOf` leaves out
  /// without a `roadIdsAt`.
  void _remask() {
    final g = lg;
    if (g == null) return;
    kerbs.applyMasks(sites, g, CutKerbMask.of(g, agents.plans));
    for (var i = 0; i < kerbs.relocateCount; i++) {
      final car = kerbs.relocateCar(i);
      if (!parked.isLive(car)) continue;
      final j = SlotPool.slotOf(car);
      final was = parked.slot[j];
      if (was >= 0) kerbs.release(was);
      if (_toKerb(car, parked.building[j])) {
        siteStats.relocates++;
      } else {
        parked.moveToGarage(car);
        siteStats.garaged++;
        siteStats.siteGarages++;
      }
    }
    kerbs.clearRelocations();
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
    // This sub-step's access events, and nothing older: the property test
    // reads the log after every sub-step (§5.5).
    events.beginStep();
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
    // 3–5. The vehicles, their arrivals and despawns; then the cars inside
    // sites, which an arrival this very sub-step may have handed to the gate.
    mover.step(now, this);
    siteMover.step(now, this, this);
    if (_gaveUpCount > 0) _drainGiveUps();
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
    // 7. The frame, with the site columns the wire draws in-site cars from
    // (package F reads them; until then they ride along unread).
    frames.publish(table,
        timeUs: now,
        worldEpochS: agents.worldEpochS,
        graphRev: graphRev,
        site: siteCols,
        sitesRev: sites.syncedSitesRev);
    // Last: a plan held in limbo is freed in the sub-step its last car left
    // (§7.6 row 3).
    sites.endStep();
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
    // Kerb slots are laid off the lane graph and nothing else, so a rebuild
    // numbers every one of them afresh: the cars standing on them are
    // remembered by their POSE while the old graph can still say where that
    // is, and put back by §14.1's rule once the new kerbs are laid.
    final relayKerbs = old == null || !next.sharesStructureWith(old);
    if (relayKerbs && old != null) _captureKerbCars(old);
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
    siteMover.bind(next);
    if (relayKerbs) {
      kerbs.bind(next);
      _remask();
      _replaceKerbCars();
    }
    // Cars still inside a site hold a road route they have not started: it
    // is carried across as a waiting route is (§7.6), and what could not be
    // carried is planned again from the site's out-joins.
    if (rm != null) _remapSiteHeld(rm);
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
      if (_rmOp[sl] != _opHold || !t.isSlotLive(sl)) continue;
      // A car held at an arrival gate has already arrived: its route is
      // spent, and the edit only moved the lane it waits in. It waits there
      // on the new lane (the gate reads the lane, not the route); a re-plan
      // would send it to the building it is standing at.
      if (siteCols.phase[sl] == SitePhase.gateHeld.index) continue;
      stats.replans++;
      _ask(t.handleOf(sl), kReplanTag);
    }
  }

  /// §7.6 for the cars waiting INSIDE sites: their held road routes carried
  /// across [rm], and whoever lost one asked for a leg again once the mover
  /// has put its car back on a stall (which it does as it goes, so the
  /// re-requests wait until it is done).
  void _remapSiteHeld(RouteRemapper rm) {
    _siteReplanCount = 0;
    siteMover.remapHeld(rm, this, this);
    for (var i = 0; i < _siteReplanCount; i++) {
      stats.replans++;
      commutes.replanFromSite(_siteReplan[i], kSiteReplanTag);
    }
    _siteReplanCount = 0;
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

  /// A building's access rows are its PLAN's joins (§7.3), so the plans
  /// moving is a reason to sync as much as the plat moving is:
  /// `SiteTable.needsSync` is that question, `sitesRev` and the chunks'
  /// identities both.
  bool _buildingsMoved() =>
      city.layout.version != _syncLayout ||
      city.parcelBuildings.length != _syncPlaced ||
      city.grownParcels.length != _syncGrown ||
      city.utils.length != _syncUtils ||
      city.grown.length != _syncCells ||
      !identical(lg, _syncGraph) ||
      sites.needsSync(agents.plans, lg);

  void _syncBuildings() {
    buildings.sync(city, lg, agents.plans);
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
    if (request.tag == kTripTag || request.tag == kSiteReplanTag) {
      // A trip leaves from its own parked car (§7.4 Departure): a car on a
      // lot stall leaves by its site's out-joins, which are the building's
      // access rows; one at a kerb leaves from its SLOT, in the lane that
      // kerb serves, and nowhere else.
      if (!_carOrigin(request.requester, g, ends) &&
          !buildings.addOrigins(request.origin, ends)) {
        return false;
      }
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

  /// The origin of [commuter]'s trip when its car stands at a KERB: that
  /// slot's `(edge, T)`, in the lane beside it. False for a trip with no car,
  /// or one whose car is on a stall or garaged — those leave from the
  /// building's own access rows.
  bool _carOrigin(int commuter, LaneGraph g, PathEnds ends) {
    final car = commutes.carOf(commuter);
    if (car < 0 || !parked.isLive(car)) return false;
    final i = SlotPool.slotOf(car);
    if (parked.where[i] != CarWhere.kerb.index) return false;
    final slot = parked.slot[i];
    if (slot < 0 || slot >= kerbs.slotCount) return false;
    final lane = kerbs.slotLane(slot);
    if (lane < 0 || lane >= g.laneCount) return false;
    ends.addOrigin(g.laneEdge[lane], kerbs.slotT(slot), lane: lane);
    return true;
  }

  @override
  void onPath(PathRequest request, PathOutcome outcome, PlannedRoute route) {
    if (request.tag == kTripTag || request.tag == kSiteReplanTag) {
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
        _arrive(h, commutes.destOfVehicle(h));
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
    // A car sent on the one-element leg to a kerb slot ahead (D17 step 2):
    // it has reached the slot it reserved, and it parks there.
    if (siteCols.phase[sl] == SitePhase.kerbBound.index) {
      _parkAtKerb(handle);
      return;
    }
    final dest = commutes.destOfVehicle(handle);
    if (_accessMoved(sl, dest)) {
      // Its building stands, but is no longer met where the route stops
      // (D36's `siteRetarget`): an edit re-cut its lot while it drove, and
      // the route, locked, was carried to the old stop. An appended leg
      // takes it on, from its lane, to the access as it is now; it arrives
      // there. Not a re-plan: the route it drove was never edited.
      table.state[sl] = _dwelling;
      stats.appendedLegs++;
      siteStats.siteRetargets++;
      _ask(handle, kSiteRetargetTag);
      return;
    }
    _arrive(handle, dest);
  }

  /// [handle] has arrived where its route stopped: the trip's leg is done
  /// and its car looks for somewhere to stand (D17) — or, its building found
  /// gone, an appended leg takes it home (§4.7).
  ///
  /// Everything the parking needs of the trip is read BEFORE
  /// `CommuteSynth.arrived`, which clocks the commuter in and lets go of its
  /// vehicle: whose car this is, and which way it was going.
  void _arrive(int handle, int dest) {
    stats.arrived++;
    final sl = SlotPool.slotOf(handle);
    final commuter = table.owner[sl];
    final homeward = table.purpose[sl] == TripPurpose.homeward.index;
    final home = commutes.homeOf(commuter);
    final back = commutes.arrived(handle, clock.timeUs);
    if (back >= 0) {
      // An appended leg (§4.6): it waits at its stop, in its lane, while the
      // way on from there is found.
      table.state[sl] = _dwelling;
      stats.appendedLegs++;
      _ask(handle, kRetargetTag);
      return;
    }
    _park(handle, dest, commuter, homeward ? -1 : home, homeward);
  }

  // ---- Parking (D17 steps 1–2, §7.5) ------------------------------------------

  /// Where [handle]'s car stands from here. [commuter] is whose trip it was,
  /// [carOwner] and [homeward] the opaque owner the car takes: a car left at
  /// work belongs to the commuter that drove it, and names the home it came
  /// from; a car brought home joins that home's pool, which is what the next
  /// commute out of it takes (§0 Q3).
  void _park(int handle, int dest, int commuter, int carOwner, bool homeward) {
    final g = lg;
    final sl = SlotPool.slotOf(handle);
    final kind = homeward ? CarOwnerKind.homePool : CarOwnerKind.commuter;
    siteCols.owner[sl] = carOwner;
    siteCols.ownerKind[sl] = kind.index;
    if (g == null || !buildings.isLive(dest)) {
      _garageFor(handle, dest, carOwner, kind, commuter);
      return;
    }
    // Step 1: the destination's own stalls, reserved at the arrival gate.
    final row = sites.rowOfBuilding(SlotPool.slotOf(dest));
    final el = table.elem[sl];
    if (row >= 0 && el >= 0 && el < g.laneCount) {
      final join = _joinOfArrival(row, g.laneEdge[el], table.destS[sl]);
      if (join >= 0) {
        final stall = sites.firstFreeStall(row, join);
        if (stall >= 0 && sites.reserve(row, stall, handle)) {
          table.state[sl] = VehicleState.parkingSearch.index;
          siteMover.holdAtGate(handle, row, join, stall);
          // `holdAtGate` clears the site columns first, so the car's owner
          // goes back on after it.
          siteCols.owner[sl] = carOwner;
          siteCols.ownerKind[sl] = kind.index;
          _siteState = true;
          return;
        }
      }
    }
    _kerbOrGarage(handle, dest, carOwner, kind, commuter);
  }

  /// Step 2: the first free, unmasked kerb slot ahead on the arrival edge,
  /// reserved bindingly, and a one-element leg to it — the same lane, a new
  /// stop, counted as an appended leg (§0 Q6). Steps 3–5 are T4b's, so what
  /// this cannot place is garaged.
  void _kerbOrGarage(int handle, int dest, int carOwner, CarOwnerKind kind,
      int commuter) {
    final g = lg;
    final sl = SlotPool.slotOf(handle);
    final el = g == null ? -1 : table.elem[sl];
    if (g != null && el >= 0 && el < g.laneCount) {
      final slot = kerbs.reserveAhead(el, table.destS[sl].toDouble(), handle);
      if (slot >= 0) {
        _one[0] = el;
        if (table.setRoute(sl, _one, 1, destS: kerbs.slotT(slot))) {
          table.state[sl] = _driving;
          table.stuckUs[sl] = 0;
          table.movedM[sl] = 0;
          table.edgeEnterUs[sl] = -1;
          stats.appendedLegs++;
          siteCols.clear(sl);
          siteCols.phase[sl] = SitePhase.kerbBound.index;
          siteCols.claim[sl] = slot;
          siteCols.owner[sl] = carOwner;
          siteCols.ownerKind[sl] = kind.index;
          _ensureCols();
          _kerbFor[sl] = dest;
          _siteState = true;
          return;
        }
        kerbs.release(slot);
      }
    }
    _garageFor(handle, dest, carOwner, kind, commuter);
  }

  /// [handle] has reached the kerb slot it reserved: its car stands there and
  /// its vehicle row goes.
  void _parkAtKerb(int handle) {
    final sl = SlotPool.slotOf(handle);
    final slot = siteCols.claim[sl];
    final dest = _kerbFor.length > sl ? _kerbFor[sl] : -1;
    final b = buildings.isLive(dest) ? SlotPool.slotOf(dest) : -1;
    final car = slot < 0
        ? SlotPool.none
        : parked.parkKerb(
            building: b,
            edge: kerbs.slotEdge(slot),
            slot: slot,
            side: kerbs.slotSide(slot),
            ownerKind: CarOwnerKind.values[siteCols.ownerKind[sl]],
            owner: siteCols.owner[sl],
            kind: table.kind[sl],
            variant: table.variant[sl]);
    if (car != SlotPool.none) {
      kerbs.occupy(slot, car);
      siteStats.parkedKerb++;
      _giveCar(table.owner[sl], car);
    } else if (slot >= 0) {
      kerbs.release(slot);
    }
    _siteState = true;
    _freeParked(handle, sl);
  }

  /// Nowhere would take it: the car leaves the world, still its owner's, and
  /// comes back at the building's access when that owner drives again
  /// (§7.5 D17 step 5, §5.6).
  void _garageFor(int handle, int dest, int carOwner, CarOwnerKind kind,
      int commuter) {
    final sl = SlotPool.slotOf(handle);
    final car = parked.garage(
        building: buildings.isLive(dest) ? SlotPool.slotOf(dest) : -1,
        ownerKind: kind,
        owner: carOwner,
        kind: table.kind[sl],
        variant: table.variant[sl]);
    if (car != SlotPool.none) {
      siteStats.garaged++;
      _giveCar(commuter, car);
      _siteState = true;
    }
    _freeParked(handle, sl);
  }

  /// The vehicle row of a car that has finished parking: off the road, its
  /// queued requests dropped, its site columns emptied.
  void _freeParked(int handle, int sl) {
    queue.cancel(_vehicleRequester(handle));
    arbiter.release(sl);
    siteCols.clear(sl);
    if (_kerbFor.length > sl) _kerbFor[sl] = -1;
    table.free(handle);
  }

  /// [commuter] keeps [car], so its next leg departs from where it stands.
  void _giveCar(int commuter, int car) => commutes.setCar(commuter, car);

  /// The plan-local in-join of site [row] a car that stopped at travel arc
  /// [t] of [edge] arrived at, or −1 (§7.4 step 2; V4 makes it unique).
  int _joinOfArrival(int row, int edge, double t) {
    final g = lg;
    if (g == null || !sites.isRowLive(row)) return -1;
    final p = sites.plan[row];
    if (p == null) return -1;
    final rg = g.graph;
    var best = -1;
    var bestM = kSiteRetargetM;
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinCanIn(j)) continue;
      final piece = p.joinPiece(j);
      if (piece < 0 || piece >= rg.pieceCount) continue;
      if (rg.pieceFwdEdge[piece] != edge && rg.pieceBwdEdge[piece] != edge) {
        continue;
      }
      final d = (g.travelArc(edge, p.joinRoadS(j)) - t).abs();
      if (d > bestM) continue;
      best = j;
      bestM = d;
    }
    return best;
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
    final sl = SlotPool.slotOf(handle);
    final commuter = table.owner[sl];
    final dest = commutes.destOfVehicle(handle);
    final home = commutes.homeOf(commuter);
    final kind = table.kind[sl], variant = table.variant[sl];
    _releaseSite(sl);
    commutes.despawned(handle, clock.timeUs);
    // §5.6: a citizen lost on the way is at their destination all the same,
    // and their car is GARAGED — never dropped, or the colony would quietly
    // lose a car on every jam and the home pools would drain.
    if (!commutes.isLive(commuter) || commutes.carOf(commuter) >= 0) return;
    final car = parked.garage(
        building: buildings.isLive(dest) ? SlotPool.slotOf(dest) : -1,
        ownerKind: CarOwnerKind.commuter,
        owner: home,
        kind: kind,
        variant: variant);
    if (car == SlotPool.none) return;
    siteStats.garaged++;
    _siteState = true;
    _giveCar(commuter, car);
  }

  /// Whatever the vehicle in [sl] held of a site goes back: a stall it had
  /// reserved at a gate, a kerb slot it was driving to. What is inside a
  /// site is the mover's, and a sync's evacuate or snap answers for it.
  void _releaseSite(int sl) {
    final ph = siteCols.phase[sl];
    if (ph == SitePhase.none.index) return;
    final claim = siteCols.claim[sl];
    if (ph == SitePhase.kerbBound.index) {
      if (claim >= 0) kerbs.release(claim);
    } else {
      final row = siteCols.row[sl];
      if (claim >= 0 && sites.isRowLive(row)) sites.unreserve(row, claim);
    }
    siteCols.clear(sl);
    if (_kerbFor.length > sl) _kerbFor[sl] = -1;
  }

  /// Room in the facade's own per-vehicle columns, as the tables grow.
  void _ensureCols() {
    final n = table.capacity;
    if (_kerbFor.length >= n) return;
    _kerbFor = Int32List(n)
      ..fillRange(0, n, -1)
      ..setRange(0, _kerbFor.length, _kerbFor);
  }

  // ---- The spawn sink, for the site mover's lost routes ------------------------

  @override
  void spawned(int owner, int handle) => commutes.spawned(owner, handle);

  @override
  void replanWaiting(int owner) {
    if (_siteReplanCount >= _siteReplan.length) {
      final n = _siteReplan.length * 2;
      _siteReplan = Int32List(n)..setRange(0, _siteReplanCount, _siteReplan);
    }
    _siteReplan[_siteReplanCount++] = owner;
  }

  // ---- The site mover's sink (§7.4, §7.5) -------------------------------------

  @override
  void parkedInStall(int handle, int row, int stall) {
    final sl = SlotPool.slotOf(handle);
    final ownerKind = CarOwnerKind.values[siteCols.ownerKind[sl]];
    final owner = siteCols.owner[sl];
    final commuter = table.owner[sl];
    final b = sites.isRowLive(row) ? sites.building[row] : -1;
    var car = SlotPool.none;
    if (stall >= 0 && sites.isRowLive(row)) {
      final p = sites.plan[row];
      final key = p != null && stall < p.stallCount ? p.stallKey(stall) : 0;
      car = parked.parkLot(
          building: b,
          row: row,
          stall: stall,
          stallKey: key,
          ownerKind: ownerKind,
          owner: owner,
          kind: table.kind[sl],
          variant: table.variant[sl]);
      if (car != SlotPool.none) {
        sites.occupy(row, stall, car);
        siteStats.parkedLot++;
      } else {
        sites.unreserve(row, stall);
      }
    }
    if (car == SlotPool.none) {
      // The mover had nowhere to put it (§7.6 row 1's last resort), or the
      // car table is full: out of the world, still its owner's.
      car = parked.garage(
          building: b,
          ownerKind: ownerKind,
          owner: owner,
          kind: table.kind[sl],
          variant: table.variant[sl]);
      if (car != SlotPool.none) siteStats.garaged++;
    }
    if (car != SlotPool.none) _giveCar(commuter, car);
    _siteState = true;
    _freeParked(handle, sl);
  }

  @override
  void gateGaveUp(int handle) {
    // The lot was full, or thirty seconds refused on the throat's room: D17
    // step 2 from where it stands. The mover empties this car's site columns
    // the instant this returns — a slot handed out again must never inherit
    // a dead car's business — so what step 2 needs of it is taken now and
    // the step itself runs after the mover's walk ([_drainGiveUps]).
    if (!table.isLive(handle)) return;
    final sl = SlotPool.slotOf(handle);
    if (_gaveUpCount * _gaveUpStride >= _gaveUp.length) {
      final n = _gaveUp.isEmpty ? 4 * _gaveUpStride : _gaveUp.length * 2;
      _gaveUp = Int32List(n)
        ..setRange(0, _gaveUpCount * _gaveUpStride, _gaveUp);
    }
    final o = _gaveUpCount * _gaveUpStride;
    _gaveUp[o] = handle;
    _gaveUp[o + 1] = commutes.destOf(table.owner[sl]);
    _gaveUp[o + 2] = siteCols.owner[sl];
    _gaveUp[o + 3] = siteCols.ownerKind[sl];
    _gaveUpCount++;
  }

  /// D17 step 2 for everyone the gate gave up on this sub-step.
  void _drainGiveUps() {
    final n = _gaveUpCount;
    _gaveUpCount = 0;
    for (var i = 0; i < n; i++) {
      final o = i * _gaveUpStride;
      final h = _gaveUp[o];
      if (!table.isLive(h)) continue;
      final sl = SlotPool.slotOf(h);
      table.state[sl] = _driving;
      _kerbOrGarage(h, _gaveUp[o + 1], _gaveUp[o + 2],
          CarOwnerKind.values[_gaveUp[o + 3]], table.owner[sl]);
    }
  }

  @override
  void exited(int handle) {
    // It is the road's again: nothing of ours is left to give back.
  }

  @override
  bool shuffleBlocker(int handle, int row, int blocker) {
    if (!sites.isRowLive(row)) return false;
    final at = sites.stallBase[row] + blocker;
    if (at < 0 || at >= sites.stallCar.length) return false;
    final car = sites.stallCar[at];
    if (car < 0 || !parked.isLive(car)) return false;
    if (!_toKerb(car, sites.building[row])) return false;
    sites.vacate(row, blocker);
    return true;
  }

  // ---- What a site sync changed (§7.6) ----------------------------------------

  @override
  void siteRevChanged(int oldRow, int newRow) {
    _remapParked(oldRow, newRow);
    siteMover.snap(oldRow, newRow);
  }

  @override
  void siteLostRole(int oldRow, int newRow) {
    if (newRow >= 0) {
      _remapParked(oldRow, newRow);
      siteMover.snap(oldRow, newRow);
      return;
    }
    // Kerbside now: there are no stalls left to stand on at all.
    _clearParked(oldRow);
    siteMover.evacuate(oldRow);
  }

  @override
  void siteGone(int oldRow) {
    // The movers carry on in the plan held in limbo; the parked cars have
    // nothing to stand on and go at once (§7.6 row 3).
    siteMover.evacuate(oldRow);
    _clearParked(oldRow, garageOnly: true);
  }

  /// Every car parked on [oldRow] onto [newRow], by its `stallKey` (C-19):
  /// the key's own stall where it survived, else the nearest free one, else
  /// garaged — each of the last two counted.
  ///
  /// In TWO passes, and that is the whole of it: a car whose key survived
  /// has a place of its own, and a car whose key went must not be given that
  /// place first simply because it came earlier in the table.
  void _remapParked(int oldRow, int newRow) {
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 0; i < parked.pool.highWater; i++) {
        if (!parked.pool.isSlotLive(i)) continue;
        if (parked.where[i] != CarWhere.lot.index) continue;
        if (parked.row[i] != oldRow) continue;
        final key = parked.stallKey[i];
        var stall = sites.stallIndexOfKey(newRow, key);
        if (stall >= 0 && sites.stallTaken(newRow, stall)) stall = -1;
        if (pass == 0) {
          if (stall < 0) continue;
        } else {
          stall = _nearestFreeStall(newRow, key);
        }
        final car = parked.pool.handleOf(i);
        if (sites.isRowLive(oldRow)) sites.vacate(oldRow, parked.stall[i]);
        if (stall < 0) {
          parked.moveToGarage(car);
          siteStats.garaged++;
          siteStats.siteGarages++;
          continue;
        }
        final p = sites.plan[newRow];
        parked.moveToStall(
            car, newRow, stall, p == null ? key : p.stallKey(stall));
        sites.occupy(newRow, stall, car);
        if (pass == 1) siteStats.relocates++;
      }
    }
  }

  /// Every car parked on [oldRow] off it: to a kerb slot near its building
  /// where one is free, else garaged. [garageOnly]: the site went, and a
  /// kerb beside a demolished lot is no place to leave it (§7.6 row 3).
  void _clearParked(int oldRow, {bool garageOnly = false}) {
    for (var i = 0; i < parked.pool.highWater; i++) {
      if (!parked.pool.isSlotLive(i)) continue;
      if (parked.where[i] != CarWhere.lot.index) continue;
      if (parked.row[i] != oldRow) continue;
      final car = parked.pool.handleOf(i);
      if (sites.isRowLive(oldRow)) sites.vacate(oldRow, parked.stall[i]);
      if (!garageOnly && _toKerb(car, parked.building[i])) {
        siteStats.relocates++;
        continue;
      }
      parked.moveToGarage(car);
      siteStats.garaged++;
      siteStats.siteGarages++;
    }
  }

  /// The free stall of [row] whose key is nearest [key]. Stall keys are the
  /// plan's frame lattice (V10), so a near key is a near place — which is as
  /// close to §14.1's "nearest free stall by distance" as a caller that no
  /// longer holds the old geometry can come.
  int _nearestFreeStall(int row, int key) {
    if (!sites.isRowLive(row)) return -1;
    final p = sites.plan[row];
    if (p == null) return -1;
    var best = -1;
    var bestD = 0;
    for (var s = 0; s < sites.stallCount[row]; s++) {
      if (sites.stallTaken(row, s)) continue;
      final d = (p.stallKey(s) - key).abs();
      if (best < 0 || d < bestD) {
        best = s;
        bestD = d;
      }
    }
    return best;
  }

  /// Moves [car] to a free kerb slot near where it stands, or near
  /// [buildingSlot]'s access, and answers whether it found one (§7.5's
  /// shuffle and relocations: a parked-car move, never a teleport onto the
  /// carriageway).
  bool _toKerb(int car, int buildingSlot) {
    if (!parked.isLive(car)) return false;
    final i = SlotPool.slotOf(car);
    var edge = -1;
    var t = 0.0;
    var side = 1;
    if (parked.where[i] == CarWhere.kerb.index && parked.slot[i] >= 0) {
      final s = parked.slot[i];
      edge = kerbs.slotEdge(s);
      t = kerbs.slotT(s);
      side = kerbs.slotSide(s);
    } else {
      final r = _accessRowOf(buildingSlot);
      if (r < 0) return false;
      edge = buildings.accEdge[r];
      t = buildings.accT[r].toDouble();
      side = buildings.accBits[r] & kAccLeft == 0 ? 1 : 0;
    }
    if (edge < 0) return false;
    final slot = kerbs.nearestFree(edge, t, side);
    if (slot < 0) return false;
    parked.moveToKerb(car, kerbs.slotEdge(slot), slot, kerbs.slotSide(slot));
    kerbs.occupy(slot, car);
    _siteState = true;
    return true;
  }

  /// The first access row of building slot [buildingSlot], or −1.
  int _accessRowOf(int buildingSlot) {
    if (buildingSlot < 0 || buildingSlot >= buildings.highWater) return -1;
    if (!buildings.isSlotLive(buildingSlot)) return -1;
    final base = BuildingTable.accRow0(buildingSlot);
    for (var k = 0; k < buildings.accCount[buildingSlot]; k++) {
      if (buildings.accEdge[base + k] >= 0) return base + k;
    }
    return -1;
  }

  // ---- Kerb cars across a rebuild, and across a save (§14.1) -------------------

  /// The pose of a car standing on kerb slot [slot] of [g]: its lane's line
  /// at the slot's arc, with the lane's own offset, and the way that lane
  /// travels. No trigonometry (D27): a direction, not an angle.
  bool _kerbPose(LaneGraph g, int slot, Float64List out, int o) {
    if (slot < 0 || slot >= kerbs.slotCount) return false;
    final lane = kerbs.slotLane(slot);
    if (lane < 0 || lane >= g.laneCount) return false;
    final e = g.laneEdge[lane];
    final t = kerbs.slotT(slot);
    final ahead = t + 0.25 <= g.edgeLen[e];
    RouteCost.pointOn(g, e, t, _pt, 0);
    RouteCost.pointOn(g, e, ahead ? t + 0.25 : t - 0.25, _pt, 2);
    var de = _pt[2] - _pt[0], dn = _pt[3] - _pt[1];
    if (!ahead) {
      de = -de;
      dn = -dn;
    }
    final l = math.sqrt(de * de + dn * dn);
    if (l < 1e-9) return false;
    final ue = de / l, un = dn / l;
    final off = g.laneOff[lane].toDouble();
    out[o] = _pt[0] + un * off;
    out[o + 1] = _pt[1] - ue * off;
    out[o + 2] = ue;
    out[o + 3] = un;
    return true;
  }

  /// The free kerb slot nearest (e, n) within [kKerbSnapM] whose lane runs
  /// within [kKerbSnapCos] of (dirE, dirN), or −1 (§14.1's re-snap rule).
  /// Ties go to the lower slot, so two machines place a car alike.
  int _snapKerb(double e, double n, double dirE, double dirN) {
    final g = lg;
    if (g == null) return -1;
    var best = -1;
    var bestD = kKerbSnapM * kKerbSnapM;
    for (var s = 0; s < kerbs.slotCount; s++) {
      if (!kerbs.isFree(s)) continue;
      if (!_kerbPose(g, s, _pose4, 0)) continue;
      if (_pose4[2] * dirE + _pose4[3] * dirN < kKerbSnapCos) continue;
      final de = _pose4[0] - e, dn = _pose4[1] - n;
      final d = de * de + dn * dn;
      if (d >= bestD) continue;
      best = s;
      bestD = d;
    }
    return best;
  }

  /// Where each kerb car stands on the graph that is going, before its slots
  /// are numbered afresh.
  void _captureKerbCars(LaneGraph old) {
    _movedCount = 0;
    for (var i = 0; i < parked.pool.highWater; i++) {
      if (!parked.pool.isSlotLive(i)) continue;
      if (parked.where[i] != CarWhere.kerb.index) continue;
      if (_movedCount >= _movedCar.length) {
        final n = _movedCar.isEmpty ? 16 : _movedCar.length * 2;
        _movedCar = Int32List(n)..setRange(0, _movedCount, _movedCar);
        _movedPose = Float64List(4 * n)
          ..setRange(0, 4 * _movedCount, _movedPose);
      }
      if (!_kerbPose(old, parked.slot[i], _movedPose, 4 * _movedCount)) {
        continue;
      }
      _movedCar[_movedCount] = parked.pool.handleOf(i);
      _movedCount++;
    }
  }

  /// The cars [_captureKerbCars] remembered, put back on the kerbs as they
  /// are now: the nearest free slot within 12 m and 45°, else garaged.
  void _replaceKerbCars() {
    for (var k = 0; k < _movedCount; k++) {
      final car = _movedCar[k];
      if (!parked.isLive(car)) continue;
      final o = 4 * k;
      final slot = _snapKerb(
          _movedPose[o], _movedPose[o + 1], _movedPose[o + 2], _movedPose[o + 3]);
      if (slot < 0) {
        parked.moveToGarage(car);
        siteStats.garaged++;
        siteStats.siteGarages++;
        continue;
      }
      parked.moveToKerb(car, kerbs.slotEdge(slot), slot, kerbs.slotSide(slot));
      kerbs.occupy(slot, car);
    }
    _movedCount = 0;
  }

  // ---- The save (§14.1) -------------------------------------------------------

  @override
  String? siteIdOf(int car) {
    if (!parked.isLive(car)) return null;
    final b = parked.building[SlotPool.slotOf(car)];
    if (b < 0 || b >= buildings.highWater || !buildings.isSlotLive(b)) {
      return null;
    }
    final id = buildings.siteId[b];
    return id.isEmpty ? null : id;
  }

  @override
  bool kerbPoseOf(int car, Float64List out) {
    final g = lg;
    if (g == null || !parked.isLive(car)) return false;
    final i = SlotPool.slotOf(car);
    if (!_kerbPose(g, parked.slot[i], _pose4, 0)) return false;
    out[0] = _pose4[0];
    out[1] = _pose4[1];
    // Only here, and on the way back: a heading is an angle in the save and a
    // direction everywhere else (D27 keeps the sub-step free of trig).
    out[2] = math.atan2(_pose4[3], _pose4[2]);
    return true;
  }

  // ---- The load (§14.1's order) -----------------------------------------------

  void _placeSavedCars(SavedAgents saved) {
    _restoring = saved;
    AgentsCodec.restoreCars(saved, this);
    _restoring = null;
    if (parked.count > 0) _siteState = true;
  }

  @override
  int rowOfSite(String siteId) {
    final h = buildings.handleOfSite(siteId);
    return h == null ? -1 : sites.rowOfBuilding(SlotPool.slotOf(h));
  }

  @override
  int stallOfKey(int row, int stallKey) {
    final s = sites.stallIndexOfKey(row, stallKey);
    return s >= 0 && !sites.stallTaken(row, s) ? s : -1;
  }

  @override
  int nearestFreeStall(int row, int stallKey) =>
      _nearestFreeStall(row, stallKey);

  @override
  void parkLot(int car, int row, int stall) {
    final s = _restoring;
    if (s == null || !sites.isRowLive(row)) return;
    final p = sites.plan[row];
    final key = p != null && stall < p.stallCount ? p.stallKey(stall) : 0;
    final made = parked.parkLot(
        building: sites.building[row],
        row: row,
        stall: stall,
        stallKey: key,
        ownerKind: CarOwnerKind.values[s.cars.ownerKind[car]],
        owner: s.cars.owner[car],
        kind: s.cars.kind[car],
        variant: s.cars.variant[car]);
    if (made == SlotPool.none) return;
    sites.occupy(row, stall, made);
    _wakeRestored(made, sites.building[row]);
  }

  @override
  bool parkKerb(int car) {
    final s = _restoring;
    if (s == null) return false;
    // A heading in the save, a direction here (D27).
    final a = s.cars.heading[car];
    final slot = _snapKerb(s.cars.e[car], s.cars.n[car], math.cos(a),
        math.sin(a));
    if (slot < 0) return false;
    final made = parked.parkKerb(
        building: -1,
        edge: kerbs.slotEdge(slot),
        slot: slot,
        side: kerbs.slotSide(slot),
        ownerKind: CarOwnerKind.values[s.cars.ownerKind[car]],
        owner: s.cars.owner[car],
        kind: s.cars.kind[car],
        variant: s.cars.variant[car]);
    if (made == SlotPool.none) return false;
    kerbs.occupy(slot, made);
    _wakeRestored(made, -1);
    return true;
  }

  @override
  void garage(int car, int row) {
    final s = _restoring;
    if (s == null) return;
    final b = sites.isRowLive(row) ? sites.building[row] : -1;
    final made = parked.garage(
        building: b,
        ownerKind: CarOwnerKind.values[s.cars.ownerKind[car]],
        owner: s.cars.owner[car],
        kind: s.cars.kind[car],
        variant: s.cars.variant[car]);
    if (made != SlotPool.none) _wakeRestored(made, b);
  }

  /// A restored car that belongs to a COMMUTER is a commuter at work: it
  /// wakes on this side of the return window and drives home in that car
  /// (§0 Q3, §14.3 — agents in flight are never saved). Its home is the
  /// building handle the car carries as its opaque owner, which a colony
  /// loaded from its own save resolves because the building table is rebuilt
  /// from the same layout in the same order. A home that no longer answers
  /// leaves the car standing where it is.
  void _wakeRestored(int car, int buildingSlot) {
    final i = SlotPool.slotOf(car);
    if (parked.ownerKind[i] != CarOwnerKind.commuter.index) return;
    final home = parked.owner[i];
    if (home < 0 || !buildings.isLive(home) || buildingSlot < 0) return;
    final job = buildings.handleOf(buildingSlot);
    if (job == home) return;
    commutes.restoreAtWork(home, job, car);
  }

  /// See [CityAgents.collectSiteBuffers].
  void collectSiteBuffers(Map<String, Object> into) {
    sites.collectBuffers(into, 'sites');
    siteCols.collectBuffers(into, 'siteCols');
    events.collectBuffers(into, 'events');
    parked.collectBuffers(into, 'parked');
    kerbs.collectBuffers(into, 'kerbs');
    siteMover.collectBuffers(into, 'siteMover');
    into['core.kerbFor'] = _kerbFor;
    into['core.gaveUp'] = _gaveUp;
    into['core.siteReplan'] = _siteReplan;
  }

  // ---- Development hooks ------------------------------------------------------

  /// See [CityAgents.debugDepart].
  int debugDepart(int car) {
    prime();
    if (!parked.isLive(car)) return SlotPool.none;
    final i = SlotPool.slotOf(car);
    final b = parked.building[i];
    if (b < 0 || b >= buildings.highWater || !buildings.isSlotLive(b)) {
      return SlotPool.none;
    }
    final from = buildings.handleOf(b);
    final to = buildings.drawJob(commutes.rng, except: b);
    if (to < 0 || to == from) return SlotPool.none;
    return commutes.force(from, to, car: car);
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
    // The sites, the cars and the kerbs (§7.8 item 11). Folded only once the
    // colony has site state of any kind, so a colony with no plans and
    // nothing parked digests exactly as it did before T4a.
    if (_siteState) {
      h = sites.digest(h);
      h = parked.digest(h);
      h = kerbs.digest(h);
      h = siteCols.digest(h, table);
      h = siteMover.digest(h);
      h = events.digest(h);
      h = siteStats.digest(h);
      for (var sl = 0; sl < table.highWater; sl++) {
        if (table.isSlotLive(sl) && _kerbFor[sl] >= 0) {
          h = fnv1aU32(h, sl);
          h = fnv1aU32(h, _kerbFor[sl]);
        }
      }
    }
    return h;
  }

  /// [hash] with [x] folded in to the thousandth.
  static int _milli(int hash, double x) => fnv1aU32(hash, (x * 1000).round());

  /// [hash] with [x] folded in whole, both halves of it: agent microseconds
  /// pass 2³² after an hour and a quarter.
  static int _wide(int hash, int x) =>
      fnv1aU32(fnv1aU32(hash, x & 0xFFFFFFFF), x ~/ 0x100000000);
}

/// The site mover as the planner's [StallDepartures]: one call, named
/// twice, so trip_planner.dart need not import the mover that imports it.
final class _StallSpawns implements StallDepartures {
  _StallSpawns(this.mover);

  final SiteMover mover;

  @override
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
          required double freeFlowS}) =>
      mover.spawnFromStall(
        row: row,
        stall: stall,
        join: join,
        kind: kind,
        variant: variant,
        ownerKind: ownerKind,
        owner: owner,
        route: route,
        n: n,
        originT: originT,
        destT: destT,
        nowUs: nowUs,
        speedFactor: speedFactor,
        freeFlowS: freeFlowS,
      );
}

/// What stands between a stall and the drive, read off the plan
/// (parked_cars.dart's [TandemStalls]; site-access.md §7.5).
///
/// Only a home pad ever has one: its `inline` stalls lie ALONG the drive, so
/// a stall nearer the street — a smaller arc on the same segment — is a car
/// the one behind it cannot get past. Every other program parks off an aisle,
/// where each stall reaches the drive on its own. The nearest such stall is
/// the blocker, and a pad is at most two deep (§3.4), so there is only one.
final class _TandemPlan implements TandemStalls {
  _TandemPlan(this.sites);

  final SiteTable sites;

  @override
  int blockerOf(int row, int stall) {
    if (!sites.isRowLive(row) || stall < 0) return -1;
    final SiteAccessPlan? p = sites.plan[row];
    if (p == null || p.program != SiteProgram.homeDriveway) return -1;
    if (stall >= p.stallCount) return -1;
    final seg = p.stallSeg(stall), s = p.stallS(stall);
    var best = -1;
    var bestS = 0.0;
    for (var i = 0; i < p.stallCount; i++) {
      if (i == stall || p.stallSeg(i) != seg) continue;
      final si = p.stallS(i);
      if (si >= s) continue;
      if (best < 0 || si > bestS) {
        best = i;
        bestS = si;
      }
    }
    return best;
  }
}
