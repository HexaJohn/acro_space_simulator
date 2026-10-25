// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
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
    // cell until the recipe is switched.
    expect(stepId(), 'make');
    final first = FactoryRecipes.forStation(StationKind.assembler).first.id;
    final cell = place(EntityKind.machine, 6, 4, recipe: first);
    runFor(2);
    if (first != RocketPartsRecipes.weldFrame.id) {
      expect(stepId(), 'make', reason: 'wrong recipe still');
      expect(f.setRecipe(cell, RocketPartsRecipes.weldFrame.id).ok, isTrue);
    }
    runFor(1);

    // e. Feed: the cell starves until an arm lifts tubes into it.
    expect(stepId(), 'feed');
    runFor(5);
    expect(stepId(), 'feed', reason: 'no arm, no tubes in the cell');
    place(EntityKind.arm, 7, 3, dir: Dir4.north);
    runUntil(() => stepId() != 'feed', limit: 10, what: 'the cell fed');

    // f. Ship: a dock alone ships nothing (frames are pallet loads and
    // nobody can lift them); a hired pallet jack does.
    expect(stepId(), 'ship');
    place(EntityKind.shippingDock, 24, 0, dir: Dir4.north);
    runFor(90);
    expect(stepId(), 'ship', reason: 'no handler can lift a frame');
    expect(f.pendingRequests, greaterThan(0),
        reason: 'the frames wait as an unserved request');
    f.hire(HandlerKind.palletJack, 1);
    runUntil(() => stepId() != 'ship', limit: 300, what: 'a frame shipped');

    // g. Second line: an electronics dock pointed straight into a wiring
    // bench (dock on the north wall facing south into the bench's top row).
    expect(stepId(), 'secondLine');
    final bench = assembler(6, 35, RocketPartsRecipes.wireAvionics.id);
    runFor(3);
    expect(stepId(), 'secondLine', reason: 'bench has no electronics yet');
    expect(f.contentsOf(bench), isEmpty);
    place(EntityKind.receivingDock, 7, 38, dir: Dir4.south,
        item: 'electronics');
    f.hire(HandlerKind.onFoot, 2);
    runUntil(() => stepId() != 'secondLine', limit: 10, what: 'bench fed');

    // h. Assemble: a bay fed by the jack (frames) and the walkers
    // (harnesses); rocket parts are HEAVY, so an arm lifts them out into a
    // shipping dock.
    expect(stepId(), 'assemble');
    final bay = assembler(24, 20, RocketPartsRecipes.assemble.id);
    runUntil(() => (f.contentsOf(bay)['rocketParts'] ?? 0) > 0,
        limit: 600, what: 'the bay to make parts');
    runFor(10);
    expect(stepId(), 'assemble',
        reason: 'heavy parts: no worker or jack can ship them');
    expect(f.contentsOf(bay)['rocketParts'] ?? 0, greaterThan(0),
        reason: 'the bay made parts, they are just stuck');
    place(EntityKind.arm, 27, 21, dir: Dir4.east);
    place(EntityKind.shippingDock, 28, 21);
    runUntil(() => stepId() != 'assemble', limit: 30, what: 'a part shipped');

    // i. Read: both UI flags, in either order.
    expect(stepId(), 'read');
    run.noteBottlenecks(true);
    runFor(1);
    expect(stepId(), 'read', reason: 'tree not opened yet');
    run.noteProductTree('steel');
    runFor(1);
    expect(stepId(), 'read', reason: 'opened on the wrong product');
    run.noteProductTree('rocketParts');
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
  /// welding cells and four wiring benches feeding one bay by belts and
  /// arms. Assisted stations (the palette's default crew) and no handlers
  /// in the loop.
  ({double to20, double rate, double jobs, Map<String, double> goals})
      buildReference() {
    boot();
    playTutorial();
    // Cells 2-4 on the tube belt, each with an input arm.
    for (final x in [10, 14, 18]) {
      assembler(x, 4, RocketPartsRecipes.weldFrame.id);
      place(EntityKind.arm, x + 1, 3, dir: Dir4.north);
    }
    // Every cell's frames go up by arm onto a frame belt along y = 8 that
    // runs east to the bay, and a last arm lifts them in. The bay moves to
    // where the belts meet: the tutorial bay is replaced (as a player
    // would) by one at (24, 8).
    final oldBay = f.blueprint.placements.firstWhere((p) =>
        p.kind == EntityKind.machine &&
        p.recipe == RocketPartsRecipes.assemble.id);
    final oldArm = f.blueprint.placements.firstWhere(
        (p) => p.kind == EntityKind.arm && p.pos == const TilePos(27, 21));
    expect(f.remove(oldArm.id).ok, isTrue);
    expect(f.remove(oldBay.id).ok, isTrue);
    for (final x in [6, 10, 14, 18]) {
      place(EntityKind.arm, x + 1, 7, dir: Dir4.north);
    }
    belt(7, 22, 8, Dir4.east);
    assembler(24, 8, RocketPartsRecipes.assemble.id);
    place(EntityKind.arm, 23, 8); // frame belt end -> bay
    // Benches 1-4 along y = 14..16, fed straight from north-wall docks at
    // y = 17..18; their harnesses go down by arm onto an avionics belt at
    // y = 12 and the bay lifts them in from it. The tutorial bench and its
    // dock at the north wall stay as they are (still fed, now idle-ish).
    for (final x in [6, 10, 14, 18]) {
      assembler(x, 14, RocketPartsRecipes.wireAvionics.id);
      place(EntityKind.receivingDock, x + 1, 17,
          dir: Dir4.south, item: 'electronics');
      place(EntityKind.arm, x + 1, 13, dir: Dir4.south);
    }
    belt(7, 25, 12, Dir4.east);
    place(EntityKind.arm, 25, 11, dir: Dir4.south); // avionics belt -> bay
    // Parts out: an arm onto a belt to a shipping dock on the east wall.
    place(EntityKind.arm, 27, 9);
    belt(28, 57, 9, Dir4.east);
    place(EntityKind.shippingDock, 58, 9);

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
