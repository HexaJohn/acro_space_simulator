// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/impact_scaling.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:flutter_test/flutter_test.dart';

const double _moonG = 1.62;

void main() {
  group('craterForImpact', () {
    test('reproduces the Apollo S-IVB lunar impact', () {
      // ~13,900 kg at ~2,580 m/s left a crater about 30 m across. This is the
      // calibration point for the default scaling coefficient, so a change to
      // that constant should land here first.
      final e = kineticEnergy(13900, 2580);
      final c = craterForImpact(
        kineticEnergyJ: e,
        surfaceGravityMs2: _moonG,
      )!;
      expect(c.diameterM, inInclusiveRange(25, 45));
    });

    test('holds the simple-crater shape ratios', () {
      final c = craterForImpact(
        kineticEnergyJ: kineticEnergy(5000, 400),
        surfaceGravityMs2: _moonG,
      )!;
      expect(c.depthM / c.diameterM, closeTo(0.2, 1e-9));
      expect(c.rimHeightM / c.diameterM, closeTo(0.04, 1e-9));
    });

    test('grows monotonically with energy', () {
      var previous = 0.0;
      for (final speed in [30.0, 60.0, 120.0, 500.0, 2000.0]) {
        final c = craterForImpact(
          kineticEnergyJ: kineticEnergy(4000, speed),
          surfaceGravityMs2: _moonG,
        )!;
        expect(c.diameterM, greaterThan(previous));
        previous = c.diameterM;
      }
    });

    test('quarter-power law: 16x the energy doubles the crater', () {
      final small = craterForImpact(
        kineticEnergyJ: 1e9,
        surfaceGravityMs2: _moonG,
      )!;
      final big = craterForImpact(
        kineticEnergyJ: 16e9,
        surfaceGravityMs2: _moonG,
      )!;
      expect(big.diameterM / small.diameterM, closeTo(2.0, 1e-6));
    });

    test('higher gravity and denser rock resist excavation', () {
      const e = 1e10;
      final moon = craterForImpact(
          kineticEnergyJ: e, surfaceGravityMs2: _moonG)!;
      final earth = craterForImpact(
          kineticEnergyJ: e, surfaceGravityMs2: 9.81)!;
      expect(earth.diameterM, lessThan(moon.diameterM));
      final hard = craterForImpact(
        kineticEnergyJ: e,
        surfaceGravityMs2: _moonG,
        targetDensityKgM3: 3000,
      )!;
      expect(hard.diameterM, lessThan(moon.diameterM));
    });

    test('declines craters too small to mesh', () {
      expect(
        craterForImpact(kineticEnergyJ: 1, surfaceGravityMs2: _moonG),
        isNull,
      );
      // A gentle bump at walking pace is not a crater.
      expect(
        craterForImpact(
          kineticEnergyJ: kineticEnergy(800, 2),
          surfaceGravityMs2: _moonG,
        ),
        isNull,
      );
    });

    test('rejects nonsense inputs instead of producing NaN geometry', () {
      expect(craterForImpact(kineticEnergyJ: 0, surfaceGravityMs2: _moonG),
          isNull);
      expect(craterForImpact(kineticEnergyJ: -5, surfaceGravityMs2: _moonG),
          isNull);
      expect(craterForImpact(kineticEnergyJ: double.nan, surfaceGravityMs2: _moonG),
          isNull);
      expect(craterForImpact(kineticEnergyJ: 1e10, surfaceGravityMs2: 0), isNull);
    });

    test('clamps runaway energies to the cap', () {
      final c = craterForImpact(
        kineticEnergyJ: 1e30,
        surfaceGravityMs2: _moonG,
        maxRimRadiusM: 250,
      )!;
      expect(c.rimRadiusM, 250);
    });
  });

  group('impactBrush', () {
    test('builds a crater brush matching the sized crater', () {
      const contact = Vector3(0, 0, 1.7374e6);
      final energy = kineticEnergy(9000, 1200);
      final sized = craterForImpact(
        kineticEnergyJ: energy,
        surfaceGravityMs2: _moonG,
      )!;
      final brush = impactBrush(
        contactBF: contact,
        normalBF: Vector3.unitZ,
        kineticEnergyJ: energy,
        surfaceGravityMs2: _moonG,
        tick: 42,
      )!;
      expect(brush.kind, TerrainBrushKind.crater);
      expect(brush.radiusM, sized.rimRadiusM);
      expect(brush.depthM, sized.depthM);
      expect(brush.rimHeightM, sized.rimHeightM);
      expect(brush.centreBF, contact);
      expect(brush.tick, 42);
    });

    test('returns null when the impact is below the threshold', () {
      expect(
        impactBrush(
          contactBF: const Vector3(0, 0, 1.7374e6),
          normalBF: Vector3.unitZ,
          kineticEnergyJ: 10,
          surfaceGravityMs2: _moonG,
        ),
        isNull,
      );
    });
  });
}
