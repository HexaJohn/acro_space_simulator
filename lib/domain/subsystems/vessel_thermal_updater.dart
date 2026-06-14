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

  void update(
    Vessel vessel, {
    required double dt,
    required AtmosphereSample ambient,
    required double airspeed,
    required double solarFlux,
    required double sunFacing, // 0..1 fraction of area lit
    double gasHeatingFactor = 1.0, // atmospheric-composition heating scale
  }) {
    for (final t in vessel.thermal) {
      model.advance(
        t,
        dt: dt,
        solarFlux: solarFlux,
        solarFacingFraction: sunFacing,
        ambient: ambient,
        airspeed: airspeed,
        gasHeatingFactor: gasHeatingFactor,
      );
      if (model.exceedsLimit(t)) {
        vessel.raise(PartOverheated(vessel.id, t.part, t.temperature));
      }
    }
  }
}
