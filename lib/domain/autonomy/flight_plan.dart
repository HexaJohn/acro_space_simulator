// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import '../vessel/vessel.dart';

/// A scheduled maneuver: apply [deltaV] (m/s, in the orbital prograde/normal/
/// radial frame) at [executeAt]. Value object; the autopilot executes nodes.
class ManeuverNode {
  final Epoch executeAt;
  final Vector3 deltaV; // prograde, normal, radial components

  const ManeuverNode({required this.executeAt, required this.deltaV});

  double get magnitude => deltaV.length;
}

/// One leg of an autonomous route: go to a target body/orbit, optionally dock.
class FlightLeg {
  final BodyId targetBody;
  final double targetAltitude; // m, parking orbit
  final VesselId? dockWith; // dock target, if any
  final List<ManeuverNode> nodes;

  const FlightLeg({
    required this.targetBody,
    required this.targetAltitude,
    this.dockWith,
    this.nodes = const [],
  });
}

/// An ordered plan an autonomous vessel follows. Aggregate root for autonomy.
class FlightPlan {
  final VesselId vessel;
  final List<FlightLeg> legs;
  int currentLegIndex;

  FlightPlan({
    required this.vessel,
    required this.legs,
    this.currentLegIndex = 0,
  });

  bool get isComplete => currentLegIndex >= legs.length;
  FlightLeg? get currentLeg => isComplete ? null : legs[currentLegIndex];

  void advanceLeg() => currentLegIndex++;
}
