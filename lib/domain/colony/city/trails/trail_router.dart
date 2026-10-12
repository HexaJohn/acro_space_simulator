// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The way a rover takes across open ground (docs/plans/desire-paths.md §7).
///
/// A* over a [TrailField]'s cells, eight neighbours, with TIME as the cost:
/// a step takes its length over the speed the ground allows. Bare regolith
/// is slow, a worn trail is quicker, a road quicker still, and a slope
/// slows the rover the steeper it is until, past [kTrailMaxGrade], it cannot
/// climb it at all. So the cheapest route is short, gentle and on the lines
/// others have already worn, which is the whole of the desire-path effect:
/// nobody chooses a trail, the trail is what everybody's cheapest route
/// turned out to share.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'trail_field.dart';

/// m/s across bare ground, a beaten track, and a road.
const double kTrailRawMps = 5;
const double kTrailWornMps = 9;
const double kTrailRoadMps = 12;

/// The steepest slope a laden rover climbs, rise over run: 24°, about
/// what the Apollo rover was rated for (25°).
const double kTrailMaxGrade = 0.45;

/// How much of its speed a rover keeps at [kTrailMaxGrade]: 1 − this.
const double _gradeSlow = 0.6;

/// A route: the cells from door to door, its length and the time it takes.
class TrailRoute {
  const TrailRoute(this.cells, this.lengthM, this.timeS);

  final Int32List cells;
  final double lengthM;
  final double timeS;
}

/// Seconds to step from cell [i] to its neighbour [j], [d] metres apart, or
/// infinity where the rover cannot. Shared with the service flood
/// ([TrailRouter.reach]) so "can get there" and "the route gets there" are
/// one rule.
double trailStepS(TrailField f, int i, int j, double d) {
  final grade = (f.height[j] - f.height[i]).abs() / d;
  if (grade > kTrailMaxGrade) return double.infinity;
  final slow = 1 - _gradeSlow * grade / kTrailMaxGrade;
  if (f.road(i) && f.road(j)) return d / (kTrailRoadMps * slow);
  final w = 0.5 * (f.wear[i] + f.wear[j]);
  return d / ((kTrailRawMps + (kTrailWornMps - kTrailRawMps) * w) * slow);
}

class TrailRouter {
  TrailRouter(this.field)
      : _g = Float64List(field.length),
        _from = Int32List(field.length),
        _seen = Int32List(field.length);

  final TrailField field;
  final Float64List _g;
  final Int32List _from;

  /// Search stamps: a cell's [_g] belongs to this search only when its stamp
  /// does, so nothing is cleared between searches.
  final Int32List _seen;
  int _stamp = 0;

  /// Searches run, and cells settled across them: the cost a bench reads.
  int searches = 0, settled = 0;

  static const _dc = [1, -1, 0, 0, 1, 1, -1, -1];
  static const _dr = [0, 0, 1, -1, 1, -1, 1, -1];

  /// The quickest route from cell [start] to cell [goal], or null when the
  /// ground between them cannot be crossed (or either is off the field).
  TrailRoute? route(int start, int goal) {
    final f = field;
    if (start < 0 || goal < 0) return null;
    if (start == goal) return TrailRoute(Int32List.fromList([start]), 0, 0);
    searches++;
    final stamp = ++_stamp;
    final cols = f.cols, rows = f.rows, cell = f.cellM;
    final diag = cell * math.sqrt2;
    final gc = goal % cols, gr = goal ~/ cols;
    // Octile distance at a worn track's speed: a road beats it, so this is
    // not strictly a lower bound there, and the route can miss a road
    // shortcut by a few seconds. That buys a search a fraction the size.
    double h(int i) {
      final dc = (i % cols - gc).abs(), dr = (i ~/ cols - gr).abs();
      final lo = math.min(dc, dr), hi = math.max(dc, dr);
      return (lo * diag + (hi - lo) * cell) / kTrailWornMps;
    }

    final heap = _Heap();
    _g[start] = 0;
    _from[start] = -1;
    _seen[start] = stamp;
    heap.push(h(start), start);
    while (heap.isNotEmpty) {
      final i = heap.pop();
      final gi = _g[i];
      if (i == goal) return _trace(start, goal, gi);
      // A stale entry: [i] was reached more cheaply after this one went in.
      if (heap.lastKey > gi + h(i) + 1e-9) continue;
      settled++;
      final c = i % cols, r = i ~/ cols;
      for (var k = 0; k < 8; k++) {
        final nc = c + _dc[k], nr = r + _dr[k];
        if (nc < 0 || nr < 0 || nc >= cols || nr >= rows) continue;
        final j = nr * cols + nc;
        if (f.blocked(j) && j != goal) continue;
        final isDiag = k >= 4;
        // No cutting a building's corner on the diagonal.
        if (isDiag &&
            (f.blocked(r * cols + nc) || f.blocked(nr * cols + c))) {
          continue;
        }
        final s = trailStepS(f, i, j, isDiag ? diag : cell);
        if (s == double.infinity) continue;
        final gj = gi + s;
        if (_seen[j] == stamp && _g[j] <= gj) continue;
        _seen[j] = stamp;
        _g[j] = gj;
        _from[j] = i;
        heap.push(gj + h(j), j);
      }
    }
    return null;
  }

  TrailRoute _trace(int start, int goal, double timeS) {
    final f = field;
    final rev = <int>[];
    for (var i = goal; i != -1; i = _from[i]) {
      rev.add(i);
      if (i == start) break;
    }
    final cells = Int32List(rev.length);
    var len = 0.0;
    for (var k = 0; k < rev.length; k++) {
      cells[k] = rev[rev.length - 1 - k];
      if (k > 0) {
        final a = cells[k - 1], b = cells[k];
        final de = f.centreE(a) - f.centreE(b), dn = f.centreN(a) - f.centreN(b);
        len += math.sqrt(de * de + dn * dn);
      }
    }
    return TrailRoute(cells, len, timeS);
  }

  /// Every cell a rover can reach from [root]: 1 reached, 0 not. The
  /// service flood (§7 "Service"): a lot is served off-road when a cell
  /// beside it is reached.
  Uint8List reach(int root) {
    final f = field;
    final out = Uint8List(f.length);
    if (root < 0 || f.blocked(root)) return out;
    final cols = f.cols, rows = f.rows, cell = f.cellM;
    final queue = Int32List(f.length);
    var head = 0, tail = 0;
    queue[tail++] = root;
    out[root] = 1;
    while (head < tail) {
      final i = queue[head++];
      final c = i % cols, r = i ~/ cols;
      for (var k = 0; k < 4; k++) {
        final nc = c + _dc[k], nr = r + _dr[k];
        if (nc < 0 || nr < 0 || nc >= cols || nr >= rows) continue;
        final j = nr * cols + nc;
        if (out[j] != 0 || f.blocked(j)) continue;
        if (trailStepS(f, i, j, cell) == double.infinity) continue;
        out[j] = 1;
        queue[tail++] = j;
      }
    }
    return out;
  }
}

/// A binary min-heap of (key, cell), ties broken by cell so a search is the
/// same search every time.
class _Heap {
  final List<double> _k = [];
  final List<int> _v = [];
  double lastKey = 0;

  bool get isNotEmpty => _k.isNotEmpty;

  bool _less(int a, int b) =>
      _k[a] < _k[b] || (_k[a] == _k[b] && _v[a] < _v[b]);

  void _swap(int a, int b) {
    final k = _k[a], v = _v[a];
    _k[a] = _k[b];
    _v[a] = _v[b];
    _k[b] = k;
    _v[b] = v;
  }

  void push(double key, int v) {
    _k.add(key);
    _v.add(v);
    var i = _k.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (!_less(i, p)) break;
      _swap(i, p);
      i = p;
    }
  }

  int pop() {
    lastKey = _k[0];
    final top = _v[0];
    final last = _k.length - 1;
    _swap(0, last);
    _k.removeLast();
    _v.removeLast();
    var i = 0;
    final n = _k.length;
    while (true) {
      final l = 2 * i + 1, r = l + 1;
      var m = i;
      if (l < n && _less(l, m)) m = l;
      if (r < n && _less(r, m)) m = r;
      if (m == i) break;
      _swap(i, m);
      i = m;
    }
    return top;
  }
}
