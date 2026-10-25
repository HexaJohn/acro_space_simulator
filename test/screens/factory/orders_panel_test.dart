// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/dock_geometry.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/dock_logistics.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/supply_world.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Orders panel and the dock ghost (§10 items 3, 4): the ghost snaps
/// a dock to the wall, the header opens the panel beside (not over) the
/// canvas, an order placed there books a truck, a number typed into its
/// field never fires an editor shortcut, and the dock inspector shows the
/// dock's truck and loading area.
void main() {
  late FactoryEditorController c;
  late FactoryFloor f;

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1700, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    f = FactoryFloor.fromBlueprint(FloorBlueprint(
        name: 'Orders Hall',
        hall: const HallSize(30, 20),
        placements: [
          const Placement(
              id: 1,
              kind: EntityKind.receivingDock,
              pos: TilePos(0, 5),
              item: 'tubes',
              span: kDockSpan),
        ]))
      ..logistics = FloorLogistics(world: SupplyWorld.sandbox());
    await t.pumpWidget(MaterialApp(home: FactoryFloorScreen(sim: f)));
    await t.pump();
    c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    c.setSpeed(0);
  }

  testWidgets('a dock ghost snaps to the nearest wall', (t) async {
    await open(t);
    c.choose(EntityKind.shippingDock);
    final canvas = find.byKey(const Key('factory-canvas'));
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    final at = t.getTopLeft(canvas) + c.tileCenterLocal(const TilePos(27, 12));
    await g.addPointer(location: at + const Offset(0, 1));
    await g.moveTo(at);
    await t.pump();
    final p = c.ghost.single.placement;
    expect(p.dir, Dir4.west, reason: 'east wall, facing in');
    expect(p.footprint.x1, 30);
    expect(c.ghost.single.check.ok, isTrue);
    await g.removePointer();
  });

  testWidgets('Orders: place a one-off truck, typing fires no shortcut',
      (t) async {
    await open(t);
    expect(find.byKey(const Key('orders-panel')), findsNothing);
    await t.tap(find.byKey(const Key('orders-button')));
    await t.pump();
    expect(find.byKey(const Key('orders-panel')), findsOneWidget);
    expect(find.byKey(const Key('order-place')), findsOneWidget);

    // Pick the tube supplier.
    await t.tap(find.byKey(const Key('order-supplier')));
    await t.pump(); await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.text('Ares Steelworks').last);
    await t.pump(); await t.pump(const Duration(milliseconds: 500));

    // Type a quantity: R in a text field must not rotate anything.
    c.choose(EntityKind.belt);
    final dir = c.ghostDir;
    await t.tap(find.byKey(const Key('order-qty')));
    await t.pump();
    await t.enterText(find.byKey(const Key('order-qty')), '2');
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.pump();
    expect(c.ghostDir, dir, reason: 'R typed in a field is text');

    await t.tap(find.byKey(const Key('order-place')));
    await t.pump();
    final lg = f.logistics!;
    final o = lg.orders.values.single;
    expect((o.good, o.dock, o.packs), ('steel', 1, 2 * 10),
        reason: 'first good of Ares, 2 trucks of 10');
    f.step(1, c.port);
    expect(lg.trucks, isNotEmpty);
    await t.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('ETA'), findsWidgets);
  });

  testWidgets('the dock inspector shows its truck and loading area',
      (t) async {
    await open(t);
    final lg = f.logistics!;
    lg.bay(1).area.add('crate:tubes', 2);
    c.select(1);
    await t.pump();
    expect(find.byKey(const Key('dock-card')), findsOneWidget);
    expect(find.textContaining('Loading area: 2 / $kLoadingAreaSlots'),
        findsOneWidget);
    await t.tap(find.byKey(const Key('dock-conveyor')));
    await t.pump();
    expect(lg.bay(1).conveyor, isTrue);
  });
}
