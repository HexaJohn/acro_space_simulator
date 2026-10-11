// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_war.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/combat/combat_hooks.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/combat/occupation_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// An occupied colony on screen: combat.md §7A.
void main() {
  CitySim occupied() {
    final city = starterKit();
    run(city, 5);
    city.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..independentAtS = city.colonyTimeS;
    city.applyCombatWrite(OccupyWrite(PortGarrison(
      opId: 1,
      homeColonyId: 'home',
      count: 5,
      perTrooperDay: const {Commodity.rations: 2},
      stock: const {Commodity.rations: 30},
      occupation: true,
    )));
    return city;
  }

  testWidgets('the HUD reads Occupied, and the panel says who holds it and how '
      'far the charter is', (t) async {
    t.view.physicalSize = const Size(1600, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = occupied();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: CityGameHud(city: city))));
    await t.pump();
    expect(find.text('Occupied 20%'), findsOneWidget);
    expect(find.byKey(const ValueKey('occupation-panel')), findsOneWidget);
    expect(find.text('Occupied — held by 5 troopers'), findsOneWidget);
    expect(find.textContaining('its charter comes back'), findsOneWidget);
  });

  testWidgets('its orders go through the host, and only a ready charter can be '
      'restored', (t) async {
    addTearDown(CombatHooks.clear);
    final city = occupied();
    final restored = <CitySim>[], withdrawn = <CitySim>[];
    CombatHooks.restoreCharter = restored.add;
    CombatHooks.withdrawGarrison = withdrawn.add;
    Future<void> show() => t.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: OccupationPanel(city: city)))));
    await show();
    final restore = t.widget<TextButton>(find.byKey(const ValueKey('occupation-restore')));
    expect(restore.onPressed, isNull, reason: 'not earned yet');
    await t.tap(find.byKey(const ValueKey('occupation-withdraw')));
    expect(withdrawn, [city]);
    city.loyalty
      ..level = 0.7
      ..charterSinceS = city.colonyTimeS - 11 * 120;
    await show();
    expect(find.textContaining('earned its charter back'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('occupation-restore')));
    expect(restored, [city]);
  });

  testWidgets('with no host to order through, it shows no orders', (t) async {
    final city = occupied();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: OccupationPanel(city: city))));
    expect(find.byKey(const ValueKey('occupation-restore')), findsNothing);
    expect(find.byKey(const ValueKey('occupation-withdraw')), findsNothing);
  });
}
