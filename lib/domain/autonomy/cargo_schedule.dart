// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import '../vessel/resource_container.dart';
import '../vessel/vessel.dart';

/// A recurring autonomous cargo run: pick up [resource] at [origin], deliver to
/// [destination], repeating every [period]. The autonomy scheduler spawns/launches
/// the assigned [carrier] when due. Aggregate root for logistics scheduling.
class CargoSchedule {
  final String id;
  final VesselId carrier;
  final BodyId origin;
  final BodyId destination;
  final ResourceType resource;
  final double quantity; // units per run

  /// Departure cadence and the next due time.
  final double period; // s between departures
  Epoch nextDeparture;

  /// Lifecycle of the active run, if any.
  CargoRunStatus status;

  CargoSchedule({
    required this.id,
    required this.carrier,
    required this.origin,
    required this.destination,
    required this.resource,
    required this.quantity,
    required this.period,
    required this.nextDeparture,
    this.status = CargoRunStatus.idle,
  });

  bool isDue(Epoch now) => status == CargoRunStatus.idle && now >= nextDeparture;

  /// Mark a run dispatched and roll the schedule forward one period.
  void dispatch() {
    status = CargoRunStatus.enRoute;
    nextDeparture = nextDeparture + period;
  }

  void completeRun() => status = CargoRunStatus.idle;
}

enum CargoRunStatus { idle, enRoute, docking, unloading }
