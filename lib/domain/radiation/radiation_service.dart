import '../simulation/domain_event.dart';
import '../vessel/vessel.dart';

/// Accumulates radiation dose on a vessel's crew and applies the health
/// consequences. Domain service.
///
/// Dose builds at the supplied [doseRateSv] (Sv/s, already shielding-attenuated
/// by the [RadiationEnvironment] at the tick). Crossing the crew's sickness
/// threshold raises [CrewIrradiated] once; reaching the lethal dose kills the
/// crew and raises [CrewLost] with cause 'radiation'.
class RadiationService {
  const RadiationService();

  void apply(Vessel vessel, {required double doseRateSv, required double dt}) {
    final crew = vessel.crew;
    if (crew == null || crew.count <= 0 || doseRateSv <= 0) return;

    crew.accumulatedDose += doseRateSv * dt;

    if (crew.accumulatedDose >= crew.lethalDoseSv) {
      crew.count = 0;
      vessel.raise(CrewLost(vessel.id, 'radiation'));
      return;
    }

    if (!crew.sick && crew.accumulatedDose >= crew.sicknessThresholdSv) {
      crew.sick = true;
      vessel.raise(CrewIrradiated(vessel.id, crew.accumulatedDose));
    }
  }
}
