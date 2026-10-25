// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/searchable_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every item and recipe picker on the floor editor is the one shared
/// type-to-search picker (docs/plans/factory-floors.md §10 item 16): label
/// or id substring, case-insensitive, grouped, keyboard navigable, Esc
/// closes, and typing in it never fires the editor's keys.
void main() {
  const opts = [
    PickerOption<String>(
        value: 'a', id: 'crate:steel', label: 'Steel ×10', group: 'PACKED'),
    PickerOption<String>(value: 'b', id: 'ore', label: 'Ore', group: 'GOODS'),
    PickerOption<String>(
        value: 'c', id: 'steel', label: 'Steel', group: 'GOODS'),
  ];

  test('matches a substring of the label or the id, any case', () {
    List<String> ids(String q) =>
        [for (final o in filterPickerOptions(opts, q)) o.id];
    expect(ids(''), ['crate:steel', 'ore', 'steel']);
    expect(ids('STEEL'), ['crate:steel', 'steel']);
    expect(ids('crate:'), ['crate:steel'], reason: 'by id');
    expect(ids('×10'), ['crate:steel'], reason: 'by label');
    expect(ids('  or '), ['ore'], reason: 'trimmed');
    expect(ids('zinc'), isEmpty);
  });

  /// A bare app with one picker; returns what onChanged received.
  Future<List<String>> bare(WidgetTester t) async {
    final picked = <String>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SearchablePicker<String>(
          key: const Key('p'),
          title: 'Pick',
          options: opts,
          selectedId: 'ore',
          onChanged: picked.add,
        ),
      ),
    ));
    await t.tap(find.byKey(const Key('p')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    return picked;
  }

  testWidgets('groups its matches under headings', (t) async {
    await bare(t);
    expect(find.byKey(const Key('picker-group-PACKED')), findsOneWidget);
    expect(find.byKey(const Key('picker-group-GOODS')), findsOneWidget);
    await t.enterText(find.byKey(const Key('picker-search')), 'ore');
    await t.pump();
    expect(find.byKey(const Key('picker-group-PACKED')), findsNothing);
    expect(find.byKey(const Key('picker-option-ore')), findsOneWidget);
    expect(find.byKey(const Key('picker-option-steel')), findsNothing);
  });

  testWidgets('arrow keys move the highlight and Enter picks it', (t) async {
    final picked = await bare(t);
    await t.enterText(find.byKey(const Key('picker-search')), 'steel');
    await t.pump();
    // Typing resets the highlight to the first match (crate:steel).
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(picked, ['c']);
    expect(find.byKey(const Key('picker-dialog')), findsNothing);
  });

  testWidgets('Esc closes without choosing', (t) async {
    final picked = await bare(t);
    expect(find.byKey(const Key('picker-dialog')), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('picker-dialog')), findsNothing);
    expect(picked, isEmpty);
  });

  // ---- on the editor ------------------------------------------------------

  late FactoryEditorController c;
  late FactoryFloor f;

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    ensureFactoryCatalog();
    f = FactoryFloor.fromBlueprint(FloorBlueprint(
      name: 'Picker Hall',
      hall: const HallSize(40, 30),
      placements: [
        for (var x = 2; x <= 6; x++)
          Placement(id: x - 1, kind: EntityKind.belt, pos: TilePos(x, 5)),
        const Placement(
            id: 20, kind: EntityKind.arm, pos: TilePos(10, 10)),
        Placement(
            id: 21,
            kind: EntityKind.machine,
            pos: const TilePos(20, 20),
            recipe: FactoryRecipes.forStation(StationKind.smelter).first.id),
      ],
    ));
    await t.pumpWidget(MaterialApp(home: FactoryFloorScreen(sim: f)));
    await t.pump();
    c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    c.setSpeed(0);
  }

  Finder pickerOf(String key) => find.byWidgetPredicate(
      (w) => w is SearchablePicker && w.key == Key(key));

  testWidgets('every item and recipe picker is the searchable one',
      (t) async {
    await open(t);
    for (final (kind, key) in [
      ('palette-receivingDock', 'palette-item'),
      ('palette-shippingDock', 'palette-item'),
      ('palette-chest', 'palette-item'),
      ('palette-arm', 'palette-item'),
      ('palette-machine-assembler', 'palette-recipe'),
    ]) {
      await t.tap(find.byKey(Key(kind)));
      await t.pump();
      expect(pickerOf(key), findsOneWidget, reason: '$kind → $key');
    }
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.byType(DropdownButton<String?>), findsNothing);
    c.setTool(FactoryTool.select);
    c.select(20);
    await t.pump();
    expect(pickerOf('inspect-arm-item'), findsOneWidget);
    c.select(21);
    await t.pump();
    expect(pickerOf('inspect-recipe'), findsOneWidget);
  });

  testWidgets('searching the dock item picker sets the dock item', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('palette-receivingDock')));
    await t.pump();
    await t.tap(find.byKey(const Key('palette-item')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('picker-search')), 'TUBES');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(c.itemChoice, isNotNull);
    expect(
        '${c.itemChoice} ${FactoryItems.byId(c.itemChoice!)!.label}'
            .toLowerCase(),
        contains('tubes'));
  });

  testWidgets('typing in a picker never fires the editor keys', (t) async {
    await open(t);
    // One undoable edit first, so a stray Ctrl+Z would show.
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    final canvas = find.byKey(const Key('factory-canvas'));
    Offset at(TilePos p) => t.getTopLeft(canvas) + c.tileCenterLocal(p);
    await mouse.addPointer(location: at(const TilePos(6, 5)));
    await mouse.moveTo(at(const TilePos(6, 5)) + const Offset(1, 0));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    await t.pump();
    expect(c.history.undoDepth, 1);
    // Hover a belt so a stray X would delete it.
    await mouse.moveTo(at(const TilePos(3, 5)));
    await t.pump();

    await t.tap(find.byKey(const Key('palette-belt')));
    await t.pump();
    await t.tap(find.byKey(const Key('palette-chest')));
    await t.pump();
    final dir = c.ghostDir, mode = c.runMode, flip = c.lFlip;
    final belts = f.blueprint.placements.length;
    await t.tap(find.byKey(const Key('palette-item')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('picker-search')));
    await t.pump();
    for (final k in [
      LogicalKeyboardKey.keyR,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.delete,
    ]) {
      await t.sendKeyEvent(k);
    }
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(c.ghostDir, dir, reason: 'R');
    expect(c.runMode, mode, reason: 'M');
    expect(c.lFlip, flip, reason: 'F');
    expect(f.blueprint.placements.length, belts, reason: 'X / Del');
    expect(c.history.undoDepth, 1, reason: 'Ctrl+Z');
    expect(c.sweeping, isFalse);
    expect(find.byKey(const Key('picker-dialog')), findsOneWidget,
        reason: 'and the picker is still open for typing');
    await mouse.removePointer();
  });
}
