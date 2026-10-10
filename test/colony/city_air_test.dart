// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// A colony breathes the planet's REAL air (docs/plans/terraforming.md §3.4,
/// phase 2): one breathability definition fed by the derived air, and the
/// sky's partial oxygen cover switched into life support and the
/// self-sufficiency measures together.
void main() {
  const atm = 101325.0;
  final mars = fixtureBodies.firstWhere((b) => b.id.value == 'mars');

  /// Mars's air with its oxygen raised to [pO2Atm] (and [n2Atm] of nitrogen
  /// added on top), as the inventory would publish it.
  CelestialBody marsWith({required double pO2Atm, double n2Atm = 0}) {
    final a = PlanetAtmosphere.seed(mars)!;
    if (n2Atm > 0) {
      a.add(AtmosphereGas.nitrogen,
          a.molesForPartialPressure(a.moles, AtmosphereGas.nitrogen, n2Atm * atm) -
              a.molesOf(AtmosphereGas.nitrogen));
    }
    a.add(AtmosphereGas.oxygen,
        a.molesForPartialPressure(a.moles, AtmosphereGas.oxygen, pO2Atm * atm) -
            a.molesOf(AtmosphereGas.oxygen));
    return a.applyTo(mars);
  }

  CitySim marsColony(CelestialBody sky) =>
      starterKit(body: 'mars')..body = sky;

  /// A bare Mars colony of forty, fully staffed and powered, with
  /// [buildings] placed at the given offsets from its hub, breathing [sky].
  /// Its oxygen store starts empty.
  CitySim cellColony(CelestialBody sky, List<(String, int)> buildings) {
    final city = CitySim.found(
      const CityConfig(bodyId: 'mars', gridSize: 20),
      bodies: fixtureBodies,
      id: 'air',
    )
      ..infiniteRobotics = true
      ..body = sky;
    CityBuildingSpec spec(String type) =>
        kUtilCatalog.firstWhere((s) => s.type == type);
    // Power and the compute the plant itself draws, as the tick tests lay
    // them out beside the hub.
    city.placeUtil(city.hubKey - 1, spec('fusion'));
    city.placeUtil(city.hubKey + city.grid, spec('datacenter'));
    city.stock[Commodity.electronics] = 1e6;
    for (final (type, offset) in buildings) {
      city.placeUtil(city.hubKey + offset, spec(type));
    }
    city.population = 40;
    city.stock[Commodity.oxygen] = 0;
    city.recompute();
    return city;
  }

  group('breathable, on the derived air', () {
    test('a Mars vented to 0.17 atm of oxygen is not breathable', () {
      final city = marsColony(marsWith(pO2Atm: 0.17));
      expect(city.sky.pressureAtm, inInclusiveRange(0.17, 0.2));
      expect(city.breathable, isFalse, reason: 'far too thin to breathe');
      expect(city.airO2, 1.0,
          reason: 'but the compressors draw every breath from it');
    });

    test('an Earth-like derived air is breathable — on Mars too', () {
      final city = marsColony(marsWith(pO2Atm: 0.21, n2Atm: 0.79));
      expect(city.sky.pressureAtm, greaterThan(0.95));
      expect(city.breathable, isTrue);
      expect(city.airO2, 1.0);
      expect(starterKit().breathable, isTrue, reason: 'and Earth still is');
      expect(starterKit(body: 'mars').breathable, isFalse);
    });

    test("a colony's own smog does not take the oxygen out of the sky", () {
      final earth = starterKit()..pollution = 200;
      expect(earth.surface.toxicFraction, greaterThan(0.2),
          reason: 'it is a health hazard on the surface conditions');
      expect(earth.breathable, isTrue);
      expect(earth.airO2, 1.0);
    });

    test('the sky the colony reads is the body it was handed', () {
      final city = marsColony(marsWith(pO2Atm: 0.08));
      expect(city.o2Fraction,
          city.body.composition!.fractions[AtmosphereGas.oxygen]);
      expect(city.windFactor,
          closeTo(city.body.atmosphere!.seaLevelDensity / 1.225, 1e-12));
      expect(city.hasWeatherAir, isTrue,
          reason: 'a twelfth of an atmosphere carries weather');
      expect(starterKit(body: 'mars').hasWeatherAir, isFalse);
    });
  });

  group('partial oxygen cover', () {
    test('half the oxygen partial pressure, half the cover', () {
      expect(marsColony(marsWith(pO2Atm: 0.08)).airO2, closeTo(0.5, 1e-9));
      expect(starterKit(body: 'mars').airO2, 0.0);
      // Under the Armstrong limit no oxygen helps an unsuited person.
      expect(marsColony(marsWith(pO2Atm: 0.05)).airO2, 0.0);
    });

    test('life support charges only what the sky does not give', () {
      // No oxygen plant at all: the stockpile is the whole supply, so the
      // people it keeps breathing double when the sky gives half.
      double supportable(CelestialBody sky) {
        final city = marsColony(sky)..population = 40;
        city.stock[Commodity.food] = 1e6;
        city.stock[Commodity.water] = 1e6;
        city.stock[Commodity.oxygen] = 30;
        city.advance(0.5);
        return city.supportablePop;
      }

      final raw = supportable(mars);
      final half = supportable(marsWith(pO2Atm: 0.08));
      expect(half / raw, closeTo(2, 0.02));
    });

    test('the oxygen stock drains at the share the sky leaves unmet', () {
      double drained(CelestialBody sky) {
        final city = cellColony(sky, const []);
        // Under the store's cap, which clamps at the end of the tick.
        final start = city.stockCap / 2;
        city.stock[Commodity.oxygen] = start;
        city.advance(0.5);
        return start - city.stockOf(Commodity.oxygen);
      }

      final raw = drained(mars);
      final half = drained(marsWith(pO2Atm: 0.08));
      expect(raw, greaterThan(0));
      expect(half, closeTo(raw / 2, raw * 0.02));
      expect(drained(marsWith(pO2Atm: 0.17)), closeTo(0, 1e-9),
          reason: 'full cover: not one breath from the store');
    });

    test('self-sufficiency counts the same cover: never over, never under',
        () {
      final city = marsColony(marsWith(pO2Atm: 0.08))..population = 100;
      final need = 100 * CitySim.waterPerPersonPerSec;
      const fed = {Commodity.food: 1e9, Commodity.water: 1e9};
      // Plants making exactly the half the sky does not cover: wholly
      // self-sufficient, and the colony that can live on it is this one.
      final half = {...fed, Commodity.oxygen: need / 2};
      expect(city.localSufficiency(half), closeTo(1.0, 1e-9));
      expect(city.localSupportablePop(half), closeTo(100, 1e-6));
      // A quarter: three quarters covered, and only half the people.
      final quarter = {...fed, Commodity.oxygen: need / 4};
      expect(city.localSufficiency(quarter), closeTo(0.75, 1e-9));
      expect(city.localSupportablePop(quarter), closeTo(50, 1e-6));
      // The raw Mars colony counts no sky at all.
      final raw = marsColony(mars)..population = 100;
      expect(raw.localSufficiency(half), closeTo(0.5, 1e-9));
      expect(raw.localSupportablePop(half), closeTo(50, 1e-6));
    });

    test('a half-oxygenated colony neither suffocates nor over-counts', () {
      // One Electrolysis Plant, and a town sized between what it can keep
      // breathing alone and what it can with half the sky: on a raw Mars
      // the people need more than it makes and the store never fills;
      // under a sky that gives half they need less, and it grows. (That the
      // sky is not counted for more than it gives, the measures above pin.)
      double o2After(CelestialBody sky) {
        final city = cellColony(sky, [('electrolysis', 1)]);
        final probe = cellColony(sky, [('electrolysis', 1)])..advance(0.5);
        final made = probe.stockOf(Commodity.oxygen) / 0.5 +
            probe.population * CitySim.waterPerPersonPerSec * (1 - probe.airO2);
        // 1.5× what the plant alone supports: suffocating raw, fine at half.
        final people = 1.5 * made / CitySim.waterPerPersonPerSec;
        for (var i = 0; i < 40; i++) {
          city
            ..population = people
            ..stock[Commodity.food] = 1e5
            ..stock[Commodity.water] = 1e5;
          city.advance(0.5);
        }
        return city.stockOf(Commodity.oxygen);
      }

      expect(o2After(mars), lessThan(1e-6), reason: 'suffocating');
      expect(o2After(marsWith(pO2Atm: 0.08)), greaterThan(1),
          reason: 'breathing, on its plant and its sky');
    });
  });

  group('the Atmospheric Harvester', () {
    CitySim withHarvester(CelestialBody sky) =>
        cellColony(sky, [('o2harvester', 1)]);

    test('yields from a sky with oxygen in it, and says how much it took', () {
      final city = withHarvester(marsWith(pO2Atm: 0.08));
      expect(city.o2Harvestable, isTrue);
      city.advance(0.5);
      expect(city.o2HarvestRate, greaterThan(0));
    });

    test('yields nothing from a sky without', () {
      final city = withHarvester(mars);
      expect(city.o2Harvestable, isFalse);
      city.advance(0.5);
      expect(city.o2HarvestRate, 0);
    });

    test('a full tank draws only what the colony breathed back out of it',
        () {
      // Review 2026-10-10: counted off its output, a harvester whose tank
      // was full kept pulling 4 stock/s out of the sky while the store sat
      // at the cap — oxygen that then existed nowhere.
      final sky = marsWith(pO2Atm: 0.08);
      final empty = withHarvester(sky)..advance(0.5);
      final full = withHarvester(sky);
      full.stock[Commodity.oxygen] = full.stockCap;
      full.advance(0.5);
      expect(full.stockOf(Commodity.oxygen), full.stockCap);
      // The tank keeps only what forty people breathed of the half the sky
      // does not cover. The empty colony kept everything, so its stock says
      // what a harvester makes and its rate what that costs the sky.
      final breathed = 40 * CitySim.waterPerPersonPerSec * (1 - full.airO2);
      final made = empty.stockOf(Commodity.oxygen) / 0.5 + breathed;
      expect(full.o2HarvestRate,
          closeTo(empty.o2HarvestRate * breathed / made, 1e-9));
      expect(full.o2HarvestRate, lessThan(empty.o2HarvestRate * 0.5));
    });

    test('on a world whose oxygen is free, it draws nothing', () {
      final earth = fixtureBodies.firstWhere((b) => b.id.value == 'earth');
      final city = withHarvester(earth);
      expect(city.breathable, isTrue);
      expect(city.o2Harvestable, isTrue);
      city.advance(0.5);
      expect(city.o2HarvestRate, 0,
          reason: 'the store is pinned full; nothing is kept, nothing taken');
    });

    test('the sky pays the bare throttle, not the bounty', () {
      // Two stock per second at full run, as the tower's vent is its bare
      // throttle — so one harvester undoes four towers at any bounty.
      final sky = marsWith(pO2Atm: 0.08);
      final rich = withHarvester(sky)..bounty = 1.0;
      final poor = withHarvester(sky)..bounty = 0.0;
      rich.advance(0.5);
      poor.advance(0.5);
      expect(rich.o2HarvestRate, greaterThan(0));
      expect(rich.o2HarvestRate, closeTo(poor.o2HarvestRate, 1e-12));
      expect(rich.o2HarvestRate, lessThanOrEqualTo(2.0));
    });
  });

  test('loyalty measures read the same airO2 the life support does', () {
    final city = marsColony(marsWith(pO2Atm: 0.12));
    final cover = city.airO2;
    expect(cover, closeTo(0.75, 1e-9));
    final need = CitySim.waterPerPersonPerSec;
    city.population = 10;
    final local = {
      Commodity.food: 1.0,
      Commodity.water: 1.0,
      Commodity.oxygen: 0.0,
    };
    expect(city.localSufficiency(local), closeTo(cover, 1e-9));
    expect(
        city.localSupportablePop({...local, Commodity.oxygen: need}),
        closeTo(1 / (1 - cover), 1e-6));
  });
}
