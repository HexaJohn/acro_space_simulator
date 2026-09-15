// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The city's web-safe 32-bit hashes, outside the traffic directory
/// (docs/plans/site-access.md §2.1, §3.9).
///
/// Site access generation lives beside the road network, not under
/// `traffic/`, yet it must hash exactly as traffic does: a stall key or a
/// plan revision the road side writes is one the traffic side compares. So
/// these are copies of `traffic/traffic_rng.dart`'s FNV-1a, bit for bit, and a
/// test pins the two equal. Never `String.hashCode` or `Object.hash`, which
/// Dart does not promise to keep between runs.
///
/// Web-safe by construction: every product of two 32-bit words goes through
/// [mul32], which splits it so no partial sum passes 2^49, and every shift is
/// masked back to 32 bits.
library;

/// All 32 bits.
const int _mask32 = 0xFFFFFFFF;

/// The low 32 bits of [a] × [b], exactly, on every platform. Both operands are
/// taken modulo 2^32.
int mul32(int a, int b) {
  final x = a & _mask32;
  final y = b & _mask32;
  final lo = (x & 0xFFFF) * y;
  final hi = ((x >> 16) * y) & 0xFFFF;
  return (lo + hi * 0x10000) & _mask32;
}

/// FNV-1a's 32-bit offset basis: where a running hash starts.
const int kFnvOffset32 = 0x811C9DC5;

/// FNV-1a's 32-bit prime.
const int _fnvPrime32 = 0x01000193;

/// [hash] with one byte (the low 8 bits of [byte]) folded in, FNV-1a.
int fnv1aByte(int hash, int byte) => mul32(hash ^ (byte & 0xFF), _fnvPrime32);

/// [hash] with the 32-bit word [value] folded in, low byte first.
int fnv1aU32(int hash, int value) {
  final v = value & _mask32;
  var h = fnv1aByte(hash, v);
  h = fnv1aByte(h, v >> 8);
  h = fnv1aByte(h, v >> 16);
  return fnv1aByte(h, v >> 24);
}

/// 32-bit FNV-1a over the UTF-8 bytes of [s], without building them. A lone
/// surrogate, which UTF-8 cannot carry, is folded as its own three-byte form.
int fnv1a32(String s) {
  var h = kFnvOffset32;
  for (var i = 0; i < s.length; i++) {
    var c = s.codeUnitAt(i);
    if (c < 0x80) {
      h = fnv1aByte(h, c);
      continue;
    }
    if (c >= 0xD800 && c < 0xDC00 && i + 1 < s.length) {
      final d = s.codeUnitAt(i + 1);
      if (d >= 0xDC00 && d < 0xE000) {
        c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
        i++;
      }
    }
    if (c < 0x800) {
      h = fnv1aByte(h, 0xC0 | (c >> 6));
    } else if (c < 0x10000) {
      h = fnv1aByte(h, 0xE0 | (c >> 12));
      h = fnv1aByte(h, 0x80 | ((c >> 6) & 0x3F));
    } else {
      h = fnv1aByte(h, 0xF0 | (c >> 18));
      h = fnv1aByte(h, 0x80 | ((c >> 12) & 0x3F));
      h = fnv1aByte(h, 0x80 | ((c >> 6) & 0x3F));
    }
    h = fnv1aByte(h, 0x80 | (c & 0x3F));
  }
  return h;
}

/// One step of Marsaglia's xorshift32 (13, 17, 5) on the 32-bit word [x]:
/// the tie-break stream of §3.9, `xorshift32(seed ^ fnv1a32(tag))`. Zero maps
/// to zero, and nothing else does. Every left shift is masked to 32 bits, so
/// the VM's 64-bit ints and the web's 32-bit bitwise operators agree.
int xorshift32(int x) {
  var v = x & _mask32;
  v ^= (v << 13) & _mask32;
  v ^= v >> 17;
  v ^= (v << 5) & _mask32;
  return v & _mask32;
}
