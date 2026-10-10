// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_site_rules.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// One set of placement rules for every path that builds ([CitySiteRules]),
/// and the colony state those rules (and the governor) read surviving a
/// save.
void main() {
  const atm = 101325.0;
  final mars = fixtureBodies.firstWhere((b) => b.id.value == 'mars');
  final harvester = kUtilCatalog.firstWhere((s) => s.type == 'o2harvester');

  /// Mars with its oxygen raised to [pO2Atm], as the inventory publishes it.
  CelestialBody marsWith(double pO2Atm) {
    final a = PlanetAtmosphere.seed(mars)!;
    a.add(
        AtmosphereGas.oxygen,
        a.molesForPartialPressure(a.moles, AtmosphereGas.oxygen, pO2Atm * atm) -
            a.molesOf(AtmosphereGas.oxygen));
    return a.applyTo(mars);
  }

  /// A Mars starter colony that can afford and has unlocked anything.
  CitySim marsKit([CelestialBody? sky]) {
    final city = starterKit(body: 'mars')
      ..ignoreUnlocks = true
      ..stock[Commodity.ore] = 1e6;
    if (sky != null) city.body = sky;
    return city;
  }

  group('a harvester is refused where the sky has no oxygen to draw', () {
    test('the shared rule', () {
      final bare = marsKit();
      expect(bare.o2Harvestable, isFalse);
      expect(bare.placementRefusal(harvester),
          '${bare.body.name} has no harvestable oxygen — use Electrolysis '
          'instead.');
      expect(bare.idleForSky(harvester), isTrue);
      final vented = marsKit(marsWith(0.08));
      expect(vented.o2Harvestable, isTrue);
      expect(vented.placementRefusal(harvester), isNull);
      expect(vented.idleForSky(harvester), isFalse);
      // Only the harvester: a farm is not the sky's business.
      final farm = kUtilCatalog.firstWhere((s) => s.type == 'farm');
      expect(bare.placementRefusal(farm), isNull);
      expect(bare.idleForSky(farm), isFalse);
    });

    test('the in-world editor refuses it on a lot, before the ore is spent',
        () {
      final city = marsKit();
      final c = CityEditController()
        ..gateCity = city
        ..tool = CityEditTool.utility
        ..selectedUtil = harvester;
      final ore = city.stockOf(Commodity.ore);
      final built = Map.of(city.parcelBuildings);
      for (final lot in freeLots(city)) {
        c.applyToParcel(city, lot.id);
        expect(c.blocked, city.placementRefusal(harvester));
      }
      expect(city.parcelBuildings, built, reason: 'nothing was placed');
      expect(city.stockOf(Commodity.ore), ore, reason: 'and nothing paid');

      // The same lot, under a sky with oxygen in it, takes the harvester:
      // it was the sky that refused, and nothing else.
      city.body = marsWith(0.08);
      var placed = false;
      for (final lot in freeLots(city)) {
        c.applyToParcel(city, lot.id);
        if (city.parcelBuildings[lot.id]?.type == 'o2harvester') {
          placed = true;
          break;
        }
      }
      expect(placed, isTrue, reason: '${c.blocked}');
      expect(city.stockOf(Commodity.ore), ore - harvester.buildCost);
    });

    test('and on its own staked plot', () {
      final city = marsKit();
      final c = CityEditController()
        ..gateCity = city
        ..selectedUtil = harvester;
      final before = city.layout.manualParcels.length;
      expect(c.claimOwnSite(city, const Vec2(400, 400)), isFalse);
      expect(c.blocked, city.placementRefusal(harvester));
      expect(city.layout.manualParcels.length, before);
    });
  });

  group('the famine state survives a save', () {
    CitySim roundTrip(CitySim c) =>
        CitySim.fromJson(c.toJson(), bodies: fixtureBodies);

    test('a fed colony saves as it always has', () {
      final j = starterKit().toJson();
      expect(j.containsKey('starved'), isFalse);
      expect(j.containsKey('foodSecurity'), isFalse);
    });

    test('a colony saved starving loads starving, and goes on the same', () {
      final city = starterKit(body: 'mars');
      run(city, 5);
      city
        ..starved = true
        ..foodSecurity = 0.08
        ..happiness = 0.3;
      final loaded = roundTrip(city);
      expect(loaded.starved, isTrue);
      expect(loaded.foodSecurity, 0.08);
      // One tick on: unsaved, the copy loaded fed, and its happiness left
      // the famine floor the original stayed on.
      city.advance(0.5);
      loaded.advance(0.5);
      expect(loaded.starved, city.starved);
      expect(loaded.foodSecurity, city.foodSecurity);
      expect(loaded.happiness, city.happiness);
    });
  });
}
