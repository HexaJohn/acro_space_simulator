// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where locked routes live: one `Int32List`, carved into power-of-two blocks.
///
/// A route is the connector list a trip locked when it was planned,
/// `[firstLane, conn1, …, connN]` (docs/plans/agent-traffic.md §2.10).
/// Thousands are alive at once, and one is made and dropped every trip, so
/// they cannot be `List<int>`s: a list per trip is a live object per trip for
/// the collector, and garbage per trip. They live in one arena instead. A
/// vehicle holds an offset and a length, and the mover reads
/// `data[off + cursor]`.
///
/// Blocks come in eight size classes, 8 to 1,024 ints, each with its own free
/// list threaded through the free blocks themselves, so allocating and
/// freeing are a few integer writes and never touch the Dart heap. A class
/// with nothing free carves a block from the unused top; with no room at the
/// top, a larger free block is split; only when nothing fits does the arena
/// grow, by doubling. Blocks are never merged, so a shifting mix of route
/// lengths can strand free space in the wrong classes. That is what
/// compaction is for ([beginCompaction]).
///
/// No route is longer than [RouteArena.maxBlock]. Only freight crossing a
/// whole sprawl gets that long, and the planner splits it at a waypoint into
/// chained legs before it gets here.
library;

import 'dart:typed_data';

/// An arena of route blocks. Offsets it hands out index [data].
class RouteArena {
  RouteArena([int capacity = initialCapacity])
      : _data = Int32List(_checkCapacity(capacity)),
        _twin = Int32List(capacity);

  /// 262,144 ints, 1 MB: the design point's routes with room to spare.
  static const int initialCapacity = 262144;

  /// The smallest block, ints.
  static const int minBlock = 8;

  /// The largest block, ints, and so the longest route.
  static const int maxBlock = 1024;

  /// Size classes: 8, 16, 32, … 1,024.
  static const int classCount = 8;

  Int32List _data;

  /// A second buffer the size of [_data], kept so a compaction allocates
  /// nothing (§15.2).
  Int32List _twin;

  /// The unused top: every block starts below it.
  int _top = 0;

  /// Each class's free list: the first free block, or -1. A free block's
  /// first int is the next free block of its class.
  final Int32List _freeHead = Int32List(classCount)
    ..fillRange(0, classCount, -1);

  int _usedInts = 0;
  int _liveBlocks = 0;
  int _growths = 0;

  /// Where the next compacted block goes, or -1 outside a compaction.
  int _compactTop = -1;
  int _compactBlocks = 0;

  static int _checkCapacity(int capacity) {
    if (capacity < minBlock) {
      throw RangeError.range(capacity, minBlock, null, 'capacity');
    }
    return capacity;
  }

  /// The ints. Routes are read and written in place at the offsets [alloc]
  /// returns. Read it again after any [alloc] (growth replaces it) and after
  /// a compaction.
  Int32List get data => _data;

  /// Ints the arena holds.
  int get capacity => _data.length;

  /// The unused top: every block, live or free, lies below it.
  int get top => _top;

  /// Ints in live blocks, counted by block size.
  int get usedInts => _usedInts;

  /// Blocks handed out and not freed.
  int get liveBlocks => _liveBlocks;

  /// Times the arena has doubled.
  int get growths => _growths;

  /// The share of the carved space sitting in free blocks, 0..1.
  double get fragmentation => _top == 0 ? 0 : (_top - _usedInts) / _top;

  /// Whether a compaction would pay: more than half the carved space is free
  /// (§2.10).
  bool get needsCompaction => fragmentation > 0.5;

  /// The size class of a route of [len] ints, 1 ≤ [len] ≤ [maxBlock].
  static int classOf(int len) {
    if (len < 1 || len > maxBlock) {
      throw RangeError.range(len, 1, maxBlock, 'len');
    }
    return len <= minBlock ? 0 : (len - 1).bitLength - 3;
  }

  /// Ints in a block of class [cls].
  static int blockSize(int cls) => minBlock << cls;

  /// A block for a route of [len] ints, as its offset into [data].
  ///
  /// The block holds [blockSize] of [classOf] ([len]) ints; its contents are
  /// whatever was last there.
  int alloc(int len) {
    assert(_compactTop < 0, 'alloc during a compaction');
    final cls = classOf(len);
    final size = minBlock << cls;
    var off = _freeHead[cls];
    if (off >= 0) {
      _freeHead[cls] = _data[off];
    } else if (_top + size <= _data.length) {
      off = _top;
      _top += size;
    } else {
      off = _split(cls);
      if (off < 0) {
        _grow(_top + size);
        off = _top;
        _top += size;
      }
    }
    _usedInts += size;
    _liveBlocks++;
    return off;
  }

  /// Returns the block at [off], which was allocated for a route of [len].
  void free(int off, int len) {
    assert(_compactTop < 0, 'free during a compaction');
    final cls = classOf(len);
    assert(off >= 0 && off + blockSize(cls) <= _top,
        'block $off is not in this arena');
    _data[off] = _freeHead[cls];
    _freeHead[cls] = off;
    _usedInts -= minBlock << cls;
    _liveBlocks--;
  }

  /// Drops every block at once.
  void clear() {
    assert(_compactTop < 0, 'clear during a compaction');
    _top = 0;
    _usedInts = 0;
    _liveBlocks = 0;
    _freeHead.fillRange(0, classCount, -1);
  }

  /// Starts a compaction. Every live block must now be [relocate]d, once,
  /// before [endCompaction]; nothing may be allocated or freed in between.
  ///
  /// The arena cannot find the owners of its blocks, so the owners drive it:
  /// the vehicle table walks its slots in order, relocates each route and
  /// stores the new offset, and the lines do the same for theirs.
  void beginCompaction() {
    assert(_compactTop < 0, 'a compaction is already running');
    _compactTop = 0;
    _compactBlocks = 0;
  }

  /// Copies the live block at [off], holding a route of [len], into the
  /// compacted arena, and returns its offset there — which names it only
  /// after [endCompaction].
  int relocate(int off, int len) {
    assert(_compactTop >= 0, 'relocate outside a compaction');
    final size = blockSize(classOf(len));
    final to = _compactTop;
    for (var i = 0; i < len; i++) {
      _twin[to + i] = _data[off + i];
    }
    _compactTop = to + size;
    _compactBlocks++;
    return to;
  }

  /// Ends a compaction: the relocated blocks, packed from 0, become the arena,
  /// and every block not relocated is gone. The old buffer becomes the next
  /// compaction's twin.
  void endCompaction() {
    assert(_compactTop >= 0, 'no compaction to end');
    final old = _data;
    _data = _twin;
    _twin = old;
    _top = _compactTop;
    _usedInts = _compactTop;
    _liveBlocks = _compactBlocks;
    _freeHead.fillRange(0, classCount, -1);
    _compactTop = -1;
  }

  /// A block of class [cls] cut from the smallest larger free block, or -1
  /// when there is none. The caller takes the front of it; the rest goes
  /// back as one free block of each class from [cls] up, which sums exactly:
  /// 2^k = 2^j + (2^j + 2^(j+1) + … + 2^(k-1)).
  int _split(int cls) {
    for (var c = cls + 1; c < classCount; c++) {
      final off = _freeHead[c];
      if (off < 0) continue;
      _freeHead[c] = _data[off];
      var at = off + blockSize(cls);
      for (var k = cls; k < c; k++) {
        _data[at] = _freeHead[k];
        _freeHead[k] = at;
        at += blockSize(k);
      }
      return off;
    }
    return -1;
  }

  /// Doubles the arena (and its twin) until [need] ints fit.
  void _grow(int need) {
    var cap = _data.length;
    while (cap < need) {
      cap *= 2;
    }
    _data = Int32List(cap)..setRange(0, _top, _data);
    _twin = Int32List(cap);
    _growths++;
  }
}
