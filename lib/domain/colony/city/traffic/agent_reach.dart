// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Who can get to a lot the way the streets run: the reach fields behind the
/// agents' readout (docs/plans/agent-traffic.md §12.3, D46, D47; §1.1).
///
/// Three questions the colony asks of every lot, and slice 2 answers from
/// the agents' own network rather than the routed model's:
///
/// - SERVICE reach: a vehicle from any station that sends one — police, fire,
///   ambulance ([TrafficRole.sendsServiceVehicles]) — gets there within the
///   routed model's radius ([TrafficTuning.serviceReachM], 4 km of route).
/// - FIRE reach: the same, from stations with safety cover only
///   ([TrafficRole.fightsFires]). A clinic's ambulance reaching a house puts
///   no fire out there (1d2e78d), so a field of its own, not the service
///   field filtered.
/// - DELIVERY reach: goods get there at all, from any works, store, the
///   spaceport ([TrafficRole.shipsGoods]) or off-world through the landing
///   site — but never from the lot's own door. A works' own goods are no
///   delivery, and nor are its own lorries turning at the node beside it and
///   coming back (e608e35, road_traffic_model.dart:521-537): a works on a
///   street nothing else reaches the right way round declines like a shop
///   there.
///
/// Each is a multi-source Dijkstra over the lane graph's DIRECTED edges,
/// relaxed along its MOVEMENTS (`LaneGraph.moveOut`): only the turns a car
/// may actually make from one edge onto the next, so a one-way street is
/// driven the way it runs and a U-turn is made only where the lane graph
/// has one (a dead end, a roundabout, a stub; §3.6). That is the one place
/// these fields differ from the routed model's, which turns any way at a
/// node, U-turns included: a lot reached only by a U-turn at a plain
/// junction is reached here by going round the block, or not at all within
/// the radius. Everything else is the routed model's rule ported as it is —
/// the radius, the roles, the sources the landing site and the grid add,
/// distances in route metres along `RoadGraph.edgeLength`, a lot entered at
/// join slot 0 (`lotPiece`, `lotS`, `lotDirs`), the nearest source behind a
/// lot on its own stretch, and the owned search that tells a lot's own
/// lorries from everyone else's (`_OwnedSearch`, road_traffic_model.dart:
/// 2330-2514) — so where the two networks agree the answers agree to the
/// metre.
///
/// A label lives on an EDGE, not a node: `dist[e]` is route metres from the
/// nearest source to the start of edge e, having been allowed to turn into
/// it. A lot at travel arc c on edge e is then `dist[e] + c` away, or the
/// distance back to a source standing on e behind it. Asked of a lot, that
/// is two array reads and a binary search along one edge: O(1) in the size
/// of the city.
///
/// The fields are recomputed as a PASS of bounded work ([step]), and only
/// when they can have changed: a pass first gathers the sources from the
/// building table, and when they and the network's structure are what the
/// published fields were searched from, it searches nothing. The published
/// fields are the last complete pass's; before the first, and for a lot
/// that pass's network does not know, every lot is reached (D47): no lot is
/// punished for not having been looked at.
///
/// A pass may allocate when the network changes size (the fields are sized
/// to it); otherwise its buffers are reused, and nothing a query does
/// allocates (§15.2).
library;

import 'dart:typed_data';

import '../road_graph.dart';
import '../road_traffic_model.dart' show TrafficRole, TrafficTuning;
import 'building_table.dart';
import 'lane_graph.dart';

/// The fields behind a colony's reach answers. See the library comment.
class AgentReach {
  /// Fields out to [radiusM] of route for service and fire — the routed
  /// model's own radius unless a caller hands in the colony's.
  AgentReach({double? radiusM})
    : radiusM = radiusM ?? const TrafficTuning().serviceReachM;

  /// Route metres within which a station's vehicle counts as reaching a
  /// lot ([TrafficTuning.serviceReachM]).
  final double radiusM;

  _Fields? _front;
  _Fields? _back;

  // ---- The pass in flight ------------------------------------------------------

  static const int _idle = 0,
      _gather = 1,
      _compare = 2,
      _svc = 3,
      _fire = 4,
      _goods = 5,
      _done = 6;

  int _phase = _idle;
  int _cursor = 0;
  bool _seeded = false;
  bool _recomputed = false;
  LaneGraph? _lg;
  BuildingTable? _table;

  final _Sources _gSvc = _Sources(), _gFire = _Sources(), _gGoods = _Sources();
  final _Search _search = _Search();
  final _OwnedSearch _owned = _OwnedSearch();

  /// Passes published, and of those the ones that searched — the rest found
  /// their sources and network as the published fields had them.
  int published = 0, searched = 0;

  /// Whether a pass is in flight, and whether one has finished and waits to
  /// be published.
  bool get passing => _phase != _idle && _phase != _done;
  bool get ready => _phase == _done;

  /// Whether any fields have been published.
  bool get hasFields => _front != null;

  /// The lane graph the published fields were searched on.
  LaneGraph? get laneGraph => _front?.lg;

  /// Drops every field and the pass in flight: the colony's agents started
  /// afresh, and nothing published of their old tables stands.
  void reset() {
    _front = null;
    _back = null;
    abort();
  }

  /// Drops the pass in flight; the published fields stay readable.
  void abort() {
    _phase = _idle;
    _lg = null;
    _table = null;
  }

  /// Starts a pass over [table]'s buildings on [lg] — the lane graph the
  /// table's access was resolved on. A pass in flight is dropped.
  void begin(LaneGraph lg, BuildingTable table) {
    _lg = lg;
    _table = table;
    _cursor = 0;
    _seeded = false;
    _recomputed = false;
    _gSvc.clear();
    _gFire.clear();
    _gGoods.clear();
    _phase = _gather;
  }

  /// Does up to [budget] units of the pass in flight: a building looked at,
  /// a source seeded, a label settled or an edge relaxed, a stretch of a
  /// field cleared. Returns the units done; the pass is [ready] when it has
  /// finished. A step overruns [budget] by at most one building's sources or
  /// one edge's movements.
  int step(int budget) {
    var work = 0;
    while (work < budget && passing) {
      final left = budget - work;
      switch (_phase) {
        case _gather:
          work += _gatherStep(left);
        case _compare:
          work += _compareStep();
        case _svc:
        case _fire:
          work += _fieldStep(left);
        case _goods:
          work += _goodsStep(left);
      }
    }
    return work;
  }

  /// Runs a whole pass now and publishes it: for tests and small tools.
  void runPass(LaneGraph lg, BuildingTable table) {
    begin(lg, table);
    while (passing) {
      step(1 << 30);
    }
    publish();
  }

  /// The finished pass's fields become the readers'. A pass that searched
  /// nothing leaves the published fields as they were, on the pass's graph
  /// (which shares their structure: a junction re-planned, a road renamed).
  void publish() {
    if (_phase != _done) return;
    final lg = _lg!;
    if (_recomputed) {
      final f = _back!;
      _back = _front;
      _front = f;
      searched++;
    }
    _front!.lg = lg;
    published++;
    _phase = _idle;
    _lg = null;
    _table = null;
  }

  // ---- Gather ----------------------------------------------------------------------

  int _gatherStep(int budget) {
    final t = _table!;
    final lg = _lg!;
    final g = lg.graph;
    var work = 0;
    while (_cursor < t.highWater && work < budget) {
      final sl = _cursor++;
      work++;
      if (!t.isSlotLive(sl)) continue;
      final spec = t.spec[sl];
      if (spec == null) continue;
      final svc = TrafficRole.sendsServiceVehicles(spec);
      final fire = TrafficRole.fightsFires(spec);
      final goods = TrafficRole.shipsGoods(spec);
      if (!svc && !fire && !goods) continue;
      work += 4;
      final lot = g.lotNoOf(t.siteId[sl]);
      if (lot != null) {
        // A lot: entered at its join slot 0, exactly where the routed model
        // seeds it (road_traffic_model.dart:1068-1083).
        final piece = g.lotPiece[lot];
        final dirs = g.lotDirs[lot];
        if (piece < 0 || dirs == 0) continue;
        final s = g.lotS[lot];
        if (svc) _addLot(_gSvc, g, piece, s, dirs, lot);
        if (fire) _addLot(_gFire, g, piece, s, dirs, lot);
        if (goods) _addLot(_gGoods, g, piece, s, dirs, lot);
      } else {
        // A building the grid placed: the access the table resolved on this
        // graph, from `attachFootprint` as the routed model's grid sites
        // are. The table keeps the arc clamped onto the lane (a lot beside a
        // junction is met at its stop bar), so a grid site's distances can
        // differ from the routed model's by that much.
        if (svc) _addSite(_gSvc, lg, t, sl);
        if (fire) _addSite(_gFire, lg, t, sl);
        if (goods) _addSite(_gGoods, lg, t, sl);
      }
    }
    if (_cursor < t.highWater) return work;
    // The landing site: the colony's door to the world, where the goods it
    // does not make come in from — a source on no lot.
    if (g.rootPiece >= 0 && g.rootDirs != 0) {
      _addLot(_gGoods, g, g.rootPiece, g.rootS, g.rootDirs, -1);
    }
    _phase = _compare;
    return work + 1;
  }

  /// A source leaving arc [s] of [piece] in the directions [dirs] allows:
  /// on each serving edge, its travel arc and the metres to the edge's end.
  static void _addLot(
    _Sources to,
    RoadGraph g,
    int piece,
    double s,
    int dirs,
    int lot,
  ) {
    final fe = g.pieceFwdEdge[piece], be = g.pieceBwdEdge[piece];
    if (dirs & RoadGraph.forwardBit != 0 && fe >= 0) {
      to.add(fe, s - g.pieceS0[piece], g.pieceS1[piece] - s, lot);
    }
    if (dirs & RoadGraph.backwardBit != 0 && be >= 0) {
      to.add(be, g.pieceS1[piece] - s, s - g.pieceS0[piece], lot);
    }
  }

  static void _addSite(_Sources to, LaneGraph lg, BuildingTable t, int sl) {
    final fe = t.accFwd[sl], be = t.accBwd[sl];
    if (fe >= 0 && fe < lg.edgeCount) {
      final at = t.accFwdT[sl].toDouble();
      to.add(fe, at, lg.edgeLen[fe] - at, -1);
    }
    if (be >= 0 && be < lg.edgeCount) {
      final at = t.accBwdT[sl].toDouble();
      to.add(be, at, lg.edgeLen[be] - at, -1);
    }
  }

  // ---- Compare: search only when something a field depends on moved -----------

  int _compareStep() {
    final lg = _lg!;
    final f = _front;
    if (f != null &&
        lg.sharesStructureWith(f.lg) &&
        _gSvc.sameAs(f.svc) &&
        _gFire.sameAs(f.fire) &&
        _gGoods.sameAs(f.goods)) {
      _phase = _done;
      return 1 + _gSvc.length + _gFire.length + _gGoods.length;
    }
    final nE = lg.edgeCount;
    var b = _back;
    if (b == null || b.edgeCount != nE) b = _back = _Fields(nE, lg);
    b.lg = lg;
    b.svc.copyFrom(_gSvc);
    b.fire.copyFrom(_gFire);
    b.goods.copyFrom(_gGoods);
    b.svcOn.build(b.svc, nE);
    b.fireOn.build(b.fire, nE);
    b.goodsOn.build(b.goods, nE);
    _recomputed = true;
    _seeded = false;
    _phase = _svc;
    return 1 + (nE >> 4) + _gSvc.length + _gFire.length + _gGoods.length;
  }

  // ---- The fields ----------------------------------------------------------------

  int _fieldStep(int budget) {
    final lg = _lg!;
    final b = _back!;
    final fire = _phase == _fire;
    final src = fire ? b.fire : b.svc;
    final s = _search;
    var work = 0;
    if (!_seeded) {
      _seeded = true;
      work += s.reset(fire ? b.fireDist : b.svcDist, radiusM);
      for (var k = 0; k < src.length; k++) {
        final e = src.edge[k];
        final d = src.rem[k];
        for (var i = lg.moveStart[e]; i < lg.moveStart[e + 1]; i++) {
          s.seed(lg.moveOut[i], d);
        }
        work += 2;
      }
    }
    work += s.run(lg, budget - work);
    if (!s.done) return work;
    _seeded = false;
    _phase = fire ? _goods : _fire;
    return work + 1;
  }

  int _goodsStep(int budget) {
    final lg = _lg!;
    final b = _back!;
    final src = b.goods;
    final s = _owned;
    var work = 0;
    if (!_seeded) {
      _seeded = true;
      work += s.reset(b.goodsDist, b.goodsLot, b.goodsDist2);
      for (var k = 0; k < src.length; k++) {
        final e = src.edge[k];
        final d = src.rem[k];
        final lot = src.lot[k];
        for (var i = lg.moveStart[e]; i < lg.moveStart[e + 1]; i++) {
          s.seed(lg.moveOut[i], d, lot);
        }
        work += 2;
      }
    }
    work += s.run(lg, budget - work);
    if (!s.done) return work;
    _seeded = false;
    _phase = _done;
    return work + 1;
  }

  // ---- Answers (from the last published pass) ------------------------------------

  /// Route metres from the nearest station that sends vehicles to [lotId]
  /// over the directed edges, the way the one-way streets run — null when
  /// none is within [radiusM], for a lot the fields do not know, and before
  /// any are published.
  double? serviceDistanceTo(String lotId) {
    final f = _front;
    if (f == null) return null;
    final d = _distance(f, lotId, f.svcDist, f.svcOn, f.svc, null, null);
    return d <= radiusM ? d : null;
  }

  /// Whether a vehicle from a station that sends one reaches [lotId] within
  /// [radiusM]. True before a pass is published and for a lot it does not
  /// know.
  bool serviceReach(String lotId) {
    final f = _front;
    if (f == null || f.lg.graph.lotNoOf(lotId) == null) return true;
    return _distance(f, lotId, f.svcDist, f.svcOn, f.svc, null, null) <=
        radiusM;
  }

  /// Whether a vehicle from a station with safety cover reaches [lotId]
  /// within [radiusM] — its own field: a clinic up the street reaches a
  /// house, and puts no fire out there. True before a pass is published and
  /// for a lot it does not know.
  bool fireReach(String lotId) {
    final f = _front;
    if (f == null || f.lg.graph.lotNoOf(lotId) == null) return true;
    return _distance(f, lotId, f.fireDist, f.fireOn, f.fire, null, null) <=
        radiusM;
  }

  /// Whether goods reach [lotId] from anywhere but its own door, however
  /// far. True before a pass is published and for a lot it does not know.
  bool deliveryReach(String lotId) {
    final f = _front;
    if (f == null || f.lg.graph.lotNoOf(lotId) == null) return true;
    return _distance(
      f,
      lotId,
      f.goodsDist,
      f.goodsOn,
      f.goods,
      f.goodsLot,
      f.goodsDist2,
    ).isFinite;
  }

  /// Route metres to [lotId] in a field: into its serving edge from the
  /// edge's start, in a direction it accepts, or from the nearest source on
  /// that edge behind it — infinite when unreached, unknown, or not on the
  /// network. With [nearestLot] the lot's own sources are passed over: at
  /// an edge one of them labels first, [otherDist] (the nearest from any
  /// other lot) is read instead (`_Results.reachDistance`,
  /// road_traffic_model.dart:2017-2043).
  static double _distance(
    _Fields f,
    String lotId,
    Float64List dist,
    _OnEdge on,
    _Sources src,
    Int32List? nearestLot,
    Float64List? otherDist,
  ) {
    final g = f.lg.graph;
    final i = g.lotNoOf(lotId);
    if (i == null) return double.infinity;
    final piece = g.lotPiece[i];
    if (piece < 0) return double.infinity;
    final s = g.lotS[i];
    final mask = g.lotDirs[i];
    final skip = nearestLot == null ? -2 : i;
    var best = double.infinity;
    final fe = g.pieceFwdEdge[piece];
    if (mask & RoadGraph.forwardBit != 0 && fe >= 0) {
      final c = s - g.pieceS0[piece];
      final at = _atEdge(fe, dist, nearestLot, otherDist, i) + c;
      if (at < best) best = at;
      final back = on.behind(src, fe, c, skip);
      if (back < best) best = back;
    }
    final be = g.pieceBwdEdge[piece];
    if (mask & RoadGraph.backwardBit != 0 && be >= 0) {
      final c = g.pieceS1[piece] - s;
      final at = _atEdge(be, dist, nearestLot, otherDist, i) + c;
      if (at < best) best = at;
      final back = on.behind(src, be, c, skip);
      if (back < best) best = back;
    }
    return best;
  }

  static double _atEdge(
    int e,
    Float64List dist,
    Int32List? nearestLot,
    Float64List? otherDist,
    int lot,
  ) {
    if (e >= dist.length) return double.infinity;
    return nearestLot != null && nearestLot[e] == lot ? otherDist![e] : dist[e];
  }
}

// ---- Internals ------------------------------------------------------------------------

/// One published set of fields, sized to a lane graph's edges. An
/// [AgentReach] holds two: readers have one while a pass fills the other.
class _Fields {
  _Fields(this.edgeCount, this.lg)
    : svcDist = Float64List(edgeCount),
      fireDist = Float64List(edgeCount),
      goodsDist = Float64List(edgeCount),
      goodsDist2 = Float64List(edgeCount),
      goodsLot = Int32List(edgeCount),
      svcOn = _OnEdge(edgeCount),
      fireOn = _OnEdge(edgeCount),
      goodsOn = _OnEdge(edgeCount);

  final int edgeCount;

  /// The graph the fields were searched on — or, after a pass that found
  /// nothing changed, one sharing its structure.
  LaneGraph lg;

  /// Per edge: route metres from the nearest source to its start.
  final Float64List svcDist, fireDist, goodsDist;

  /// Per edge, the goods field's second label: the lot the nearest source
  /// stands on (-1 for none: the landing site, a grid site), and the metres
  /// from the nearest on any other lot.
  final Float64List goodsDist2;
  final Int32List goodsLot;

  /// The sources each field was searched from, in gather order, and the
  /// same sources by the edge they stand on.
  final _Sources svc = _Sources(), fire = _Sources(), goods = _Sources();
  final _OnEdge svcOn, fireOn, goodsOn;
}

/// Where a field's sources stand, as gathered: the serving edge, the travel
/// arc along it, the metres on to its end, and the graph lot (-1 for none).
class _Sources {
  Int32List edge = Int32List(16);
  Float64List t = Float64List(16);
  Float64List rem = Float64List(16);
  Int32List lot = Int32List(16);
  int length = 0;

  void clear() => length = 0;

  void add(int e, double at, double toEnd, int onLot) {
    if (length == edge.length) _grow();
    edge[length] = e;
    t[length] = at;
    rem[length] = toEnd;
    lot[length] = onLot;
    length++;
  }

  void _grow() {
    final n = edge.length * 2;
    edge = Int32List(n)..setRange(0, length, edge);
    t = Float64List(n)..setRange(0, length, t);
    rem = Float64List(n)..setRange(0, length, rem);
    lot = Int32List(n)..setRange(0, length, lot);
  }

  /// Whether [other] holds the same sources in the same order, to the bit.
  bool sameAs(_Sources other) {
    if (length != other.length) return false;
    for (var k = 0; k < length; k++) {
      if (edge[k] != other.edge[k] ||
          t[k] != other.t[k] ||
          rem[k] != other.rem[k] ||
          lot[k] != other.lot[k]) {
        return false;
      }
    }
    return true;
  }

  void copyFrom(_Sources other) {
    length = 0;
    for (var k = 0; k < other.length; k++) {
      add(other.edge[k], other.t[k], other.rem[k], other.lot[k]);
    }
  }
}

/// A field's sources by the edge they stand on, each edge's run ascending by
/// travel arc (ties in gather order): `order[start[e] .. start[e + 1] − 1]`
/// index into the field's [_Sources].
class _OnEdge {
  _OnEdge(int edgeCount)
    : start = Int32List(edgeCount + 1),
      _next = Int32List(edgeCount + 1);

  final Int32List start;
  final Int32List _next;
  Int32List order = Int32List(16);

  void build(_Sources src, int edgeCount) {
    final st = start;
    st.fillRange(0, st.length, 0);
    for (var k = 0; k < src.length; k++) {
      st[src.edge[k] + 1]++;
    }
    for (var e = 0; e < edgeCount; e++) {
      st[e + 1] += st[e];
    }
    if (order.length < src.length) order = Int32List(src.length * 2);
    // Placed by counting, in gather order within each edge's run, then each
    // run sorted by arc with an insertion sort, which keeps ties in that
    // order — as the routed model's per-piece lists keep them.
    _next.setRange(0, st.length, st);
    for (var k = 0; k < src.length; k++) {
      order[_next[src.edge[k]]++] = k;
    }
    for (var k = 0; k < src.length; k++) {
      final e = src.edge[k];
      final lo = st[e], hi = st[e + 1];
      // Each run once: from the place of its first source.
      if (hi - lo < 2 || order[lo] != k) continue;
      for (var i = lo + 1; i < hi; i++) {
        final kk = order[i];
        final v = src.t[kk];
        var j = i;
        while (j > lo && src.t[order[j - 1]] > v) {
          order[j] = order[j - 1];
          j--;
        }
        order[j] = kk;
      }
    }
  }

  /// Metres back from travel arc [c] on edge [e] to the nearest source at or
  /// behind it — the largest arc not past [c], passing over the source on
  /// lot [skip] — or infinity when every source is ahead.
  double behind(_Sources src, int e, double c, int skip) {
    if (e + 1 >= start.length) return double.infinity;
    final lo0 = start[e], hi0 = start[e + 1];
    if (lo0 == hi0 || src.t[order[lo0]] > c + 1e-6) return double.infinity;
    var lo = lo0, hi = hi0 - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (src.t[order[mid]] <= c + 1e-6) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    while (lo >= lo0 && src.lot[order[lo]] == skip) {
      lo--;
    }
    if (lo < lo0) return double.infinity;
    return c - src.t[order[lo]];
  }
}

/// A resumable, bounded Dijkstra over a lane graph's edges and movements,
/// writing its labels into the field it was [reset] onto.
class _Search {
  Float64List _dist = Float64List(0);
  Uint8List _settled = Uint8List(0);
  Float64List _hk = Float64List(64);
  Int32List _hn = Int32List(64);
  int _hs = 0;
  double _bound = double.infinity;

  bool done = true;

  /// Readies a search into [dist] (every label infinite) out to [bound]
  /// metres. The work of clearing it.
  int reset(Float64List dist, double bound) {
    _dist = dist;
    dist.fillRange(0, dist.length, double.infinity);
    if (_settled.length != dist.length) {
      _settled = Uint8List(dist.length);
    } else {
      _settled.fillRange(0, _settled.length, 0);
    }
    _hs = 0;
    _bound = bound;
    done = false;
    return 1 + (dist.length >> 4);
  }

  void seed(int e, double d) {
    if (d >= _dist[e] || d > _bound) return;
    _dist[e] = d;
    _push(e, d);
  }

  /// Settles labels until the search is exhausted or [budget] units are
  /// spent. A label past the bound is never pushed, so an exhausted search
  /// has settled every finite one.
  int run(LaneGraph lg, int budget) {
    var work = 0;
    final start = lg.moveStart, out = lg.moveOut, len = lg.edgeLen;
    final dist = _dist, settled = _settled;
    while (_hs > 0 && work < budget) {
      final d = _hk[0];
      final u = _hn[0];
      _pop();
      work++;
      if (settled[u] == 1 || d > dist[u]) continue;
      settled[u] = 1;
      final nd = d + len[u];
      if (nd > _bound) continue;
      for (var i = start[u]; i < start[u + 1]; i++) {
        work++;
        final v = out[i];
        if (settled[v] == 1) continue;
        if (nd < dist[v]) {
          dist[v] = nd;
          _push(v, nd);
        }
      }
    }
    if (_hs == 0) done = true;
    return work;
  }

  void _push(int n, double k) {
    if (_hs == _hk.length) {
      _hk = Float64List(_hk.length * 2)..setRange(0, _hs, _hk);
      _hn = Int32List(_hn.length * 2)..setRange(0, _hs, _hn);
    }
    var i = _hs++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_hk[p] <= k) break;
      _hk[i] = _hk[p];
      _hn[i] = _hn[p];
      i = p;
    }
    _hk[i] = k;
    _hn[i] = n;
  }

  void _pop() {
    _hs--;
    if (_hs == 0) return;
    final k = _hk[_hs];
    final n = _hn[_hs];
    var i = 0;
    while (true) {
      var c = 2 * i + 1;
      if (c >= _hs) break;
      if (c + 1 < _hs && _hk[c + 1] < _hk[c]) c++;
      if (_hk[c] >= k) break;
      _hk[i] = _hk[c];
      _hn[i] = _hn[c];
      i = c;
    }
    _hk[i] = k;
    _hn[i] = n;
  }
}

/// A resumable, unbounded Dijkstra over a lane graph's edges and movements
/// from sources that each stand on a lot (-1 for a source on none — the
/// landing site, a grid site — all of which count as one), keeping two
/// labels an edge: the nearest source ([_dist], on [_lot]) and the nearest
/// on any other lot ([_dist2]). The routed model's `_OwnedSearch`
/// (road_traffic_model.dart:2330-2514) with an edge where it has a node: a
/// label is settled at most twice, and only settled labels are carried on,
/// since a source two others beat to an edge is beaten by them to
/// everywhere past it.
class _OwnedSearch {
  Float64List _dist = Float64List(0), _dist2 = Float64List(0);
  Int32List _lot = Int32List(0), _lot2 = Int32List(0);
  Uint8List _settled = Uint8List(0);
  Float64List _hk = Float64List(64);
  Int32List _hn = Int32List(64), _ho = Int32List(64);
  int _hs = 0;

  bool done = true;

  /// Readies a search into [dist], [lot] and [dist2]. The work of clearing
  /// it.
  int reset(Float64List dist, Int32List lot, Float64List dist2) {
    final n = dist.length;
    _dist = dist..fillRange(0, n, double.infinity);
    _dist2 = dist2..fillRange(0, n, double.infinity);
    _lot = lot..fillRange(0, n, -1);
    if (_lot2.length != n) {
      _lot2 = Int32List(n);
      _settled = Uint8List(n);
    } else {
      _settled.fillRange(0, n, 0);
    }
    _hs = 0;
    done = false;
    return 1 + (n >> 3);
  }

  void seed(int e, double d, int onLot) {
    if (_offer(e, d, onLot)) _push(e, d, onLot);
  }

  /// A source on [onLot] reaches the start of edge [n] at [d]: true when
  /// that is one of its two labels now — the nearest, or the nearest of
  /// another lot than the nearest's.
  bool _offer(int n, double d, int onLot) {
    final k = _settled[n];
    if (k == 2) return false;
    final d1 = _dist[n];
    if (d1 == double.infinity) {
      _dist[n] = d;
      _lot[n] = onLot;
      return true;
    }
    if (_lot[n] == onLot) {
      // A settled label is final (every later offer is further anyway).
      if (k > 0 || d >= d1) return false;
      _dist[n] = d;
      return true;
    }
    final d2 = _dist2[n];
    final second = d2 != double.infinity && _lot2[n] == onLot;
    if (second && d >= d2) return false;
    if (k == 0 && d < d1) {
      // The new nearest: the old one is the other lot's now.
      _dist2[n] = d1;
      _lot2[n] = _lot[n];
      _dist[n] = d;
      _lot[n] = onLot;
      return true;
    }
    if (!second && d >= d2) return false;
    _dist2[n] = d;
    _lot2[n] = onLot;
    return true;
  }

  int run(LaneGraph lg, int budget) {
    var work = 0;
    final start = lg.moveStart, out = lg.moveOut, len = lg.edgeLen;
    while (_hs > 0 && work < budget) {
      final d = _hk[0];
      final u = _hn[0];
      final o = _ho[0];
      _pop();
      work++;
      final k = _settled[u];
      if (k == 2) continue;
      if (k == 0 && _lot[u] == o && _dist[u] == d) {
        // The nearest label.
      } else if (_dist2[u] == d && _lot2[u] == o && (k == 1 || _dist[u] == d)) {
        // The other lot's label — or, unsettled, a tie with the nearest,
        // which it may as well be.
        if (k == 0) {
          _dist2[u] = _dist[u];
          _lot2[u] = _lot[u];
          _dist[u] = d;
          _lot[u] = o;
        }
      } else {
        // Stale: bettered since, or beaten to the edge by two other lots.
        continue;
      }
      _settled[u] = k + 1;
      final nd = d + len[u];
      for (var i = start[u]; i < start[u + 1]; i++) {
        work++;
        final v = out[i];
        if (_offer(v, nd, o)) _push(v, nd, o);
      }
    }
    if (_hs == 0) done = true;
    return work;
  }

  void _push(int n, double k, int o) {
    if (_hs == _hk.length) {
      _hk = Float64List(_hk.length * 2)..setRange(0, _hs, _hk);
      _hn = Int32List(_hn.length * 2)..setRange(0, _hs, _hn);
      _ho = Int32List(_ho.length * 2)..setRange(0, _hs, _ho);
    }
    var i = _hs++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_hk[p] <= k) break;
      _hk[i] = _hk[p];
      _hn[i] = _hn[p];
      _ho[i] = _ho[p];
      i = p;
    }
    _hk[i] = k;
    _hn[i] = n;
    _ho[i] = o;
  }

  void _pop() {
    _hs--;
    if (_hs == 0) return;
    final k = _hk[_hs];
    final n = _hn[_hs];
    final o = _ho[_hs];
    var i = 0;
    while (true) {
      var c = 2 * i + 1;
      if (c >= _hs) break;
      if (c + 1 < _hs && _hk[c + 1] < _hk[c]) c++;
      if (_hk[c] >= k) break;
      _hk[i] = _hk[c];
      _hn[i] = _hn[c];
      _ho[i] = _ho[c];
      i = c;
    }
    _hk[i] = k;
    _hn[i] = n;
    _ho[i] = o;
  }
}
