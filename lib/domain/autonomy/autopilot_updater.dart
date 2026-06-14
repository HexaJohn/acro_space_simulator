import '../shared/vector3.dart';
import '../simulation/domain_event.dart';
import '../simulation/epoch.dart';
import '../vessel/vessel.dart';
import 'flight_plan.dart';
import 'plan_validator.dart';

/// Executes a vessel's [FlightPlan]: when a [ManeuverNode]'s execute epoch has
/// passed, applies its delta-v as an instantaneous impulse (impulsive-burn
/// approximation — exact for gameplay-scale nodes), consumes the node, and
/// advances the leg when its nodes are spent.
///
/// Delta-v is given in the prograde/normal/radial (PNR) frame:
///   prograde = v̂
///   normal   = (r × v)̂   (orbit normal)
///   radial   = prograde × normal
/// The updater rotates it into the inertial frame before adding to velocity.
///
/// Domain service — pure aside from mutating the vessel's plan and velocity.
class AutopilotUpdater {
  final PlanValidator validator;
  const AutopilotUpdater({this.validator = const PlanValidator()});

  void update(Vessel vessel, {required Epoch now}) {
    final plan = vessel.flightPlan;
    if (plan == null || plan.isComplete) return;
    final leg = plan.currentLeg;
    if (leg == null || leg.nodes.isEmpty) {
      if (leg != null) plan.advanceLeg();
      return;
    }

    final node = leg.nodes.first;

    // Point the vessel prograde ahead of the burn so the attitude controller
    // can orient it in time (cosmetic for the impulsive model, but it makes the
    // ship visibly turn to face its burn direction).
    final vNow = vessel.state.velocity;
    if (vNow.length > 1e-6) vessel.targetFacing = vNow.normalized;

    if (now.seconds < node.executeAt.seconds) return; // not due yet

    // Comms gate: a blacked-out vessel can't act on commands — hold the burn
    // until the control link is restored. (Attitude was set above, which is a
    // passive on-board behaviour and may continue.)
    if (!vessel.hasCommLink) return;

    // Fuel-budget gate: when the first burn of the plan comes due, verify the
    // vessel can afford the whole plan. If not, abort rather than strand it
    // half-way through a transfer.
    if (!validator.canAfford(vessel, plan)) {
      vessel.raise(PlanAborted(
        vessel.id,
        'insufficient delta-v: have ${vessel.deltaVCapacity().toStringAsFixed(0)} m/s, '
        'need ${validator.requiredDeltaV(plan).toStringAsFixed(0)} m/s',
      ));
      vessel.flightPlan = null;
      return;
    }

    // Build the PNR basis from the current state.
    final v = vessel.state.velocity;
    final r = vessel.state.position;
    final prograde = v.length < 1e-9 ? Vector3.unitY : v.normalized;
    final h = r.cross(v);
    final normal = h.length < 1e-9 ? Vector3.unitZ : h.normalized;
    final radial = prograde.cross(normal).normalized;

    // deltaV components: x=prograde, y=normal, z=radial.
    final dvInertial = prograde * node.deltaV.x +
        normal * node.deltaV.y +
        radial * node.deltaV.z;

    vessel.updateState(
      vessel.state.copyWith(velocity: vessel.state.velocity + dvInertial),
    );

    // Consume the node; advance the leg when empty.
    leg.nodes.removeAt(0);
    if (leg.nodes.isEmpty) plan.advanceLeg();
  }
}
