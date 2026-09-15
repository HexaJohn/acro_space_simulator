// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/hash32.dart' as h;
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart'
    as t;
import 'package:flutter_test/flutter_test.dart';

/// The city's copy of traffic's hash (docs/plans/site-access.md §2.1, §3.9) is
/// pinned equal to it: a key the road side hashes is one traffic compares.
void main() {
  test('fnv1a32 is traffic_rng\'s, byte for byte, and the standard FNV-1a',
      () {
    const strings = [
      '',
      'a',
      'foobar',
      'lot-r0x1-l10',
      'lot-m3',
      'Náměstí Míru',
      '\u{1F697} garage',
      'lone \uD83D surrogate',
    ];
    for (final s in strings) {
      expect(h.fnv1a32(s), t.fnv1a32(s), reason: s);
    }
    // Published FNV-1a 32 test vectors.
    expect(h.fnv1a32(''), 0x811C9DC5);
    expect(h.fnv1a32('a'), 0xE40C292C);
    expect(h.fnv1a32('foobar'), 0xBF9CF968);
  });

  test('fnv1aU32, fnv1aByte and mul32 are traffic_rng\'s', () {
    const words = [0, 1, 255, 256, 65535, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, -1];
    for (final w in words) {
      expect(h.fnv1aU32(h.kFnvOffset32, w), t.fnv1aU32(t.kFnvOffset32, w));
      expect(h.fnv1aByte(h.kFnvOffset32, w), t.fnv1aByte(t.kFnvOffset32, w));
      for (final v in words) {
        expect(h.mul32(w, v), t.mul32(w, v), reason: '$w × $v');
      }
    }
    expect(h.kFnvOffset32, t.kFnvOffset32);
  });

  test('xorshift32 is Marsaglia\'s (13, 17, 5) on 32-bit words', () {
    expect(h.xorshift32(0), 0);
    expect(h.xorshift32(1), 270369);
    var x = 2463534242;
    final seen = <int>[];
    for (var i = 0; i < 4; i++) {
      x = h.xorshift32(x);
      expect(x, inInclusiveRange(1, 0xFFFFFFFF));
      seen.add(x);
    }
    // Marsaglia's paper seed: the first draws of xorshift32.
    expect(seen.first, 723471715);
    expect(h.xorshift32(-1), h.xorshift32(0xFFFFFFFF),
        reason: 'taken modulo 2^32');
  });
}
