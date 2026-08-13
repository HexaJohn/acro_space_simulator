// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

/// A tiny seeded PRNG for procedural prop generation.
///
/// Not `dart:math`'s [math.Random]: its sequence is an implementation detail
/// that may differ between the VM and dart2js, and a tree that grows differently
/// on web than on desktop breaks the whole point of seeded content. This is an
/// explicit 32-bit avalanche mix — every operation masked to 32 bits so the
/// web's doubles produce the identical stream (the same discipline
/// [ValueNoise3] uses).
class PropRandom {
  PropRandom(int seed) : _state = (seed ^ 0x9e3779b9) & 0xffffffff;

  int _state;

  /// Next raw 32-bit value.
  int nextInt32() {
    var h = (_state + 0x6d2b79f5) & 0xffffffff;
    _state = h;
    h = (h ^ (h >> 15)) & 0xffffffff;
    h = (h * 0x2c1b3c6d) & 0xffffffff;
    h = (h ^ (h >> 12)) & 0xffffffff;
    h = (h * 0x297a2d39) & 0xffffffff;
    h = (h ^ (h >> 15)) & 0xffffffff;
    return h;
  }

  /// Uniform in `[0, 1)`.
  double next() => nextInt32() / 0x100000000;

  /// Uniform in `[min, max)`.
  double range(double min, double max) => min + (max - min) * next();

  /// Uniform in `[-spread, +spread)`.
  double jitter(double spread) => range(-spread, spread);

  /// Uniform integer in `[0, max)`.
  int intBelow(int max) => max <= 0 ? 0 : nextInt32() % max;

  /// True with probability [p].
  bool chance(double p) => next() < p;

  /// A fresh generator derived from this one — lets a sub-part (one branch, one
  /// blade) draw its own stream without the number of draws in a sibling
  /// shifting it. Determinism survives edits to unrelated code paths.
  PropRandom fork(int salt) => PropRandom(nextInt32() ^ (salt * 0x85ebca6b));
}

/// Golden-angle radians (~137.5 deg) — the phyllotaxis step. Successive
/// branches/leaves rotated by this around the parent axis never line up, which
/// is why real plants use it and why a fixed `2*pi/n` looks synthetic.
const double goldenAngle = math.pi * (3.0 - 2.23606797749979); // pi*(3-sqrt5)
