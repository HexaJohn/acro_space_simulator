// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_factory_sim.dart';

const _press = FactoryRecipe(
    id: 'test:press', label: 'Press One', station: StationKind.press,
    inputs: [ItemQty('steel', 1)], outputs: [ItemQty('tubes', 1)],
    seconds: 2, powerKw: 20);
const _press2 = FactoryRecipe(
    id: 'test:press2', label: 'Press Two', station: StationKind.press,
    inputs: [ItemQty('steel', 2)], outputs: [ItemQty('tubes', 1)],
    seconds: 3, powerKw: 30);

/// The floor editor (docs/plans/factory-floors.md §4) against a recording
/// fake: every test pins one thing the UI must ask the sim for, so the
/// wave-2 swap to the real floor changes no behaviour the player sees.
void main() {
  FactoryRecipes.register(_press);
  FactoryRecipes.register(_press2);

  late FakeFactorySim sim;
  late FactoryEditorController c;
  late Finder canvas;

  FloorBlueprint hall([List<Placement>? pl]) => FloorBlueprint(
      name: 'Test Hall', hall: const HallSize(40, 30), placements: pl);

  Future<void> open(WidgetTester t, FakeFactorySim s,
      {void Function(FloorBlueprint)? onSave}) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    sim = s;
    await t.pumpWidget(MaterialApp(
        home: FactoryFloorScreen(sim: s, onSaveBlueprint: onSave)));
    await t.pump();
    c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    canvas = find.byKey(const Key('factory-canvas'));
  }

  Offset at(WidgetTester t, TilePos p) =>
      t.getTopLeft(canvas) + c.tileCenterLocal(p);

  Future<void> click(WidgetTester t, TilePos p,
      {int buttons = kPrimaryButton}) async {
    final g = await t.startGesture(at(t, p),
        kind: PointerDeviceKind.mouse, buttons: buttons);
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

  /// Picking a palette entry and clicking the floor must send exactly that
  /// kind, tile and facing to the sim — the editor never edits the layout
  /// itself.
  testWidgets('palette place calls sim.place with kind, pos and dir',
      (t) async {
    await open(t, FakeFactorySim(hall()));
    await t.tap(find.byKey(const Key('palette-chest')));
    await t.pump();
    await click(t, const TilePos(5, 5));
    expect(sim.placed, hasLength(1));
    expect(sim.placed.single.kind, EntityKind.chest);
    expect(sim.placed.single.pos, const TilePos(5, 5));
    expect(sim.placed.single.dir, Dir4.east);

    // A machine is centred on the cursor and carries the station's first
    // recipe (the real catalog's, registered by the editor).
    await t.tap(find.byKey(const Key('palette-machine-press')));
    await t.pump();
    await click(t, const TilePos(20, 15));
    final m = sim.placed.last;
    expect(m.kind, EntityKind.machine);
    expect(m.recipe, FactoryRecipes.forStation(StationKind.press).first.id);
    expect(m.pos, const TilePos(19, 14));
  });

  /// R turns the ghost before it is placed (not a placed object), and the
  /// turned facing is what gets placed.
  testWidgets('R rotates the ghost', (t) async {
    await open(t, FakeFactorySim(hall()));
    await t.tap(find.byKey(const Key('palette-belt')));
    await t.pump();
    final g = await hover(t, const TilePos(8, 8));
    expect(c.ghost.single.placement.dir, Dir4.east);
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.pump();
    expect(c.ghostDir, Dir4.east.turnCw);
    expect(c.ghost.single.placement.dir, Dir4.east.turnCw);
    await g.removePointer();
    await click(t, const TilePos(8, 8));
    expect(sim.placed.single.dir, Dir4.east.turnCw);
    expect(sim.rotated, isEmpty, reason: 'nothing placed was rotated');
  });

  /// A ghost that overlaps something is red, and clicking it sends nothing:
  /// the preview and the commit must agree.
  testWidgets('refused placement shows invalid and does not call place',
      (t) async {
    await open(t, FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.chest, pos: TilePos(5, 5)),
    ])));
    await t.tap(find.byKey(const Key('palette-chest')));
    await t.pump();
    final g = await hover(t, const TilePos(5, 5));
    expect(c.ghostValid, isFalse);
    expect(c.ghost.single.check.refusal, EditRefusal.overlaps);
    await g.removePointer();
    await click(t, const TilePos(5, 5));
    expect(sim.placed, isEmpty);
    expect(find.byKey(const Key('factory-message')), findsOneWidget);
  });

  /// The right button never edits the floor (no right-click delete, no
  /// accidental place); only primary does the tool's work.
  testWidgets('secondary click does nothing', (t) async {
    await open(t, FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.chest, pos: TilePos(5, 5)),
    ])));
    await t.tap(find.byKey(const Key('palette-chest')));
    await t.pump();
    await click(t, const TilePos(9, 9), buttons: kSecondaryButton);
    await t.tap(find.byKey(const Key('tool-delete')));
    await t.pump();
    await click(t, const TilePos(5, 5), buttons: kSecondaryButton);
    expect(sim.placed, isEmpty);
    expect(sim.removed, isEmpty);
  });

  /// Removal is a tool (and the Del key on a selection), never a right
  /// click.
  testWidgets('Delete tool and Del key call remove', (t) async {
    await open(t, FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.chest, pos: TilePos(5, 5)),
      const Placement(id: 2, kind: EntityKind.chest, pos: TilePos(7, 5)),
    ])));
    await t.tap(find.byKey(const Key('tool-delete')));
    await t.pump();
    await click(t, const TilePos(5, 5));
    expect(sim.removed, [1]);

    await t.tap(find.byKey(const Key('tool-select')));
    await t.pump();
    await click(t, const TilePos(7, 5));
    expect(c.selectedId, 2);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.pump();
    expect(sim.removed, [1, 2]);
  });

  /// Dragging lays a belt on every tile the drag crossed, each pointing at
  /// the next, so the run is connected end to end without touching R.
  testWidgets('drag-lay belts makes a connected, directed run', (t) async {
    await open(t, FakeFactorySim(hall()));
    await t.tap(find.byKey(const Key('palette-belt')));
    await t.pump();
    final g = await t.startGesture(at(t, const TilePos(2, 2)),
        kind: PointerDeviceKind.mouse);
    await g.moveTo(at(t, const TilePos(6, 2)));
    await t.pump();
    await g.moveTo(at(t, const TilePos(6, 5)));
    await t.pump();
    await g.up();
    await t.pump();
    final run = sim.placed;
    expect(run, hasLength(8));
    expect(run.every((p) => p.kind == EntityKind.belt), isTrue);
    expect(run.first.pos, const TilePos(2, 2));
    expect(run.last.pos, const TilePos(6, 5));
    for (var i = 0; i < run.length - 1; i++) {
      expect(run[i].pos.step(run[i].dir), run[i + 1].pos,
          reason: 'belt $i must feed belt ${i + 1}');
    }
    expect(run.first.dir, Dir4.east);
    expect(run.last.dir, Dir4.north, reason: 'the end keeps the heading');
  });

  /// Dragging a spanned kind lays one placement covering the dragged
  /// rectangle, not a tile at a time.
  testWidgets('drag-rect lays a spanned aisle', (t) async {
    await open(t, FakeFactorySim(hall()));
    await t.tap(find.byKey(const Key('palette-aisle')));
    await t.pump();
    final g = await t.startGesture(at(t, const TilePos(10, 4)),
        kind: PointerDeviceKind.mouse);
    await g.moveTo(at(t, const TilePos(3, 5)));
    await t.pump();
    await g.up();
    await t.pump();
    expect(sim.placed.single.kind, EntityKind.aisle);
    expect(sim.placed.single.pos, const TilePos(3, 4));
    expect(sim.placed.single.span, (8, 2));
  });

  /// The inspector's recipe dropdown and crew-mode chips go straight to
  /// setRecipe / setMode on the selected machine.
  testWidgets('recipe and mode pickers call setRecipe and setMode',
      (t) async {
    await open(t, FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.machine, pos: TilePos(20, 10),
          recipe: 'test:press'),
    ])));
    await click(t, const TilePos(21, 11));
    expect(c.selectedId, 1);
    expect(find.byKey(const Key('inspector')), findsOneWidget);
    await t.tap(find.byKey(const Key('mode-automated')));
    await t.pump();
    expect(sim.modes, [(1, MachineMode.automated)]);
    await t.tap(find.byKey(const Key('inspect-recipe')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('picker-option-test:press2')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(sim.recipes, [(1, 'test:press2')]);
  });

  /// The roster's +/- hire and let go through the sim, one at a time.
  testWidgets('roster +/- calls hire', (t) async {
    await open(t, FakeFactorySim(hall()));
    await t.tap(find.byKey(const Key('hire-forklift-plus')));
    await t.pump();
    await t.tap(find.byKey(const Key('hire-forklift-plus')));
    await t.pump();
    await t.tap(find.byKey(const Key('hire-forklift-minus')));
    await t.pump();
    expect(sim.hires, [
      (HandlerKind.forklift, 1),
      (HandlerKind.forklift, 1),
      (HandlerKind.forklift, -1),
    ]);
    final count = t.widget<Text>(find.byKey(const Key('hire-forklift-count')));
    expect(count.data, '1');
  });

  /// "Save as blueprint" hands out a COPY: later edits to the live floor
  /// must not rewrite the saved design.
  testWidgets('save as blueprint fires the callback with a copy', (t) async {
    FloorBlueprint? saved;
    await open(
        t,
        FakeFactorySim(hall([
          const Placement(id: 1, kind: EntityKind.chest, pos: TilePos(5, 5)),
        ])),
        onSave: (bp) => saved = bp);
    await t.tap(find.byKey(const Key('save-blueprint')));
    await t.pump();
    expect(saved, isNotNull);
    expect(saved!.placements, hasLength(1));
    expect(identical(saved, sim.blueprint), isFalse);
    sim.place(const Placement(id: 0, kind: EntityKind.chest,
        pos: TilePos(9, 9)));
    expect(saved!.placements, hasLength(1));
  });

  /// While open the floor runs: the ticker steps the sim every frame, the
  /// readout reads the floor's LIFETIME counters (never taking the period
  /// ledger, which is the colony's), and pause really stops it.
  testWidgets('the ticker steps the sim; pause stops it', (t) async {
    await open(t, FakeFactorySim(hall()));
    for (var i = 0; i < 70; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(sim.steps, greaterThan(30));
    expect(sim.stepped, closeTo(70 * 0.016, 0.05));
    expect(sim.ledgersTaken, 0, reason: 'the editor never takes the ledger');
    expect(c.ratesOut['steel'], closeTo(2, 1e-9),
        reason: 'the fake ships two steel per sim second');

    await t.tap(find.byKey(const Key('speed-0')));
    await t.pump();
    final before = sim.stepped;
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(sim.stepped, before);

    await t.tap(find.byKey(const Key('speed-4')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 16));
    expect(sim.stepped - before, closeTo(4 * 0.032, 0.02));
  });

  /// The biggest hall the plan expects (~550 × 400 tiles) with 2,000
  /// placements, handlers and belt items paints without throwing, with
  /// every overlay on, and the static layers are built once, not per frame.
  testWidgets('a 550x400 hall with 2,000 placements paints', (t) async {
    final pl = <Placement>[];
    var id = 1;
    pl.add(Placement(id: id++, kind: EntityKind.aisle, pos: const TilePos(0, 200),
        span: (550, 2)));
    pl.add(Placement(id: id++, kind: EntityKind.craneBay,
        pos: const TilePos(300, 50), span: (120, 30)));
    for (var i = 0; i < 1500; i++) {
      pl.add(Placement(id: id++, kind: EntityKind.belt,
          pos: TilePos(5 + i % 500, 10 + 3 * (i ~/ 500)),
          dir: Dir4.values[i % 4]));
    }
    for (var i = 0; i < 300; i++) {
      pl.add(Placement(id: id++, kind: EntityKind.machine,
          pos: TilePos(5 + (i % 100) * 5, 40 + (i ~/ 100) * 5),
          recipe: 'test:press', mode: MachineMode.values[i % 3]));
    }
    for (var i = 0; i < 194; i++) {
      pl.add(Placement(id: id++,
          kind: const [EntityKind.chest, EntityKind.arm, EntityKind.rack,
              EntityKind.crossing][i % 4],
          pos: TilePos(5 + (i % 98) * 5, 100 + (i ~/ 98) * 4)));
    }
    pl.add(Placement(id: id++, kind: EntityKind.receivingDock,
        pos: const TilePos(10, 0), item: FactoryItems.ore.id));
    pl.add(Placement(id: id++, kind: EntityKind.shippingDock,
        pos: const TilePos(20, 399)));
    pl.add(Placement(id: id++, kind: EntityKind.chargingBay,
        pos: const TilePos(30, 300)));
    pl.add(Placement(id: id++, kind: EntityKind.staging,
        pos: const TilePos(40, 300), span: (10, 4)));
    expect(pl.length, 2000);
    final s = FakeFactorySim(FloorBlueprint(
        name: 'Big', hall: const HallSize(550, 400), placements: pl))
      ..crew = [
        for (var i = 0; i < 40; i++)
          HandlerView(id: i, kind: HandlerKind.values[i % 5], x: 10.0 + i * 7,
              y: 20.0 + i, state: HandlerState.carrying, carrying: 'ore',
              carryingCount: 1),
      ]
      ..belt = [
        for (var i = 0; i < 1500; i += 3)
          BeltItemView(pl[2 + i].pos, 'steel', (i % 10) / 10),
      ];
    await open(t, s);
    final st = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen));
    for (final o in FactoryOverlay.values) {
      await t.tap(find.byKey(Key('overlay-${o.name}')));
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    sw.stop();
    expect(t.takeException(), isNull);
    expect(st.layerBuilds, 1, reason: 'static layers are cached by layoutRev');
    // Zoom in on a corner (labels + grid) and paint again.
    c.zoomAt(const Offset(100, 100), 20);
    await t.pump(const Duration(milliseconds: 16));
    expect(t.takeException(), isNull);
    // A loose sanity bound, not a benchmark: 20 test frames of a full hall.
    expect(sw.elapsedMilliseconds, lessThan(10000));
  });

  /// A plain click (no drag) with a spanned tool lays the 2x2 the hover
  /// previewed, not the 1x1 a zero-size drag rectangle would make.
  testWidgets('plain click with a spanned tool lays the previewed span',
      (t) async {
    await open(t, FakeFactorySim(hall()));
    await t.tap(find.byKey(const Key('palette-aisle')));
    await t.pump();
    final g = await hover(t, const TilePos(6, 6));
    expect(c.ghost.single.placement.span, kDefaultSpan);
    await g.removePointer();
    final down = await t.startGesture(at(t, const TilePos(6, 6)),
        kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(c.ghost.single.placement.span, kDefaultSpan,
        reason: 'pressing must not shrink the preview');
    await down.up();
    await t.pump();
    expect(sim.placed.single.kind, EntityKind.aisle);
    expect(sim.placed.single.pos, const TilePos(6, 6));
    expect(sim.placed.single.span, kDefaultSpan);
  });

  /// Handing the screen a different sim (or port) rebinds the editor to it:
  /// the old sim stops stepping, edits and paint go to the new one, and the
  /// layer cache is rebuilt even though both sims share layoutRev 0.
  testWidgets('swapping the sim rebinds the controller and layer cache',
      (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = FakeFactorySim(hall());
    final b = FakeFactorySim(FloorBlueprint(
        name: 'Other', hall: const HallSize(20, 10)));
    Widget app(FakeFactorySim s, [FactoryColonyPort? p]) =>
        MaterialApp(home: FactoryFloorScreen(sim: s, port: p));
    await t.pumpWidget(app(a));
    await t.pump(const Duration(milliseconds: 16));
    final st =
        t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen));
    final first = st.controller;
    final sandbox = first.port;
    // A rebuild with the same sim keeps the controller and its sandbox.
    await t.pumpWidget(app(a));
    expect(identical(st.controller, first), isTrue);
    expect(identical(st.controller.port, sandbox), isTrue,
        reason: 'the default port is made once, not per build');

    await t.pumpWidget(app(b));
    await t.pump(const Duration(milliseconds: 16));
    expect(identical(st.controller.sim, b), isTrue);
    expect(identical(st.controller.port, sandbox), isTrue);
    expect(st.layerBuilds, 1, reason: 'a fresh cache built for the new sim');
    expect(st.controller.index.blueprint, same(b.bp));
    final aSteps = a.steps;
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(a.steps, aSteps, reason: 'the old sim no longer runs');
    expect(b.steps, greaterThan(0));

    final port = StockColonyPort();
    await t.pumpWidget(app(b, port));
    expect(identical(st.controller.port, port), isTrue);
    expect(t.takeException(), isNull);
  });

  /// An arm's pick filter is set from the inspector. The editor surface has
  /// no setItem, so it is a remove + place of the same arm with the filter,
  /// and the selection follows the re-placed arm.
  testWidgets('arm inspector sets the pick filter by remove + place',
      (t) async {
    await open(t, FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.arm, pos: TilePos(5, 5),
          dir: Dir4.north),
    ])));
    await click(t, const TilePos(5, 5));
    expect(c.selectedId, 1);
    await t.tap(find.byKey(const Key('inspect-arm-item')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    // Every plant chain's items are registered, so 'ore' sits well down
    // the list: search for it (§10 item 16).
    await t.enterText(find.byKey(const Key('picker-search')), 'ore');
    await t.pump();
    await t.tap(find.byKey(Key('picker-option-${FactoryItems.ore.id}')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(sim.removed, [1]);
    final arm = sim.placed.single;
    expect(arm.kind, EntityKind.arm);
    expect(arm.pos, const TilePos(5, 5));
    expect(arm.dir, Dir4.north);
    expect(arm.item, FactoryItems.ore.id);
    final sel = c.selectedId;
    expect(sel, isNotNull, reason: 'the selection follows the new arm');
    expect(c.index.byId(sel!)?.item, FactoryItems.ore.id);

    // Back to "any item": the filter is cleared, not kept.
    await t.tap(find.byKey(const Key('inspect-arm-item')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('picker-search')), 'any');
    await t.pump();
    await t.tap(find.byKey(const Key('picker-option-*any')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(sim.removed, [1, sel]);
    expect(sim.placed.last.item, isNull);
    expect(sim.placed.last.pos, const TilePos(5, 5));
  });

  /// A crossing is a walkable belt tile: a belt run dragged across an aisle
  /// is laid as crossings there, and a crossing laid on a belt replaces it
  /// (keeping its direction).
  testWidgets('belts over an aisle become crossings; crossing replaces belt',
      (t) async {
    await open(t, FakeFactorySim(hall([
      const Placement(id: 1, kind: EntityKind.aisle, pos: TilePos(5, 0),
          span: (2, 30)),
      const Placement(id: 2, kind: EntityKind.belt, pos: TilePos(10, 10),
          dir: Dir4.north),
    ])));
    await t.tap(find.byKey(const Key('palette-belt')));
    await t.pump();
    final g = await t.startGesture(at(t, const TilePos(3, 4)),
        kind: PointerDeviceKind.mouse);
    await g.moveTo(at(t, const TilePos(8, 4)));
    await t.pump();
    await g.up();
    await g.removePointer();
    await t.pump();
    final run = sim.placed;
    expect(run.map((p) => p.kind), [
      EntityKind.belt, EntityKind.belt, EntityKind.crossing,
      EntityKind.crossing, EntityKind.belt, EntityKind.belt,
    ]);
    expect(run.every((p) => p.dir == Dir4.east), isTrue);

    await t.tap(find.byKey(const Key('palette-crossing')));
    await t.pump();
    final h = await hover(t, const TilePos(10, 10));
    expect(c.ghostValid, isTrue, reason: 'a crossing may go on a belt');
    await h.removePointer();
    await click(t, const TilePos(10, 10));
    expect(sim.removed, [2]);
    expect(sim.placed.last.kind, EntityKind.crossing);
    expect(sim.placed.last.pos, const TilePos(10, 10));
    expect(sim.placed.last.dir, Dir4.north);
    expect(c.index.beltDirAt(const TilePos(10, 10)), Dir4.north,
        reason: 'a crossing carries items along its dir like a belt');
  });
}
