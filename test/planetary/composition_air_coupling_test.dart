// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/planetary/atmosphere_pollution.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
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
    final base = AtmosphericComposition.mars();
    final state = AtmospherePollution(bodyId: 'mars', totalMoles: 1e17);
    const AtmospherePollutionService().advance(
      state,
      pollutionRate: 3000,
      dt: 1e8,
    );

    final after = state.applyTo(base);
    const marsAir = AtmosphereModel(
      seaLevelPressure: 610,
      seaLevelDensity: 0.020,
      seaLevelTemperature: 210,
      scaleHeight: 11100,
      atmosphereHeight: 90000,
    );
    final changed = marsAir.withMeanMolarMass(
      baselineKgPerMol: base.meanMolecularWeight,
      currentKgPerMol: after.meanMolecularWeight,
    );

    expect(state.isMeasurable, isTrue);
    // Mars is already almost pure CO2, so adding more barely moves the mean
    // molar mass — the drag change should be real but tiny, not dramatic.
    expect(changed.seaLevelDensity,
        greaterThanOrEqualTo(marsAir.seaLevelDensity));
    expect(
        (changed.seaLevelDensity - marsAir.seaLevelDensity).abs() /
            marsAir.seaLevelDensity,
        lessThan(0.05));
  });
}
