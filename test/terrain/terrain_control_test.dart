// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/planetary/terrain_config.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_control.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_feature.dart';
import 'package:flutter_test/flutter_test.dart';

const double _moonRadius = 1.7374e6;

/// Evenly spread, deterministic directions over the sphere.
List<Vector3> sphereDirections(int n) {
  final golden = math.pi * (3.0 - math.sqrt(5.0));
  return [
    for (var i = 0; i < n; i++)
      () {
        final y = 1.0 - 2.0 * (i + 0.5) / n;
        final r = math.sqrt(math.max(0.0, 1.0 - y * y));
        final t = golden * i;
        return Vector3(math.cos(t) * r, y, math.sin(t) * r);
      }(),
  ];
}

SyntheticControl control({int seed = 0x11A00, double lineation = 0}) =>
    SyntheticControl(
      seed: seed,
      radiusM: _moonRadius,
      reliefScaleM: 4000,
      lineation: lineation,
    );

void main() {
  group('UniformControl', () {
    test('reports the same everywhere', () {
      const c = UniformControl(relief: 1234, roughness: 0.3, ridgedness: 0.7);
      for (final d in sphereDirections(50)) {
        expect(c.reliefAt(d), 1234);
        expect(c.roughnessAt(d), 0.3);
        expect(c.ridgednessAt(d), 0.7);
        expect(c.lineationAt(d), Vector3.zero);
      }
    });
  });

  group('SyntheticControl', () {
    test('is deterministic', () {
      final a = control(), b = control();
      for (final d in sphereDirections(80)) {
        expect(b.reliefAt(d), a.reliefAt(d));
        expect(b.roughnessAt(d), a.roughnessAt(d));
        expect(b.ridgednessAt(d), a.ridgednessAt(d));
      }
    });

    test('the seed changes the fields', () {
      final a = control(seed: 1), b = control(seed: 2);
      var differing = 0;
      for (final d in sphereDirections(100)) {
        if ((a.reliefAt(d) - b.reliefAt(d)).abs() > 1e-9) differing++;
      }
      expect(differing, greaterThan(95));
    });

    test('channels stay inside their declared ranges', () {
      final c = control();
      for (final d in sphereDirections(500)) {
        expect(c.reliefAt(d), inInclusiveRange(0.0, 4000.0));
        expect(c.roughnessAt(d), inInclusiveRange(0.0, 1.0));
        expect(c.ridgednessAt(d), inInclusiveRange(0.0, 1.0));
      }
    });

    test('actually VARIES — the whole reason it exists', () {
      // A control field that returns nearly the same relief everywhere would
      // leave terrain exactly as uniform as the plain fBm it replaces, while
      // passing every range check above.
      final c = control();
      final relief = [for (final d in sphereDirections(600)) c.reliefAt(d)];
      final lo = relief.reduce(math.min), hi = relief.reduce(math.max);
      expect(hi - lo, greaterThan(1000),
          reason: 'relief should span provinces, not hover at one value');
      final mean = relief.reduce((a, b) => a + b) / relief.length;
      final variance = relief
              .map((v) => (v - mean) * (v - mean))
              .reduce((a, b) => a + b) /
          relief.length;
      expect(math.sqrt(variance), greaterThan(200));
    });

    test('varies SLOWLY — provinces, not landforms', () {
      // The control fields must be far lower frequency than the detail layer,
      // or they stop reading as regions and start reading as more noise.
      final c = control();
      final base = const Vector3(0.31, 0.45, 0.84).normalized;
      // 2 km apart on a Moon-sized body is a small step against a 400 km
      // region scale, so relief should barely move.
      final seed = base.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
      final tangent = seed.cross(base).normalized;
      final near = (base + tangent * (2000 / _moonRadius)).normalized;
      final delta = (c.reliefAt(base) - c.reliefAt(near)).abs();
      expect(delta, lessThan(120),
          reason: 'relief jumped ${delta.toStringAsFixed(0)} m over 2 km');
    });

    test('lineation is off by default and tangent when on', () {
      final off = control();
      for (final d in sphereDirections(40)) {
        expect(off.lineationAt(d), Vector3.zero);
      }
      final on = control(lineation: 1.0);
      for (final d in sphereDirections(200)) {
        final l = on.lineationAt(d);
        // Perpendicular to the radial: a lineation with a radial component
        // would tilt features out of the surface.
        expect(l.dot(d).abs(), lessThan(1e-9), reason: 'not tangent at $d');
        expect(l.length, closeTo(1.0, 1e-9));
      }
    });
  });

  group('ErodedReliefFeature', () {
    final feature = ErodedReliefFeature(
      seed: 0xEA47B,
      radiusM: _moonRadius,
      featureScaleM: 18000,
    );

    test('is deterministic and bounded by the local relief', () {
      final c = control();
      for (final d in sphereDirections(400)) {
        final h = feature.heightAt(d, c);
        expect(h, feature.heightAt(d, c));
        expect(h.abs(), lessThanOrEqualTo(c.reliefAt(d) + 1e-9));
      }
    });

    test('zero relief yields exactly zero, with no noise leaking through', () {
      const flat = UniformControl(relief: 0);
      for (final d in sphereDirections(60)) {
        expect(feature.heightAt(d, flat), 0);
      }
    });

    test('relief scales the output', () {
      const small = UniformControl(relief: 100);
      const big = UniformControl(relief: 10000);
      var ratioSum = 0.0;
      var n = 0;
      for (final d in sphereDirections(200)) {
        final a = feature.heightAt(d, small);
        if (a.abs() < 1e-6) continue;
        ratioSum += feature.heightAt(d, big) / a;
        n++;
      }
      expect(ratioSum / n, closeTo(100, 1));
    });

    test('ridgedness changes the character, not just the scale', () {
      const rounded = UniformControl(relief: 3000, ridgedness: 0);
      const sharp = UniformControl(relief: 3000, ridgedness: 1);
      var differing = 0;
      for (final d in sphereDirections(200)) {
        if ((feature.heightAt(d, rounded) - feature.heightAt(d, sharp)).abs() >
            1.0) {
          differing++;
        }
      }
      expect(differing, greaterThan(190));
    });

    test('roughness raises detail amplitude', () {
      const smooth = UniformControl(relief: 3000, roughness: 0);
      const rough = UniformControl(relief: 3000, roughness: 1);
      double meanAbs(UniformControl c) {
        var sum = 0.0;
        final dirs = sphereDirections(300);
        for (final d in dirs) {
          sum += feature.heightAt(d, c).abs();
        }
        return sum / dirs.length;
      }
      expect(meanAbs(rough), greaterThan(meanAbs(smooth) * 1.5));
    });
  });

  group('TerrainField with the detail layer', () {
    const legacy = TerrainConfig(
        seed: 0x11A00, amplitude: 3000, featureScale: 18000);
    const eroded = TerrainConfig(
      seed: 0x11A00,
      amplitude: 3000,
      featureScale: 18000,
      erodedDetail: true,
    );

    test('honours the +/- amplitude contract the mesher relies on', () {
      // cell_mesher sizes its voxel shell from this bound, and the collision
      // raymarch brackets against it. Breaking it clips terrain rather than
      // just looking different.
      final f = eroded.fieldFor(_moonRadius);
      for (final d in sphereDirections(2000)) {
        expect(f.heightInDirection(d.x, d.y, d.z).abs(),
            lessThanOrEqualTo(3000 + 1e-6));
      }
    });

    test('is deterministic across instances', () {
      final a = eroded.fieldFor(_moonRadius);
      final b = eroded.fieldFor(_moonRadius);
      for (final d in sphereDirections(100)) {
        expect(b.heightInDirection(d.x, d.y, d.z),
            a.heightInDirection(d.x, d.y, d.z));
      }
    });

    test('groundRadiusAt stays the zero crossing of density', () {
      final f = eroded.fieldFor(_moonRadius);
      for (final d in sphereDirections(200)) {
        final g = f.groundRadiusAt(d.x, d.y, d.z);
        expect(f.density(d.x * g, d.y * g, d.z * g).abs(), lessThan(1e-3));
        expect(f.density(d.x * (g - 50), d.y * (g - 50), d.z * (g - 50)),
            lessThan(0));
        expect(f.density(d.x * (g + 50), d.y * (g + 50), d.z * (g + 50)),
            greaterThan(0));
      }
    });

    test('actually produces different ground than the legacy field', () {
      // Same seed, same amplitude — if these agreed, the layer would not be
      // engaged and every test above would be passing vacuously.
      final a = legacy.fieldFor(_moonRadius);
      final b = eroded.fieldFor(_moonRadius);
      var differing = 0;
      for (final d in sphereDirections(200)) {
        if ((a.heightInDirection(d.x, d.y, d.z) -
                    b.heightInDirection(d.x, d.y, d.z))
                .abs() >
            1.0) {
          differing++;
        }
      }
      expect(differing, greaterThan(190));
    });

    test('off by default, so no body changes without being migrated', () {
      const untouched =
          TerrainConfig(seed: 5, amplitude: 1000, featureScale: 9000);
      expect(untouched.erodedDetail, isFalse);
      expect(untouched.fieldFor(_moonRadius).detail, isNull);
    });
  });

  group('TerrainDetail', () {
    test('none is flat', () {
      expect(TerrainDetail.none.isEmpty, isTrue);
      for (final d in sphereDirections(30)) {
        expect(TerrainDetail.none.heightAt(d), 0);
      }
    });

    test('sums its features', () {
      final c = control();
      final f = ErodedReliefFeature(
          seed: 7, radiusM: _moonRadius, featureScaleM: 18000);
      final one = TerrainDetail([f], c);
      final two = TerrainDetail([f, f], c);
      for (final d in sphereDirections(50)) {
        expect(two.heightAt(d), closeTo(one.heightAt(d) * 2, 1e-9));
      }
    });

    test('peakRelief finds a bound the control never exceeds', () {
      final c = control();
      final detail = TerrainDetail(
        [
          ErodedReliefFeature(
              seed: 3, radiusM: _moonRadius, featureScaleM: 18000)
        ],
        c,
      );
      final peak = detail.peakRelief(samples: 2048);
      // The estimate is a sampling of a noise field, so it can undershoot the
      // true maximum slightly; it must be close, and callers pad it.
      for (final d in sphereDirections(4000)) {
        expect(c.reliefAt(d), lessThanOrEqualTo(peak * 1.10));
      }
      expect(peak, greaterThan(0));
    });
  });
}
