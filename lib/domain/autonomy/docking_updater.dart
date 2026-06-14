import '../shared/vector3.dart';
import '../simulation/domain_event.dart';
import '../vessel/docking_port.dart';
import '../vessel/vessel.dart';
import 'docking_solver.dart';

/// Executes a vessel's [DockingApproach]: each tick it computes the relative
/// state between the chaser's and target's docking ports, asks the
/// [DockingSolver] for guidance, and applies the commanded closing velocity
/// (RCS abstraction — translation only, exact alignment assumed for gameplay).
/// On capture it latches both ports and raises [DockingCompleted].
///
/// Domain service. Translation guidance is applied directly to the chaser's
/// velocity (a fine-control RCS model); full 6-DOF thrust docking can replace
/// this without changing callers.
class DockingUpdater {
  final DockingSolver solver;
  const DockingUpdater([this.solver = const DockingSolver()]);

  void update(Vessel chaser, Vessel target, {required double dt}) {
    final approach = chaser.docking;
    if (approach == null || approach.docked) return;

    final chaserPort = _portWorld(chaser, approach.chaserPortId);
    final targetPort = _portWorld(target, approach.targetPortId);
    if (chaserPort == null || targetPort == null) return;

    final relPos = targetPort.position - chaserPort.position;
    final relVel = target.state.velocity - chaser.state.velocity;

    final command = solver.solve(
      relativePosition: relPos,
      relativeVelocity: relVel,
      targetPortFacing: targetPort.facing,
    );

    if (command.capture || relPos.length < DockingPort.captureDistance) {
      _latch(chaser, target, approach);
      return;
    }

    // Closing velocity toward the target port, tapering inside braking range,
    // expressed relative to the target so we rendezvous rather than overshoot.
    final distance = relPos.length;
    final speed = distance > solver.brakingDistance
        ? solver.approachSpeed
        : solver.approachSpeed * (distance / solver.brakingDistance);
    final closing = relPos.normalized * speed;
    chaser.updateState(
      chaser.state.copyWith(velocity: target.state.velocity + closing),
    );
  }

  void _latch(Vessel chaser, Vessel target, dynamic approach) {
    final cp = _findPort(chaser, approach.chaserPortId);
    final tp = _findPort(target, approach.targetPortId);
    cp?.latchedTo = approach.targetPortId;
    tp?.latchedTo = approach.chaserPortId;
    approach.docked = true;
    // Match velocity exactly at the moment of latch.
    chaser.updateState(chaser.state.copyWith(velocity: target.state.velocity));
    chaser.raise(DockingCompleted(chaser.id, target.id));
  }

  /// Port position + facing in the inertial frame.
  ({Vector3 position, Vector3 facing})? _portWorld(Vessel v, String portId) {
    final port = _findPort(v, portId);
    if (port == null) return null;
    final worldPos = v.state.position + v.state.attitude.rotate(port.position);
    final worldFacing = v.state.attitude.rotate(port.facing);
    return (position: worldPos, facing: worldFacing);
  }

  DockingPort? _findPort(Vessel v, String portId) {
    for (final p in v.allParts) {
      final dp = p.dockingPort;
      if (dp != null && dp.id == portId) return dp;
    }
    return null;
  }
}
