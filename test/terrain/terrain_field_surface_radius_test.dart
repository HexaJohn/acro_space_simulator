// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

/// `surfaceRadiusAt` is the cheap per-frame ground query a vehicle stands
/// on. What is pinned: it answers the SAME radius as the marching
/// `groundRadiusAt` across plain relief, a crater (bowl and rim) and a
/// levelling pad — and it is cheaper, which is its whole reason to exist.
void main() {
  const r = 1.7374e6;
  final dir = const Vector3(0.3, 0.4, 0.87).normalized;
  final east = Vector3.unitZ.cross(dir).normalized;
  final north = dir.cross(east);
  final base = TerrainField(
    radius: r,
    amplitude: 4000,
    featureScale: 60000,
    seed: 0x11A00,
  );
  Vector3 onGround(Vector3 d) => d * base.groundRadiusAt(d.x, d.y, d.z);

  final crater = TerrainBrush.crater(
    contactBF: onGround(dir),
    normalBF: dir,
    radiusM: 220,
    depthM: 60,
    rimHeightM: 15,
  );
  final padDir = (dir + east * (900 / r)).normalized;
  final padCentre = onGround(padDir);
  final pad = TerrainBrush.pad(
    centreBF: padCentre,
    radiusM: 120,
    datumRadiusM: padCentre.length + 8,
  );
  final field = TerrainField(
    radius: r,
    amplitude: 4000,
    featureScale: 60000,
    seed: 0x11A00,
    edits: TerrainEdits.of([crater, pad]),
  );

  Vector3 at(double eastM, double northM) =>
      (dir + east * (eastM / r) + north * (northM / r)).normalized;

  test('agrees with the marching query across relief, crater and pad', () {
    var worst = 0.0;
    var checked = 0;
    for (var i = -40; i <= 40; i++) {
      for (var j = -3; j <= 3; j++) {
        final d = at(i * 30.0, j * 40.0);
        final fast = field.surfaceRadiusAt(d.x, d.y, d.z);
        final slow = field.groundRadiusAt(d.x, d.y, d.z);
        worst = math.max(worst, (fast - slow).abs());
        checked++;
      }
    }
    expect(checked, greaterThan(500));
    expect(worst, lessThan(5e-3),
        reason: 'the two queries disagree by $worst m somewhere');
  });

  test('the pad reads at its datum and the bowl below the base', () {
    final p = field.surfaceRadiusAt(padDir.x, padDir.y, padDir.z);
    expect(p, closeTo(padCentre.length + 8, 5e-3));
    final c = field.surfaceRadiusAt(dir.x, dir.y, dir.z);
    expect(c, lessThan(base.groundRadiusAt(dir.x, dir.y, dir.z) - 40));
    // Off every brush it is the base relief, exactly.
    final far = at(0, -3000);
    expect(field.surfaceRadiusAt(far.x, far.y, far.z),
        base.groundRadiusAt(far.x, far.y, far.z));
  });

  test('costs less than the march where brushes cover the ray', () {
    final ds = [for (var i = -20; i <= 20; i++) at(i * 12.0, 5.0)];
    final sw = Stopwatch()..start();
    for (var k = 0; k < 5; k++) {
      for (final d in ds) {
        field.surfaceRadiusAt(d.x, d.y, d.z);
      }
    }
    final fast = sw.elapsedMicroseconds;
    sw.reset();
    for (var k = 0; k < 5; k++) {
      for (final d in ds) {
        field.groundRadiusAt(d.x, d.y, d.z);
      }
    }
    final slow = sw.elapsedMicroseconds;
    expect(fast, lessThan(slow),
        reason: 'fast ${fast}us vs march ${slow}us over ${ds.length * 5} samples');
  });
}
