// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_curves.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shapes the road tool lays: straight, pulled through a control point,
/// and carried on from the last stretch's heading.
void main() {
  void near(Vec2 a, Vec2 b, [double tol = 1e-6]) {
    expect(a.distanceTo(b), lessThan(tol), reason: '$a vs $b');
  }

  test('a straight road is its two ends', () {
    expect(RoadCurves.straight(const Vec2(0, 0), const Vec2(10, 0)),
        [const Vec2(0, 0), const Vec2(10, 0)]);
  });

  group('the curved mode', () {
    test('starts and ends where clicked, and bends toward the control', () {
      const a = Vec2(0, 0), c = Vec2(0, 100), b = Vec2(100, 100);
      final pts = RoadCurves.quadratic(a, c, b);
      near(pts.first, a);
      near(pts.last, b);
      // The Bézier's midpoint is (a + 2c + b) / 4.
      final mid = pts[pts.length ~/ 2];
      near(mid, const Vec2(25, 75), 3);
      // It leaves heading for the control and arrives from it.
      near(RoadCurves.startTangent(pts), const Vec2(0, 1), 0.05);
      near(RoadCurves.endTangent(pts), const Vec2(1, 0), 0.05);
    });

    test('is laid out a few metres apart', () {
      final pts = RoadCurves.quadratic(
          const Vec2(0, 0), const Vec2(0, 200), const Vec2(200, 200));
      for (var i = 1; i < pts.length; i++) {
        expect(pts[i].distanceTo(pts[i - 1]),
            lessThanOrEqualTo(RoadCurves.sampleStepM * 1.5));
      }
    });
  });

  group('the freeform mode', () {
    test('runs straight when the end is dead ahead', () {
      final pts = RoadCurves.tangentArc(
          const Vec2(0, 0), const Vec2(0, 1), const Vec2(0, 50));
      expect(pts, hasLength(2));
    });

    test('carries on from the heading along one circle', () {
      // North out of the origin, ending north-east: a quarter circle about
      // (100, 0).
      final pts = RoadCurves.tangentArc(
          const Vec2(0, 0), const Vec2(0, 1), const Vec2(100, 100));
      near(pts.first, const Vec2(0, 0));
      near(pts.last, const Vec2(100, 100));
      for (final p in pts) {
        expect(p.distanceTo(const Vec2(100, 0)), closeTo(100, 1e-6));
      }
      near(RoadCurves.startTangent(pts), const Vec2(0, 1), 0.05);
      near(RoadCurves.endTangent(pts), const Vec2(1, 0), 0.05);
      expect(RoadCurves.minRadius(pts), closeTo(100, 1));
    });

    test('turns either way', () {
      final left = RoadCurves.tangentArc(
          const Vec2(0, 0), const Vec2(0, 1), const Vec2(-100, 100));
      for (final p in left) {
        expect(p.distanceTo(const Vec2(-100, 0)), closeTo(100, 1e-6));
      }
    });

    test('never loops round behind its own start', () {
      // The end is behind: an arc would turn past 180 degrees.
      final pts = RoadCurves.tangentArc(
          const Vec2(0, 0), const Vec2(0, 1), const Vec2(20, -80));
      near(pts.first, const Vec2(0, 0));
      near(pts.last, const Vec2(20, -80));
      // A curve pulled along the tangent: it still leaves heading north.
      near(RoadCurves.startTangent(pts), const Vec2(0, 1), 0.2);
    });
  });

  test('a straight line has no radius to speak of', () {
    expect(
        RoadCurves.minRadius(
            const [Vec2(0, 0), Vec2(0, 10), Vec2(0, 20), Vec2(0, 30)]),
        double.infinity);
    expect(RoadCurves.length(const [Vec2(0, 0), Vec2(3, 4)]), 5);
    expect(math.pi, isNotNull);
  });
}
