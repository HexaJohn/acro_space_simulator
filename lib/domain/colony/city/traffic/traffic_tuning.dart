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
  /// sub-step and never on a question.
  ///
  /// Sized by §15.1's frame gates (readout_pass_bench_test, JIT test VM,
  /// the 2-mile sprawl): a unit costs 25–40 ns, so the 24,000 first shipped
  /// took 0.6–1.1 ms a sub-step, and a 25× held frame of four sub-steps,
  /// the rest of the agents' work included, read 3.9–4.8 ms at p99 — over
  /// the 3.2 ms gate. At 8,000 that frame stayed under 2.8 ms and a 1×
  /// frame under 1.5 ms in every frame measured. A pass gets 80,000 units
  /// an epoch: that sprawl's pass (about 190,000) publishes every third
  /// picture.
  static int readoutWorkPerStep = 8000;

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

  // ---- Sites: the arrival gate, departures and the home back-out ----------
  //
  // Slice T4a (site-access.md §7.4, §7.5; docs/plans/t4a-implementation.md
  // §1.8). Added once and frozen: the site mover, the gate and the kerb
  // slots read these, never literals of their own.

  /// The arrival gate (§7.4 steps 3–4): the fastest a car may be to be
  /// granted the turn in (G3, m/s); the seconds refused after which the
  /// far-side ETA test is waived (a forced grant, counted); and the seconds
  /// refused — whatever refused it, since the forced grant never waives a
  /// body — after which the car gives the stall up and looks for a kerb slot
  /// (D17 step 2). The give-up must stay the later of the two, or no car
  /// would ever get the forced grant it is waiting for.
  static double gateMaxMps = 3;
  static double gateForcedS = 25;
  static double gateGiveUpS = 30;

  /// A forward-out departure stops with its front this far inside the kerb
  /// line (`throatWait`, §7.4 step 4, ROAD's `kSiteThroatStopM`), and accrues
  /// stuck time there only after this many seconds (step 6).
  static double throatStopM = 1;
  static double throatStuckAfterS = 60;

  /// Home back-out gap acceptance (§7.4): the ETA an approaching vehicle in
  /// the target lane must be at least (s), the far lane's for a
  /// far-direction departure, the floor the forced grant waives them to,
  /// and the seconds refused before that forced grant (never with a body in
  /// the footprint).
  static double backOutEtaS = 8;
  static double backOutFarEtaS = 10;
  static double backOutEtaFloorS = 6;
  static double backOutForcedS = 120;

  /// The seconds a home car waits in its stall before it gives the
  /// departure up altogether (§7.5): the forced grant never waives a body in
  /// the footprint, so a driveway blocked by something that does not move
  /// would otherwise hold the car — and its owner's leg — for ever. Five
  /// minutes: long past the forced grant, which by then has had three
  /// minutes of waived ETA to find a gap in any street that has one.
  static double backOutGiveUpS = 300;

  /// Home back-out geometry (§7.4), metres from the join's `T` on the target
  /// lane: the footprint runs [backOutUpM] upstream (the tail swing) to
  /// [backOutDownM] downstream; no vehicle may be stopped or queued within
  /// [backOutQueueM] upstream of it; the opposing and adjacent lanes are
  /// checked within ±[backOutSideM]. The reverse is no faster than
  /// [backOutMaxMps].
  static double backOutUpM = 10;
  static double backOutDownM = 2;
  static double backOutQueueM = 15;
  static double backOutSideM = 6;
  static double backOutMaxMps = 2;

  /// The stop to shift from reverse to drive once a back-out is in its lane
  /// (s), and the seconds a deep tandem car waits blocked before the outer
  /// car is shuffled to a kerb slot (§7.5).
  static double shiftStopS = 0.5;
  static double tandemShuffleS = 120;

  /// D17 step 2's reach: kerb slots ahead on the arrival edge within this
  /// many metres (§7.5). A site change snaps a car moving inside a site to
  /// the nearest new site lane within [siteSnapM] metres whose direction is
  /// within the angle of cosine [siteSnapCos] (60°) of its own (§7.6).
  static double kerbAheadM = 60;
  static double siteSnapM = 3;
  static double siteSnapCos = 0.5;

  // ---- Measurement ------------------------------------------------------------

  /// Agent seconds between published delay tables (§4.2). A search prices
  /// every edge from the table it started with.
  static double congestionEpochS = 2.0;

  /// The window of the congestion index's EMA, agent seconds (§4.2): the
  /// HUD's Flow is one minus the index.
  static double congestionWindowS = 60;

  /// Vehicles one lane carries a minute at free flow (§12.3's
  /// `laneFlowPerMin`): the flow at which a piece's measured load, and so
  /// its traffic noise, is full — a piece of `lanes` lanes carrying
  /// `lanes × laneFlowPerMin` vehicles a minute both ways.
  static double laneFlowPerMin = 30;

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
    readoutWorkPerStep = 8000;
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
    gateMaxMps = 3;
    gateForcedS = 25;
    gateGiveUpS = 30;
    throatStopM = 1;
    throatStuckAfterS = 60;
    backOutEtaS = 8;
    backOutFarEtaS = 10;
    backOutEtaFloorS = 6;
    backOutForcedS = 120;
    backOutGiveUpS = 300;
    backOutUpM = 10;
    backOutDownM = 2;
    backOutQueueM = 15;
    backOutSideM = 6;
    backOutMaxMps = 2;
    shiftStopS = 0.5;
    tandemShuffleS = 120;
    kerbAheadM = 60;
    siteSnapM = 3;
    siteSnapCos = 0.5;
    congestionEpochS = 2.0;
    congestionWindowS = 60;
    laneFlowPerMin = 30;
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
        'gateMaxMps': gateMaxMps,
        'gateForcedS': gateForcedS,
        'gateGiveUpS': gateGiveUpS,
        'throatStopM': throatStopM,
        'throatStuckAfterS': throatStuckAfterS,
        'backOutEtaS': backOutEtaS,
        'backOutFarEtaS': backOutFarEtaS,
        'backOutEtaFloorS': backOutEtaFloorS,
        'backOutForcedS': backOutForcedS,
        'backOutGiveUpS': backOutGiveUpS,
        'backOutUpM': backOutUpM,
        'backOutDownM': backOutDownM,
        'backOutQueueM': backOutQueueM,
        'backOutSideM': backOutSideM,
        'backOutMaxMps': backOutMaxMps,
        'shiftStopS': shiftStopS,
        'tandemShuffleS': tandemShuffleS,
        'kerbAheadM': kerbAheadM,
        'siteSnapM': siteSnapM,
        'siteSnapCos': siteSnapCos,
        'congestionEpochS': congestionEpochS,
        'congestionWindowS': congestionWindowS,
        'laneFlowPerMin': laneFlowPerMin,
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
