// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony HUD's plant economy (docs/plans/factory-floors.md §7 Q8-Q11):
/// the Budget drawer's plant lines and its help text, a failed firm's
/// offer answered from the HUD, and the stock drawer listing a floor's
/// intermediates under COMPONENTS.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/firm_policy.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../colony/factory_integration/factory_colony_fixture.dart';

Future<void> pumpHud(WidgetTester t, CitySim city) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
      MaterialApp(home: Scaffold(body: CityGameHud(city: city))));
  await t.pump();
}

void main() {
  // An upgrade no firm would pay back is a subsidy: once one is paid, the
  // drawer says how much, beside the plant's tax line.
  testWidgets('the Budget drawer shows industrial subsidies', (t) async {
    final city = foundedColony();
    placeOnFreeLot(city, specOf('steelmill'));
    city.colonyEconomy.industrialSubsidyTotal = 42;
    await pumpHud(t, city);
    await t.tap(find.text('Budget'));
    await t.pump();
    expect(find.text('Corporate tax'), findsOneWidget);
    expect(find.text('Industrial subsidies'), findsOneWidget);
    expect(find.text('§42 paid'), findsOneWidget);
    // Buildings still cost ore; the help says where the plant money goes.
    expect(find.textContaining("paid in ore, a plant's floor too"),
        findsOneWidget);
    expect(find.textContaining('taxed on its profit'), findsOneWidget);
  });

  // A closed plant's offer shows on the HUD with only the options its
  // economy allows, and a button resolves it.
  testWidgets('a firm offer is answered from the HUD', (t) async {
    final city = foundedColony()..economy = Economy.capitalism;
    final lot = placeOnFreeLot(city, specOf('steelmill'));
    city.colonyEconomy.offers.add(FirmOffer(
        site: lot, options: closureOptions(city.economyKind)));
    await pumpHud(t, city);
    expect(find.byKey(const Key('firm-offer')), findsOneWidget);
    expect(find.text('Sell to new firm'), findsOneWidget);
    await t.tap(find.byKey(const Key('firm-offer-nationalise')));
    await t.pump();
    expect(city.pendingFirmOffers, isEmpty);
    expect(city.ownerOf(lot).isState, isTrue);
    expect(find.byKey(const Key('firm-offer')), findsNothing);
  });

  // Communism has no buyers: no "Sell" button to press.
  testWidgets('a communist offer has no sale', (t) async {
    final city = foundedColony()..economy = Economy.communism;
    final lot = placeOnFreeLot(city, specOf('steelmill'));
    city.colonyEconomy.offers.add(FirmOffer(
        site: lot, options: closureOptions(city.economyKind)));
    await pumpHud(t, city);
    expect(find.text('Nationalise'), findsOneWidget);
    expect(find.text('Sell to new firm'), findsNothing);
  });

  // Pig iron shipped out of a plate line is stock like any good, but no
  // colony commodity names it: the drawer lists it under COMPONENTS with
  // the item's own label instead of hiding it.
  testWidgets('the stock drawer lists a floor intermediate', (t) async {
    final city = foundedColony();
    city.stock[FactoryItems.pigIron.id] = 12;
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CityEditOverlay(
                controller: CityEditController(), city: city, onClose: null))));
    await t.pump();
    await t.tap(find.text('Stock'));
    await t.pump();
    expect(find.text(FactoryItems.pigIron.label), findsOneWidget);
    expect(find.text('COMPONENTS'), findsOneWidget);
  });
}
