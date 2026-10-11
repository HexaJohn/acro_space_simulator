// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Combat's only source of chance: stateless rolls (docs/plans/combat.md §7.5).
///
/// A battle must come out the same whether it was fought in one 0.5 s tick or
/// twenty-five 0.02 s ones, before or after a save, watched or not. A random
/// STREAM cannot promise that — whoever draws first changes what everyone
/// after them gets, and its state would have to be saved. So a roll here is a
/// pure function of what it is about: the operation's seed, the thing being
/// rolled for, and when. Nothing to save, and evaluation order cannot matter.
///
/// Built on the city's web-safe FNV-1a (`hash32.dart`, itself pinned to the
/// traffic hash), finished with Murmur3's mixer so neighbouring inputs give
/// unrelated rolls. Never `math.Random`, `hashCode` or `Object.hash`: the combat
/// hygiene test bans them under `lib/domain/combat/`.
library;

import '../colony/city/hash32.dart';

const int _mask32 = 0xFFFFFFFF;

/// 2^-32, exact, so a 32-bit word scales to [0, 1) exactly on every platform.
const double _unitScale = 1.0 / 4294967296.0;

/// Murmur3's finaliser: a bijection on 32-bit words that spreads every input
/// bit over every output bit.
int combatMix32(int z) {
  var h = z & _mask32;
  h = mul32(h ^ (h >> 16), 0x85EBCA6B);
  h = mul32(h ^ (h >> 13), 0xC2B2AE35);
  return (h ^ (h >> 16)) & _mask32;
}

/// A 32-bit roll for ([seed], [a], [b]).
int combatRoll32(int seed, int a, int b) =>
    combatMix32(fnv1aU32(fnv1aU32(fnv1aU32(kFnvOffset32, seed), a), b));

/// A roll in [0, 1).
double combatUnit(int seed, int a, int b) =>
    combatRoll32(seed, a, b) * _unitScale;

/// A roll in [-1, 1).
double combatSigned(int seed, int a, int b) =>
    combatUnit(seed, a, b) * 2.0 - 1.0;

/// An operation's seed: the target colony and the operation's own id, from the
/// saved operation counter. Not the launch tick: reloading and launching a
/// tick later must not reroll the same decision (§6.5 of the reference).
int combatSeed(String targetColonyId, int operationId) =>
    combatMix32(fnv1aU32(fnv1a32(targetColonyId), operationId));

/// A stable 32-bit key for a string id (an objective's), for rolls about it.
int combatKey(String id) => fnv1a32(id);
