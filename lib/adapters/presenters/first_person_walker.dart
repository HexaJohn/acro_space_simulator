// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../../domain/shared/vector3.dart';

/// Eye height of a standing figure, metres. The camera sits here above the
/// terrain, so the horizon reads like a person's rather than a drone's.
const double walkEyeHeight = 1.7;

/// Comfortable walking pace, m/s (~5 km/h).
const double walkSpeed = 1.4;

/// Sprint pace, m/s. Shift holds this.
const double walkRunSpeed = 5.0;

/// How high a jump clears on EARTH, metres. The impulse is derived from this
/// and the LOCAL gravity (`v = sqrt(2·g·h)`), so a body's gravity decides how
/// the hop feels for free: the same legs that clear half a metre on Earth
/// float three metres up on the Moon.
const double walkJumpHeightEarth = 0.5;
const double _earthG = 9.80665;

/// Jump take-off speed (m/s) for a figure with Earth-calibrated legs standing
/// in [gravity] m/s². Zero (no jump possible) in free fall.
double walkJumpSpeed(double gravity) =>
    gravity <= 0 ? 0 : math.sqrt(2 * _earthG * walkJumpHeightEarth);

/// The result of one walk step: where the figure's EYE ended up and how it is
/// moving vertically.
class WalkStep {
  const WalkStep({
    required this.posLocal,
    required this.vertVel,
    required this.grounded,
  });

  /// Eye position in the body's ROTATING (body-fixed) frame, metres from centre.
  final Vector3 posLocal;

  /// Speed along the local up axis, m/s. Negative = falling.
  final double vertVel;

  /// Standing on the ground (jump is available, gravity is cancelled).
  final bool grounded;
}

/// Advance a first-person figure walking on a spherical body's terrain.
///
/// Pure: no Flutter, no repositories, no clock. Everything that varies —
/// where the ground is, which way the camera looks — arrives as an argument,
/// which is what lets the surface-relative motion be tested without a scene.
///
/// **Frame.** [posLocal] and the basis vectors are in the body's ROTATING
/// frame, the same frame the freecam anchor lives in (see `SimulationView`).
/// Walking a spinning body therefore carries the figure along with the surface
/// for free: it stands still relative to the rock under its boots, not relative
/// to the stars.
///
/// **Local up is radial** — `posLocal.normalized`. The camera's [forwardLocal] /
/// [rightLocal] are flattened onto the tangent plane before they drive motion,
/// so looking at the sky or at your feet never slows the walk or lifts it off
/// the ground; only the heading matters. Looking exactly along the up axis
/// degenerates the forward projection, and the right vector supplies the
/// heading instead (`forward = up × right`).
///
/// **Ground query is a callback**, [groundRadiusAt], sampled AFTER the
/// horizontal move so the figure steps onto the height at its new position
/// rather than the one it left. Feed it the same terrain field a landing
/// craft touches down on and the walker and the lander agree on where the
/// surface is.
WalkStep stepFirstPersonWalk({
  required Vector3 posLocal,
  required double vertVel,
  required bool grounded,
  required Vector3 forwardLocal,
  required Vector3 rightLocal,
  required double moveForward, // -1..1
  required double moveRight, // -1..1
  required bool jump,
  required double dt,
  required double gravity, // m/s², positive
  required double Function(Vector3 posLocal) groundRadiusAt,
  double eyeHeight = walkEyeHeight,
  double speed = walkSpeed,
}) {
  final r0 = posLocal.length;
  if (!r0.isFinite || r0 <= 0 || !dt.isFinite || dt <= 0) {
    return WalkStep(posLocal: posLocal, vertVel: vertVel, grounded: grounded);
  }
  final up = posLocal * (1 / r0);

  // Heading basis: camera forward/right flattened onto the tangent plane.
  var right = rightLocal - up * rightLocal.dot(up);
  if (right.length < 1e-9) return WalkStep(posLocal: posLocal, vertVel: vertVel, grounded: grounded);
  right = right.normalized;
  var fwd = forwardLocal - up * forwardLocal.dot(up);
  fwd = fwd.length < 1e-6 ? up.cross(right).normalized : fwd.normalized;

  // Horizontal step. Diagonals are clamped to unit so W+D is not 41% faster.
  var move = fwd * moveForward + right * moveRight;
  final moveLen = move.length;
  if (moveLen > 1) move = move * (1 / moveLen);
  var next = posLocal + move * (speed * dt);

  // Vertical: jump impulse (only with feet down), then gravity, then the
  // ground floor. Gravity is applied before the position update so a hop
  // starts at full take-off speed.
  var v = vertVel;
  if (jump && grounded) v = walkJumpSpeed(gravity);
  v -= gravity * dt;
  var radius = next.length + v * dt;
  if (radius <= 0) radius = next.length; // degenerate; keep the last radius
  next = next.normalized * radius;

  final floor = groundRadiusAt(next) + eyeHeight;
  if (radius <= floor) {
    next = next.normalized * floor;
    // Land: kill the descent, keep an upward push (walking off a lip while
    // still rising should not be clipped back down).
    return WalkStep(posLocal: next, vertVel: math.max(v, 0), grounded: true);
  }
  return WalkStep(posLocal: next, vertVel: v, grounded: false);
}
