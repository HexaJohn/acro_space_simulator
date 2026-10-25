// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_scenario.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/rocketfactory_template.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Rocket Parts scenario played the way a player would: every edit goes
/// through the floor's editor surface (place, setRecipe, hire) with the
/// palette's own defaults (an assembler is placed with the station's FIRST
/// recipe and then switched), the floor is stepped, and the runner reads
/// it. Each step must complete when — and only when — the floor really
/// does the thing, so a core-system bug shows up here as a step that never
/// completes, not as a tutorial that lies.
void main() {
  /// The world under test: a fresh scenario floor and its runner.
  late FactoryFloor f;
  late ScenarioRunner run;

  void boot() {
    final s = rocketPartsScenario();
    f = FactoryFloor.fromBlueprint(s.blueprint());
    run = ScenarioRunner(s);
  }

  /// Runs the floor [seconds] in 1 s slices, updating the runner after
  /// each (the panel updates a few times a second; 1 s is the sample step).
  void runFor(double seconds) {
    for (var t = 0.0; t < seconds - 1e-9; t += 1) {
      f.step(1, run.port);
      run.update(f);
    }
  }

  /// Runs until [done] (checked each second) or [limit] sim seconds; the
  /// sim seconds it took, or fails.
  double runUntil(bool Function() done, {double limit = 600, String? what}) {
    final t0 = f.simSeconds;
    while (!done()) {
      if (f.simSeconds - t0 > limit) {
        fail('timed out after ${limit}s waiting for ${what ?? 'condition'}');
      }
      f.step(1, run.port);
      run.update(f);
    }
    return f.simSeconds - t0;
  }

  String? stepId() => run.currentStep?.id;

  int place(EntityKind k, int x, int y,
      {Dir4 dir = Dir4.east, String? item, String? recipe}) {
    final r = f.place(Placement(
        id: 0, kind: k, pos: TilePos(x, y), dir: dir, item: item,
        recipe: recipe));
    expect(r.ok, isTrue, reason: 'place $k at ($x, $y): ${r.refusal}');
    return r.placementId!;
  }

  /// An assembler as the palette lays one: the station's first recipe,
  /// then the Inspector's recipe switch to [recipe].
  int assembler(int x, int y, String recipe) {
    final first = FactoryRecipes.forStation(StationKind.assembler).first.id;
    final id = place(EntityKind.machine, x, y, recipe: first);
    if (first != recipe) expect(f.setRecipe(id, recipe).ok, isTrue);
    return id;
  }

  void belt(int x0, int x1, int y, Dir4 dir) {
    for (var x = x0; x <= x1; x++) {
      place(EntityKind.belt, x, y, dir: dir);
    }
  }

  /// The tutorial as built in the doc's suggested layout. Returns the sim
  /// second each step completed, by id.
  Map<String, double> playTutorial() {
    expect(stepId(), 'welcome');
    runFor(5);
    expect(stepId(), 'welcome', reason: 'a reading step waits for Next');
    expect(run.next(f), isTrue);

    // b. Receive: a tube dock on the south wall, facing in (north).
    expect(stepId(), 'receive');
    runFor(2);
    expect(stepId(), 'receive');
    place(EntityKind.receivingDock, 4, 0, dir: Dir4.north, item: 'tubes');
    runFor(1);

    // c. Move: nothing rides until a belt starts in front of the dock.
    expect(stepId(), 'move');
    runFor(3);
    expect(stepId(), 'move', reason: 'no belt yet, nothing can ride one');
    belt(4, 19, 2, Dir4.east);
    runUntil(() => stepId() != 'move', limit: 10, what: 'tubes on the belt');

    // d. Make: placed with the palette default recipe, it is not a welding
    // cell until the recipe is switched. The cell sits just past the belt's
    // end, one tile short: its Input 1 port is (21, 2), fed from (20, 2).
    expect(stepId(), 'make');
    final first = FactoryRecipes.forStation(StationKind.assembler).first.id;
    final cell = place(EntityKind.machine, 21, 1, recipe: first);
    runFor(2);
    if (first != RocketPartsRecipes.weldFrame.id) {
      expect(stepId(), 'make', reason: 'wrong recipe still');
      expect(f.setRecipe(cell, RocketPartsRecipes.weldFrame.id).ok, isTrue);
    }
    runFor(1);

    // e. Feed: the cell starves until the belt's last tile points into its
    // Input 1 port.
    expect(stepId(), 'feed');
    runFor(5);
    expect(stepId(), 'feed', reason: 'the belt stops a tile short');
    place(EntityKind.belt, 20, 2);
    runUntil(() => stepId() != 'feed', limit: 10, what: 'the cell fed');

    // f. Ship: frames leave only by the output port (23, 2), onto (24, 2).
    // A dock alone ships nothing (nothing carries the frames to it); a belt
    // from the output port into it does, with no handler hired at all.
    expect(stepId(), 'ship');
    place(EntityKind.shippingDock, 30, 2);
    runFor(90);
    expect(stepId(), 'ship', reason: 'nothing carries a frame to the dock');
    expect(f.contentsOf(cell)[RocketPartsItems.frame.id] ?? 0, greaterThan(0),
        reason: 'frames wait inside: its output port has no belt');
    belt(24, 29, 2, Dir4.east); // output port -> the dock at (30, 2)
    runUntil(() => stepId() != 'ship', limit: 120, what: 'a frame shipped');
    expect(f.handlers, isEmpty, reason: 'no handler was needed');

    // g. Second line: an electronics dock on the north wall, its belt into
    // a wiring bench's Input 1 port (6, 36) from (5, 36).
    expect(stepId(), 'secondLine');
    final bench = assembler(6, 35, RocketPartsRecipes.wireAvionics.id);
    runFor(3);
    expect(stepId(), 'secondLine', reason: 'bench has no electronics yet');
    expect(f.contentsOf(bench), isEmpty);
    place(EntityKind.receivingDock, 5, 38, dir: Dir4.south,
        item: 'electronics');
    runFor(5);
    expect(stepId(), 'secondLine', reason: 'no belt into the port yet');
    place(EntityKind.belt, 5, 37, dir: Dir4.south);
    place(EntityKind.belt, 5, 36);
    runUntil(() => stepId() != 'secondLine', limit: 10, what: 'bench fed');

    // h. Assemble, the two-input puzzle: the bay replaces the frame dock so
    // the frame belt runs into its Input 1 (30, 2); the bench's harnesses
    // leave its output port (8, 36) onto (9, 36) and ride round into Input
    // 2 (31, 3) from (31, 4). Rocket parts are HEAVY: the bay blocks until
    // a belt leaves its output port (32, 2) for a shipping dock.
    expect(stepId(), 'assemble');
    final frameDock = f.blueprint.placements.firstWhere(
        (p) => p.kind == EntityKind.shippingDock && p.pos == const TilePos(30, 2));
    expect(f.remove(frameDock.id).ok, isTrue);
    final bay = assembler(30, 1, RocketPartsRecipes.assemble.id);
    belt(9, 30, 36, Dir4.east);
    for (var y = 36; y >= 4; y--) {
      place(EntityKind.belt, 31, y, dir: Dir4.south);
    }
    runUntil(() => (f.contentsOf(bay)['rocketParts'] ?? 0) > 0,
        limit: 600, what: 'the bay to make parts');
    runFor(10);
    expect(stepId(), 'assemble',
        reason: 'heavy parts: nothing carries them out yet');
    expect(f.contentsOf(bay)['rocketParts'] ?? 0, greaterThan(0),
        reason: 'the bay made parts, they are just stuck');
    belt(33, 37, 2, Dir4.east);
    place(EntityKind.shippingDock, 38, 2);
    runUntil(() => stepId() != 'assemble', limit: 30, what: 'a part shipped');

    // i. Read: both UI flags, in either order.
    expect(stepId(), 'read');
    run.noteBottlenecks(true);
    runFor(1);
    expect(stepId(), 'read', reason: 'Recipe info not opened yet');
    run.noteRecipeInfo('steel');
    runFor(1);
    expect(stepId(), 'read', reason: 'opened on the wrong product');
    // The full product tree is debug-only (§10 item 15): it no longer
    // counts for the step.
    run.noteProductTree('rocketParts');
    runFor(1);
    expect(stepId(), 'read', reason: 'the debug tree is not the step');
    run.noteRecipeInfo('rocketParts');
    runFor(1);
    expect(run.inGoals, isTrue);
    return {...run.progress.stepDoneAt};
  }

  test('supply port grants listed commodities only and records the rest',
      () {
    final port = ScenarioColonyPort({'tubes'});
    expect(port.take('tubes', 3), 3);
    expect(port.take('ore', 2), 0);
    expect(port.take('ore', 1), 0);
    expect(port.refused['ore'], 2);
    expect(port.taken, {'tubes': 3});
    expect(port.give('rocketParts', 4), 4);
    expect(port.given['rocketParts'], 4);
    port.setSupply({'ore'});
    expect(port.take('tubes', 1), 0);
    expect(port.take('ore', 1), 1);
  });

  test('an off-list dock never unloads and is reported', () {
    boot();
    final ore = place(EntityKind.receivingDock, 4, 0,
        dir: Dir4.north, item: 'ore');
    place(EntityKind.receivingDock, 10, 0, dir: Dir4.north, item: 'tubes');
    belt(4, 4, 2, Dir4.east);
    belt(10, 10, 2, Dir4.east);
    runFor(5);
    expect(f.lifetime.received['ore'], isNull);
    expect(f.lifetime.received['tubes'], greaterThan(0));
    expect(run.port.refused['ore'], greaterThan(0));
    expect([for (final p in run.unsuppliedDocks(f)) p.id], [ore]);
  });

  test('tutorial steps complete in order, each only when its thing happens',
      () {
    boot();
    final done = playTutorial();
    expect(done.keys, [
      'welcome', 'receive', 'move', 'make', 'feed', 'ship', 'secondLine',
      'assemble', 'read',
    ]);
    // Monotone timestamps in sim seconds.
    final ts = done.values.toList();
    for (var i = 1; i < ts.length; i++) {
      expect(ts[i], greaterThanOrEqualTo(ts[i - 1]));
    }
    // ignore: avoid_print
    print('tutorial step times (sim s): $done');
  });

  test('Back re-reads a done step without undoing it; Skip opens goals', () {
    boot();
    run.next(f);
    place(EntityKind.receivingDock, 4, 0, dir: Dir4.north, item: 'tubes');
    runFor(1);
    expect(stepId(), 'move');
    expect(run.canNext, isFalse, reason: 'a doing step advances itself');
    expect(run.next(f), isFalse);
    expect(run.back(), isTrue);
    expect(stepId(), 'receive');
    runFor(2);
    expect(stepId(), 'receive', reason: 'a reviewed step does not re-fire');
    expect(run.canNext, isTrue);
    run.next(f);
    expect(stepId(), 'move');
    run.skipTutorial(f);
    expect(run.inGoals, isTrue);
    expect(run.progress.goalStartS, f.simSeconds);
  });

  /// The doc's reference plant, built on top of the tutorial line: four
  /// welding cells and five wiring benches feeding one bay, all by belts
  /// into and out of ports (§10 item 19). A port takes one belt, so each
  /// new cell and bench gets its own receiving dock, and their outputs
  /// side-merge into the frame belt and the harness belt. Assisted
  /// stations (the palette's default crew) and no handlers at all.
  ({double to20, double rate, double jobs, Map<String, double> goals})
      buildReference() {
    boot();
    playTutorial();
    // Cells 2-4 stacked up column x = 21..23, each fed from its own tube
    // dock at x = 18; their frames leave the output ports onto a belt down
    // column 24 that side-loads into the frame belt at (24, 2).
    for (final y in [5, 9, 13]) {
      place(EntityKind.receivingDock, 18, y + 1, item: 'tubes');
      place(EntityKind.belt, 20, y + 1);
      assembler(21, y, RocketPartsRecipes.weldFrame.id);
    }
    for (var y = 14; y >= 3; y--) {
      place(EntityKind.belt, 24, y, dir: Dir4.south);
    }
    // Benches 2-5 stacked at x = 28..30, each fed from its own electronics
    // dock at x = 25; their harnesses leave onto the harness belt down
    // column 31 into the bay's Input 2.
    for (final y in [5, 9, 13, 17]) {
      place(EntityKind.receivingDock, 25, y + 1, item: 'electronics');
      place(EntityKind.belt, 27, y + 1);
      assembler(28, y, RocketPartsRecipes.wireAvionics.id);
    }

    final t0 = f.simSeconds;
    final to20 = runUntil(() => run.progress.goalMetAt.containsKey('ship20'),
        limit: 900, what: '20 parts');
    runUntil(() => run.progress.goalMetAt.containsKey('rate'),
        limit: 900, what: '0.4/s');
    // Steady state, past the burst from buffers the tutorial line filled:
    // 360 s is ten weld cycles.
    runFor(120);
    final s0 = f.lifetime.shipped['rocketParts'] ?? 0;
    runFor(360);
    final steady = ((f.lifetime.shipped['rocketParts'] ?? 0) - s0) / 360;
    return (
      to20: to20,
      rate: steady,
      jobs: f.jobDemand,
      goals: {
        for (final e in run.progress.goalMetAt.entries) e.key: e.value - t0,
      },
    );
  }

  test('a reference layout ships 20 parts and sustains 0.4/s on ≤ 50 jobs',
      () {
    final r = buildReference();
    // ignore: avoid_print
    print('reference: 20 parts in ${r.to20}s, steady rate '
        '${r.rate.toStringAsFixed(3)}/s, rolling ${run.rate}, '
        'jobs ${r.jobs}, goals ${r.goals}');
    expect(r.rate, greaterThanOrEqualTo(kTutorialTargetRate));
    expect(r.jobs, lessThanOrEqualTo(kTutorialJobCap));
    expect(run.progress.goalMetAt.keys, containsAll(['ship20', 'rate', 'lean']));
    expect(run.progress.goalMetAt.containsKey('deepChain'), isFalse);
  });

  test('the one-cell tutorial line does not meet the rate goals', () {
    boot();
    playTutorial();
    runFor(400);
    final rate = run.rate;
    expect(rate, isNotNull, reason: 'the window is full after 400 s');
    expect(rate!, lessThan(kTutorialTargetRate));
    expect(run.progress.goalMetAt.containsKey('rate'), isFalse);
    expect(run.progress.goalMetAt.containsKey('lean'), isFalse);
    final reading = run.readGoals(f).firstWhere((g) => g.$1.id == 'rate').$2;
    expect(reading.progress, closeTo(rate / kTutorialTargetRate, 1e-9));
  });

  test('ore-only supply refuses the tube and electronics docks', () {
    boot();
    playTutorial();
    final s = run.scenario.supplyOptions
        .firstWhere((o) => o.id == kOreOnlySupply);
    run.setSupply(s, f);
    final before = f.lifetime.received['tubes'] ?? 0;
    runFor(30);
    expect(f.lifetime.received['tubes'] ?? 0, before);
    expect(run.unsuppliedDocks(f), hasLength(2));
    final deep = run.readGoals(f).firstWhere((g) => g.$1.id == 'deepChain');
    expect(deep.$2.met, isFalse);
    expect(deep.$2.status, contains('tubes not made yet'));
  });

  test('deterministic: two playthroughs agree bit for bit', () {
    final a = buildReference();
    final ja = f.toJson().toString();
    final pa = {...run.progress.stepDoneAt};
    final b = buildReference();
    expect(f.toJson().toString(), ja);
    expect(run.progress.stepDoneAt, pa);
    expect(b.to20, a.to20);
    expect(b.rate, a.rate);
    expect(b.goals, a.goals);
  });
}
