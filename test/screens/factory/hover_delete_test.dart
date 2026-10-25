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
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_painter.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../colony/factory/factory_test_support.dart';

/// The hover-delete hotkey (docs/plans/factory-floors.md §10 item 12):
/// hold X and whatever the cursor rests on or sweeps over is removed, with
/// no tool switch and no selection, the whole sweep one undo step. Driven
/// the way the player meets it: a real mouse hovering the canvas and real
/// key events, on the real floor.
void main() {
  late FactoryEditorController c;
  late FactoryFloor f;
  late Finder canvas;

  const kPortMillHall = HallSize(28, 10);
  const kPortMillWalkers = 2;

  /// A compact port-correct steel line (the Steel Mill template's chain on
  /// a 28 × 10 hall), laid here so this test doesn't hang on the template's
  /// layout. Every machine faces east (ports per `station_ports.dart`):
  /// ore belts into the smelter's input port; pig iron leaves its front
  /// port by belt into the furnace; its slag port belts round into the tube
  /// press. The crane carries billets furnace → mill between their hand
  /// ports in one bay; steel belts mill → packer; the forklift clears steel
  /// crates from the packer's hand port (worked from the aisle) to the
  /// dock; walkers clear the press's tubes from its hand port to shipping.
  FloorBlueprint portMill() {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 3, item: 'ore');
    l.beltRow(2, 3, 3); // → smelter input (4, 3)
    l.add(EntityKind.machine, 4, 2, recipe: SteelRecipes.smelt.id);
    l.beltRow(8, 9, 3); // pig iron (7, 3) → furnace input (10, 3)
    l.add(EntityKind.machine, 10, 2,
        recipe: SteelRecipes.cast.id, mode: MachineMode.assisted);
    l.add(EntityKind.machine, 15, 2,
        recipe: SteelRecipes.roll.id, mode: MachineMode.assisted);
    // Hand ports (11, 2) and (17, 2) and their outside tiles under the hook.
    l.add(EntityKind.craneBay, 10, 1, span: (10, 4));
    l.add(EntityKind.belt, 20, 3); // steel (19, 3) → packer input (21, 3)
    l.add(EntityKind.machine, 21, 2, recipe: SteelRecipes.packSteel.id);
    // The packer's hand port (22, 2) is worked from (22, 1) on the aisle.
    l.add(EntityKind.aisle, 20, 0, span: (8, 2));
    l.add(EntityKind.chargingBay, 24, 2);
    l.add(EntityKind.shippingDock, 26, 2);
    // Slag (6, 5) → north, then east into the press input (8, 7).
    l.add(EntityKind.belt, 6, 6, dir: Dir4.north);
    l.beltRow(6, 7, 7);
    l.add(EntityKind.machine, 8, 6, recipe: SteelRecipes.tube.id);
    l.add(EntityKind.shippingDock, 12, 6); // tubes, walked from (9, 5)
    return FloorBlueprint(
      name: 'Port Mill',
      hall: kPortMillHall,
      placements: l.out,
      roster: {
        HandlerKind.onFoot: kPortMillWalkers,
        HandlerKind.forklift: 1,
        HandlerKind.crane: 1,
      },
    );
  }

  /// A blank hall with a row of east belts at y = 5, x = 2..9 (ids 1..8),
  /// and an aisle under x = 20..23.
  FloorBlueprint hall() => FloorBlueprint(
        name: 'Sweep Hall',
        hall: const HallSize(40, 30),
        placements: [
          for (var x = 2; x <= 9; x++)
            Placement(
                id: x - 1, kind: EntityKind.belt, pos: TilePos(x, 5)),
          const Placement(
              id: 50,
              kind: EntityKind.aisle,
              pos: TilePos(20, 10),
              span: (4, 2)),
        ],
      );

  Future<void> open(WidgetTester t, FactoryFloor floor,
      {bool debugTools = false}) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    f = floor;
    await t.pumpWidget(MaterialApp(
        home: FactoryFloorScreen(sim: floor, debugTools: debugTools)));
    await t.pump();
    c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    c.setSpeed(0);
    canvas = find.byKey(const Key('factory-canvas'));
  }

  Offset at(WidgetTester t, TilePos p) =>
      t.getTopLeft(canvas) + c.tileCenterLocal(p);

  Future<TestGesture> mouse(WidgetTester t, TilePos p) async {
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at(t, p) + const Offset(0, 1));
    await g.moveTo(at(t, p));
    await t.pump();
    return g;
  }

  Set<int> beltXs() => {
        for (final p in f.blueprint.placements)
          if (p.kind == EntityKind.belt) p.pos.x,
      };

  FactoryFloorPainter painter(WidgetTester t) => t
      .widget<CustomPaint>(
          find.descendant(of: canvas, matching: find.byType(CustomPaint)))
      .painter! as FactoryFloorPainter;

  testWidgets('X removes what the cursor is over: no tool, no selection',
      (t) async {
    await open(t, FactoryFloor.fromBlueprint(hall()));
    final g = await mouse(t, const TilePos(4, 5));
    expect(c.tool, FactoryTool.select);
    expect(c.selectedId, isNull);
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(beltXs(), isNot(contains(4)));
    expect(beltXs().length, 7, reason: 'only the one under the cursor');
    await t.sendKeyUpEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(c.tool, FactoryTool.select, reason: 'no tool switch');
    expect(c.history.undoDepth, 1);
    await g.removePointer();
  });

  testWidgets('holding X while sweeping deletes along the path, one undo step',
      (t) async {
    await open(t, FactoryFloor.fromBlueprint(hall()));
    final g = await mouse(t, const TilePos(2, 5));
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    await g.moveTo(at(t, const TilePos(3, 5)));
    await t.pump();
    // A fast flick: one pointer event straight from x = 3 to x = 7. The
    // tiles between are still swept.
    await g.moveTo(at(t, const TilePos(7, 5)));
    await t.pump();
    await t.sendKeyUpEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(beltXs(), {8, 9});
    expect(c.history.undoDepth, 1, reason: 'the whole sweep is one step');
    expect(c.history.undoLabel, 'Delete sweep');

    // After release, moving deletes nothing more.
    await g.moveTo(at(t, const TilePos(9, 5)));
    await t.pump();
    expect(beltXs(), {8, 9});

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(beltXs(), {for (var x = 2; x <= 9; x++) x},
        reason: 'one Ctrl+Z brings the whole sweep back');
    await g.removePointer();
  });

  testWidgets('a held X shows a red outline on its target', (t) async {
    await open(t, FactoryFloor.fromBlueprint(hall()));
    final g = await mouse(t, const TilePos(12, 12)); // empty floor
    expect(painter(t).sweepRect, isNull, reason: 'only while X is held');
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(c.sweeping, isTrue);
    // Nothing to delete here: the ring sits on the hover tile.
    final tile = painter(t).sweepRect;
    expect(tile, isNotNull);
    expect(tile!.center, const Offset(12.5, 12.5));
    expect(tile.width, lessThan(1));
    // Over an aisle the ring stays tile-sized (markings are kept without
    // Shift); with Shift it grows to the aisle X would now remove.
    await g.moveTo(at(t, const TilePos(21, 10)));
    await t.pump();
    expect(painter(t).sweepRect!.width, lessThan(1));
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(painter(t).sweepRect!.left, closeTo(20 - 0.08, 1e-9));
    expect(painter(t).sweepRect!.width, closeTo(4 + 0.16, 1e-9));
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(painter(t).sweepRect, isNull, reason: 'gone once X is let go');
    await g.removePointer();
  });

  testWidgets('floor markings need Shift+X, like the area delete', (t) async {
    await open(t, FactoryFloor.fromBlueprint(hall()));
    final g = await mouse(t, const TilePos(21, 10));
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(f.blueprint.placements.any((p) => p.kind == EntityKind.aisle),
        isTrue);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(f.blueprint.placements.any((p) => p.kind == EntityKind.aisle),
        isFalse);
    await g.removePointer();
  });

  testWidgets('goods a swept station held become floor piles', (t) async {
    ensureFactoryCatalog();
    final floor = FactoryFloor.fromBlueprint(portMill());
    floor.step(120, InfiniteColonyPort());
    await open(t, floor);
    final m = floor.blueprint.placements.firstWhere((p) =>
        p.kind == EntityKind.machine && floor.contentsOf(p.id).isNotEmpty);
    final pilesBefore = floor.piles.length;
    final g = await mouse(t, m.pos);
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(floor.blueprint.placements.any((p) => p.id == m.id), isFalse);
    expect(floor.piles.length, greaterThan(pilesBefore));
    expect(conservationError(floor), isEmpty);
    await g.removePointer();
  });

  testWidgets('X typed into a text field never deletes', (t) async {
    await open(t, FactoryFloor.fromBlueprint(hall()), debugTools: true);
    final g = await mouse(t, const TilePos(4, 5));
    // The debug product tree's search sits inside the editor's focus.
    await t.tap(find.byKey(const Key('product-tree-button')));
    await t.pump();
    await t.pump();
    await t.tap(find.byKey(const Key('ptree-search')));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(beltXs().length, 8, reason: 'X went to the text field');
    expect(c.sweeping, isFalse);
    await g.removePointer();
  });

  testWidgets('X pressed with the cursor off the floor deletes nothing',
      (t) async {
    await open(t, FactoryFloor.fromBlueprint(hall()));
    final g = await mouse(t, const TilePos(4, 5));
    // Over to the palette: the floor's hover must not linger.
    await g.moveTo(t.getCenter(find.byKey(const Key('tool-delete'))));
    await t.pump();
    expect(c.hover, isNull);
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(beltXs().length, 8);
    await g.removePointer();
  });
}
