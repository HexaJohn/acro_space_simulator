// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The agent simulation's only source of chance, and its only hash.
///
/// Two colonies with the same seed, fed the same ticks, must make the same
/// draws in the same order: that is what lets a twin run, a resumed save and
/// a replayed frame agree to the bit (docs/plans/agent-traffic.md, D27).
/// `math.Random` cannot promise it — its algorithm is the platform's to
/// choose, and an unseeded one reads the clock — and `String.hashCode` and
/// `Object.hash` fail the same way as keys, free to change between runs. So
/// every draw an agent makes comes from a [TrafficRng] and every hash from
/// [fnv1a32], and the traffic source-hygiene test bans the other three under
/// this directory.
///
/// Web-safe by construction. On the web an int is a double, exact only to
/// 2^53, so a 32 × 32-bit product — anything up to 2^64 — quietly loses its
/// low bits, which are the only bits a hash or a generator keeps.
/// xoshiro128** multiplies by nothing but 5 and 9, which stays below 2^36;
/// every other product (the FNV prime, the seed mixer) goes through [mul32],
/// which splits it so that no partial sum passes 2^49. Determinism is still
/// claimed per platform only: the integers here agree everywhere, but a
/// double computed from them is the compiler's.
library;

/// All 32 bits.
const int _mask32 = 0xFFFFFFFF;

/// 2^32: how many values one draw can take.
const int _twoPow32 = 0x100000000;

/// 2^-32, exactly, so a draw scaled by it is exact on every platform.
const double _unitScale = 1.0 / 4294967296.0;

/// The golden-ratio Weyl increment, ⌊2^32/φ⌋, odd: stepping by it visits
/// every 32-bit word before repeating one.
const int _golden32 = 0x9E3779B9;

/// The low 32 bits of [a] × [b], exactly, on every platform.
///
/// Both operands are taken modulo 2^32 (a negative one as its two's-
/// complement bits), so a word read back out of an `Int32List` multiplies
/// as the unsigned word it was. Split at 16 bits rather than multiplied
/// whole: the whole product runs to 2^64, past what a web int holds, while
/// each partial here stays below 2^48 and their sum below 2^49.
int mul32(int a, int b) {
  final x = a & _mask32;
  final y = b & _mask32;
  final lo = (x & 0xFFFF) * y;
  // Only the low 16 bits of the high partial survive the shift into place.
  final hi = ((x >> 16) * y) & 0xFFFF;
  return (lo + hi * 0x10000) & _mask32;
}

/// [x] (a 32-bit word) rotated left by [k] bits, 0 < k < 32.
int _rotl(int x, int k) => ((x << k) | (x >> (32 - k))) & _mask32;

/// Murmur3's finaliser: a bijection on 32-bit words that spreads every input
/// bit over every output bit. Seeds and forks go through it, so neighbouring
/// seeds do not start neighbouring streams. It maps 0 to 0 and nothing else
/// to 0.
int _mix32(int z) {
  var h = z & _mask32;
  h = mul32(h ^ (h >> 16), 0x85EBCA6B);
  h = mul32(h ^ (h >> 13), 0xC2B2AE35);
  return h ^ (h >> 16);
}

/// FNV-1a's 32-bit offset basis: where a running hash starts.
const int kFnvOffset32 = 0x811C9DC5;

/// FNV-1a's 32-bit prime.
const int _fnvPrime32 = 0x01000193;

/// [hash] with one byte (the low 8 bits of [byte]) folded in, FNV-1a.
int fnv1aByte(int hash, int byte) =>
    mul32(hash ^ (byte & 0xFF), _fnvPrime32);

/// [hash] with the 32-bit word [value] folded in, low byte first: how a
/// digest hashes a typed column without boxing each value into a string.
int fnv1aU32(int hash, int value) {
  final v = value & _mask32;
  var h = fnv1aByte(hash, v);
  h = fnv1aByte(h, v >> 8);
  h = fnv1aByte(h, v >> 16);
  return fnv1aByte(h, v >> 24);
}

/// 32-bit FNV-1a over the UTF-8 bytes of [s], without building them.
///
/// The standard hash, so it can be checked against any reference. The keys
/// this simulation hashes (a junction's whole-metre position, a site id) are
/// ASCII, where the bytes are the code units, but a road a player named in
/// Czech hashes to the same bytes everywhere too. A lone surrogate, which
/// UTF-8 cannot carry, is folded as its own three-byte form.
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

/// xoshiro128**: four 32-bit words of state, a period of 2^128 − 1, output
/// that passes BigCrush — and multiplies small enough for the web.
///
/// One instance per stream. A subsystem whose draws must not shift when
/// another subsystem adds one takes a stream of its own with [fork].
class TrafficRng {
  /// A stream seeded from [seed], taken modulo 2^32.
  ///
  /// Each state word is a Weyl step of the seed through the Murmur3
  /// finaliser, so neighbouring seeds start unrelated streams. Four
  /// consecutive Weyl steps are distinct and the finaliser maps only 0 to 0,
  /// so at most one word is zero — the all-zero state, which xoshiro never
  /// leaves, cannot be seeded.
  factory TrafficRng(int seed) {
    final x = seed & _mask32;
    return TrafficRng._(
      _mix32(x + _golden32),
      _mix32(x + 2 * _golden32),
      _mix32(x + 3 * _golden32),
      _mix32(x + 4 * _golden32),
    );
  }

  /// A stream resumed from [toJson]'s list.
  ///
  /// Throws a [FormatException] for anything else — four integer words, each
  /// 0 ≤ w < 2^32, not all zero — rather than start a stream the save never
  /// had.
  factory TrafficRng.fromJson(Object? json) {
    if (json is List && json.length == 4) {
      final w0 = json[0], w1 = json[1], w2 = json[2], w3 = json[3];
      if (_isWord(w0) && _isWord(w1) && _isWord(w2) && _isWord(w3)) {
        final a = w0 as int, b = w1 as int, c = w2 as int, d = w3 as int;
        if ((a | b | c | d) != 0) return TrafficRng._(a, b, c, d);
      }
    }
    throw FormatException('not a TrafficRng state: four 32-bit words, '
        'not all zero', json);
  }

  TrafficRng._(this._s0, this._s1, this._s2, this._s3);

  int _s0;
  int _s1;
  int _s2;
  int _s3;

  static bool _isWord(Object? v) => v is int && v >= 0 && v <= _mask32;

  /// The next draw, 0 ≤ n < 2^32.
  int nextU32() {
    final s1 = _s1;
    final result = (_rotl((s1 * 5) & _mask32, 7) * 9) & _mask32;
    final t = (s1 << 9) & _mask32;
    _s2 ^= _s0;
    _s3 ^= s1;
    _s1 = s1 ^ _s2;
    _s0 ^= _s3;
    _s2 ^= t;
    _s3 = _rotl(_s3, 11);
    return result;
  }

  /// A draw uniform on 0 ≤ k < [n], for 1 ≤ [n] ≤ 2^32.
  ///
  /// Exactly uniform: 2^32 is rarely a multiple of [n], so the short run of
  /// draws that would favour the low residues is rejected and drawn again
  /// rather than folded in. That happens to fewer than one draw in two for
  /// any [n], and almost never for the small ones the simulation asks for.
  int nextInt(int n) {
    if (n < 1 || n > _twoPow32) {
      throw RangeError.range(n, 1, _twoPow32, 'n');
    }
    final floor = (_twoPow32 - n) % n;
    while (true) {
      final r = nextU32();
      if (r >= floor) return r % n;
    }
  }

  /// A draw uniform on [0, 1), in steps of 2^-32 — exact, since both the
  /// draw and the scale are exact doubles.
  double nextUnit() => nextU32() * _unitScale;

  /// A draw uniform on [[lo], [hi]): the U(a, b) the design's tables quote.
  double nextBetween(double lo, double hi) => lo + (hi - lo) * nextUnit();

  /// A stream of its own for one subsystem, keyed by [salt].
  ///
  /// Forking reads this stream's state but does not advance it, so taking a
  /// fork never shifts the draws anyone else sees — and the same [salt]
  /// forks the same child from the same state. Give each subsystem its own
  /// salt, and fork it once.
  TrafficRng fork(int salt) {
    final k = salt & _mask32;
    var a = _mix32(_s0 ^ _mix32(k + _golden32));
    final b = _mix32(_s1 ^ _mix32(k + 2 * _golden32));
    final c = _mix32(_s2 ^ _mix32(k + 3 * _golden32));
    final d = _mix32(_s3 ^ _mix32(k + 4 * _golden32));
    // xoshiro never leaves the all-zero state; a fork that landed on it (a
    // 2^-128 chance) starts one word along instead.
    if ((a | b | c | d) == 0) a = 1;
    return TrafficRng._(a, b, c, d);
  }

  /// The four state words, as the save's `rng` list (§14.1).
  List<int> toJson() => [_s0, _s1, _s2, _s3];
}
