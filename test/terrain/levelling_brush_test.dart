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

  test('a corridor levelled in plan grades the MIDDLE of a steep run, '
      'where the same corridor projected in 3-D leaves the hillside standing',
      () {
    // A site's access corridor: 56 m along, 80 m down into the platform its
    // drive leaves — the case `TerrainBrush.planLevel` exists for
    // (docs/plans/site-access.md §6.3). The middle of it is a 43 m cut.
    final a = dirAt(0), b = dirAt(56);
    TerrainBrush corridor({required bool planLevel}) => TerrainBrush.cutFill(
          startBF: a * bodyR,
          endBF: b * (bodyR - 80),
          radiusM: 4.5,
          datumRadiusM: bodyR,
          datumRadiusEndM: bodyR - 80,
          falloffM: 4.5,
          maxCutM: 160,
          planLevel: planLevel,
        );

    /// The composed field at [east] metres along, [r] from the centre.
    double density(double east, double r, TerrainBrush brush) {
      final p = dirAt(east) * r;
      return brush.apply(baseDensity(p), p);
    }

    // In plan, every point of the run stands on the straight grade between
    // its two datums — which is what the renderer draws it on
    // (`SiteCorridorRun.radiusAt`).
    final plan = corridor(planLevel: true);
    for (final (east, want) in [
      (0.0, bodyR),
      (14.0, bodyR - 20),
      (28.0, bodyR - 40),
      (42.0, bodyR - 60),
      (56.0, bodyR - 80),
    ]) {
      expect(surfaceRadius(dirAt(east), [plan]), closeTo(want, 0.05),
          reason: 'the grade is wrong ${east}m along');
      // And the hillside above the grade is gone: air, not rock.
      expect(density(east, naturalGround(dirAt(east)), plan),
          greaterThan(want == bodyR ? -0.01 : 20),
          reason: 'the ground above the grade is still solid ${east}m along');
    }

    // Projected in three dimensions the same corridor cuts only its ends: a
    // sample offset radially from a chord that steep maps to a far-off place
    // along it, where the lateral test then rejects it, and the field keeps
    // its natural value — the hillside standing through the middle of the
    // drive, which the outermost-crossing ground query then reports as the
    // ground (`TerrainField.groundRadiusAt`) and the mesher meshes.
    final flat = corridor(planLevel: false);
    for (final east in [14.0, 28.0, 42.0]) {
      expect(density(east, naturalGround(dirAt(east)), flat).abs(),
          lessThan(1e-9),
          reason: 'the 3-D projection is what the plan rule is measured '
              'against: it moved the ground ${east}m along after all');
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
