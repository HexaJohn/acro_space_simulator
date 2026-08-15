// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/planetary/atmosphere_pollution.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:flutter_test/flutter_test.dart';

/// The colony read the host body's gas mix but never changed it. These pin the
/// closed loop — and pin it against the REAL mass of air involved, so the
/// answer is honest on Earth and on Mars alike.
void main() {
  const service = AtmospherePollutionService();

  double molesFor({
    required double pressurePa,
    required double gravity,
    required double radius,
    required AtmosphericComposition mix,
  }) =>
      AtmospherePollution.molesOf(
        surfacePressurePa: pressurePa,
        gravity: gravity,
        bodyRadiusM: radius,
        meanMolarMassKgPerMol: mix.meanMolecularWeight,
      );

  test('atmospheric mole count matches the real figure for Earth', () {
    final moles = molesFor(
      pressurePa: 101325,
      gravity: 9.81,
      radius: 6371000,
      mix: AtmosphericComposition.earth(),
    );
    // Earth's atmosphere is ~1.8e20 moles.
    expect(moles, greaterThan(1.5e20));
    expect(moles, lessThan(2.1e20));
  });

  test('Earth shrugs off a colony; Mars does not', () {
    final earth = AtmospherePollution(
      bodyId: 'earth',
      totalMoles: molesFor(
        pressurePa: 101325,
        gravity: 9.81,
        radius: 6371000,
        mix: AtmosphericComposition.earth(),
      ),
    );
    final mars = AtmospherePollution(
      bodyId: 'mars',
      totalMoles: molesFor(
        pressurePa: 610,
        gravity: 3.72,
        radius: 3389500,
        mix: AtmosphericComposition.mars(),
      ),
    );

    // A heavy industrial colony running for a decade of sim time.
    const decade = 3.15e8;
    for (final state in [earth, mars]) {
      service.advance(state, pollutionRate: 40, dt: decade);
    }

    expect(earth.isMeasurable, isFalse,
        reason: 'one city cannot move a 1.8e20-mole atmosphere');
    expect(mars.isMeasurable, isTrue,
        reason: 'a thin atmosphere is a different proposition entirely');
    expect(mars.co2Fraction, greaterThan(earth.co2Fraction * 100));
  });

  test('emissions raise CO2 in the composition, diluting the rest', () {
    final base = AtmosphericComposition.mars();
    final state = AtmospherePollution(bodyId: 'mars', totalMoles: 1e18);
    service.advance(state, pollutionRate: 5000, dt: 1e8);

    final after = state.applyTo(base);
    expect(after.fractions[AtmosphereGas.carbonDioxide]!,
        greaterThan(base.fractions[AtmosphereGas.carbonDioxide]!));
    expect(after.fractions[AtmosphereGas.nitrogen]!,
        lessThan(base.fractions[AtmosphereGas.nitrogen]!));
    // Still a valid mix.
    final sum = after.fractions.values.fold(0.0, (a, b) => a + b);
    expect(sum, closeTo(1.0, 1e-9));
  });

  test('scrubbing pulls CO2 back down and releases oxygen', () {
    final state = AtmospherePollution(bodyId: 'mars', totalMoles: 1e18);
    service.advance(state, pollutionRate: 200, dt: 1e6);
    final dirty = state.co2Moles;

    // Terraforming towers scrub (negative pollution).
    service.advance(state, pollutionRate: -200, dt: 1e6);
    expect(state.co2Moles, lessThan(dirty));
    expect(state.o2Moles, greaterThan(0),
        reason: 'taking the carbon out releases the oxygen');
  });

  test('aerosols settle out when the colony cleans up; CO2 does not', () {
    final state = AtmospherePollution(bodyId: 'mars', totalMoles: 1e18);
    service.advance(state, pollutionRate: 60, dt: 5000);
    final haze = state.aerosolBurden;
    final co2 = state.co2Moles;
    expect(haze, greaterThan(0));

    // Industry stops. Give it a season.
    for (var i = 0; i < 200; i++) {
      service.advance(state, pollutionRate: 0, dt: 500);
    }
    expect(state.aerosolBurden, lessThan(haze * 0.1),
        reason: 'particulates fall out of the sky');
    expect(state.co2Moles, closeTo(co2, 1e-6),
        reason: 'the gas stays put — that is the point');
  });

  test('an airless body cannot be polluted', () {
    final vacuum = AtmospherePollution(bodyId: 'moon', totalMoles: 0);
    service.advance(vacuum, pollutionRate: 1000, dt: 1e6);
    expect(vacuum.co2Fraction, 0);
    final base = AtmosphericComposition.earth();
    expect(vacuum.applyTo(base).fractions, base.fractions);
  });
}
