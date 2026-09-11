// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/traffic/route_arena.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

/// The route arena: size classes, reuse, splitting, growth and compaction.
///
/// Its promises are that a live route is never touched by anyone else's
/// alloc, free or compaction, and that once a colony's route mix has warmed
/// up the arena stops growing (docs/plans/agent-traffic.md §2.10, §17.1).
void main() {
  /// Live routes, as their owner would hold them: an offset and a length per
  /// id, and contents that say which id and element they are.
  ({Int32List off, Int32List len, void Function(int) fill, int Function() bad})
      routes(RouteArena arena, int n) {
    final off = Int32List(n);
    final len = Int32List(n);
    int signature(int id, int k) => id * 4096 + k;
    return (
      off: off,
      len: len,
      fill: (id) {
        final d = arena.data;
        for (var k = 0; k < len[id]; k++) {
          d[off[id] + k] = signature(id, k);
        }
      },
      bad: () {
        final d = arena.data;
        var wrong = 0;
        for (var id = 0; id < n; id++) {
          for (var k = 0; k < len[id]; k++) {
            if (d[off[id] + k] != signature(id, k)) wrong++;
          }
        }
        return wrong;
      },
    );
  }

  test('size classes run 8 to 1,024 ints: the smallest that fits', () {
    expect([
      for (final len in const [1, 8, 9, 16, 17, 32, 33, 64, 65, 128, 129, //
        256, 257, 512, 513, 1024])
        RouteArena.classOf(len),
    ], const [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7]);
    expect([
      for (var c = 0; c < RouteArena.classCount; c++) RouteArena.blockSize(c),
    ], const [8, 16, 32, 64, 128, 256, 512, 1024]);
    expect(() => RouteArena.classOf(0), throwsRangeError);
    expect(() => RouteArena.classOf(1025), throwsRangeError,
        reason: 'a longer route is chained legs, split by the planner');
  });

  test('blocks never overlap, and hold what was written', () {
    final arena = RouteArena();
    final rng = TrafficRng(6);
    final r = routes(arena, 300);
    for (var id = 0; id < 300; id++) {
      r.len[id] = 1 + rng.nextInt(RouteArena.maxBlock);
      r.off[id] = arena.alloc(r.len[id]);
      r.fill(id);
    }
    expect(r.bad(), 0);
    final spans = [
      for (var id = 0; id < 300; id++)
        (r.off[id], r.off[id] + RouteArena.blockSize(RouteArena.classOf(r.len[id]))),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < spans.length; i++) {
      expect(spans[i].$1, greaterThanOrEqualTo(spans[i - 1].$2));
    }
    expect(spans.last.$2, lessThanOrEqualTo(arena.top));
    expect(arena.liveBlocks, 300);
  });

  test('a freed block is the next one of its class', () {
    final arena = RouteArena();
    final a = arena.alloc(20);
    final b = arena.alloc(20);
    arena.free(a, 20);
    expect(arena.usedInts, 32);
    expect(arena.alloc(30), a, reason: 'the same 32-int class, last freed');
    expect(arena.alloc(20), isNot(anyOf(a, b)));
    expect(arena.alloc(8), isNot(a), reason: 'classes do not share lists');
  });

  test('with the top used up, a larger free block is split before growing',
      () {
    final arena = RouteArena(2048);
    final big = arena.alloc(1024);
    arena.alloc(1024);
    arena.free(big, 1024);
    // 8 + (8 + 16 + … + 512) = 1024: the one freed block serves all of these.
    final offs = [
      for (final len in const [8, 8, 16, 32, 64, 128, 256, 512])
        arena.alloc(len),
    ];
    expect(arena.growths, 0);
    expect(arena.capacity, 2048);
    expect(offs.first, big);
    expect(offs.every((o) => o >= big && o < big + 1024), isTrue);
    expect(offs.toSet(), hasLength(offs.length));

    arena.alloc(8);
    expect(arena.growths, 1, reason: 'nothing left to split: it doubles');
    expect(arena.capacity, 4096);
  });

  test('growth doubles the arena and keeps every route', () {
    final arena = RouteArena(64);
    final r = routes(arena, 40);
    for (var id = 0; id < 40; id++) {
      r.len[id] = 1 + id * 7;
      r.off[id] = arena.alloc(r.len[id]);
      r.fill(id);
    }
    expect(arena.growths, greaterThan(0));
    expect(arena.capacity & (arena.capacity - 1), 0,
        reason: 'doubled from a power of two');
    expect(r.bad(), 0);
  });

  test('10k random cycles after warm-up cause no growth', () {
    // The design point: 2,000 live vehicles, each re-planned in turn.
    const n = 2000;
    final arena = RouteArena();
    final rng = TrafficRng(8);
    final r = routes(arena, n);
    void plan(int id) {
      r.len[id] = 1 + rng.nextInt(120);
      r.off[id] = arena.alloc(r.len[id]);
      r.fill(id);
    }

    void cycle() {
      final id = rng.nextInt(n);
      arena.free(r.off[id], r.len[id]);
      plan(id);
    }

    for (var id = 0; id < n; id++) {
      plan(id);
    }
    for (var i = 0; i < 5000; i++) {
      cycle();
    }
    final capacity = arena.capacity;
    final growths = arena.growths;
    for (var i = 0; i < 10000; i++) {
      cycle();
    }
    expect(arena.capacity, capacity);
    expect(arena.growths, growths);
    expect(arena.liveBlocks, n);
    expect(r.bad(), 0, reason: 'no route was touched by another');
  });

  test('compaction packs the live routes and keeps every one', () {
    const n = 400;
    final arena = RouteArena();
    final rng = TrafficRng(10);
    final r = routes(arena, n);
    final live = List.filled(n, true);
    // Long routes, then most of them dropped and short ones planned in their
    // place: the freed long blocks are stranded in the wrong class.
    for (var id = 0; id < n; id++) {
      r.len[id] = 200 + rng.nextInt(100);
      r.off[id] = arena.alloc(r.len[id]);
      r.fill(id);
    }
    for (var id = 0; id < n; id++) {
      if (id % 5 == 0) continue;
      arena.free(r.off[id], r.len[id]);
      live[id] = false;
    }
    for (var id = 0; id < n; id++) {
      if (live[id]) continue;
      r.len[id] = 1 + rng.nextInt(8);
      r.off[id] = arena.alloc(r.len[id]);
      r.fill(id);
      live[id] = true;
    }
    expect(arena.needsCompaction, isTrue);

    for (var round = 0; round < 2; round++) {
      arena.beginCompaction();
      for (var id = 0; id < n; id++) {
        r.off[id] = arena.relocate(r.off[id], r.len[id]);
      }
      arena.endCompaction();
      expect(arena.fragmentation, 0, reason: 'round $round');
      expect(arena.top, arena.usedInts);
      expect(arena.liveBlocks, n);
      expect(r.bad(), 0, reason: 'round $round kept every route');
    }

    // And it carries on as an arena.
    arena.free(r.off[0], r.len[0]);
    r.len[0] = 50;
    r.off[0] = arena.alloc(50);
    r.fill(0);
    expect(r.bad(), 0);
  });

  test('clear drops every block', () {
    final arena = RouteArena()
      ..alloc(10)
      ..alloc(300);
    arena.clear();
    expect(arena.top, 0);
    expect(arena.usedInts, 0);
    expect(arena.liveBlocks, 0);
    expect(arena.alloc(8), 0);
  });
}
