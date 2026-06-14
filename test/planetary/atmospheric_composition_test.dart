import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Earth fractions sum to ~1', () {
    final earth = AtmosphericComposition.earth();
    final sum = earth.fractions.values.fold<double>(0, (a, b) => a + b);
    expect(sum, closeTo(1.0, 1e-6));
  });

  test('all factory atmospheres have fractions summing to ~1', () {
    for (final atmo in [
      AtmosphericComposition.earth(),
      AtmosphericComposition.mars(),
      AtmosphericComposition.titan(),
      AtmosphericComposition.venus(),
    ]) {
      final sum = atmo.fractions.values.fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-6));
    }
  });

  test('Earth mean molecular weight is ~0.029 kg/mol', () {
    final earth = AtmosphericComposition.earth();
    expect(earth.meanMolecularWeight, closeTo(0.029, 0.001));
  });

  test('CO2-heavy Mars is heavier than Earth', () {
    final mars = AtmosphericComposition.mars();
    final earth = AtmosphericComposition.earth();
    expect(mars.meanMolecularWeight, greaterThan(earth.meanMolecularWeight));
  });

  test('Venus (CO2) is heavier than Earth too', () {
    final venus = AtmosphericComposition.venus();
    final earth = AtmosphericComposition.earth();
    expect(venus.meanMolecularWeight, greaterThan(earth.meanMolecularWeight));
  });

  test('Mars mean molecular weight is ~that of CO2 (~0.044 kg/mol)', () {
    final mars = AtmosphericComposition.mars();
    expect(mars.meanMolecularWeight, closeTo(0.044, 0.002));
  });

  test('Titan is mostly nitrogen, lighter than Mars', () {
    final titan = AtmosphericComposition.titan();
    final mars = AtmosphericComposition.mars();
    expect(titan.fractions[AtmosphereGas.nitrogen], greaterThan(0.9));
    expect(titan.meanMolecularWeight, lessThan(mars.meanMolecularWeight));
  });

  test('mean molecular weight is positive and finite', () {
    final earth = AtmosphericComposition.earth();
    expect(earth.meanMolecularWeight, greaterThan(0));
    expect(earth.meanMolecularWeight.isFinite, isTrue);
  });

  test('Earth is dominated by nitrogen then oxygen', () {
    final earth = AtmosphericComposition.earth();
    final n2 = earth.fractions[AtmosphereGas.nitrogen]!;
    final o2 = earth.fractions[AtmosphereGas.oxygen]!;
    expect(n2, greaterThan(o2));
    expect(n2, closeTo(0.78, 0.01));
    expect(o2, closeTo(0.21, 0.01));
  });

  test('a custom composition normalises and computes a sane weight', () {
    // Pure hydrogen atmosphere -> mean molecular weight ~ that of H2.
    final h2 = AtmosphericComposition({AtmosphereGas.hydrogen: 1.0});
    expect(h2.meanMolecularWeight, closeTo(0.002016, 1e-4));
  });
}
