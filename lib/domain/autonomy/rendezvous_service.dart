import '../dynamics/state_vector.dart';
import '../shared/vector3.dart';

/// Relative-motion readout for a rendezvous — the numbers a docking/approach
/// display shows: range, range-rate (closing speed), relative velocity, and
/// time to closest approach. Value object.
class RendezvousInfo {
  final Vector3 relativePosition; // target - chaser
  final Vector3 relativeVelocity; // target - chaser
  final double range; // m
  final double rangeRate; // m/s, negative = closing
  final double timeToClosestApproach; // s, 0 if already past / not closing

  const RendezvousInfo({
    required this.relativePosition,
    required this.relativeVelocity,
    required this.range,
    required this.rangeRate,
    required this.timeToClosestApproach,
  });

  bool get isClosing => rangeRate < 0;
}

/// Computes [RendezvousInfo] for a chaser/target pair. Domain service — pure
/// kinematics (straight-line relative motion), the basis for autonomous
/// approach and for the rendezvous UI. Both states must be in the same frame.
class RendezvousService {
  const RendezvousService();

  RendezvousInfo compute({
    required StateVector chaser,
    required StateVector target,
  }) {
    final relPos = target.position - chaser.position;
    final relVel = target.velocity - chaser.velocity;
    final range = relPos.length;

    // Range-rate = d|relPos|/dt = (relPos . relVel) / |relPos|.
    final rangeRate = range == 0 ? 0.0 : relPos.dot(relVel) / range;

    // Closest approach (linear): tca = -(relPos . relVel) / |relVel|^2, >= 0.
    final vSq = relVel.lengthSquared;
    final tca = vSq == 0 ? 0.0 : (-relPos.dot(relVel) / vSq).clamp(0.0, double.infinity).toDouble();

    return RendezvousInfo(
      relativePosition: relPos,
      relativeVelocity: relVel,
      range: range,
      rangeRate: rangeRate,
      timeToClosestApproach: tca,
    );
  }
}
