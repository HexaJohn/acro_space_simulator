// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../vessel/vessel.dart';
import 'flight_plan.dart';

/// Checks whether a vessel can afford a [FlightPlan] given its delta-v budget.
/// Domain service — the realism gate that stops autonomous vessels committing
/// to transfers they can't complete (running dry mid-burn).
class PlanValidator {
  const PlanValidator();

  /// Total delta-v the plan demands (sum of all maneuver-node magnitudes).
  double requiredDeltaV(FlightPlan plan) {
    var total = 0.0;
    for (final leg in plan.legs) {
      for (final node in leg.nodes) {
        total += node.magnitude;
      }
    }
    return total;
  }

  /// True if the vessel's current [Vessel.deltaVCapacity] covers the plan.
  bool canAfford(Vessel vessel, FlightPlan plan) =>
      vessel.deltaVCapacity() >= requiredDeltaV(plan);

  /// Delta-v left over after the plan (negative = short by that much).
  double margin(Vessel vessel, FlightPlan plan) =>
      vessel.deltaVCapacity() - requiredDeltaV(plan);
}

/// Validator that approves every plan — for debug/cheat vessels with infinite
/// propellant, or contexts where the fuel gate should be bypassed.
class AlwaysAffordablePlanValidator implements PlanValidator {
  const AlwaysAffordablePlanValidator();
  @override
  double requiredDeltaV(FlightPlan plan) => 0;
  @override
  bool canAfford(Vessel vessel, FlightPlan plan) => true;
  @override
  double margin(Vessel vessel, FlightPlan plan) => double.infinity;
}
