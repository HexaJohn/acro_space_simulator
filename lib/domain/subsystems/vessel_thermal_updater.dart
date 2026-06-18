import '../simulation/domain_event.dart';
import '../thermal/thermal_model.dart';
import '../universe/atmosphere_model.dart';
import '../vessel/vessel.dart';

/// Subsystem updater: runs the per-part [ThermalModel] over a vessel's thermal
/// states for one tick, then raises [PartOverheated] for any part that exceeds
/// its limit. Domain service — the application tick calls it during the
/// subsystem phase. Pure aside from mutating the vessel's owned thermal states.
class VesselThermalUpdater {
  final ThermalModel model;
  const VesselThermalUpdater([this.model = const ThermalModel()]);

  /// Largest thermal integration sub-step (s). The heat ODE (radiative cooling
  /// ∝ T^4) is stiff; a single huge dt at high time-warp overshoots and the
  /// temperature runs away (a landed craft "burning up" while warping). Split dt
  /// into chunks no bigger than this so the integration stays stable.
  static const double _maxSubStep = 2.0;

  void update(
    Vessel vessel, {
    required double dt,
    required AtmosphereSample ambient,
    required double airspeed,
    required double solarFlux,
    required double sunFacing, // 0..1 fraction of area lit
    double gasHeatingFactor = 1.0, // atmospheric-composition heating scale
  }) {
    // Sub-step the integration so a big warp dt doesn't overshoot. Cap the step
    // count so extreme warp doesn't spin millions of iterations — at that point
    // the craft is near thermal equilibrium anyway, so coarser steps are fine.
    const maxSteps = 64;
    var steps = dt <= _maxSubStep ? 1 : (dt / _maxSubStep).ceil();
    if (steps > maxSteps) steps = maxSteps;
    final sub = dt / steps;
    for (final t in vessel.thermal) {
      for (var i = 0; i < steps; i++) {
        model.advance(
          t,
          dt: sub,
          solarFlux: solarFlux,
          solarFacingFraction: sunFacing,
          ambient: ambient,
          airspeed: airspeed,
          gasHeatingFactor: gasHeatingFactor,
        );
      }
      if (model.exceedsLimit(t)) {
        vessel.raise(PartOverheated(vessel.id, t.part, t.temperature));
      }
    }
  }
}
