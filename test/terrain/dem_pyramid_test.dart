// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';
import 'package:flutter_test/flutter_test.dart';

const double _moonRadius = 1.7374e6;

/// A pyramid whose elevation is an analytic function of direction, so every
/// sample has a known expected value.
DemPyramid synthetic({
  int faceSize = 64,
  int levelCount = 4,
  double Function(Vector3)? f,
}) {
  final fn = f ?? (d) => 4000.0 * d.z;
  const minE = -5000.0, maxE = 5000.0;
  final levels = <List<Int16List>>[];
  for (var l = 0; l < levelCount; l++) {
    final size = faceSize >> l;
    final faces = <Int16List>[];
    for (final face in CubeFace.values) {
      final grid = Int16List(size * size);
      for (var y = 0; y < size; y++) {
        final t = (y + 0.5) / size * 2 - 1;
        for (var x = 0; x < size; x++) {
          final s = (x + 0.5) / size * 2 - 1;
          grid[y * size + x] =
              DemPyramid.quantise(fn(directionOf(face, s, t)), minE, maxE);
        }
      }
      faces.add(grid);
    }
    levels.add(faces);
  }
  return DemPyramid(
    radiusM: _moonRadius,
    faceSize: faceSize,
    minElevM: minE,
    maxElevM: maxE,
    levels: levels,
  );
}

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

void main() {
  group('quantisation', () {
    test('round-trips within a step', () {
      const minE = -9000.0, maxE = 11000.0;
      final step = (maxE - minE) / 65535;
      for (var v = minE; v <= maxE; v += 137.0) {
        final q = DemPyramid.quantise(v, minE, maxE);
        expect(q, inInclusiveRange(-32768, 32767));
        final back = minE + (q + 32768) / 65535.0 * (maxE - minE);
        expect(back, closeTo(v, step));
      }
    });

    test('int16 is fine enough to be invisible', () {
      // The Moon's ~20 km range across int16 is sub-metre per step, well below
      // anything the mesher can resolve — the reason float32 is not shipped.
      final step = (10757.0 - -9114.5) / 65535;
      expect(step, lessThan(0.5));
    });

    test('clamps out-of-range input instead of wrapping', () {
      expect(DemPyramid.quantise(1e9, -100, 100), 32767);
      expect(DemPyramid.quantise(-1e9, -100, 100), -32768);
    });
  });

  group('sampling', () {
    final dem = synthetic();

    test('reproduces the analytic field it was built from', () {
      for (final d in sphereDirections(500)) {
        expect(dem.elevationAt(d), closeTo(4000.0 * d.z, 120),
            reason: 'at $d');
      }
    });

    test('is continuous across cube seams', () {
      // Faces are sampled independently and clamp at their edges, so a seam is
      // where a bug would show as a visible ridge.
      for (var a = 0.0; a < 2 * math.pi; a += 0.02) {
        // Walk the +X/+Y seam.
        final d1 = Vector3(1, 0.999, math.sin(a)).normalized;
        final d2 = Vector3(0.999, 1, math.sin(a)).normalized;
        expect((dem.elevationAt(d1) - dem.elevationAt(d2)).abs(),
            lessThan(200));
      }
    });

    test('coarser levels agree with finer ones on a smooth field', () {
      for (final d in sphereDirections(200)) {
        final fine = dem.elevationAt(d, level: 0);
        final coarse = dem.elevationAt(d, level: 3);
        expect(coarse, closeTo(fine, 400), reason: 'level mismatch at $d');
      }
    });

    test('clamps an out-of-range level instead of throwing', () {
      final d = Vector3.unitZ;
      expect(dem.elevationAt(d, level: 99), dem.elevationAt(d, level: 3));
      expect(dem.elevationAt(d, level: -5), dem.elevationAt(d, level: 0));
    });

    test('localRelief is near zero on a flat field and large on a rough one',
        () {
      final flat = synthetic(f: (d) => 0.0);
      final rough = synthetic(f: (d) => 4000.0 * math.sin(d.x * 40));
      final probe = const Vector3(0.4, 0.5, 0.77).normalized;
      expect(flat.localReliefAt(probe), lessThan(1.0));
      expect(rough.localReliefAt(probe), greaterThan(flat.localReliefAt(probe)));
    });
  });

  group('encode / decode', () {
    test('round-trips exactly', () {
      final a = synthetic(faceSize: 32, levelCount: 3);
      final b = DemPyramid.decode(a.encode());
      expect(b.radiusM, a.radiusM);
      expect(b.faceSize, a.faceSize);
      expect(b.levelCount, a.levelCount);
      expect(b.minElevM, a.minElevM);
      expect(b.maxElevM, a.maxElevM);
      for (final d in sphereDirections(300)) {
        expect(b.elevationAt(d), a.elevationAt(d));
      }
    });

    test('rejects a corrupt header rather than moving the ground silently', () {
      final bytes = synthetic(faceSize: 16, levelCount: 2).encode();
      final bad = Uint8List.fromList(bytes)..[0] = 0;
      expect(() => DemPyramid.decode(bad), throwsFormatException);
      expect(() => DemPyramid.decode(Uint8List(4)), throwsFormatException);
    });
  });

  group('DemDerivedControl', () {
    test('reports relief and roughness from the data, not from noise', () {
      final flat = DemDerivedControl(synthetic(f: (d) => 0.0));
      final rough =
          DemDerivedControl(synthetic(f: (d) => 4000.0 * math.sin(d.x * 40)));
      final probe = const Vector3(0.4, 0.5, 0.77).normalized;
      expect(flat.reliefAt(probe), lessThan(1.0));
      expect(flat.roughnessAt(probe), lessThan(0.01));
      expect(rough.reliefAt(probe), greaterThan(flat.reliefAt(probe)));
      expect(rough.roughnessAt(probe), greaterThan(flat.roughnessAt(probe)));
    });

    test('keeps the detail layer a minority contributor', () {
      // The DEM owns everything above its Nyquist; the procedural layer only
      // fills below it. If detail relief approached the real relief it would
      // drown the actual landforms.
      final dem = synthetic(f: (d) => 4000.0 * math.sin(d.x * 20));
      final control = DemDerivedControl(dem, detailFraction: 0.35);
      for (final d in sphereDirections(200)) {
        expect(control.reliefAt(d),
            lessThanOrEqualTo(dem.localReliefAt(d, level: 2) * 0.351));
      }
    });

    test('channels stay in range', () {
      final dem = synthetic(f: (d) => 4000.0 * math.sin(d.x * 20));
      final control = DemDerivedControl(dem);
      for (final d in sphereDirections(300)) {
        expect(control.roughnessAt(d), inInclusiveRange(0.0, 1.0));
        expect(control.ridgednessAt(d), inInclusiveRange(0.0, 1.0));
        expect(control.lineationAt(d), Vector3.zero);
      }
    });
  });

  group('the baked lunar pyramid', () {
    final file = File('assets/terrain/moon.acrodem');

    test('matches published lunar elevations', () {
      if (!file.existsSync()) {
        markTestSkipped('run tool/bake_dem.dart to produce moon.acrodem');
        return;
      }
      final dem = DemPyramid.decode(file.readAsBytesSync());
      expect(dem.radiusM, 1737400);

      Vector3 at(double latDeg, double lonDeg) {
        final lat = latDeg * math.pi / 180, lon = lonDeg * math.pi / 180;
        return Vector3(math.cos(lat) * math.cos(lon),
            math.cos(lat) * math.sin(lon), math.sin(lat));
      }

      // Against published figures, with slack for the ~2.6 km/px bake.
      expect(dem.elevationAt(at(0.67, 23.47)), closeTo(-1900, 400),
          reason: 'Apollo 11 / Mare Tranquillitatis');
      expect(dem.elevationAt(at(33, -16)), closeTo(-2400, 600),
          reason: 'Mare Imbrium');
      expect(dem.elevationAt(at(-53, -169)), closeTo(-7100, 800),
          reason: 'South Pole-Aitken');

      // The real lunar range, which no procedural field would land on.
      expect(dem.minElevM, closeTo(-9100, 300));
      expect(dem.maxElevM, closeTo(10760, 300));
    });

    test('stays small enough to keep resident for collision', () {
      if (!file.existsSync()) {
        markTestSkipped('run tool/bake_dem.dart to produce moon.acrodem');
        return;
      }
      // Physics samples this from the deterministic tick, so it has to be fully
      // in memory on both server and client — no streaming, no async.
      expect(file.lengthSync(), lessThan(16 * 1024 * 1024));
    });
  });
}
