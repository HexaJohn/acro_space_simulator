// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/planetary/volatile_reservoir.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The terraforming tower family (docs/plans/terraforming.md §4, phase 3):
/// what each tower does to its world's gas, the limit each stops at on a
/// world like Earth, and that every new term lands in one long warp step
/// where many short ones do. Plus the chemistry that came with them —
/// methane oxidising — and the ledger that says who did what.
void main() {
  final system = RealSolarSystem.build();
  CelestialBody body(String id) => system.require(BodyId(id));
  PlanetAtmosphere seed(String id) => PlanetAtmosphere.seed(body(id))!;
  const service = PlanetAtmosphereService();
  const ledger = PlanetAtmosphereService.ledgerOnly();
  const tuning = TerraformTuning();
  const marsYear = 686.98 * 86400.0;
  const year = 3.15576e7;

  /// One colony running the given towers at full throttle for [dt].
  AtmosphereFlows run({
    double oxygenators = 0,
    double greenhouse = 0,
    double bakers = 0,
    double sequestrators = 0,
    double arrays = 0,
    double pollutionRate = 0,
    required double dt,
    String colony = 'c',
  }) =>
      AtmosphereFlows()
        ..addColony(
          pollutionRate: pollutionRate,
          oxygenatorRun: oxygenators,
          towers: TowerRuns()
            ..greenhouse = greenhouse
            ..baker = bakers
            ..sequestrator = sequestrators
            ..retention = arrays,
          dt: dt,
          colony: colony,
        );

  double floorMoles(PlanetAtmosphere a) =>
      tuning.co2FloorPa /
      (a.pascalsPerKg *
          AtmosphericComposition.molarMass[AtmosphereGas.carbonDioxide]!);

  VolatileReservoir store(PlanetAtmosphere a, String name) =>
      a.reservoirs.firstWhere((r) => r.name == name);

  group('the Oxygenator splits CO2, it does not make oxygen from nothing', () {
    test('a mole of CO2 out of the sky for every mole of O2 in', () {
      final a = seed('mars');
      final n0 = a.totalMoles;
      final o2 = a.molesOf(AtmosphereGas.oxygen);
      final co2 = a.molesOf(AtmosphereGas.carbonDioxide);
      const dt = 1e6;
      ledger.advance(a, run(oxygenators: 5, dt: dt), dt: dt);
      final vented = 5 * dt * tuning.oxygenatorRate;
      expect(a.molesOf(AtmosphereGas.oxygen) - o2,
          closeTo(vented, vented * 1e-9));
      expect(co2 - a.molesOf(AtmosphereGas.carbonDioxide),
          closeTo(vented, vented * 1e-9));
      expect(a.totalMoles, closeTo(n0, n0 * 1e-12),
          reason: 'CO2 → O2 keeps the molecule count');
      // Lighter oxygen for heavier CO2: the column lightens.
      expect(a.surfacePressurePa, lessThan(610));
    });

    test('past the sky\'s CO2 it splits the crust, and leaves the floor', () {
      final a = seed('mars');
      ledger.advance(a, run(oxygenators: 50, dt: 5 * marsYear),
          dt: 5 * marsYear);
      expect(a.molesOf(AtmosphereGas.carbonDioxide),
          closeTo(floorMoles(a), floorMoles(a) * 1e-9),
          reason: 'it takes the CO2 down to the floor and no further');
      expect(a.molesOf(AtmosphereGas.oxygen),
          greaterThan(a.referenceMolesOf(AtmosphereGas.carbonDioxide) * 2),
          reason: 'and goes on venting from the rock beyond it');
    });

    test('the oxygen cap still lands exactly with the CO2 split out', () {
      final a = seed('mars');
      ledger.advance(a, run(oxygenators: 50, dt: 60 * marsYear),
          dt: 60 * marsYear);
      expect(a.partialPressurePa(AtmosphereGas.oxygen),
          closeTo(tuning.oxygenTargetPa, tuning.oxygenTargetPa * 1e-9));
      // Short of the CO2 running out, the joint closed form: a cap a few
      // per cent above Mars's reference O2, reached on the split alone.
      final b = seed('mars');
      final target = b.partialPressurePa(AtmosphereGas.oxygen) * 3;
      final capped = PlanetAtmosphereService.ledgerOnly(
          tuning: TerraformTuning(oxygenTargetPa: target));
      capped.advance(b, run(oxygenators: 50, dt: marsYear), dt: marsYear);
      expect(b.partialPressurePa(AtmosphereGas.oxygen),
          closeTo(target, target * 1e-9));
      expect(b.molesOf(AtmosphereGas.carbonDioxide), greaterThan(floorMoles(b)),
          reason: 'reached on the sky\'s CO2, not past it');
    });

    test('Earth: nothing to vent, so nothing split', () {
      final a = seed('earth');
      service.advance(a, run(oxygenators: 50, dt: 10 * year), dt: 10 * year);
      expect(a.molesOf(AtmosphereGas.carbonDioxide),
          a.referenceMolesOf(AtmosphereGas.carbonDioxide));
      expect(a.molesOf(AtmosphereGas.oxygen),
          a.referenceMolesOf(AtmosphereGas.oxygen));
    });
  });

  group('the Greenhouse Factory', () {
    test('fills the sky with agent and warms Mars', () {
      final a = seed('mars');
      final t0 = a.surfaceTemperatureK;
      ledger.advance(a, run(greenhouse: 10, dt: 3 * marsYear),
          dt: 3 * marsYear);
      final emitted = 10 * 3 * marsYear * tuning.greenhouseRate;
      expect(a.greenhouseAgentMoles, closeTo(emitted, emitted * 1e-9));
      // About a pascal: ~+25 K on Mars.
      expect(a.agentPartialPressurePa, inInclusiveRange(0.8, 1.2));
      expect(a.surfaceTemperatureK - t0, inInclusiveRange(15, 35));
      // Agent is forcing, not air.
      expect(a.surfacePressurePa, closeTo(610, 610 * 1e-9));
    });

    test('stops at the warming target, in closed form', () {
      final a = seed('mars');
      ledger.advance(a, run(greenhouse: 50, dt: 200 * marsYear),
          dt: 200 * marsYear);
      expect(a.surfaceTemperatureK,
          closeTo(tuning.warmingTargetK, 1e-6));
      final more = a.greenhouseAgentMoles;
      ledger.advance(a, run(greenhouse: 50, dt: 50 * marsYear),
          dt: 50 * marsYear);
      expect(a.greenhouseAgentMoles, more, reason: 'and holds there');
    });

    test('Earth cannot be cooked: it is already at the target', () {
      final a = seed('earth');
      service.advance(a, run(greenhouse: 100, dt: 100 * year), dt: 100 * year);
      expect(a.greenhouseAgentMoles, 0);
      expect(a.surfaceTemperatureK, a.referenceTemperatureK);
    });

    test('the agent breaks down over its lifetime', () {
      final a = seed('mars')
        ..greenhouseAgentMoles = 1e14;
      service.advance(a, AtmosphereFlows(),
          dt: service.agentLifetimeSeconds);
      expect(a.greenhouseAgentMoles, closeTo(1e14 / math.e, 1e14 * 1e-6));
    });
  });

  group('the Regolith Baker', () {
    test('frees CO2 and N2 from the carbonates and nitrates', () {
      final a = seed('mars');
      final co2 = a.molesOf(AtmosphereGas.carbonDioxide);
      final n2 = a.molesOf(AtmosphereGas.nitrogen);
      ledger.advance(a, run(bakers: 50, dt: 10 * marsYear), dt: 10 * marsYear);
      final carbonates = store(a, 'carbonates');
      final nitrates = store(a, 'nitrates');
      final k = 50 * tuning.bakerRate * 10 * marsYear;
      final f = 1 - math.exp(-k);
      expect(carbonates.moles,
          closeTo(carbonates.referenceMoles * (1 - f), carbonates.referenceMoles * 1e-9));
      expect(a.molesOf(AtmosphereGas.carbonDioxide) - co2,
          closeTo(carbonates.referenceMoles * f, carbonates.referenceMoles * 1e-9));
      expect(a.molesOf(AtmosphereGas.nitrogen) - n2,
          closeTo(nitrates.referenceMoles * f, nitrates.referenceMoles * 1e-9));
      // The caps and soil are climate's, not the baker's.
      expect(store(a, 'polarCo2').moles, store(a, 'polarCo2').referenceMoles);
    });

    test('bounded by the stores: a vast bake empties them and no more', () {
      final a = seed('mars');
      final co2 = a.molesOf(AtmosphereGas.carbonDioxide);
      final n2 = a.molesOf(AtmosphereGas.nitrogen);
      ledger.advance(a, run(bakers: 50, dt: 1e5 * marsYear),
          dt: 1e5 * marsYear);
      final c = store(a, 'carbonates');
      final n = store(a, 'nitrates');
      expect(c.moles, 0);
      expect(n.moles, 0);
      expect(a.molesOf(AtmosphereGas.carbonDioxide) - co2,
          closeTo(c.referenceMoles, c.referenceMoles * 1e-9));
      expect(a.molesOf(AtmosphereGas.nitrogen) - n2,
          closeTo(n.referenceMoles, n.referenceMoles * 1e-9));
    });

    test('stops once the world is warm enough', () {
      final a = seed('mars');
      // Warm Mars past the target first.
      a.greenhouseAgentMoles =
          a.agentMolesForTemperature(tuning.warmingTargetK + 5);
      ledger.advance(a, run(bakers: 50, dt: marsYear), dt: marsYear);
      expect(store(a, 'carbonates').moles,
          store(a, 'carbonates').referenceMoles);
    });

    test('Earth has nothing to bake', () {
      expect(VolatileReservoir.hasBakeableStore('earth'), isFalse);
      expect(VolatileReservoir.hasBakeableStore('moon'), isFalse);
      expect(VolatileReservoir.hasBakeableStore('mars'), isTrue);
      final a = seed('earth');
      service.advance(a, run(bakers: 50, dt: 10 * year), dt: 10 * year);
      expect(a.molesOf(AtmosphereGas.carbonDioxide),
          a.referenceMolesOf(AtmosphereGas.carbonDioxide));
    });
  });

  group('the Carbon Sequestrator', () {
    test('takes CO2 into rock, down to the floor and no further', () {
      final a = seed('venus');
      final co2 = a.molesOf(AtmosphereGas.carbonDioxide);
      const dt = 1e3 * year;
      ledger.advance(a, run(sequestrators: 50, dt: dt), dt: dt);
      final taken = 50 * dt * tuning.sequestratorRate;
      expect(co2 - a.molesOf(AtmosphereGas.carbonDioxide),
          closeTo(taken, taken * 1e-9));
    });

    test("Earth's floor: industrial CO2 out, the greenhouse kept", () {
      final a = seed('earth');
      final t0 = a.surfaceTemperatureK;
      service.advance(a, run(sequestrators: 50, dt: 100 * year),
          dt: 100 * year);
      expect(a.molesOf(AtmosphereGas.carbonDioxide),
          closeTo(floorMoles(a), floorMoles(a) * 1e-9));
      // ~280 ppm, pre-industrial.
      final x = a.composition!.fractions[AtmosphereGas.carbonDioxide]!;
      expect(x, inInclusiveRange(2.6e-4, 2.9e-4));
      expect(t0 - a.surfaceTemperatureK, inInclusiveRange(0, 1.5),
          reason: 'about a kelvin: Earth cannot be frozen by default');
    });
  });

  group('the Atmospheric Retention Array', () {
    test('suppression follows the arrays, and drops when they stop', () {
      final a = seed('moon');
      service.advance(a, run(arrays: 4, dt: year), dt: year);
      expect(a.escapeSuppression, closeTo(1 - math.pow(0.5, 4), 1e-12));
      service.advance(a, run(oxygenators: 1, dt: year), dt: year);
      expect(a.escapeSuppression, 0);
      // A step no colony reported on holds it.
      a.escapeSuppression = 0.5;
      service.advance(a, AtmosphereFlows(), dt: year);
      expect(a.escapeSuppression, 0.5);
    });

    test("lowers the Moon's leak and holds more air", () {
      final open = seed('moon');
      final held = seed('moon');
      for (var y = 0; y < 5; y++) {
        service.advance(open, run(oxygenators: 50, dt: year), dt: year);
        service.advance(held, run(oxygenators: 50, arrays: 6, dt: year),
            dt: year);
      }
      // Five years is a third of the held sky's e-fold, so it is still
      // filling; the open one settled within months.
      expect(held.surfacePressurePa, greaterThan(5 * open.surfacePressurePa));
      final leakOpen =
          open.ledger!.rate(GasProcess.escape, AtmosphereGas.oxygen.name);
      final leakHeld =
          held.ledger!.rate(GasProcess.escape, AtmosphereGas.oxygen.name);
      expect(leakOpen, lessThan(0));
      // Per mole held, the leak is a few per cent of the open sky's (the
      // thicker sky's exobase differs a little too)...
      final perMoleOpen = leakOpen / open.molesOf(AtmosphereGas.oxygen);
      final perMoleHeld = leakHeld / held.molesOf(AtmosphereGas.oxygen);
      expect(perMoleHeld / perMoleOpen, lessThan(1 / 40));
      // ...and on the same sky, exactly the six arrays' 1/64th.
      final k = service.escapeRates(held)[AtmosphereGas.oxygen]!;
      held.escapeSuppression = 0;
      final k0 = service.escapeRates(held)[AtmosphereGas.oxygen]!;
      expect(k / k0, closeTo(1 / 64, 1e-12));
    });
  });

  group('the ledger at the oxygen cap', () {
    test('a sky held at the cap books its real leak, not the clip', () {
      // The Moon under ten arrays, filled to the cap by fifty towers: from
      // here the towers only top up what leaks. The cap clipping the vent
      // was booked as escape — several times the real leak, every other
      // step.
      final a = seed('moon');
      AtmosphereFlows held(double dt) =>
          run(oxygenators: 50, arrays: 10, dt: dt);
      const month = 30 * 86400.0;
      for (var i = 0; i < 80 * 12; i++) {
        service.advance(a, held(month), dt: month);
      }
      final o2 = AtmosphereGas.oxygen;
      expect(a.surfacePressurePa, greaterThan(10000), reason: 'filled');
      for (final dt in [20.0, 86400.0, month, 86400.0, 20.0]) {
        final n0 = a.molesOf(o2);
        final k = service.escapeRates(a)[o2]!;
        service.advance(a, held(dt), dt: dt);
        final l = a.ledger!;
        final escape = l.rate(GasProcess.escape, o2.name);
        expect(escape, closeTo(-k * n0, 0.01 * k * n0),
            reason: '$dt s: the Jeans leak');
        // And the books balance: every gas's net is how its inventory moved.
        final moved = (a.molesOf(o2) - n0) / dt;
        expect(l.net(o2.name), closeTo(moved, 0.01 * k * n0),
            reason: '$dt s: the ledger nets to the inventory');
      }
    });
  });

  group('methane', () {
    test('beyond the reference it oxidises to CO2 and water', () {
      final a = seed('earth');
      final ch4 = a.molesOf(AtmosphereGas.methane);
      final co2 = a.molesOf(AtmosphereGas.carbonDioxide);
      final h2o = a.molesOf(AtmosphereGas.water);
      final o2 = a.molesOf(AtmosphereGas.oxygen);
      a.add(AtmosphereGas.methane, 1e16);
      service.advance(a, AtmosphereFlows(), dt: service.methaneLifetimeSeconds);
      final left = a.molesOf(AtmosphereGas.methane) - ch4;
      expect(left, closeTo(1e16 / math.e, 1e16 * 1e-9));
      final burned = 1e16 - left;
      expect(a.molesOf(AtmosphereGas.carbonDioxide) - co2,
          closeTo(burned, burned * 1e-6));
      expect(a.molesOf(AtmosphereGas.water) - h2o,
          closeTo(2 * burned, burned * 1e-6));
      expect(o2 - a.molesOf(AtmosphereGas.oxygen),
          closeTo(2 * burned, burned * 1e-6));
    });

    test('a reference Titan rests', () {
      final a = seed('titan');
      expect(a.isAtRest, isTrue);
      // Integrated anyway: its methane does not oxidise (only an excess
      // does). What it loses is Jeans escape, a part in 1e12 a century.
      service.advance(a, AtmosphereFlows(), dt: 100 * year);
      expect(a.ledger!.rate(GasProcess.chemistry, AtmosphereGas.methane.name),
          0);
      final ref = a.referenceMolesOf(AtmosphereGas.methane);
      expect(a.molesOf(AtmosphereGas.methane), closeTo(ref, ref * 1e-10));
    });
  });

  group('warp: one long step lands where many short ones do', () {
    void same(PlanetAtmosphere big, PlanetAtmosphere small, double tol,
        {double? co2Tol}) {
      for (final g in AtmosphereGas.values) {
        final x = big.molesOf(g);
        final t = g == AtmosphereGas.carbonDioxide ? co2Tol ?? tol : tol;
        expect(small.molesOf(g), closeTo(x, x.abs() * t + 1), reason: g.name);
      }
      for (var i = 0; i < big.reservoirs.length; i++) {
        final x = big.reservoirs[i].moles;
        expect(small.reservoirs[i].moles, closeTo(x, x.abs() * tol + 1),
            reason: big.reservoirs[i].name);
      }
      expect(small.greenhouseAgentMoles,
          closeTo(big.greenhouseAgentMoles, big.greenhouseAgentMoles * tol + 1));
    }

    void compare(PlanetAtmosphereService s, String world, double span, int n,
        AtmosphereFlows Function(double dt) flows, double tol,
        {double? co2Tol, void Function(PlanetAtmosphere)? prepare}) {
      final big = seed(world);
      final small = seed(world);
      prepare?.call(big);
      prepare?.call(small);
      s.advance(big, flows(span), dt: span);
      for (var i = 0; i < n; i++) {
        s.advance(small, flows(span / n), dt: span / n);
      }
      same(big, small, tol, co2Tol: co2Tol);
    }

    test('the factory, to its target', () {
      compare(ledger, 'mars', 200 * marsYear, 1000,
          (dt) => run(greenhouse: 50, dt: dt), 1e-9);
    });

    test('the agent breaking down', () {
      // Seeded with agent to break down: from a fresh sky the comparison
      // was of nothing against nothing.
      compare(service, 'venus', 5000 * year, 500, (dt) => run(dt: dt), 1e-9,
          prepare: (a) => a.greenhouseAgentMoles = 1e14);
      final a = seed('venus')..greenhouseAgentMoles = 1e14;
      service.advance(a, run(dt: 5000 * year), dt: 5000 * year);
      expect(a.greenhouseAgentMoles, inExclusiveRange(1e12, 5e13),
          reason: 'about two lifetimes: most of it gone, not all');
    });

    test('the baker', () {
      compare(ledger, 'mars', 20 * marsYear, 1000,
          (dt) => run(bakers: 50, dt: dt), 1e-9);
    });

    test('the sequestrator, to its floor', () {
      compare(ledger, 'earth', 100 * year, 1000,
          (dt) => run(sequestrators: 50, dt: dt), 1e-9);
    });

    test('towers and arrays holding the Moon against its leak', () {
      compare(service, 'moon', 10 * year, 1000,
          (dt) => run(oxygenators: 50, arrays: 6, dt: dt), 1e-6);
    });

    test('methane oxidising', () {
      final big = seed('earth')..add(AtmosphereGas.methane, 1e16);
      final small = seed('earth')..add(AtmosphereGas.methane, 1e16);
      service.advance(big, AtmosphereFlows(), dt: 50 * year);
      for (var i = 0; i < 1000; i++) {
        service.advance(small, AtmosphereFlows(), dt: 50 * year / 1000);
      }
      same(big, small, 1e-9);
    });

    test('the whole family on a warming Mars', () {
      // Feedbacks on: the caps answer the agent, the oxygenators eat the
      // baked CO2, the sequestrators race them. Sub-stepped, so a part in
      // a thousand — except the CO2, which the oxygenators hold at its
      // floor: a trace there, whose last parts in a hundred are which side
      // of a sub-step the baked and industrial CO2 landed on.
      compare(service, 'mars', 20 * marsYear, 2000,
          (dt) => run(
              oxygenators: 20,
              greenhouse: 10,
              bakers: 20,
              sequestrators: 2,
              pollutionRate: 40,
              dt: dt),
          1e-3,
          co2Tol: 2e-2);
    });

    test('a vast step drives nothing negative', () {
      final a = seed('mars');
      service.advance(
          a,
          run(
              oxygenators: 50,
              greenhouse: 50,
              bakers: 50,
              sequestrators: 50,
              arrays: 10,
              dt: 1e6 * marsYear),
          dt: 1e6 * marsYear);
      for (final g in AtmosphereGas.values) {
        expect(a.molesOf(g), greaterThanOrEqualTo(0), reason: g.name);
      }
      for (final r in a.reservoirs) {
        expect(r.moles, greaterThanOrEqualTo(0), reason: r.name);
      }
      expect(a.greenhouseAgentMoles, greaterThanOrEqualTo(0));
      expect(a.surfaceTemperatureK.isFinite, isTrue);
      expect(a.surfaceTemperatureK, lessThan(tuning.warmingTargetK + 30));
    });
  });

  group('the ledger', () {
    test('says which colony is doing what to the sky', () {
      final a = seed('mars');
      final flows = AtmosphereFlows()
        ..addColony(
            pollutionRate: 10,
            oxygenatorRun: 3,
            dt: 1e5,
            colony: 'a',
            colonyName: 'Ares')
        ..addColony(
            pollutionRate: 0,
            oxygenatorRun: 1,
            towers: TowerRuns()..greenhouse = 2,
            dt: 1e5,
            colony: 'b',
            colonyName: 'Bradbury');
      ledger.advance(a, flows, dt: 1e5);
      final l = a.ledger!;
      final o2 = AtmosphereGas.oxygen.name;
      final total = l.rate(GasProcess.oxygenator, o2);
      expect(total, closeTo(4 * tuning.oxygenatorRate, total * 1e-9));
      final ares = l.colonies['a']!;
      final bradbury = l.colonies['b']!;
      expect(ares.name, 'Ares');
      expect(ares.rates[GasProcess.oxygenator]![o2],
          closeTo(0.75 * total, total * 1e-9));
      expect(bradbury.rates[GasProcess.oxygenator]![o2],
          closeTo(0.25 * total, total * 1e-9));
      expect(bradbury.rates[GasProcess.greenhouse]![agentGasKey],
          closeTo(2 * tuning.greenhouseRate, tuning.greenhouseRate * 1e-6));
      expect(ares.rates[GasProcess.greenhouse], isNull);
      expect(ares.rates[GasProcess.industry]![AtmosphereGas.carbonDioxide.name],
          closeTo(10 * ledger.molesPerPollutionSecond, 1e-6));
    });

    test('the waiting flows keep their towers and colonies through a save', () {
      final a = seed('mars');
      a.pendingFlows.addColony(
          pollutionRate: 4,
          oxygenatorRun: 1,
          towers: TowerRuns()
            ..greenhouse = 2
            ..baker = 3
            ..sequestrator = 0.5
            ..retention = 1,
          dt: 60,
          colony: 'x',
          colonyName: 'Xanadu');
      final b = seed('mars')..restore(a.toJson());
      final fa = a.takePendingFlows()!;
      final fb = b.takePendingFlows()!;
      expect(fb.greenhouseRun, fa.greenhouseRun);
      expect(fb.bakerRun, fa.bakerRun);
      expect(fb.sequestratorRun, fa.sequestratorRun);
      expect(fb.retentionRun, fa.retentionRun);
      expect(fb.retentionArrays, 1);
      expect(fb.byColony['x']!.name, 'Xanadu');
      expect(fb.byColony['x']!.greenhouse, 120);
      expect(fb.seconds, 60);
    });
  });
}
