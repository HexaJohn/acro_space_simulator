// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where handlers can walk, and the way to anything
/// (docs/plans/factory-floors.md §3 "Material handling").
///
/// A floor's handlers go to a FEW places over and over: the same press, the
/// same packer, the same dock. So instead of an A* per trip, each target gets
/// one FLOW FIELD — a breadth-first distance from every tile to the target's
/// goal tiles — built the first time a handler heads there and kept until
/// the layout changes. A handler then just steps to whichever neighbour is
/// one closer. Thousands of trips cost one BFS per target per layout edit.
///
/// Walkable = a hall tile no solid entity covers, except crossings (a
/// crossing is a belt tile with a walkway over it). Aisles, staging areas
/// and crane bays are floor markings and stay walkable. Path cost is tiles.
///
/// Deterministic: neighbours are always tried in [Dir4] order (east, north,
/// west, south), goals are seeded row-major, and the BFS queue is a plain
/// array — nothing depends on hash order.
library;

import 'dart:typed_data';

import 'factory_grid.dart';

/// Distance stored for a tile the target can't be reached from.
const int kUnreachable = -1;

class FloorPathing {
  FloorPathing(this.hall, this.walkable)
      : assert(walkable.length == hall.w * hall.h);

  final HallSize hall;

  /// 1 = walkable, row-major `y * w + x`.
  final Uint8List walkable;

  final Map<int, Int32List> _fields = {};

  int _index(TilePos t) => t.y * hall.w + t.x;

  bool isWalkable(TilePos t) =>
      hall.contains(t) && walkable[_index(t)] == 1;

  /// Number of flow fields built so far (the cache's size), for tests.
  int get cachedFields => _fields.length;

  /// The flow field to [targetId]'s [goals] (walkable tiles, row-major).
  /// Cached by [targetId]: the caller makes a fresh [FloorPathing] whenever
  /// the layout changes, which is the whole invalidation story.
  Int32List fieldTo(int targetId, List<TilePos> goals) =>
      _fields[targetId] ??= _bfs(goals);

  Int32List _bfs(List<TilePos> goals) {
    final w = hall.w, h = hall.h;
    final dist = Int32List(w * h)..fillRange(0, w * h, kUnreachable);
    final queue = Int32List(w * h);
    var head = 0, tail = 0;
    for (final g in goals) {
      if (!isWalkable(g)) continue;
      final i = _index(g);
      if (dist[i] != kUnreachable) continue;
      dist[i] = 0;
      queue[tail++] = i;
    }
    while (head < tail) {
      final i = queue[head++];
      final x = i % w, y = i ~/ w;
      final d = dist[i] + 1;
      for (final dir in Dir4.values) {
        final nx = x + dir.dx, ny = y + dir.dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final j = ny * w + nx;
        if (walkable[j] != 1 || dist[j] != kUnreachable) continue;
        dist[j] = d;
        queue[tail++] = j;
      }
    }
    return dist;
  }

  /// Tiles from [at] to the field's goal, or [kUnreachable].
  int distance(Int32List field, TilePos at) =>
      hall.contains(at) ? field[_index(at)] : kUnreachable;

  /// The neighbour of [at] one step closer along [field] (first in [Dir4]
  /// order on a tie), or null at a goal or when cut off.
  TilePos? nextStep(Int32List field, TilePos at) {
    final d = distance(field, at);
    if (d <= 0) return null;
    for (final dir in Dir4.values) {
      final n = at.step(dir);
      if (distance(field, n) == d - 1) return n;
    }
    return null;
  }

  /// The first walkable tile in row-major order, or null for a full hall.
  TilePos? firstWalkable() {
    for (var i = 0; i < walkable.length; i++) {
      if (walkable[i] == 1) return TilePos(i % hall.w, i ~/ hall.w);
    }
    return null;
  }

  /// The row-major first tile of the LARGEST connected walkable region (ties
  /// to the earlier region), or null for a full hall. Belts walling off a
  /// strip by the hall's origin must not strand a new hire there.
  TilePos? mainRegionStart() {
    final n = walkable.length;
    final seen = Uint8List(n);
    final queue = Int32List(n);
    var bestStart = -1, bestSize = 0;
    for (var s = 0; s < n; s++) {
      if (walkable[s] != 1 || seen[s] == 1) continue;
      var head = 0, tail = 0;
      seen[s] = 1;
      queue[tail++] = s;
      while (head < tail) {
        final i = queue[head++];
        final x = i % hall.w, y = i ~/ hall.w;
        for (final dir in Dir4.values) {
          final nx = x + dir.dx, ny = y + dir.dy;
          if (nx < 0 || ny < 0 || nx >= hall.w || ny >= hall.h) continue;
          final j = ny * hall.w + nx;
          if (walkable[j] != 1 || seen[j] == 1) continue;
          seen[j] = 1;
          queue[tail++] = j;
        }
      }
      if (tail > bestSize) {
        bestSize = tail;
        bestStart = s;
      }
    }
    return bestStart < 0 ? null : TilePos(bestStart % hall.w, bestStart ~/ hall.w);
  }
}
