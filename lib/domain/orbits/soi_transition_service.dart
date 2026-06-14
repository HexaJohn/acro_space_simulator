import '../dynamics/state_vector.dart';
import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import '../universe/star_system.dart';
import 'body_ephemeris.dart';

/// Result of a sphere-of-influence transition: the body the vessel now belongs
/// to, and its state RE-EXPRESSED in that body's centred inertial frame.
class SoiTransitionResult {
  final CelestialBody newBody;
  final StateVector shiftedState;
  const SoiTransitionResult(this.newBody, this.shiftedState);
}

/// Detects patched-conic SOI transitions using REAL body positions from the
/// [BodyEphemeris], and computes the frame shift so the vessel's state is
/// continuous across the boundary. Domain service — the heart of correct
/// multi-body navigation.
///
/// Frame shift maths (Galilean, frames share axes):
///   entering child:  r' = r - r_child(parent frame),  v' = v - v_child
///   escaping to parent: r' = r + r_child(parent frame), v' = v + v_child
/// where r_child / v_child are the child's position/velocity relative to the
/// shared parent at this epoch.
class SoiTransitionService {
  final BodyEphemeris ephemeris;
  const SoiTransitionService([this.ephemeris = const BodyEphemeris()]);

  SoiTransitionResult? resolve({
    required StateVector state,
    required CelestialBody current,
    required StarSystem system,
    required Epoch epoch,
  }) {
    final r = state.position.length;

    // 1. Escape: outside the current body's SOI -> drop to the parent frame.
    if (!current.isStar && r > current.soiRadius) {
      final parent = system.parentOf(current);
      if (parent != null) {
        final rChild =
            ephemeris.positionRelativeToParent(current, system, epoch);
        final vChild =
            ephemeris.velocityRelativeToParent(current, system, epoch);
        return SoiTransitionResult(
          parent,
          state.copyWith(
            position: state.position + rChild,
            velocity: state.velocity + vChild,
          ),
        );
      }
    }

    // 2. Capture: entered a child body's SOI -> shift into the child frame.
    for (final child in system.childrenOf(current.id)) {
      final childPos = ephemeris.positionRelativeToParent(child, system, epoch);
      final rel = state.position - childPos;
      if (rel.length < child.soiRadius) {
        final childVel =
            ephemeris.velocityRelativeToParent(child, system, epoch);
        return SoiTransitionResult(
          child,
          state.copyWith(
            position: rel,
            velocity: state.velocity - childVel,
          ),
        );
      }
    }

    return null; // no transition
  }

  // Exposed for callers that only need the geometric offset.
  Vector3 parentFrameOffset(
    CelestialBody body,
    StarSystem system,
    Epoch epoch,
  ) =>
      ephemeris.positionRelativeToParent(body, system, epoch);
}
