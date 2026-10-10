// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/application/usecases/local_colony_atmosphere.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_site_rules.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tower family in a colony, and the slider's retirement
/// (docs/plans/terraforming.md §4, §5.5, phase 3): the colony's production
/// step reports each tower's throttle, placement refuses a tower where its
/// gas has nowhere to come from, `terraform` is a readout of the planet's
/// sky rather than state, and the flat sandbox's towers move its air.
void main() {
  final system = RealSolarSystem.build();
  final bodies = system.all.where((b) => !b.isStar).toList();
  CelestialBody body(String id) => system.require(BodyId(id));
  CityBuildingSpec spec(String type) =>
      kUtilCatalog.firstWhere((s) => s.type == type);
  const atm = 101325.0;

  /// A colony on [bodyId] with every tower of [types] powered, computed and
  /// staffed.
  CitySim towered(String bodyId, List<String> types) {
    final city = CitySim.found(
      CityConfig(bodyId: bodyId, gridSize: 30),
      bodies: bodies,
    )..infiniteRobotics = true;
    final g = city.grid;
    final h = city.hubKey;
    // A street along the row above the hub, everything fronting it.
    for (var x = -5; x <= 12; x++) {
      city.addRoad(h - g + x);
    }
    city.placeUtil(h - 1, spec('fusion'));
    city.placeUtil(h - 2, spec('fusion'));
    city.placeUtil(h - 3, spec('datacenter'));
    city.placeUtil(h - 4, spec('datacenter'));
    for (var i = 0; i < types.length; i++) {
      city.placeUtil(h + 1 + 2 * i, spec(types[i]));
    }
    city.population = 2000;
    city.stock[Commodity.electronics] = 1e6;
    city.recompute();
    return city;
  }

  group('the colony reports its towers', () {
    test('each tower kind is summed on its throttle', () {
      final city = towered('mars', [
        TerraformTowers.oxygenator,
        TerraformTowers.greenhouseFactory,
        TerraformTowers.regolithBaker,
        TerraformTowers.carbonSequestrator,
        TerraformTowers.retentionArray,
      ]);
      for (var i = 0; i < 4; i++) {
        city.advance(0.5);
      }
      final r = city.towerRuns;
      expect(r.oxygenator, greaterThan(0.5));
      expect(r.greenhouse, greaterThan(0.5));
      expect(r.baker, greaterThan(0.5));
      expect(r.sequestrator, greaterThan(0.5));
      expect(r.retention, greaterThan(0.5));
      expect(city.oxygenatorRun, r.oxygenator);
    });

    test('every tower is in the catalogue, late game gated late', () {
      for (final t in TerraformTowers.all) {
        final s = spec(t);
        expect(s.group, 'env', reason: t);
        expect(s.claimsOwnSite, t == TerraformTowers.oxygenator,
            reason: 'the new towers keep generated colonies as they were');
      }
      final array = spec(TerraformTowers.retentionArray);
      expect(array.unlockPop,
          kUtilCatalog.map((s) => s.unlockPop).reduce((a, b) => a > b ? a : b));
      expect(array.powerDraw, greaterThanOrEqualTo(500));
    });
  });

  group('placement: a tower where its gas has nowhere to come from', () {
    CitySim on(String id) => CitySim.found(
        CityConfig(bodyId: id, gridSize: 12),
        bodies: bodies);

    test('a Regolith Baker needs carbonates or nitrates in the soil', () {
      final baker = spec(TerraformTowers.regolithBaker);
      expect(on('mars').placementRefusal(baker), isNull);
      expect(on('earth').placementRefusal(baker), contains('soil'));
      expect(on('moon').placementRefusal(baker), isNotNull);
    });

    test('a Greenhouse Factory needs a sky to hold its agent', () {
      final f = spec(TerraformTowers.greenhouseFactory);
      expect(on('mars').placementRefusal(f), isNull);
      expect(on('moon').placementRefusal(f), contains('no air'));
    });

    test('a Carbon Sequestrator needs CO2 above its floor', () {
      final s = spec(TerraformTowers.carbonSequestrator);
      expect(on('mars').placementRefusal(s), isNull);
      expect(on('earth').placementRefusal(s), isNull,
          reason: "Earth's 400 ppm is above the 280 ppm floor");
      expect(on('moon').placementRefusal(s), isNotNull);
      expect(on('titan').placementRefusal(s), isNotNull);
    });
  });

  group('the slider is retired', () {
    test('a tower running in a colony alone changes no air', () {
      // With no planet integrating it, a colony's towers used to fake the
      // air through the slider. Now nothing the colony does by itself moves
      // its sky: the planet's inventory is the only way.
      final city = towered('mars', [TerraformTowers.oxygenator]);
      final before = city.body;
      for (var i = 0; i < 200; i++) {
        city.advance(0.5);
      }
      expect(city.oxygenatorRun, greaterThan(0.5));
      expect(identical(city.body, before), isTrue);
      expect(city.sky.pressureAtm, before.atmosphere!.seaLevelPressure / atm);
      expect(city.terraform, city.sky.breathableProgress);
    });

    test('"terraform" is the derived sky\'s progress to breathable', () {
      CitySim found(CelestialBody b) => CitySim.found(
          CityConfig(bodyId: b.id.value, gridSize: 12),
          bodies: bodies)
        ..body = b;
      expect(found(body('earth')).terraform, 1);
      final bare = found(body('mars')).terraform;
      expect(bare, lessThan(0.05));
      // A Mars vented to 0.17 atm of nearly pure oxygen: the oxygen and
      // toxicity tests pass, the pressure does not.
      final a = PlanetAtmosphere.seed(body('mars'))!;
      a.add(
          AtmosphereGas.oxygen,
          a.molesForPartialPressure(
                  a.moles, AtmosphereGas.oxygen, 0.17 * atm) -
              a.molesOf(AtmosphereGas.oxygen));
      final vented = found(a.applyTo(body('mars')));
      expect(vented.breathable, isFalse);
      expect(vented.terraform, inInclusiveRange(0.5, 0.99));
      expect(vented.terraform, greaterThan(bare));
    });

    test("an old save's terraform value is read and ignored", () {
      final city = towered('mars', [TerraformTowers.oxygenator]);
      final json = city.toJson();
      expect(json.containsKey('terraform'), isFalse);
      json['terraform'] = 0.95;
      final back = CitySim.fromJson(json, bodies: bodies);
      expect(back.terraform, back.sky.breathableProgress);
      expect(back.terraform, lessThan(0.05));
    });
  });

  group('the flat sandbox has a planet', () {
    test("its towers move its air, and the colony breathes it", () {
      final city = towered('mars', [TerraformTowers.oxygenator]);
      final air = LocalColonyAtmosphere();
      const dt = 3600.0 * 24;
      for (var i = 0; i < 30; i++) {
        city.advance(0.5);
        air.step(city, dt);
      }
      final state = air.state!;
      expect(identical(city.planetAir, state), isTrue);
      // A month of one tower: ~5.7e14 mol, most of Mars's own oxygen again.
      expect(state.molesOf(AtmosphereGas.oxygen),
          greaterThan(state.referenceMolesOf(AtmosphereGas.oxygen) * 1.5));
      expect(city.body.composition!.fractions[AtmosphereGas.oxygen]!,
          greaterThan(body('mars')
              .composition!
              .fractions[AtmosphereGas.oxygen]!),
          reason: "the colony's body is republished with the new air");
      expect(state.ledger!.colonies[city.id], isNotNull,
          reason: 'the panel can say which colony did it');
    });

    test('re-sited, it seeds the new world afresh', () {
      final city = towered('mars', [TerraformTowers.oxygenator]);
      final air = LocalColonyAtmosphere();
      for (var i = 0; i < 10; i++) {
        city.advance(0.5);
        air.step(city, 3600.0 * 24);
      }
      city.body = body('moon');
      air.step(city, 0);
      expect(air.state!.bodyId, 'moon');
      expect(air.state!.isAtRest, isTrue);
    });

    test('a re-pick of the same world keeps its air', () {
      final city = towered('mars', [TerraformTowers.oxygenator]);
      final air = LocalColonyAtmosphere();
      for (var i = 0; i < 10; i++) {
        city.advance(0.5);
        air.step(city, 3600.0 * 24);
      }
      final o2 = city.body.composition!.fractions[AtmosphereGas.oxygen]!;
      city.body = body('mars'); // the planet picker hands back the reference
      air.step(city, 0);
      expect(city.body.composition!.fractions[AtmosphereGas.oxygen],
          closeTo(o2, 1e-6));
    });
  });
}
