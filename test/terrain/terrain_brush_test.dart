// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:flutter_test/flutter_test.dart';

/// The brushes are tested against a flat half-space rather than a real terrain
/// field: density is the signed height above the contact plane, which is
/// exactly what the real field looks like locally at the scale of a crater.
/// That makes every dimension in the assertions an exact expected value.
void main() {
  const contact = Vector3(1000, 0, 0);
  const normal = Vector3(1, 0, 0);
  const tangent = Vector3(0, 1, 0);

  /// Signed height of [p] above the contact plane (negative = below = solid).
  double plane(Vector3 p) => (p - contact).dot(normal);

  /// Composed density of [brush] over the half-space at [p].
  double at(TerrainBrush brush, Vector3 p) => brush.apply(plane(p), p);

  /// Height above the contact plane where the composed surface sits, along the
  /// vertical through [lateral] metres out from the axis.
  double surfaceHeight(TerrainBrush brush, double lateral, {double from = 400}) {
    final base = contact + tangent * lateral;
    var air = from, solid = -from;
    for (var i = 0; i < 60; i++) {
      final mid = (air + solid) * 0.5;
      if (at(brush, base + normal * mid) <= 0) {
        solid = mid;
      } else {
        air = mid;
      }
    }
    return (air + solid) * 0.5;
  }

  group('sphere brush', () {
    final brush =
        TerrainBrush.sphere(centreBF: contact, radiusM: 10, tick: 3);

    test('carves air at its centre', () {
      expect(at(brush, contact), greaterThan(0));
      // A point well inside solid rock but inside the ball is air too.
      expect(at(brush, contact - normal * 5), greaterThan(0));
    });

    test('leaves rock outside the ball solid', () {
      expect(at(brush, contact - normal * 30), lessThan(0));
    });

    test('is exactly the identity outside its bounding radius', () {
      final far = contact - normal * (brush.boundingRadiusM + 1);
      expect(at(brush, far), plane(far));
      final side = contact + tangent * (brush.boundingRadiusM + 1);
      expect(at(brush, side), plane(side));
    });
  });

  group('crater brush', () {
    const radius = 50.0, depth = 20.0, rim = 4.0;
    final brush = TerrainBrush.crater(
      contactBF: contact,
      normalBF: normal,
      radiusM: radius,
      depthM: depth,
      rimHeightM: rim,
    );

    test('bowl geometry solves to the requested depth and mouth', () {
      // rs - h0 == depth is the defining constraint of the solved bowl.
      expect(brush.bowlRadiusM - brush.bowlOffsetM, closeTo(depth, 1e-9));
      // The cavity opens inside the crest so the subtraction cannot eat it.
      final mouth = math.sqrt(brush.bowlRadiusM * brush.bowlRadiusM -
          brush.bowlOffsetM * brush.bowlOffsetM);
      expect(mouth, lessThan(radius));
    });

    test('floor sits one depth below the contact plane', () {
      expect(surfaceHeight(brush, 0), closeTo(-depth, 0.01));
    });

    test('rim crest stands proud of the surrounding surface', () {
      // Regression: with the bowl mouth at the crest radius the subtraction
      // swallowed the rim and the crater came out as a lipless divot.
      expect(surfaceHeight(brush, radius), greaterThan(rim * 0.5));
    });

    test('relief returns to the plane well outside the rim', () {
      expect(surfaceHeight(brush, radius * 3), closeTo(0, 0.01));
    });

    test('profile descends monotonically from the crest to the floor', () {
      var previous = surfaceHeight(brush, radius);
      for (final f in [0.8, 0.6, 0.4, 0.2, 0.0]) {
        final h = surfaceHeight(brush, radius * f);
        expect(h, lessThan(previous + 1e-6),
            reason: 'lateral ${radius * f} rose above the ring outside it');
        previous = h;
      }
    });

    test('is exactly the identity outside its bounding radius', () {
      for (final dir in [normal, -normal, tangent, Vector3(0, 0, 1)]) {
        final p = contact + dir * (brush.boundingRadiusM + 0.5);
        expect(at(brush, p), plane(p), reason: 'leaked along $dir');
      }
    });

    test('never flips the sign of deep rock or high air', () {
      // The bounding cutoff is only safe because it is buried in unambiguous
      // material. Sweep the shell just inside it and check nothing crosses.
      final r = brush.boundingRadiusM * 0.999;
      for (var i = 0; i < 64; i++) {
        final a = 2 * math.pi * i / 64;
        final p = contact + normal * (r * math.cos(a)) + tangent * (r * math.sin(a));
        final before = plane(p), after = at(brush, p);
        if (before.abs() < 1e-9) continue;
        expect(before.sign, after.sign,
            reason: 'sign flipped at the cutoff for $p');
      }
    });
  });

  test('a rimless crater is a plain bowl', () {
    final brush = TerrainBrush.crater(
      contactBF: contact,
      normalBF: normal,
      radiusM: 30,
      depthM: 12,
    );
    expect(surfaceHeight(brush, 0), closeTo(-12, 0.01));
    expect(surfaceHeight(brush, 60), closeTo(0, 0.01));
  });

  test('axis need not be unit length', () {
    final a = TerrainBrush.crater(
      contactBF: contact,
      normalBF: normal,
      radiusM: 40,
      depthM: 15,
      rimHeightM: 3,
    );
    final b = TerrainBrush.crater(
      contactBF: contact,
      normalBF: normal * 7.5,
      radiusM: 40,
      depthM: 15,
      rimHeightM: 3,
    );
    expect(surfaceHeight(b, 0), closeTo(surfaceHeight(a, 0), 1e-9));
    expect(surfaceHeight(b, 40), closeTo(surfaceHeight(a, 40), 1e-9));
  });
}
