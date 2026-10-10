// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Composition used to drive reentry heating and sky colour but not one number
/// a wing feels. These pin the coupling — and pin that it stays inert until a
/// colony has actually changed something.
void main() {
  const earthAir = AtmosphereModel(
    seaLevelPressure: 101325,
    seaLevelDensity: 1.225,
    seaLevelTemperature: 288,
    scaleHeight: 8500,
    atmosphereHeight: 140000,
  );

  test('an unchanged mix returns the hand-tuned model untouched', () {
    final mix = AtmosphericComposition.earth();
    final same = earthAir.withMeanMolarMass(
      baselineKgPerMol: mix.meanMolecularWeight,
      currentKgPerMol: mix.meanMolecularWeight,
    );
    expect(identical(same, earthAir), isTrue);
  });

  test('heavier air sits lower: denser at the surface, thinner aloft', () {
    final base = AtmosphericComposition.earth();
    // A heavily CO2-loaded version of the same sky.
    final loaded = AtmosphericComposition({
      ...base.fractions,
      AtmosphereGas.carbonDioxide: 0.25,
    });

    final changed = earthAir.withMeanMolarMass(
      baselineKgPerMol: base.meanMolecularWeight,
      currentKgPerMol: loaded.meanMolecularWeight,
    );

    expect(loaded.meanMolecularWeight, greaterThan(base.meanMolecularWeight));
    expect(changed.seaLevelDensity, greaterThan(earthAir.seaLevelDensity));
    expect(changed.scaleHeight, lessThan(earthAir.scaleHeight));

    // And that reaches the thing a wing actually feels.
    expect(changed.sampleAt(0).density,
        greaterThan(earthAir.sampleAt(0).density));
    expect(changed.sampleAt(30000).density,
        lessThan(earthAir.sampleAt(30000).density));
  });

  test('colony emissions drive the change end to end', () {
    final mars = RealSolarSystem.build().require(const BodyId('mars'));
    final state = PlanetAtmosphere.seed(mars)!;
    const PlanetAtmosphereService().advance(
      state,
      AtmosphereFlows()
        ..addColony(pollutionRate: 3000, oxygenatorRun: 0, dt: 1e8),
      dt: 1e8,
    );

    final marsAir = mars.atmosphere!;
    final changed = state.air!;

    expect(state.isMeasurable, isTrue);
    // Mars is already almost pure CO2, so adding more barely moves the mean
    // molar mass: what the extra gas does is add PRESSURE, and the density
    // a wing feels rises with it — by about the share of air added.
    final added = state.totalMoles / state.referenceTotalMoles - 1;
    expect(added, greaterThan(0));
    expect(changed.seaLevelPressure / marsAir.seaLevelPressure - 1,
        closeTo(added, added * 0.05));
    expect(changed.seaLevelDensity, greaterThan(marsAir.seaLevelDensity));
    expect(
        (changed.scaleHeight - marsAir.scaleHeight).abs() /
            marsAir.scaleHeight,
        lessThan(0.05),
        reason: 'the mix is still CO2: scale height barely moves');
  });
}
