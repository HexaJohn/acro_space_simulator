// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// A planet's air as an inventory of gas (docs/plans/terraforming.md §3.1-3.2,
/// phase 1). These pin it against the REAL mass of air involved, so the answer
/// is honest on Earth and on Mars alike — and pin that an untouched world
/// reads back exactly the hand-tuned air it always had.
///
/// The ledger tests use [PlanetAtmosphereService.ledgerOnly]: they pin what
/// the colonies put in and take out, mole for mole, and since phase 2 the
/// planet answers back (Mars's cap takes industry CO2, its soil gives some
/// up as the towers warm it) — that is pinned in planet_feedbacks_test.dart.
void main() {
  final system = RealSolarSystem.build();
  CelestialBody body(String id) => system.require(BodyId(id));
  PlanetAtmosphere seed(String id) => PlanetAtmosphere.seed(body(id))!;
  const service = PlanetAtmosphereService();
  const ledger = PlanetAtmosphereService.ledgerOnly();
  const marsYear = 686.98 * 86400.0;
  const atm = 101325.0;

  /// [towers] at full throttle and [pollutionRate] of industry, held for
  /// [dt] seconds, as one step.
  AtmosphereFlows flows({
    double towers = 0,
    double pollutionRate = 0,
    required double dt,
  }) =>
      AtmosphereFlows()
        ..addColony(pollutionRate: pollutionRate, oxygenatorRun: towers, dt: dt);

  group('seeding', () {
    test('atmospheric mole count matches the real figure for Earth', () {
      // Earth's atmosphere is ~1.8e20 moles; Mars's ~5.4e17.
      expect(seed('earth').totalMoles, inInclusiveRange(1.5e20, 2.1e20));
      expect(seed('mars').totalMoles, inInclusiveRange(4.5e17, 6.5e17));
    });

    test('an untouched inventory hands back the reference air, identically',
        () {
      for (final id in ['earth', 'mars', 'venus', 'titan']) {
        final a = seed(id);
        expect(identical(a.air, body(id).atmosphere), isTrue, reason: id);
        expect(identical(a.composition, body(id).composition), isTrue,
            reason: id);
        expect(a.surfacePressurePa,
            closeTo(body(id).atmosphere!.seaLevelPressure, 1e-9 * 1e7));
      }
    });

    test('an airless world starts with an empty sky; a giant has none', () {
      for (final id in ['moon', 'mercury']) {
        final a = PlanetAtmosphere.seed(body(id))!;
        expect(a.totalMoles, 0, reason: id);
        expect(a.air, isNull, reason: id);
        expect(a.composition, isNull, reason: id);
        expect(a.isAtRest, isTrue, reason: id);
      }
      expect(PlanetAtmosphere.seed(body('jupiter')), isNull,
          reason: 'no surface to hold a sky against');
      expect(PlanetAtmosphere.seed(body('sun')), isNull);
    });
  });

  group('derived air', () {
    test('more of the same mix: pressure and density follow the mass', () {
      final a = seed('mars');
      final ref = a.air!;
      for (final e in a.moles.entries) {
        a.add(e.key, e.value); // double every gas
      }
      final air = a.air!;
      final tr = air.seaLevelTemperature / ref.seaLevelTemperature;
      expect(air.seaLevelPressure, closeTo(2 * ref.seaLevelPressure, 1e-9));
      expect(air.seaLevelTemperature, greaterThan(ref.seaLevelTemperature),
          reason: 'twice the CO2, in twice the pressure: a warmer Mars');
      expect(air.seaLevelDensity, closeTo(2 * ref.seaLevelDensity / tr, 1e-12));
      expect(air.scaleHeight, closeTo(ref.scaleHeight * tr, 1e-6),
          reason: 'same molar mass: scale height follows temperature');
      expect(air.atmosphereHeight, greaterThan(ref.atmosphereHeight),
          reason: 'thicker air reaches higher before it counts as space');
      // The top still sits at the reference's absolute pressure.
      final pTopRef = ref.seaLevelPressure *
          (ref.sampleAt(ref.atmosphereHeight - 1).pressure /
              ref.seaLevelPressure);
      expect(air.sampleAt(air.atmosphereHeight - 1).pressure,
          closeTo(pTopRef, pTopRef * 1e-3));
      expect(a.composition!.fractions[AtmosphereGas.carbonDioxide],
          closeTo(body('mars').composition!.fractions[
              AtmosphereGas.carbonDioxide]!, 1e-12));
    });

    test('heavier air sits lower: denser at the surface, thinner aloft', () {
      final a = seed('earth');
      final ref = a.air!;
      // Swap a quarter of the nitrogen for argon mole-for-mole: a heavier
      // mix that is no greenhouse gas, so the temperature barely moves (CO2
      // would cook the planet and lift the air instead).
      final n2 = a.molesOf(AtmosphereGas.nitrogen) * 0.25;
      a.add(AtmosphereGas.nitrogen, -n2);
      a.add(AtmosphereGas.argon, n2);
      final air = a.air!;
      expect(air.seaLevelTemperature - ref.seaLevelTemperature,
          lessThan(2.0));
      expect(a.meanMolarMass,
          greaterThan(body('earth').composition!.meanMolecularWeight));
      expect(air.seaLevelDensity, greaterThan(ref.seaLevelDensity));
      expect(air.scaleHeight, lessThan(ref.scaleHeight));
      expect(air.sampleAt(0).density, greaterThan(ref.sampleAt(0).density));
      expect(air.sampleAt(30000).density,
          lessThan(ref.sampleAt(30000).density));
    });

    test('applyTo republishes the air without touching anything else', () {
      final a = seed('mars');
      a.add(AtmosphereGas.oxygen, 1e18);
      final mars = body('mars');
      final next = a.applyTo(mars);
      expect(next.id, mars.id);
      expect(next.mu, mars.mu);
      expect(next.radius, mars.radius);
      expect(next.atmosphere!.seaLevelPressure,
          greaterThan(mars.atmosphere!.seaLevelPressure));
      expect(next.composition!.fractions[AtmosphereGas.oxygen]!,
          greaterThan(mars.composition!.fractions[AtmosphereGas.oxygen]!));
    });
  });

  group('industry', () {
    test('Earth shrugs off a colony; Mars does not', () {
      final earth = seed('earth');
      final mars = seed('mars');
      // A heavy industrial colony running for a decade of sim time.
      const decade = 3.15e8;
      for (final s in [earth, mars]) {
        ledger.advance(s, flows(pollutionRate: 40, dt: decade), dt: decade);
      }
      expect(earth.isMeasurable, isFalse,
          reason: 'one city cannot move a 1.8e20-mole atmosphere');
      expect(mars.isMeasurable, isTrue,
          reason: 'a thin atmosphere is a different proposition entirely');
      expect(mars.fractionChange(AtmosphereGas.carbonDioxide),
          greaterThan(earth.fractionChange(AtmosphereGas.carbonDioxide) * 100));
      // And it is real gas: Mars's surface pressure went up.
      expect(mars.surfacePressurePa, greaterThan(610));
    });

    test('emissions raise CO2 in the composition, diluting the rest', () {
      final a = seed('mars');
      final base = body('mars').composition!;
      service.advance(a, flows(pollutionRate: 5000, dt: 1e8), dt: 1e8);
      final after = a.composition!;
      expect(after.fractions[AtmosphereGas.carbonDioxide]!,
          greaterThan(base.fractions[AtmosphereGas.carbonDioxide]!));
      expect(after.fractions[AtmosphereGas.nitrogen]!,
          lessThan(base.fractions[AtmosphereGas.nitrogen]!));
      final sum = after.fractions.values.fold(0.0, (x, y) => x + y);
      expect(sum, closeTo(1.0, 1e-9));
    });

    test('scrubbing pulls CO2 back down and releases oxygen', () {
      final a = seed('mars');
      ledger.advance(a, flows(pollutionRate: 200, dt: 1e6), dt: 1e6);
      final dirty = a.molesOf(AtmosphereGas.carbonDioxide);
      final o2 = a.molesOf(AtmosphereGas.oxygen);
      ledger.advance(a, flows(pollutionRate: -200, dt: 1e6), dt: 1e6);
      expect(a.molesOf(AtmosphereGas.carbonDioxide), lessThan(dirty));
      expect(a.molesOf(AtmosphereGas.oxygen), greaterThan(o2),
          reason: 'taking the carbon out releases the oxygen');
    });

    test('a scrubber cannot take out more CO2 than the sky holds', () {
      final a = seed('earth');
      final co2 = a.molesOf(AtmosphereGas.carbonDioxide);
      final o2 = a.molesOf(AtmosphereGas.oxygen);
      // Absurd scrubbing for absurdly long: far more than Earth's CO2.
      service.advance(a, flows(pollutionRate: -1e9, dt: 1e9), dt: 1e9);
      expect(a.molesOf(AtmosphereGas.carbonDioxide), 0);
      expect(a.molesOf(AtmosphereGas.oxygen) - o2,
          closeTo(co2 * service.o2PerScrubbedPollution, co2 * 1e-9),
          reason: 'oxygen for the carbon actually removed, no more');
    });

    test('aerosols settle out when the colony cleans up; CO2 does not', () {
      final a = seed('mars');
      ledger.advance(a, flows(pollutionRate: 60, dt: 5000), dt: 5000);
      final haze = a.aerosolBurden;
      final co2 = a.molesOf(AtmosphereGas.carbonDioxide);
      expect(haze, greaterThan(0));
      for (var i = 0; i < 200; i++) {
        ledger.advance(a, AtmosphereFlows(), dt: 500);
      }
      expect(a.aerosolBurden, lessThan(haze * 0.1),
          reason: 'particulates fall out of the sky');
      expect(a.molesOf(AtmosphereGas.carbonDioxide), co2,
          reason: 'the gas stays put — that is the point');
    });
  });

  group('conservation', () {
    test('every mole added or removed is accounted for', () {
      final a = seed('mars');
      final before = a.totalMoles;
      final o2Before = a.molesOf(AtmosphereGas.oxygen);
      final co2Before = a.molesOf(AtmosphereGas.carbonDioxide);
      // Industry and towers well below the oxygen target.
      const dt = 1e6;
      ledger.advance(a, flows(towers: 3, pollutionRate: 40, dt: dt), dt: dt);
      final co2In = 40 * dt * service.molesPerPollutionSecond;
      final o2In = 3 * dt * service.tuning.oxygenatorRate;
      expect(a.molesOf(AtmosphereGas.carbonDioxide) - co2Before,
          closeTo(co2In, co2In * 1e-9));
      expect(a.molesOf(AtmosphereGas.oxygen) - o2Before,
          closeTo(o2In, o2In * 1e-9));
      expect(a.totalMoles - before, closeTo(co2In + o2In, (co2In + o2In) * 1e-9));
      // No other gas moved.
      for (final g in [AtmosphereGas.nitrogen, AtmosphereGas.argon]) {
        expect(a.molesOf(g), a.referenceMolesOf(g));
      }
    });

    test('pressure is the column weight of the inventory', () {
      final a = seed('mars');
      service.advance(a, flows(towers: 50, dt: 5 * marsYear), dt: 5 * marsYear);
      final mars = body('mars');
      final g = mars.mu / (mars.radius * mars.radius);
      final area = 4 * 3.141592653589793 * mars.radius * mars.radius;
      expect(a.surfacePressurePa,
          closeTo(a.massKg * g / area, a.surfacePressurePa * 1e-6));
    });

    test('two colonies on one world share its air', () {
      final shared = seed('mars');
      final f = AtmosphereFlows()
        ..addColony(
            pollutionRate: 10, oxygenatorRun: 2, dt: 1e5, colony: 'a')
        ..addColony(
            pollutionRate: 30, oxygenatorRun: 1, dt: 1e5, colony: 'b');
      service.advance(shared, f, dt: 1e5);
      final single = seed('mars');
      service.advance(single, flows(towers: 3, pollutionRate: 40, dt: 1e5),
          dt: 1e5);
      expect(shared.molesOf(AtmosphereGas.oxygen),
          single.molesOf(AtmosphereGas.oxygen));
      expect(shared.molesOf(AtmosphereGas.carbonDioxide),
          single.molesOf(AtmosphereGas.carbonDioxide));
      // Side by side, not one after another: their haze is one sky's worth
      // of both colonies' smoke over the same 1e5 s.
      expect(shared.aerosolBurden,
          closeTo(single.aerosolBurden, single.aerosolBurden * 1e-12));
    });
  });

  group('warp', () {
    test('one long step lands where many short ones do', () {
      final big = seed('mars');
      final small = seed('mars');
      // Long enough to hit the oxygen cap part-way through, so the cap's
      // closed form is exercised as well as the linear flows and the haze.
      const span = 40 * marsYear;
      ledger.advance(big, flows(towers: 50, pollutionRate: 40, dt: span),
          dt: span);
      const n = 4000;
      for (var i = 0; i < n; i++) {
        ledger.advance(
            small, flows(towers: 50, pollutionRate: 40, dt: span / n),
            dt: span / n);
      }
      // A few parts per million, not exact, for one honest reason: once the
      // towers are holding at the cap, the CO2 industry keeps adding is
      // heavier than the mean and so RAISES the O2 partial pressure, and short
      // steps judge the cap before each step's CO2 lands while one long step
      // judges it after all of it. Every flow on its own is exact.
      for (final g in AtmosphereGas.values) {
        final x = big.molesOf(g);
        expect(small.molesOf(g), closeTo(x, x.abs() * 1e-5 + 1),
            reason: g.name);
      }
      expect(small.aerosolBurden,
          closeTo(big.aerosolBurden, big.aerosolBurden * 1e-6));
      expect(big.surfacePressurePa.isFinite, isTrue);
    });

    test('a frame of held ticks landing in one step does not inflate haze',
        () {
      // A frame-budgeted colony's whole frame of replayed ticks arrives in
      // the next tick's flows. Its emission RATE is unchanged, so neither is
      // the haze it holds the sky at — the long-step equilibrium.
      const dt = 2e4;
      final inline = seed('mars');
      service.advance(inline, flows(pollutionRate: 60, dt: dt), dt: dt);
      final held = seed('mars');
      final frame = AtmosphereFlows();
      for (var i = 0; i < 6; i++) {
        frame.addColony(
            pollutionRate: 60, oxygenatorRun: 0, dt: dt, colony: 'held');
      }
      expect(frame.seconds, 6 * dt);
      service.advance(held, frame, dt: dt);
      expect(held.aerosolBurden, greaterThan(0));
      expect(held.aerosolBurden,
          closeTo(inline.aerosolBurden, inline.aerosolBurden * 1e-9));
    });

    test('a vast step cannot drive the haze or a gas negative', () {
      final a = seed('mars');
      service.advance(a, flows(pollutionRate: 60, dt: 5000), dt: 5000);
      service.advance(a, flows(pollutionRate: -1e9, dt: 1e12), dt: 1e12);
      expect(a.aerosolBurden, greaterThanOrEqualTo(0));
      for (final g in AtmosphereGas.values) {
        expect(a.molesOf(g), greaterThanOrEqualTo(0));
      }
    });
  });

  group('terraforming at the tuned scale', () {
    test('50 towers bring Mars to breathable-order oxygen in ~30 Mars years',
        () {
      final a = seed('mars');
      final target = service.tuning.oxygenTargetPa;
      double years = 0;
      while (a.partialPressurePa(AtmosphereGas.oxygen) < target * (1 - 1e-9) &&
          years < 100) {
        service.advance(a, flows(towers: 50, dt: marsYear), dt: marsYear);
        years += 1;
      }
      expect(years, inInclusiveRange(28, 32));
      // The towers stop at the target rather than pumping on. Not to the
      // last part in a billion: the warmth the thicker sky holds goes on
      // freeing CO2 from the cap and soil, which raises the mean molar mass
      // and with it the O2 partial pressure, a little past where the towers
      // stopped (the exact stop is pinned on the ledger below).
      service.advance(a, flows(towers: 50, dt: 10 * marsYear),
          dt: 10 * marsYear);
      expect(a.partialPressurePa(AtmosphereGas.oxygen),
          closeTo(target, target * 1e-2));
      // ~0.16 atm of sky, most of it oxygen.
      expect(a.surfacePressurePa / atm, inInclusiveRange(0.15, 0.2));
    });

    test('the towers stop exactly at the target', () {
      final a = seed('mars');
      final target = ledger.tuning.oxygenTargetPa;
      ledger.advance(a, flows(towers: 50, dt: 40 * marsYear),
          dt: 40 * marsYear);
      expect(a.partialPressurePa(AtmosphereGas.oxygen),
          closeTo(target, target * 1e-9));
    });

    test('Mars measurably moves within a single year', () {
      final a = seed('mars');
      service.advance(a, flows(towers: 50, dt: marsYear), dt: marsYear);
      expect(a.surfacePressurePa, greaterThan(610 * 1.5),
          reason: 'a year of a serious tower programme is a real change');
    });

    test('Earth is effectively immovable at the same scale', () {
      final a = seed('earth');
      final p0 = a.surfacePressurePa;
      final x0 = body('earth').composition!.fractions[AtmosphereGas.oxygen]!;
      // Fifty towers (which also scrub, at -2 pollution each) beside a heavy
      // industrial base, for the full thirty Mars years.
      const span = 30 * marsYear;
      service.advance(a, flows(towers: 50, pollutionRate: 40 - 100, dt: span),
          dt: span);
      service.advance(a, flows(pollutionRate: 40, dt: span), dt: span);
      expect((a.surfacePressurePa / p0 - 1).abs(), lessThan(1e-4));
      expect(
          (a.composition!.fractions[AtmosphereGas.oxygen]! - x0).abs(),
          lessThan(1e-4));
      expect(service.oxygenHeadroom(a), 0,
          reason: "Earth's sky already gives full oxygen cover");
    });

    test('the rate scale is tunable', () {
      const fast = PlanetAtmosphereService(
          tuning: TerraformTuning(terraformRateScale: 4.4e5));
      final a = seed('mars');
      final b = seed('mars');
      service.advance(a, flows(towers: 10, dt: marsYear), dt: marsYear);
      fast.advance(b, flows(towers: 10, dt: marsYear), dt: marsYear);
      final da = a.molesOf(AtmosphereGas.oxygen) -
          a.referenceMolesOf(AtmosphereGas.oxygen);
      final db = b.molesOf(AtmosphereGas.oxygen) -
          b.referenceMolesOf(AtmosphereGas.oxygen);
      expect(db, closeTo(2 * da, da * 1e-9));
    });
  });

  group('persistence', () {
    test('the inventory round-trips through JSON', () {
      final a = seed('mars');
      service.advance(a, flows(towers: 20, pollutionRate: 60, dt: marsYear),
          dt: marsYear);
      final b = seed('mars')..restore(a.toJson());
      for (final g in AtmosphereGas.values) {
        expect(b.molesOf(g), a.molesOf(g), reason: g.name);
      }
      expect(b.aerosolBurden, a.aerosolBurden);
      expect(b.air!.seaLevelPressure, a.air!.seaLevelPressure);
      for (var i = 0; i < a.reservoirs.length; i++) {
        expect(b.reservoirs[i].moles, a.reservoirs[i].moles,
            reason: a.reservoirs[i].name);
      }
      expect(b.surfaceTemperatureK, a.surfaceTemperatureK);
    });

    test('flows still waiting are saved with the inventory', () {
      final a = seed('mars');
      a.pendingFlows
        ..addColony(pollutionRate: 40, oxygenatorRun: 2, dt: 300, colony: 'x')
        ..addColony(pollutionRate: -5, oxygenatorRun: 1, dt: 900, colony: 'y');
      final b = seed('mars')..restore(a.toJson());
      final fa = a.takePendingFlows()!;
      final fb = b.takePendingFlows()!;
      expect(fb.pollution, fa.pollution);
      expect(fb.emission, fa.emission);
      expect(fb.oxygenatorRun, fa.oxygenatorRun);
      expect(fb.seconds, fa.seconds);
      expect(b.takePendingFlows(), isNull, reason: 'taken once');
      expect(seed('mars').toJson().containsKey('pending'), isFalse,
          reason: 'nothing waiting, nothing saved');
    });

    test('reset goes back to the exact reference air', () {
      final a = seed('mars');
      service.advance(a, flows(towers: 20, dt: marsYear), dt: marsYear);
      a.resetToReference();
      expect(identical(a.air, body('mars').atmosphere), isTrue);
      expect(a.aerosolBurden, 0);
    });

    test('reset drops the flows the session had waiting', () {
      final a = seed('mars');
      a.pendingFlows.addColony(pollutionRate: 1, oxygenatorRun: 1, dt: 10);
      a.resetToReference();
      expect(a.takePendingFlows(), isNull);
    });
  });

  group('publishing', () {
    test('a sub-tolerance drift is not republished; a real change is', () {
      final a = seed('mars');
      expect(a.needsPublish(), isFalse);
      a.add(AtmosphereGas.oxygen, a.totalMoles * 1e-9);
      expect(a.needsPublish(), isFalse);
      a.add(AtmosphereGas.oxygen, a.totalMoles * 1e-3);
      expect(a.needsPublish(), isTrue);
      a.markPublished();
      expect(a.needsPublish(), isFalse);
    });
  });
}
