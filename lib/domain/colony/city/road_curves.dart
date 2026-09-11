// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The shapes the road tool draws.
///
/// A city builder's road tool has three ways to lay a road: STRAIGHT (a
/// start and an end), CURVED (a start, a point the curve is pulled toward,
/// an end) and FREEFORM (each new stretch leaves the last one on its own
/// heading, so a chain of clicks lays one smooth road). All three come out
/// of here as a dense polyline — a point every few metres — which is what
/// `CityLayout.commitRoad` takes as controls: it resamples at 2 m and thins
/// the result back to the fewest controls that keep the shape (a straight
/// road comes back as its two ends), so the shape committed is the shape
/// drawn.
library;

import 'dart:math' as math;

import 'parcel.dart';

class RoadCurves {
  const RoadCurves._();

  /// Spacing of the points a curve is laid out with.
  static const double sampleStepM = 4;

  /// Furthest one freeform arc may turn. Past this the arc would loop
  /// round behind its own start; a curve pulled along the tangent reads as
  /// what the player meant instead.
  static const double maxArcTurnRad = 2 * math.pi / 3;

  /// A straight road from [a] to [b].
  static List<Vec2> straight(Vec2 a, Vec2 b) => [a, b];

  /// A curve from [a] to [b] pulled toward [control] — the Curved mode's
  /// second click. A quadratic Bézier: it leaves [a] heading for [control]
  /// and arrives at [b] from it, which is exactly the "point used as a
  /// tangent" the tool describes.
  static List<Vec2> quadratic(Vec2 a, Vec2 control, Vec2 b,
      {double stepM = sampleStepM}) {
    // The curve is no longer than its control polygon and no shorter than
    // its chord; the mean is close enough to space the points by.
    final approx =
        (a.distanceTo(control) + control.distanceTo(b) + a.distanceTo(b)) / 2;
    final n = math.max(2, (approx / stepM).ceil());
    return [
      for (var i = 0; i <= n; i++) _quad(a, control, b, i / n),
    ];
  }

  /// The arc that leaves [a] heading along [tangent] and ends at [b] — the
  /// Freeform mode: each stretch carries on from the heading the last one
  /// ended on, so a chain of clicks is one smooth road.
  ///
  /// Straight when [b] lies dead ahead. A circle is fixed by a point, the
  /// tangent there and a second point, so there is exactly one such arc;
  /// when it would turn further than [maxTurnRad] it is replaced by a
  /// curve pulled along the tangent.
  static List<Vec2> tangentArc(Vec2 a, Vec2 tangent, Vec2 b,
      {double stepM = sampleStepM, double maxTurnRad = maxArcTurnRad}) {
    final t = tangent.normalized;
    final d = b - a;
    final len = d.length;
    if (len < 1e-6 || t.length < 1e-9) return [a, b];
    final cross = t.cross(d);
    final along = t.dot(d);
    if (cross.abs() <= len * 1e-3 && along > 0) return [a, b];
    // The chord makes angle alpha with the tangent; the arc turns 2*alpha
    // (the tangent-chord angle is half the arc).
    final alpha = math.atan2(cross.abs(), along);
    final turn = 2 * alpha;
    if (turn > maxTurnRad) {
      return quadratic(a, a + t * (len / 2), b, stepM: stepM);
    }
    // Centre on the side [b] lies, at the radius that puts [b] on it:
    // |d - r n|^2 = r^2  =>  r = |d|^2 / (2 n.d).
    final nrm = cross > 0 ? t.perp : t.perp * -1.0;
    final r = len * len / (2 * nrm.dot(d));
    final c = a + nrm * r;
    final sign = cross > 0 ? 1.0 : -1.0;
    final n = math.max(2, (r * turn / stepM).ceil());
    final from = a - c;
    return [
      for (var i = 0; i <= n; i++)
        i == 0
            ? a
            : i == n
                ? b
                : c + _rotate(from, sign * turn * i / n),
    ];
  }

  /// Direction of travel leaving the last point of [pts].
  static Vec2 endTangent(List<Vec2> pts) {
    for (var i = pts.length - 1; i > 0; i--) {
      final d = pts[i] - pts[i - 1];
      if (d.length > 1e-6) return d.normalized;
    }
    return const Vec2(0, 1);
  }

  /// Direction of travel leaving the first point of [pts].
  static Vec2 startTangent(List<Vec2> pts) {
    for (var i = 1; i < pts.length; i++) {
      final d = pts[i] - pts[i - 1];
      if (d.length > 1e-6) return d.normalized;
    }
    return const Vec2(0, 1);
  }

  /// Length of the polyline [pts].
  static double length(List<Vec2> pts) {
    var sum = 0.0;
    for (var i = 1; i < pts.length; i++) {
      sum += pts[i].distanceTo(pts[i - 1]);
    }
    return sum;
  }

  /// The tightest radius [pts] turns through, from the circle through each
  /// run of three points; infinite for a straight line.
  static double minRadius(List<Vec2> pts) {
    var best = double.infinity;
    for (var i = 1; i + 1 < pts.length; i++) {
      final a = pts[i - 1], b = pts[i], c = pts[i + 1];
      final ab = a.distanceTo(b), bc = b.distanceTo(c), ca = c.distanceTo(a);
      final area2 = (b - a).cross(c - a).abs();
      if (area2 < 1e-9) continue;
      final r = ab * bc * ca / (2 * area2);
      if (r < best) best = r;
    }
    return best;
  }

  static Vec2 _quad(Vec2 a, Vec2 c, Vec2 b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  static Vec2 _rotate(Vec2 v, double ang) {
    final cs = math.cos(ang), sn = math.sin(ang);
    return Vec2(v.e * cs - v.n * sn, v.e * sn + v.n * cs);
  }
}
