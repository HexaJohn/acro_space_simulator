// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

/// The agents' chance and hashing, pinned to their references: a change of
/// algorithm — or a platform that computes one differently — fails here,
/// rather than as a twin run that quietly drifts.
void main() {
  group('TrafficRng', () {
    List<int> draws(TrafficRng rng, int n) =>
        [for (var i = 0; i < n; i++) rng.nextU32()];

    test("is xoshiro128**: the reference implementation's outputs", () {
      // State {1, 2, 3, 4}. These are the C reference's outputs
      // (prng.di.unimi.it/xoshiro128starstar.c); the first four were also
      // worked by hand from the algorithm.
      expect(draws(TrafficRng.fromJson(const [1, 2, 3, 4]), 10), const [
        11520, 0, 5927040, 70819200, 2031721883, //
        1637235492, 1287239034, 3734860849, 3729100597, 4258142804,
      ]);
    });

    test('a seed draws its golden first 32', () {
      final rng = TrafficRng(20260911);
      expect(rng.toJson(),
          const [0xC2E4DF12, 0x1600A5B5, 0xE1E45CCF, 0x4BE8F503]);
      expect(draws(rng, 32), const [
        0x0E906A6F, 0x83602424, 0x43218174, 0xE55B18FA, //
        0x34BAFB8A, 0xA22E5BDF, 0x423E76CB, 0x29F5EDB0,
        0xC291A7FE, 0x8E9C53DA, 0xBE8ED2EF, 0xFF4FFBA1,
        0x8E0963C3, 0xA82C0069, 0x42F8A4BB, 0xE155A287,
        0xDAB9181D, 0x18D94F56, 0xD6660521, 0x0F607415,
        0x545E20F1, 0x14F3AD67, 0x8AE9360C, 0x2C63035D,
        0x3157AB0F, 0x1DD69711, 0x405AC4DC, 0x7BFD3D54,
        0xD9234A65, 0xB364A105, 0xF40E58EC, 0x47E6E86D,
      ]);
    });

    test('one seed draws one stream; the next seed another', () {
      final a = draws(TrafficRng(7), 1000);
      expect(draws(TrafficRng(7), 1000), a);
      final b = draws(TrafficRng(8), 1000);
      var same = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] == b[i]) same++;
      }
      expect(same, lessThan(2), reason: 'neighbouring seeds are unrelated');
    });

    test('draws stay in their ranges', () {
      final rng = TrafficRng(1);
      var bad = 0;
      for (var i = 0; i < 10000; i++) {
        final u = rng.nextU32();
        final x = rng.nextUnit();
        final f = rng.nextBetween(0.92, 1.05);
        if (u < 0 || u > 0xFFFFFFFF) bad++;
        if (x < 0 || x >= 1) bad++;
        if (f < 0.92 || f >= 1.05) bad++;
      }
      expect(bad, 0);
    });

    test('nextInt is uniform, and exactly so for any bound', () {
      final rng = TrafficRng(3);
      final counts = List.filled(3, 0);
      for (var i = 0; i < 30000; i++) {
        counts[rng.nextInt(3)]++;
      }
      for (final c in counts) {
        expect(c, closeTo(10000, 400));
      }

      // A bound where a quarter of all draws must be rejected: what is left
      // still falls evenly on its thirds.
      const n = 0xC0000000;
      final thirds = List.filled(3, 0);
      for (var i = 0; i < 3000; i++) {
        final k = rng.nextInt(n);
        expect(k, lessThan(n));
        thirds[k * 3 ~/ n]++;
      }
      for (final c in thirds) {
        expect(c, closeTo(1000, 150));
      }

      expect(rng.nextInt(1), 0);
      expect(rng.nextInt(0x100000000), inInclusiveRange(0, 0xFFFFFFFF));
      expect(() => rng.nextInt(0), throwsRangeError);
      expect(() => rng.nextInt(0x100000001), throwsRangeError);
    });

    test('its state round-trips through a save', () {
      final rng = TrafficRng(42);
      draws(rng, 17);
      final saved = jsonDecode(jsonEncode(rng.toJson()));
      final resumed = TrafficRng.fromJson(saved);
      expect(draws(resumed, 100), draws(rng, 100));
    });

    test('a state that is not one is refused, not guessed at', () {
      for (final bad in <Object?>[
        null,
        7,
        const [1, 2, 3],
        const [1, 2, 3, 4, 5],
        const [0, 0, 0, 0],
        const [1, 2, 3, -1],
        const [1, 2, 3, 0x100000000],
        const [1, 2, 3, 4.5],
        const ['1', 2, 3, 4],
      ]) {
        expect(() => TrafficRng.fromJson(bad), throwsFormatException,
            reason: '$bad');
      }
    });

    test('a fork is a stream of its own, and forking disturbs nothing', () {
      final parent = TrafficRng(9);
      final child = parent.fork(1);
      final again = parent.fork(1);
      final sibling = parent.fork(2);

      expect(draws(parent, 50), draws(TrafficRng(9), 50),
          reason: 'the parent draws on as if it had never been forked');
      final c = draws(child, 4096);
      expect(draws(again, 4096), c, reason: 'one salt, one child');

      // Independent: bit for bit, two streams agree half the time.
      double agreement(List<int> a, List<int> b) {
        var agree = 0;
        for (var i = 0; i < a.length; i++) {
          var x = a[i] ^ b[i];
          var ones = 0;
          while (x != 0) {
            ones += x & 1;
            x >>= 1;
          }
          agree += 32 - ones;
        }
        return agree / (a.length * 32);
      }

      expect(agreement(c, draws(sibling, 4096)), closeTo(0.5, 0.01));
      expect(agreement(c, draws(TrafficRng(9), 4096)), closeTo(0.5, 0.01),
          reason: 'nor is a child its parent over again');
    });
  });

  group('mul32', () {
    final mask = BigInt.from(0xFFFFFFFF);
    int exact(int a, int b) =>
        ((BigInt.from(a) * BigInt.from(b)) & mask).toInt();

    test('is the low 32 bits of the exact product', () {
      const edges = [
        0, 1, 2, 3, 0xFFFF, 0x10000, 0x10001, //
        0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF,
      ];
      final rng = TrafficRng(5);
      final pairs = [
        for (final a in edges)
          for (final b in edges) (a, b),
        for (var i = 0; i < 10000; i++) (rng.nextU32(), rng.nextU32()),
      ];
      final wrong = [
        for (final (a, b) in pairs)
          if (mul32(a, b) != exact(a, b)) '($a, $b)',
      ];
      expect(wrong, isEmpty);
    });

    test('goldens', () {
      expect(mul32(0xFFFFFFFF, 0xFFFFFFFF), 1);
      expect(mul32(0xFFFF, 0x10001), 0xFFFFFFFF);
      expect(mul32(0x10000, 0x10000), 0);
      expect(mul32(3, 0x55555556), 2);
    });

    test('takes an operand as its low 32 bits', () {
      expect(mul32(-1, -1), 1);
      expect(mul32(-1, 2), 0xFFFFFFFE);
      expect(mul32(0x100000003, 5), 15);
    });
  });

  group('fnv1a32', () {
    final mask = BigInt.from(0xFFFFFFFF);

    /// The textbook loop, over the bytes, in exact arithmetic.
    int reference(List<int> bytes) {
      var h = 0x811C9DC5;
      for (final b in bytes) {
        h = ((BigInt.from(h ^ b) * BigInt.from(0x01000193)) & mask).toInt();
      }
      return h;
    }

    test("matches FNV's own test vectors", () {
      expect(fnv1a32(''), 0x811C9DC5);
      expect(fnv1a32('a'), 0xE40C292C);
      expect(fnv1a32('foobar'), 0xBF9CF968);
    });

    test('hashes the UTF-8 bytes, as any implementation would', () {
      for (final s in const [
        '12,-40',
        'lot-r3-l2',
        'Třída Míru',
        '中央大街',
        'rocket \u{1F680} road',
        '\u{10FFFF}',
      ]) {
        expect(fnv1a32(s), reference(utf8.encode(s)), reason: s);
      }
    });

    test('fnv1aU32 folds a word in low byte first', () {
      expect(fnv1aU32(kFnvOffset32, 0x04030201),
          const [1, 2, 3, 4].fold(kFnvOffset32, fnv1aByte));
      expect(fnv1aU32(kFnvOffset32, -1),
          fnv1aU32(kFnvOffset32, 0xFFFFFFFF),
          reason: 'a column value hashes as its 32-bit pattern');
    });
  });
}
