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
/// **Layers** (phase 4). Walkers path on the walkable mask, layer 0. Other
/// handler kinds path on their own masks ([setLayer]: a forklift's
/// drivable aisles, a crane's bay), and the one cache holds fields for all
/// of them keyed by (layer, target), so the bound below covers every kind.
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
  /// the first key. Keyed by (layer, target).
  final LinkedHashMap<(int, int), Uint16List> _fields = LinkedHashMap();

  /// Passability masks other than layer 0 ([walkable]), by layer id.
  final Map<int, Uint8List> _layers = {};

  int _index(TilePos t) => t.y * hall.w + t.x;

  bool isWalkable(TilePos t) =>
      hall.contains(t) && walkable[_index(t)] == 1;

  /// Sets layer [layer]'s mask (same shape as [walkable]; 1 = passable).
  /// Layer 0 is always [walkable]. Call before asking for its fields.
  void setLayer(int layer, Uint8List mask) {
    assert(layer != 0 && mask.length == walkable.length);
    _layers[layer] = mask;
    _regions.remove(layer);
  }

  /// [layer]'s mask, or null for a layer never set (nothing passable).
  Uint8List? maskOf(int layer) => layer == 0 ? walkable : _layers[layer];

  /// Whether [t] is passable on [layer].
  bool isPassable(int layer, TilePos t) {
    if (!hall.contains(t)) return false;
    final m = maskOf(layer);
    return m != null && m[_index(t)] == 1;
  }

  /// Number of flow fields built so far (the cache's size), for tests.
  int get cachedFields => _fields.length;

  /// Whether [targetId]'s field on [layer] is cached now (tests).
  bool isCached(int targetId, {int layer = 0}) =>
      _fields.containsKey((layer, targetId));

  /// The flow field to [targetId]'s [goals] (passable tiles, row-major) on
  /// [layer]. Cached by (layer, target) (any ints: the floor reserves
  /// negative target keys for floor piles and the idle spot); the caller
  /// makes a fresh [FloorPathing] whenever the layout changes, which is the
  /// whole invalidation story, and must always pass the same goals for one
  /// key within one layout.
  Uint16List fieldTo(int targetId, List<TilePos> goals, {int layer = 0}) {
    final key = (layer, targetId);
    final hit = _fields.remove(key);
    if (hit != null) {
      _fields[key] = hit;
      return hit;
    }
    while (_fields.length >= maxFields) {
      _fields.remove(_fields.keys.first);
    }
    final mask = maskOf(layer) ?? Uint8List(walkable.length);
    return _fields[key] = _bfs(goals, mask);
  }

  Uint16List _bfs(List<TilePos> goals, Uint8List walkable) {
    final w = hall.w, h = hall.h;
    final dist = Uint16List(w * h)..fillRange(0, w * h, _kFar);
    final queue = Int32List(w * h);
    var head = 0, tail = 0;
    for (final g in goals) {
      if (!hall.contains(g)) continue;
      final i = _index(g);
      if (walkable[i] != 1) continue;
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

  /// Connected-region labels of [layer] (4-neighbour), cached per layer:
  /// -1 for an impassable tile, else the region's index in row-major order
  /// of its first tile. Handlers never leave the region they stand in
  /// between layout edits, so "which handlers could ever get there" is a
  /// region question, not a per-trip one.
  Int32List regionsOf(int layer) => _regions[layer] ??= _label(layer);

  final Map<int, Int32List> _regions = {};

  /// Tile count of each region of [layer], by region index.
  List<int> regionSizes(int layer) {
    final labels = regionsOf(layer);
    final out = <int>[];
    for (final r in labels) {
      if (r < 0) continue;
      while (out.length <= r) {
        out.add(0);
      }
      out[r]++;
    }
    return out;
  }

  /// The region [t] lies in on [layer], or -1 (impassable / outside).
  int regionAt(int layer, TilePos t) =>
      hall.contains(t) ? regionsOf(layer)[_index(t)] : -1;

  /// The LARGEST region of [layer] (ties to the earlier one), or -1.
  int largestRegion(int layer) {
    final sizes = regionSizes(layer);
    var best = -1, bestSize = 0;
    for (var r = 0; r < sizes.length; r++) {
      if (sizes[r] > bestSize) {
        best = r;
        bestSize = sizes[r];
      }
    }
    return best;
  }

  Int32List _label(int layer) {
    final mask = maskOf(layer) ?? Uint8List(walkable.length);
    final n = mask.length;
    final labels = Int32List(n)..fillRange(0, n, -1);
    final queue = Int32List(n);
    var next = 0;
    for (var s = 0; s < n; s++) {
      if (mask[s] != 1 || labels[s] >= 0) continue;
      final r = next++;
      var head = 0, tail = 0;
      labels[s] = r;
      queue[tail++] = s;
      while (head < tail) {
        final i = queue[head++];
        final x = i % hall.w, y = i ~/ hall.w;
        for (final dir in Dir4.values) {
          final nx = x + dir.dx, ny = y + dir.dy;
          if (nx < 0 || ny < 0 || nx >= hall.w || ny >= hall.h) continue;
          final j = ny * hall.w + nx;
          if (mask[j] != 1 || labels[j] >= 0) continue;
          labels[j] = r;
          queue[tail++] = j;
        }
      }
    }
    return labels;
  }

  /// The row-major first tile of the LARGEST connected passable region on
  /// [layer] (ties to the earlier region), or null when nothing is
  /// passable. Belts walling off a strip by the hall's origin must not
  /// strand a new hire there.
  TilePos? mainRegionStart({int layer = 0}) {
    if (maskOf(layer) == null) return null;
    final r = largestRegion(layer);
    if (r < 0) return null;
    final labels = regionsOf(layer);
    for (var i = 0; i < labels.length; i++) {
      if (labels[i] == r) return TilePos(i % hall.w, i ~/ hall.w);
    }
    return null;
  }
}
