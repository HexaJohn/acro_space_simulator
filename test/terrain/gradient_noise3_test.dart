// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/terrain/gradient_noise3.dart';
import 'package:flutter_test/flutter_test.dart';

const noise = GradientNoise3(0x5EED);

/// Central-difference gradient of any scalar field, for checking analytic ones.
({double dx, double dy, double dz}) numericalGradient(
  double Function(double, double, double) f,
  double x,
  double y,
  double z, {
  double h = 1e-5,
}) =>
    (
      dx: (f(x + h, y, z) - f(x - h, y, z)) / (2 * h),
      dy: (f(x, y + h, z) - f(x, y - h, z)) / (2 * h),
      dz: (f(x, y, z + h) - f(x, y, z - h)) / (2 * h),
    );

/// Reproducible sample points, deliberately off the integer lattice (where the
/// field is exactly zero and the derivative check would be trivially easy).
List<List<double>> probePoints(int n, {int seed = 3}) {
  final rng = math.Random(seed);
  return [
    for (var i = 0; i < n; i++)
      [
        rng.nextDouble() * 40 - 20,
        rng.nextDouble() * 40 - 20,
        rng.nextDouble() * 40 - 20,
      ],
  ];
}

void main() {
  group('GradientNoise3', () {
    test('is deterministic', () {
      for (final p in probePoints(50)) {
        final a = noise.sample(p[0], p[1], p[2]);
        final b = noise.sample(p[0], p[1], p[2]);
        expect(b.value, a.value);
        expect(b.dx, a.dx);
        expect(b.dy, a.dy);
        expect(b.dz, a.dz);
      }
    });

    test('stays roughly within -1..1', () {
      var maxAbs = 0.0;
      for (final p in probePoints(3000, seed: 11)) {
        final v = noise.sample(p[0], p[1], p[2]).value;
        maxAbs = math.max(maxAbs, v.abs());
      }
      expect(maxAbs, lessThanOrEqualTo(1.05));
      // And it actually uses the range — a field pinned near zero would pass
      // the bound above while being useless.
      expect(maxAbs, greaterThan(0.5));
    });

    test('is zero on the integer lattice', () {
      // The defining property of gradient noise, and what kills value noise's
      // blockiness: every lattice point evaluates to exactly zero.
      for (var i = -3; i <= 3; i++) {
        for (var j = -3; j <= 3; j++) {
          expect(noise.sample(i.toDouble(), j.toDouble(), 2.0).value,
              closeTo(0, 1e-12));
        }
      }
    });

    test('ANALYTIC derivative matches central differences', () {
      // The lynchpin. erodedFbm keys entirely off these gradients, and a
      // derivative that is merely plausible produces terrain that merely looks
      // plausible while being wrong on exactly the steep faces that matter.
      for (final p in probePoints(400, seed: 7)) {
        final s = noise.sample(p[0], p[1], p[2]);
        final g = numericalGradient(noise.noise, p[0], p[1], p[2]);
        expect(s.dx, closeTo(g.dx, 1e-4), reason: 'd/dx at $p');
        expect(s.dy, closeTo(g.dy, 1e-4), reason: 'd/dy at $p');
        expect(s.dz, closeTo(g.dz, 1e-4), reason: 'd/dz at $p');
      }
    });

    test('the seed changes the field', () {
      const other = GradientNoise3(0xC0FFEE);
      var differing = 0;
      for (final p in probePoints(100, seed: 5)) {
        if ((noise.sample(p[0], p[1], p[2]).value -
                    other.sample(p[0], p[1], p[2]).value)
                .abs() >
            1e-9) {
          differing++;
        }
      }
      expect(differing, greaterThan(95));
    });
  });

  group('fbm3', () {
    test('derivative matches central differences', () {
      double f(double x, double y, double z) =>
          fbm3(noise, x, y, z, octaves: 4).value;
      for (final p in probePoints(120, seed: 21)) {
        final s = fbm3(noise, p[0], p[1], p[2], octaves: 4);
        final g = numericalGradient(f, p[0], p[1], p[2]);
        expect(s.dx, closeTo(g.dx, 1e-3), reason: 'd/dx at $p');
        expect(s.dy, closeTo(g.dy, 1e-3), reason: 'd/dy at $p');
        expect(s.dz, closeTo(g.dz, 1e-3), reason: 'd/dz at $p');
      }
    });

    test('stays roughly within -1..1', () {
      for (final p in probePoints(500, seed: 31)) {
        expect(fbm3(noise, p[0], p[1], p[2], octaves: 6).value.abs(),
            lessThanOrEqualTo(1.05));
      }
    });

    test('zero octaves is a defined no-op, not a divide by zero', () {
      final s = fbm3(noise, 1.5, 2.5, 3.5, octaves: 0);
      expect(s.value, 0);
      expect(s.value.isNaN, isFalse);
    });
  });

  group('erodedFbm', () {
    test('gradient is a slope ESTIMATE, not the exact derivative', () {
      // Documented contract. The exact derivative would need the damping
      // term's own derivative, hence the noise Hessian; this returns the
      // damping-weighted sum of the octave gradients instead. It must still be
      // finite, deterministic, and broadly aligned with the true gradient —
      // it is consumed as a steepness signal.
      double f(double x, double y, double z) =>
          erodedFbm(noise, x, y, z, octaves: 5).value;
      var aligned = 0;
      final points = probePoints(200, seed: 41);
      for (final p in points) {
        final s = erodedFbm(noise, p[0], p[1], p[2], octaves: 5);
        expect(s.dx.isFinite && s.dy.isFinite && s.dz.isFinite, isTrue);
        expect(erodedFbm(noise, p[0], p[1], p[2], octaves: 5).dx, s.dx);
        final g = numericalGradient(f, p[0], p[1], p[2]);
        if (s.dx * g.dx + s.dy * g.dy + s.dz * g.dz > 0) aligned++;
      }
      expect(aligned, greaterThan((points.length * 0.9).floor()),
          reason: 'the estimate should point the same way as the true gradient');
    });

    test('zero damping degenerates to plain fBm', () {
      for (final p in probePoints(40, seed: 51)) {
        final a = erodedFbm(noise, p[0], p[1], p[2],
            octaves: 5, slopeDamping: 0);
        final b = fbm3(noise, p[0], p[1], p[2], octaves: 5);
        expect(a.value, closeTo(b.value, 1e-12));
        expect(a.dx, closeTo(b.dx, 1e-12));
      }
    });

    test('damping suppresses detail where the field is already steep', () {
      // The whole point of the technique. Measured as the RETAINED FRACTION of
      // slope (eroded / plain) rather than the raw loss: steep ground has more
      // slope to shed in absolute terms whatever the damping does, so raw loss
      // conflates the effect with the thing it is conditioned on.
      final points = probePoints(1200, seed: 61);
      // Slope of the leading octaves is what the damping term actually reads.
      final slopes = [
        for (final p in points) fbm3(noise, p[0], p[1], p[2], octaves: 2).slope
      ];
      final sorted = [...slopes]..sort();
      final lowCut = sorted[(sorted.length * 0.15).floor()];
      final highCut = sorted[(sorted.length * 0.85).floor()];

      final steepKept = <double>[], flatKept = <double>[];
      for (var i = 0; i < points.length; i++) {
        final p = points[i];
        final plain = fbm3(noise, p[0], p[1], p[2], octaves: 6);
        if (plain.slope < 1e-9) continue;
        final eroded = erodedFbm(noise, p[0], p[1], p[2], octaves: 6);
        final kept = eroded.slope / plain.slope;
        if (slopes[i] >= highCut) steepKept.add(kept);
        if (slopes[i] <= lowCut) flatKept.add(kept);
      }
      double mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
      final steep = mean(steepKept), flat = mean(flatKept);
      expect(steep, lessThan(flat),
          reason: 'steep ground ($steep) must retain a smaller fraction of its '
              'detail than flat ground ($flat)');
      // And by a decisive margin, not a rounding difference.
      expect(steep, lessThan(flat * 0.8));
    });

    test('stays bounded and finite', () {
      for (final p in probePoints(500, seed: 71)) {
        final s = erodedFbm(noise, p[0], p[1], p[2], octaves: 8);
        expect(s.value.isFinite, isTrue);
        expect(s.value.abs(), lessThanOrEqualTo(1.05));
      }
    });
  });

  group('ridgedFbm', () {
    test('stays within 0..1', () {
      for (final p in probePoints(500, seed: 81)) {
        final v = ridgedFbm(noise, p[0], p[1], p[2]);
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    test('crests where the underlying field crosses zero', () {
      // A ridge is the fold at |n| = 0, so the peak of the first octave should
      // land where the raw field changes sign.
      var found = false;
      for (var t = 0.0; t < 6; t += 0.01) {
        final a = noise.sample(t, 0.3, 0.7).value;
        final b = noise.sample(t + 0.01, 0.3, 0.7).value;
        if (a.sign != b.sign) {
          expect(ridgedFbm(noise, t, 0.3, 0.7, octaves: 1),
              greaterThan(0.9));
          found = true;
          break;
        }
      }
      expect(found, isTrue, reason: 'expected a zero crossing to test against');
    });
  });

  group('domainWarp', () {
    test('is deterministic and actually displaces', () {
      final a = domainWarp(noise, 3.3, -1.7, 5.1);
      final b = domainWarp(noise, 3.3, -1.7, 5.1);
      expect([a.x, a.y, a.z], [b.x, b.y, b.z]);
      expect((a.x - 3.3).abs() + (a.y + 1.7).abs() + (a.z - 5.1).abs(),
          greaterThan(1e-6));
    });

    test('offset is bounded by the requested strength', () {
      for (final p in probePoints(200, seed: 91)) {
        final w = domainWarp(noise, p[0], p[1], p[2], strength: 2.0);
        expect((w.x - p[0]).abs(), lessThanOrEqualTo(2.0 * 1.05));
        expect((w.y - p[1]).abs(), lessThanOrEqualTo(2.0 * 1.05));
        expect((w.z - p[2]).abs(), lessThanOrEqualTo(2.0 * 1.05));
      }
    });

    test('the three channels are decorrelated', () {
      // Sharing lattice cells would collapse the warp onto a diagonal, which
      // looks like the terrain being sheared rather than flowing.
      var same = 0;
      for (final p in probePoints(200, seed: 101)) {
        final w = domainWarp(noise, p[0], p[1], p[2]);
        if ((w.x - p[0] - (w.y - p[1])).abs() < 1e-9) same++;
      }
      expect(same, 0);
    });
  });
}
