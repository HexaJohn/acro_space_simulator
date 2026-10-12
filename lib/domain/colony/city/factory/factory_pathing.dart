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
///
/// **Memory.** A field is one [Uint16List] (2 bytes a tile: 15 KB for a
/// 100 × 75 hall), and the cache keeps at most [kMaxCachedFields] of them,
/// least recently used out first. Eviction never changes a result — a field
/// is a pure function of the layout and its goals, so a rebuilt one is
/// identical — only how often a BFS runs. The LRU order itself is driven
/// by the deterministic sim, so even the BFS count is reproducible.
library;

import 'dart:collection';

import 'dart:typed_data';

import 'factory_grid.dart';

/// Distance [FloorPathing.distance] reports for a tile the target can't be
/// reached from.
const int kUnreachable = -1;

/// The [Uint16List] cell value for "unreachable". A path this long or
/// longer (65,535 tiles: far beyond any hall's aisle network) is treated as
/// unreachable rather than wrapping.
const int _kFar = 0xFFFF;

/// Flow fields one floor keeps at once (about 1 MB for a 100 × 75 hall).
/// A floor's busy targets are its stations, docks and the idle spot — a
/// few dozen at most — so a template never evicts in steady state.
const int kMaxCachedFields = 64;

class FloorPathing {
  FloorPathing(this.hall, this.walkable, {this.maxFields = kMaxCachedFields})
      : assert(walkable.length == hall.w * hall.h),
        assert(maxFields > 0);

  final HallSize hall;

  /// 1 = walkable, row-major `y * w + x`.
  final Uint8List walkable;

  /// Cache bound (see [kMaxCachedFields]).
  final int maxFields;

  /// Insertion order = recency: a hit is moved to the end, eviction takes
  /// the first key.
  final LinkedHashMap<int, Uint16List> _fields = LinkedHashMap();

  int _index(TilePos t) => t.y * hall.w + t.x;

  bool isWalkable(TilePos t) =>
      hall.contains(t) && walkable[_index(t)] == 1;

  /// Number of flow fields built so far (the cache's size), for tests.
  int get cachedFields => _fields.length;

  /// Whether [targetId]'s field is cached now (tests).
  bool isCached(int targetId) => _fields.containsKey(targetId);

  /// The flow field to [targetId]'s [goals] (walkable tiles, row-major).
  /// Cached by [targetId] (any int: the floor reserves negative keys for
  /// floor piles and the idle spot); the caller makes a fresh [FloorPathing]
  /// whenever the layout changes, which is the whole invalidation story, and
  /// must always pass the same goals for one key within one layout.
  Uint16List fieldTo(int targetId, List<TilePos> goals) {
    final hit = _fields.remove(targetId);
    if (hit != null) {
      _fields[targetId] = hit;
      return hit;
    }
    while (_fields.length >= maxFields) {
      _fields.remove(_fields.keys.first);
    }
    return _fields[targetId] = _bfs(goals);
  }

  Uint16List _bfs(List<TilePos> goals) {
    final w = hall.w, h = hall.h;
    final dist = Uint16List(w * h)..fillRange(0, w * h, _kFar);
    final queue = Int32List(w * h);
    var head = 0, tail = 0;
    for (final g in goals) {
      if (!isWalkable(g)) continue;
      final i = _index(g);
      if (dist[i] != _kFar) continue;
      dist[i] = 0;
      queue[tail++] = i;
    }
    while (head < tail) {
      final i = queue[head++];
      final x = i % w, y = i ~/ w;
      final d = dist[i] + 1;
      if (d >= _kFar) continue; // too far to store: unreachable
      for (final dir in Dir4.values) {
        final nx = x + dir.dx, ny = y + dir.dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final j = ny * w + nx;
        if (walkable[j] != 1 || dist[j] != _kFar) continue;
        dist[j] = d;
        queue[tail++] = j;
      }
    }
    return dist;
  }

  /// Tiles from [at] to the field's goal, or [kUnreachable].
  int distance(Uint16List field, TilePos at) {
    if (!hall.contains(at)) return kUnreachable;
    final d = field[_index(at)];
    return d == _kFar ? kUnreachable : d;
  }

  /// The neighbour of [at] one step closer along [field] (first in [Dir4]
  /// order on a tie), or null at a goal or when cut off.
  TilePos? nextStep(Uint16List field, TilePos at) {
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
