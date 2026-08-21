// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_site_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The in-world editor is the whole colony interface now.
///
/// There is no longer a button out to a flat map: the readouts that used to sit
/// behind it are drawers on the toolbar, and every action a building carries is
/// on the building itself.
void main() {
  CitySim colony() {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'inworld',
    );
    city.layout.addRoad(const RoadSpline(
        id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
    return city;
  }

  Widget host(CitySim city, CityEditController c) => MaterialApp(
        home: Scaffold(
          body: CityEditOverlay(
            controller: c,
            city: city,
            onClose: () {},
          ),
        ),
      );

  testWidgets('the toolbar offers no way out to a flat map', (t) async {
    await t.pumpWidget(host(colony(), CityEditController()));
    expect(find.byTooltip('City panels'), findsNothing);
    expect(find.byIcon(Icons.dashboard), findsNothing);
    // Closing the editor is still there — that returns to flight, not to a map.
    expect(find.byTooltip('Close editor'), findsOneWidget);
  });

  testWidgets('the readouts are drawers on the in-world toolbar', (t) async {
    final city = colony()..population = 42;
    await t.pumpWidget(host(city, CityEditController()));

    for (final r in CityReadout.values) {
      expect(find.text(r.label), findsOneWidget, reason: '${r.label} tab');
    }

    // Opening one shows the colony's actual numbers, in the world.
    await t.tap(find.text('City'));
    await t.pumpAndSettle();
    expect(find.text('COLONY STATUS'), findsOneWidget);
    expect(find.text('42'), findsWidgets, reason: 'live population');

    // One at a time: opening Politics closes City.
    await t.tap(find.text('Politics'));
    await t.pumpAndSettle();
    expect(find.text('COLONY STATUS'), findsNothing);
    expect(find.text('GOVERNMENT'), findsOneWidget);

    // Tapping the open tab again closes it, giving the view back.
    await t.tap(find.text('Politics'));
    await t.pumpAndSettle();
    expect(find.text('GOVERNMENT'), findsNothing);
  });

  testWidgets('a spaceport carries its actions wherever it was placed',
      (t) async {
    final city = colony();
    final lot = city.layout.autoParcels.first;
    city.parcelBuildings[lot.id] =
        kUtilCatalog.firstWhere((s) => s.label == 'Spaceport');

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showCitySiteMenu(
              context: ctx,
              sim: city,
              site: lot.id,
              spec: city.siteSpec(lot.id)!,
              onChanged: () {},
              // The in-world host offers pad targeting; it offers no bridge
              // actions, because you are already in the world.
              hooks: CitySiteHooks(
                onOpenVab: () {},
                onTargetPad: (_) {},
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    expect(find.text('Spaceport'), findsOneWidget);
    expect(find.text('Design & launch craft'), findsOneWidget);
    expect(find.text('Land lander on this pad'), findsOneWidget);
    expect(find.text('Request assistance'), findsOneWidget);
    expect(find.text('Schedule deliveries'), findsOneWidget);
    expect(find.text('Target this pad'), findsOneWidget);
    expect(find.text('Demolish'), findsOneWidget);
    // The flat map's escape hatches are NOT offered in the world.
    expect(find.text('Pilot a landing'), findsNothing);
    expect(find.text('Launch in 3D sim'), findsNothing);
  });

  testWidgets('booking a delivery on a lot-placed port sticks', (t) async {
    final city = colony();
    final lot = city.layout.autoParcels.first;
    city.parcelBuildings[lot.id] =
        kUtilCatalog.firstWhere((s) => s.label == 'Spaceport');
    city.stock[Commodity.ore] = 500;

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showDeliveryConfig(
                context: ctx, sim: city, site: lot.id, onChanged: () {}),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('No deliveries booked.'), findsOneWidget);
    expect(find.text('1 pad'), findsOneWidget);

    await t.tap(find.text('Add delivery'));
    await t.pumpAndSettle();
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    expect(city.deliveries[lot.id], hasLength(1),
        reason: 'the booking is keyed on the LOT, not a grid cell');
  });

  testWidgets('the world drawer cannot re-site a live colony', (t) async {
    final city = colony();
    await t.pumpWidget(host(city, CityEditController()));
    await t.tap(find.text('World'));
    await t.pumpAndSettle();

    // The knobs that ARE safe on a live colony come first in the drawer.
    expect(find.text('TIME WARP'), findsOneWidget);
    expect(find.text('DIFFICULTY'), findsOneWidget);

    // The host world is stated, not offered as a choice: a live colony stands
    // at a real lat/lon on a real planet, and a dropdown that moved it between
    // worlds mid-flight would strand everything holding a reference to it.
    await t.scrollUntilVisible(find.text('Planet'), 120,
        scrollable: find.byType(Scrollable).last);
    await t.pumpAndSettle();
    expect(find.text(city.body.name), findsOneWidget);
    expect(find.byType(DropdownButton<CelestialBody>), findsNothing);
    expect(find.byType(DropdownButton<Biome>), findsNothing);
  });
}
