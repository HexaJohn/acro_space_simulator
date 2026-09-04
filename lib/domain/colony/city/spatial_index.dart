// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Uniform-grid spatial indexes over colony-local metres.
///
/// The plat used to answer every "what is near this?" by scanning: every
/// candidate lot against every lot cut so far, every lot corner's depth ray
/// against every road, every new road's crossings against every road's
/// samples. Fine at a hundred roads; at a twenty-mile city — sixty thousand
/// streets, two hundred thousand lots — it is ten billion tests, which is
/// why the sprawl was a separate, lot-less model. These two indexes make
/// each of those questions local, so the whole city can be one plat.
///
/// Both are plain hash grids: an item lives in every cell its box touches,
/// a query walks the cells its box touches. Cell keys and packed entries
/// stay under 2^53 so the web build's doubles hold them exactly.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'parcel.dart';

/// An axis-aligned bound in colony-local metres.
class Box2 {
  const Box2(this.minE, this.minN, this.maxE, this.maxN);

  final double minE, minN, maxE, maxN;

  static Box2 of(List<Vec2> pts) {
    var lo = double.infinity, ln = double.infinity;
    var he = -double.infinity, hn = -double.infinity;
    for (final p in pts) {
      if (p.e < lo) lo = p.e;
      if (p.n < ln) ln = p.n;
      if (p.e > he) he = p.e;
      if (p.n > hn) hn = p.n;
    }
    return Box2(lo, ln, he, hn);
  }

  static Box2 around(Vec2 c, double r) =>
      Box2(c.e - r, c.n - r, c.e + r, c.n + r);

  /// Could anything in [o] be within [slack] of anything in this?
  bool within(Box2 o, double slack) =>
      o.minE - slack <= maxE &&
      o.maxE + slack >= minE &&
      o.minN - slack <= maxN &&
      o.maxN + slack >= minN;

  Box2 grow(double d) => Box2(minE - d, minN - d, maxE + d, maxN + d);

  double get width => maxE - minE;
  double get height => maxN - minN;
}

/// One cell key for (ix, iy), unique for |i| < 2^25 and under 2^52.
int _cellKey(int ix, int iy) => (ix + 33554432) * 67108864 + (iy + 33554432);

/// Items with boxes, looked up by box.
class BoxIndex<T> {
  BoxIndex({this.cellM = 32});

  final double cellM;
  final List<T> _items = [];
  final List<Box2> _boxes = [];
  final Map<int, List<int>> _cells = {};

  int get length => _items.length;
  List<T> get items => List.unmodifiable(_items);

  void clear() {
    _items.clear();
    _boxes.clear();
    _cells.clear();
  }

  int add(T item, Box2 box) {
    final index = _items.length;
    _items.add(item);
    _boxes.add(box);
    final x0 = (box.minE / cellM).floor(), x1 = (box.maxE / cellM).floor();
    final y0 = (box.minN / cellM).floor(), y1 = (box.maxN / cellM).floor();
    for (var ix = x0; ix <= x1; ix++) {
      for (var iy = y0; iy <= y1; iy++) {
        (_cells[_cellKey(ix, iy)] ??= []).add(index);
      }
    }
    return index;
  }

  /// Every item whose box comes within [slack] of [box], each once, in
  /// insertion order — so a caller that depends on order sees the order
  /// the items were added in, the way a scan of a list would.
  List<T> near(Box2 box, [double slack = 0]) {
    final ids = nearIndices(box, slack);
    return [for (final i in ids) _items[i]];
  }

  List<int> nearIndices(Box2 box, [double slack = 0]) {
    final q = slack == 0 ? box : box.grow(slack);
    final x0 = (q.minE / cellM).floor(), x1 = (q.maxE / cellM).floor();
    final y0 = (q.minN / cellM).floor(), y1 = (q.maxN / cellM).floor();
    final seen = <int>{};
    for (var ix = x0; ix <= x1; ix++) {
      for (var iy = y0; iy <= y1; iy++) {
        final cell = _cells[_cellKey(ix, iy)];
        if (cell == null) continue;
        for (final i in cell) {
          if (_boxes[i].within(box, slack)) seen.add(i);
        }
      }
    }
    return seen.toList()..sort();
  }
}

/// A road's samples, as the index holds them.
class IndexedRoad {
  IndexedRoad(this.road, this.e, this.n, this.cum, this.box);

  final RoadSpline road;

  /// Sample eastings and northings, and cumulative arc length at each.
  final Float64List e, n, cum;
  final Box2 box;

  int get sampleCount => e.length;
  int get segmentCount => math.max(0, e.length - 1);
  double get lengthM => cum.isEmpty ? 0 : cum.last;

  Vec2 sampleAt(int i) => Vec2(e[i], n[i]);

  /// Distance from [p] to segment [i] (samples i-1 .. i).
  double distanceToSegment(Vec2 p, int i) {
    final ae = e[i - 1], an = n[i - 1];
    final ex = e[i] - ae, en = n[i] - an;
    final len2 = ex * ex + en * en;
    final t = len2 <= 1e-12
        ? 0.0
        : (((p.e - ae) * ex + (p.n - an) * en) / len2).clamp(0.0, 1.0);
    final dx = p.e - (ae + ex * t), dn = p.n - (an + en * t);
    return math.sqrt(dx * dx + dn * dn);
  }

  /// Nearest point on segment [i] to [p], and its distance.
  (Vec2, double) nearestOnSegment(Vec2 p, int i) {
    final ae = e[i - 1], an = n[i - 1];
    final ex = e[i] - ae, en = n[i] - an;
    final len2 = ex * ex + en * en;
    final t = len2 <= 1e-12
        ? 0.0
        : (((p.e - ae) * ex + (p.n - an) * en) / len2).clamp(0.0, 1.0);
    final q = Vec2(ae + ex * t, an + en * t);
    return (q, p.distanceTo(q));
  }

  /// Arc length at parameter [u] along segment [i].
  double arcAt(int i, double u) => cum[i - 1] + (cum[i] - cum[i - 1]) * u;

  /// Distance from [p] to the whole road, over every segment. The slow
  /// path, for callers that already know the road is near.
  double distanceTo(Vec2 p) {
    if (e.isEmpty) return double.infinity;
    if (e.length == 1) return p.distanceTo(sampleAt(0));
    var best = double.infinity;
    for (var i = 1; i < e.length; i++) {
      final d = distanceToSegment(p, i);
      if (d < best) best = d;
    }
    return best;
  }

  List<Vec2> get samples => [for (var i = 0; i < e.length; i++) sampleAt(i)];
}

/// Roads by their sampled SEGMENTS: a query for a box returns exactly the
/// pieces of road that pass near it, however long the roads are — a
/// ten-kilometre highway fronting a lot costs the lot four segments, not
/// five thousand.
class SegmentIndex {
  SegmentIndex({this.cellM = 32, this.sampleM = 2});

  final double cellM;

  /// Sample spacing every road is held at. Two metres is what the crossing
  /// test always used, so a split lands where it always did.
  final double sampleM;

  final List<IndexedRoad?> _roads = [];
  final Map<String, int> _slotOf = {};
  final Map<int, List<int>> _cells = {};
  int _dead = 0;

  static const int _segBits = 16777216; // 2^24 segments per road

  Iterable<IndexedRoad> get roads => _roads.whereType<IndexedRoad>();
  int get roadCount => _slotOf.length;

  /// Every live road with its slot, in slot order.
  Iterable<(int, IndexedRoad)> get indexed sync* {
    for (var i = 0; i < _roads.length; i++) {
      final r = _roads[i];
      if (r != null) yield (i, r);
    }
  }

  IndexedRoad? byId(String id) {
    final slot = _slotOf[id];
    return slot == null ? null : _roads[slot];
  }

  IndexedRoad? bySlot(int slot) => _roads[slot];
  int? slotOf(String id) => _slotOf[id];

  void clear() {
    _roads.clear();
    _slotOf.clear();
    _cells.clear();
    _dead = 0;
  }

  /// Index [road]. [samples] are its points at [sampleM] when the caller
  /// already has them — the pieces of a split are cut from the parent's own
  /// samples, and re-evaluating the spline through their decimated controls
  /// cost more than the split itself on a long road cut a hundred times.
  int add(RoadSpline road, {List<Vec2>? samples}) {
    final old = _slotOf[road.id];
    if (old != null) remove(road.id);
    // A straight road IS its two ends: one segment answers every distance
    // and crossing question exactly, and a suburb of sixty thousand
    // straight streets held at 2 m would be a hundred megabytes of points.
    final pts = samples ??
        (road.controls.length == 2 && !road.closed
            ? List.of(road.controls)
            : road.sample(stepM: sampleM));
    final e = Float64List(pts.length), n = Float64List(pts.length);
    final cum = Float64List(pts.length);
    for (var i = 0; i < pts.length; i++) {
      e[i] = pts[i].e;
      n[i] = pts[i].n;
      if (i > 0) cum[i] = cum[i - 1] + pts[i].distanceTo(pts[i - 1]);
    }
    final rec = IndexedRoad(road, e, n, cum, Box2.of(pts));
    final slot = _roads.length;
    _roads.add(rec);
    _slotOf[road.id] = slot;
    _each(rec, (key, entry) => (_cells[key] ??= []).add(entry), slot);
    return slot;
  }

  void remove(String id) {
    final slot = _slotOf.remove(id);
    if (slot == null) return;
    final rec = _roads[slot]!;
    _each(rec, (key, entry) {
      final cell = _cells[key];
      if (cell == null) return;
      cell.remove(entry);
      if (cell.isEmpty) _cells.remove(key);
    }, slot);
    _roads[slot] = null;
    _dead++;
  }

  void _each(IndexedRoad rec, void Function(int key, int entry) f, int slot) {
    for (var i = 1; i < rec.e.length; i++) {
      final e0 = rec.e[i - 1], e1 = rec.e[i];
      final n0 = rec.n[i - 1], n1 = rec.n[i];
      final x0 = (math.min(e0, e1) / cellM).floor();
      final x1 = (math.max(e0, e1) / cellM).floor();
      final y0 = (math.min(n0, n1) / cellM).floor();
      final y1 = (math.max(n0, n1) / cellM).floor();
      final entry = slot * _segBits + i;
      for (var ix = x0; ix <= x1; ix++) {
        for (var iy = y0; iy <= y1; iy++) {
          f(_cellKey(ix, iy), entry);
        }
      }
    }
    if (rec.e.length == 1) {
      // A single sample still occupies its cell, so a point road is found.
      final ix = (rec.e[0] / cellM).floor(), iy = (rec.n[0] / cellM).floor();
      f(_cellKey(ix, iy), slot * _segBits);
    }
  }

  /// Every (road, segment) whose cells the grown [box] touches. A segment
  /// straddling cells is reported once per cell; callers that count use a
  /// set. Segment 0 means a one-sample road.
  void visit(Box2 box, double slack,
      void Function(int slot, IndexedRoad road, int seg) f) {
    final q = slack == 0 ? box : box.grow(slack);
    final x0 = (q.minE / cellM).floor(), x1 = (q.maxE / cellM).floor();
    final y0 = (q.minN / cellM).floor(), y1 = (q.maxN / cellM).floor();
    for (var ix = x0; ix <= x1; ix++) {
      for (var iy = y0; iy <= y1; iy++) {
        final cell = _cells[_cellKey(ix, iy)];
        if (cell == null) continue;
        for (final entry in cell) {
          final slot = entry ~/ _segBits;
          final rec = _roads[slot];
          if (rec == null) continue;
          f(slot, rec, entry - slot * _segBits);
        }
      }
    }
  }

  /// The roads with a segment near [box], each once, in slot order —
  /// which is insertion order, so a caller iterating them sees what a
  /// scan of the road list would have.
  List<int> slotsNear(Box2 box, [double slack = 0]) {
    final seen = <int>{};
    visit(box, slack, (slot, road, seg) => seen.add(slot));
    return seen.toList()..sort();
  }

  /// The segments of each road near [box]: slot -> distinct segment indices.
  Map<int, List<int>> segmentsNear(Box2 box, [double slack = 0]) {
    final seen = <int, Set<int>>{};
    visit(box, slack, (slot, road, seg) => (seen[slot] ??= {}).add(seg));
    return {
      for (final slot in seen.keys.toList()..sort())
        slot: seen[slot]!.toList()..sort(),
    };
  }

  /// Nearest point on any road to [p], searching outward from [startM] and
  /// doubling until something is found or [maxM] is reached.
  ({int slot, IndexedRoad road, int seg, Vec2 point, double distance})?
      nearest(Vec2 p, {double startM = 64, double maxM = 1e7}) {
    if (_slotOf.isEmpty) return null;
    var r = startM;
    while (true) {
      int? bestSlot;
      IndexedRoad? bestRoad;
      var bestSeg = -1;
      Vec2? bestPt;
      var best = double.infinity;
      visit(Box2.around(p, r), 0, (slot, rec, seg) {
        if (seg == 0) {
          final q = rec.sampleAt(0);
          final d = p.distanceTo(q);
          if (d < best) {
            best = d;
            bestSlot = slot;
            bestRoad = rec;
            bestSeg = 0;
            bestPt = q;
          }
          return;
        }
        final (q, d) = rec.nearestOnSegment(p, seg);
        if (d < best) {
          best = d;
          bestSlot = slot;
          bestRoad = rec;
          bestSeg = seg;
          bestPt = q;
        }
      });
      // Found within the box's inscribed circle: nothing outside the box
      // can be nearer.
      if (bestSlot != null && best <= r) {
        return (
          slot: bestSlot!,
          road: bestRoad!,
          seg: bestSeg,
          point: bestPt!,
          distance: best
        );
      }
      if (r >= maxM) {
        if (bestSlot == null) return null;
        return (
          slot: bestSlot!,
          road: bestRoad!,
          seg: bestSeg,
          point: bestPt!,
          distance: best
        );
      }
      r = math.min(maxM, r * 2);
    }
  }

  /// Rebuild the cell lists when enough removed roads have left holes.
  void compact() {
    if (_dead < 64 || _dead < _roads.length ~/ 2) return;
    final live = _roads.whereType<IndexedRoad>().toList();
    clear();
    for (final rec in live) {
      final slot = _roads.length;
      _roads.add(rec);
      _slotOf[rec.road.id] = slot;
      _each(rec, (key, entry) => (_cells[key] ??= []).add(entry), slot);
    }
  }
}
