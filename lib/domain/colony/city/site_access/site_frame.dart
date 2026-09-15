// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The site frame: the one right-handed frame every site access generator
/// works in, x along the frontage and y into the lot
/// (docs/plans/site-access.md §3.1).
///
/// Nothing a lot carries is trusted as it stands. The plat's `l`-side auto
/// lots wind clockwise, the starter kit's spaceport and solar farm store their
/// frontage running backwards, grid cells front a fake north edge and hand
/// drawn sites may have no frontage at all. The frame normalises all of it:
/// a counter-clockwise copy of the polygon, a frontage direction chosen so the
/// normal agrees with the inward normal of the CCW edge under it, and an
/// effective frontage
/// wherever the stored one is missing or off the polygon.
///
/// Determinism (§3.9): no platform hash, no draw from a generator, no clock, no
/// map iteration and no trigonometry in generation. Every tie is broken by an
/// explicit total order. The headings are derived for placement only.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import '../spatial_index.dart';
import 'site_access_constants.dart';

/// The road index a site frame searches: the layout's own segment index.
typedef RoadIndex = SegmentIndex;

/// Whether a road of class [c] may carry a site's kerb join (§3.2): it carries
/// cars, is at grade and not limited-access, and fronts lots (or is an alley).
bool isEligibleJoinRoad(RoadClass c) =>
    c.carriesCars &&
    !c.limitedAccess &&
    !c.isElevated &&
    (c.platsLots || c == RoadClass.alley);

/// The widest half width of any eligible class: how far past the reach a
/// query must look to be sure of every road that could qualify.
final double _maxEligibleHalfWidth = RoadClass.values
    .where(isEligibleJoinRoad)
    .fold(0.0, (m, c) => math.max(m, c.halfWidth));

/// Twice the signed area of [p]: positive when counter-clockwise.
double _twiceSignedArea(List<Vec2> p) {
  var sum = 0.0;
  for (var i = 0; i < p.length; i++) {
    sum += p[i].cross(p[(i + 1) % p.length]);
  }
  return sum;
}

/// A counter-clockwise copy of [p], rotated to start at the vertex with the
/// smallest `(e, n)`: the canonical edge numbering of §3.1's tie rule.
List<Vec2> _canonicalCcw(List<Vec2> p) {
  final ccw = _twiceSignedArea(p) < 0 ? p.reversed.toList() : List.of(p);
  var start = 0;
  for (var i = 1; i < ccw.length; i++) {
    final a = ccw[i], b = ccw[start];
    if (a.e < b.e || (a.e == b.e && a.n < b.n)) start = i;
  }
  return [for (var k = 0; k < ccw.length; k++) ccw[(start + k) % ccw.length]];
}

/// Even-odd containment of ([e], [n]) in the ring ([xs], [ys]).
bool _ringContains(List<double> xs, List<double> ys, double e, double n) {
  var inside = false;
  final count = xs.length;
  for (var i = 0, j = count - 1; i < count; j = i++) {
    final ai = ys[i] > n, aj = ys[j] > n;
    if (ai != aj &&
        e < (xs[j] - xs[i]) * (n - ys[i]) / (ys[j] - ys[i]) + xs[i]) {
      inside = !inside;
    }
  }
  return inside;
}

/// Whether segments [a]-[b] and [c]-[d] properly cross. (A road only touching
/// an edge has its nearest point on the edge line, which the outside test
/// already refuses.)
bool _segmentsCross(Vec2 a, Vec2 b, Vec2 c, Vec2 d) {
  final ab = b - a, cd = d - c;
  final d1 = ab.cross(c - a), d2 = ab.cross(d - a);
  final d3 = cd.cross(a - c), d4 = cd.cross(b - c);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true;
  }
  return false;
}

/// Distance from [p] to segment [a]-[b].
double _pointSegmentDistance(Vec2 p, Vec2 a, Vec2 b) =>
    p.distanceTo(_nearestOnSegment(p, a, b));

Vec2 _nearestOnSegment(Vec2 p, Vec2 a, Vec2 b) {
  final d = b - a;
  final len2 = d.dot(d);
  if (len2 <= 1e-12) return a;
  final t = ((p - a).dot(d) / len2).clamp(0.0, 1.0);
  return a + d * t;
}

/// A point inside [polygon] (either winding): the vertex average when the
/// polygon contains it, else the midpoint of the longest horizontal chord
/// through that average, which handles concave L and U lots (§3.1). Ties go to
/// the westernmost chord. A polygon with no chord returns the average.
Vec2 interiorPoint(List<Vec2> polygon) {
  if (polygon.isEmpty) return const Vec2(0, 0);
  var se = 0.0, sn = 0.0;
  for (final p in polygon) {
    se += p.e;
    sn += p.n;
  }
  final avg = Vec2(se / polygon.length, sn / polygon.length);
  final xs = [for (final p in polygon) p.e];
  final ys = [for (final p in polygon) p.n];
  if (_ringContains(xs, ys, avg.e, avg.n)) return avg;

  final hits = <double>[];
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    if ((ys[i] > avg.n) != (ys[j] > avg.n)) {
      hits.add((xs[j] - xs[i]) * (avg.n - ys[i]) / (ys[j] - ys[i]) + xs[i]);
    }
  }
  hits.sort();
  var best = -1.0;
  Vec2? mid;
  for (var k = 0; k + 1 < hits.length; k += 2) {
    final len = hits[k + 1] - hits[k];
    if (len > best) {
      best = len;
      mid = Vec2((hits[k] + hits[k + 1]) / 2, avg.n);
    }
  }
  return mid ?? avg;
}

/// The frontage a lot should have, whatever it stores (§3.1): over the edges of
/// [polygon] at least 6 m long, the nearest point `R` of an eligible road
/// within `reachM + halfWidth`, lying strictly outside the edge, scored
/// `dist − 15·|t_edge·t_road|`; the lowest score wins, ties to the smaller
/// edge index counted counter-clockwise from the vertex with the smallest
/// `(e, n)`, then the smaller road slot, then the smaller segment.
///
/// Returns the winning edge's corners in counter-clockwise order, or null when
/// no eligible road is in reach (the caller falls back to the longest edge and
/// the site gets no plan).
(Vec2, Vec2)? effectiveFrontage(
  List<Vec2> polygon,
  RoadIndex roads, {
  double reachM = kSiteReachM,
}) {
  if (polygon.length < 3) return null;
  final p = _canonicalCcw(polygon);
  final m = p.length;

  var bestScore = double.infinity;
  var bestEdge = -1, bestSlot = -1, bestSeg = -1;

  final box = Box2.of(p);
  final slack = reachM + _maxEligibleHalfWidth;
  for (var k = 0; k < m; k++) {
    final a = p[k], b = p[(k + 1) % m];
    final edge = b - a;
    final edgeLen = edge.length;
    if (edgeLen < kEffectiveFrontageMinEdgeM) continue;
    final tEdge = edge * (1 / edgeLen);
    roads.visit(box, slack, (slot, rec, seg) {
      if (seg == 0) return; // a one-sample road has no tangent
      if (!isEligibleJoinRoad(rec.road.roadClass)) return;
      final q0 = rec.sampleAt(seg - 1), q1 = rec.sampleAt(seg);
      final roadDir = q1 - q0;
      final roadLen = roadDir.length;
      if (roadLen <= 1e-9) return;
      // A road crossing the edge has its nearest point ON it, never outside:
      // it is not this edge's frontage.
      if (_segmentsCross(a, b, q0, q1)) return;

      // The true nearest pair of the two segments. Candidates in a fixed
      // order; the first strictly nearest is kept.
      var dist = double.infinity;
      Vec2? r;
      void consider(Vec2 onRoad, double d) {
        if (d < dist) {
          dist = d;
          r = onRoad;
        }
      }

      final ra = _nearestOnSegment(a, q0, q1);
      consider(ra, a.distanceTo(ra));
      final rb = _nearestOnSegment(b, q0, q1);
      consider(rb, b.distanceTo(rb));
      consider(q0, _pointSegmentDistance(q0, a, b));
      consider(q1, _pointSegmentDistance(q1, a, b));
      final hit = r;
      if (hit == null) return;
      if (dist > reachM + rec.road.halfWidth) return;
      // Outside the edge: on the right of a counter-clockwise edge.
      if (edge.cross(hit - a) >= 0) return;

      final tRoad = roadDir * (1 / roadLen);
      final score =
          dist - kEffectiveFrontageTangentWeight * tEdge.dot(tRoad).abs();
      final better =
          score < bestScore ||
          (score == bestScore &&
              (k < bestEdge ||
                  (k == bestEdge &&
                      (slot < bestSlot ||
                          (slot == bestSlot && seg < bestSeg)))));
      if (better) {
        bestScore = score;
        bestEdge = k;
        bestSlot = slot;
        bestSeg = seg;
      }
    });
  }
  if (bestEdge < 0) return null;
  return (p[bestEdge], p[(bestEdge + 1) % m]);
}

/// An axis-aligned rectangle in site-frame metres: x along the frontage, y into
/// the lot.
class SiteRect {
  const SiteRect(this.x0, this.y0, this.x1, this.y1);

  final double x0, y0, x1, y1;

  double get width => x1 - x0;
  double get depth => y1 - y0;

  @override
  String toString() => 'SiteRect([$x0, $x1] x [$y0, $y1])';
}

/// One right-handed frame per site: x along the frontage, y into the lot.
///
/// Built only by [SiteFrame.of]. Immutable; the [profile] is computed on first
/// read.
class SiteFrame {
  SiteFrame._(
    this._polygon,
    this.origin,
    this.u,
    this.v,
    this.widthM,
    this.usedEffectiveFrontage,
  );

  /// The site frame of [polygon] (either winding), fronting [frontage] when it
  /// is given and its midpoint lies on the polygon, else its
  /// [effectiveFrontage] against [roads] (else its longest edge).
  ///
  /// Null for a degenerate polygon: fewer than 3 vertices, a non-finite
  /// coordinate, an area under 30 m², or a zero-length frontage.
  static SiteFrame? of(
    List<Vec2> polygon,
    (Vec2, Vec2)? frontage,
    RoadIndex roads,
  ) {
    if (polygon.length < 3) return null;
    for (final q in polygon) {
      if (!q.e.isFinite || !q.n.isFinite) return null;
    }
    if (_twiceSignedArea(polygon).abs() / 2 < kMinSiteAreaM2) return null;
    final p = _canonicalCcw(polygon);

    var used = frontage;
    if (used != null) {
      final mid = (used.$1 + used.$2) * 0.5;
      var near = double.infinity;
      for (var k = 0; k < p.length; k++) {
        final d = _pointSegmentDistance(mid, p[k], p[(k + 1) % p.length]);
        if (d < near) near = d;
      }
      if (!(near <= kFrontageOffPolygonM)) used = null;
    }
    var effective = false;
    if (used == null) {
      effective = true;
      used = effectiveFrontage(p, roads) ?? _longestEdge(p);
    }

    var (a, b) = used;
    final w = b.distanceTo(a);
    if (!(w >= kFrameDegenerateM)) return null;
    var u = (b - a) * (1 / w);
    var v = u.perp;
    // Orient v by the canonical CCW edge under the frontage midpoint, whose
    // left normal points into the lot by construction. (§3.1's pseudocode
    // compares against interiorPoint, which on a concave lot can lie across
    // the frontage line, e.g. an L lot fronting its notch floor.) The interior
    // point is only the fallback when that edge is perpendicular to u.
    final mid = (a + b) * 0.5;
    var nearest = double.infinity;
    Vec2? inward;
    for (var k = 0; k < p.length; k++) {
      final e = p[(k + 1) % p.length] - p[k];
      final len = e.length;
      if (len <= 1e-9) continue;
      final d = _pointSegmentDistance(mid, p[k], p[(k + 1) % p.length]);
      if (d < nearest) {
        nearest = d;
        inward = (e * (1 / len)).perp;
      }
    }
    final side = inward == null ? 0.0 : v.dot(inward);
    final flip = side.abs() >= 1e-9
        ? side < 0
        : (interiorPoint(p) - a).dot(v) < 0;
    if (flip) {
      final t = a;
      a = b;
      b = t;
      u = u * -1;
      v = u.perp;
    }
    return SiteFrame._(p, a, u, v, w, effective);
  }

  static (Vec2, Vec2) _longestEdge(List<Vec2> p) {
    var best = -1.0;
    var k0 = 0;
    for (var k = 0; k < p.length; k++) {
      final len = p[k].distanceTo(p[(k + 1) % p.length]);
      if (len > best) {
        best = len;
        k0 = k;
      }
    }
    return (p[k0], p[(k0 + 1) % p.length]);
  }

  /// The counter-clockwise polygon, canonically rotated.
  final List<Vec2> _polygon;

  /// The frontage corner the frame's x runs from.
  final Vec2 origin;

  /// Unit vector along the frontage (local +x).
  final Vec2 u;

  /// Unit vector into the lot (local +y): `u.perp`, counter-clockwise.
  final Vec2 v;

  /// Frontage length W, along [u].
  final double widthM;

  /// Whether the frontage was chosen by [effectiveFrontage] (or the longest
  /// edge) rather than stored on the lot.
  final bool usedEffectiveFrontage;

  /// Heading of the street side, `−v`, in the `Parcel.heading` convention
  /// (radians from north toward east). Equals `Parcel.heading` wherever
  /// `Parcel.facing == −v`. Negated as `0 − v` so no component is −0.0: an
  /// axis-aligned street would otherwise read −π where `Parcel.heading`
  /// reads π.
  double get streetHeading => Vec2(0.0 - v.e, 0.0 - v.n).heading;

  /// `streetHeading + π`: spinning a building by `−buildingHeading` maps its
  /// local +Y onto [v] and local +X onto [u].
  double get buildingHeading => streetHeading + math.pi;

  /// World east/north to frame metres.
  Vec2 toLocal(Vec2 world) {
    final d = world - origin;
    return Vec2(d.dot(u), d.dot(v));
  }

  /// Frame metres to world east/north.
  Vec2 toWorld(Vec2 local) => origin + u * local.e + v * local.n;

  /// The lot's depth profile in this frame, built on first read.
  late final DepthProfile profile = DepthProfile._(this, _polygon);
}

/// The inside depth of a lot, one column every 0.5 m along the frontage
/// (§3.1). Each column keeps the single inside interval nearest the frontage,
/// less a 0.3 m margin at each end. Searches read the profile; every emitted
/// rectangle must also pass the exact [containsRect].
class DepthProfile {
  DepthProfile._(SiteFrame frame, List<Vec2> polygon)
    : _xs = Float64List(polygon.length),
      _ys = Float64List(polygon.length) {
    var lo = double.infinity, hi = -double.infinity;
    for (var i = 0; i < polygon.length; i++) {
      final l = frame.toLocal(polygon[i]);
      _xs[i] = l.e;
      _ys[i] = l.n;
      if (l.e < lo) lo = l.e;
      if (l.e > hi) hi = l.e;
    }
    _x0 = lo;
    final columns = math.max(1, ((hi - lo) / kDepthProfileStepM).ceil());
    _far = Float64List(columns);
    final hits = <double>[];
    var maxDepth = 0.0;
    for (var col = 0; col < columns; col++) {
      final x = lo + (col + 0.5) * kDepthProfileStepM;
      hits.clear();
      final n = _xs.length;
      for (var i = 0, j = n - 1; i < n; j = i++) {
        if ((_xs[i] > x) != (_xs[j] > x)) {
          hits.add(
            (_ys[j] - _ys[i]) * (x - _xs[i]) / (_xs[j] - _xs[i]) + _ys[i],
          );
        }
      }
      hits.sort();
      var bestGap = double.infinity;
      var y0 = 0.0, y1 = 0.0;
      for (var k = 0; k + 1 < hits.length; k += 2) {
        final a = hits[k], b = hits[k + 1];
        final gap = a > 0 ? a : (b < 0 ? -b : 0.0);
        if (gap < bestGap) {
          bestGap = gap;
          y0 = a;
          y1 = b;
        }
      }
      y0 += kDepthProfileMarginM;
      y1 -= kDepthProfileMarginM;
      // A column whose nearest interval starts past the frontage line (plus
      // the 1 m a trusted stored frontage may sit off the lot) cannot be
      // reached from the frontage: an open U's notch. It reads 0.
      if (!bestGap.isFinite ||
          y1 <= y0 ||
          y0 > kDepthProfileMarginM + kFrontageOffPolygonM + 1e-9) {
        _far[col] = 0;
        continue;
      }
      _far[col] = y1;
      if (y1 > maxDepth) maxDepth = y1;
    }
    _maxDepth = maxDepth;
  }

  final Float64List _xs, _ys;
  late final double _x0;
  late final Float64List _far;
  late final double _maxDepth;

  int _column(double x) {
    final i = ((x - _x0) / kDepthProfileStepM).floor();
    return i < 0 || i >= _far.length ? -1 : i;
  }

  /// How far into the lot (frame y, metres from the frontage line) the usable
  /// interval of the column holding [x] reaches; 0 outside the lot, where the
  /// column's interval is thinner than its margins, or where that interval
  /// starts more than 1 m past the frontage line (unreachable from it).
  double depthAt(double x) {
    final i = _column(x);
    if (i < 0) return 0;
    return math.max(0.0, _far[i]);
  }

  /// The deepest [depthAt] of any column.
  double get maxDepthM => _maxDepth;

  /// Exactly whether [r] (frame metres) lies inside the lot: every corner
  /// inside and no polygon edge through its interior (Liang-Barsky). A
  /// rectangle that fails is dropped by the caller, never nudged.
  bool containsRect(SiteRect r) {
    if (!(r.x1 > r.x0) || !(r.y1 > r.y0)) return false;
    if (!_ringContains(_xs, _ys, r.x0, r.y0) ||
        !_ringContains(_xs, _ys, r.x1, r.y0) ||
        !_ringContains(_xs, _ys, r.x1, r.y1) ||
        !_ringContains(_xs, _ys, r.x0, r.y1)) {
      return false;
    }
    const eps = 1e-9;
    final xMin = r.x0 + eps, xMax = r.x1 - eps;
    final yMin = r.y0 + eps, yMax = r.y1 - eps;
    final n = _xs.length;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final px = _xs[i], py = _ys[i];
      final dx = _xs[j] - px, dy = _ys[j] - py;
      if (_clipsInterior(px, py, dx, dy, xMin, xMax, yMin, yMax)) return false;
    }
    return true;
  }

  static bool _clipsInterior(
    double px,
    double py,
    double dx,
    double dy,
    double xMin,
    double xMax,
    double yMin,
    double yMax,
  ) {
    var t0 = 0.0, t1 = 1.0;
    bool edge(double p, double q) {
      if (p == 0) return q >= 0;
      final t = q / p;
      if (p < 0) {
        if (t > t1) return false;
        if (t > t0) t0 = t;
      } else {
        if (t < t0) return false;
        if (t < t1) t1 = t;
      }
      return true;
    }

    if (!edge(-dx, px - xMin)) return false;
    if (!edge(dx, xMax - px)) return false;
    if (!edge(-dy, py - yMin)) return false;
    if (!edge(dy, yMax - py)) return false;
    return t0 < t1;
  }
}
