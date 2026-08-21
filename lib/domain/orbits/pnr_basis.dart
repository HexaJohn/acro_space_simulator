// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The prograde / normal / radial frame a maneuver node's delta-v is expressed
/// in, built from a state vector.
///
/// Shared because BOTH ends have to agree: the encounter planner previews the
/// burn in this frame and the autopilot executes it in this frame, and a node
/// that means one thing to the preview and another to the burn is worse than no
/// preview at all.
library;

import '../shared/vector3.dart';

/// A right-handed orthonormal triad: `prograde` along the velocity, `normal`
/// along the orbit's angular momentum, `radial` completing it.
typedef PnrBasis = ({Vector3 prograde, Vector3 normal, Vector3 radial});

/// How small `sin(angle between r and v)` has to get before the orbit normal is
/// treated as undefined.
///
/// This test MUST be relative. `|r x v|` is `|r| |v| sin(theta)`, which on a
/// real orbit is astronomical — around 1e10 for low Earth orbit — and on a
/// radial trajectory is nothing but rounding error, around 1e-6 at planetary
/// scale. An ABSOLUTE threshold like 1e-9 sits below the rounding error, so it
/// never fires exactly when it is needed: a craft falling straight down (its
/// prograde vector aligned with gravity) got an orbit normal that was pure
/// numerical noise, normalised into a confident-looking unit vector pointing
/// nowhere in particular. Nudging the velocity by one part in 1e10 swung it by
/// a third of a radian. Any node with a normal or radial component then fired
/// along an arbitrary direction, and the craft left on a trajectory that had
/// nothing to do with the burn that was planned.
///
/// 1e-10 sits far above the noise floor (~1e-15) and far below any real orbit's
/// geometry, so it separates the two cleanly.
const double _radialTolerance = 1e-10;

/// The PNR frame at [position] / [velocity].
///
/// On a radial trajectory the normal and radial directions are genuinely
/// undefined — every direction perpendicular to the velocity is as good as any
/// other. What matters is that the answer is DETERMINISTIC and orthonormal, so
/// the preview and the burn agree and neither wanders between ticks.
PnrBasis pnrBasis(Vector3 position, Vector3 velocity) {
  final prograde =
      velocity.length < 1e-9 ? Vector3.unitY : velocity.normalized;
  final h = position.cross(velocity);
  final normal = h.length > _radialTolerance * position.length * velocity.length
      ? h.normalized
      : anyPerpendicular(prograde);
  return (
    prograde: prograde,
    normal: normal,
    radial: prograde.cross(normal).normalized,
  );
}

/// Some unit vector perpendicular to [v], chosen the same way every time.
Vector3 anyPerpendicular(Vector3 v) {
  final ref = v.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
  final p = v.cross(ref);
  return p.length > 1e-12 ? p.normalized : Vector3.unitZ;
}
