// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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
