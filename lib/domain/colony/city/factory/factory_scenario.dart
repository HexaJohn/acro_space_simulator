// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Guided scenarios on a factory floor: a starting hall, what the colony
/// will deliver, a tutorial that teaches the loop, and open goals after it
/// (docs/plans/factory-floors.md §4).
///
/// The floor systems (docks, belts, arms, handlers, load classes) are all
/// built, but a player dropped into an empty hall has no way to learn them
/// except by reading the code. A scenario is the smallest thing that fixes
/// that WITHOUT changing the floor: it only READS the floor through the
/// same [FactorySim] view the editor draws from (placements, recipes,
/// belt items, handlers, `contentsOf`, `statusOf`, the lifetime ledger),
/// and it only touches the colony side through its own
/// [ScenarioColonyPort]. So a step's check can never pass on something the
/// player can't see on screen, and a tutorial can't paper over a floor bug:
/// if the engine misbehaves, the step simply never completes.
///
/// **Determinism.** Pure Dart, no clock, no RNG. Everything is keyed by the
/// floor's own `simSeconds` and by the order calls arrive in, so a test that
/// drives the same edits and steps gets the same progress bit for bit.
///
/// **Who calls what.** The host (the editor's tutorial panel, or a test)
/// steps the floor, then calls [ScenarioRunner.update] with it. UI events
/// the floor can't see (Recipe info opened on an item, an overlay switched
/// on) come in through [ScenarioRunner.noteRecipeInfo] and
/// [ScenarioRunner.noteBottlenecks]. ([ScenarioRunner.noteProductTree] is
/// still recorded, for the debug-only product tree, but no step reads it:
/// a game mode never shows the full tree, docs/plans/factory-floors.md §10
/// item 15.)
library;

import 'dart:collection';

import 'factory_catalog.dart';
import 'factory_colony_port.dart';
import 'factory_entities.dart';
import 'factory_grid.dart';
import 'factory_item.dart';
import 'factory_recipe.dart';
import 'factory_sim_api.dart';
import 'floor_blueprint.dart';
import 'templates/rocketfactory_template.dart';

/// Slop for sim-second comparisons (0.25 s sub-steps are exact in binary,
/// but rates divide by sums of them).
const double _eps = 1e-9;

// ---------------------------------------------------------------------------
// Supply
// ---------------------------------------------------------------------------

/// The colony side of a scenario floor: receiving docks get only what the
/// scenario supplies, and shipping never fills.
///
/// A sandbox ([InfiniteColonyPort]) hands a dock anything, which would let a
/// player skip the chain the scenario is about (an "ore only" challenge
/// means nothing if a tube dock still works). So [take] grants a commodity
/// only while it is on [supply] — unlimited, like the sandbox — and for one
/// that is not, grants nothing and records it in [refused], so the UI can
/// say "this dock's item isn't supplied in this scenario" instead of the
/// player watching a dock that silently never unloads. Every [give] is
/// accepted and tallied: a scenario is about making, not storage caps.
class ScenarioColonyPort implements FactoryColonyPort {
  ScenarioColonyPort(Iterable<String> supply) : _supply = SplayTreeSet.of(supply);

  final SplayTreeSet<String> _supply;

  /// Commodities taken and given, by commodity (sorted maps: a readout
  /// lists them in the same order every frame).
  final SplayTreeMap<String, double> taken = SplayTreeMap();
  final SplayTreeMap<String, double> given = SplayTreeMap();

  /// Refused [take] calls by commodity. A receiving dock asks once per
  /// sub-step while its tile has room, so this counts sub-steps spent
  /// waiting on an unsupplied item, not units.
  final SplayTreeMap<String, int> refused = SplayTreeMap();

  /// The commodities receiving docks may deliver right now (sorted).
  Set<String> get supply => UnmodifiableSetView(_supply);

  /// Replaces the supply list (a scenario's "ore only" challenge).
  void setSupply(Iterable<String> commodities) {
    _supply
      ..clear()
      ..addAll(commodities);
  }

  bool supplies(String commodity) => _supply.contains(commodity);

  @override
  double take(String commodity, double units) {
    if (!(units > 0)) return 0;
    if (!_supply.contains(commodity)) {
      refused[commodity] = (refused[commodity] ?? 0) + 1;
      return 0;
    }
    taken[commodity] = (taken[commodity] ?? 0) + units;
    return units;
  }

  @override
  double give(String commodity, double units) {
    if (!(units > 0)) return 0;
    given[commodity] = (given[commodity] ?? 0) + units;
    return units;
  }

  @override
  double get powerShare => 1;
  @override
  double get staffingShare => 1;
}

/// A named supply list the player can switch to mid-scenario.
class SupplyOption {
  const SupplyOption(
      {required this.id, required this.label, required this.commodities});
  final String id;
  final String label;
  final Set<String> commodities;
}

// ---------------------------------------------------------------------------
// Steps and goals
// ---------------------------------------------------------------------------

/// What on screen a hint points at. The editor maps each to a palette
/// entry, roster row or header button and pulses its border; the domain
/// only names it, so a scenario never depends on a widget key.
enum ScenarioHintTarget {
  receivingDock,
  shippingDock,
  belt,
  arm,
  assembler,
  craneBay,
  walker,
  palletJack,
  crane,
  bottlenecks,

  /// The debug-only full product tree (no shipped step points here).
  productTree,

  /// The in-game Recipe info panel (direct components / raw total).
  recipeInfo,
}

/// Where to look for the tool a step needs, and which on-screen controls
/// to pulse.
class ScenarioHint {
  const ScenarioHint(this.text, [this.targets = const {}]);
  final String text;
  final Set<ScenarioHintTarget> targets;
}

/// Whether a step is done, read from the floor only (see the library doc).
typedef StepCheck = bool Function(FactorySim sim, ScenarioProgress p);

class TutorialStep {
  const TutorialStep({
    required this.id,
    required this.title,
    required this.body,
    this.hint,
    this.check,
  });

  /// Stable within a scenario (progress keys completions by it).
  final String id;
  final String title;

  /// Plain and concrete: what to do and why it matters, 1-3 sentences.
  final String body;
  final ScenarioHint? hint;

  /// Null: a reading step that completes on Next.
  final StepCheck? check;

  bool get manual => check == null;
}

/// One goal's state right now.
class GoalReading {
  const GoalReading(
      {required this.progress, required this.status, required this.met});

  /// 0..1, for a progress bar.
  final double progress;

  /// "12 / 20 shipped", "0.31 / 0.40 per s" …
  final String status;

  /// The goal's condition holds at this instant (the runner latches it).
  final bool met;
}

typedef GoalRead = GoalReading Function(FactorySim sim, ScenarioProgress p);

class ScenarioGoal {
  const ScenarioGoal({
    required this.id,
    required this.title,
    required this.detail,
    required this.read,
    this.optional = false,
  });
  final String id;
  final String title;
  final String detail;
  final GoalRead read;

  /// A challenge, not part of "the plant works".
  final bool optional;
}

/// A guided start: the hall, what docks can receive, the tutorial, the
/// goals after it.
class FactoryScenario {
  const FactoryScenario({
    required this.id,
    required this.title,
    required this.blueprint,
    required this.supply,
    required this.steps,
    required this.goals,
    required this.product,
    required this.targetRate,
    required this.rateWindowS,
    required this.jobCap,
    this.supplyOptions = const [],
    this.freePlayTitle = 'Free play',
    this.freePlayBody = '',
  });

  final String id;
  final String title;

  /// A fresh copy of the starting layout each call.
  final FloorBlueprint Function() blueprint;

  /// Commodities receiving docks may deliver at the start.
  final Set<String> supply;

  /// Other supply lists the goal view offers (the first is the default).
  final List<SupplyOption> supplyOptions;
  final List<TutorialStep> steps;
  final List<ScenarioGoal> goals;

  /// The commodity the scenario is about, for the rate window.
  final String product;

  /// Units of [product] per sim second the rate goals ask for.
  final double targetRate;

  /// Sim seconds the rolling rate looks back over.
  final double rateWindowS;

  /// Most jobs the lean goal allows.
  final double jobCap;

  final String freePlayTitle;
  final String freePlayBody;
}

// ---------------------------------------------------------------------------
// Progress
// ---------------------------------------------------------------------------

/// Sim seconds between rate-window samples: one a second is far finer than
/// any station's cycle and keeps a 60 s window at ~60 samples.
const double kScenarioSampleS = 1.0;

/// Where a player is in a scenario. Plain data the runner mutates; a check
/// reads it (the UI flags) but never writes it.
class ScenarioProgress {
  /// Index of the current tutorial step. Equal to the step count once the
  /// tutorial is over (finished or skipped): goal mode.
  int step = 0;

  /// Products the player has opened the (debug) product tree on.
  final SplayTreeSet<String> treeItemsSeen = SplayTreeSet();

  /// Items the player has opened Recipe info on (the "Read the floor"
  /// step wants Rocket Parts here).
  final SplayTreeSet<String> recipeInfoSeen = SplayTreeSet();

  /// The Bottlenecks overlay has been switched on at least once.
  bool bottlenecksSeen = false;

  /// Sim second each step was completed at, by step id.
  final Map<String, double> stepDoneAt = {};

  /// Sim second each goal was first met at, by goal id.
  final Map<String, double> goalMetAt = {};

  /// Sim second goal mode began (null: still in the tutorial).
  double? goalStartS;

  /// Lifetime shipped totals when goal mode began (goals count from here,
  /// so what the tutorial line shipped is not free progress).
  Map<String, double> shippedAtGoalStart = const {};

  /// The supply option in force ([FactoryScenario.supplyOptions] id; null
  /// = the scenario's starting supply).
  String? supplyOptionId;

  /// When the current supply option was chosen, and the lifetime shipped
  /// totals then (a supply challenge counts from its own start).
  double? supplyChangedS;
  Map<String, double> shippedAtSupplyChange = const {};

  /// Recipes seen running ([MachineStatus.working]) on the floor since the
  /// current supply option was chosen: "did the player actually build the
  /// steel chain?" is answered from what ran, not from what was placed.
  final SplayTreeSet<String> recipesSeenWorking = SplayTreeSet();

  /// (sim second, lifetime shipped of the product) samples, oldest first.
  final List<(double, double)> samples = [];

  /// Total lifetime units of [commodity] shipped since goal mode began.
  double shippedSinceGoalStart(FactorySim sim, String commodity) =>
      (sim.lifetime.shipped[commodity] ?? 0) -
      (shippedAtGoalStart[commodity] ?? 0);

  /// Same, since the current supply option was chosen.
  double shippedSinceSupplyChange(FactorySim sim, String commodity) =>
      (sim.lifetime.shipped[commodity] ?? 0) -
      (shippedAtSupplyChange[commodity] ?? 0);

  /// Units per sim second over the last [windowS], or null until the
  /// samples cover a whole window (a 10 s burst is not a sustained rate).
  double? rollingRate(double windowS) {
    if (samples.isEmpty) return null;
    final (t1, v1) = samples.last;
    (double, double)? base;
    for (var i = samples.length - 1; i >= 0; i--) {
      if (samples[i].$1 <= t1 - windowS + _eps) {
        base = samples[i];
        break;
      }
    }
    if (base == null) return null;
    final dt = t1 - base.$1;
    return dt > 0 ? (v1 - base.$2) / dt : null;
  }
}

/// What one [ScenarioRunner.update] changed.
class ScenarioEvents {
  const ScenarioEvents(this.stepsDone, this.goalsMet);
  static const none = ScenarioEvents([], []);
  final List<String> stepsDone;
  final List<String> goalsMet;
  bool get isEmpty => stepsDone.isEmpty && goalsMet.isEmpty;
}

/// Drives one scenario on one floor: advances the tutorial when a step's
/// check passes, latches goals, keeps the rate window, owns the port.
class ScenarioRunner {
  ScenarioRunner(this.scenario, {ScenarioColonyPort? port})
      : port = port ?? ScenarioColonyPort(scenario.supply);

  final FactoryScenario scenario;
  final ScenarioColonyPort port;
  final ScenarioProgress progress = ScenarioProgress();

  /// The floor clock at the last call that saw the floor.
  double _simS = 0;

  bool get inGoals => progress.step >= scenario.steps.length;

  /// The step being shown, or null in goal mode.
  TutorialStep? get currentStep =>
      inGoals ? null : scenario.steps[progress.step];

  bool isDone(TutorialStep s) => progress.stepDoneAt.containsKey(s.id);

  /// Next is offered on a reading step and on one already done (the player
  /// went Back to re-read it); a doing step advances by itself.
  bool get canNext {
    final s = currentStep;
    return s != null && (s.manual || isDone(s));
  }

  bool get canBack => progress.step > 0;

  /// The rolling product rate (null until a whole window is sampled).
  double? get rate => progress.rollingRate(scenario.rateWindowS);

  /// Reads the floor: samples the rate, notes running recipes, completes
  /// the current step if its check passes (one step per call, so the UI
  /// can flash each), and latches goals in goal mode.
  ScenarioEvents update(FactorySim sim) {
    _simS = sim.simSeconds;
    _sample(sim);
    for (final p in sim.blueprint.placements) {
      final r = p.recipe;
      if (p.kind != EntityKind.machine || r == null) continue;
      if (sim.statusOf(p.id) == MachineStatus.working) {
        progress.recipesSeenWorking.add(r);
      }
    }
    final steps = <String>[];
    final s = currentStep;
    final check = s?.check;
    if (s != null && check != null && !isDone(s) && check(sim, progress)) {
      progress.stepDoneAt[s.id] = _simS;
      steps.add(s.id);
      _advance(sim);
    }
    final goals = <String>[];
    if (inGoals) {
      for (final g in scenario.goals) {
        if (progress.goalMetAt.containsKey(g.id)) continue;
        if (g.read(sim, progress).met) {
          progress.goalMetAt[g.id] = _simS;
          goals.add(g.id);
        }
      }
    }
    return steps.isEmpty && goals.isEmpty
        ? ScenarioEvents.none
        : ScenarioEvents(steps, goals);
  }

  void _sample(FactorySim sim) {
    final t = sim.simSeconds;
    final v = sim.lifetime.shipped[scenario.product] ?? 0;
    final ss = progress.samples;
    if (ss.isNotEmpty && t < ss.last.$1 + kScenarioSampleS - _eps) return;
    ss.add((t, v));
    // Keep one sample at or before the window's start, drop older ones.
    final start = t - scenario.rateWindowS;
    while (ss.length > 2 && ss[1].$1 <= start + _eps) {
      ss.removeAt(0);
    }
  }

  /// Moves past the current step (a reading step's Next, or a reviewed
  /// one's). A doing step not yet done is refused: false.
  bool next(FactorySim sim) {
    final s = currentStep;
    if (s == null || !canNext) return false;
    _simS = sim.simSeconds;
    progress.stepDoneAt.putIfAbsent(s.id, () => _simS);
    _advance(sim);
    return true;
  }

  /// Back one step to re-read it (from goal mode: the last step).
  bool back() {
    if (!canBack) return false;
    progress.step--;
    return true;
  }

  /// Ends the tutorial now and opens the goals.
  void skipTutorial(FactorySim sim) {
    if (inGoals) return;
    _simS = sim.simSeconds;
    progress.step = scenario.steps.length;
    _startGoals(sim);
  }

  void _advance(FactorySim sim) {
    // One step at a time, even past steps already done: a player who went
    // Back to re-read steps forward through them with Next.
    progress.step++;
    if (inGoals) _startGoals(sim);
  }

  void _startGoals(FactorySim sim) {
    if (progress.goalStartS != null) return;
    progress
      ..goalStartS = sim.simSeconds
      ..shippedAtGoalStart = {...sim.lifetime.shipped};
  }

  /// The UI saw the (debug) product tree open on [item].
  void noteProductTree(String item) => progress.treeItemsSeen.add(item);

  /// The UI saw Recipe info open on [item].
  void noteRecipeInfo(String item) => progress.recipeInfoSeen.add(item);

  /// The UI's Bottlenecks overlay is [on].
  void noteBottlenecks(bool on) {
    if (on) progress.bottlenecksSeen = true;
  }

  /// Switches the docks' supply to [option] (null: the starting supply),
  /// and starts that option's counters afresh.
  void setSupply(SupplyOption? option, FactorySim sim) {
    port.setSupply(option?.commodities ?? scenario.supply);
    progress
      ..supplyOptionId = option?.id
      ..supplyChangedS = sim.simSeconds
      ..shippedAtSupplyChange = {...sim.lifetime.shipped};
    progress.recipesSeenWorking.clear();
  }

  /// The goal readings, in scenario order.
  List<(ScenarioGoal, GoalReading)> readGoals(FactorySim sim) => [
        for (final g in scenario.goals) (g, g.read(sim, progress)),
      ];

  /// Receiving docks whose item the current supply doesn't include, by id:
  /// they will never unload, and the player should be told why.
  List<Placement> unsuppliedDocks(FactorySim sim) => [
        for (final p in sim.blueprint.placements)
          if (p.kind == EntityKind.receivingDock && !_supplied(p.item)) p,
      ];

  bool _supplied(String? item) {
    if (item == null) return true; // an unset dock asks for nothing
    final c = FactoryItems.byId(item)?.commodity ?? item;
    return port.supplies(c);
  }
}

// ---------------------------------------------------------------------------
// Floor queries the checks share
// ---------------------------------------------------------------------------

Iterable<Placement> _ofKind(FactorySim sim, EntityKind k) =>
    sim.blueprint.placements.where((p) => p.kind == k);

Iterable<Placement> _running(FactorySim sim, String recipeId) => sim
    .blueprint.placements
    .where((p) => p.kind == EntityKind.machine && p.recipe == recipeId);

bool _hasDock(FactorySim sim, String item) =>
    _ofKind(sim, EntityKind.receivingDock).any((p) => p.item == item);

/// A station running [recipeId] that is plainly being fed: it holds one of
/// [items] (inputs or outputs) or is crafting or waiting to unload.
bool _fed(FactorySim sim, String recipeId, Set<String> items) {
  for (final p in _running(sim, recipeId)) {
    final st = sim.statusOf(p.id);
    if (st == MachineStatus.working || st == MachineStatus.blocked) {
      return true;
    }
    final c = sim.contentsOf(p.id);
    if (items.any((i) => (c[i] ?? 0) > 0)) return true;
  }
  return false;
}

double _shipped(FactorySim sim, String commodity) =>
    sim.lifetime.shipped[commodity] ?? 0;

String _fmt2(double v) => v.toStringAsFixed(2);

// ---------------------------------------------------------------------------
// The Rocket Parts scenario
// ---------------------------------------------------------------------------

/// The tutorial hall: 60 × 40 tiles (120 × 80 m). Twice the template's
/// footprint each way, so a first, sprawling layout fits with room to tidy
/// it, yet small enough that the whole hall fits on one screen.
const HallSize kTutorialHall = HallSize(60, 40);

/// Rocket parts shipped for the first goal: ten bay crafts, enough that
/// the line has to really run, not just squeeze out one pair.
const double kTutorialShipGoal = 20;

/// The real Rocket Parts Factory's spec rate, parts per sim second
/// (`rocketfactory_template.dart` mass balance): the bar a player's plant
/// is measured against.
const double kTutorialTargetRate = 0.4;

/// Sim seconds the rate goal is measured over: 180 s, NOT the 60 s first
/// asked for. Rocket parts leave in lumps: every welding cell finishes 2
/// frames per cycle (36 s assisted, 60 s manual), and cells fed off one
/// belt fall into step, so the bay ships a burst each cycle. Measured on
/// the reference plant (steady 0.444/s), a 60 s window holds one burst or
/// two and reads 0.27 or 0.53 by luck of alignment, so a 60 s goal would
/// latch on a lucky window, or never hold. 180 s is five assisted cycles
/// and three manual ones exactly, so it always holds whole cycles of the
/// slow stations and reads the true rate.
const double kTutorialRateWindowS = 180;

/// The spec plant's crew (template doc: 32 station + 18 handler jobs).
const double kTutorialJobCap = 50;

/// Rocket parts the ore-only challenge asks for, counted from the switch.
const double kDeepChainGoal = 20;

/// Commodity ids the scenario names.
const String _tubes = 'tubes';
const String _electronics = 'electronics';
const String _ore = 'ore';
const String _rocketParts = 'rocketParts';

/// The ore-only supply option's id.
const String kOreOnlySupply = 'oreOnly';

/// Whether some recipe that makes [item] has run since the supply changed.
bool _madeHere(ScenarioProgress p, String item) {
  for (final rid in p.recipesSeenWorking) {
    final r = FactoryRecipes.byId(rid);
    if (r == null) continue;
    if (r.outputs.any((q) => q.item == item)) return true;
  }
  return false;
}

/// The 'Rocket Parts' scenario: an empty hall, tubes and electronics on
/// tap, a tutorial that builds one small line by hand, then free play
/// toward a plant that matches the real one.
FactoryScenario rocketPartsScenario() {
  ensureFactoryCatalog();
  registerRocketPartsChain();
  final frame = RocketPartsItems.frame.id;
  final avionics = RocketPartsItems.avionics.id;
  final weld = RocketPartsRecipes.weldFrame.id;
  final wire = RocketPartsRecipes.wireAvionics.id;

  GoalReading rateReading(FactorySim sim, ScenarioProgress p,
      {required bool lean}) {
    final r = p.rollingRate(kTutorialRateWindowS);
    final jobs = sim.jobDemand;
    final rateOk = r != null && r + _eps >= kTutorialTargetRate;
    final jobsOk = jobs <= kTutorialJobCap + _eps;
    final rateText = r == null
        ? 'measuring… (needs ${kTutorialRateWindowS.toStringAsFixed(0)} s)'
        : '${_fmt2(r)} / ${_fmt2(kTutorialTargetRate)} per s';
    return GoalReading(
      progress: r == null ? 0 : (r / kTutorialTargetRate).clamp(0.0, 1.0),
      status: lean
          ? '$rateText · ${jobs.toStringAsFixed(1)} / '
              '${kTutorialJobCap.toStringAsFixed(0)} jobs'
          : rateText,
      met: rateOk && (!lean || jobsOk),
    );
  }

  return FactoryScenario(
    id: 'rocketParts',
    title: 'Rocket Parts',
    blueprint: () => FloorBlueprint(
        name: 'Rocket Parts Tutorial',
        plantType: kRocketPartsType,
        hall: kTutorialHall),
    supply: const {_tubes, _electronics},
    supplyOptions: const [
      SupplyOption(
          id: 'parts',
          label: 'Tubes + Electronics',
          commodities: {_tubes, _electronics}),
      SupplyOption(id: kOreOnlySupply, label: 'Ore only', commodities: {_ore}),
    ],
    product: _rocketParts,
    targetRate: kTutorialTargetRate,
    rateWindowS: kTutorialRateWindowS,
    jobCap: kTutorialJobCap,
    steps: [
      const TutorialStep(
        id: 'welcome',
        title: 'Welcome to the factory floor',
        body: 'This empty hall is yours. Freight comes in at receiving docks, '
            'machines turn it into something else, belts, arms and workers '
            'move it between them, and shipping docks send the result to the '
            'colony. You will build a small rocket parts line, one piece at a '
            'time.',
        hint: ScenarioHint('Drag empty floor or middle-drag to pan; the '
            'wheel zooms. The floor keeps running while you build.'),
      ),
      TutorialStep(
        id: 'receive',
        title: 'Bring tubes in',
        body: 'Pick Receiving Dock, set its item to '
            '${FactoryItems.tubes.pickerLabel}, and place it '
            'on a wall of the hall (it snaps to the nearest one). Goods come '
            'by truck: open Orders in the header and order a truck of Tubes '
            'to this dock, and tick Dock conveyor in the Inspector so the '
            'truck unloads itself (or hire a Pallet Jack to unload it). A '
            'dock sets goods down only onto something in front of its '
            'loading area, so nothing arrives yet.',
        hint: ScenarioHint(
            'DOCKS ▸ Receiving Dock, item: ${FactoryItems.tubes.pickerLabel}',
            {ScenarioHintTarget.receivingDock}),
        check: (sim, p) => _hasDock(sim, _tubes),
      ),
      TutorialStep(
        id: 'move',
        title: 'Lay a belt',
        body: 'Choose Belt and drag a run that starts on the tile in front of '
            'the dock. The dock unloads a tube a second onto it and the belt '
            'carries them along to its end, where they queue.',
        hint: const ScenarioHint(
            'TRANSPORT ▸ Belt, then drag', {ScenarioHintTarget.belt}),
        check: (sim, p) => sim.beltItems.any((b) => b.item == _tubes),
      ),
      // Steps from here teach explicit PORTS (§10 item 19): every station
      // has fixed input ports (one per recipe input, green notches),
      // output ports (orange) and one hand port (white) where handlers
      // load and unload it. Arms no longer feed or clear machines, so the
      // line is belts into ports and belts out of ports.
      TutorialStep(
        id: 'make',
        title: 'Place a welding cell',
        body: 'Pick the Assembler, choose the recipe Weld Frame, and place it '
            'just past the END of the tube belt. Weld Frame turns 5 tubes '
            'into 2 welded frames every 36 s. Look at its edges: the green '
            'notches are INPUT ports (hover one: "Input 1: Tubes"), the '
            'orange notch is its OUTPUT port, and the white one is the HAND '
            'port where workers load and unload it.',
        hint: const ScenarioHint('MACHINES ▸ Assembler, recipe: Weld Frame '
            '(or set it in the Inspector)', {ScenarioHintTarget.assembler}),
        check: (sim, p) => _running(sim, weld).isNotEmpty,
      ),
      // Steps 5 and 6 were the playtest's sticking point (§10 item 2), and
      // with ports they are where the puzzle starts: the belt has to meet
      // the right notch, pointing the right way.
      TutorialStep(
        id: 'feed',
        title: 'Run the tubes into input 1',
        body: 'A belt feeds a machine only through an INPUT port: its last '
            'tile must sit on the tile just outside the green "Input 1: '
            'Tubes" notch (the middle of the cell\'s back, the side its '
            'arrow points away from), pointing INTO the cell. Extend or '
            'redraw the tube belt so it does. A belt touching any other '
            'tile of the cell, or the wrong notch, feeds nothing. When the '
            'port is connected it lights up and the cell starts welding.',
        hint: const ScenarioHint(
            'TRANSPORT ▸ Belt, last tile → the Input 1 notch',
            {ScenarioHintTarget.belt}),
        check: (sim, p) => _fed(sim, weld, {_tubes, frame}),
      ),
      TutorialStep(
        id: 'ship',
        title: 'Take the frames out of the output port',
        body: 'Frames leave only by the cell\'s orange OUTPUT port, on the '
            'side its arrow points at. Lay a Belt starting on the tile just '
            'outside that notch and run it into a Shipping Dock (the belt\'s '
            'last tile points into the dock, which ships any item). With '
            'no belt there and nobody to carry them, the frames pile up '
            'inside and the cell stops: "blocked".',
        hint: const ScenarioHint(
            'Belt from the output notch → Shipping Dock',
            {ScenarioHintTarget.belt, ScenarioHintTarget.shippingDock}),
        check: (sim, p) => _shipped(sim, frame) >= 1,
      ),
      TutorialStep(
        id: 'secondLine',
        title: 'Start the avionics line',
        body: 'Add an Assembler set to Wire Avionics (3 electronics → 2 '
            'harnesses) and a Receiving Dock set to '
            '${FactoryItems.electronics.pickerLabel} — the LOOSE boards, not '
            'the ${FactoryItems.crateElectronics.pickerLabel}, which no bench '
            'here unpacks. Run a belt from in front of the dock into the '
            'bench\'s Input 1 notch, the same way as the tubes. Its '
            'harnesses will leave by its output port in the next step.',
        hint: ScenarioHint(
            'Receiving Dock (${FactoryItems.electronics.pickerLabel}), '
            'Assembler (Wire Avionics), Belt → its Input 1',
            const {
              ScenarioHintTarget.receivingDock,
              ScenarioHintTarget.assembler,
              ScenarioHintTarget.belt,
            }),
        check: (sim, p) =>
            _hasDock(sim, _electronics) &&
            _fed(sim, wire, {_electronics, avionics}),
      ),
      TutorialStep(
        id: 'assemble',
        title: 'Assemble rocket parts: two inputs',
        body: 'Place an Assembler set to Assemble Rocket Parts (1 frame + 1 '
            'harness → 2 parts). It has TWO input ports: frames go into '
            'Input 1 (the back) and harnesses into Input 2 (the top). '
            'Replace the frame shipping dock with it so the frame belt runs '
            'into Input 1, then run a belt from the wiring bench\'s output '
            'port round into Input 2 — hover a notch to check which is '
            'which. Rocket parts are HEAVY, so no worker can lift them: '
            'run a belt from the assembler\'s output port into a Shipping '
            'Dock. (Arms still load and unload chests and docks, but never '
            'a machine. A handler — a Pallet Jack for frames, a Crane over '
            'the hand port for parts — is the alternative to a belt: '
            'hand frames to a handler at the cell\'s white hand port.)',
        hint: const ScenarioHint(
            'Assembler (Assemble Rocket Parts): frames → Input 1, harnesses '
            '→ Input 2, output belt → Shipping Dock',
            {
              ScenarioHintTarget.assembler,
              ScenarioHintTarget.belt,
              ScenarioHintTarget.shippingDock,
              ScenarioHintTarget.palletJack,
              ScenarioHintTarget.craneBay,
              ScenarioHintTarget.crane,
            }),
        check: (sim, p) => _shipped(sim, _rocketParts) >= 1,
      ),
      TutorialStep(
        id: 'read',
        title: 'Read the floor',
        body: 'Turn on Bottlenecks in the header: each machine is tinted by '
            'what holds it up (starved, blocked, unstaffed). Then open '
            'Recipe info on Rocket Parts: Components shows what one recipe '
            'takes in and puts out, Raw total what a part costs in raw '
            'materials. Working out the steps between is up to you.',
        hint: const ScenarioHint('Header ▸ Bottlenecks, then Recipe info',
            {ScenarioHintTarget.bottlenecks, ScenarioHintTarget.recipeInfo}),
        check: (sim, p) =>
            p.bottlenecksSeen && p.recipeInfoSeen.contains(_rocketParts),
      ),
    ],
    freePlayTitle: 'Free play: build a plant that makes rocket parts',
    freePlayBody: 'The line you built works, but slowly. Grow it into a real '
        'plant: the colony\'s Rocket Parts Factory makes 0.4 parts a second '
        'with 50 jobs. Belts cost no crew, but each one connects to one '
        'port, so feeding more cells is a layout puzzle; Recipe info shows '
        'what each step takes.',
    goals: [
      ScenarioGoal(
        id: 'ship20',
        title: 'Ship ${kTutorialShipGoal.toStringAsFixed(0)} rocket parts',
        detail: 'Counted from the start of free play.',
        read: (sim, p) {
          final n = p.shippedSinceGoalStart(sim, _rocketParts);
          return GoalReading(
              progress: (n / kTutorialShipGoal).clamp(0.0, 1.0),
              status: '${n.toStringAsFixed(0)} / '
                  '${kTutorialShipGoal.toStringAsFixed(0)} shipped',
              met: n + _eps >= kTutorialShipGoal);
        },
      ),
      ScenarioGoal(
        id: 'rate',
        title: 'Sustain ${_fmt2(kTutorialTargetRate)} rocket parts/s',
        detail: 'The real plant\'s rate, held over a rolling '
            '${kTutorialRateWindowS.toStringAsFixed(0)} s window.',
        read: (sim, p) => rateReading(sim, p, lean: false),
      ),
      ScenarioGoal(
        id: 'lean',
        title: 'Hit that rate with ≤ ${kTutorialJobCap.toStringAsFixed(0)} '
            'jobs',
        detail: 'The real plant\'s crew. Automated or assisted stations and '
            'belts in place of handlers free people for the colony.',
        read: (sim, p) => rateReading(sim, p, lean: true),
      ),
      ScenarioGoal(
        id: 'deepChain',
        optional: true,
        title: 'Deep chain: rocket parts from ore',
        detail: 'Switch the supply to Ore only, then ship '
            '${kDeepChainGoal.toStringAsFixed(0)} rocket parts. Tubes come '
            'from the steel chain (smelt ore; press the slag) and electronics '
            'from the electronics chain: open Recipe info on Tubes and '
            'Electronics to see what each takes. Ore is a PALLET load.',
        read: (sim, p) {
          if (p.supplyOptionId != kOreOnlySupply) {
            return const GoalReading(
                progress: 0, status: 'Supply is not Ore only', met: false);
          }
          final n = p.shippedSinceSupplyChange(sim, _rocketParts);
          final tubes = _madeHere(p, _tubes);
          final elec = _madeHere(p, _electronics);
          final parts = [
            '${n.toStringAsFixed(0)} / ${kDeepChainGoal.toStringAsFixed(0)} '
                'shipped',
            tubes ? 'tubes made ✓' : 'tubes not made yet',
            elec ? 'electronics made ✓' : 'electronics not made yet',
          ];
          return GoalReading(
              progress: (n / kDeepChainGoal).clamp(0.0, 1.0),
              status: parts.join(' · '),
              met: n + _eps >= kDeepChainGoal && tubes && elec);
        },
      ),
    ],
  );
}
