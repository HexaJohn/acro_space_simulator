// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Slots for things that come and go, and handles that know when their thing
/// has gone.
///
/// A vehicle is a row in typed columns, not an object
/// (docs/plans/agent-traffic.md §2.1): a Dart object per car is a live object
/// per car for the collector to mark, and old-generation marking is what once
/// paused frames for 25–78 ms. So a vehicle is a SLOT, and whatever remembers
/// one — a queue, a follower, the inspector — holds a HANDLE: the slot, and
/// the generation it was handed out under. Freeing a slot moves its
/// generation on, so a handle kept past its vehicle's despawn reads as stale
/// instead of silently naming the next car to take the slot.
///
/// A handle is `gen << 20 | slot`: a slot below 2^20 and a generation below
/// 2^11, so it always stays below 2^31 — a plain positive int on every
/// platform, and one an `Int32List` holds without a sign flip. Generations
/// start at 1, so a zeroed column never reads as a live handle, and
/// [SlotPool.none] (-1) is no handle at all.
library;

import 'dart:typed_data';

/// A free list of slots, each with a generation.
///
/// It never grows by itself. Its owner's columns have to grow with it, so
/// [alloc] reports a full pool as [none] and the owner decides whether this
/// is a moment it may [grow] — during warm-up or a graph rebuild only (§2.1)
/// — or a trip that waits. Allocation is last-freed-first, and a fresh pool
/// hands its slots out lowest first: deterministic either way, which is all
/// the simulation asks of it.
class SlotPool {
  SlotPool(int capacity)
      : _gen = Uint16List(
            RangeError.checkValueInInterval(capacity, 1, maxSlots, 'capacity')),
        _live = Uint8List(capacity),
        _free = Int32List(capacity) {
    _gen.fillRange(0, capacity, 1);
    _stackAllFree();
  }

  /// Bits of a handle that hold the slot.
  static const int slotBits = 20;

  /// The most slots a pool can hold: 2^20.
  static const int maxSlots = 1 << slotBits;

  /// Masks a handle down to its slot.
  static const int slotMask = maxSlots - 1;

  /// Generations run 1 … [genLimit] − 1 and then wrap to 1, so that
  /// `gen << 20` stays below 2^31.
  static const int genLimit = 1 << 11;

  /// No handle.
  static const int none = -1;

  Uint16List _gen;
  Uint8List _live;

  /// The free slots as a stack: [_freeTop] entries, the next to go on top.
  Int32List _free;
  int _freeTop = 0;

  int _liveCount = 0;
  int _highWater = 0;

  /// Slots in the pool.
  int get capacity => _gen.length;

  /// Slots handed out and not freed.
  int get liveCount => _liveCount;

  /// One past the highest slot handed out since the pool was made or
  /// cleared: iteration in slot order runs `0 <= slot < highWater` and skips
  /// the slots that are not [isSlotLive].
  int get highWater => _highWater;

  /// Whether [alloc] would return [none].
  bool get isFull => _freeTop == 0;

  /// The slot of [handle].
  static int slotOf(int handle) => handle & slotMask;

  /// The generation of [handle].
  static int genOf(int handle) => handle >> slotBits;

  /// A slot, as a handle under its current generation; [none] when every
  /// slot is live.
  int alloc() {
    if (_freeTop == 0) return none;
    final slot = _free[--_freeTop];
    _live[slot] = 1;
    _liveCount++;
    if (slot >= _highWater) _highWater = slot + 1;
    return (_gen[slot] << slotBits) | slot;
  }

  /// Frees [handle]'s slot and moves its generation on, so every copy of
  /// [handle] goes stale. A stale or foreign handle frees nothing and
  /// returns false — so freeing twice is harmless, never a corrupt list.
  bool free(int handle) {
    if (!isLive(handle)) return false;
    final slot = handle & slotMask;
    _live[slot] = 0;
    _liveCount--;
    _gen[slot] = _nextGen(_gen[slot]);
    _free[_freeTop++] = slot;
    return true;
  }

  /// Whether [handle] names a slot that is live under the same generation.
  bool isLive(int handle) {
    if (handle < 0) return false;
    final slot = handle & slotMask;
    return slot < _gen.length &&
        _live[slot] == 1 &&
        _gen[slot] == handle >> slotBits;
  }

  /// Whether [slot] is handed out — for iteration in slot order.
  bool isSlotLive(int slot) => _live[slot] == 1;

  /// The handle of the live [slot].
  int handleOf(int slot) => (_gen[slot] << slotBits) | slot;

  /// Grows the pool to [newCapacity] slots, at most [maxSlots].
  ///
  /// Live handles stay live. The slots already free are handed out first,
  /// then the new ones, lowest first.
  void grow(int newCapacity) {
    final old = capacity;
    RangeError.checkValueInInterval(
        newCapacity, old + 1, maxSlots, 'newCapacity');
    _gen = Uint16List(newCapacity)
      ..setRange(0, old, _gen)
      ..fillRange(old, newCapacity, 1);
    _live = Uint8List(newCapacity)..setRange(0, old, _live);
    final free = Int32List(newCapacity);
    var k = 0;
    for (var s = newCapacity - 1; s >= old; s--) {
      free[k++] = s;
    }
    for (var i = 0; i < _freeTop; i++) {
      free[k++] = _free[i];
    }
    _free = free;
    _freeTop = k;
  }

  /// Frees every slot at once. Every outstanding handle goes stale, and the
  /// next [alloc] starts again from slot 0.
  void clear() {
    for (var s = 0; s < _highWater; s++) {
      if (_live[s] == 0) continue;
      _live[s] = 0;
      _gen[s] = _nextGen(_gen[s]);
    }
    _stackAllFree();
    _liveCount = 0;
    _highWater = 0;
  }

  /// Every slot on the free stack, slot 0 on top.
  void _stackAllFree() {
    final n = _free.length;
    for (var i = 0; i < n; i++) {
      _free[i] = n - 1 - i;
    }
    _freeTop = n;
  }

  /// The generation after [g]: 1 after the last, never 0.
  static int _nextGen(int g) => g + 1 >= genLimit ? 1 : g + 1;
}
