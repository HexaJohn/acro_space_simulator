// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../domain/shared/vector3.dart';

/// One planned conic leg for display: sampled points in [body]'s
/// centred-inertial frame (metres), exactly like [VesselSnapshot.trajectory].
class PlannerLegOverlay {
  final String body;
  final List<double> points; // flattened x,y,z triples
  final bool closed;

  const PlannerLegOverlay({
    required this.body,
    required this.points,
    required this.closed,
  });
}

/// Render feed for the encounter planner: the planning plane, the planned
/// post-burn trajectory legs, the burn point, and the closest-approach pair.
///
/// In-process only (never serialized, never part of the determinism
/// fingerprint) — this is UI planning state, not world state. All positions
/// are body-relative metres in [frameBody]'s centred-inertial frame; the
/// renderer adds the body's world position like it does for vessels.
class PlannerOverlay {
  /// The body the plan is anchored on (the craft's dominant body at the burn).
  final String frameBody;

  /// Unit normal of the post-burn orbital plane (inertial axes).
  final Vector3 planeNormal;

  /// Radius of the drawn planning plane, metres.
  final double planeRadiusM;

  final List<PlannerLegOverlay> legs;

  /// Burn point, [frameBody]-relative metres.
  final Vector3 nodePosition;

  /// Unit direction of the ascending/descending node line between the planned
  /// plane and the target's plane, through the body centre. Null when
  /// coplanar or the target orbits another body.
  final Vector3? nodeLineDirection;

  /// Closest-approach pair, [frameBody]-relative metres. Null without a
  /// target.
  final Vector3? closeApproachCraft;
  final Vector3? closeApproachTarget;

  /// Body id whose SOI the planned trajectory enters, if any.
  final String? encounterBody;

  const PlannerOverlay({
    required this.frameBody,
    required this.planeNormal,
    required this.planeRadiusM,
    required this.legs,
    required this.nodePosition,
    this.nodeLineDirection,
    this.closeApproachCraft,
    this.closeApproachTarget,
    this.encounterBody,
  });
}
