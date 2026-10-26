// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_scenario.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_painter.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../colony/factory/factory_test_support.dart';
import 'fake_factory_sim.dart';

/// The editor-feel items of the user's tutorial playtest
/// (docs/plans/factory-floors.md §10 items 1, 2, 6, 7, 8, 9, 10), each
/// pinned the way the player meets it: through the palette, real pointer
/// gestures on the canvas and real key events, against the recording fake
/// (what the editor ASKS the floor) or the real floor (what the floor then
/// DOES — items kept, goods piled, structure undone).
void main() {
  late FactoryEditorController c;
  late Finder canvas;

  FloorBlueprint hall([List<Placement>? pl]) => FloorBlueprint(
      name: 'Test Hall', hall: const HallSize(40, 30), placements: pl);

  Future<void> open(WidgetTester t, FactorySim s,
      {bool debugTools = false}) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: FactoryFloorScreen(sim: s, debugTools: debugTools)));
    await t.pump();
    c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    canvas = find.byKey(const Key('factory-canvas'));
  }

  Offset at(WidgetTester t, TilePos p) =>
      t.getTopLeft(canvas) + c.tileCenterLocal(p);

  Future<void> click(WidgetTester t, TilePos p) async {
    final g = await t.startGesture(at(t, p), kind: PointerDeviceKind.mouse);
    await g.up();
    await t.pump();
  }

  Future<TestGesture> hover(WidgetTester t, TilePos p) async {
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at(t, p) + const Offset(0, 1));
    await g.moveTo(at(t, p));
    await t.pump();
    return g;
  }

  /// A primary drag through [path] (each a pointer move), released at the
  /// last tile unless [release] is false.
  Future<TestGesture> drag(WidgetTester t, List<TilePos> path,
      {bool release = true}) async {
    final g =
        await t.startGesture(at(t, path.first), kind: PointerDeviceKind.mouse);
    for (final p in path.skip(1)) {
      await g.moveTo(at(t, p));
      await t.pump();
    }
    if (release) {
      await g.up();
      await t.pump();
    }
    return g;
  }

  Future<void> pick(WidgetTester t, String key) async {
    await t.tap(find.byKey(Key(key)));
    await t.pump();
  }

  Future<void> withKey(WidgetTester t, LogicalKeyboardKey mod,
      Future<void> Function() body) async {
    await t.sendKeyDownEvent(mod);
    await body();
    await t.sendKeyUpEvent(mod);
    await t.pump();
  }

  FactoryFloorPainter painter(WidgetTester t) => t
      .widget<CustomPaint>(
          find.descendant(of: canvas, matching: find.byType(CustomPaint)))
      .painter! as FactoryFloorPainter;

  // ---- 1. Placement arrows -------------------------------------------------

  testWidgets('every directed ghost draws a filled arrowhead', (t) async {
    await open(t, FakeFactorySim(hall()));
    await pick(t, 'palette-belt');
    final g = await hover(t, const TilePos(8, 8));
    expect(painter(t).ghostArrows, 1);
    await g.removePointer();
    await pick(t, 'palette-aisle');
    final h = await hover(t, const TilePos(8, 8));
    expect(painter(t).ghostArrows, 0, reason: 'a floor marking has no facing');
    await h.removePointer();
  });

  testWidgets("an arm's ghost marks the tile it takes from and drops into",
      (t) async {
    await open(t, FakeFactorySim(hall()));
    await pick(t, 'palette-arm');
    await t.sendKeyEvent(LogicalKeyboardKey.keyR); // east -> south
    await t.sendKeyEvent(LogicalKeyboardKey.keyR); // -> west
    await t.sendKeyEvent(LogicalKeyboardKey.keyR); // -> north
    await t.pump();
    final g = await hover(t, const TilePos(5, 5));
    expect(c.ghostDir, Dir4.north);
    expect(painter(t).armGhostEnds,
        [(const TilePos(5, 4), const TilePos(5, 6))],
        reason: 'takes from behind (south), drops in front (north)');
    expect(painter(t).ghostArrows, 1);
    await g.removePointer();
  });

  // ---- 2. Tutorial steps 6 and 7 --------------------------------------------

  test('tutorial steps 6 and 7 say which port the belt meets; the jack '
      'comes later', () {
    final steps = rocketPartsScenario().steps;
    final ids = [for (final s in steps) s.id];
    final feed = steps[ids.indexOf('feed')];
    final ship = steps[ids.indexOf('ship')];
    expect(ids.indexOf('feed'), 5, reason: 'step 6 (after hiring)');
    expect(ids.indexOf('ship'), 6, reason: 'step 7');
    // Explicit ports (§10 item 19): the belt meets the input notch pointing
    // in, and the frames leave by the output notch.
    expect(feed.body, contains('INPUT port'));
    expect(feed.body, contains('INTO the cell'));
    expect(ship.body, contains('OUTPUT port'));
    expect(ship.body, contains('Shipping Dock'));
    expect(ship.body, isNot(contains('Pallet Jack')));
    expect(ship.hint!.targets, isNot(contains(ScenarioHintTarget.palletJack)));
    final later = steps.skip(7).where((s) => s.body.contains('Pallet Jack'));
    expect(later, isNotEmpty, reason: 'the jack is the later alternative');
    expect(later.first.body, contains('hand frames to a handler'));
  });

  // ---- 6. Item picker ------------------------------------------------------

  testWidgets('the picker spells out loose vs packed and marks used items',
      (t) async {
    await open(t, FakeFactorySim(hall([
      Placement(id: 1, kind: EntityKind.machine, pos: const TilePos(20, 20),
          recipe: SteelRecipes.packSteel.id),
    ])));
    await pick(t, 'palette-receivingDock');
    expect(find.byKey(const Key('palette-item-unused')), findsOneWidget,
        reason: 'the default (ore) is used by nothing here');
    await t.tap(find.byKey(const Key('palette-item')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final used = '${FactoryItems.steel.pickerLabel} · used here';
    // Used items lead, under their own heading.
    final opts = find.descendant(
        of: find.byKey(const Key('picker-list')),
        matching: find.byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('picker-option-')));
    expect((t.widget(opts.first).key! as ValueKey<String>).value,
        'picker-option-${FactoryItems.steel.id}',
        reason: 'the packer takes steel, listed first');
    expect(find.text(used), findsOneWidget);
    // The list opens scrolled to the current pick (ore), further down.
    await t.ensureVisible(find.text(used));
    await t.pump();
    await t.tap(find.text(used));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(c.itemChoice, FactoryItems.steel.id);
    expect(find.byKey(const Key('palette-item-unused')), findsNothing);
  });

  testWidgets('a receiving dock nothing here uses carries a warning',
      (t) async {
    final sim = FakeFactorySim(hall([
      Placement(id: 1, kind: EntityKind.machine, pos: const TilePos(20, 20),
          recipe: SteelRecipes.packSteel.id),
      const Placement(id: 2, kind: EntityKind.receivingDock,
          pos: TilePos(2, 2), item: 'crate:electronics'),
      const Placement(id: 3, kind: EntityKind.receivingDock,
          pos: TilePos(2, 6), item: 'steel'),
    ]));
    await open(t, sim);
    expect(painter(t).unusedDockMarks, 1, reason: 'the crate dock only');
    await click(t, const TilePos(2, 2));
    expect(c.selectedId, 2);
    expect(find.byKey(const Key('dock-unused-warning')), findsOneWidget);
    await click(t, const TilePos(2, 6));
    expect(c.selectedId, 3);
    expect(find.byKey(const Key('dock-unused-warning')), findsNothing);
  });

  test("the tutorial's electronics step names the loose form", () {
    final s = rocketPartsScenario()
        .steps
        .firstWhere((s) => s.id == 'secondLine');
    expect(s.body, contains('Electronics (loose · hand)'));
    expect(s.hint!.text, contains('Electronics (loose · hand)'));
  });

  // ---- 7. Shift+R ----------------------------------------------------------

  testWidgets('Shift+R turns the ghost counter-clockwise', (t) async {
    await open(t, FakeFactorySim(hall()));
    await pick(t, 'palette-belt');
    final g = await hover(t, const TilePos(8, 8));
    await withKey(t, LogicalKeyboardKey.shiftLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyR));
    expect(c.ghostDir, Dir4.east.turnCcw);
    expect(c.ghost.single.placement.dir, Dir4.north);
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.pump();
    expect(c.ghostDir, Dir4.east, reason: 'plain R turns back clockwise');
    await g.removePointer();
  });

  testWidgets('Shift+R turns a selected object counter-clockwise',
      (t) async {
    final sim = FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.belt, pos: TilePos(5, 5)),
    ]));
    await open(t, sim);
    await click(t, const TilePos(5, 5));
    expect(c.selectedId, 1);
    await withKey(t, LogicalKeyboardKey.shiftLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyR));
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.pump();
    expect(sim.rotated, [1, 1]);
    expect(sim.rotatedCcw, [true, false]);
    await t.tap(find.byKey(const Key('inspect-rotate-ccw')));
    await t.pump();
    expect(sim.rotatedCcw.last, isTrue);
  });

  // ---- 8. Redraw belts over belts --------------------------------------------

  testWidgets('a run drawn over belts re-points them instead of refusing',
      (t) async {
    final sim = FakeFactorySim(hall([
      for (var x = 3; x <= 7; x++)
        Placement(id: x, kind: EntityKind.belt, pos: TilePos(x, 4)),
      const Placement(id: 20, kind: EntityKind.crossing, pos: TilePos(5, 6)),
    ]));
    await open(t, sim);
    await pick(t, 'palette-belt');
    final g = await drag(t, [
      for (var y = 2; y <= 7; y++) TilePos(5, y),
    ], release: false);
    final at4 = c.ghost.firstWhere((p) => p.rect.y0 == 4);
    expect(at4.redirects, 5, reason: 'the belt on (5, 4) is re-pointed');
    expect(at4.check.ok, isTrue);
    final at6 = c.ghost.firstWhere((p) => p.rect.y0 == 6);
    expect(at6.redirects, 20);
    expect(at6.placement.kind, EntityKind.crossing,
        reason: 'a crossing keeps its walkway');
    expect(painter(t).redirectGhosts, 2, reason: 'tinted apart from new');
    expect(c.ghostValid, isTrue);
    await g.up();
    await t.pump();
    expect(sim.redirected, [(5, Dir4.north), (20, Dir4.north)]);
    expect(sim.removed, isEmpty, reason: 'nothing removed: items stay');
    expect([for (final p in sim.placed) p.pos.y], [2, 3, 5, 7]);
    expect(sim.placed.every((p) => p.kind == EntityKind.belt), isTrue);
  });

  testWidgets('anything that is not a belt still blocks a run', (t) async {
    final sim = FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.chest, pos: TilePos(5, 4)),
    ]));
    await open(t, sim);
    await pick(t, 'palette-belt');
    await drag(t, [for (var y = 2; y <= 6; y++) TilePos(5, y)],
        release: false);
    final at4 = c.ghost.firstWhere((p) => p.rect.y0 == 4);
    expect(at4.redirects, isNull);
    expect(at4.check.refusal, EditRefusal.overlaps);
  });

  testWidgets('redirecting a loaded real belt keeps its items', (t) async {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 4, item: 'ore');
    final belts = l.beltRow(2, 8, 4);
    final f = FactoryFloor.fromBlueprint(l.blueprint(30, 20));
    f.step(60, InfiniteColonyPort());
    int onBelts() =>
        belts.fold(0, (n, id) => n + (f.contentsOf(id)['ore'] ?? 0));
    await open(t, f);
    await pick(t, 'speed-0');
    final before = onBelts();
    expect(before, greaterThan(0));
    await pick(t, 'palette-belt');
    // Back along the row, west, then the far end turned north.
    await drag(t, [const TilePos(8, 4), const TilePos(5, 4)]);
    expect(f.blueprint.byId(belts[6])!.dir, Dir4.west);
    expect(f.blueprint.byId(belts[3])!.dir, Dir4.west);
    expect(onBelts(), before, reason: 'every item stayed on its belt');
    expect(f.piles, isEmpty);
    expect(conservationError(f), isEmpty);
    // Undo puts the facings back, still without touching the items.
    await withKey(t, LogicalKeyboardKey.controlLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyZ));
    expect(f.blueprint.byId(belts[6])!.dir, Dir4.east);
    expect(onBelts(), before);
    expect(conservationError(f), isEmpty);
  });

  // ---- 9. Area delete + undo -----------------------------------------------

  testWidgets('the Delete tool drags a box: red preview, then one delete',
      (t) async {
    final sim = FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.chest, pos: TilePos(4, 4)),
      const Placement(id: 2, kind: EntityKind.chest, pos: TilePos(6, 5)),
      const Placement(id: 3, kind: EntityKind.belt, pos: TilePos(5, 6)),
      const Placement(id: 4, kind: EntityKind.chest, pos: TilePos(20, 20)),
      const Placement(id: 5, kind: EntityKind.aisle, pos: TilePos(0, 5),
          span: (30, 2)),
    ]));
    await open(t, sim);
    await pick(t, 'tool-delete');
    final g = await drag(t, [const TilePos(3, 3), const TilePos(7, 7)],
        release: false);
    expect({for (final p in c.deleteTargets) p.id}, {1, 2, 3},
        reason: 'solids only: the aisle marking is kept');
    expect(painter(t).deletePreviewRects, hasLength(3));
    expect(painter(t).deleteLabel, 'Delete 2 Chest · 1 Belt');
    await g.up();
    await t.pump();
    expect(sim.removed.toSet(), {1, 2, 3});
    expect(c.history.undoDepth, 1, reason: 'one box is one undo step');
    expect(c.deleteRect, isNull);

    // Shift adds floor markings.
    final h = await drag(t, [const TilePos(10, 4), const TilePos(12, 6)],
        release: false);
    expect(c.deleteTargets, isEmpty);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect([for (final p in c.deleteTargets) p.id], [5]);
    await h.up();
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(sim.removed.last, 5);

    // A plain click still deletes just what it hits.
    await click(t, const TilePos(20, 20));
    expect(sim.removed.last, 4);
  });

  testWidgets('area delete piles held goods; undo restores the structure',
      (t) async {
    final f = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    f.step(120, InfiniteColonyPort());
    await open(t, f);
    await pick(t, 'speed-0');
    final layout = {
      for (final p in f.blueprint.placements) (p.kind, p.pos.key, p.dir),
    };
    final held = f.itemsOnFloor.values.fold(0, (a, b) => a + b);
    expect(held, greaterThan(0));
    await pick(t, 'tool-delete');
    final hallSize = f.blueprint.hall;
    await drag(t, [
      const TilePos(0, 0),
      TilePos(hallSize.w - 1, hallSize.h - 1),
    ]);
    expect(f.blueprint.placements
        .where((p) => !kOverlayKinds.contains(p.kind)), isEmpty,
        reason: 'every solid in the box is gone');
    expect(f.blueprint.placements, isNotEmpty,
        reason: 'floor markings kept without Shift');
    expect(f.piles, isNotEmpty, reason: 'what stations held is piled');
    expect(conservationError(f), isEmpty);
    final piled = [...f.piles];

    await withKey(t, LogicalKeyboardKey.controlLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyZ));
    expect({
      for (final p in f.blueprint.placements) (p.kind, p.pos.key, p.dir),
    }, layout, reason: 'undo restores the layout');
    expect(f.piles.length, piled.length,
        reason: 'undo restores structure, not goods: the piles stay');
    expect(conservationError(f), isEmpty);

    // Redo takes the box out again.
    await withKey(t, LogicalKeyboardKey.controlLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyY));
    expect(f.blueprint.placements
        .where((p) => !kOverlayKinds.contains(p.kind)), isEmpty);
    expect(conservationError(f), isEmpty);
  });

  testWidgets('every kind of edit undoes and redoes on the real floor',
      (t) async {
    final f = FactoryFloor.fromBlueprint(
        FloorBlueprint(name: 't', hall: const HallSize(30, 20)));
    await open(t, f);
    await pick(t, 'speed-0');
    Future<void> undo() => withKey(t, LogicalKeyboardKey.controlLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyZ));
    Future<void> redo() => withKey(t, LogicalKeyboardKey.controlLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyY));
    List<String> layout() => [
          for (final p in f.blueprint.placements)
            '${p.kind.name}@${p.pos}/${p.dir.name}/${p.recipe}/${p.mode}/${p.item}',
        ]..sort();

    // place
    await pick(t, 'palette-machine-packer');
    await click(t, const TilePos(10, 10));
    final m = f.blueprint.placements.single;
    final placed = layout();
    await undo();
    expect(f.blueprint.placements, isEmpty);
    await redo();
    expect(layout(), placed);

    // rotate (by key) and set mode (by the inspector's chip)
    final m2 = f.blueprint.placements.single;
    expect(m2.kind, m.kind);
    await pick(t, 'tool-select');
    await click(t, TilePos(m2.pos.x, m2.pos.y));
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.pump();
    expect(f.blueprint.placements.single.dir, Dir4.south);
    await undo();
    expect(f.blueprint.placements.single.dir, Dir4.east);
    await t.tap(find.byKey(const Key('mode-manual')));
    await t.pump();
    expect(f.blueprint.placements.single.crew, MachineMode.manual);
    await undo();
    expect(f.blueprint.placements.single.crew, MachineMode.assisted);
    await redo();
    expect(f.blueprint.placements.single.crew, MachineMode.manual);

    // hire
    await t.tap(find.byKey(const Key('hire-onFoot-plus')));
    await t.pump();
    expect(f.blueprint.roster[HandlerKind.onFoot], 1);
    await undo();
    expect(f.blueprint.roster[HandlerKind.onFoot] ?? 0, 0);
    await redo();
    expect(f.blueprint.roster[HandlerKind.onFoot], 1);

    // remove, then undo all the way back to the empty hall
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.pump();
    expect(f.blueprint.placements, isEmpty);
    while (c.history.canUndo) {
      await undo();
    }
    expect(f.blueprint.placements, isEmpty);
    expect(f.blueprint.roster, isEmpty);
    expect(c.history.redoDepth, greaterThan(0));
    // A new edit drops the redo branch.
    await pick(t, 'palette-chest');
    await click(t, const TilePos(3, 3));
    expect(c.history.canRedo, isFalse);
  });

  test('undo survives ids the floor reuses and re-places', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final f = FactoryFloor.fromBlueprint(
        FloorBlueprint(name: 't', hall: const HallSize(20, 20)));
    final c = FactoryEditorController(f, InfiniteColonyPort());
    Placement chest(int x) =>
        Placement(id: 0, kind: EntityKind.chest, pos: TilePos(x, 1));
    final a = c.history.place(chest(1)).placementId!;
    final b = c.history.place(chest(3)).placementId!;
    expect(c.history.remove(f.blueprint.byId(a)!).ok, isTrue);
    // Undo the removal: A comes back under a NEW id (the floor's max + 1).
    c.undo();
    final aBack = f.blueprint.placements.firstWhere((p) => p.pos.x == 1).id;
    expect(aBack, isNot(a));
    // Undo B's placement, then A's: each must remove the right chest.
    c.undo();
    expect([for (final p in f.blueprint.placements) p.pos.x], [1]);
    c.undo();
    expect(f.blueprint.placements, isEmpty);
    // Redo all three: A, B, then A removed again.
    c.redo();
    c.redo();
    c.redo();
    expect([for (final p in f.blueprint.placements) p.pos.x], [3]);
    expect(b, isPositive);
    c.dispose();
  });

  testWidgets('keys typed into the product tree search never edit the floor',
      (t) async {
    final sim = FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.belt, pos: TilePos(5, 5)),
    ]));
    await open(t, sim, debugTools: true);
    await click(t, const TilePos(5, 5));
    await t.sendKeyEvent(LogicalKeyboardKey.keyR); // reaches the editor
    await t.pump();
    expect(sim.rotated, [1]);
    expect(c.history.canUndo, isTrue);
    await t.tap(find.byKey(const Key('product-tree-button')));
    await t.pump();
    await t.tap(find.byKey(const Key('ptree-search')));
    await t.pump();
    await withKey(t, LogicalKeyboardKey.shiftLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyR));
    await withKey(t, LogicalKeyboardKey.controlLeft,
        () => t.sendKeyEvent(LogicalKeyboardKey.keyZ));
    expect(sim.rotated, [1], reason: 'no rotate from the search box');
    expect(c.history.canUndo, isTrue, reason: 'no undo from the search box');
  });

  // ---- 10. Run modes ---------------------------------------------------------

  testWidgets('Straight locks a wobbly belt drag to its main axis',
      (t) async {
    final sim = FakeFactorySim(hall());
    await open(t, sim);
    await pick(t, 'palette-belt');
    await pick(t, 'run-mode-straight');
    expect(c.runMode, RunMode.straight);
    await drag(t, [
      const TilePos(2, 2),
      const TilePos(4, 3),
      const TilePos(6, 1),
      const TilePos(8, 3),
    ]);
    expect([for (final p in sim.placed) p.pos],
        [for (var x = 2; x <= 8; x++) TilePos(x, 2)]);
    expect(sim.placed.every((p) => p.dir == Dir4.east), isTrue);
  });

  testWidgets('L-shape turns one corner and F flips it', (t) async {
    final sim = FakeFactorySim(hall());
    await open(t, sim);
    await pick(t, 'palette-belt');
    await t.sendKeyEvent(LogicalKeyboardKey.keyM); // freeform -> straight
    await t.sendKeyEvent(LogicalKeyboardKey.keyM); // -> L
    await t.pump();
    expect(c.runMode, RunMode.lShape);
    final g = await drag(t, [const TilePos(2, 2), const TilePos(6, 5)],
        release: false);
    expect([for (final p in c.ghost) p.placement.pos], [
      for (var x = 2; x <= 6; x++) TilePos(x, 2),
      for (var y = 3; y <= 5; y++) TilePos(6, y),
    ]);
    expect(c.ghost[3].placement.dir, Dir4.east);
    expect(c.ghost[4].placement.dir, Dir4.north, reason: 'the corner turns');
    expect(painter(t).ghostArrows, 8, reason: 'arrows along the whole run');
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.pump();
    expect([for (final p in c.ghost) p.placement.pos], [
      for (var y = 2; y <= 5; y++) TilePos(2, y),
      for (var x = 3; x <= 6; x++) TilePos(x, 5),
    ], reason: 'flipped: y first');
    await g.up();
    await t.pump();
    expect(sim.placed, hasLength(8));
  });

  testWidgets('holding Shift forces a freeform drag straight', (t) async {
    final sim = FakeFactorySim(hall());
    await open(t, sim);
    await pick(t, 'palette-belt');
    expect(c.runMode, RunMode.freeform);
    final g = await drag(t, [
      const TilePos(2, 2),
      const TilePos(5, 2),
      const TilePos(5, 4),
    ], release: false);
    expect(c.ghost, hasLength(6), reason: 'freeform follows the corner');
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect([for (final p in c.ghost) p.placement.pos],
        [for (var x = 2; x <= 5; x++) TilePos(x, 2)]);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(c.ghost, hasLength(6), reason: 'the freehand path comes back');
    await g.up();
    await t.pump();
  });

  testWidgets('aisles follow the run modes too', (t) async {
    final sim = FakeFactorySim(hall());
    await open(t, sim);
    await pick(t, 'palette-aisle');
    await pick(t, 'run-mode-lShape');
    await drag(t, [const TilePos(2, 2), const TilePos(10, 8)]);
    expect([for (final p in sim.placed) (p.pos, p.span)], [
      (const TilePos(2, 2), (10, 2)),
      (const TilePos(10, 4), (2, 6)),
    ], reason: 'two 2-wide legs, the corner paid for once');
    await pick(t, 'run-mode-straight');
    await drag(t, [const TilePos(20, 2), const TilePos(22, 12)]);
    expect(sim.placed.last.pos, const TilePos(20, 2));
    expect(sim.placed.last.span, (2, 12), reason: 'locked to y');
    await pick(t, 'run-mode-freeform');
    await drag(t, [const TilePos(30, 2), const TilePos(33, 5)]);
    expect(sim.placed.last.span, (4, 4), reason: 'freeform: the rectangle');
  });
}
