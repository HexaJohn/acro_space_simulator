// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
