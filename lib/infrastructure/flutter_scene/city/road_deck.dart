// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Roads off the ground: the deck a raised or sunk road runs on, and the
/// structure it stands on or runs into.
///
/// The road tool lifts a road onto a deck (see `road_elevation.dart`), and
/// the frame carries that as a LIFT per centreline point — the deck's
/// height above the drape, which is where the points themselves still lie
/// (see `RoadSnapshot.lifts`). Keeping the points on the ground is what
/// lets a pier stand on it and a portal know where the hillside is; the
/// lift says how far above it (or, negative, below it) the carriageway
/// runs.
///
/// Three things follow from a lift, and all three are here:
///
///   * the lift as the function of arc length every carriageway emitter
///     already takes ([liftAt]) — exact at each point, because those
///     emitters' stations ARE the points;
///   * the RUNS of a road that are above ground ([runs]): a stretch deeper
///     than [RoadElevation.tunnelCoverM] is in a tunnel and draws nothing,
///     and a run that stops short of its road's end stops at a mouth, where
///     the deck meets that depth and a [portal] stands;
///   * the structure under a deck that stands clear of the ground
///     ([structure]): piers from the drape up, a girder along each edge and
///     a parapet on it — deeper girders on longer spans where the deck is
///     high enough to be a bridge.
///
/// Metres, anchor-relative, like every road emitter; the vertex writes
/// apply the render scale. Plain arithmetic on the request's own values
/// and nothing else, because it runs on the tile workers (see
/// `city_tile_mesher.dart`).
library;

import 'dart:math' as math;

import '../../../domain/architecture/architecture_style.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import 'oriented_box.dart';
import 'road_mesher.dart';

/// A pier's footprint put to the roads around it: whether a pier standing
/// on the drape at [foot] — [halfAcrossM] either side of its deck's
/// centreline and [halfAlongM] along the deck ([along]), [up] radial —
/// would stand in another road's carriageway. See [RoadCorridors].
typedef PierBlocked = bool Function(Vector3 foot, Vector3 along, Vector3 up,
    double halfAcrossM, double halfAlongM);

/// The carriageways a pier keeps out of: a tile's roads as corridors in
/// plan — a centreline and a half width — which a deck's piers move along
/// the deck to clear ([RoadDeckMesher.structure], [RoadMesher.piers]).
///
/// A raised road crosses what is under it without either being cut —
/// that is what the tool raised it for — so nothing on the deck says
/// where the road beneath runs, and a pier stood wherever its span fell:
/// as often as not in the lanes it was built to clear.
///
/// The roads stay the tile's body-fixed point lists; each keeps only its
/// bounds, anchor-relative, so a pier measures just the roads that come
/// near it, and a tile whose roads all lie on the ground never builds one
/// (see `CityTileMeshJob`). Plain arithmetic on the request's own values,
/// for the tile workers.
class RoadCorridors {
  RoadCorridors(this.anchorBF);

  final Vector3 anchorBF;

  /// How far clear of a carriageway's edge a pier's face keeps: a kerb and
  /// a verge's worth.
  static const double clearM = 1.5;

  final List<int> _ids = [];
  final List<List<double>> _points = [];
  final List<double> _halfWidths = [];

  /// Six per road, anchor-relative: the least x, y, z, then the greatest.
  final List<double> _bounds = [];

  int get length => _ids.length;

  /// Road [id]'s carriageway: [halfWidthM] either side of [pointsBF]
  /// (body-fixed xyz triplets, two points or more).
  void add(int id, List<double> pointsBF, double halfWidthM) {
    if (pointsBF.length < 6) return;
    var x0 = double.infinity, y0 = double.infinity, z0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity, z1 = -double.infinity;
    for (var i = 0; i + 2 < pointsBF.length; i += 3) {
      final x = pointsBF[i] - anchorBF.x;
      final y = pointsBF[i + 1] - anchorBF.y;
      final z = pointsBF[i + 2] - anchorBF.z;
      x0 = math.min(x0, x);
      y0 = math.min(y0, y);
      z0 = math.min(z0, z);
      x1 = math.max(x1, x);
      y1 = math.max(y1, y);
      z1 = math.max(z1, z);
    }
    _ids.add(id);
    _points.add(pointsBF);
    _halfWidths.add(halfWidthM);
    _bounds.addAll([x0, y0, z0, x1, y1, z1]);
  }

  /// Whether a pier at [foot] (anchor-relative, on the drape) standing
  /// [halfAcrossM] either side of its deck and [halfAlongM] along it would
  /// come within [clearM] of any carriageway but road [except]'s. The pier
  /// is a slab across its deck, so it is measured as its long axis in the
  /// ground plane, with the corridor widened by its half thickness.
  bool blocks(Vector3 foot, Vector3 along, Vector3 up, double halfAcrossM,
      double halfAlongM,
      {int? except}) {
    final flat = along - up * along.dot(up);
    if (flat.length < 1e-6) return false;
    final e2 = flat.normalized;
    final e1 = e2.cross(up).normalized;
    final ax = anchorBF.x + foot.x, ay = anchorBF.y + foot.y;
    final az = anchorBF.z + foot.z;
    for (var k = 0; k < _ids.length; k++) {
      if (_ids[k] == except) continue;
      final keep = _halfWidths[k] + clearM + halfAlongM;
      final reach = keep + halfAcrossM;
      final b = 6 * k;
      if (foot.x < _bounds[b] - reach ||
          foot.y < _bounds[b + 1] - reach ||
          foot.z < _bounds[b + 2] - reach ||
          foot.x > _bounds[b + 3] + reach ||
          foot.y > _bounds[b + 4] + reach ||
          foot.z > _bounds[b + 5] + reach) {
        continue;
      }
      final pts = _points[k];
      var pu = 0.0, pv = 0.0;
      for (var i = 0; i + 2 < pts.length; i += 3) {
        final dx = pts[i] - ax, dy = pts[i + 1] - ay, dz = pts[i + 2] - az;
        final u = dx * e1.x + dy * e1.y + dz * e1.z;
        final v = dx * e2.x + dy * e2.y + dz * e2.z;
        if (i > 0 && axisDistance(pu, pv, u, v, halfAcrossM) < keep) {
          return true;
        }
        pu = u;
        pv = v;
      }
    }
    return false;
  }

  /// Distance in the plane from the segment (pu, pv)-(qu, qv) to the
  /// segment from (-a, 0) to (a, 0).
  static double axisDistance(
      double pu, double pv, double qu, double qv, double a) {
    // Across the axis line between the axis's ends: they touch.
    if (pv != qv && (pv <= 0) != (qv < 0)) {
      final u = pu + (qu - pu) * (pv / (pv - qv));
      if (u.abs() <= a) return 0;
    }
    // Otherwise the nearest pair has an end of one of the two in it.
    double toAxis(double u, double v) {
      final du = math.max(u.abs() - a, 0.0);
      return math.sqrt(du * du + v * v);
    }

    double toSegment(double u, double v) {
      final du = qu - pu, dv = qv - pv;
      final len2 = du * du + dv * dv;
      final t = len2 < 1e-12
          ? 0.0
          : (((u - pu) * du + (v - pv) * dv) / len2).clamp(0.0, 1.0);
      final eu = pu + du * t - u, ev = pv + dv * t - v;
      return math.sqrt(eu * eu + ev * ev);
    }

    return math.min(math.min(toAxis(pu, pv), toAxis(qu, qv)),
        math.min(toSegment(-a, 0), toSegment(a, 0)));
  }
}

/// One stretch of a road above ground: its drape points, the deck's lift
/// at each, and where it lies on its road.
class RoadRun {
  const RoadRun({
    required this.pts,
    required this.lifts,
    required this.s0,
    required this.fromStart,
    required this.toEnd,
  });

  /// The whole of a road that follows the ground: its own points, as they
  /// are, and no lifts — the run every road the generator lays is.
  const RoadRun.whole(this.pts)
      : lifts = null,
        s0 = 0,
        fromStart = true,
        toEnd = true;

  /// Drape points, anchor-relative metres: the road's own, plus a point
  /// interpolated at each tunnel mouth.
  final List<Vector3> pts;

  /// The deck above the drape at each of [pts]; null for a road on the
  /// ground.
  final List<double>? lifts;

  /// Arc length of the run's first point from its road's first point: what
  /// the road's bridge ranges are measured from.
  final double s0;

  /// Whether the run begins at its road's first point, and ends at its
  /// last. An end that does not is a tunnel mouth.
  final bool fromStart, toEnd;
}

class RoadDeckMesher {
  const RoadDeckMesher._();

  /// Headroom under a portal's lintel, over the deck at the mouth: a
  /// lorry's height and the lights above it.
  static const double portalClearM = 5.4;

  /// How far the wing walls run back out of a mouth along the cutting.
  static const double wingWallM = 14.0;

  /// Pier spacing under a deck that stands clear of the ground, and under
  /// one high enough to be a bridge: the higher the deck, the longer the
  /// span — which is most of what makes a bridge read as a bridge rather
  /// than a viaduct at a distance.
  static const double pierSpacingM = 38;
  static const double bridgePierSpacingM = 64;

  /// Depth of the edge girders, over a viaduct span and over a bridge's.
  static const double girderDepthM = 1.2;
  static const double bridgeGirderDepthM = 2.4;

  /// Height of the parapet on a raised deck's edge.
  static const double parapetHeightM = 0.9;

  /// Precast concrete, off the facade atlas — what the viaduct's barriers
  /// and the sound walls are made of.
  static const double _concreteU =
      (FacadeMaterial.precast + 0.5) / kFacadeMaterials;

  // ---- The lift -------------------------------------------------------------

  /// Arc length at each of [pts], summed the way [RoadMesher]'s stations
  /// sum it, term for term: a lookup at a station's own arc then lands on
  /// that station's own lift exactly.
  static List<double> cumulative(List<Vector3> pts) {
    final out = List<double>.filled(pts.length, 0);
    var s = 0.0;
    for (var i = 1; i < pts.length; i++) {
      s += (pts[i] - pts[i - 1]).length;
      out[i] = s;
    }
    return out;
  }

  /// The lift at arc [s] over points at [cum] carrying [lifts]: linear
  /// between points, held past either end.
  static double lerp(List<double> cum, List<double> lifts, double s) {
    final n = cum.length;
    if (s <= cum[0]) return lifts[0];
    if (s >= cum[n - 1]) return lifts[n - 1];
    var lo = 0, hi = n - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = cum[hi] - cum[lo];
    if (span <= 0) return lifts[hi];
    return lifts[lo] + (lifts[hi] - lifts[lo]) * ((s - cum[lo]) / span);
  }

  /// The deck's lift along [pts] as the function of arc length the road
  /// emitters take ([RoadMesher.carriageway]'s `liftAt`): [lifts] between
  /// the points, plus the plan's own bridges over [bridges] — arc ranges
  /// from the ROAD's first point, which lies [s0] before this run's. The
  /// two compose: a generated bridge on a road the player also raised
  /// stands on top of the raise.
  static double Function(double s) liftAt(
    List<Vector3> pts,
    List<double> lifts, {
    List<(double, double)> bridges = const [],
    double s0 = 0,
  }) {
    final cum = cumulative(pts);
    if (bridges.isEmpty) return (s) => lerp(cum, lifts, s);
    return (s) =>
        lerp(cum, lifts, s) + RoadMesher.bridgeLiftAt(s + s0, bridges);
  }

  // ---- Runs and spans -------------------------------------------------------

  /// The stretches of a road above ground: every maximal run of points no
  /// deeper than [RoadElevation.tunnelCoverM], each carried on to the MOUTH
  /// where its deck reaches that depth — a point interpolated between the
  /// last point outside and the first inside, at exactly the cover depth.
  /// A road that never goes under is one run; one wholly underground is
  /// none.
  static List<RoadRun> runs(List<Vector3> pts, List<double> lifts) {
    const deep = -RoadElevation.tunnelCoverM;
    final n = pts.length;
    if (n < 2 || lifts.length != n) return const [];
    bool under(int i) => lifts[i] < deep;
    final cum = cumulative(pts);
    final out = <RoadRun>[];
    var i = 0;
    while (i < n) {
      if (under(i)) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < n && !under(j + 1)) {
        j++;
      }
      final p = <Vector3>[];
      final l = <double>[];
      var s0 = cum[i];
      if (i > 0) {
        // The mouth behind the run: the deck climbs out of the tunnel
        // between i-1 (under) and i.
        final t = (deep - lifts[i - 1]) / (lifts[i] - lifts[i - 1]);
        if (t < 1) {
          p.add(pts[i - 1] + (pts[i] - pts[i - 1]) * t);
          l.add(deep);
          s0 = cum[i - 1] + (cum[i] - cum[i - 1]) * t;
        }
      }
      for (var k = i; k <= j; k++) {
        p.add(pts[k]);
        l.add(lifts[k]);
      }
      if (j < n - 1) {
        // The mouth ahead: the deck goes under between j and j+1.
        final t = (lifts[j] - deep) / (lifts[j] - lifts[j + 1]);
        if (t > 0) {
          p.add(pts[j] + (pts[j + 1] - pts[j]) * t);
          l.add(deep);
        }
      }
      if (p.length >= 2) {
        out.add(RoadRun(
            pts: p, lifts: l, s0: s0, fromStart: i == 0, toEnd: j == n - 1));
      }
      i = j + 1;
    }
    return out;
  }

  /// Index spans (first and last point, inclusive, two points or more) of
  /// [pts] where the deck runs at grade — no more than
  /// [RoadElevation.structureClearM] above the drape, where the ground is
  /// cut or filled to meet it and a pavement can run beside it — and where
  /// it stands up on a structure.
  static ({List<(int, int)> graded, List<(int, int)> raised}) spans(
      List<Vector3> pts, double Function(double s) liftAt) {
    final cum = cumulative(pts);
    final graded = <(int, int)>[];
    final raised = <(int, int)>[];
    var start = 0;
    bool up(int i) => liftAt(cum[i]) > RoadElevation.structureClearM;
    for (var i = 1; i <= pts.length; i++) {
      if (i < pts.length && up(i) == up(start)) continue;
      if (i - 1 > start) (up(start) ? raised : graded).add((start, i - 1));
      start = i;
    }
    return (graded: graded, raised: raised);
  }

  /// [pts] from [from] to [to] (inclusive) lifted radially onto the deck:
  /// what the pavement, its lamps and its furniture stand on where the
  /// deck runs at grade, and the lamps on a structure. Radial, so every
  /// emitter's own "up" — the point's direction from the body's centre —
  /// is the one it had on the ground.
  static List<Vector3> raise(List<Vector3> pts, Vector3 anchorBF,
      double Function(double s) liftAt,
      {int from = 0, int? to}) {
    final cum = cumulative(pts);
    final last = to ?? pts.length - 1;
    return [
      for (var i = from; i <= last; i++)
        pts[i] + (pts[i] + anchorBF).normalized * liftAt(cum[i]),
    ];
  }

  // ---- Structure ------------------------------------------------------------

  /// Everything a raised deck along [pts] stands on and carries at its
  /// edges, wherever [liftAt] holds it more than
  /// [RoadElevation.structureClearM] clear of the drape: a girder along
  /// each edge with its top at the deck, a parapet on each edge, and a
  /// pier from a metre into the ground up to the girders' soffit — every
  /// [pierSpacingM], or every [bridgePierSpacingM] under deeper girders
  /// where the deck is higher than [RoadElevation.bridgeHeightM]. Into
  /// [solid], in precast concrete.
  ///
  /// Given [blocked] (see [RoadCorridors]), a pier that falls due in the
  /// carriageway of a road beneath moves on along the deck to the first
  /// point clear of it — at most a span on; a road running the length of
  /// the deck beneath it has no clear point, and there the pier stands.
  static void structure(
    MeshBuilder solid,
    List<Vector3> pts,
    Vector3 anchorBF,
    double halfWidthM,
    double Function(double s) liftAt, {
    PierBlocked? blocked,
  }) {
    final n = pts.length;
    if (n < 2) return;
    final cum = cumulative(pts);
    final lift = [for (final s in cum) liftAt(s)];
    const clear = RoadElevation.structureClearM;
    const bridge = RoadElevation.bridgeHeightM;
    const deckLift = RoadMesher.ribbonLiftM;

    // Girders and parapets, a segment at a time, where the segment's middle
    // stands clear: a deck climbing off the fill is carried from the first
    // segment that leaves it.
    for (var i = 1; i < n; i++) {
      final la = lift[i - 1], lb = lift[i];
      if ((la + lb) / 2 <= clear) continue;
      final a = pts[i - 1], b = pts[i];
      final seg = b - a;
      if (seg.length < 1e-6) continue;
      final ua = (a + anchorBF).normalized, ub = (b + anchorBF).normalized;
      final up = (ua + ub).normalized;
      final side = seg.normalized.cross(up).normalized;
      final depth =
          math.max(la, lb) > bridge ? bridgeGirderDepthM : girderDepthM;
      final da = a + ua * (deckLift + la), db = b + ub * (deckLift + lb);
      for (final sign in const [-1.0, 1.0]) {
        // The girder's face just outside the carriageway's edge.
        final g = side * (sign * (halfWidthM + 0.25));
        OrientedBox.span(solid, da + g - ua * (depth / 2),
            db + g - ub * (depth / 2), up, 0.5, depth,
            u: _concreteU);
        final p = side * (sign * (halfWidthM + 0.15));
        OrientedBox.span(solid, da + p + ua * (parapetHeightM / 2),
            db + p + ub * (parapetHeightM / 2), up, 0.3, parapetHeightM,
            u: _concreteU);
      }
    }

    // Piers, on the points: the first where the deck leaves the fill, then
    // one a span on — moved on past a road beneath.
    var since = double.infinity;
    // Where the pier being moved on fell due.
    double? dueAt;
    for (var k = 0; k < n; k++) {
      if (k > 0) since += cum[k] - cum[k - 1];
      final l = lift[k];
      if (l <= clear) {
        since = double.infinity;
        dueAt = null;
        continue;
      }
      final isBridge = l > bridge;
      final span = isBridge ? bridgePierSpacingM : pierSpacingM;
      if (since < span) continue;
      final p = pts[k];
      final up = (p + anchorBF).normalized;
      final ahead = k + 1 < n ? pts[k + 1] - p : p - pts[k - 1];
      if (blocked != null && ahead.length >= 1e-6) {
        final due = dueAt ??= cum[k];
        if (cum[k] - due < span &&
            blocked(p, ahead.normalized, up,
                halfWidthM * (isBridge ? 1.6 : 1.4) / 2,
                (isBridge ? 3.2 : 2.4) / 2)) {
          continue;
        }
        dueAt = null;
      }
      since = 0;
      if (ahead.length < 1e-6) continue;
      final depth = isBridge ? bridgeGirderDepthM : girderDepthM;
      final h = l + deckLift - depth + 1.0;
      if (h <= 0.5) continue;
      OrientedBox.upright(solid, p - up * 1.0, ahead.normalized, up,
          halfWidthM * (isBridge ? 1.6 : 1.4), isBridge ? 3.2 : 2.4, h,
          u: _concreteU);
    }
  }

  /// A tunnel portal at the mouth [at] (on the drape), the road running
  /// [into] the hill from it, its deck [deckLiftM] above the drape there
  /// (negative: the cover depth). Two wing walls retaining the cutting from
  /// the deck up, running back out along the approach; a lintel over the
  /// opening at [portalClearM]; and a headwall above it, wider than the
  /// opening, up to just above the ground it holds back. Into [solid], in
  /// precast concrete.
  static void portal(
    MeshBuilder solid,
    Vector3 at,
    Vector3 into,
    Vector3 anchorBF,
    double halfWidthM, {
    double deckLiftM = -RoadElevation.tunnelCoverM,
  }) {
    final up = (at + anchorBF).normalized;
    final flat = into - up * into.dot(up);
    if (flat.length < 1e-6) return;
    final along = flat.normalized;
    final side = along.cross(up).normalized;
    final deck = at + up * deckLiftM;
    final lintelTop = deckLiftM + portalClearM + 1.2;
    // The headwall stands at least a little proud of the ground over the
    // mouth, whatever the cover.
    final topLift = math.max(lintelTop + 0.4, 1.2);
    final wallOut = halfWidthM + 0.9;
    const wallW = 0.8;
    final h = topLift - deckLiftM;
    for (final sign in const [-1.0, 1.0]) {
      final off = side * (sign * (wallOut + wallW / 2)) + up * (h / 2);
      OrientedBox.span(solid, deck + off - along * wingWallM,
          deck + off + along * 1.0, up, wallW, h,
          u: _concreteU);
    }
    // The lintel over the opening, from wall to wall.
    final lintel = deck + up * (portalClearM + 0.6) + along * 0.5;
    OrientedBox.span(solid, lintel - side * (wallOut + wallW),
        lintel + side * (wallOut + wallW), up, 1.2, 1.2,
        u: _concreteU);
    // The headwall, above the lintel and wider than the opening.
    final headH = topLift - lintelTop;
    if (headH > 0.05) {
      final c = at + up * ((lintelTop + topLift) / 2) + along * 0.5;
      OrientedBox.span(solid, c - side * (wallOut + 3.0),
          c + side * (wallOut + 3.0), up, 1.0, headH,
          u: _concreteU);
    }
  }
}
