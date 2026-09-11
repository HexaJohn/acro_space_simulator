// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

/// Slots and their generations. The pool's whole job is that a handle kept
/// past its vehicle's despawn reads as stale — never as the next car to take
/// the slot.
void main() {
  test('a fresh pool hands out its slots lowest first, as live handles', () {
    final pool = SlotPool(4);
    final hs = [for (var i = 0; i < 4; i++) pool.alloc()];
    expect([for (final h in hs) SlotPool.slotOf(h)], const [0, 1, 2, 3]);
    expect([for (final h in hs) SlotPool.genOf(h)], everyElement(1));
    expect(hs.every(pool.isLive), isTrue);
    expect(pool.liveCount, 4);
    expect(pool.highWater, 4);
    expect(pool.isFull, isTrue);
    expect(pool.alloc(), SlotPool.none);
    expect(pool.isLive(0), isFalse,
        reason: 'a zeroed column never names a live slot');
    expect(pool.isLive(SlotPool.none), isFalse);
  });

  test('freeing moves the generation on, so old handles go stale', () {
    final pool = SlotPool(4);
    final a = pool.alloc();
    expect(pool.free(a), isTrue);
    expect(pool.isLive(a), isFalse);
    expect(pool.free(a), isFalse, reason: 'freeing twice is a no-op');
    expect(pool.liveCount, 0);

    final b = pool.alloc();
    expect(SlotPool.slotOf(b), SlotPool.slotOf(a), reason: 'slot reused');
    expect(SlotPool.genOf(b), SlotPool.genOf(a) + 1);
    expect(pool.isLive(b), isTrue);
    expect(pool.isLive(a), isFalse,
        reason: 'the old handle does not name the new occupant');
  });

  test('generations wrap to 1, never 0, and a handle stays below 2^31', () {
    final pool = SlotPool(1);
    final gens = <int>{};
    var h = pool.alloc();
    for (var i = 0; i < 3 * SlotPool.genLimit; i++) {
      gens.add(SlotPool.genOf(h));
      pool.free(h);
      h = pool.alloc();
    }
    expect(gens, hasLength(SlotPool.genLimit - 1));
    expect(gens.contains(0), isFalse);
    expect(gens.reduce((a, b) => a > b ? a : b), SlotPool.genLimit - 1);
    // The largest handle any pool can make.
    expect(
        ((SlotPool.genLimit - 1) << SlotPool.slotBits) | SlotPool.slotMask,
        0x7FFFFFFF);
  });

  test('growing keeps live handles and hands out the old free slots first',
      () {
    final pool = SlotPool(4);
    final hs = [for (var i = 0; i < 4; i++) pool.alloc()];
    pool.free(hs[1]);
    pool.grow(8);
    expect(pool.capacity, 8);
    expect([hs[0], hs[2], hs[3]].every(pool.isLive), isTrue);
    expect([for (var i = 0; i < 5; i++) SlotPool.slotOf(pool.alloc())],
        const [1, 4, 5, 6, 7]);
    expect(pool.isFull, isTrue);
    expect(() => pool.grow(8), throwsRangeError, reason: 'grow only grows');
    expect(() => SlotPool(0), throwsRangeError);
    expect(() => SlotPool(SlotPool.maxSlots + 1), throwsRangeError);
  });

  test('a walk in slot order sees exactly the live slots', () {
    final pool = SlotPool(16);
    final rng = TrafficRng(2);
    final live = <int>[];
    for (var i = 0; i < 10000; i++) {
      if (live.isNotEmpty && (pool.isFull || rng.nextInt(2) == 0)) {
        final h = live.removeAt(rng.nextInt(live.length));
        expect(pool.free(h), isTrue);
      } else {
        final h = pool.alloc();
        expect(pool.isLive(h), isTrue);
        expect(live.contains(h), isFalse);
        live.add(h);
      }
      expect(pool.liveCount, live.length);
    }
    final walked = [
      for (var s = 0; s < pool.highWater; s++)
        if (pool.isSlotLive(s)) pool.handleOf(s),
    ];
    expect(walked.toSet(), live.toSet());
    expect(walked, hasLength(live.length));
  });

  test('clear frees everything, and every old handle goes stale', () {
    final pool = SlotPool(4);
    final hs = [for (var i = 0; i < 3; i++) pool.alloc()];
    pool.clear();
    expect(pool.liveCount, 0);
    expect(pool.highWater, 0);
    expect(hs.any(pool.isLive), isFalse);
    final again = pool.alloc();
    expect(SlotPool.slotOf(again), 0);
    expect(again, isNot(hs[0]));
  });
}
