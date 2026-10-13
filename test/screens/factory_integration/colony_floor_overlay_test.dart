// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A plant's floor opened over the LIVE colony view
/// (docs/plans/factory-floors.md §4). The editor is hosted inside the
/// view's own stack, not pushed as a route: a pushed opaque route offstages
/// the view, its ticker stops, and the colony that steps the floor would
/// freeze while the player watched it. And the world must not steal the
/// editor's input — the view's outer pointer Listener is an ANCESTOR of the
/// overlay and used to take the keyboard back on every click.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/render_backend.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../colony/factory_integration/factory_colony_fixture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The city game's view over [colony], software backend.
  Future<void> pumpView(WidgetTester t, CitySim colony) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: SimulationView(
        injectedCity: colony,
        cityMode: true,
        spawnDemoOrbiter: false,
        initialBackend: RenderBackend.software,
      ),
    ));
    await t.pump(const Duration(milliseconds: 16));
  }

  Future<void> frames(WidgetTester t, int n) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  /// A colony with a Steel Mill on a free lot; returns the lot.
  (CitySim, String) plantColony() {
    final colony = foundedColony();
    return (colony, placeOnFreeLot(colony, specOf('steelmill')));
  }

  testWidgets('the floor opens inside the view and the colony keeps running',
      (t) async {
    final (colony, lot) = plantColony();
    await pumpView(t, colony);
    final open = SimViewControl.instance.factoryFloor!(lot);
    await t.pump();
    expect(open['open'], lot);
    expect(find.byType(FactoryFloorScreen), findsOneWidget);
    // Not a route over the view: the view is still on stage under it.
    expect(find.byType(SimulationView), findsOneWidget);
    expect(colony.factoryFloors[lot]!.live, isNotNull,
        reason: 'the floor is live while the editor shows it');

    final before = colony.colonyTimeS;
    await frames(t, 30);
    expect(colony.colonyTimeS, greaterThan(before),
        reason: 'the colony froze under the floor editor');
    expect(find.byKey(const Key('colony-driven')), findsOneWidget,
        reason: 'the colony steps the floor, the screen only watches');
  });

  testWidgets('its back arrow closes the floor with the colony', (t) async {
    final (colony, lot) = plantColony();
    await pumpView(t, colony);
    SimViewControl.instance.factoryFloor!(lot);
    await t.pump();
    await t.tap(find.byKey(const Key('factory-back')));
    await t.pump();
    expect(find.byType(FactoryFloorScreen), findsNothing);
    expect(colony.factoryFloors[lot]!.live, isNull,
        reason: 'closeFloor ends the live sim');
  });

  testWidgets('the editor keeps the keyboard and the world does not orbit',
      (t) async {
    final (colony, lot) = plantColony();
    await pumpView(t, colony);
    final cam = SimViewControl.instance.status!();
    SimViewControl.instance.factoryFloor!(lot);
    await t.pump();
    await t.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'factory-floor',
        reason: 'R and Del must reach the editor');

    // A real click (with a pixel of jitter) on the floor canvas, and a
    // middle-drag: the editor's, never the world's camera.
    final canvas = t.getCenter(find.byKey(const Key('factory-canvas')));
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.down(canvas);
    await t.pump();
    await g.moveBy(const Offset(3, 1));
    await g.up();
    await t.pump();
    final m = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await m.down(canvas);
    await m.moveBy(const Offset(120, 40));
    await m.up();
    await t.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'factory-floor',
        reason: "the view's ancestor Listener took the keyboard back");
    final after = SimViewControl.instance.status!();
    expect(after['azimuth'], cam['azimuth']);
    expect(after['elevation'], cam['elevation']);
  });

  // A key the editor has no use for stops at the overlay: G would walk
  // out onto the colony, under the editor, from the view's key handler.
  testWidgets("the world's keys don't act under the editor", (t) async {
    final (colony, lot) = plantColony();
    await pumpView(t, colony);
    SimViewControl.instance.factoryFloor!(lot);
    await t.pump();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    expect(SimViewControl.instance.status!()['walk'], isNot(true));
    expect(find.byType(FactoryFloorScreen), findsOneWidget);
  });

  testWidgets('a plant lost while open takes the editor down', (t) async {
    final (colony, lot) = plantColony();
    await pumpView(t, colony);
    SimViewControl.instance.factoryFloor!(lot);
    await t.pump();
    colony.clearParcel(lot);
    await frames(t, 2);
    expect(find.byType(FactoryFloorScreen), findsNothing);
  });
}
