// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the combat phase may ask of the flying world (docs/plans/combat.md
/// §7E): a port the tick implements over its vessels and bodies, so the
/// combat code imports no vessel or orbit code. Read once a tick, at its end.
library;

import '../../shared/vector3.dart';

abstract interface class CombatSky {
  /// [vesselId]'s position about [bodyId], body-centred inertial — or null
  /// when the vessel is gone, landed, or not in that body's sphere of
  /// influence.
  Vector3? positionAbout(String vesselId, String bodyId);

  /// The body-fixed point [bf] on [bodyId], in its inertial frame now.
  Vector3 toInertial(String bodyId, Vector3 bf);

  /// The vessel's name, or null when it is gone.
  String? nameOf(String vesselId);

  /// Whether the player owns it.
  bool isPlayers(String vesselId);

  /// Whether it stands within 60 m of one of [colonyId]'s pads.
  bool landedAtPad(String vesselId, String colonyId);
}
