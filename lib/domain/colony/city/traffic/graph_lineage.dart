// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What became of a network's roads in the next network, and of the routes
/// planned on them (docs/plans/agent-traffic.md §3.9).
///
/// Routes never change for traffic (§4.6). Only a network edit may touch a
/// planned route, and only as far as the edit forces. A road drawn across a
/// route splits the road it crosses — `r5` becomes `r5x0` and `r5x1`,
/// numbered along it — and the route is carried onto the pieces, passing
/// STRAIGHT THROUGH the new junction in the lane it was already in: trips
/// already planned do not use the new road, and only new trips see it. A
/// route is planned afresh only when the edit made it impossible — a road
/// on it gone, reversed or re-laid, a movement it makes no longer allowed,
/// or no lanes left that drive it.
///
/// Lineage runs through road ids and arcs, never through graph numbers,
/// which are dense per build and mean nothing across two builds. A new road
/// is a CHILD of an old one when its id descends from the old id by the
/// layout's split naming (`<id>x<i>`, nested) and it lies on the old road's
/// line: both its ends within [kOnLineM] of the old polyline, in order, and
/// its length the length of the arc between them. Adjust Roads also lays a
/// road under a descendant id (`CityLayout.childIdFor`), but on new
/// geometry: that is not a child but a new road, and every route over the
/// old one re-plans. A road that kept its id (an upgrade, a reversal) is
/// its own child.
///
/// An [EdgeLineage] holds the OLD lane graph — and through it the old
/// `RoadGraph` — for the one rebuild it serves, and is dropped after. It is
/// built on an edit and may allocate; remapping a route allocates only when
/// a road was re-laid under the vehicle.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../road_graph.dart';
import '../spatial_index.dart';
import 'lane_graph.dart';
import 'lane_planner.dart';

/// How far off an old road's line a new road's end, or a vehicle's place on
/// a re-laid road, may lie and still be on it. Decimation keeps a road
/// within 0.15 m of its samples, and a cut lies exactly on the line.
const double kOnLineM = 0.5;

/// The widest gap between two pieces of one road that a route crosses as
/// though nothing were there: the sliver a split drops (under 8 m, a car's
/// length) plus slack — and only where the pieces either side share a node.
const double kSliverBridgeM = 8.5;

/// How far a child's length may differ from the arc it covers on its
/// parent: re-sampling a decimated piece moves its length by centimetres.
const double kChildLengthSlackM = 1.0;
const double kChildLengthSlackShare = 0.005;

/// What a remap did with a vehicle.
enum RemapStatus {
  /// The route was carried onto the new network, perhaps with some lanes
  /// re-chosen (`RouteRemapper.lanesRepaired`).
  kept,

  /// The vehicle is still on the network, but its route is impossible: it
  /// holds at the end of its edge and re-plans from where it is.
  replan,

  /// Where the vehicle is no longer exists.
  despawn,
}

/// Each old road's children in the new network, in arc order, and the new
/// roads re-laid in its place.
class EdgeLineage {
  EdgeLineage._(
    this.from,
    this.to,
    this.childStart,
    this.childRoad,
    this.childC0,
    this.childC1,
    this.childScale,
    this.relaidStart,
    this.relaidRoad,
  );

  /// The lineage of [from]'s roads in [to].
  factory EdgeLineage(LaneGraph from, LaneGraph to) {
    final og = from.graph, ng = to.graph;
    final nOld = og.roadCount, nNew = ng.roadCount;
    final ancestor = Int32List(nNew)..fillRange(0, nNew, -1);
    final isChild = Uint8List(nNew);
    final c0 = Float64List(nNew), c1 = Float64List(nNew);
    final nChild = Int32List(nOld + 1), nRelaid = Int32List(nOld + 1);
    for (var r = 0; r < nNew; r++) {
      final a = _ancestorOf(og, ng.roads[r].id);
      if (a < 0) continue;
      ancestor[r] = a;
      final span = _onLine(og.roadRecs[a], ng.roadRecs[r]);
      if (span == null) {
        nRelaid[a + 1]++;
        continue;
      }
      isChild[r] = 1;
      c0[r] = span.c0;
      c1[r] = span.c1;
      nChild[a + 1]++;
    }
    for (var a = 0; a < nOld; a++) {
      nChild[a + 1] += nChild[a];
      nRelaid[a + 1] += nRelaid[a];
    }
    final childRoad = Int32List(nChild[nOld]);
    final childC0 = Float64List(nChild[nOld]);
    final childC1 = Float64List(nChild[nOld]);
    final childScale = Float64List(nChild[nOld]);
    final relaidRoad = Int32List(nRelaid[nOld]);
    final fillC = Int32List.fromList(nChild.sublist(0, nOld));
    final fillR = Int32List.fromList(nRelaid.sublist(0, nOld));
    for (var r = 0; r < nNew; r++) {
      final a = ancestor[r];
      if (a < 0) continue;
      if (isChild[r] == 0) {
        relaidRoad[fillR[a]++] = r;
        continue;
      }
      final k = fillC[a]++;
      childRoad[k] = r;
      childC0[k] = c0[r];
      childC1[k] = c1[r];
      final len = ng.roadRecs[r].lengthM;
      childScale[k] = len > 0 ? (c1[r] - c0[r]) / len : 1.0;
    }
    // Each old road's children in arc order (ties by road number): a
    // handful each, so an insertion sort.
    for (var a = 0; a < nOld; a++) {
      for (var i = nChild[a] + 1; i < nChild[a + 1]; i++) {
        for (var j = i;
            j > nChild[a] &&
                (childC0[j] < childC0[j - 1] ||
                    (childC0[j] == childC0[j - 1] &&
                        childRoad[j] < childRoad[j - 1]));
            j--) {
          _swapI(childRoad, j);
          _swapD(childC0, j);
          _swapD(childC1, j);
          _swapD(childScale, j);
        }
      }
    }
    return EdgeLineage._(from, to, nChild, childRoad, childC0, childC1,
        childScale, nRelaid, relaidRoad);
  }

  /// The old network and the new.
  final LaneGraph from, to;

  /// Old road r's children are entries `childStart[r] .. childStart[r + 1]
  /// − 1`, in arc order: each a new road number, the arc range it covers on
  /// the old road, and old metres per new metre along it.
  final Int32List childStart, childRoad;
  final Float64List childC0, childC1, childScale;

  /// Old road r's re-laid successors — new roads under a descendant id that
  /// do not lie on its line — are `relaidRoad[relaidStart[r] ..
  /// relaidStart[r + 1] − 1]`.
  final Int32List relaidStart, relaidRoad;

  /// The nearest ancestor of new road id [id] among [og]'s roads: itself,
  /// else the id cut at each `x` from the last. −1 for none.
  static int _ancestorOf(RoadGraph og, String id) {
    final self = og.roadNoOf(id);
    if (self != null) return self;
    for (var i = id.lastIndexOf('x'); i > 0; i = id.lastIndexOf('x', i - 1)) {
      final a = og.roadNoOf(id.substring(0, i));
      if (a != null) return a;
    }
    return -1;
  }

  /// The arc range [now] covers on [old]'s line, or null when it does not
  /// lie on it.
  static ({double c0, double c1})? _onLine(IndexedRoad old, IndexedRoad now) {
    if (identical(old.e, now.e) && identical(old.n, now.n)) {
      return (c0: 0.0, c1: old.lengthM);
    }
    final last = now.sampleCount - 1;
    if (last < 1) return null;
    final a = project(old, now.e[0], now.n[0]);
    final b = project(old, now.e[last], now.n[last]);
    if (a.d > kOnLineM || b.d > kOnLineM || b.s <= a.s) return null;
    final len = now.lengthM;
    final slack = kChildLengthSlackM + kChildLengthSlackShare * len;
    if (((b.s - a.s) - len).abs() > slack) return null;
    return (c0: a.s, c1: b.s);
  }

  /// The point of [rec]'s line nearest (pe, pn): how far it is, its arc,
  /// and the segment it lies on (1-based: from sample `seg − 1`).
  static ({double d, double s, int seg}) project(
      IndexedRoad rec, double pe, double pn) {
    var bestD = double.infinity, bestS = 0.0;
    var bestSeg = 1;
    for (var i = 1; i < rec.sampleCount; i++) {
      final ae = rec.e[i - 1], an = rec.n[i - 1];
      final ex = rec.e[i] - ae, en = rec.n[i] - an;
      final ll = ex * ex + en * en;
      var u = ll <= 1e-18 ? 0.0 : ((pe - ae) * ex + (pn - an) * en) / ll;
      if (u < 0) {
        u = 0;
      } else if (u > 1) {
        u = 1;
      }
      final qe = ae + ex * u - pe, qn = an + en * u - pn;
      final d = math.sqrt(qe * qe + qn * qn);
      if (d < bestD) {
        bestD = d;
        bestS = rec.cum[i - 1] + (rec.cum[i] - rec.cum[i - 1]) * u;
        bestSeg = i;
      }
    }
    return (d: bestD, s: bestS, seg: bestSeg);
  }

  static void _swapI(Int32List a, int j) {
    final t = a[j];
    a[j] = a[j - 1];
    a[j - 1] = t;
  }

  static void _swapD(Float64List a, int j) {
    final t = a[j];
    a[j] = a[j - 1];
    a[j - 1] = t;
  }
}

/// Carries routes planned on the old network onto the new (§3.9).
///
/// A route is the arena's `[firstLane, c₁, …, c_n]` in the OLD graph's ids.
/// The vehicle is on route edge [at] — edge 0 is `firstLane`'s, edge i the
/// edge connector i leads onto — either on its lane, [s] metres along it, or
/// still on the connector leading into it. Its stop is [destS] metres
/// (travel arc) along the route's last edge.
///
/// The result is the REMAINING route from the vehicle on, in the new
/// graph's ids, in [route]: its first lane the lane the vehicle is on — or,
/// from a connector, the lane it lands in (it keeps its old connector's
/// geometry until it hands over, which is the owner's limbo table's
/// business). [lane] and [laneS] place the vehicle for a re-plan too, and
/// [stopS] is the new stop.
class RouteRemapper {
  RouteRemapper(this.lineage);

  final EdgeLineage lineage;
  final LanePlanner _planner = LanePlanner();

  Int32List _edges = Int32List(64);
  Int32List _want = Int32List(64);
  int _n = 0;

  /// The pieces of the chain being gathered, in travel order, and the
  /// child entry each belongs to.
  Int32List _pc = Int32List(16);
  Int32List _pk = Int32List(16);
  int _nPc = 0;

  int _placeEdge = -1;
  double _placeT = 0;
  double _lastT = 0;

  /// A vehicle strictly inside its edge, and a range never empty: at a cut,
  /// "the piece ahead" is then never in doubt.
  static const double _eps = 1e-3;

  // ---- The result -----------------------------------------------------------

  /// The remaining route in the new graph, `[firstLane, c₁, …]`.
  Int32List route = Int32List(64);
  int routeLength = 0;

  /// The vehicle's lane on the new network, and metres along it (0 when it
  /// lands there from a connector).
  int lane = -1;
  double laneS = 0;

  /// The stop on the new route's last edge, travel metres.
  double stopS = 0;

  /// Whether a connector the old route relied on was gone, and lanes were
  /// re-chosen over its span.
  bool lanesRepaired = false;

  /// Remaps the route in `data[off .. off + len − 1]`; see the class
  /// comment. [destMask] overrides the lanes the route may end in (by
  /// index); by default the old last lane's side is kept: the kerb lane, the
  /// innermost, or the same index where the edge still has it.
  RemapStatus remap(Int32List data, int off, int len,
      {int at = 0,
      bool onConnector = false,
      double s = 0,
      required double destS,
      int? destMask}) {
    final from = lineage.from, to = lineage.to;
    routeLength = 0;
    lanesRepaired = false;
    lane = -1;
    laneS = 0;
    stopS = 0;
    if (len <= 0 || at < 0 || at >= len) return RemapStatus.despawn;

    // Where the vehicle is: on its lane, or entering the edge from its
    // connector.
    final lane0 = _laneAt(data, off, at);
    final e0 = from.laneEdge[lane0];
    final k0 = from.laneIdx[lane0];
    final len0 = from.edgeLen[e0];
    var t0 = onConnector ? 0.0 : from.edgeLaneS0[e0] + s;
    if (t0 > len0 - _eps) t0 = len0 - _eps;
    if (t0 < 0) t0 = 0;

    // Where that is now: on a child of its road, or on a road laid again
    // under it; else nowhere.
    var tb0 = at == len - 1 ? destS : len0;
    if (tb0 < t0 + _eps) tb0 = t0 + _eps;
    var placed = _collect(e0, t0, tb0) > 0 &&
        _placeOnFirst(e0, t0, onConnector ? kSliverBridgeM : kOnLineM);
    if (!placed) placed = _placeOnRelaid(e0, t0);
    if (!placed) return RemapStatus.despawn;
    final nPlaced = to.edgeLaneCount[_placeEdge];
    final kPlaced = k0 < nPlaced ? k0 : nPlaced - 1;
    lane = to.edgeLaneBase[_placeEdge] + kPlaced;
    laneS = onConnector ? 0.0 : _laneS(to, _placeEdge, _placeT);

    // Every remaining old edge, as the chain of new edges that covers it.
    _n = 0;
    for (var i = at; i < len; i++) {
      final li = _laneAt(data, off, i);
      final ei = from.laneEdge[li];
      final ta = i == at ? t0 : 0.0;
      var tb = i == len - 1 ? destS : from.edgeLen[ei];
      if (tb < ta + _eps) tb = ta + _eps;
      final startTol = i == at && !onConnector ? kOnLineM : kSliverBridgeM;
      if (!_chain(ei, ta, tb, from.laneIdx[li], startTol, last: i == len - 1)) {
        return RemapStatus.replan;
      }
    }
    if (_n == 0 || _edges[0] != _placeEdge) return RemapStatus.replan;

    // One road on from the next, at one node, by a movement still allowed.
    for (var j = 0; j + 1 < _n; j++) {
      final x = _edges[j], y = _edges[j + 1];
      if (to.edgeTo[x] != to.edgeFrom[y] || !to.canFollow(x, y)) {
        return RemapStatus.replan;
      }
    }

    // The lanes: the vehicle's own first, the planned index on every edge
    // after, and the old last lane's side at the end.
    _want[0] = kPlaced;
    final lf = _laneAt(data, off, len - 1);
    final kOld = from.laneIdx[lf];
    final nOld = from.edgeLaneCount[from.laneEdge[lf]];
    final eLast = _edges[_n - 1];
    final nNew = to.edgeLaneCount[eLast];
    final kNew = kOld == 0
        ? 0
        : (kOld == nOld - 1 ? nNew - 1 : math.min(kOld, nNew - 1));
    if (_n > 1) _want[_n - 1] = kNew;
    if (!_planner.repair(to, _edges, _want, _n,
        destMask: destMask ?? (1 << kNew))) {
      return RemapStatus.replan;
    }
    lanesRepaired = _planner.repaired;
    final n = _planner.routeLength;
    if (route.length < n) route = Int32List(2 * n);
    route.setRange(0, n, _planner.route);
    routeLength = n;
    stopS = _clamp(_lastT, to.edgeLaneS0[eLast], to.edgeLaneS1[eLast]);
    return RemapStatus.kept;
  }

  int _laneAt(Int32List data, int off, int i) =>
      i == 0 ? data[off] : lineage.from.conToLane[data[off + i]];

  /// Gathers the new pieces covering travel arcs [ta] .. [tb] of old edge
  /// [oldEdge], in travel order. Pieces are taken where they overlap the
  /// range's interior, so at a cut the piece AHEAD is the one taken.
  int _collect(int oldEdge, double ta, double tb) {
    final from = lineage.from, ng = lineage.to.graph;
    _nPc = 0;
    // An outside connection's sink edge (slice 8) has no road to descend
    // from; the stubs remap those.
    if (oldEdge >= from.roadEdgeCount) return 0;
    final r = from.edgeRoad[oldEdge];
    final fwd = from.edgeForward[oldEdge] == 1;
    final ra = from.roadArc(oldEdge, ta), rb = from.roadArc(oldEdge, tb);
    final lo = ra < rb ? ra : rb, hi = ra < rb ? rb : ra;
    for (var k = lineage.childStart[r]; k < lineage.childStart[r + 1]; k++) {
      final cr = lineage.childRoad[k];
      final c0 = lineage.childC0[k], sc = lineage.childScale[k];
      for (var p = ng.roadFirstPiece[cr]; p < ng.roadFirstPiece[cr + 1]; p++) {
        final m0 = c0 + ng.pieceS0[p] * sc, m1 = c0 + ng.pieceS1[p] * sc;
        if (m1 <= lo || m0 >= hi) continue;
        if (_nPc == _pc.length) {
          _pc = Int32List(_pc.length * 2)..setRange(0, _nPc, _pc);
          _pk = Int32List(_pk.length * 2)..setRange(0, _nPc, _pk);
        }
        _pc[_nPc] = p;
        _pk[_nPc] = k;
        _nPc++;
      }
    }
    if (!fwd) {
      for (var i = 0, j = _nPc - 1; i < j; i++, j--) {
        final p = _pc[i], k = _pk[i];
        _pc[i] = _pc[j];
        _pk[i] = _pk[j];
        _pc[j] = p;
        _pk[j] = k;
      }
    }
    return _nPc;
  }

  /// Gathered piece [i]'s arc range on the OLD road.
  double _m0(int i) =>
      lineage.childC0[_pk[i]] +
      lineage.to.graph.pieceS0[_pc[i]] * lineage.childScale[_pk[i]];
  double _m1(int i) =>
      lineage.childC0[_pk[i]] +
      lineage.to.graph.pieceS1[_pc[i]] * lineage.childScale[_pk[i]];

  /// Puts the vehicle, at travel arc [t0] of old edge [e0], on the first
  /// gathered piece — if that piece reaches within [tol] of it and still
  /// runs its way.
  bool _placeOnFirst(int e0, double t0, double tol) {
    final from = lineage.from, to = lineage.to, ng = to.graph;
    final fwd = from.edgeForward[e0] == 1;
    final arc = from.roadArc(e0, t0);
    final gap = fwd ? _m0(0) - arc : arc - _m1(0);
    if (gap > tol) return false;
    final p = _pc[0], k = _pk[0];
    final e = fwd ? ng.pieceFwdEdge[p] : ng.pieceBwdEdge[p];
    if (e < 0) return false;
    final sc = _clamp((arc - lineage.childC0[k]) / lineage.childScale[k],
        ng.pieceS0[p], ng.pieceS1[p]);
    _placeEdge = e;
    _placeT = to.travelArc(e, sc);
    return true;
  }

  /// Puts the vehicle on a road re-laid in place of its own, where the new
  /// line runs within [kOnLineM] under it and a direction of it runs the
  /// vehicle's way: the unchanged stretch of a road whose end was dragged.
  bool _placeOnRelaid(int e0, double t0) {
    final from = lineage.from, to = lineage.to, og = from.graph;
    final ng = to.graph;
    if (e0 >= from.roadEdgeCount) return false;
    final r = from.edgeRoad[e0];
    final lo = lineage.relaidStart[r], hi = lineage.relaidStart[r + 1];
    if (lo == hi) return false;
    final fwd = from.edgeForward[e0] == 1;
    final arc = from.roadArc(e0, t0);
    final rec = og.roadRecs[r];
    // The vehicle's point and heading on the old line.
    final i = _segmentAt(rec, arc);
    final seg = rec.cum[i] - rec.cum[i - 1];
    final u = seg <= 1e-12 ? 0.0 : _clamp((arc - rec.cum[i - 1]) / seg, 0, 1);
    final pe = rec.e[i - 1] + (rec.e[i] - rec.e[i - 1]) * u;
    final pn = rec.n[i - 1] + (rec.n[i] - rec.n[i - 1]) * u;
    final sign = fwd ? 1.0 : -1.0;
    final de = (rec.e[i] - rec.e[i - 1]) * sign;
    final dn = (rec.n[i] - rec.n[i - 1]) * sign;
    for (var k = lo; k < hi; k++) {
      final nr = lineage.relaidRoad[k];
      final nrec = ng.roadRecs[nr];
      final hit = EdgeLineage.project(nrec, pe, pn);
      if (hit.d > kOnLineM) continue;
      final j = hit.seg;
      final same = de * (nrec.e[j] - nrec.e[j - 1]) +
              dn * (nrec.n[j] - nrec.n[j - 1]) >
          0;
      var p = ng.pieceAt(nr, hit.s);
      if (!same && p > ng.roadFirstPiece[nr] && hit.s <= ng.pieceS0[p]) p--;
      final e = same ? ng.pieceFwdEdge[p] : ng.pieceBwdEdge[p];
      if (e < 0) continue;
      _placeEdge = e;
      _placeT = to.travelArc(e, hit.s);
      return true;
    }
    return false;
  }

  /// The chain of new edges covering travel arcs [ta] .. [tb] of old edge
  /// [oldEdge], appended to the route with planned lane index [want]. False
  /// when the pieces do not cover the range — reaching within [startTol] of
  /// its start and [kSliverBridgeM] of its end, with no gap between two of
  /// them wider than a dropped sliver — or no longer run the edge's way.
  /// For the [last] edge, notes where the stop falls on the last piece.
  bool _chain(int oldEdge, double ta, double tb, int want, double startTol,
      {required bool last}) {
    final from = lineage.from, to = lineage.to, ng = to.graph;
    final n = _collect(oldEdge, ta, tb);
    if (n == 0) return false;
    final fwd = from.edgeForward[oldEdge] == 1;
    final ra = from.roadArc(oldEdge, ta), rb = from.roadArc(oldEdge, tb);
    final startGap = fwd ? _m0(0) - ra : ra - _m1(0);
    final endGap = fwd ? rb - _m1(n - 1) : _m0(n - 1) - rb;
    if (startGap > startTol || endGap > kSliverBridgeM) return false;
    for (var i = 0; i < n; i++) {
      if (i > 0) {
        final gap = fwd ? _m0(i) - _m1(i - 1) : _m0(i - 1) - _m1(i);
        if (gap > kSliverBridgeM) return false;
      }
      final p = _pc[i];
      final e = fwd ? ng.pieceFwdEdge[p] : ng.pieceBwdEdge[p];
      if (e < 0) return false;
      _push(e, want);
    }
    if (last) {
      final p = _pc[n - 1], k = _pk[n - 1];
      final sc = _clamp((rb - lineage.childC0[k]) / lineage.childScale[k],
          ng.pieceS0[p], ng.pieceS1[p]);
      _lastT = to.travelArc(_edges[_n - 1], sc);
    }
    return true;
  }

  void _push(int edge, int want) {
    if (_n == _edges.length) {
      _edges = Int32List(_n * 2)..setRange(0, _n, _edges);
      _want = Int32List(_n * 2)..setRange(0, _n, _want);
    }
    _edges[_n] = edge;
    _want[_n] = want;
    _n++;
  }

  static double _laneS(LaneGraph lg, int edge, double t) {
    final lo = lg.edgeLaneS0[edge], hi = lg.edgeLaneS1[edge];
    return _clamp(t - lo, 0, hi - lo);
  }

  /// The 1-based segment of [rec] holding arc [s].
  static int _segmentAt(IndexedRoad rec, double s) {
    final cum = rec.cum;
    var lo = 0, hi = rec.sampleCount;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] < s) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var i = lo;
    if (i < 1) i = 1;
    if (i > rec.sampleCount - 1) i = rec.sampleCount - 1;
    return i;
  }

  static double _clamp(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);
}
