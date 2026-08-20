// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/megastructure/halo_ring.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const spec = HaloRingSpec(radiusM: 5.0e6);
  final field = spec.field();

  // A point above the terrain floor at phi (toward the axis by [up] metres).
  Vector3 above(double phi, double z, double up) {
    final rho = field.floorRadiusAt(phi, z) - up;
    return Vector3(math.cos(phi) * rho, math.sin(phi) * rho, z);
  }

  group('spec', () {
    test('default spin yields ~1 g at the floor', () {
      expect(spec.spinGravityMs2, closeTo(9.80665, 1e-9));
      // ~75 minutes for a 5,000 km ring.
      expect(spec.spinPeriodS / 60, closeTo(75, 1));
    });

    test('derived extents are ordered', () {
      expect(spec.crestRadiusM, lessThan(spec.radiusM));
      expect(spec.radiusM, lessThan(spec.outerRadiusM));
      expect(spec.interiorHalfWidthM, lessThan(spec.halfWidthM));
    });
  });

  group('base density', () {
    test('air at the ring centre and on the axis', () {
      expect(field.density(0, 0, 0), greaterThan(0));
      expect(field.density(0, 0, spec.halfWidthM * 2), greaterThan(0));
    });

    test('air just above the terrain floor, solid just below', () {
      for (final phi in [0.0, 1.3, math.pi, 5.1]) {
        final p = above(phi, 1000, 5);
        expect(field.density(p.x, p.y, p.z), greaterThan(0),
            reason: 'above floor at phi=$phi');
        final q = above(phi, 1000, -5);
        expect(field.density(q.x, q.y, q.z), lessThan(0),
            reason: 'below floor at phi=$phi');
      }
    });

    test('solid through the shell, air beyond the hull skin', () {
      final mid = spec.radiusM + spec.shellThicknessM / 2;
      expect(field.density(mid, 0, 0), lessThan(0));
      final out = spec.outerRadiusM + 5;
      expect(field.density(out, 0, 0), greaterThan(0));
    });

    test('air beyond the band edge', () {
      final rho = spec.radiusM + spec.shellThicknessM / 2;
      expect(field.density(rho, 0, spec.halfWidthM + 5), greaterThan(0));
    });

    test('rim wall is solid above the floor, air above the crest', () {
      final zWall = spec.halfWidthM - spec.wallThicknessM / 2;
      final inWall = spec.radiusM - spec.wallHeightM / 2;
      expect(field.density(inWall, 0, zWall), lessThan(0));
      final aboveCrest = spec.crestRadiusM - 5;
      expect(field.density(aboveCrest, 0, zWall), greaterThan(0));
    });
  });

  group('terrain height field', () {
    test('bounded by amplitude and deterministic', () {
      final other = HaloRingSpec(radiusM: 5.0e6).field();
      for (var i = 0; i < 200; i++) {
        final phi = i * 0.031;
        final z = (i % 40 - 20) * 200.0;
        final h = field.heightAt(phi, z);
        expect(h.abs(), lessThanOrEqualTo(spec.terrainAmplitudeM));
        expect(other.heightAt(phi, z), h, reason: 'same seed, same surface');
      }
    });

    test('relief is not everywhere flat', () {
      var spread = 0.0;
      for (var i = 0; i < 50; i++) {
        spread = math.max(spread, field.heightAt(i * 0.1, 0).abs());
      }
      expect(spread, greaterThan(1));
    });

    test('feathers to zero at the wall feet', () {
      expect(field.heightAt(1.0, spec.interiorHalfWidthM), 0);
      expect(field.heightAt(1.0, -spec.interiorHalfWidthM), 0);
    });
  });

  group('terrain edits compose', () {
    test('a sphere brush carves air into solid ground', () {
      final centre = above(2.0, 0, -20); // 20 m under the floor
      final edits = TerrainEdits()
        ..add(TerrainBrush.sphere(centreBF: centre, radiusM: 15));
      final dug = field.withEdits(edits);
      expect(field.density(centre.x, centre.y, centre.z), lessThan(0),
          reason: 'pristine ground is solid');
      expect(dug.density(centre.x, centre.y, centre.z), greaterThan(0),
          reason: 'the brush removed it');
      // Elsewhere unaffected.
      final far = above(4.0, 2000, -20);
      expect(dug.density(far.x, far.y, far.z), lessThan(0));
    });
  });

  group('build state', () {
    test('phase count maps onto stage layers', () {
      final s0 = HaloRingBuildState.of(0, 0.5);
      expect(s0.stage, HaloRingStage.skeleton);
      expect(s0.trussArc, 0.5);
      expect(s0.hullArc, 0);
      expect(s0.terrainArc, 0);
      expect(s0.lightsLevel, 0);

      final s2 = HaloRingBuildState.of(2, 0.25);
      expect(s2.stage, HaloRingStage.terraform);
      expect(s2.trussArc, 1);
      expect(s2.hullArc, 1);
      expect(s2.terrainArc, 0.25);
      expect(s2.lightsLevel, 0);

      final done = HaloRingBuildState.of(4, 0.0);
      expect(done.stage, HaloRingStage.habitable);
      expect(done.stageFraction, 1);
      expect(done.lightsLevel, 1);
    });
  });
}
