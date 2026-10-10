// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../domain/planetary/planet_atmosphere.dart';

/// One body's gas inventory in a [WorldSnapshot] (docs/plans/terraforming.md
/// §5.6).
///
/// Authoritative world state, not render config: the inventory decides a
/// body's pressure and so the drag every craft in its sky feels. Two runs that
/// disagree about it will disagree about where a reentry ends — so it is hashed
/// into the fingerprint. The derived air itself rides the body descriptors,
/// which already carry the gas fractions; this is the state they came from.
class AtmosphereSnapshot {
  const AtmosphereSnapshot({required this.body, required this.moles});

  factory AtmosphereSnapshot.of(PlanetAtmosphere a) => AtmosphereSnapshot(
        body: a.bodyId,
        moles: {for (final e in a.moles.entries) e.key.name: e.value},
      );

  factory AtmosphereSnapshot.fromJson(Map<String, dynamic> j) =>
      AtmosphereSnapshot(
        body: j['body'] as String,
        moles: {
          for (final e in ((j['moles'] as Map?) ?? const {}).entries)
            e.key as String: (e.value as num).toDouble(),
        },
      );

  final String body;

  /// Moles per gas, keyed by gas name, in gas-enum order.
  final Map<String, double> moles;

  Map<String, dynamic> toJson() => {'body': body, 'moles': moles};

  /// Append this inventory to a fingerprint.
  ///
  /// RELATIVE precision, not the fixed 1e-3 the vessel states use: a Mars
  /// inventory is ~1e17 moles, where an absolute quantum hashes float noise
  /// and a fraction of a mole means nothing. Ten significant figures is a
  /// part in 1e10 — far below anything the derived air, and so any craft,
  /// could feel, and far above double rounding noise.
  void writeFingerprint(StringBuffer buf) {
    buf
      ..write(body)
      ..write(':');
    for (final e in moles.entries) {
      buf
        ..write(e.key)
        ..write('=')
        ..write(e.value.isNaN ? 'nan' : e.value.toStringAsPrecision(10))
        ..write(',');
    }
    buf.write(';');
  }
}
