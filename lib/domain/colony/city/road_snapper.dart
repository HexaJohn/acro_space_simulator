// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a click on the ground lands when the road tool is held.
///
/// A city builder's road tool pulls the cursor onto the things a road
/// should line up with: other roads (their ends first, then anywhere along
/// them), round angles, the zoning grid, and guidelines — the lines that
/// carry an existing road on past its end or cross it square. Each can be
/// switched off from the snapping menu ([RoadSnapOptions]); the answer says
/// what it snapped to, so the tool can join the road it landed on and the
/// renderer can draw the guideline it followed.
///
/// Pure: a layout and a point in, a point out, in colony-local metres.
library;

import 'dart:math' as math;

import 'city_layout.dart';
import 'parcel.dart';
import 'spatial_index.dart';

/// The snapping menu.
class RoadSnapOptions {
  const RoadSnapOptions({
    this.roads = true,
    this.angles = true,
    this.zoningGrid = true,
    this.guidelines = true,
  });

  /// Onto other roads: their ends, then anywhere along them.
  final bool roads;

  /// The heading onto round angles (15 degree steps) from the road it
  /// leaves.
  final bool angles;

  /// Lengths that cut into whole lots, and parallel roads a whole block
  /// apart.
  final bool zoningGrid;

  /// Onto the lines that carry a road on past its end, or cross it square.
  final bool guidelines;

  static const RoadSnapOptions off = RoadSnapOptions(
      roads: false, angles: false, zoningGrid: false, guidelines: false);

  RoadSnapOptions copyWith({
    bool? roads,
    bool? angles,
    bool? zoningGrid,
    bool? guidelines,
  }) =>
      RoadSnapOptions(
        roads: roads ?? this.roads,
        angles: angles ?? this.angles,
        zoningGrid: zoningGrid ?? this.zoningGrid,
        guidelines: guidelines ?? this.guidelines,
      );
}

/// What a point snapped to.
enum RoadSnapKind {
  /// Nothing: the cursor as it was.
  free,

  /// The end of an existing road.
  roadEnd,

  /// A point along an existing road — where the new road will cut it.
  roadPoint,

  /// A guideline (a road carried on, or crossed square, or a block's
  /// width from a road).
  guideline,

  /// Where two guidelines cross.
  guidelineCross,

  /// A round angle (and, with the zoning grid, a whole-lot length).
  angle,

  /// A whole-lot length at the heading drawn.
  grid,
}

/// Where a point landed.
class RoadSnap {
  const RoadSnap(
    this.point,
    this.kind, {
    this.roadId,
    this.roadEndIsStart,
    this.roadS,
    this.roadTangent,
    this.guides = const [],
    this.angleRad,
    this.lengthM,
  });

  final Vec2 point;
  final RoadSnapKind kind;

  /// The road snapped onto ([RoadSnapKind.roadEnd], [RoadSnapKind.roadPoint]).
  final String? roadId;

  /// For a road end: whether it is that road's FIRST point.
  final bool? roadEndIsStart;

  /// Arc length along that road, metres from its first point.
  final double? roadS;

  /// That road's direction there, first point toward last (unit).
  final Vec2? roadTangent;

  /// Lines to draw while this snap holds: the guideline(s) followed, or the
  /// angle's ray. Each is a polyline, colony-local.
  final List<List<Vec2>> guides;

  /// The snapped angle from the reference heading, radians (angle snaps).
  final double? angleRad;

  /// The length from the start point (angle/grid snaps).
  final double? lengthM;

  bool get onRoad =>
      kind == RoadSnapKind.roadEnd || kind == RoadSnapKind.roadPoint;
}

/// A guideline: a segment [o] + [d] t for t in [t0, t1].
class _Guide {
  const _Guide(this.o, this.d, this.t0, this.t1);
  final Vec2 o, d;
  final double t0, t1;

  (Vec2, double, double) project(Vec2 p) {
    final t = (p - o).dot(d).clamp(t0, t1);
    final q = o + d * t;
    return (q, p.distanceTo(q), t);
  }
}

class RoadSnapper {
  RoadSnapper(
    this.layout, {
    this.options = const RoadSnapOptions(),
    this.frontageM = 24,
    this.cornerClearM = 12,
    this.lotDepthM = 32,
    this.sidewalkM = 3,
    this.newHalfWidthM = 4,
    this.scale = 1,
    this.passesOver,
  });

  final CityLayout layout;
  final RoadSnapOptions options;

  /// The stretches of road the point being placed passes over rather than
  /// lands on: [road] at arc [s] of its [lengthM], an END of it when
  /// [atStart] is set (true for its first). A road's tunnel, say, to an end
  /// on the ground, which can neither see it nor meet it. Null: lands on
  /// any road.
  final bool Function(RoadSpline road, double s, double lengthM, bool? atStart)?
      passesOver;

  /// The plat the zoning grid lines up with: lot frontage, the clearance
  /// kept at each end of a road, lot depth, pavement.
  final double frontageM, cornerClearM, lotDepthM, sidewalkM;

  /// Half width of the road being drawn — how far a parallel road must be
  /// for a whole block to fit between them.
  final double newHalfWidthM;

  /// Tolerance multiplier: 1 at street scale, more when the camera is far.
  final double scale;

  static const double endSnapM = 12;
  static const double roadSnapM = 9;
  static const double guideSnapM = 5;
  static const double guideReachM = 400;
  static const double angleStepRad = 15 * math.pi / 180;
  static const double angleSnapRad = 3 * math.pi / 180;

  /// Where [cursor] lands. [from] is the point the road is being drawn from
  /// (the angle and grid snaps measure from it); [fromTangent] the heading
  /// it should carry on (the last stretch's end, or the road it leaves).
  RoadSnap snap(Vec2 cursor, {Vec2? from, Vec2? fromTangent}) {
    if (options.roads) {
      final end = _nearestEnd(cursor, endSnapM * scale);
      if (end != null) return end;
      final along = _nearestAlong(cursor, roadSnapM * scale);
      if (along != null) return along;
    }

    if (options.guidelines || options.zoningGrid) {
      final g = _snapToGuides(cursor, from, fromTangent);
      if (g != null) return g;
    }

    if (from != null && (options.angles || options.zoningGrid)) {
      final d = cursor - from;
      var len = d.length;
      if (len > 1e-6) {
        var dir = d * (1 / len);
        var kind = RoadSnapKind.free;
        double? angle;
        if (options.angles) {
          final ref = fromTangent ?? _roadDirectionAt(from) ?? const Vec2(0, 1);
          final rel = _signedAngle(ref, dir);
          final snapped = (rel / angleStepRad).roundToDouble() * angleStepRad;
          if ((rel - snapped).abs() <= angleSnapRad) {
            dir = _rotate(ref.normalized, snapped);
            angle = snapped;
            kind = RoadSnapKind.angle;
          }
        }
        if (options.zoningGrid) {
          len = gridLength(len);
          if (kind == RoadSnapKind.free) kind = RoadSnapKind.grid;
        }
        if (kind != RoadSnapKind.free) {
          final p = from + dir * len;
          return RoadSnap(p, kind,
              angleRad: angle,
              lengthM: len,
              guides: kind == RoadSnapKind.angle
                  ? [
                      [from, from + dir * (len + 30)]
                    ]
                  : const []);
        }
      }
    }
    return RoadSnap(cursor, RoadSnapKind.free);
  }

  /// The nearest length to [lengthM] that cuts into whole lots: the two
  /// corner clearances plus a whole number of frontages (at least one).
  double gridLength(double lengthM) {
    final k = math.max(1, ((lengthM - 2 * cornerClearM) / frontageM).round());
    return 2 * cornerClearM + k * frontageM;
  }

  RoadSnap? _nearestEnd(Vec2 p, double withinM) {
    RoadSnap? best;
    var bestD = withinM;
    final seen = <int>{};
    layout.roadIndex.visit(Box2.around(p, withinM), 0, (slot, rec, _) {
      if (!seen.add(slot) || rec.sampleCount == 0) return;
      for (final start in const [true, false]) {
        if (passesOver?.call(
                rec.road, start ? 0 : rec.lengthM, rec.lengthM, start) ??
            false) {
          continue;
        }
        final i = start ? 0 : rec.sampleCount - 1;
        final q = rec.sampleAt(i);
        final d = p.distanceTo(q);
        if (d < bestD) {
          bestD = d;
          best = RoadSnap(q, RoadSnapKind.roadEnd,
              roadId: rec.road.id,
              roadEndIsStart: start,
              roadS: start ? 0 : rec.lengthM,
              roadTangent: _tangentAtSample(rec, i));
        }
      }
    });
    return best;
  }

  RoadSnap? _nearestAlong(Vec2 p, double withinM) {
    RoadSnap? best;
    var bestD = withinM;
    layout.roadIndex.visit(Box2.around(p, withinM), 0, (slot, rec, seg) {
      if (seg == 0) return;
      final (q, d) = rec.nearestOnSegment(p, seg);
      if (d < bestD) {
        final a = rec.sampleAt(seg - 1), b = rec.sampleAt(seg);
        final segLen = a.distanceTo(b);
        final u = segLen <= 1e-9 ? 0.0 : a.distanceTo(q) / segLen;
        final s = rec.arcAt(seg, u);
        if (passesOver?.call(rec.road, s, rec.lengthM, null) ?? false) return;
        bestD = d;
        best = RoadSnap(q, RoadSnapKind.roadPoint,
            roadId: rec.road.id, roadS: s, roadTangent: (b - a).normalized);
      }
    });
    return best;
  }

  /// Direction of the road [p] lies on (first point toward last), if any.
  Vec2? _roadDirectionAt(Vec2 p) {
    final hit = _nearestAlong(p, 1.0);
    if (hit != null) return hit.roadTangent;
    final end = _nearestEnd(p, 1.0);
    return end?.roadTangent;
  }

  static Vec2 _tangentAtSample(IndexedRoad rec, int i) {
    if (rec.sampleCount < 2) return const Vec2(0, 1);
    final a = i == 0 ? rec.sampleAt(0) : rec.sampleAt(i - 1);
    final b = i == 0 ? rec.sampleAt(1) : rec.sampleAt(i);
    return (b - a).normalized;
  }

  RoadSnap? _snapToGuides(Vec2 cursor, Vec2? from, Vec2? fromTangent) {
    final guides = _guidesNear(cursor, from, fromTangent);
    if (guides.isEmpty) return null;
    final tol = guideSnapM * scale;
    _Guide? first;
    var firstD = tol;
    Vec2? firstQ;
    for (final g in guides) {
      final (q, d, _) = g.project(cursor);
      if (d < firstD) {
        firstD = d;
        first = g;
        firstQ = q;
      }
    }
    if (first == null) return null;
    // A second guideline, crossing the first, near enough to meet at.
    for (final g in guides) {
      if (identical(g, first)) continue;
      if (first.d.cross(g.d).abs() < math.sin(10 * math.pi / 180)) continue;
      final x = _intersect(first, g);
      if (x == null || x.distanceTo(cursor) > tol * 1.5) continue;
      return RoadSnap(x, RoadSnapKind.guidelineCross,
          guides: [_drawn(first, x), _drawn(g, x)]);
    }
    return RoadSnap(firstQ!, RoadSnapKind.guideline,
        guides: [_drawn(first, firstQ)]);
  }

  /// The guideline from its origin to just past [at], for drawing.
  static List<Vec2> _drawn(_Guide g, Vec2 at) {
    final t = (at - g.o).dot(g.d);
    final lo = math.min(0.0, t) - 10;
    final hi = math.max(0.0, t) + 30;
    return [g.o + g.d * lo.clamp(g.t0, g.t1), g.o + g.d * hi.clamp(g.t0, g.t1)];
  }

  List<_Guide> _guidesNear(Vec2 cursor, Vec2? from, Vec2? fromTangent) {
    final out = <_Guide>[];
    if (options.guidelines) {
      // Every road END near the cursor: the road carried on past it, and the
      // line crossing it square.
      final seen = <int>{};
      layout.roadIndex.visit(Box2.around(cursor, guideReachM), 0,
          (slot, rec, _) {
        if (!seen.add(slot) || rec.sampleCount < 2) return;
        for (final start in const [true, false]) {
          final i = start ? 0 : rec.sampleCount - 1;
          final q = rec.sampleAt(i);
          if (q.distanceTo(cursor) > guideReachM) continue;
          final along = _tangentAtSample(rec, i);
          final out0 = start ? along * -1.0 : along;
          out.add(_Guide(q, out0, 0, guideReachM));
          out.add(_Guide(q, along.perp, -guideReachM, guideReachM));
        }
      });
      if (from != null && fromTangent != null && fromTangent.length > 1e-9) {
        final t = fromTangent.normalized;
        out.add(_Guide(from, t, 0, guideReachM));
        out.add(_Guide(from, t.perp, -guideReachM, guideReachM));
      }
    }
    if (options.zoningGrid) {
      // A block's width from every straight road nearby: two rows of lots
      // back to back fit exactly between it and the new one.
      final seen = <int>{};
      layout.roadIndex.visit(Box2.around(cursor, guideReachM / 2), 0,
          (slot, rec, _) {
        if (!seen.add(slot) || rec.sampleCount < 2) return;
        if (!rec.road.platsLots) return;
        final a = rec.sampleAt(0), b = rec.sampleAt(rec.sampleCount - 1);
        final len = a.distanceTo(b);
        // Only a road that IS straight end to end has one parallel.
        if (len < 20 || (rec.lengthM - len) > 0.5) return;
        final d = (b - a) * (1 / len);
        final gap = rec.road.halfWidth +
            newHalfWidthM +
            2 * (sidewalkM + lotDepthM);
        for (final side in const [1.0, -1.0]) {
          out.add(_Guide(a + d.perp * (gap * side), d, -guideReachM / 2,
              len + guideReachM / 2));
        }
      });
    }
    return out;
  }

  static Vec2? _intersect(_Guide a, _Guide b) {
    final denom = a.d.cross(b.d);
    if (denom.abs() < 1e-9) return null;
    final w = b.o - a.o;
    final ta = w.cross(b.d) / denom;
    final tb = w.cross(a.d) / denom;
    if (ta < a.t0 - 1e-6 || ta > a.t1 + 1e-6) return null;
    if (tb < b.t0 - 1e-6 || tb > b.t1 + 1e-6) return null;
    return a.o + a.d * ta;
  }

  /// Angle from [a] to [b], counter-clockwise positive, in (-pi, pi].
  static double _signedAngle(Vec2 a, Vec2 b) =>
      math.atan2(a.cross(b), a.dot(b));

  static Vec2 _rotate(Vec2 v, double ang) {
    final cs = math.cos(ang), sn = math.sin(ang);
    return Vec2(v.e * cs - v.n * sn, v.e * sn + v.n * cs);
  }
}
