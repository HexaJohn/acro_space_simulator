// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The chunk buffer pool's policy, without a GPU: the size classes a
// request rounds to, the cooling a released buffer must serve before it
// is handed out again (an in-flight frame may still read it), the byte
// budget that drops the coldest buffers, and the hit/miss accounting the
// studio's panel reads. The engine's buffers are never touched here: the
// pool is generic over its handle, and these use a stand-in.

import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/device_buffer_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// A buffer that is only its identity and size.
class _Buf {
  _Buf(this.sizeInBytes);
  final int sizeInBytes;
}

void main() {
  const kib = 1024;
  const mib = 1024 * kib;

  group('size classes', () {
    test('round up to the next power of two from 256 KiB to 4 MiB', () {
      expect(DeviceBufferPool.classFor(1), 256 * kib);
      expect(DeviceBufferPool.classFor(256 * kib), 256 * kib);
      expect(DeviceBufferPool.classFor(256 * kib + 1), 512 * kib);
      expect(DeviceBufferPool.classFor(700 * kib), 1 * mib);
      expect(DeviceBufferPool.classFor(1 * mib), 1 * mib);
      expect(DeviceBufferPool.classFor(3 * mib), 4 * mib);
      expect(DeviceBufferPool.classFor(4 * mib), 4 * mib);
    });

    test('anything larger than the largest class, or nothing, is unpooled', () {
      expect(DeviceBufferPool.classFor(4 * mib + 1), isNull);
      expect(DeviceBufferPool.classFor(64 * mib), isNull);
      expect(DeviceBufferPool.classFor(0), isNull);
      expect(DeviceBufferPool.classFor(-5), isNull);
    });

    test('every class is a power of two inside the range', () {
      for (var bytes = 1; bytes <= 4 * mib; bytes = bytes * 2 + 1) {
        final c = DeviceBufferPool.classFor(bytes)!;
        expect(c & (c - 1), 0, reason: '$c is not a power of two');
        expect(c, greaterThanOrEqualTo(bytes));
        expect(c, inInclusiveRange(256 * kib, 4 * mib));
        if (c > DeviceBufferPool.minClassBytes) {
          expect(c ~/ 2, lessThan(bytes), reason: '$bytes rounded past $c');
        }
      }
    });
  });

  group('cooling', () {
    test('a released buffer is not handed out until it has cooled', () {
      final pool = DeviceBufferPool<_Buf>(budgetBytes: 256 * mib);
      final b = _Buf(512 * kib);
      pool.release(b, 512 * kib, 10);
      expect(pool.acquire(512 * kib, 10), isNull);
      expect(pool.acquire(512 * kib, 11), isNull);
      expect(pool.acquire(512 * kib, 12), isNull);
      expect(pool.misses, 3);
      expect(pool.hits, 0);
      expect(identical(pool.acquire(512 * kib, 13), b), isTrue);
      expect(pool.hits, 1);
      expect(pool.freeCount, 0);
      expect(pool.freeBytes, 0);
    });

    test('the cooling period is the knob', () {
      final pool = DeviceBufferPool<_Buf>(
        budgetBytes: 256 * mib,
        coolingFrames: 1,
      );
      final b = _Buf(256 * kib);
      pool.release(b, 256 * kib, 5);
      expect(pool.acquire(256 * kib, 5), isNull);
      expect(identical(pool.acquire(256 * kib, 6), b), isTrue);
    });

    test(
      'a hit is the coldest cooled buffer of its class, and its class only',
      () {
        final pool = DeviceBufferPool<_Buf>(budgetBytes: 256 * mib);
        final old = _Buf(1 * mib), newer = _Buf(1 * mib), other = _Buf(2 * mib);
        pool.release(newer, 1 * mib, 20);
        pool.release(old, 1 * mib, 10);
        pool.release(other, 2 * mib, 0);
        expect(identical(pool.acquire(1 * mib, 30), old), isTrue);
        expect(identical(pool.acquire(1 * mib, 30), newer), isTrue);
        expect(pool.acquire(1 * mib, 30), isNull);
        expect(identical(pool.acquire(2 * mib, 30), other), isTrue);
        expect(pool.hits, 3);
        expect(pool.misses, 1);
      },
    );
  });

  group('budget', () {
    test('over the budget the coldest buffers are dropped', () {
      final pool = DeviceBufferPool<_Buf>(budgetBytes: 1 * mib);
      final a = _Buf(512 * kib), b = _Buf(512 * kib);
      final c = _Buf(512 * kib), d = _Buf(512 * kib);
      pool.release(a, 512 * kib, 1);
      pool.release(b, 512 * kib, 2);
      expect(pool.freeBytes, 1 * mib);
      expect(pool.evicted, 0);
      pool.release(c, 512 * kib, 3);
      expect(pool.freeBytes, 1 * mib);
      expect(pool.freeCount, 2);
      expect(pool.evicted, 1);
      pool.release(d, 512 * kib, 4);
      expect(pool.evicted, 2);
      // The two coldest, a then b, went; c and d remain, c first.
      expect(identical(pool.acquire(512 * kib, 100), c), isTrue);
      expect(identical(pool.acquire(512 * kib, 100), d), isTrue);
      expect(pool.acquire(512 * kib, 100), isNull);
    });

    test('a budget of zero disables the pool', () {
      final pool = DeviceBufferPool<_Buf>(budgetBytes: 0);
      pool.release(_Buf(256 * kib), 256 * kib, 1);
      expect(pool.freeCount, 0);
      expect(pool.freeBytes, 0);
      expect(pool.evicted, 1);
      expect(pool.acquire(256 * kib, 100), isNull);
      // A disabled pool was asked nothing: no miss is counted against it.
      expect(pool.misses, 0);
    });

    test('a budget lowered at run time sheds the coldest on the next call', () {
      final pool = DeviceBufferPool<_Buf>(budgetBytes: 4 * mib);
      final cold = _Buf(1 * mib), warm = _Buf(1 * mib);
      pool.release(cold, 1 * mib, 1);
      pool.release(warm, 1 * mib, 2);
      pool.budgetBytes = 1 * mib;
      expect(pool.acquire(4 * mib, 3), isNull);
      expect(pool.freeCount, 1);
      expect(identical(pool.acquire(1 * mib, 10), warm), isTrue);
      pool.budgetBytes = 0;
      pool.release(warm, 1 * mib, 11);
      expect(pool.freeCount, 0);
    });

    test('clear forgets every free buffer', () {
      final pool = DeviceBufferPool<_Buf>(budgetBytes: 4 * mib);
      pool.release(_Buf(1 * mib), 1 * mib, 1);
      pool.release(_Buf(1 * mib), 1 * mib, 1);
      pool.clear();
      expect(pool.freeCount, 0);
      expect(pool.freeBytes, 0);
      expect(pool.acquire(1 * mib, 50), isNull);
    });
  });

  group('the knobs', () {
    // The defaults the A/B compares against: the pool on at a zoom's worth
    // of replaced tiles, and a cooling period past the raster thread's lag.
    test('CityNodes.bufferPoolBytes and bufferPoolCoolFrames defaults', () {
      expect(CityNodes.bufferPoolBytes, 256 << 20);
      expect(CityNodes.bufferPoolCoolFrames, 3);
    });

    test('a GPU pool at the knob is disabled by a zero budget', () {
      final pool = GpuDeviceBufferPool(budgetBytes: 0);
      expect(pool.acquire(256 * kib, 10), isNull);
      expect(pool.freeCount, 0);
    });
  });
}
