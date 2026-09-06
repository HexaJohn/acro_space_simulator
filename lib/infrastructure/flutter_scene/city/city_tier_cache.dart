// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The built sets a tile has already shown, kept by the key they answer.
///
/// A tile that changes tier — near to mid as the camera pulls out, mid
/// back to near as it returns — was rebuilt from scratch each way: the
/// worker meshed it again, the frame uploaded it again a slice at a time,
/// and the replaced set's GPU buffers went to the finalizers, whose
/// stop-the-world part is what the worst frames of a zoom were made of.
/// A zoom out and back rebuilt seventy-odd tiles twice for two sets each
/// of which the tile had held a few seconds earlier.
///
/// So a replaced set is PARKED here rather than dropped: its nodes come
/// out of the scene but keep their buffers, and a tile whose want key
/// comes back to one it holds re-attaches the set the same frame — no
/// meshing, no upload, no reveal, and no finalizer. The key is the tile's
/// whole want key (structure, tier, camera cell, flags, invalidation), so
/// a hit is exactly the build that would otherwise be made.
///
/// The budget is bytes, colony-wide: the sets are resident geometry, and
/// what bounds them is GPU memory, not a count. Past the budget the
/// least recently parked set goes first, whichever tile it belongs to;
/// a per-tile cap besides keeps one near tile that tracks the camera —
/// a new set every sixty-four metres — from filling the budget with
/// its own history and pushing every other tile's out.
///
/// Pure: the sets are opaque to it, which is how it is pinned without a
/// scene (see `test/flutter_scene/city_tier_cache_test.dart`).
library;

import 'dart:collection';

/// One parked set: the tile it belongs to, the key it answers, its bytes.
class _CachedSet<T> {
  _CachedSet(this.tile, this.key, this.set, this.bytes);
  final String tile;
  final String key;
  final T set;
  final int bytes;
}

/// Parked sets of type [T], by tile and want key, evicted least recently
/// parked first by bytes.
class CityTierCache<T> {
  /// Every parked set, oldest first: a [LinkedHashMap] keeps insertion
  /// order, and a set is only ever inserted (parked) or removed (taken,
  /// dropped, evicted), so the order IS the recency.
  final LinkedHashMap<String, _CachedSet<T>> _entries = LinkedHashMap();

  /// The keys each tile holds, so a tile's drop does not walk the map.
  final Map<String, Set<String>> _byTile = {};

  int _bytes = 0;

  /// Bytes of every set parked now.
  int get bytes => _bytes;

  /// Sets parked now, across every tile.
  int get sets => _entries.length;

  /// Sets parked for one tile.
  int setsOf(String tile) => _byTile[tile]?.length ?? 0;

  bool has(String tile, String key) => _entries.containsKey(_id(tile, key));

  static String _id(String tile, String key) => '$tile\u0000$key';

  /// The tile's set for [key], taken OUT of the cache — the caller is
  /// about to attach it, and a set in the scene is not a parked one — or
  /// null when the tile holds none for that key.
  T? take(String tile, String key) {
    final e = _remove(_id(tile, key));
    return e?.set;
  }

  /// Park [set] as the tile's answer to [key], sized [bytes], and evict
  /// what the budget no longer holds: the tile's oldest sets past
  /// [perTile] (0 for no cap), then the oldest sets of any tile while
  /// the total is over [budgetBytes]. Returns the sets evicted.
  ///
  /// A set alone over the budget is not kept at all — parking it would
  /// evict everything else for a set that will be evicted itself by the
  /// next — and a budget of zero keeps nothing, which is the off switch.
  /// The same tile and key parked twice keeps the newer set: the older
  /// one is returned as evicted.
  List<T> put(String tile, String key, T set, int bytes,
      {required int budgetBytes, int perTile = 0}) {
    final evicted = <T>[];
    if (budgetBytes <= 0 || bytes > budgetBytes) {
      evicted.add(set);
      return evicted;
    }
    final id = _id(tile, key);
    final old = _remove(id);
    if (old != null) evicted.add(old.set);
    if (perTile > 0) {
      final keys = _byTile[tile];
      while (keys != null && keys.length >= perTile) {
        // The tile's oldest: the first of its keys met walking the map.
        final oldest = _entries.values.firstWhere((e) => e.tile == tile);
        evicted.add(_remove(_id(oldest.tile, oldest.key))!.set);
      }
    }
    _entries[id] = _CachedSet(tile, key, set, bytes);
    _byTile.putIfAbsent(tile, () => {}).add(key);
    _bytes += bytes;
    while (_bytes > budgetBytes && _entries.length > 1) {
      final oldest = _entries.values.first;
      evicted.add(_remove(_id(oldest.tile, oldest.key))!.set);
    }
    return evicted;
  }

  /// Forget every set of one tile.
  ///
  /// The tile's members changed, or the tile itself is gone: nothing it
  /// held answers any key it will want again.
  List<T> dropTile(String tile) {
    final keys = _byTile.remove(tile);
    if (keys == null) return const [];
    final dropped = <T>[];
    for (final key in keys) {
      final e = _entries.remove(_id(tile, key));
      if (e == null) continue;
      _bytes -= e.bytes;
      dropped.add(e.set);
    }
    return dropped;
  }

  /// Forget everything.
  void clear() {
    _entries.clear();
    _byTile.clear();
    _bytes = 0;
  }

  /// Every set, and the cache emptied: the caller owns what leaves.
  List<T> drain() {
    final all = [for (final e in _entries.values) e.set];
    clear();
    return all;
  }

  _CachedSet<T>? _remove(String id) {
    final e = _entries.remove(id);
    if (e == null) return null;
    _bytes -= e.bytes;
    final keys = _byTile[e.tile];
    if (keys != null) {
      keys.remove(e.key);
      if (keys.isEmpty) _byTile.remove(e.tile);
    }
    return e;
  }
}
