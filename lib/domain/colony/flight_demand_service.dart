// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import 'colony.dart';

/// Converts arriving flights into city RCI demand at the destination — the link
/// between the autonomous-flight/logistics system and the city-builder. Domain
/// service.
///
/// Cargo arrivals feed industry (raw materials to process) and commerce (goods
/// to sell). Passenger arrivals feed residential (people needing homes) and
/// commercial (leisure/relaxation: shops, entertainment). Demand accumulates
/// and is consumed by zone growth, so steady flights keep a city expanding.
class FlightDemandService {
  /// Demand added per cargo unit / passenger (small; many flights add up).
  final double demandPerCargoUnit;
  final double demandPerPassenger;

  const FlightDemandService({
    this.demandPerCargoUnit = 0.001,
    this.demandPerPassenger = 0.004,
  });

  /// A cargo flight delivered [cargoUnits] of goods to [colony].
  void onCargoArrival(Colony colony, {required double cargoUnits}) {
    final d = cargoUnits * demandPerCargoUnit;
    colony.demand = colony.demand.add(industrial: d, commercial: d * 0.6);
  }

  /// A passenger flight brought [passengers] people to [colony].
  void onPassengerArrival(Colony colony, {required int passengers}) {
    final d = passengers * demandPerPassenger;
    colony.demand = colony.demand.add(residential: d, commercial: d * 0.5);
  }
}
