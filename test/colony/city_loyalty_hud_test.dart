// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The City Game HUD's loyalty chip and notice banner
/// (docs/plans/colony-secession.md §3.5): absent while the colony is loyal
/// and calm, and naming the stage once it is not.
void main() {
  Future<void> pumpHud(WidgetTester t, CitySim city) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: CityGameHud(city: city))));
    await t.pump();
  }

  testWidgets('a loyal colony shows no loyalty chip', (t) async {
    final city = starterKit();
    await pumpHud(t, city);
    expect(find.textContaining('Restless'), findsNothing);
  });

  testWidgets('a restless colony shows its stage, and a notice is raised',
      (t) async {
    final city = starterKit();
    city.loyalty
      ..level = 0.52
      ..stage = LoyaltyStage.restless
      ..onRevolt('REVOLT! 3 citizens fled, treasury raided.');
    await pumpHud(t, city);
    await t.pump();
    expect(find.text('Restless 37%'), findsOneWidget,
        reason: 'the stage and the loyalty, after the revolt hit');
    expect(find.textContaining('REVOLT! 3 citizens fled'), findsOneWidget,
        reason: 'the revolt toast the HUD never had');
    expect(city.loyalty.notices, isEmpty, reason: 'drained into the banner');
  });
}
