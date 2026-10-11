// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where the bubble's units can walk and see (docs/plans/combat.md §7H): a
/// grid on the battle raster's cells — blocked under a building or up a
/// slope too steep to climb — with a flow field per destination, and a line
/// of sight over the raster and round the buildings.
///
/// Pure and counted: a flow field is one Dijkstra over the raster's 22,500
/// cells, built when first asked for and kept; a sight line samples the
/// raster every 4 m. Nothing here reads the terrain field.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'battle_raster.dart';

/// Steeper than this (rise over run, ~35°) a cell is a wall.
const double kMaxClimb = 0.7;

/// A building stands this tall for sight lines, m.
const double kBuildingHeightM = 8;

class NavGrid {
  NavGrid(this.raster, this.footprints) : blocked = Uint8List(raster.n * raster.n) {
    final n = raster.n;
    for (var k = 0; k < blocked.length; k++) {
      final (e, nn) = raster.cellCentre(k);
      // A cell is shut within half a cell of a wall, so a walk between cell
      // centres never cuts a corner of the building.
      final pad = raster.cellM * 0.75;
      if (footprints.any((f) => _d2(f.$1, f.$2, e, nn) < (f.$3 + pad) * (f.$3 + pad))) {
        blocked[k] = 1;
        continue;
      }
      final i = k % n, j = k ~/ n;
      final r = raster.radii[k];
      var steep = false;
      for (final (di, dj) in const [(1, 0), (0, 1)]) {
        final ii = i + di, jj = j + dj;
        if (ii >= n || jj >= n) continue;
        final rr = raster.radii[jj * n + ii];
        if ((rr - r).abs() / raster.cellM > kMaxClimb) steep = true;
      }
      if (steep) blocked[k] = 1;
    }
  }

  final BattleRaster raster;

  /// Buildings: (east, north, radius m).
  final List<(double, double, double)> footprints;

  /// 1 where nobody walks.
  final Uint8List blocked;

  /// Flow fields by destination key, built on first use. Fields to a moving
  /// point ([transient]) are kept a few at a time, oldest dropped.
  final Map<String, Float32List> _fields = {};
  final List<String> _transient = [];
  static const int keepTransient = 4;

  /// Dijkstras run, for a budget readout.
  int built = 0;

  int get n => raster.n;

  int? cellOf(double e, double nn) {
    if (!raster.contains(e, nn)) return null;
    final i = ((e - raster.west) / raster.cellM).floor().clamp(0, n - 1);
    final j = ((nn - raster.south) / raster.cellM).floor().clamp(0, n - 1);
    return j * n + i;
  }

  /// Metres to walk from each cell to ([e], [nn]): infinity where it cannot
  /// be reached. Built once per [key] (an objective id, a rally point).
  Float32List flowTo(String key, double e, double nn, {bool transient = false}) {
    final have = _fields[key];
    if (have != null) return have;
    built++;
    final f = _fields[key] = _dijkstra(e, nn);
    if (transient) {
      _transient.add(key);
      while (_transient.length > keepTransient) {
        _fields.remove(_transient.removeAt(0));
      }
    }
    return f;
  }

  Float32List _dijkstra(double e, double nn) => Float32List.fromList(_dijkstra64(e, nn));

  // In doubles: a distance popped from the heap must compare equal to the one
  // stored, and float32 storage rounds it, which skipped live nodes.
  Float64List _dijkstra64(double e, double nn) {
    final dist = Float64List(blocked.length)..fillRange(0, blocked.length, double.infinity);
    var goal = cellOf(e, nn);
    if (goal == null) return dist;
    // A goal inside a building: the nearest open cell stands in for it.
    if (blocked[goal] == 1) {
      var best = -1;
      var bd = double.infinity;
      for (var k = 0; k < blocked.length; k++) {
        if (blocked[k] == 1) continue;
        final (ce, cn) = raster.cellCentre(k);
        final d = _d2(ce, cn, e, nn);
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      if (best < 0) return dist;
      goal = best;
    }
    final heap = _Heap();
    dist[goal] = 0;
    heap.push(goal, 0);
    final c = raster.cellM, diag = raster.cellM * math.sqrt2;
    while (heap.isNotEmpty) {
      final (k, d) = heap.pop();
      if (d > dist[k]) continue;
      final i = k % n, j = k ~/ n;
      for (var dj = -1; dj <= 1; dj++) {
        for (var di = -1; di <= 1; di++) {
          if (di == 0 && dj == 0) continue;
          final ii = i + di, jj = j + dj;
          if (ii < 0 || jj < 0 || ii >= n || jj >= n) continue;
          final kk = jj * n + ii;
          if (blocked[kk] == 1) continue;
          // No cutting a blocked corner.
          if (di != 0 && dj != 0 && (blocked[j * n + ii] == 1 || blocked[jj * n + i] == 1)) continue;
          final nd = d + (di != 0 && dj != 0 ? diag : c);
          if (nd < dist[kk]) {
            dist[kk] = nd;
            heap.push(kk, nd);
          }
        }
      }
    }
    return dist;
  }

  /// One step of [stepM] metres from ([e], [nn]) down [field]: toward the
  /// neighbouring cell nearest the goal, or straight at the goal once in its
  /// cell. Null where the field cannot reach.
  (double, double)? step(Float32List field, double e, double nn, double stepM, (double, double) goal) {
    final k = cellOf(e, nn);
    if (k == null) return null;
    final here = field[k];
    final i = k % n, j = k ~/ n;
    if (here.isInfinite) {
      // Drifted into a shut cell (a corner of a building): back out to the
      // nearest reachable cell round it, never on through the wall.
      for (var ring = 1; ring <= 3; ring++) {
        var best = -1;
        var bd = double.infinity;
        for (var dj = -ring; dj <= ring; dj++) {
          for (var di = -ring; di <= ring; di++) {
            final ii = i + di, jj = j + dj;
            if (ii < 0 || jj < 0 || ii >= n || jj >= n) continue;
            final kk = jj * n + ii;
            if (field[kk].isInfinite) continue;
            final (ce, cn) = raster.cellCentre(kk);
            final d = _d2(ce, cn, e, nn);
            if (d < bd) {
              bd = d;
              best = kk;
            }
          }
        }
        if (best >= 0) {
          final (te, tn) = raster.cellCentre(best);
          return _toward(e, nn, te, tn, stepM);
        }
      }
      return null;
    }
    if (here <= raster.cellM * 1.5) return _toward(e, nn, goal.$1, goal.$2, stepM);
    var best = k;
    var bd = here;
    for (var dj = -1; dj <= 1; dj++) {
      for (var di = -1; di <= 1; di++) {
        final ii = i + di, jj = j + dj;
        if (ii < 0 || jj < 0 || ii >= n || jj >= n) continue;
        final kk = jj * n + ii;
        if (field[kk] < bd) {
          bd = field[kk];
          best = kk;
        }
      }
    }
    final (te, tn) = raster.cellCentre(best);
    return _toward(e, nn, te, tn, stepM);
  }

  /// Whether a line from (east, north, height above the ground there) [a] to
  /// [b] is clear of the raster's ground and the buildings.
  bool lineOfSight((double, double, double) a, (double, double, double) b) {
    final ra = raster.radiusAt(a.$1, a.$2), rb = raster.radiusAt(b.$1, b.$2);
    if (ra == null || rb == null) return true;
    final ya = ra + a.$3, yb = rb + b.$3;
    final len = math.sqrt(_d2(a.$1, a.$2, b.$1, b.$2));
    final steps = (len / 4).ceil();
    for (var s = 1; s < steps; s++) {
      final t = s / steps;
      final e = a.$1 + (b.$1 - a.$1) * t, nn = a.$2 + (b.$2 - a.$2) * t;
      final y = ya + (yb - ya) * t;
      final g = raster.radiusAt(e, nn);
      if (g != null && g > y - 0.2) return false;
    }
    for (final f in footprints) {
      // A shooter in a building fires out of it, and is seen in it: the
      // building round either end is no wall between them.
      if (_d2(a.$1, a.$2, f.$1, f.$2) < f.$3 * f.$3 || _d2(b.$1, b.$2, f.$1, f.$2) < f.$3 * f.$3) continue;
      // Closest approach of the segment to the building's centre, in plan.
      final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
      final l2 = dx * dx + dy * dy;
      final t = l2 <= 0 ? 0.0 : (((f.$1 - a.$1) * dx + (f.$2 - a.$2) * dy) / l2).clamp(0.0, 1.0);
      final pe = a.$1 + dx * t, pn = a.$2 + dy * t;
      if (_d2(pe, pn, f.$1, f.$2) >= f.$3 * f.$3) continue;
      // Over the roof?
      final g = raster.radiusAt(pe, pn) ?? ra;
      final y = ya + (yb - ya) * t;
      if (y - g < kBuildingHeightM) return false;
    }
    return true;
  }

  /// A step of [stepM] straight from ([e], [n]) toward ([te], [tn]).
  static (double, double) straight(double e, double n, double te, double tn, double stepM) =>
      _toward(e, n, te, tn, stepM);

  static (double, double) _toward(double e, double n, double te, double tn, double stepM) {
    final de = te - e, dn = tn - n;
    final l = math.sqrt(de * de + dn * dn);
    if (l <= stepM) return (te, tn);
    return (e + de / l * stepM, n + dn / l * stepM);
  }

  static double _d2(double a, double b, double c, double d) => (a - c) * (a - c) + (b - d) * (b - d);
}

/// A binary min-heap of (cell, distance).
class _Heap {
  final List<int> _k = [];
  final List<double> _d = [];
  bool get isNotEmpty => _k.isNotEmpty;

  void push(int k, double d) {
    _k.add(k);
    _d.add(d);
    var i = _k.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_d[p] <= _d[i]) break;
      _swap(i, p);
      i = p;
    }
  }

  (int, double) pop() {
    final top = (_k[0], _d[0]);
    final lastK = _k.removeLast(), lastD = _d.removeLast();
    if (_k.isNotEmpty) {
      _k[0] = lastK;
      _d[0] = lastD;
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        var m = i;
        if (l < _k.length && _d[l] < _d[m]) m = l;
        if (r < _k.length && _d[r] < _d[m]) m = r;
        if (m == i) break;
        _swap(i, m);
        i = m;
      }
    }
    return top;
  }

  void _swap(int a, int b) {
    final k = _k[a], d = _d[a];
    _k[a] = _k[b];
    _d[a] = _d[b];
    _k[b] = k;
    _d[b] = d;
  }
}
