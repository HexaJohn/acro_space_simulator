// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Budget drawer's plant-economy lines (docs/plans/factory-floors.md §3
/// "Profit is taxed into funds (a new corporate tax line in the Budget
/// drawer)", §7 Q10 "industry deficit Budget line").
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/factory_integration/economy_fixture.dart';
import '../colony/factory_integration/factory_colony_fixture.dart';

Future<void> openBudget(WidgetTester t, CitySim city) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
      MaterialApp(home: Scaffold(body: CityGameHud(city: city))));
  await t.pump();
  await t.tap(find.text('Budget'));
  await t.pump();
}

void main() {
  // A colony without plants keeps the drawer it always had.
  testWidgets('no plant, no plant lines', (t) async {
    await openBudget(t, economyColony());
    expect(find.text('Tax income'), findsOneWidget);
    expect(find.text('Corporate tax'), findsNothing);
    expect(find.text('Industry deficit'), findsNothing);
  });

  // A private plant's tax shows as its own line, the number the Net adds.
  testWidgets('a private plant shows its corporate tax', (t) async {
    final city = economyColony();
    placePlant(city, 'steelmill');
    runDays(city, 1.01, specs: [specOf('steelmill')]);
    await openBudget(t, city);
    expect(find.text('Corporate tax'), findsOneWidget);
    expect(find.text('+${city.corporateTaxRate.toStringAsFixed(2)} §/s'),
        findsOneWidget);
    expect(find.text('Industry deficit'), findsNothing);
  });

  // A losing state plant shows the deficit the treasury pays for it.
  testWidgets('a losing state plant shows the industry deficit', (t) async {
    final city = economyColony(economy: Economy.communism);
    placePlant(city, 'steelmill');
    runDays(city, 1.01, specs: [specOf('steelmill')], inputs: 0);
    await openBudget(t, city);
    expect(find.text('Industry deficit'), findsOneWidget);
    expect(find.text('−${city.industryDeficitRate.toStringAsFixed(2)} §/s'),
        findsOneWidget);
  });
}
