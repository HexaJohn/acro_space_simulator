// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/planetary/volatile_reservoir.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a planet does back (docs/plans/terraforming.md §3.2-3.3, phase 2):
/// a greenhouse temperature from the real air, Mars's caps and soil giving
/// up CO2 as it warms, small worlds leaking their air to space, and the
/// Atmospheric Harvester taking oxygen out of the sky. Every term is pinned
/// against warp: one long step must land where many short ones do.
void main() {
  final system = RealSolarSystem.build();
  CelestialBody body(String id) => system.require(BodyId(id));
  PlanetAtmosphere seed(String id) => PlanetAtmosphere.seed(body(id))!;
  const service = PlanetAtmosphereService();
  const marsYear = 686.98 * 86400.0;
  const year = 3.15576e7;
  const atm = 101325.0;

  AtmosphereFlows flows({
    double towers = 0,
    double pollutionRate = 0,
    double harvest = 0,
    required double dt,
  }) =>
      AtmosphereFlows()
        ..addColony(
            pollutionRate: pollutionRate,
            oxygenatorRun: towers,
            o2HarvestRate: harvest,
            dt: dt);

  /// Moles of super-greenhouse agent for [pa] pascals of it on [a].
  double agentFor(PlanetAtmosphere a, double pa) =>
      pa / (PlanetAtmosphere.agentMolarMass * a.pascalsPerKg);

  /// Total CO2 a world has: its sky plus every CO2 store.
  double co2Everywhere(PlanetAtmosphere a) =>
      a.molesOf(AtmosphereGas.carbonDioxide) +
      a.reservoirs
          .where((r) => r.gas == AtmosphereGas.carbonDioxide)
          .fold(0.0, (s, r) => s + r.moles);

  group('greenhouse temperature', () {
    test('every reference sky reads back its reference temperature', () {
      for (final (id, t) in [
        ('earth', 288.15),
        ('mars', 210.0),
        ('venus', 737.0),
        ('titan', 94.0),
      ]) {
        final a = seed(id);
        expect(a.surfaceTemperatureK, t, reason: id);
        // And the physics alone lands within a few kelvin: the calibration
        // is a small residual, not the answer.
        expect(a.climateCalibrationK.abs(), lessThan(3.0), reason: id);
        expect(a.temperatureFor(a.moles), closeTo(t, 1e-9), reason: id);
      }
    });

    test('more greenhouse gas warms; the same gas warms a thick sky more', () {
      final earth = seed('earth');
      final t0 = earth.surfaceTemperatureK;
      earth.add(AtmosphereGas.carbonDioxide,
          earth.molesOf(AtmosphereGas.carbonDioxide)); // doubled CO2
      final warming = earth.surfaceTemperatureK - t0;
      expect(warming, inInclusiveRange(1.0, 4.5),
          reason: 'a doubling is a few kelvin, not a doubling');
      // Oxygen is no greenhouse gas, but thickening Mars's sky with it
      // pressure-broadens the CO2 already there.
      final mars = seed('mars');
      mars.add(AtmosphereGas.oxygen, 1.9e19); // ~0.16 atm of O2
      expect(mars.surfaceTemperatureK, greaterThan(215));
    });

    test('the super-greenhouse agent warms; haze cools', () {
      final mars = seed('mars');
      mars.greenhouseAgentMoles = agentFor(mars, 1);
      expect(mars.agentPartialPressurePa, closeTo(1, 1e-9));
      expect(mars.surfaceTemperatureK - 210, inInclusiveRange(15, 35),
          reason: 'a pascal of PFC is tens of kelvin on Mars');
      final hazy = seed('mars')..aerosolBurden = 1.0;
      expect(hazy.surfaceTemperatureK, lessThan(210));
    });

    test('temperature feeds the derived air', () {
      final mars = seed('mars');
      final ref = mars.air!;
      mars.greenhouseAgentMoles = agentFor(mars, 3);
      final warm = mars.air!;
      final tr = warm.seaLevelTemperature / ref.seaLevelTemperature;
      expect(tr, greaterThan(1.1));
      expect(warm.seaLevelPressure, closeTo(ref.seaLevelPressure, 1e-9),
          reason: 'same column of gas, same pressure');
      expect(warm.seaLevelDensity, closeTo(ref.seaLevelDensity / tr, 1e-12));
      expect(warm.scaleHeight, closeTo(ref.scaleHeight * tr, 1e-6));
      expect(mars.applyTo(body('mars')).atmosphere!.seaLevelTemperature,
          warm.seaLevelTemperature);
    });
  });

  group('volatile reservoirs', () {
    test('an untouched Mars is at rest', () {
      final a = seed('mars');
      expect(a.isAtRest, isTrue);
      expect(a.reservoirs.map((r) => r.name),
          ['polarCo2', 'regolithCo2', 'polarWater']);
      // And integrating it anyway moves nothing that matters.
      service.advance(a, AtmosphereFlows(), dt: 10 * marsYear);
      expect(a.surfacePressurePa, closeTo(610, 610 * 1e-9));
    });

    test('the cap buffers Mars: industry CO2 mostly freezes out', () {
      // Mars's pressure is pinned by the frost point of its polar CO2: add
      // CO2 and most of it condenses onto the cap within a few years, which
      // is why the industrial ledger alone overstates what a colony does to
      // a Martian sky. It still warms a little, so it does not all go.
      final a = seed('mars');
      const decade = 3.15e8;
      final added = 40 * decade * service.molesPerPollutionSecond;
      service.advance(a, flows(pollutionRate: 40, dt: decade), dt: decade);
      final inAir = a.molesOf(AtmosphereGas.carbonDioxide) -
          a.referenceMolesOf(AtmosphereGas.carbonDioxide);
      expect(inAir, greaterThan(0));
      expect(inAir, lessThan(0.5 * added));
      expect(co2Everywhere(a) - co2Everywhere(seed('mars')),
          closeTo(added, added * 1e-6),
          reason: 'it went onto the cap and into the soil, not away');
      expect(a.isMeasurable, isTrue);
    });

    test('warming Mars releases CO2 and thickens it, bounded by the stores',
        () {
      final a = seed('mars');
      final total = co2Everywhere(a);
      a.greenhouseAgentMoles = agentFor(a, 3);
      for (var y = 0; y < 60; y++) {
        service.advance(a, AtmosphereFlows(), dt: marsYear);
      }
      // The cap is gone, the soil part-spent, the sky five times thicker and
      // ~40 K warmer — more than the agent alone would give.
      final cap = a.reservoirs.firstWhere((r) => r.name == 'polarCo2');
      final soil = a.reservoirs.firstWhere((r) => r.name == 'regolithCo2');
      expect(cap.moles, lessThan(cap.referenceMoles * 0.01));
      expect(soil.moles, lessThan(soil.referenceMoles));
      expect(soil.moles, greaterThan(0));
      expect(a.surfacePressurePa, greaterThan(5 * 610));
      final agentOnly = seed('mars')
        ..greenhouseAgentMoles = agentFor(seed('mars'), 3);
      expect(a.surfaceTemperatureK,
          greaterThan(agentOnly.surfaceTemperatureK + 5),
          reason: 'the released CO2 warms it further: the feedback');
      // Not a mole made or lost: it moved from the stores into the sky.
      expect(co2Everywhere(a), closeTo(total, total * 1e-9));
      expect(a.molesOf(AtmosphereGas.carbonDioxide),
          lessThan(a.referenceMolesOf(AtmosphereGas.carbonDioxide) +
              cap.referenceMoles +
              soil.referenceMoles));
      // Warm enough for the polar ice to put water in the air.
      expect(a.partialPressurePa(AtmosphereGas.water), greaterThan(1));
    });

    test('cooled again, the CO2 condenses back onto the cap', () {
      final a = seed('mars');
      a.greenhouseAgentMoles = agentFor(a, 3);
      for (var y = 0; y < 40; y++) {
        service.advance(a, AtmosphereFlows(), dt: marsYear);
      }
      final warm = a.surfacePressurePa;
      a.greenhouseAgentMoles = 0;
      for (var y = 0; y < 40; y++) {
        service.advance(a, AtmosphereFlows(), dt: marsYear);
      }
      expect(a.surfacePressurePa, lessThan(warm / 3));
      expect(a.surfacePressurePa, closeTo(610, 610 * 0.05),
          reason: 'back near the frost-point pressure of the cap');
      final cap = a.reservoirs.firstWhere((r) => r.name == 'polarCo2');
      expect(cap.moles, greaterThan(cap.referenceMoles * 0.5));
      expect(a.partialPressurePa(AtmosphereGas.water), lessThan(1e-3),
          reason: 'and the water freezes out at the cold trap');
    });

    test('with an optimistic soil, the runaway sustains itself — to a bound',
        () {
      // McKay, Toon & Kasting (1991)-style: a regolith holding a couple of
      // bar of CO2 (a bar's worth is ~8.8e19 mol). A pulse of warming tips
      // it, and it stays warm with the agent gone, held there by the CO2 it
      // freed — short of emptying the soil. (A one-bar soil is not enough:
      // the isotherm falls off as the soil empties, and it collapses back.)
      const soilMoles = 2 * 8.8e19;
      final a = PlanetAtmosphere.seed(body('mars'),
          reservoirs: VolatileReservoir.marsDefaults(
              regolithCo2Moles: soilMoles))!;
      a.greenhouseAgentMoles = agentFor(a, 10);
      for (var y = 0; y < 60; y++) {
        service.advance(a, AtmosphereFlows(), dt: marsYear);
      }
      a.greenhouseAgentMoles = 0;
      for (var y = 0; y < 200; y++) {
        service.advance(a, AtmosphereFlows(), dt: marsYear);
      }
      expect(a.surfacePressurePa, greaterThan(0.5 * atm),
          reason: 'a self-sustaining warm, thick Mars');
      expect(a.surfaceTemperatureK, greaterThan(273));
      final soil = a.reservoirs.firstWhere((r) => r.name == 'regolithCo2');
      expect(soil.moles, greaterThan(0), reason: 'bounded by the store');
      expect(a.molesOf(AtmosphereGas.carbonDioxide),
          lessThan(a.referenceMolesOf(AtmosphereGas.carbonDioxide) +
              soilMoles +
              VolatileReservoir.marsCapCo2Moles));
    });

    test('the response is smooth: no threshold for warp to oscillate across',
        () {
      // Hold Mars a little warm and watch the pressure settle: monotone,
      // with no overshoot, at every step size.
      for (final dt in [marsYear / 50, marsYear, 10 * marsYear]) {
        final a = seed('mars')..greenhouseAgentMoles = agentFor(seed('mars'), 0.3);
        var last = a.surfacePressurePa;
        for (var t = 0.0; t < 100 * marsYear; t += dt) {
          service.advance(a, AtmosphereFlows(), dt: dt);
          final p = a.surfacePressurePa;
          expect(p, greaterThanOrEqualTo(last - 1e-6), reason: 'dt $dt');
          last = p;
        }
      }
    });
  });

  group('escape', () {
    test('the Moon leaks vented gas; a retention array holds it', () {
      final moon = seed('moon');
      final held = seed('moon')..escapeSuppression = 0.99;
      for (final a in [moon, held]) {
        a.add(AtmosphereGas.oxygen, 1e17);
        service.advance(a, AtmosphereFlows(), dt: year);
      }
      expect(moon.molesOf(AtmosphereGas.oxygen), lessThan(1e17 * 0.05),
          reason: 'an e-fold of months');
      expect(held.molesOf(AtmosphereGas.oxygen), greaterThan(1e17 * 0.9));
    });

    test('towers on the Moon fight a leak they cannot win', () {
      final moon = seed('moon');
      for (var y = 0; y < 5; y++) {
        service.advance(moon, flows(towers: 50, dt: year), dt: year);
      }
      // The programme that oxygenates Mars holds about a thousandth of an
      // atmosphere here: no partial cover (Armstrong limit), still domed.
      expect(moon.surfacePressurePa, lessThan(0.005 * atm));
      expect(moon.surfacePressurePa, greaterThan(0));
      expect(moon.applyTo(body('moon')).atmosphere, isNotNull,
          reason: 'but it is a real, thin sky while they pump');
    });

    test('a leaked-out Moon is airless and at rest again', () {
      final moon = seed('moon')..add(AtmosphereGas.nitrogen, 1e16);
      expect(moon.applyTo(body('moon')).hasAtmosphere, isTrue);
      service.advance(moon, AtmosphereFlows(), dt: 50 * year);
      expect(moon.totalMoles, 0);
      expect(moon.isAtRest, isTrue);
      final published = moon.applyTo(body('moon'));
      expect(published.atmosphere, isNull);
      expect(published.composition, isNull);
    });

    test('Mercury leaks too; Mars keeps all but its lightest gases', () {
      final mercury = seed('mercury')..add(AtmosphereGas.oxygen, 1e17);
      service.advance(mercury, AtmosphereFlows(), dt: 30 * year);
      expect(mercury.molesOf(AtmosphereGas.oxygen), lessThan(0.1 * 1e17));

      final mars = seed('mars')
        ..add(AtmosphereGas.hydrogen, 1e16)
        ..add(AtmosphereGas.nitrogen, 1e16);
      final n2 = mars.molesOf(AtmosphereGas.nitrogen);
      service.advance(mars, AtmosphereFlows(), dt: 10 * year);
      expect(mars.molesOf(AtmosphereGas.hydrogen), lessThan(1e16 * 0.01),
          reason: 'light gases first');
      expect(mars.molesOf(AtmosphereGas.nitrogen), closeTo(n2, n2 * 1e-12));
    });

    test('Earth and Venus lose nothing a game could measure', () {
      for (final id in ['earth', 'venus']) {
        final a = seed(id);
        final k = service.escapeRates(a);
        for (final g in a.moles.keys) {
          final perMillennium = (k[g] ?? 0) * 1000 * year;
          expect(perMillennium, lessThan(1e-12), reason: '$id ${g.name}');
        }
      }
    });

    test('suppression is the phase-3 hook: it scales every rate', () {
      final a = seed('moon');
      final full = service.escapeRates(a);
      a.escapeSuppression = 0.75;
      final cut = service.escapeRates(a);
      for (final e in full.entries) {
        expect(cut[e.key], closeTo(e.value * 0.25, e.value * 1e-12));
      }
      a.escapeSuppression = 1;
      expect(service.escapeRates(a), isEmpty);
    });
  });

  group('the Atmospheric Harvester', () {
    test('draws the planet\'s oxygen down by what it makes', () {
      const ledger = PlanetAtmosphereService.ledgerOnly();
      final earth = seed('earth');
      final o2 = earth.molesOf(AtmosphereGas.oxygen);
      // One harvester at full run (2 stock/s) for a year.
      ledger.advance(earth, flows(harvest: 2, dt: year), dt: year);
      final taken = 2 * year * ledger.tuning.harvesterMolesPerStockUnit;
      expect(o2 - earth.molesOf(AtmosphereGas.oxygen),
          closeTo(taken, taken * 1e-9));
      expect(earth.isMeasurable, isTrue,
          reason: 'harvesting thins the sky — measurably, on Earth too');
    });

    test('cannot take more than is there', () {
      final mars = seed('mars');
      service.advance(mars, flows(harvest: 1e6, dt: 100 * year),
          dt: 100 * year);
      expect(mars.molesOf(AtmosphereGas.oxygen), 0);
      for (final g in AtmosphereGas.values) {
        expect(mars.molesOf(g), greaterThanOrEqualTo(0));
      }
    });

    test('a stock unit weighs what a tower vents for one', () {
      // The tower vents oxygenatorRate into the sky for its 0.5 stock/s, so
      // a harvester and a tower of equal stock output cancel on the planet.
      const t = TerraformTuning();
      expect(t.harvesterMolesPerStockUnit,
          closeTo(t.oxygenatorRate / 0.5, 1e-6));
      const ledger = PlanetAtmosphereService.ledgerOnly();
      final mars = seed('mars');
      final o2 = mars.molesOf(AtmosphereGas.oxygen);
      ledger.advance(mars, flows(towers: 1, harvest: 0.5, dt: marsYear),
          dt: marsYear);
      expect(mars.molesOf(AtmosphereGas.oxygen), closeTo(o2, o2 * 1e-9));
    });
  });

  group('warp', () {
    void expectSameWorld(PlanetAtmosphere big, PlanetAtmosphere small,
        {required double tolerance}) {
      for (final g in AtmosphereGas.values) {
        final x = small.molesOf(g);
        expect(big.molesOf(g), closeTo(x, x.abs() * tolerance + 1),
            reason: g.name);
      }
      for (var i = 0; i < big.reservoirs.length; i++) {
        final x = small.reservoirs[i].moles;
        expect(big.reservoirs[i].moles,
            closeTo(x, tolerance * small.reservoirs[i].referenceMoles + 1),
            reason: big.reservoirs[i].name);
      }
      expect(big.surfaceTemperatureK,
          closeTo(small.surfaceTemperatureK, 0.05));
    }

    test('a warming, venting, polluted Mars: one step or four thousand', () {
      final big = seed('mars');
      final small = seed('mars');
      for (final a in [big, small]) {
        a.greenhouseAgentMoles = agentFor(a, 3);
      }
      const span = 40 * marsYear;
      service.advance(
          big, flows(towers: 50, pollutionRate: 40, dt: span), dt: span);
      const n = 4000;
      for (var i = 0; i < n; i++) {
        service.advance(small,
            flows(towers: 50, pollutionRate: 40, dt: span / n), dt: span / n);
      }
      expectSameWorld(big, small, tolerance: 1e-3);
    });

    test('a tower holding the Moon against its leak: one step or many', () {
      final big = seed('moon');
      final small = seed('moon');
      service.advance(big, flows(towers: 50, dt: 3 * year), dt: 3 * year);
      for (var i = 0; i < 3000; i++) {
        service.advance(small, flows(towers: 50, dt: 3 * year / 3000),
            dt: 3 * year / 3000);
      }
      expectSameWorld(big, small, tolerance: 1e-6);
    });

    test('a vast step cannot drive a gas, a store or the heat negative', () {
      final a = seed('mars')..greenhouseAgentMoles = agentFor(seed('mars'), 10);
      service.advance(a, flows(towers: 50, harvest: 3, dt: 1e12), dt: 1e12);
      for (final g in AtmosphereGas.values) {
        expect(a.molesOf(g), greaterThanOrEqualTo(0));
        expect(a.molesOf(g).isFinite, isTrue);
      }
      for (final r in a.reservoirs) {
        expect(r.moles, greaterThanOrEqualTo(0));
      }
      expect(a.surfaceTemperatureK.isFinite, isTrue);
      expect(a.surfaceTemperatureK, greaterThan(0));
    });
  });

  group('persistence', () {
    test('stores, agent and suppression round-trip; old saves keep reference',
        () {
      final a = seed('mars')
        ..greenhouseAgentMoles = agentFor(seed('mars'), 2)
        ..escapeSuppression = 0.4;
      service.advance(a, flows(towers: 10, dt: 5 * marsYear),
          dt: 5 * marsYear);
      final b = seed('mars')..restore(a.toJson());
      expect(b.greenhouseAgentMoles, a.greenhouseAgentMoles);
      expect(b.escapeSuppression, a.escapeSuppression);
      for (var i = 0; i < a.reservoirs.length; i++) {
        expect(b.reservoirs[i].moles, a.reservoirs[i].moles);
      }
      expect(b.surfaceTemperatureK, a.surfaceTemperatureK);
      // A phase-1 save: moles only.
      final old = Map<String, dynamic>.of(a.toJson())
        ..remove('reservoirs')
        ..remove('agent')
        ..remove('suppression');
      final c = seed('mars')..restore(old);
      for (final r in c.reservoirs) {
        expect(r.moles, r.referenceMoles, reason: r.name);
      }
      expect(c.greenhouseAgentMoles, 0);
    });

    test('reset puts the stores back too', () {
      final a = seed('mars')..greenhouseAgentMoles = agentFor(seed('mars'), 3);
      service.advance(a, AtmosphereFlows(), dt: 10 * marsYear);
      expect(a.isAtRest, isFalse);
      a.resetToReference();
      expect(a.isAtRest, isTrue);
      expect(identical(a.air, body('mars').atmosphere), isTrue);
    });
  });
}
