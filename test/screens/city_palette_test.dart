// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The in-flight editor offers the WHOLE catalogue, the way the 2D builder
/// does — grouped, searchable, and with locked entries shown rather than
/// hidden. A palette that silently omits half the game reads as a shorter one.
void main() {
  CitySim colony({double population = 0}) => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'pal',
      )..population = population;

  Future<void> pumpPalette(WidgetTester t, CitySim city,
      {CityEditController? c}) async {
    final controller = (c ?? CityEditController())..set(CityEditTool.utility);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CityEditOverlay(
          controller: controller,
          city: city,
          onClose: () {},
        ),
      ),
    ));
    await t.pump();
  }

  testWidgets('every building in the catalogue is offered', (t) async {
    await pumpPalette(t, colony());
    // Scrolling a list virtualises rows, so assert on the data the palette is
    // built from plus a sample of what is actually on screen.
    expect(kUtilCatalog.length, greaterThan(40));
    expect(find.text('Solar Farm'), findsOneWidget);
    expect(find.text('Fission Reactor'), findsOneWidget);
  });

  testWidgets('locked buildings are shown, with what unlocks them', (t) async {
    await pumpPalette(t, colony()); // population 0: almost everything locked
    final gated = kUtilCatalog.firstWhere((s) => s.unlockPop > 0);
    expect(find.text('pop ${gated.unlockPop}'), findsWidgets,
        reason: 'the gate is the thing that tells you what to grow toward');
  });

  testWidgets('an unlocked building shows its cost instead', (t) async {
    await pumpPalette(t, colony(population: 5000));
    final free = kUtilCatalog.firstWhere((s) => s.unlockPop == 0);
    expect(find.text('${free.buildCost.round()} ore'), findsWidgets);
  });

  testWidgets('groups are labelled, in catalogue order', (t) async {
    await pumpPalette(t, colony());
    expect(find.text('POWER'), findsOneWidget);
    // The list virtualises: the second header sits below the fold once the
    // power group has a row's worth of entries, so scroll to it.
    // The search field is a Scrollable too, so drag the list itself.
    for (var i = 0; i < 8 && find.text('CITY SERVICES').evaluate().isEmpty; i++) {
      await t.drag(find.byType(ListView).last, const Offset(0, -200));
      await t.pump();
    }
    expect(find.text('CITY SERVICES'), findsOneWidget);
  });

  testWidgets('search filters the palette', (t) async {
    final c = CityEditController();
    await pumpPalette(t, colony(), c: c);
    expect(find.text('Solar Farm'), findsOneWidget);

    await t.enterText(find.byType(TextField), 'reactor');
    await t.pump();

    expect(find.text('Fission Reactor'), findsOneWidget);
    expect(find.text('Solar Farm'), findsNothing);
  });

  testWidgets('a search that matches nothing says so', (t) async {
    await pumpPalette(t, colony());
    await t.enterText(find.byType(TextField), 'zzzz');
    await t.pump();
    expect(find.textContaining('No buildings match'), findsOneWidget);
  });

  testWidgets('picking a building selects it and holds the build tool',
      (t) async {
    final c = CityEditController();
    await pumpPalette(t, colony(population: 5000), c: c);
    await t.tap(find.text('Solar Farm'));
    await t.pump();
    expect(c.selectedUtil.label, 'Solar Farm');
    expect(c.tool, CityEditTool.utility);
  });

  testWidgets('a palette row expands to the full effect breakdown', (t) async {
    final c = CityEditController();
    await pumpPalette(t, colony(population: 5000), c: c);

    // Filter to one row first: the palette virtualises, so an unsearched
    // catalogue leaves most rows off-screen and unhittable.
    await t.enterText(find.byType(TextField), 'refinery');
    await t.pump();
    expect(find.text('Makes Fuel'), findsNothing); // collapsed

    await t.tap(find.byIcon(Icons.expand_more).first);
    await t.pump();

    // The detail names every flow, not just the headline.
    expect(find.text('Needs Ore'), findsOneWidget);
    expect(find.text('Makes Fuel'), findsOneWidget);
    expect(find.textContaining('Site'), findsWidgets);
  });

  testWidgets('only one row is open at a time', (t) async {
    final c = CityEditController()
      ..buildSearch = 'refinery'
      ..expandedLabel = 'Refinery';
    await pumpPalette(t, colony(population: 5000), c: c);
    expect(find.text('Makes Fuel'), findsOneWidget);

    // Opening another row closes this one.
    c.expandedLabel = 'Steel Mill';
    c.changed();
    await t.pump();
    expect(find.text('Makes Fuel'), findsNothing);
  });

  testWidgets('the zone picker names kind and density, as the 2D one does',
      (t) async {
    final c = CityEditController()..set(CityEditTool.zone);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CityEditOverlay(
            controller: c, city: colony(), onClose: () {}),
      ),
    ));
    await t.pump();

    for (final label in ['Residential', 'Commercial', 'Industrial']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in ['Low', 'Medium', 'High']) {
      expect(find.text(label), findsOneWidget);
    }

    // And it says what the chosen combination grows.
    await t.tap(find.text('High'));
    await t.pump();
    expect(c.density, Density.high);
    expect(find.textContaining('Towers'), findsOneWidget);
  });
}
