// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../../domain/shared/vector3.dart';
import 'first_person_walker.dart';

/// Thrust the pack can produce along one axis, m/s². Sized so a shove off the
/// ground reads as deliberate rather than twitchy, and so it can out-push
/// lunar gravity (1.62) but NOT Earth's.
const double evaThrustAccel = 3.2;

/// Propellant, kg, and how fast full thrust burns it. ~120 s of continuous
/// single-axis firing: enough to cross a construction site, not enough to
/// treat as free flight.
const double evaPropellantKg = 12.0;
const double evaBurnKgPerSec = 0.10;

/// Speed at or below which a contact counts as landing rather than a crash.
/// Above it the pack still stops you — nothing is damaged today — but the
/// caller can read [EvaStep.hardContact] to make something of it.
const double evaSoftLandingMs = 4.0;

/// One frame of the walker floating on their thruster pack.
class EvaStep {
  const EvaStep({
    required this.posLocal,
    required this.velLocal,
    required this.propellantKg,
    required this.grounded,
    required this.hardContact,
    required this.thrusting,
  });

  /// Eye position in the body's ROTATING frame, metres from centre.
  final Vector3 posLocal;

  /// Velocity in that same frame, m/s. THIS is what makes the pack a pack:
  /// releasing the stick leaves it untouched, so you coast.
  final Vector3 velLocal;

  final double propellantKg;

  /// Standing on the ground again — the caller should hand control back to
  /// [stepFirstPersonWalk].
  final bool grounded;

  /// Touched down above [evaSoftLandingMs].
  final bool hardContact;

  /// Burning propellant this frame.
  final bool thrusting;
}

/// Advance a walker flying an EVA thruster pack.
///
/// The difference from [stepFirstPersonWalk] is the whole point: walking is
/// POSITION-controlled (release W and you stop dead, because feet do that),
/// flying is VELOCITY-controlled (release W and you keep going, because
/// nothing is holding you). Everything else — the body-fixed rotating frame,
/// the radial "up", the terrain floor — is shared with the walker so stepping
/// off a ledge into a hover and landing again is continuous.
///
/// **Gravity is real and local.** On Ryugu (µ ≈ 30 m³/s²) this is genuine
/// weightless drifting; on the Moon it is a hover pack that must fight 1.62
/// m/s²; on Earth it cannot lift you at all, which is correct for a pack this
/// size. What it is NOT is orbital free fall: the anchor lives in the body's
/// rotating frame with no orbital velocity of its own, so floating "in orbit"
/// would simply fall. Orbital EVA needs the walker to become a real sim body
/// carrying a state vector.
EvaStep stepEvaPack({
  required Vector3 posLocal,
  required Vector3 velLocal,
  required Vector3 forwardLocal,
  required Vector3 rightLocal,
  required double throttleForward, // -1..1, camera-relative
  required double throttleRight,
  required double throttleUp, // +1 climb, -1 descend (local vertical)
  required double dt,
  required double gravity, // m/s², positive
  required double propellantKg,
  required double Function(Vector3 posLocal) groundRadiusAt,
  double eyeHeight = walkEyeHeight,
  double thrustAccel = evaThrustAccel,
  double burnKgPerSec = evaBurnKgPerSec,
}) {
  final r0 = posLocal.length;
  if (!r0.isFinite || r0 <= 0 || !dt.isFinite || dt <= 0) {
    return EvaStep(
      posLocal: posLocal,
      velLocal: velLocal,
      propellantKg: propellantKg,
      grounded: false,
      hardContact: false,
      thrusting: false,
    );
  }
  final up = posLocal * (1 / r0);

  // Thrust axes: the camera's own forward/right flattened onto the tangent
  // plane, plus the local vertical. Flattened rather than raw so pitching the
  // view does not silently become a climb command — climb is its own axis.
  var right = rightLocal - up * rightLocal.dot(up);
  right = right.length < 1e-9 ? Vector3.zero : right.normalized;
  var fwd = forwardLocal - up * forwardLocal.dot(up);
  fwd = fwd.length < 1e-6
      ? (right.lengthSquared > 0 ? up.cross(right).normalized : Vector3.zero)
      : fwd.normalized;

  var command = fwd * throttleForward + right * throttleRight + up * throttleUp;
  final commandLen = command.length;
  if (commandLen > 1) command = command * (1 / commandLen);
  final demand = math.min(commandLen, 1.0);

  // Dry pack still steers nothing: no propellant, no thrust, just gravity.
  final dry = propellantKg <= 0;
  final thrusting = !dry && demand > 1e-3;
  var accel = up * -gravity;
  if (thrusting) accel = accel + command * thrustAccel;

  var vel = velLocal + accel * dt;
  var next = posLocal + vel * dt;
  final fuel = thrusting
      ? math.max(0.0, propellantKg - burnKgPerSec * demand * dt)
      : propellantKg;

  final floor = groundRadiusAt(next) + eyeHeight;
  if (next.length <= floor) {
    final upAtContact = next.length > 0 ? next.normalized : up;
    final closing = -vel.dot(upAtContact); // + = coming down
    next = upAtContact * floor;
    // Kill the inward component, keep the tangential slide: landing on a slope
    // with lateral speed should skid, not stop dead in mid-air.
    final radial = upAtContact * vel.dot(upAtContact);
    vel = vel - radial;
    return EvaStep(
      posLocal: next,
      velLocal: vel,
      propellantKg: fuel,
      grounded: true,
      hardContact: closing > evaSoftLandingMs,
      thrusting: thrusting,
    );
  }
  return EvaStep(
    posLocal: next,
    velLocal: vel,
    propellantKg: fuel,
    grounded: false,
    hardContact: false,
    thrusting: thrusting,
  );
}
