// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/terrain/gradient_noise3.dart';
import 'package:acro_space_simulator/domain/terrain/hydraulic_erosion.dart';
import 'package:flutter_test/flutter_test.dart';

const int _n = 96;

/// Multi-scale fBm relief — ridges and basins, the way real ground is.
///
/// Deliberately NOT a dome. A dome has a consistent downhill, which sounds like
/// the obvious thing to erode, but water on it flows radially OUTWARD and
/// diverges everywhere — so it never concentrates into channels and the whole
/// point of hydraulic erosion cannot show up. Drainage needs basins to run
/// into.
Float64List testTerrain({int seed = 5}) {
  const noise = GradientNoise3(11);
  final g = Float64List(_n * _n);
  for (var y = 0; y < _n; y++) {
    for (var x = 0; x < _n; x++) {
      final u = x / _n, v = y / _n;
      g[y * _n + x] =
          400.0 + fbm3(noise, u * 3, v * 3, seed * 0.37, octaves: 6).value * 320;
    }
  }
  return g;
}

double mean(Float64List a) => a.reduce((x, y) => x + y) / a.length;

/// Mean absolute difference between a cell and its right/down neighbour — a
/// proxy for how rough the surface is at the finest scale.
double roughness(Float64List g, int n) {
  var sum = 0.0;
  var count = 0;
  for (var y = 1; y < n - 1; y++) {
    for (var x = 1; x < n - 1; x++) {
      final i = y * n + x;
      sum += (g[i] - g[i + 1]).abs() + (g[i] - g[i + n]).abs();
      count += 2;
    }
  }
  return sum / count;
}

void main() {
  group('erode', () {
    test('is deterministic for a seed', () {
      final t = testTerrain();
      final a = erode(t, _n, _n,
          params: const ErosionParams(droplets: 3000), seed: 7);
      final b = erode(t, _n, _n,
          params: const ErosionParams(droplets: 3000), seed: 7);
      for (var i = 0; i < a.height.length; i++) {
        expect(b.height[i], a.height[i]);
        expect(b.flow[i], a.flow[i]);
      }
    });

    test('does not modify its input', () {
      final t = testTerrain();
      final copy = Float64List.fromList(t);
      erode(t, _n, _n, params: const ErosionParams(droplets: 2000));
      expect(t, copy);
    });

    test('roughly conserves mass — it MOVES material, it does not delete it',
        () {
      // The physical check. A droplet picking up more than it puts down
      // anywhere would quietly sink the whole terrain, and the result would
      // still look plausible in isolation.
      final t = testTerrain();
      final r = erode(t, _n, _n,
          params: const ErosionParams(droplets: 20000), seed: 3);
      final before = mean(t), after = mean(r.height);
      expect((after - before).abs(), lessThan(mean(t).abs() * 0.05 + 5),
          reason: 'mean height moved from $before to $after');
    });

    test('smooths the surface overall', () {
      final t = testTerrain();
      final r = erode(t, _n, _n,
          params: const ErosionParams(droplets: 40000), seed: 9);
      expect(roughness(r.height, _n), lessThan(roughness(t, _n)));
    });

    test('deposition settles where the water goes', () {
      // The distinguishing test against a plain smoothing pass. A blur also
      // produces a heavy-tailed change distribution (it moves most where
      // curvature is highest), so a percentile ratio proves nothing on its own.
      // What only erosion can do is put the change where the water went.
      final t = testTerrain();
      final r = erode(t, _n, _n,
          params: const ErosionParams(droplets: 40000), seed: 4);

      // This is a HILLSLOPE TRANSPORT model, and the test says so rather than
      // pretending otherwise. Capacity scales with slope, so excavation happens
      // on steep ground — hillsides — while the valleys everything drains into
      // are flat, drop below capacity, and receive the load. Deposition is
      // therefore what tracks the water here, not erosion.
      //
      // Carving valleys INTO bedrock instead would need a stream-power term
      // (incision rising with accumulated discharge), which this does not have;
      // see the note in `hydraulic_erosion.dart`.
      final deposited = <int>[];
      for (var i = 0; i < t.length; i++) {
        if (r.height[i] - t[i] > 1) deposited.add(i);
      }
      expect(deposited, isNotEmpty);

      var depositedFlow = 0.0;
      for (final i in deposited) {
        depositedFlow += r.flow[i];
      }
      depositedFlow /= deposited.length;
      final meanFlow = r.flow.reduce((a, b) => a + b) / r.flow.length;

      expect(depositedFlow, greaterThan(meanFlow),
          reason: 'sediment should settle along the drainage '
              '(deposited=$depositedFlow mean=$meanFlow)');
    });

    test('flow accumulation is a usable 0..1 channel', () {
      final r = erode(testTerrain(), _n, _n,
          params: const ErosionParams(droplets: 20000), seed: 2);
      for (final v in r.flow) {
        expect(v, inInclusiveRange(0.0, 1.0));
        expect(v.isFinite, isTrue);
      }
      expect(r.flow.reduce(math.max), greaterThan(0.5));
    });

    test('flow concentrates rather than spreading evenly', () {
      // The whole value of the channel: it must pick out drainage lines the
      // shader can key riverbeds and wet rock off.
      final r = erode(testTerrain(), _n, _n,
          params: const ErosionParams(droplets: 40000), seed: 6);
      final sorted = Float64List.fromList(r.flow)..sort();
      final median = sorted[sorted.length ~/ 2];
      final top = sorted[(sorted.length * 0.99).floor()];
      // The threshold is modest ON PURPOSE: the channel is log-compressed so
      // tributaries stay visible against the trunk lines, which deliberately
      // narrows the top-to-median ratio. Raw accumulation would show a far
      // wider spread and be far less useful to a shader.
      expect(top, greaterThan(median * 1.4));
    });

    test('produces no NaN or infinity', () {
      final r = erode(testTerrain(), _n, _n,
          params: const ErosionParams(droplets: 20000), seed: 8);
      for (final v in r.height) {
        expect(v.isFinite, isTrue);
      }
    });

    test('zero droplets is a clean no-op', () {
      final t = testTerrain();
      final r = erode(t, _n, _n, params: const ErosionParams(droplets: 0));
      expect(r.height, t);
      for (final v in r.flow) {
        expect(v, 0);
      }
    });

    test('a flat plain is left alone', () {
      // No slope, no transport. A pass that pitted flat ground would be
      // manufacturing terrain rather than eroding it.
      final flat = Float64List(_n * _n);
      final r = erode(flat, _n, _n,
          params: const ErosionParams(droplets: 5000), seed: 1);
      for (final v in r.height) {
        expect(v.abs(), lessThan(1e-6));
      }
    });
  });
}
