// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The site sheet's factory-floor rows (docs/plans/factory-floors.md §4):
/// "Factory floor" only on a placed plant that has a floor, owner actions,
/// the demolition question asked only when a DESIGNED floor would be lost,
/// and the detail sheet reading the floor's rates rather than the spec's.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_site_actions.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/colony_floor_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../colony/factory_integration/factory_colony_fixture.dart';

/// Opens [site]'s menu from a host with a "Factory floor" hook that records
/// the site it was asked to open.
Future<List<String>> openMenu(WidgetTester t, CitySim sim, String site,
    {bool withHook = true}) async {
  t.view.physicalSize = const Size(1200, 1400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final opened = <String>[];
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showCitySiteMenu(
            context: context,
            sim: sim,
            site: site,
            spec: sim.siteSpec(site)!,
            onChanged: () {},
            hooks: CitySiteHooks(
                onOpenFactoryFloor: withHook ? opened.add : null),
          ),
          child: const Text('open menu'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open menu'));
  await t.pumpAndSettle();
  return opened;
}

CityBuildingSpec parkSpec() => kUtilCatalog.firstWhere((s) => s.type == 'park');

void main() {
  // The action exists for a placed floor plant, and tapping it hands the
  // host the site (which shows the overlay).
  testWidgets('a floor plant offers "Factory floor"', (t) async {
    final sim = foundedColony();
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    final opened = await openMenu(t, sim, lot);
    expect(find.text('Factory floor'), findsOneWidget);
    await t.tap(find.text('Factory floor'));
    await t.pumpAndSettle();
    expect(opened, [lot]);
  });

  // A building with no floor never shows it: floors are for placed plants
  // only (user decision, 2026-10-12).
  testWidgets('a park does not', (t) async {
    final sim = foundedColony();
    final lot = placeOnFreeLot(sim, parkSpec());
    await openMenu(t, sim, lot);
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Factory floor'), findsNothing);
  });

  // A host that cannot keep the colony running under the editor passes no
  // hook, and must not offer one.
  testWidgets('no hook, no action', (t) async {
    final sim = foundedColony();
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    await openMenu(t, sim, lot, withHook: false);
    expect(find.text('Factory floor'), findsNothing);
  });

  // A firm's plant can be taken into state hands from its menu.
  testWidgets('Nationalise makes it a state plant', (t) async {
    final sim = foundedColony()..economy = Economy.capitalism;
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    expect(sim.ownerOf(lot).isState, isFalse);
    await openMenu(t, sim, lot);
    await t.tap(find.text('Nationalise'));
    await t.pumpAndSettle();
    expect(sim.ownerOf(lot).isState, isTrue);
  });

  // A template floor is rebuilt for free with the plant, so its demolition
  // asks nothing.
  testWidgets('demolishing a template floor asks nothing', (t) async {
    final sim = foundedColony();
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    await openMenu(t, sim, lot);
    await t.tap(find.text('Demolish'));
    await t.pumpAndSettle();
    expect(find.textContaining('custom floor design will be lost'),
        findsNothing);
    expect(sim.parcelBuildings.containsKey(lot), isFalse);
  });

  // A designed floor is the player's work: the question comes first, "Keep
  // it" keeps the plant, and only agreeing demolishes it.
  testWidgets('demolishing a designed floor asks first', (t) async {
    final sim = foundedColony();
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    sim.factoryFloors[lot]!.designed = true;

    await openMenu(t, sim, lot);
    await t.tap(find.text('Demolish'));
    await t.pumpAndSettle();
    expect(find.textContaining('custom floor design will be lost'),
        findsOneWidget);
    await t.tap(find.byKey(const Key('floor-loss-cancel')));
    await t.pumpAndSettle();
    expect(sim.parcelBuildings.containsKey(lot), isTrue);

    await t.tap(find.text('open menu'));
    await t.pumpAndSettle();
    await t.tap(find.text('Demolish'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('floor-loss-confirm')));
    await t.pumpAndSettle();
    expect(sim.parcelBuildings.containsKey(lot), isFalse);
    expect(sim.factoryFloors[lot], isNull);
  });

  // The detail lines read the floor: a measured design making 2 steel/s
  // says 2, not the spec's nameplate 1.5, and says who runs it.
  test('floor detail lines are the floor rates', () {
    final sim = foundedColony();
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    sim.factoryFloors[lot]!
      ..designed = true
      ..dirty = false
      ..rates = const MeasuredRates(
          inPerS: {'ore': 2.5},
          outPerS: {'steel': 2.0},
          powerKw: 4000,
          jobs: 20,
          seconds: 300);
    final lines = floorSiteLines(sim, lot);
    expect(lines, contains('+2.00 Steel/s'));
    expect(lines, contains('−2.50 Ore/s'));
    expect(lines, contains('20 jobs'));
    expect(lines.any((l) => l.contains('1.5')), isFalse);
    expect(lines.first, anyOf('State plant', startsWith('Private')));
  });
}
