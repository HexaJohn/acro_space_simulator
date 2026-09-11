// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The `'agents'` block of a colony's save (docs/plans/agent-traffic.md
/// §14.1, §14.4).
///
/// Slice 1 saves one thing: that the colony runs agents, so a save and a
/// load keep them on. Vehicles in flight are never saved (§14.3) — the
/// route arena is tied to one graph object, and transient machinery
/// re-derives — so a restored colony starts its spawn ramp afresh. Citizens,
/// the RNG, accumulators and stops join the block in later slices, each
/// column in sorted site order so a save is deterministic; that is why this
/// is the one traffic file allowed to iterate a map.
///
/// The block is additive: `GameStateCodec.schemaVersion` stays 1, an absent
/// block means agents off, and the block carries its own `v`. A block of a
/// version this build does not read is dropped rather than half-read.
library;

/// Reads and writes the `'agents'` save block.
class AgentsCodec {
  AgentsCodec._();

  /// The block's schema version. Bumped on any change to its shape.
  static const int version = 1;

  /// The block for a colony whose agents are [enabled].
  static Map<String, Object?> encode({required bool enabled}) =>
      {'v': version, 'enabled': enabled};

  /// The enabled flag [json] carries, or null when there is no block, a
  /// block of another version, or one that is not a block at all: the
  /// colony then runs without agents, as it did before it had any.
  static bool? enabledOf(Object? json) {
    if (json is! Map) return null;
    if (json['v'] != version) return null;
    final enabled = json['enabled'];
    return enabled is bool ? enabled : null;
  }
}
