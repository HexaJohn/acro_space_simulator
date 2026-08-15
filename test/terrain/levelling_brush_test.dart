// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:flutter_test/flutter_test.dart';

/// The levelling brushes are what let a city sit on real terrain: pads flatten
/// building sites, cut/fill grades roads, and a stepped pit is a quarry.
void main() {
  const bodyR = 600000.0; // a small moon, so curvature is not negligible

  /// Natural ground: a constant slope running east, 1 m rise per 10 m.
  double naturalGround(Vector3 dir) {
    // East offset in metres at this direction, relative to +Z pole frame.
    final east = math.atan2(dir.y, dir.x) * bodyR;
    return bodyR + east * 0.1;
  }

  double baseDensity(Vector3 p) => p.length - naturalGround(p.normalized);

  /// Radius where the composed field crosses zero along [dir] — the surface.
  double surfaceRadius(Vector3 dir, List<TerrainBrush> brushes) {
    double field(double r) {
      final p = dir * r;
      var d = baseDensity(p);
      for (final b in brushes) {
        d = b.apply(d, p);
      }
      return d;
    }

    var lo = bodyR - 5000, hi = bodyR + 5000;
    for (var i = 0; i < 200; i++) {
      final mid = (lo + hi) / 2;
      if (field(mid) < 0) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  /// Direction [east] metres east of the +X point on the equator.
  Vector3 dirAt(double east) {
    final lon = east / bodyR;
    return Vector3(math.cos(lon), math.sin(lon), 0);
  }

  test('a pad levels a slope flat, and eases back to natural ground', () {
    final centre = dirAt(0) * naturalGround(dirAt(0));
    final pad = TerrainBrush.pad(
      centreBF: centre,
      radiusM: 100,
      datumRadiusM: bodyR,
      falloffM: 40,
      maxCutM: 200,
    );

    // Across the pad the surface is FLAT at the datum, though the natural
    // ground rises 20 m over the same span.
    for (final east in [-90.0, -40.0, 0.0, 40.0, 90.0]) {
      expect(surfaceRadius(dirAt(east), [pad]), closeTo(bodyR, 0.5),
          reason: 'pad interior should be level at ${east}m east');
    }
    // Both cut (uphill) and fill (downhill) happened.
    expect(naturalGround(dirAt(90)), greaterThan(bodyR + 5));
    expect(naturalGround(dirAt(-90)), lessThan(bodyR - 5));

    // Well outside the falloff the ground is untouched.
    for (final east in [-400.0, 400.0]) {
      expect(surfaceRadius(dirAt(east), [pad]),
          closeTo(naturalGround(dirAt(east)), 0.5));
    }
  });

  test('the pad edge is a smooth ramp, not a cliff', () {
    final centre = dirAt(0) * naturalGround(dirAt(0));
    final pad = TerrainBrush.pad(
      centreBF: centre,
      radiusM: 100,
      datumRadiusM: bodyR,
      falloffM: 50,
      maxCutM: 200,
    );

    // Walk out through the falloff; no single metre may drop more than the
    // natural slope plus a modest grading allowance.
    var prev = surfaceRadius(dirAt(100), [pad]);
    for (var east = 101.0; east <= 150; east += 1) {
      final r = surfaceRadius(dirAt(east), [pad]);
      expect((r - prev).abs(), lessThan(1.0),
          reason: 'step at ${east}m east is a cliff');
      prev = r;
    }
  });

  test('a stepped pit digs benches down to its floor', () {
    final centre = dirAt(0) * naturalGround(dirAt(0));
    final pit = TerrainBrush.steppedPit(
      centreBF: centre,
      radiusM: 400,
      datumRadiusM: bodyR,
      depthM: 200,
      benches: 4,
      falloffM: 40,
    );

    final floor = surfaceRadius(dirAt(0), [pit]);
    expect(floor, closeTo(bodyR - 200, 1), reason: 'centre is the pit floor');

    // Sampling outward, the surface only ever rises — a terraced wall.
    var prev = floor;
    for (var east = 20.0; east <= 400; east += 20) {
      final r = surfaceRadius(dirAt(east), [pit]);
      expect(r, greaterThanOrEqualTo(prev - 0.5),
          reason: 'benches must step up toward the rim');
      prev = r;
    }
    // And it is genuinely stepped: distinct bench levels, not a smooth cone.
    final levels = <double>{};
    for (var east = 10.0; east < 400; east += 10) {
      levels.add(((surfaceRadius(dirAt(east), [pit]) - bodyR) / 10).round() * 10);
    }
    expect(levels.length, greaterThanOrEqualTo(3));
    expect(levels.length, lessThanOrEqualTo(6));
  });

  test('a cut/fill corridor holds a constant grade between its ends', () {
    final a = dirAt(-500);
    final b = dirAt(500);
    final road = TerrainBrush.cutFill(
      startBF: a * naturalGround(a),
      endBF: b * naturalGround(b),
      radiusM: 8,
      datumRadiusM: bodyR - 20,
      datumRadiusEndM: bodyR + 20,
      falloffM: 6,
      maxCutM: 120,
    );

    // The carriageway runs straight from one datum to the other.
    for (final (east, want) in [
      (-500.0, bodyR - 20),
      (0.0, bodyR),
      (250.0, bodyR + 10),
      (500.0, bodyR + 20),
    ]) {
      expect(surfaceRadius(dirAt(east), [road]), closeTo(want, 1.5),
          reason: 'grade wrong at ${east}m east');
    }
  });

  test('a levelling brush leaves the field untouched outside its bound', () {
    final centre = dirAt(0) * naturalGround(dirAt(0));
    final pad = TerrainBrush.pad(
      centreBF: centre,
      radiusM: 100,
      datumRadiusM: bodyR,
      falloffM: 40,
    );
    final far = dirAt(5000) * bodyR;
    expect(pad.affects(far), isFalse);
    expect(pad.apply(123.0, far), 123.0);
  });
}
