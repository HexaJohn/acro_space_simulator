import '../simulation/domain_event.dart';
import '../universe/atmosphere_model.dart';
import '../vessel/vessel.dart';

/// Checks a vessel against aerodynamic structural limits. A vessel that exceeds
/// its maximum dynamic pressure (max-Q) breaks apart — the classic launch /
/// reentry failure when going too fast too low. Domain service.
///
/// Dynamic pressure q = 0.5 * rho * v^2. The caller (tick) removes a vessel that
/// returns true and publishes the raised [StructuralFailure].
class StructuralService {
  const StructuralService();

  /// Returns true if the vessel failed structurally this tick.
  bool check(
    Vessel vessel, {
    required AtmosphereSample ambient,
    required double maxDynamicPressure,
  }) {
    if (ambient.density <= 0) return false;
    final speed = vessel.state.velocity.length;
    final q = 0.5 * ambient.density * speed * speed;
    if (q > maxDynamicPressure) {
      vessel.raise(StructuralFailure(vessel.id, q));
      return true;
    }
    return false;
  }
}
