import 'dart:math' as math;

import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import 'flight_plan.dart';

/// Computes maneuver nodes for common orbital transfers. Domain service — pure
/// delta-v math, the analytical brain behind autonomous flight planning. The
/// nodes it returns are executed by the [AutopilotUpdater].
///
/// All delta-v is in the prograde/normal/radial (PNR) frame the autopilot
/// expects; transfers here are coplanar so only the prograde (x) component is
/// non-zero.
class ManeuverPlanner {
  const ManeuverPlanner();

  /// Two-burn Hohmann transfer between coplanar circular orbits of radius
  /// [fromRadius] and [toRadius] about a body of gravitational parameter [mu].
  ///
  /// Burn 1 at [startEpoch] enters the transfer ellipse; burn 2 half a transfer
  /// period later circularizes at the destination. Prograde when raising,
  /// retrograde when lowering — the signs fall out of the formulas.
  List<ManeuverNode> hohmann({
    required double mu,
    required double fromRadius,
    required double toRadius,
    required Epoch startEpoch,
  }) {
    final r1 = fromRadius;
    final r2 = toRadius;
    final at = (r1 + r2) / 2; // transfer semi-major axis

    final vCirc1 = math.sqrt(mu / r1);
    final vCirc2 = math.sqrt(mu / r2);
    final vTransfer1 = math.sqrt(mu * (2 / r1 - 1 / at)); // speed at r1 on ellipse
    final vTransfer2 = math.sqrt(mu * (2 / r2 - 1 / at)); // speed at r2 on ellipse

    final dv1 = vTransfer1 - vCirc1; // +raise / -lower
    final dv2 = vCirc2 - vTransfer2;

    final tHalf = math.pi * math.sqrt(at * at * at / mu);

    return [
      ManeuverNode(executeAt: startEpoch, deltaV: Vector3(dv1, 0, 0)),
      ManeuverNode(
        executeAt: startEpoch + tHalf,
        deltaV: Vector3(dv2, 0, 0),
      ),
    ];
  }

  /// Single burn to circularize at [radius]: matches the local circular speed.
  /// Positive prograde when currently slower than circular, retrograde when
  /// faster.
  ManeuverNode circularize({
    required double mu,
    required double radius,
    required double currentSpeed,
    required Epoch atEpoch,
  }) {
    final vCirc = math.sqrt(mu / radius);
    return ManeuverNode(
      executeAt: atEpoch,
      deltaV: Vector3(vCirc - currentSpeed, 0, 0),
    );
  }

  /// A pure inclination (plane) change at [orbitalSpeed]: delta-v =
  /// 2 v sin(di/2), applied along the orbit normal. Best done at low orbital
  /// speed (apoapsis) — the caller chooses [atEpoch].
  ManeuverNode planeChange({
    required double orbitalSpeed,
    required double inclinationChange,
    required Epoch atEpoch,
  }) {
    final dv = 2 * orbitalSpeed * math.sin(inclinationChange.abs() / 2);
    final signed = inclinationChange >= 0 ? dv : -dv;
    return ManeuverNode(executeAt: atEpoch, deltaV: Vector3(0, signed, 0));
  }

  /// A Hohmann transfer plus a plane change executed at the destination (where
  /// orbital speed is lowest, so the inclination change is cheapest). Returns
  /// three nodes: depart, arrive-circularize, plane-change.
  List<ManeuverNode> hohmannWithPlaneChange({
    required double mu,
    required double fromRadius,
    required double toRadius,
    required double inclinationChange,
    required Epoch startEpoch,
  }) {
    final transfer =
        hohmann(mu: mu, fromRadius: fromRadius, toRadius: toRadius, startEpoch: startEpoch);
    final vAtDest = math.sqrt(mu / toRadius);
    final plane = planeChange(
      orbitalSpeed: vAtDest,
      inclinationChange: inclinationChange,
      atEpoch: transfer.last.executeAt,
    );
    return [...transfer, plane];
  }

  /// Total delta-v budget of a Hohmann transfer (sum of burn magnitudes) —
  /// useful for fuel checks before committing a plan.
  double hohmannDeltaVBudget({
    required double mu,
    required double fromRadius,
    required double toRadius,
  }) {
    final nodes = hohmann(
      mu: mu,
      fromRadius: fromRadius,
      toRadius: toRadius,
      startEpoch: Epoch.zero,
    );
    return nodes.fold(0.0, (s, n) => s + n.magnitude);
  }
}
