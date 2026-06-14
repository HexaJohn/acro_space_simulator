import '../shared/vector3.dart';
import '../vessel/docking_port.dart';

/// Control command an autopilot issues to a vessel's RCS/engine: a thrust
/// direction (unit, vessel frame) and throttle, plus desired attitude.
class GuidanceCommand {
  final Vector3 thrustDirection; // unit, vessel body frame
  final double throttle; // 0..1
  final Vector3 targetFacing; // desired forward axis, inertial
  final bool capture; // request latch this tick

  const GuidanceCommand({
    required this.thrustDirection,
    required this.throttle,
    required this.targetFacing,
    this.capture = false,
  });

  static const GuidanceCommand idle = GuidanceCommand(
    thrustDirection: Vector3.zero,
    throttle: 0,
    targetFacing: Vector3.unitZ,
  );
}

/// Computes guidance to bring a chaser's docking port onto a target port.
/// Domain service — pure proportional guidance (the "brain" of autonomous
/// docking). A real game tunes this or swaps in a fancier controller.
class DockingSolver {
  /// Approach gains.
  final double approachSpeed; // m/s far-field closing speed
  final double positionGain;
  final double brakingDistance; // m, start slowing inside this

  const DockingSolver({
    this.approachSpeed = 5.0,
    this.positionGain = 0.5,
    this.brakingDistance = 50.0,
  });

  /// [relativePosition]/[relativeVelocity] are chaser-port to target-port, in
  /// the inertial frame. Returns the command to close the gap and align.
  GuidanceCommand solve({
    required Vector3 relativePosition,
    required Vector3 relativeVelocity,
    required Vector3 targetPortFacing,
  }) {
    final distance = relativePosition.length;
    if (distance < DockingPort.captureDistance) {
      return GuidanceCommand(
        thrustDirection: Vector3.zero,
        throttle: 0,
        targetFacing: -targetPortFacing,
        capture: true,
      );
    }

    // Desired closing velocity tapers near the target.
    final desiredSpeed =
        distance > brakingDistance ? approachSpeed : approachSpeed * (distance / brakingDistance);
    final desiredVel = relativePosition.normalized * (-desiredSpeed);

    // Command acceleration ~ correct the velocity error.
    final velError = desiredVel - relativeVelocity;
    final dir = velError.normalized;
    final throttle = (velError.length * positionGain).clamp(0.0, 1.0);

    return GuidanceCommand(
      thrustDirection: dir,
      throttle: throttle.toDouble(),
      targetFacing: -targetPortFacing, // point port at the target port
    );
  }
}
