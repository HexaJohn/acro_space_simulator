import '../simulation/epoch.dart';
import 'cargo_schedule.dart';

/// Scans recurring [CargoSchedule]s and dispatches any whose departure time has
/// arrived (autonomous cargo ships leaving on a cadence). Domain service.
///
/// Dispatch here is the scheduling decision; actually flying the run is the
/// autopilot/docking pipeline (the carrier gets a flight plan elsewhere). The
/// scheduler returns the ids it dispatched so the application can wire up the
/// carriers' plans.
class CargoScheduler {
  const CargoScheduler();

  List<String> process(Iterable<CargoSchedule> schedules, {required Epoch now}) {
    final dispatched = <String>[];
    for (final s in schedules) {
      if (s.isDue(now)) {
        s.dispatch();
        dispatched.add(s.id);
      }
    }
    return dispatched;
  }
}
