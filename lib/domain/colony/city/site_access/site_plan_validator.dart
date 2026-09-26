// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The plan invariants V1–V13 (docs/plans/site-access.md §2.4): `assert`ed
/// by `PlanBuilder.build`, always run in tests.
///
/// [SitePlanValidator.validate] returns structured [SiteViolation]s, each
/// naming its invariant, so a test can say "this broken plan fails V5 and
/// nothing else". Each rule is checked by exactly one invariant, so one
/// defect is reported under one name:
///
/// - V1 reads the [RoadGraph]'s `kerbWindows` (which hold for every override)
///   and, when given, the lane spans of lane graphs built from that graph
///   under any overrides ([SiteLaneSpans]). V1–V3 run only with a graph.
/// - V5 owns a throat's via spacing; V8 owns every other segment's, and
///   every segment's width.
/// - V7 owns turnaround radii ≥ 6 m; V13 owns the 12.5 m truck circle.
/// - V9 owns stall direction bits; V7's home-pad exception asks only that the
///   pad's stalls are `inline`.
/// - Non-finite numbers, pave rings that are not convex and counter-
///   clockwise, and paving over the envelope are [SiteInvariant.geometry].
///   A non-finite number stops the check there; so does a V6 index out of
///   range (nothing after could be read safely).
///
/// Strong connectivity (V7) counts the ROAD links of `SiteLaneGraph`
/// (every out-join's out-lane to every in-join's in-lane): a kerb node has
/// site degree 1, so no site is strongly connected without them. Because a
/// road link is no site path, V7 ALSO walks the site links alone: from every
/// in-join's in-lane to every stall entry lane and every out-join's
/// out-lane, and from every stall exit lane to every out-join's out-lane. A
/// node of site degree 0 fails V7.
///
/// V13 walks the directed lanes of truck segments (see `_truckPath`).
///
/// Allocates freely: build-time assertion and tests only.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart' show RoadClass;
import '../road_graph.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_join.dart' show joinDirsFor;
import 'site_lane_graph.dart';

/// The invariant a [SiteViolation] breaks.
enum SiteInvariant {
  v1Window,
  v2SideAndDirections,
  v3OneSource,
  v4Roles,
  v5Throat,
  v6Nodes,
  v7Connected,
  v8Segments,
  v9Stalls,
  v10OrderAndKeys,
  v11Entrance,
  v12Revision,
  v13Reserved,
  geometry;

  /// `V1` .. `V13`, or `geometry`.
  String get label => index < 13 ? 'V${index + 1}' : 'geometry';
}

/// The stop-bar-to-stop-bar lane span of each directed edge of a lane graph
/// built from the validated [RoadGraph] (`LaneGraph.edgeLaneS0/S1`, whose
/// edges are the road graph's), and its road-arc → travel-arc map
/// (`LaneGraph.travelArc`). A record, so the site access domain needs no
/// traffic import.
typedef SiteLaneSpans = ({
  Float32List laneS0,
  Float32List laneS1,
  double Function(int edge, double roadS) travelArc,
});

/// One broken invariant of one site.
class SiteViolation {
  const SiteViolation(this.invariant, this.site, this.siteId, this.detail);

  final SiteInvariant invariant;
  final int site;
  final String siteId;
  final String detail;

  @override
  String toString() => '${invariant.label} [$siteId]: $detail';
}

/// Checks plans against V1–V13. See the library comment.
abstract final class SitePlanValidator {
  /// Every violation of every site of [chunk].
  static List<SiteViolation> validateChunk(SiteAccessChunk chunk,
      {RoadGraph? graph, List<SiteLaneSpans> laneSpans = const []}) {
    final out = <SiteViolation>[];
    for (var k = 0; k < chunk.siteCount; k++) {
      out.addAll(validate(chunk.plan(k), graph: graph, laneSpans: laneSpans));
    }
    return out;
  }

  /// Every violation of [plan]. V1–V3 need [graph]; V1 also checks
  /// [laneSpans] when given.
  static List<SiteViolation> validate(SiteAccessPlan plan,
          {RoadGraph? graph, List<SiteLaneSpans> laneSpans = const []}) =>
      (_Check(plan, graph, laneSpans)..run()).out;

  /// The invariants [plan] breaks, each once.
  static Set<SiteInvariant> brokenBy(SiteAccessPlan plan,
      {RoadGraph? graph, List<SiteLaneSpans> laneSpans = const []}) {
    final vs = validate(plan, graph: graph, laneSpans: laneSpans);
    return {for (final v in vs) v.invariant};
  }
}

const double _eps = 1e-6;

/// Rectangles that share an edge touch; they overlap only past this.
const double _touchM = 0.01;

class _Check {
  _Check(this.p, this.g, this.spans);

  final SiteAccessPlan p;
  final RoadGraph? g;
  final List<SiteLaneSpans> spans;
  final List<SiteViolation> out = [];

  void bad(SiteInvariant v, String detail) =>
      out.add(SiteViolation(v, p.site, p.siteId, detail));

  late final Int32List _degree = () {
    final d = Int32List(p.nodeCount);
    for (var k = 0; k < p.segCount; k++) {
      d[p.segFrom(k)]++;
      d[p.segTo(k)]++;
    }
    return d;
  }();

  late final List<int> _throats = [
    for (var j = 0; j < p.joinCount; j++)
      if (p.joinIsCut(j) && p.joinThroatSeg(j) >= 0) p.joinThroatSeg(j)
  ];

  void run() {
    if (!_finite()) return;
    if (!_indices()) return;
    if (g != null) {
      _v1();
      _v2();
      _v3();
    }
    _v4();
    _v5();
    _v6();
    _v7();
    _v8();
    _v9();
    _v10();
    _v11();
    _v12();
    _v13();
    _geometry();
  }

  // ---- geometry: finite ------------------------------------------------------

  bool _finite() {
    final bad = <String>[];
    void f(double x, String what) {
      if (!x.isFinite) bad.add(what);
    }

    f(p.frameE, 'frameE');
    f(p.frameN, 'frameN');
    f(p.frameUE, 'frameUE');
    f(p.frameUN, 'frameUN');
    f(p.envX0, 'envX0');
    f(p.envX1, 'envX1');
    f(p.envY0, 'envY0');
    f(p.envY1, 'envY1');
    f(p.envFrontInset, 'envFrontInset');
    f(p.gateX, 'gateX');
    f(p.gateW, 'gateW');
    f(p.truckTurnRadiusM, 'truckTurnRadiusM');
    for (var i = 0; i < p.pointCount; i++) {
      f(p.ptE(i), 'ptE[$i]');
      f(p.ptN(i), 'ptN[$i]');
      f(p.ptHT(i), 'ptHT[$i]');
      f(p.ptDz(i), 'ptDz[$i]');
    }
    for (var j = 0; j < p.joinCount; j++) {
      f(p.joinRoadS(j), 'joinRoadS[$j]');
      f(p.joinCutHalfM(j), 'joinCutHalfM[$j]');
    }
    for (var n = 0; n < p.nodeCount; n++) {
      f(p.nodeTurnR(n), 'nodeTurnR[$n]');
      f(p.nodeTurnHx(n), 'nodeTurnHx[$n]');
      f(p.nodeTurnHn(n), 'nodeTurnHn[$n]');
    }
    for (var k = 0; k < p.segCount; k++) {
      f(p.segLenM(k), 'segLenM[$k]');
      f(p.segWidthM(k), 'segWidthM[$k]');
      f(p.segSpeedMps(k), 'segSpeedMps[$k]');
      f(p.segMaxVehLenM(k), 'segMaxVehLenM[$k]');
    }
    for (var i = 0; i < p.stallCount; i++) {
      f(p.stallS(i), 'stallS[$i]');
      f(p.stallE(i), 'stallE[$i]');
      f(p.stallN(i), 'stallN[$i]');
      f(p.stallDirE(i), 'stallDirE[$i]');
      f(p.stallDirN(i), 'stallDirN[$i]');
      f(p.stallLenM(i), 'stallLenM[$i]');
      f(p.stallWidthM(i), 'stallWidthM[$i]');
    }
    for (var b = 0; b < p.bayCount; b++) {
      f(p.bayE(b), 'bayE[$b]');
      f(p.bayN(b), 'bayN[$b]');
      f(p.bayDirE(b), 'bayDirE[$b]');
      f(p.bayDirN(b), 'bayDirN[$b]');
      f(p.bayLenM(b), 'bayLenM[$b]');
      f(p.bayWidthM(b), 'bayWidthM[$b]');
      f(p.bayS(b), 'bayS[$b]');
    }
    for (var q = 0; q < p.fenceGapCount; q++) {
      f(p.fenceGapT0(q), 'fenceGapT0[$q]');
      f(p.fenceGapT1(q), 'fenceGapT1[$q]');
    }
    if (bad.isEmpty) return true;
    this.bad(SiteInvariant.geometry, 'not finite: ${bad.join(', ')}');
    return false;
  }

  // ---- V6 structure (indices), then the rest of V6 later ----------------------

  bool _indices() {
    final errs = <String>[];
    bool inR(int v, int lo, int hi) => v >= lo && v < hi;
    final nP = p.pointCount, nN = p.nodeCount, nS = p.segCount;
    for (var n = 0; n < nN; n++) {
      if (!inR(p.nodePt(n), 0, nP)) errs.add('nodePt[$n]');
    }
    for (var k = 0; k < nS; k++) {
      if (!inR(p.segFrom(k), 0, nN)) errs.add('segFrom[$k]');
      if (!inR(p.segTo(k), 0, nN)) errs.add('segTo[$k]');
      if (p.segFrom(k) == p.segTo(k)) errs.add('segment $k is a loop');
    }
    if (p.segViaStart(0) != 0 || p.segViaStart(nS) != p.viaCount) {
      errs.add('segViaStart ends');
    }
    for (var k = 0; k < nS; k++) {
      if (p.segViaStart(k + 1) < p.segViaStart(k)) errs.add('segViaStart[$k]');
    }
    for (var v = 0; v < p.viaCount; v++) {
      if (!inR(p.viaPt(v), 0, nP)) errs.add('viaPt[$v]');
    }
    for (var j = 0; j < p.joinCount; j++) {
      if (!inR(p.joinKerbNode(j), -1, nN)) errs.add('joinKerbNode[$j]');
      if (!inR(p.joinThroatSeg(j), -1, nS)) errs.add('joinThroatSeg[$j]');
    }
    for (var i = 0; i < p.stallCount; i++) {
      if (!inR(p.stallSeg(i), 0, nS)) errs.add('stallSeg[$i]');
    }
    for (var b = 0; b < p.bayCount; b++) {
      if (!inR(p.baySeg(b), 0, nS)) errs.add('baySeg[$b]');
    }
    for (var l = 0; l < p.lampCount; l++) {
      if (!inR(p.lampPt(l), 0, nP)) errs.add('lampPt[$l]');
    }
    final nPavePt = p.chunk.pavePtStart(p.site + 1) - p.chunk.pavePtStart(p.site);
    if (p.paveStart(0) != 0 || p.paveStart(p.paveCount) != nPavePt) {
      errs.add('paveStart ends');
    }
    for (var i = 0; i < nPavePt; i++) {
      if (!inR(p.pavePt(i), 0, nP)) errs.add('pavePt[$i]');
    }
    final nPathPt = p.chunk.pathPtStart(p.site + 1) - p.chunk.pathPtStart(p.site);
    if (p.pathStart(0) != 0 || p.pathStart(p.pathCount) != nPathPt) {
      errs.add('pathStart ends');
    }
    for (var i = 0; i < nPathPt; i++) {
      if (!inR(p.pathPt(i), 0, nP)) errs.add('pathPt[$i]');
    }
    for (var i = 0; i < nP; i++) {
      final h = p.ptHJoin(i);
      if (h != kPtNoJoin && h >= p.joinCount) errs.add('ptHJoin[$i]');
    }
    // entrancePt, pavementPt and entranceNode are V11's (read guarded there).
    if (errs.isEmpty) return true;
    bad(SiteInvariant.v6Nodes, 'index out of range: ${errs.join(', ')}');
    return false;
  }

  // ---- shared geometry helpers -----------------------------------------------

  late final List<Float64List> _poly = [
    for (var k = 0; k < p.segCount; k++) _polyOf(k)
  ];

  Float64List _polyOf(int k) {
    final n = p.segPointCount(k);
    final xy = Float64List(2 * n);
    for (var i = 0; i < n; i++) {
      final pt = p.segPoint(k, i);
      xy[2 * i] = p.ptE(pt);
      xy[2 * i + 1] = p.ptN(pt);
    }
    return xy;
  }

  double _len(int k) {
    final xy = _poly[k];
    var len = 0.0;
    for (var i = 2; i < xy.length; i += 2) {
      final de = xy[i] - xy[i - 2], dn = xy[i + 1] - xy[i - 1];
      len += math.sqrt(de * de + dn * dn);
    }
    return len;
  }

  /// The point at arc [s] of segment [k] and the unit tangent there.
  (double, double, double, double) _at(int k, double s) {
    final xy = _poly[k];
    var acc = 0.0;
    final last = xy.length - 2;
    for (var i = 2; i < xy.length; i += 2) {
      final de = xy[i] - xy[i - 2], dn = xy[i + 1] - xy[i - 1];
      final l = math.sqrt(de * de + dn * dn);
      if (l <= 1e-12) continue;
      if (s <= acc + l || i == last) {
        final t = ((s - acc) / l).clamp(0.0, 1.0);
        return (xy[i - 2] + de * t, xy[i - 1] + dn * t, de / l, dn / l);
      }
      acc += l;
    }
    return (xy[0], xy[1], 0.0, 0.0);
  }

  /// Corners of an oriented rectangle centred at (ce, cn), long axis along
  /// the unit (de, dn) with half length [hl], half width [hw].
  static Float64List _rect(
      double ce, double cn, double de, double dn, double hl, double hw) {
    final pe = -dn, pn = de;
    return Float64List.fromList([
      ce - de * hl - pe * hw, cn - dn * hl - pn * hw, //
      ce + de * hl - pe * hw, cn + dn * hl - pn * hw,
      ce + de * hl + pe * hw, cn + dn * hl + pn * hw,
      ce - de * hl + pe * hw, cn - dn * hl + pn * hw,
    ]);
  }

  Float64List _stallRect(int i) {
    final (de, dn) = _unit(p.stallDirE(i), p.stallDirN(i));
    return _rect(p.stallE(i), p.stallN(i), de, dn, p.stallLenM(i) / 2,
        p.stallWidthM(i) / 2);
  }

  Float64List _bayRect(int b) {
    final (de, dn) = _unit(p.bayDirE(b), p.bayDirN(b));
    return _rect(
        p.bayE(b), p.bayN(b), de, dn, p.bayLenM(b) / 2, p.bayWidthM(b) / 2);
  }

  /// The carriageway rectangles of segment [k], one per polyline piece.
  List<Float64List> _segRects(int k) {
    final xy = _poly[k];
    final hw = p.segWidthM(k) / 2;
    return [
      for (var i = 2; i < xy.length; i += 2)
        if (_dist(xy[i - 2], xy[i - 1], xy[i], xy[i + 1]) > 1e-9)
          _pieceRect(xy[i - 2], xy[i - 1], xy[i], xy[i + 1], hw),
    ];
  }

  static Float64List _pieceRect(
      double ae, double an, double be, double bn, double hw) {
    final l = _dist(ae, an, be, bn);
    final de = (be - ae) / l, dn = (bn - an) / l;
    return _rect((ae + be) / 2, (an + bn) / 2, de, dn, l / 2, hw);
  }

  /// World corners of the envelope, or null when it is empty.
  Float64List? get _envelope {
    if (p.envX1 - p.envX0 <= _eps || p.envY1 - p.envY0 <= _eps) return null;
    final (ue, un) = _unit(p.frameUE, p.frameUN);
    final ve = -un, vn = ue;
    List<double> w(double x, double y) =>
        [p.frameE + ue * x + ve * y, p.frameN + un * x + vn * y];
    return Float64List.fromList([
      ...w(p.envX0, p.envY0),
      ...w(p.envX1, p.envY0),
      ...w(p.envX1, p.envY1),
      ...w(p.envX0, p.envY1),
    ]);
  }

  /// A pave ring's world corners.
  Float64List _paveRing(int q) {
    final a = p.paveStart(q), b = p.paveStart(q + 1);
    final xy = Float64List(2 * (b - a));
    for (var i = a; i < b; i++) {
      final pt = p.pavePt(i);
      xy[2 * (i - a)] = p.ptE(pt);
      xy[2 * (i - a) + 1] = p.ptN(pt);
    }
    return xy;
  }

  static (double, double) _unit(double e, double n) {
    final l = math.sqrt(e * e + n * n);
    return l <= 1e-12 ? (0.0, 0.0) : (e / l, n / l);
  }

  static double _dist(double ae, double an, double be, double bn) {
    final de = be - ae, dn = bn - an;
    return math.sqrt(de * de + dn * dn);
  }

  /// Whether two convex polygons overlap by more than [tol] (separating
  /// axes over both polygons' edge normals).
  static bool _overlap(Float64List a, Float64List b, double tol) {
    bool separated(Float64List poly) {
      final n = poly.length ~/ 2;
      for (var i = 0; i < n; i++) {
        final j = (i + 1) % n;
        final ex = poly[2 * j] - poly[2 * i], ey = poly[2 * j + 1] - poly[2 * i + 1];
        final l = math.sqrt(ex * ex + ey * ey);
        if (l <= 1e-12) continue;
        final ax = -ey / l, ay = ex / l;
        var minA = double.infinity, maxA = double.negativeInfinity;
        for (var k = 0; k < a.length; k += 2) {
          final d = a[k] * ax + a[k + 1] * ay;
          minA = math.min(minA, d);
          maxA = math.max(maxA, d);
        }
        var minB = double.infinity, maxB = double.negativeInfinity;
        for (var k = 0; k < b.length; k += 2) {
          final d = b[k] * ax + b[k + 1] * ay;
          minB = math.min(minB, d);
          maxB = math.max(maxB, d);
        }
        if (maxA <= minB + tol || maxB <= minA + tol) return true;
      }
      return false;
    }

    return !separated(a) && !separated(b);
  }

  /// Whether every corner of [inner] lies in the convex CCW ring [ring]
  /// (within [tol]).
  static bool _inside(Float64List inner, Float64List ring, double tol) {
    final n = ring.length ~/ 2;
    for (var k = 0; k < inner.length; k += 2) {
      for (var i = 0; i < n; i++) {
        final j = (i + 1) % n;
        final ex = ring[2 * j] - ring[2 * i], ey = ring[2 * j + 1] - ring[2 * i + 1];
        final l = math.sqrt(ex * ex + ey * ey);
        if (l <= 1e-12) continue;
        final cross =
            (ex * (inner[k + 1] - ring[2 * i + 1]) - ey * (inner[k] - ring[2 * i])) / l;
        if (cross < -tol) return false;
      }
    }
    return true;
  }

  bool _insideSomePave(Float64List rect) {
    for (var q = 0; q < p.paveCount; q++) {
      final ring = _paveRing(q);
      if (ring.length >= 6 && _inside(rect, ring, _touchM)) return true;
    }
    return false;
  }

  /// Site-path distance (along segments, either way) from node [from].
  Float64List _pathDist(int from) {
    final n = p.nodeCount;
    final d = Float64List(n)..fillRange(0, n, double.infinity);
    final done = Uint8List(n);
    d[from] = 0;
    for (var it = 0; it < n; it++) {
      var u = -1;
      var best = double.infinity;
      for (var i = 0; i < n; i++) {
        if (done[i] == 0 && d[i] < best) {
          best = d[i];
          u = i;
        }
      }
      if (u < 0) break;
      done[u] = 1;
      for (var k = 0; k < p.segCount; k++) {
        final a = p.segFrom(k), b = p.segTo(k);
        if (a != u && b != u) continue;
        final w = a == u ? b : a;
        final nd = d[u] + _len(k);
        if (nd < d[w]) d[w] = nd;
      }
    }
    return d;
  }

  // ---- V1 --------------------------------------------------------------------

  bool _inWindow(int piece, double lo, double hi) {
    final kw = g!.kerbWindows;
    if (piece < 0 || piece >= kw.pieceCount) return false;
    for (var k = kw.start[piece]; k < kw.start[piece + 1]; k++) {
      if (lo >= kw.lo[k] - _eps && hi <= kw.hi[k] + _eps) return true;
    }
    return false;
  }

  void _v1() {
    final graph = g!;
    final home = p.program == SiteProgram.homeDriveway;
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinIsCut(j)) continue;
      final piece = p.joinPiece(j);
      final s = p.joinRoadS(j), m = p.joinCutHalfM(j);
      if (piece < 0 || piece >= graph.pieceCount) {
        bad(SiteInvariant.v1Window, 'cut join $j has no piece');
        continue;
      }
      if (!_inWindow(piece, s - m, s + m)) {
        bad(SiteInvariant.v1Window,
            'cut join $j: [$s ± $m] lies in no kerb window of piece $piece');
      }
      final dirs = p.joinDirs(j);
      final margin = kHomeSwingMarginM - kJoinWindowClearM;
      if (home) {
        if (dirs & RoadGraph.forwardBit != 0 &&
            !_inWindow(piece, s - margin, s + m)) {
          bad(SiteInvariant.v1Window,
              'home join $j: no ${kHomeSwingMarginM}m swing margin upstream '
              '(forward) in the kerb windows');
        }
        if (dirs & RoadGraph.backwardBit != 0 &&
            !_inWindow(piece, s - m, s + margin)) {
          bad(SiteInvariant.v1Window,
              'home join $j: no ${kHomeSwingMarginM}m swing margin upstream '
              '(backward) in the kerb windows');
        }
      }
      for (var i = 0; i < spans.length; i++) {
        final sp = spans[i];
        for (final (e, bit) in [
          (graph.pieceFwdEdge[piece], RoadGraph.forwardBit),
          (graph.pieceBwdEdge[piece], RoadGraph.backwardBit),
        ]) {
          if (e < 0 || e >= sp.laneS0.length) continue;
          final t = sp.travelArc(e, s);
          if (t - m < sp.laneS0[e] + kJoinWindowClearM - 1e-3 ||
              t + m > sp.laneS1[e] - kJoinWindowClearM + 1e-3) {
            bad(SiteInvariant.v1Window,
                'cut join $j: [$t ± $m] leaves lane span $i of edge $e '
                '[${sp.laneS0[e]} + 6, ${sp.laneS1[e]} − 6]');
          }
          if (home && dirs & bit != 0 &&
              t - kHomeSwingMarginM < sp.laneS0[e] - 1e-3) {
            bad(SiteInvariant.v1Window,
                'home join $j: ${(t - sp.laneS0[e]).toStringAsFixed(3)} m of '
                'lane upstream on edge $e (span $i), under '
                '$kHomeSwingMarginM m');
          }
        }
      }
    }
  }

  // ---- V2 --------------------------------------------------------------------

  void _v2() {
    final graph = g!;
    for (var j = 0; j < p.joinCount; j++) {
      final piece = p.joinPiece(j);
      if (piece < 0 || piece >= graph.pieceCount) continue;
      final road = graph.roads[graph.pieceRoad[piece]];
      final want = joinDirsFor(road, p.joinRight(j));
      if (p.joinDirs(j) != want) {
        bad(SiteInvariant.v2SideAndDirections,
            'join $j dirs ${p.joinDirs(j)} != joinDirsFor(road, '
            'right ${p.joinRight(j)}) $want');
      }
    }
  }

  // ---- V3 --------------------------------------------------------------------

  void _v3() {
    final graph = g!;
    final lot = p.graphLot;
    if (lot >= 0 && p.joinCount > 0 && p.joinSlot(0) != 0) {
      bad(SiteInvariant.v3OneSource, 'join 0 is slot ${p.joinSlot(0)}, not 0');
    }
    for (var j = 0; j < p.joinCount; j++) {
      final ref = p.joinRef(j);
      if (lot >= 0) {
        final want = graph.joinRefOf(lot, p.joinSlot(j));
        if (ref != want) {
          bad(SiteInvariant.v3OneSource,
              'join $j ref $ref != joinRefOf(lot $lot, slot ${p.joinSlot(j)}) '
              '$want');
          continue;
        }
      } else if (ref != kJoinRefNone) {
        bad(SiteInvariant.v3OneSource,
            'join $j of a site that is no graph lot names graph join $ref');
        continue;
      }
      if (ref == kJoinRefNone) continue;
      final slot = graph.joinOfRef(ref);
      if (slot == null) {
        bad(SiteInvariant.v3OneSource, 'join $j ref $ref resolves to nothing');
        continue;
      }
      final diffs = <String>[
        if (p.joinPiece(j) != slot.piece) 'piece ${p.joinPiece(j)}/${slot.piece}',
        if (p.joinRoadS(j) != slot.s) 's ${p.joinRoadS(j)}/${slot.s}',
        if (p.joinRight(j) != slot.right) 'right',
        if (p.joinDirs(j) != slot.dirs) 'dirs ${p.joinDirs(j)}/${slot.dirs}',
      ];
      final kn = p.joinKerbNode(j);
      if (kn >= 0 && (p.nodeE(kn) != slot.kerbE || p.nodeN(kn) != slot.kerbN)) {
        diffs.add('kerb point (${p.nodeE(kn)}, ${p.nodeN(kn)})/'
            '(${slot.kerbE}, ${slot.kerbN})');
      }
      if (diffs.isNotEmpty) {
        bad(SiteInvariant.v3OneSource,
            'join $j differs from its slot (ref $ref): ${diffs.join(', ')}');
      }
    }
  }

  // ---- V4 --------------------------------------------------------------------

  void _v4() {
    final network = p.hasNetwork;
    if (network != (p.segCount > 0)) {
      bad(SiteInvariant.v4Roles,
          'kPlanNetwork ${network ? 'set' : 'clear'} with ${p.segCount} segments');
    }
    final kerbProgram =
        p.program == SiteProgram.kerbOnly || p.program == SiteProgram.none;
    if (kerbProgram == network) {
      bad(SiteInvariant.v4Roles,
          'program ${p.program.name} with${network ? '' : 'out'} a network');
    }
    if (!network) {
      if (p.joinCount != 1 ||
          p.joinKind(0) != SiteJoinKind.kerbside ||
          p.nodeCount != 0 ||
          p.stallCount != 0 ||
          p.bayCount != 0) {
        bad(SiteInvariant.v4Roles,
            'a kerbside plan has exactly one kerbside join and no nodes, '
            'segments, stalls or bays');
      }
      return;
    }
    // §2.4 asks a network plan for ≥ 1 in-capable and ≥ 1 out-capable CUT
    // join — not that EVERY join be a cut. A kerbside join alongside is a real
    // plan shape: R8's alley car park keeps slot 0 as the frontage, kerbside
    // and uncut, so its street wall stays an unbroken run of shopfronts, and
    // drives in and out through the alley cut on slot 3. It carries no kerb
    // node or throat, so V5 passes it over; it is no lane, so V7 and V13 do
    // too; and it contributes to neither role below, so a plan of kerbside
    // joins alone is still rejected (no in-capable and no out-capable cut).
    var canIn = false, canOut = false;
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinIsCut(j)) continue;
      canIn |= p.joinCanIn(j);
      canOut |= p.joinCanOut(j);
    }
    if (!canIn) bad(SiteInvariant.v4Roles, 'no in-capable cut join');
    if (!canOut) bad(SiteInvariant.v4Roles, 'no out-capable cut join');
    for (var a = 0; a < p.joinCount; a++) {
      for (var b = a + 1; b < p.joinCount; b++) {
        if (!p.joinIsCut(a) || !p.joinIsCut(b)) continue;
        if (p.joinPiece(a) != p.joinPiece(b)) continue;
        // A 6 m gap between the cuts' EDGES, not their centres.
        final gap = (p.joinRoadS(a) - p.joinRoadS(b)).abs() -
            p.joinCutHalfM(a) -
            p.joinCutHalfM(b);
        if (gap < kJoinWindowClearM - _eps) {
          bad(SiteInvariant.v4Roles,
              'cuts $a and $b on piece ${p.joinPiece(a)} overlap or lie '
              '${gap.toStringAsFixed(3)} m apart edge to edge, under '
              '$kJoinWindowClearM m');
        }
      }
    }
  }

  // ---- V5 --------------------------------------------------------------------

  void _v5() {
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinIsCut(j)) continue;
      final kn = p.joinKerbNode(j), t = p.joinThroatSeg(j);
      if (kn < 0 || t < 0) {
        bad(SiteInvariant.v5Throat, 'cut join $j has no kerb node or throat');
        continue;
      }
      if (p.nodeFlags(kn) & kNodeKerb == 0) {
        bad(SiteInvariant.v5Throat, 'join $j kerb node $kn lacks kNodeKerb');
      }
      if (_degree[kn] != 1) {
        bad(SiteInvariant.v5Throat,
            'join $j kerb node $kn has site degree ${_degree[kn]}');
      }
      final fromKerb = p.segFrom(t) == kn;
      if (!fromKerb && p.segTo(t) != kn) {
        bad(SiteInvariant.v5Throat, 'join $j throat $t does not leave its kerb');
        continue;
      }
      if (p.segFlags(t) & kSegThroat == 0) {
        bad(SiteInvariant.v5Throat, 'join $j throat $t lacks kSegThroat');
      }
      // The polyline from the kerb.
      final xy = _poly[t];
      final n = xy.length ~/ 2;
      double px(int i) => fromKerb ? xy[2 * i] : xy[2 * (n - 1 - i)];
      double py(int i) => fromKerb ? xy[2 * i + 1] : xy[2 * (n - 1 - i) + 1];
      final ke = px(0), kN = py(0), fe = px(n - 1), fn = py(n - 1);
      final chord = _dist(ke, kN, fe, fn);
      final len = _len(t);
      if (len < kThroatMinM - _eps) {
        bad(SiteInvariant.v5Throat,
            'join $j throat is ${len.toStringAsFixed(3)} m, under $kThroatMinM');
      }
      if (chord > 1e-9) {
        final ce = (fe - ke) / chord, cn = (fn - kN) / chord;
        for (var i = 1; i < n - 1; i++) {
          final off = ((px(i) - ke) * -cn + (py(i) - kN) * ce).abs();
          if (off > kThroatStraightM + 1e-9) {
            bad(SiteInvariant.v5Throat,
                'join $j throat via $i lies ${off.toStringAsFixed(3)} m off '
                'its chord');
          }
        }
        for (var i = 1; i < n; i++) {
          final gap = _dist(px(i - 1), py(i - 1), px(i), py(i));
          if (gap > kViaMaxGapM + _eps) {
            bad(SiteInvariant.v5Throat,
                'join $j throat points ${i - 1}..$i lie '
                '${gap.toStringAsFixed(3)} m apart');
          }
        }
        final graph = g;
        final piece = p.joinPiece(j);
        if (graph != null && piece >= 0 && piece < graph.pieceCount) {
          final r = graph.pieceRoad[piece];
          final roadLen = graph.roadRecs[r].lengthM;
          final s = p.joinRoadS(j);
          final a = graph.pointAt(r, (s - 0.5).clamp(0.0, roadLen));
          final b = graph.pointAt(r, (s + 0.5).clamp(0.0, roadLen));
          final (te, tn) = _unit(b.e - a.e, b.n - a.n);
          final ne = p.joinRight(j) ? tn : -tn;
          final nn = p.joinRight(j) ? -te : te;
          if (ce * ne + cn * nn < kCos10 - 1e-9) {
            bad(SiteInvariant.v5Throat,
                'join $j throat is more than 10° off the road normal');
          }
          final cls = graph.roads[r].roadClass;
          final flagged = p.segFlags(t) & kSegCrossesPavement != 0;
          if (_hasPavement(cls) && !flagged) {
            bad(SiteInvariant.v5Throat,
                'join $j throat crosses a pavement without kSegCrossesPavement');
          } else if (!_hasPavement(cls) && flagged) {
            bad(SiteInvariant.v5Throat,
                'join $j throat carries kSegCrossesPavement on a road without one');
          }
        }
        if (p.program == SiteProgram.homeDriveway) {
          if (p.joinCutHalfM(j) < kHomeCutHalfM - _eps) {
            bad(SiteInvariant.v5Throat,
                'home join $j cut half ${p.joinCutHalfM(j)} under $kHomeCutHalfM');
          }
          final far = fromKerb ? p.segTo(t) : p.segFrom(t);
          var pads = 0;
          for (var k = 0; k < p.segCount; k++) {
            if (k == t || p.segKind(k) != SiteSegmentKind.apron) continue;
            final a = p.segFrom(k), b = p.segTo(k);
            if (a != far && b != far) continue;
            pads++;
            // One straight run: every via point AND the end node lie on the
            // throat's chord extended, beyond the throat.
            final pxy = _poly[k];
            final np = pxy.length ~/ 2;
            final farAt = a == far ? 0 : np - 1;
            for (var i = 0; i < np; i++) {
              if (i == farAt) continue;
              final ex = pxy[2 * i] - ke, ey = pxy[2 * i + 1] - kN;
              final off = (ex * -cn + ey * ce).abs();
              final along = ex * ce + ey * cn;
              if (off > kThroatStraightM + 1e-9 || along <= chord) {
                final what = i == np - 1 - farAt ? 'end' : 'via';
                bad(SiteInvariant.v5Throat,
                    'home pad $k $what lies ${off.toStringAsFixed(3)} m off '
                    'the throat axis');
              }
            }
          }
          if (pads == 0) {
            bad(SiteInvariant.v5Throat,
                'home join $j: no pad continues its throat');
          }
        }
      }
      // Nothing on the throat.
      for (var i = 0; i < p.stallCount; i++) {
        if (p.stallSeg(i) == t) {
          bad(SiteInvariant.v5Throat, 'stall $i lies on throat $t');
        }
      }
      for (var b = 0; b < p.bayCount; b++) {
        if (p.baySeg(b) == t) {
          bad(SiteInvariant.v5Throat, 'bay $b lies on throat $t');
        }
      }
      // Nothing within 7 m of the kerb along the site path.
      final d = _pathDist(kn);
      double mouth(int seg, double s) => math.min(
          d[p.segFrom(seg)] + s, d[p.segTo(seg)] + _len(seg) - s);
      for (var i = 0; i < p.stallCount; i++) {
        final m = mouth(p.stallSeg(i), p.stallS(i));
        if (m < kThroatMinM - 1e-4) {
          bad(SiteInvariant.v5Throat,
              'stall $i mouth ${m.toStringAsFixed(3)} m from join $j kerb');
        }
      }
      for (var b = 0; b < p.bayCount; b++) {
        final m = mouth(p.baySeg(b), p.bayS(b));
        if (m < kThroatMinM - 1e-4) {
          bad(SiteInvariant.v5Throat,
              'bay $b mouth ${m.toStringAsFixed(3)} m from join $j kerb');
        }
      }
      for (var nd = 0; nd < p.nodeCount; nd++) {
        final branch = _degree[nd] >= 3 || p.nodeFlags(nd) & kNodeBranch != 0;
        if (branch && d[nd] < kThroatMinM - 1e-4) {
          bad(SiteInvariant.v5Throat,
              'branch node $nd ${d[nd].toStringAsFixed(3)} m from join $j kerb');
        }
      }
    }
  }

  static bool _hasPavement(RoadClass c) => c.hasPavement;

  // ---- V6 (the rest) ---------------------------------------------------------

  void _v6() {
    if (p.nodeCount > kMaxPlanNodes) {
      bad(SiteInvariant.v6Nodes, '${p.nodeCount} nodes, over $kMaxPlanNodes');
    }
    final order = List<int>.generate(p.nodeCount, (i) => i)
      ..sort((a, b) {
        final c = p.nodeE(a).compareTo(p.nodeE(b));
        return c != 0 ? c : a.compareTo(b);
      });
    for (var i = 0; i < order.length; i++) {
      for (var k = i + 1; k < order.length; k++) {
        final a = order[i], b = order[k];
        if (p.nodeE(b) - p.nodeE(a) >= kNodeMinGapM) break;
        if (_dist(p.nodeE(a), p.nodeN(a), p.nodeE(b), p.nodeN(b)) <
            kNodeMinGapM) {
          bad(SiteInvariant.v6Nodes, 'nodes $a and $b lie within $kNodeMinGapM m');
        }
      }
    }
    for (var k = 0; k < p.segCount; k++) {
      if (_len(k) < kSegMinLenM - _eps) {
        bad(SiteInvariant.v6Nodes, 'segment $k is under $kSegMinLenM m');
      }
    }
  }

  // ---- V7 --------------------------------------------------------------------

  void _v7() {
    if (!p.hasNetwork || p.segCount == 0) return;
    final lg = SiteLaneGraph.of(p);
    if (!lg.isStronglyConnected) {
      bad(SiteInvariant.v7Connected,
          'site lanes form ${lg.componentCount} strongly connected components');
    }
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinIsCut(j)) continue;
      if (p.joinCanIn(j) && lg.inLane(j) < 0) {
        bad(SiteInvariant.v7Connected, 'in-capable join $j has no in-lane');
      }
      if (p.joinCanOut(j) && lg.outLane(j) < 0) {
        bad(SiteInvariant.v7Connected, 'out-capable join $j has no out-lane');
      }
    }
    _v7Reach(lg);
    for (var n = 0; n < p.nodeCount; n++) {
      if (_degree[n] == 0) {
        bad(SiteInvariant.v7Connected, 'isolated node $n (site degree 0)');
        continue;
      }
      if (_degree[n] != 1 || p.nodeFlags(n) & kNodeKerb != 0) continue;
      switch (p.nodeTurnKind(n)) {
        case TurnaroundKind.circle:
          if (p.nodeTurnR(n) < kTurnCircleMinM - 1e-4) {
            bad(SiteInvariant.v7Connected,
                'dead end $n: circle radius ${p.nodeTurnR(n)} under '
                '$kTurnCircleMinM');
          }
        case TurnaroundKind.hammerhead:
          if (!_hammerheadA(n) && !_hammerheadB(n)) {
            bad(SiteInvariant.v7Connected,
                'dead end $n: hammerhead is neither a clear 6 × 6 m apron nor '
                'a T end');
          }
        case TurnaroundKind.none:
          if (!_homePadEnd(n)) {
            bad(SiteInvariant.v7Connected,
                'dead end $n has no turnaround and is no home pad end');
          }
      }
    }
  }

  /// The lanes reachable from [from] over site links only (every kind but
  /// ROAD), or, with [reverse], the lanes [from] is reachable from.
  static Uint8List _reach(SiteLaneGraph lg, List<int> from,
      {bool reverse = false}) {
    final n = lg.laneCount;
    final seen = Uint8List(n);
    final stack = <int>[];
    for (final l in from) {
      if (l >= 0 && l < n && lg.isPresent(l) && seen[l] == 0) {
        seen[l] = 1;
        stack.add(l);
      }
    }
    // Reverse adjacency, built only when asked.
    List<List<int>>? into;
    if (reverse) {
      into = List.generate(n, (_) => <int>[]);
      for (var a = 0; a < n; a++) {
        for (var i = lg.linkStart[a]; i < lg.linkStart[a + 1]; i++) {
          if (lg.linkKind[i] == kSiteLinkRoad) continue;
          into[lg.linkTo[i]].add(a);
        }
      }
    }
    while (stack.isNotEmpty) {
      final a = stack.removeLast();
      if (into != null) {
        for (final b in into[a]) {
          if (seen[b] == 0 && lg.isPresent(b)) {
            seen[b] = 1;
            stack.add(b);
          }
        }
        continue;
      }
      for (var i = lg.linkStart[a]; i < lg.linkStart[a + 1]; i++) {
        if (lg.linkKind[i] == kSiteLinkRoad) continue;
        final b = lg.linkTo[i];
        if (seen[b] == 0 && lg.isPresent(b)) {
          seen[b] = 1;
          stack.add(b);
        }
      }
    }
    return seen;
  }

  /// §2.4 V7 inside the site (road links excluded): from every in-capable
  /// join's in-lane, every stall entry lane and every out-capable join's
  /// out-lane; from every stall exit lane, every out-capable join's out-lane.
  void _v7Reach(SiteLaneGraph lg) {
    final entries = <(int, int)>[]; // (stall, lane)
    final exits = <(int, int)>[];
    for (var i = 0; i < p.stallCount; i++) {
      for (final dir in const [kSiteDirFwd, kSiteDirBwd]) {
        final lane = lg.stallLane(i, dir);
        if (!lg.isPresent(lane)) continue; // absent lanes are V9's
        if (p.stallInDirs(i) & dir != 0) entries.add((i, lane));
        if (p.stallOutDirs(i) & dir != 0) exits.add((i, lane));
      }
    }
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinIsCut(j) || !p.joinCanIn(j) || lg.inLane(j) < 0) continue;
      final r = _reach(lg, [lg.inLane(j)]);
      for (var o = 0; o < p.joinCount; o++) {
        if (!p.joinIsCut(o) || !p.joinCanOut(o) || lg.outLane(o) < 0) continue;
        if (r[lg.outLane(o)] == 0) {
          bad(SiteInvariant.v7Connected,
              'join $o\'s out-lane is unreachable inside the site from join '
              '$j\'s in-lane');
        }
      }
      for (final (i, lane) in entries) {
        if (r[lane] == 0) {
          bad(SiteInvariant.v7Connected,
              'stall $i entry lane $lane is unreachable from join $j');
        }
      }
    }
    // Lanes that reach each out-lane, once per out-join.
    for (var o = 0; o < p.joinCount; o++) {
      if (!p.joinIsCut(o) || !p.joinCanOut(o) || lg.outLane(o) < 0) continue;
      final back = _reach(lg, [lg.outLane(o)], reverse: true);
      for (final (i, lane) in exits) {
        if (back[lane] == 0) {
          bad(SiteInvariant.v7Connected,
              'join $o\'s out-lane is unreachable from stall $i exit lane '
              '$lane');
        }
      }
    }
  }

  int _onlySeg(int n) {
    for (var k = 0; k < p.segCount; k++) {
      if (p.segFrom(k) == n || p.segTo(k) == n) return k;
    }
    return -1;
  }

  /// The clear paved rectangle along the last 6 m of the segment into [n].
  bool _hammerheadA(int n) {
    final k = _onlySeg(n);
    final atEnd = p.segTo(k) == n;
    final len = _len(k);
    final (ne, nn, _, _) = _at(k, atEnd ? len : 0);
    final (be, bn, _, _) = _at(k, atEnd ? math.max(0, len - 1) : math.min(len, 1));
    final (de, dn) = _unit(be - ne, bn - nn);
    final a = kHammerheadApronM;
    final rect = _rect(ne + de * a / 2, nn + dn * a / 2, de, dn, a / 2, a / 2);
    if (!_insideSomePave(rect)) return false;
    for (var i = 0; i < p.stallCount; i++) {
      if (_overlap(_stallRect(i), rect, _touchM)) return false;
    }
    for (var b = 0; b < p.bayCount; b++) {
      if (_overlap(_bayRect(b), rect, _touchM)) return false;
    }
    return true;
  }

  /// A T end: the last 3 m of a ≥ 6 m aisle stall-free, with 5.2 m of paved
  /// row depth on one side.
  bool _hammerheadB(int n) {
    final k = _onlySeg(n);
    if (p.segKind(k) != SiteSegmentKind.aisle) return false;
    final len = _len(k);
    if (len < kTEndAisleMinM - _eps) return false;
    final atEnd = p.segTo(k) == n;
    final t0 = atEnd ? len - kTEndClearM : 0.0;
    final t1 = atEnd ? len : kTEndClearM;
    for (var i = 0; i < p.stallCount; i++) {
      if (p.stallSeg(i) != k) continue;
      final h = p.stallWidthM(i) / 2;
      if (p.stallS(i) + h > t0 + _eps && p.stallS(i) - h < t1 - _eps) {
        return false;
      }
    }
    final (me, mn, te, tn) = _at(k, (t0 + t1) / 2);
    final hw = p.segWidthM(k) / 2;
    for (final side in const [-1.0, 1.0]) {
      final off = hw + kTEndRowDepthM / 2;
      final pe = -tn * side, pn = te * side;
      final rect = _rect(me + pe * off, mn + pn * off, te, tn,
          kTEndClearM / 2, kTEndRowDepthM / 2);
      if (_insideSomePave(rect)) return true;
    }
    return false;
  }

  /// §2.4 V7's one exception: the `to` node of a home plan's apron whose
  /// stalls are all `inline`, flagged a dead end, with no turnaround.
  bool _homePadEnd(int n) {
    if (p.program != SiteProgram.homeDriveway) return false;
    if (p.nodeFlags(n) & kNodeDeadEnd == 0) return false;
    final k = _onlySeg(n);
    if (p.segKind(k) != SiteSegmentKind.apron || p.segTo(k) != n) return false;
    var stalls = 0;
    for (var i = 0; i < p.stallCount; i++) {
      if (p.stallSeg(i) != k) continue;
      if (p.stallAngle(i) != StallAngle.inline) return false;
      stalls++;
    }
    return stalls > 0;
  }

  // ---- V8 --------------------------------------------------------------------

  void _v8() {
    for (var k = 0; k < p.segCount; k++) {
      final w = p.segWidthM(k);
      final mode = p.segLaneMode(k);
      if (w < kSegMinWidthM - 1e-4 || w > kSegMaxWidthM + 1e-4) {
        bad(SiteInvariant.v8Segments, 'segment $k width $w outside [3, 12]');
      }
      final v = p.segSpeedMps(k);
      if (v <= 0 || v > kSiteMaxSpeedMps + 1e-4) {
        bad(SiteInvariant.v8Segments, 'segment $k speed $v outside (0, 20 km/h]');
      }
      if (p.segMaxVehLenM(k) < kSegMinVehLenM - 1e-4) {
        bad(SiteInvariant.v8Segments,
            'segment $k segMaxVehLenM ${p.segMaxVehLenM(k)} under $kSegMinVehLenM');
      }
      var perpendicular = false, angled = false;
      for (var i = 0; i < p.stallCount; i++) {
        if (p.stallSeg(i) != k) continue;
        final a = p.stallAngle(i);
        perpendicular |= a == StallAngle.perpendicular;
        angled |= a == StallAngle.angled60 || a == StallAngle.angled45;
      }
      switch (mode) {
        case SiteLaneMode.twoWay:
          if (w < kTwoWayMinWidthM - 1e-4) {
            bad(SiteInvariant.v8Segments, 'two-way segment $k is $w m wide');
          }
          if (perpendicular && w < kTwoWayPerpendicularMinWidthM - 1e-4) {
            bad(SiteInvariant.v8Segments,
                'two-way segment $k with perpendicular stalls is $w m wide');
          }
        case SiteLaneMode.sharedSingle:
          if (w >= kTwoWayMinWidthM) {
            bad(SiteInvariant.v8Segments, 'sharedSingle segment $k is $w m wide');
          }
        case SiteLaneMode.oneWayForward:
        case SiteLaneMode.oneWayBackward:
          break;
      }
      if (angled) {
        final oneWay = mode == SiteLaneMode.oneWayForward ||
            mode == SiteLaneMode.oneWayBackward;
        if (!oneWay || w < kAngledMinWidthM - 1e-4) {
          bad(SiteInvariant.v8Segments,
              'segment $k carries angled stalls but is no one-way ≥ 3.5 m');
        }
      }
      final len = _len(k);
      if ((p.segLenM(k) - len).abs() > kSegLenTolM) {
        bad(SiteInvariant.v8Segments,
            'segment $k segLenM ${p.segLenM(k)} != polyline length $len');
      }
      if (!_throats.contains(k)) {
        final xy = _poly[k];
        for (var i = 2; i < xy.length; i += 2) {
          final gap = _dist(xy[i - 2], xy[i - 1], xy[i], xy[i + 1]);
          if (gap > kViaMaxGapM + _eps) {
            bad(SiteInvariant.v8Segments,
                'segment $k points lie ${gap.toStringAsFixed(3)} m apart');
          }
        }
      }
    }
  }

  // ---- V9 --------------------------------------------------------------------

  void _v9() {
    if (p.stallCount > kMaxPlanStalls) {
      bad(SiteInvariant.v9Stalls, '${p.stallCount} stalls, over $kMaxPlanStalls');
    }
    final rects = [for (var i = 0; i < p.stallCount; i++) _stallRect(i)];
    final env = _envelope;
    for (var i = 0; i < p.stallCount; i++) {
      final k = p.stallSeg(i);
      final len = _len(k);
      final s = p.stallS(i);
      final angle = p.stallAngle(i);
      final inD = p.stallInDirs(i), outD = p.stallOutDirs(i);
      final lanes = SiteLaneGraph.presentDirs(p.segLaneMode(k));
      if (s < -1e-4 || s > len + 1e-4) {
        bad(SiteInvariant.v9Stalls, 'stall $i mouth s $s off segment $k (0..$len)');
      }
      final (pe, pn, te, tn) = _at(k, s.clamp(0.0, len));
      final (de, dn) = _unit(p.stallDirE(i), p.stallDirN(i));
      switch (angle) {
        case StallAngle.inline:
          if (p.program != SiteProgram.homeDriveway ||
              p.segKind(k) != SiteSegmentKind.apron) {
            bad(SiteInvariant.v9Stalls,
                'inline stall $i outside a home pad (apron)');
          }
          if (inD != kSiteDirFwd) {
            bad(SiteInvariant.v9Stalls, 'inline stall $i stallInDirs $inD != {fwd}');
          }
          if (outD != kSiteDirBwd) {
            bad(SiteInvariant.v9Stalls,
                'inline stall $i stallOutDirs $outD != {bwd}');
          }
          if (de * te + dn * tn < kStallNoseDot) {
            bad(SiteInvariant.v9Stalls,
                'inline stall $i nose is not along its pad from→to');
          }
          final lateral = ((p.stallE(i) - pe) * -tn + (p.stallN(i) - pn) * te).abs();
          if (lateral > p.segWidthM(k) / 2 + 1e-4) {
            bad(SiteInvariant.v9Stalls, 'inline stall $i does not lie on its pad');
          }
        case StallAngle.parallel:
          if ((de * te + dn * tn).abs() < kStallNoseDot) {
            bad(SiteInvariant.v9Stalls, 'parallel stall $i is not along its segment');
          }
        case StallAngle.perpendicular:
        case StallAngle.angled60:
        case StallAngle.angled45:
          final (me, mn) = _unit(p.stallE(i) - pe, p.stallN(i) - pn);
          if (de * me + dn * mn < kStallNoseDot) {
            bad(SiteInvariant.v9Stalls,
                'stall $i nose does not point from its mouth into the stall');
          }
          if (inD & kSiteDirFwd != 0 &&
              s - kStallRunupHalfWidthM < kStallRunupM - 1e-4) {
            bad(SiteInvariant.v9Stalls, 'stall $i forward bit without run-up');
          }
          if (inD & kSiteDirBwd != 0 &&
              len - s - kStallRunupHalfWidthM < kStallRunupM - 1e-4) {
            bad(SiteInvariant.v9Stalls, 'stall $i backward bit without run-up');
          }
          if (angle == StallAngle.perpendicular &&
              inD == (kSiteDirFwd | kSiteDirBwd) &&
              (p.segLaneMode(k) != SiteLaneMode.twoWay ||
                  p.segWidthM(k) < kTwoWayPerpendicularMinWidthM - 1e-4)) {
            bad(SiteInvariant.v9Stalls,
                'stall $i takes both in-dirs; that needs a two-way segment >= 6 m');
          }
      }
      if (inD == 0) bad(SiteInvariant.v9Stalls, 'stall $i has no in-dir bit');
      if (inD & ~lanes != 0) {
        bad(SiteInvariant.v9Stalls, 'stall $i in-dirs $inD name absent lanes');
      }
      if (outD == 0) bad(SiteInvariant.v9Stalls, 'stall $i has no out-dir bit');
      if (outD & ~lanes != 0) {
        bad(SiteInvariant.v9Stalls, 'stall $i out-dirs $outD name absent lanes');
      }
      for (var o = i + 1; o < p.stallCount; o++) {
        if (_overlap(rects[i], rects[o], _touchM)) {
          bad(SiteInvariant.v9Stalls, 'stalls $i and $o overlap');
        }
      }
      // Its own segment is exempt only at the mouth edge: a non-inline
      // stall's mouth-edge midpoint lies on or past its carriageway's edge
      // (an angled stall's corner wedge may still cross the rectangle).
      if (angle != StallAngle.inline) {
        final hl = p.stallLenM(i) / 2;
        final me = p.stallE(i) - de * hl, mn = p.stallN(i) - dn * hl;
        final lateral = ((me - pe) * -tn + (mn - pn) * te).abs();
        if (lateral < p.segWidthM(k) / 2 - _touchM) {
          bad(SiteInvariant.v9Stalls,
              'stall $i intrudes on its own carriageway: mouth edge '
              '${lateral.toStringAsFixed(3)} m off the centreline of segment '
              '$k (half width ${p.segWidthM(k) / 2})');
        }
      }
      for (var k2 = 0; k2 < p.segCount; k2++) {
        if (k2 == k) continue;
        for (final r in _segRects(k2)) {
          if (_overlap(rects[i], r, _touchM)) {
            bad(SiteInvariant.v9Stalls, 'stall $i overlaps segment $k2');
            break;
          }
        }
      }
      if (env != null && _overlap(rects[i], env, _touchM)) {
        bad(SiteInvariant.v9Stalls, 'stall $i overlaps the envelope');
      }
    }
  }

  // ---- V10 -------------------------------------------------------------------

  void _v10() {
    for (var i = 0; i < _throats.length; i++) {
      if (_throats[i] != i) {
        bad(SiteInvariant.v10OrderAndKeys,
            'throat of cut join $i is segment ${_throats[i]}, not $i');
      }
    }
    int rank(int k) {
      if (_throats.contains(k)) return 0;
      return switch (p.segKind(k)) {
        SiteSegmentKind.aisle => 1,
        SiteSegmentKind.accessRoad || SiteSegmentKind.driveway => 2,
        SiteSegmentKind.apron => 3,
      };
    }

    final (ue, un) = _unit(p.frameUE, p.frameUN);
    (double, double) frame(int node) {
      final de = p.nodeE(node) - p.frameE, dn = p.nodeN(node) - p.frameN;
      return (de * -un + dn * ue, de * ue + dn * un); // (y, x)
    }

    for (var k = 1; k < p.segCount; k++) {
      final ra = rank(k - 1), rb = rank(k);
      if (rb < ra) {
        bad(SiteInvariant.v10OrderAndKeys,
            'segment $k (rank $rb) follows segment ${k - 1} (rank $ra)');
      } else if (ra == 1 && rb == 1) {
        final (ya, xa) = frame(p.segFrom(k - 1));
        final (yb, xb) = frame(p.segFrom(k));
        if (yb < ya - _eps || ((yb - ya).abs() <= _eps && xb < xa - _eps)) {
          bad(SiteInvariant.v10OrderAndKeys,
              'aisle $k starts before aisle ${k - 1} in (y, x)');
        }
      }
    }
    for (var i = 1; i < p.stallCount; i++) {
      final a = i - 1;
      final c1 = p.stallSeg(a).compareTo(p.stallSeg(i));
      final c2 = p.stallS(a).compareTo(p.stallS(i));
      final c3 = p.stallSide(a).compareTo(p.stallSide(i));
      final ordered = c1 < 0 || (c1 == 0 && (c2 < 0 || (c2 == 0 && c3 < 0)));
      if (!ordered) {
        bad(SiteInvariant.v10OrderAndKeys,
            'stalls $a and $i are not strictly ordered by (seg, s, side)');
      }
    }
    final n = p.stallCount;
    final seen = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final idx = p.stallKeyIdx(i);
      if (idx < 0 || idx >= n || seen[idx] == 1) {
        bad(SiteInvariant.v10OrderAndKeys, 'stallKeyIdx is no permutation');
        return;
      }
      seen[idx] = 1;
      if (p.stallKey(idx) != p.stallKeySorted(i)) {
        bad(SiteInvariant.v10OrderAndKeys,
            'stallKeySorted[$i] != stallKey[stallKeyIdx[$i]]');
      }
      if (i > 0 && p.stallKeySorted(i) <= p.stallKeySorted(i - 1)) {
        bad(SiteInvariant.v10OrderAndKeys, 'stall keys are not unique and sorted');
      }
    }
  }

  // ---- V11 -------------------------------------------------------------------

  void _v11() {
    final ep = p.entrancePt, pp = p.pavementPt, en = p.entranceNode;
    final hasDoor = ep >= 0 && ep < p.pointCount;
    final hasPavement = pp >= 0 && pp < p.pointCount;
    if (!hasDoor) {
      bad(SiteInvariant.v11Entrance, 'no entrance: entrancePt $ep');
    }
    if (!hasPavement) {
      bad(SiteInvariant.v11Entrance, 'no pavement point: pavementPt $pp');
    }
    if (en < -1 || en >= p.nodeCount) {
      bad(SiteInvariant.v11Entrance, 'entranceNode $en out of range');
      return;
    }
    if (p.hasNetwork) {
      if (en < 0) {
        bad(SiteInvariant.v11Entrance, 'network plan without an entrance node');
      } else if (hasDoor) {
        final d = _dist(p.ptE(ep), p.ptN(ep), p.nodeE(en), p.nodeN(en));
        if (d > kEntranceMaxM + _eps) {
          bad(SiteInvariant.v11Entrance,
              'door ${d.toStringAsFixed(2)} m from entrance node $en');
        }
      }
      return;
    }
    if (p.entranceNode != -1) {
      bad(SiteInvariant.v11Entrance, 'kerbside plan with an entrance node');
    }
    final graph = g;
    if (graph != null &&
        hasPavement &&
        p.joinCount > 0 &&
        p.joinRef(0) != kJoinRefNone) {
      final slot = graph.joinOfRef(p.joinRef(0));
      if (slot != null) {
        final d = _dist(p.ptE(pp), p.ptN(pp), slot.kerbE, slot.kerbN);
        if (d > kPavementPointMaxM + _eps) {
          bad(SiteInvariant.v11Entrance,
              'pavement point ${d.toStringAsFixed(2)} m from slot 0 kerb');
        }
      }
    }
  }

  // ---- V12 -------------------------------------------------------------------

  void _v12() {
    final want = p.chunk.revisionOf(p.site);
    if (p.rev == 0 || p.rev != want) {
      bad(SiteInvariant.v12Revision, 'rev ${p.rev} != content hash $want');
    }
  }

  // ---- V13 -------------------------------------------------------------------

  void _v13() {
    final trucks = p.admitsTrucks;
    if (!trucks) {
      if (p.truckTurnRadiusM != 0) {
        bad(SiteInvariant.v13Reserved,
            'truckTurnRadiusM ${p.truckTurnRadiusM} without kPlanAdmitsTrucks');
      }
      return;
    }
    if (p.truckTurnRadiusM < kTruckTurnMinM - 1e-4) {
      bad(SiteInvariant.v13Reserved,
          'truckTurnRadiusM ${p.truckTurnRadiusM} under $kTruckTurnMinM');
    }
    if (!_truckPath()) {
      bad(SiteInvariant.v13Reserved,
          'kPlanAdmitsTrucks without a directed in→bay→out truck path (width '
          '≥ 3.5 m, vehicles ≥ 12 m, U-turns and bay reversals only at '
          '≥ 12.5 m circles)');
    }
  }

  /// Whether a truck can drive in by some in-lane, serve some bay and leave
  /// by some out-lane, over the [SiteLaneGraph] lanes of truck segments
  /// (width ≥ 3.5 m, `segMaxVehLenM` ≥ 12):
  /// - movements between truck lanes as §2.5 allows them;
  /// - a U-turn only at a `circle` of radius ≥ 12.5 m;
  /// - a bay on segment k is entered forward from a reachable lane L of k.
  ///   Leaving it, the truck reverses out: onto EITHER lane of k when an end
  ///   node of k is such a circle (the reversal swings into the circle),
  ///   otherwise it goes on along L.
  bool _truckPath() {
    if (p.segCount == 0 || p.bayCount == 0) return false;
    final lg = SiteLaneGraph.of(p);
    final n = lg.laneCount;
    bool truckSeg(int k) =>
        p.segWidthM(k) >= kTruckMinWidthM - 1e-4 &&
        p.segMaxVehLenM(k) >= kTruckMinVehLenM - 1e-4;
    bool bigCircle(int node) =>
        p.nodeTurnKind(node) == TurnaroundKind.circle &&
        p.nodeTurnR(node) >= kTruckTurnMinM - 1e-4;
    bool truckLane(int l) => lg.isPresent(l) && truckSeg(SiteLaneGraph.segOf(l));
    bool usable(int i) {
      final kind = lg.linkKind[i];
      if (kind == kSiteLinkMovement) return true;
      if (kind == kSiteLinkUTurn) return bigCircle(lg.linkVia[i]);
      return false; // inline-stall and road links carry no truck
    }

    Uint8List walk(List<int> from, {required bool reverse}) {
      final seen = Uint8List(n);
      final stack = <int>[];
      for (final l in from) {
        if (truckLane(l) && seen[l] == 0) {
          seen[l] = 1;
          stack.add(l);
        }
      }
      while (stack.isNotEmpty) {
        final a = stack.removeLast();
        if (reverse) {
          for (var x = 0; x < n; x++) {
            if (seen[x] == 1 || !truckLane(x)) continue;
            for (var i = lg.linkStart[x]; i < lg.linkStart[x + 1]; i++) {
              if (lg.linkTo[i] == a && usable(i)) {
                seen[x] = 1;
                stack.add(x);
                break;
              }
            }
          }
          continue;
        }
        for (var i = lg.linkStart[a]; i < lg.linkStart[a + 1]; i++) {
          final b = lg.linkTo[i];
          if (seen[b] == 0 && truckLane(b) && usable(i)) {
            seen[b] = 1;
            stack.add(b);
          }
        }
      }
      return seen;
    }

    final ins = <int>[], outs = <int>[];
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinIsCut(j)) continue;
      if (p.joinCanIn(j) && lg.inLane(j) >= 0) ins.add(lg.inLane(j));
      if (p.joinCanOut(j) && lg.outLane(j) >= 0) outs.add(lg.outLane(j));
    }
    final fromIn = walk(ins, reverse: false);
    final toOut = walk(outs, reverse: true);
    for (var b = 0; b < p.bayCount; b++) {
      final k = p.baySeg(b);
      if (!truckSeg(k)) continue;
      final swing = bigCircle(p.segFrom(k)) || bigCircle(p.segTo(k));
      for (final l in [2 * k, 2 * k + 1]) {
        if (l >= n || fromIn[l] == 0) continue;
        if (toOut[l] == 1) return true;
        final r = SiteLaneGraph.reverseOf(l);
        if (swing && r < n && toOut[r] == 1) return true;
      }
    }
    return false;
  }

  // ---- geometry --------------------------------------------------------------

  void _geometry() {
    final env = _envelope;
    for (var q = 0; q < p.paveCount; q++) {
      final ring = _paveRing(q);
      final n = ring.length ~/ 2;
      if (n < 3) {
        bad(SiteInvariant.geometry, 'pave $q has $n points');
        continue;
      }
      var convex = true;
      for (var i = 0; i < n; i++) {
        final a = i, b = (i + 1) % n, c = (i + 2) % n;
        final cross = (ring[2 * b] - ring[2 * a]) * (ring[2 * c + 1] - ring[2 * b + 1]) -
            (ring[2 * b + 1] - ring[2 * a + 1]) * (ring[2 * c] - ring[2 * b]);
        if (cross < -1e-9) convex = false;
      }
      if (!convex) {
        bad(SiteInvariant.geometry, 'pave $q is not a convex CCW ring');
      }
      if (env != null && _overlap(ring, env, _touchM)) {
        bad(SiteInvariant.geometry, 'pave $q overlaps the envelope');
      }
    }
  }
}
