// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/station_ports.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_painter.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/floor_layout_index.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/machine_ports_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_factory_sim.dart';

/// The editor side of explicit ports (docs/plans/factory-floors.md §10 item
/// 19): notches drawn on placed machines and ghosts, a connected port lit,
/// a hover tip naming the slot, and an arm aimed at a machine explained.
void main() {
  setUpAll(ensureFactoryCatalog);
  late FactoryEditorController c;
  late Finder canvas;

  /// A smelter at (10, 10) with its ore belt on Input 1 (10, 11) and a
  /// pig-iron belt on Output 1 (13, 11); its slag port is open. An arm at
  /// (9, 15) faces open floor past the smelter.
  FloorBlueprint hall() => FloorBlueprint(
        name: 'Ports',
        hall: const HallSize(30, 24),
        placements: [
          const Placement(
              id: 1, kind: EntityKind.machine, pos: TilePos(10, 10),
              recipe: 'steel:smelt'),
          const Placement(id: 2, kind: EntityKind.belt, pos: TilePos(9, 11)),
          const Placement(id: 3, kind: EntityKind.belt, pos: TilePos(14, 11)),
          const Placement(id: 4, kind: EntityKind.arm, pos: TilePos(9, 15)),
        ],
      );

  Future<void> open(WidgetTester t, FactorySim s) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: FactoryFloorScreen(sim: s)));
    await t.pump();
    c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    canvas = find.byKey(const Key('factory-canvas'));
  }

  Offset at(WidgetTester t, TilePos p) =>
      t.getTopLeft(canvas) + c.tileCenterLocal(p);

  Future<TestGesture> hover(WidgetTester t, TilePos p) async {
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at(t, p) + const Offset(0, 1));
    await g.moveTo(at(t, p));
    await t.pump();
    return g;
  }

  FactoryFloorPainter painter(WidgetTester t) => t
      .widget<CustomPaint>(
          find.descendant(of: canvas, matching: find.byType(CustomPaint)))
      .painter! as FactoryFloorPainter;

  test('connected ports read off the layout, as the sim connects them', () {
    final ix = FloorLayoutIndex(hall(), 0);
    final marks = portMarksOf(ix.byId(1)!, ix);
    String role(PortMark m) => '${m.port.role.name}${m.port.slot}';
    expect({for (final m in marks) role(m): m.connected}, {
      'input0': true,
      'output0': true,
      'output1': false,
      'hand0': false,
    });
    expect(marks.firstWhere((m) => role(m) == 'output1').label,
        'Output 2: Slag (byproduct)');
    // Every notch sits on its port's tile.
    for (final m in marks) {
      expect(Rect.fromLTWH(m.port.tile.x.toDouble(), m.port.tile.y.toDouble(),
              1, 1).contains(m.rect.center), isTrue);
    }
    expect(portTipAt(ix, const TilePos(10, 11)), 'Input 1: Ore');
    expect(portTipAt(ix, const TilePos(12, 13)),
        'Output 2: Slag (byproduct) — not connected');
    expect(portTipAt(ix, const TilePos(11, 11)), isNull,
        reason: 'the middle of the machine is no port');
  });

  testWidgets('placed machines and ghosts draw their notches; hover names one',
      (t) async {
    await open(t, FakeFactorySim(hall()));
    await t.pump(const Duration(milliseconds: 16));
    expect(painter(t).portMarks, 4, reason: 'the smelter: 1 in, 2 out, hand');
    expect(painter(t).litPorts, 2, reason: 'its ore and pig-iron belts');

    final g = await hover(t, const TilePos(10, 11));
    expect(find.byKey(const Key('port-tip')), findsOneWidget);
    expect(find.text('Input 1: Ore'), findsOneWidget);
    await g.moveTo(at(t, const TilePos(20, 20)));
    await t.pump();
    expect(find.byKey(const Key('port-tip')), findsNothing);

    // A machine ghost carries its ports too.
    await t.tap(find.byKey(const Key('palette-machine-press')));
    await t.pump();
    await g.moveTo(at(t, const TilePos(20, 4)));
    await t.pump();
    expect(painter(t).portMarks, greaterThan(4),
        reason: 'the press ghost adds its notches');
    await g.removePointer();
  });

  testWidgets('an arm aimed at a machine says it does nothing', (t) async {
    await open(t, FakeFactorySim(hall()));
    expect(armMachineNote(c.index.byId(4)!, c.index.solidAt), isNull,
        reason: 'it faces open floor');
    c.select(4);
    await t.pump();
    expect(find.byKey(const Key('arm-machine-note')), findsNothing);
    // Re-laid onto the smelter's west face (9, 12) → (10, 12).
    final ix = FloorLayoutIndex(
        hall()
          ..placements.removeWhere((p) => p.id == 4)
          ..placements.add(const Placement(
              id: 4, kind: EntityKind.arm, pos: TilePos(9, 12))),
        1);
    expect(armMachineNote(ix.byId(4)!, ix.solidAt), kArmMachineNote);
  });
}
