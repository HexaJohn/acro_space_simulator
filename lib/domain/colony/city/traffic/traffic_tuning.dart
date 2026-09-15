// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Every number the agent simulation is tuned by, in one place.
///
/// Statics with defaults rather than constants, so the perf panel's knobs
/// (E24) and the tests can turn them; one class, so a twin run can be sure it
/// turned the same ones. Only SIMULATION values live here — values that
/// change what happens, which two runs compared for determinism must
/// therefore share (docs/plans/agent-traffic.md §15.4). How agents are drawn
/// is the renderer's business and lives in its own statics. The scheduling
/// values at the end change only WHEN work runs, never what it computes.
///
/// Every budget is counted, never timed (D9): expansions, agents, sub-steps.
/// A limit read off the wall clock would make the simulation's result depend
/// on the machine it ran on.
library;

/// The agent simulation's tunables. [reset] restores every default.
class AgentTuning {
  AgentTuning._();

  // ---- Exposure --------------------------------------------------------------

  /// The A/B switch (`--knob=agentsOn`). A colony's own flag says where agents
  /// run; this says whether they run anywhere.
  static bool agentsOn = true;

  // ---- Budgets and caps (§4.8, §6.5) -------------------------------------

  /// Node or state expansions the path pump may spend per sub-step, shared by
  /// its search contexts. A search that runs out resumes on the next one.
  static int pathExpansionsPerStep = 4000;

  /// Work units the readout's pass — reach, noise, land value (§12.3) — may
  /// do per sub-step, in the routed model's own units
  /// (`TrafficTuning.workPerStep`): a label settled, an edge relaxed, a
  /// building, a road or a lot looked at, an index cell or road segment the
  /// noise sampler measured. §12.3 runs reach "through the path budget's
  /// skim lane", which §4.8 serves only when the queue is otherwise empty
  /// and gives no share; a busy colony would never publish. So the pass has
  /// a budget of its own, counted like every other (D9), spent in the
  /// sub-step and never on a question: never more per colony tick at the
  /// 25× clamp's 2.5 sub-steps than the routed model's 60,000 a tick, whose
  /// work it takes over (E3a), and a pass of 240,000 an epoch.
  static int readoutWorkPerStep = 24000;

  /// The pedestrian searches' own budget (slice 4).
  static int pedExpansionsPerStep = 1500;

  /// Vehicles alive at once. Past it, car trips wait at their origin.
  static int maxVehicles = 4096;

  /// The share of [maxVehicles] held back for service, transit and freight
  /// vehicles, so a car jam can never stop the garbage trucks leaving.
  static double serviceReserveShare = 0.10;

  /// Pedestrians alive at once (slice 4).
  static int maxPeds = 4096;

  /// Car-trip path requests queued at once. Past it, trips are deferred.
  static int maxQueuedPaths = 512;

  /// The reserved lane's own queue cap: service, transit and freight.
  static int maxQueuedServicePaths = 128;

  /// Vehicles (and, separately, pedestrians) spawned per sub-step. The rest
  /// wait for the next sub-step, in queue order.
  static int maxSpawnsPerStep = 24;

  /// Agent seconds over which a fresh or restored colony ramps
  /// [maxSpawnsPerStep] up from 0, so a load does not spawn a burst.
  static double warmupS = 10;

  // ---- Movement and junctions (§5) ----------------------------------------

  /// Agent seconds without progress before a driving vehicle is despawned:
  /// despawning hides mistakes, and a wedge must not stand for ever. A
  /// knob, 30–600. Frozen while dwelling or held for a re-plan.
  static double stuckDespawnS = 120;

  /// Seconds at a stop line before the gap rules' ETA test is waived — the
  /// deadlock breaker. An occupied conflict still holds the vehicle.
  static double impatientGrantS = 25;

  /// Whether a junction is entered only with room to leave it.
  static bool dontBlockBox = true;

  /// The wedge breaker: when [wedgeHeads] approach heads at one node have
  /// each waited past [wedgeWaitS], the longest waiter is despawned.
  static double wedgeWaitS = 60;
  static int wedgeHeads = 3;

  /// Vehicles an all-way stop's arrival queue holds.
  static int allWayStopQueueCap = 16;

  /// Element hand-overs one vehicle may make in one sub-step: enough for
  /// short connectors at the fastest limit.
  static int maxHandOversPerStep = 4;

  // ---- Measurement ------------------------------------------------------------

  /// Agent seconds between published delay tables (§4.2). A search prices
  /// every edge from the table it started with.
  static double congestionEpochS = 2.0;

  /// The window of the congestion index's EMA, agent seconds (§4.2): the
  /// HUD's Flow is one minus the index.
  static double congestionWindowS = 60;

  /// Agent seconds between incremental building syncs (§2.6).
  static double buildingSyncS = 2.0;

  // ---- Demand (slices 1–2: CommuteSynth) and what later slices add ---------

  /// Outbound car commutes per resident per agent second: 60% employed ×
  /// 75% with a car × 85% driving, over a 915 s cycle (§6.5).
  static double commuteRatePerResident = 0.00042;

  /// The dwell at work before the commute home, U(min, max) agent seconds.
  static double commuteReturnMinS = 240;
  static double commuteReturnMaxS = 540;

  /// Scales every activity dwell (slice 3); calibrated so moving vehicles
  /// are 8–12% of population.
  static double activityDwellScale = 1.0;

  /// The share of car owners' errands that leave the map (slice 8).
  static double outOfTownShare = 0.08;

  /// Dispatch by path cost instead of CS1's straight line (slice 5): off,
  /// so a badly placed depot floods its district, by design.
  static bool dispatchByPathCost = false;

  /// Freight moves money (slice 8, once its balance test lands).
  static bool freightEconomy = false;

  /// § per vehicle-second on the road, from slice 8.
  static double fleetUpkeep = 0.02;

  /// Whether outside connections carry migration (slice 8).
  static bool connectionsAllowMigration = false;

  /// Freight trains (slice 9b).
  static bool freightRail = false;

  // ---- The graph ------------------------------------------------------------------

  /// Roads above which the lane graph is built resumably, a phase at a time
  /// across advances, instead of inline (§3.8).
  static int graphBuildInlineMaxRoads = 3000;

  // ---- Scheduling: when ticks run, never what they compute (§5.7) ---------

  /// Agent sub-steps a frame-budgeted colony runs per UI frame, give or
  /// take a tick: what a frame leaves unspent carries to the next, and a
  /// backlog adds its share, never more than one tick's worth together
  /// (`CityAgents.endFrame`). Further ticks queue whole and replay on later
  /// frames.
  static int maxAgentSubStepsPerFrame = 4;

  /// Colony seconds the frame hold may queue: a frame runs whatever is held
  /// past it — a hitch, never a dropped tick — so a held colony is never
  /// further behind the world than this. Above the 12.5 s the host's
  /// catch-up frame owes at 25× (25 ticks of 0.5 s) and the tick or two a
  /// slower host keeps waiting, so that frame is spread over the frames
  /// after it by the budget rather than run on the spot.
  static double maxHeldCityS = 15;

  /// Restores every default. Tests that turn a knob call it in `tearDown`,
  /// since statics outlive the test that set them.
  static void reset() {
    agentsOn = true;
    pathExpansionsPerStep = 4000;
    readoutWorkPerStep = 24000;
    pedExpansionsPerStep = 1500;
    maxVehicles = 4096;
    serviceReserveShare = 0.10;
    maxPeds = 4096;
    maxQueuedPaths = 512;
    maxQueuedServicePaths = 128;
    maxSpawnsPerStep = 24;
    warmupS = 10;
    stuckDespawnS = 120;
    impatientGrantS = 25;
    dontBlockBox = true;
    wedgeWaitS = 60;
    wedgeHeads = 3;
    allWayStopQueueCap = 16;
    maxHandOversPerStep = 4;
    congestionEpochS = 2.0;
    congestionWindowS = 60;
    buildingSyncS = 2.0;
    commuteRatePerResident = 0.00042;
    commuteReturnMinS = 240;
    commuteReturnMaxS = 540;
    activityDwellScale = 1.0;
    outOfTownShare = 0.08;
    dispatchByPathCost = false;
    freightEconomy = false;
    fleetUpkeep = 0.02;
    connectionsAllowMigration = false;
    freightRail = false;
    graphBuildInlineMaxRoads = 3000;
    maxAgentSubStepsPerFrame = 4;
    maxHeldCityS = 15;
  }

  /// Every tunable by name, as it stands: what two runs compare to prove they
  /// shared their tuning, and what the tuning test compares to prove [reset]
  /// misses nothing.
  static Map<String, Object> snapshot() => {
        'agentsOn': agentsOn,
        'pathExpansionsPerStep': pathExpansionsPerStep,
        'readoutWorkPerStep': readoutWorkPerStep,
        'pedExpansionsPerStep': pedExpansionsPerStep,
        'maxVehicles': maxVehicles,
        'serviceReserveShare': serviceReserveShare,
        'maxPeds': maxPeds,
        'maxQueuedPaths': maxQueuedPaths,
        'maxQueuedServicePaths': maxQueuedServicePaths,
        'maxSpawnsPerStep': maxSpawnsPerStep,
        'warmupS': warmupS,
        'stuckDespawnS': stuckDespawnS,
        'impatientGrantS': impatientGrantS,
        'dontBlockBox': dontBlockBox,
        'wedgeWaitS': wedgeWaitS,
        'wedgeHeads': wedgeHeads,
        'allWayStopQueueCap': allWayStopQueueCap,
        'maxHandOversPerStep': maxHandOversPerStep,
        'congestionEpochS': congestionEpochS,
        'congestionWindowS': congestionWindowS,
        'buildingSyncS': buildingSyncS,
        'commuteRatePerResident': commuteRatePerResident,
        'commuteReturnMinS': commuteReturnMinS,
        'commuteReturnMaxS': commuteReturnMaxS,
        'activityDwellScale': activityDwellScale,
        'outOfTownShare': outOfTownShare,
        'dispatchByPathCost': dispatchByPathCost,
        'freightEconomy': freightEconomy,
        'fleetUpkeep': fleetUpkeep,
        'connectionsAllowMigration': connectionsAllowMigration,
        'freightRail': freightRail,
        'graphBuildInlineMaxRoads': graphBuildInlineMaxRoads,
        'maxAgentSubStepsPerFrame': maxAgentSubStepsPerFrame,
        'maxHeldCityS': maxHeldCityS,
      };
}
