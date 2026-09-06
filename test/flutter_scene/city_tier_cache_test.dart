// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The tier cache's bookkeeping: what it keeps, what it evicts first, and
// what its byte count says after each. The sets are opaque to it, so
// they are strings here; what the scene does with a hit is CityNodes's.

import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tier_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mib = 1 << 20;

  test('a parked set is taken back once, by tile and key, and then gone', () {
    final cache = CityTierCache<String>();
    expect(cache.put('t1', 'near', 'A', 3 * mib, budgetBytes: 64 * mib),
        isEmpty);
    expect(cache.sets, 1);
    expect(cache.bytes, 3 * mib);
    expect(cache.has('t1', 'near'), isTrue);
    // Another tile's same key is another set.
    expect(cache.take('t2', 'near'), isNull);
    expect(cache.take('t1', 'mid'), isNull);
    expect(cache.take('t1', 'near'), 'A');
    expect(cache.take('t1', 'near'), isNull);
    expect(cache.sets, 0);
    expect(cache.bytes, 0);
    expect(cache.setsOf('t1'), 0);
  });

  test('over the budget the least recently parked set goes, any tile', () {
    final cache = CityTierCache<String>();
    const budget = 10 * mib;
    cache.put('t1', 'near', 'A', 4 * mib, budgetBytes: budget);
    cache.put('t2', 'near', 'B', 4 * mib, budgetBytes: budget);
    // 12 MiB: the oldest, t1's, goes — not the one just parked.
    expect(cache.put('t3', 'near', 'C', 4 * mib, budgetBytes: budget), ['A']);
    expect(cache.sets, 2);
    expect(cache.bytes, 8 * mib);
    expect(cache.has('t1', 'near'), isFalse);
    expect(cache.has('t2', 'near'), isTrue);
    expect(cache.has('t3', 'near'), isTrue);
    // A big one evicts as many as it takes.
    expect(cache.put('t4', 'near', 'D', 9 * mib, budgetBytes: budget),
        ['B', 'C']);
    expect(cache.sets, 1);
    expect(cache.bytes, 9 * mib);
  });

  test('a set alone over the budget is not kept, and zero keeps nothing',
      () {
    final cache = CityTierCache<String>();
    cache.put('t1', 'near', 'A', 4 * mib, budgetBytes: 10 * mib);
    expect(cache.put('t2', 'near', 'B', 11 * mib, budgetBytes: 10 * mib),
        ['B']);
    // The one already parked is untouched by a set that could never fit.
    expect(cache.sets, 1);
    expect(cache.has('t1', 'near'), isTrue);
    expect(cache.put('t3', 'near', 'C', 1, budgetBytes: 0), ['C']);
    expect(cache.sets, 1);
  });

  test('the same tile and key parked again keeps the newer set', () {
    final cache = CityTierCache<String>();
    cache.put('t1', 'near', 'A', 2 * mib, budgetBytes: 64 * mib);
    expect(cache.put('t1', 'near', 'A2', 3 * mib, budgetBytes: 64 * mib),
        ['A']);
    expect(cache.sets, 1);
    expect(cache.bytes, 3 * mib);
    expect(cache.take('t1', 'near'), 'A2');
  });

  test('a per-tile cap evicts that tile\'s oldest, leaving other tiles', () {
    final cache = CityTierCache<String>();
    const budget = 64 * mib;
    cache.put('t1', 'cam0', 'A0', mib, budgetBytes: budget, perTile: 2);
    cache.put('t2', 'near', 'B', mib, budgetBytes: budget, perTile: 2);
    cache.put('t1', 'cam1', 'A1', mib, budgetBytes: budget, perTile: 2);
    expect(
        cache.put('t1', 'cam2', 'A2', mib, budgetBytes: budget, perTile: 2),
        ['A0']);
    expect(cache.setsOf('t1'), 2);
    expect(cache.has('t1', 'cam1'), isTrue);
    expect(cache.has('t1', 'cam2'), isTrue);
    expect(cache.has('t2', 'near'), isTrue);
    expect(cache.bytes, 3 * mib);
    // No cap: the tile keeps all it parks.
    cache.put('t1', 'cam3', 'A3', mib, budgetBytes: budget);
    expect(cache.setsOf('t1'), 3);
  });

  test('dropping a tile forgets only its sets, bytes included', () {
    final cache = CityTierCache<String>();
    cache.put('t1', 'near', 'A', 2 * mib, budgetBytes: 64 * mib);
    cache.put('t1', 'mid', 'A\'', mib, budgetBytes: 64 * mib);
    cache.put('t2', 'near', 'B', 4 * mib, budgetBytes: 64 * mib);
    expect(cache.dropTile('t1'), unorderedEquals(['A', 'A\'']));
    expect(cache.dropTile('t1'), isEmpty);
    expect(cache.sets, 1);
    expect(cache.bytes, 4 * mib);
    expect(cache.take('t2', 'near'), 'B');
    cache.put('t2', 'near', 'B', 4 * mib, budgetBytes: 64 * mib);
    cache.clear();
    expect(cache.sets, 0);
    expect(cache.bytes, 0);
    expect(cache.has('t2', 'near'), isFalse);
  });

  test('taking a set makes room without an eviction', () {
    final cache = CityTierCache<String>();
    const budget = 8 * mib;
    cache.put('t1', 'near', 'A', 4 * mib, budgetBytes: budget);
    cache.put('t2', 'near', 'B', 4 * mib, budgetBytes: budget);
    expect(cache.take('t1', 'near'), 'A');
    expect(cache.put('t3', 'near', 'C', 4 * mib, budgetBytes: budget),
        isEmpty);
    expect(cache.bytes, 8 * mib);
    expect(cache.has('t2', 'near'), isTrue);
  });
}
