// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'pnr_basis.dart';
import 'dart:math' as math;

import '../autonomy/flight_plan.dart';
import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import '../universe/star_system.dart';
import 'body_ephemeris.dart';
import 'orbit.dart';
import 'patched_conic_service.dart';
import 'state_vector_converter.dart';

/// The predicted closest pass between the planned trajectory and the target.
///
/// Positions are body-centred inertial metres in [frameBody]'s frame (the
/// planning frame — the body the craft orbits when the burn happens), so a
/// renderer places them exactly like vessel snapshot positions.
class CloseApproach {
  final double distanceMeters;
  final double epochSeconds;
  final Vector3 craftPosition;
  final Vector3 targetPosition;
  final BodyId frameBody;

  const CloseApproach({
    required this.distanceMeters,
    required this.epochSeconds,
    required this.craftPosition,
    required this.targetPosition,
    required this.frameBody,
  });
}

/// What a planned maneuver leads to: the post-burn conic legs, the burn point,
/// and — when a target is set — the predicted closest approach, any SOI
/// encounter, and the geometry relating the two orbital planes.
class EncounterPlan {
  /// The node this plan evaluates (absolute epoch + PNR delta-v).
  final ManeuverNode node;

  /// Body-centred position of the burn point, in [postOrbit]'s body frame.
  final Vector3 burnPosition;

  /// Post-burn patched-conic legs (first leg starts at the burn).
  final List<ConicPatch> patches;

  /// The first post-burn conic (for apsis readouts).
  final Orbit postOrbit;

  final CloseApproach? closeApproach;

  /// Target body whose SOI the planned trajectory enters, if any.
  final BodyId? encounterBody;
  final double? encounterEpochSeconds;

  /// Angle between the post-burn orbital plane and the target's plane (rad),
  /// null without a target.
  final double? relativeInclination;

  /// Unit direction (inertial) of the line of nodes between the post-burn
  /// plane and the target's plane, through the planning body's centre. Null
  /// when coplanar or the target orbits a different body.
  final Vector3? nodeLineDirection;

  /// Unit normal (inertial) of the post-burn orbital plane.
  final Vector3 planeNormal;

  const EncounterPlan({
    required this.node,
    required this.burnPosition,
    required this.patches,
    required this.postOrbit,
    required this.planeNormal,
    this.closeApproach,
    this.encounterBody,
    this.encounterEpochSeconds,
    this.relativeInclination,
    this.nodeLineDirection,
  });
}

/// A rendezvous target that is another craft: its state at the planning epoch,
/// in its dominant body's centred-inertial frame (root-parallel axes).
class TargetCraftState {
  final Vector3 position;
  final Vector3 velocity;
  final BodyId body;

  const TargetCraftState({
    required this.position,
    required this.velocity,
    required this.body,
  });
}

/// Evaluates a planned maneuver against a target: propagate the craft's conic
/// to the burn, apply the node's delta-v in the prograde/normal/radial frame,
/// predict the resulting patched-conic trajectory, and search it for the
/// closest approach to a target body (moon transfer) or target craft
/// (rendezvous). Domain service — pure, display-oriented; the numbers a
/// transfer-planning UI shows while the player drags the node.
class EncounterPlannerService {
  final StateVectorOrbitConverter converter;
  final PatchedConicService patchedConics;
  final BodyEphemeris ephemeris;

  const EncounterPlannerService({
    this.converter = const StateVectorOrbitConverter(),
    this.patchedConics = const PatchedConicService(),
    this.ephemeris = const BodyEphemeris(),
  });

  /// Evaluate [node] for a craft at ([position], [velocity]) about [body] at
  /// [epoch]. At most one of [targetBody] / [targetCraft] should be set.
  ///
  /// Returns null for a degenerate state the conic solver cannot propagate
  /// (landed / zero-radius orbit).
  EncounterPlan? plan({
    required Vector3 position,
    required Vector3 velocity,
    required CelestialBody body,
    required StarSystem system,
    required Epoch epoch,
    required ManeuverNode node,
    BodyId? targetBody,
    TargetCraftState? targetCraft,
  }) {
    final orbit = converter.toOrbit(
        position: position, velocity: velocity, body: body, epoch: epoch);
    final n = orbit.elements.meanMotion(orbit.mu);
    if (!n.isFinite || n <= 0) return null;

    // Burns cannot be scheduled in the past; clamp to "now".
    final tBurn = math.max(node.executeAt.seconds, epoch.seconds);
    final sBurn = converter.toStateVector(orbit, Epoch(tBurn));

    // Prograde/normal/radial basis at the burn point (the ManeuverNode frame):
    // prograde along the velocity, normal along the orbit's angular momentum,
    // radial completing the right-handed triad (points away from the body).
    final basis = pnrBasis(sBurn.position, sBurn.velocity);
    final vNew = sBurn.velocity +
        basis.prograde * node.deltaV.x +
        basis.normal * node.deltaV.y +
        basis.radial * node.deltaV.z;

    final postOrbit = converter.toOrbit(
        position: sBurn.position, velocity: vNew, body: body, epoch: Epoch(tBurn));
    final nPost = postOrbit.elements.meanMotion(postOrbit.mu);
    if (!nPost.isFinite || nPost <= 0) return null;

    final patches = patchedConics.predict(
      position: sBurn.position,
      velocity: vNew,
      body: body,
      system: system,
      epoch: Epoch(tBurn),
      pointsPerPatch: 192,
    );
    if (patches.isEmpty) return null;

    final hPost = sBurn.position.cross(vNew);
    final planeNormal =
        hPost.length > 1e-9 ? hPost.normalized : Vector3.unitZ;

    // SOI encounter along the planned legs, if any.
    BodyId? encounterBody;
    double? encounterEpoch;
    for (final p in patches) {
      if (p.end == PatchEndKind.encounter && p.nextBody != null) {
        encounterBody = p.nextBody;
        encounterEpoch = p.endSeconds;
        break;
      }
    }

    // Target geometry.
    CloseApproach? ca;
    double? relInc;
    Vector3? nodeLine;
    if (targetBody != null || targetCraft != null) {
      final Vector3 Function(double t) targetWorldAt;
      Vector3? hTarget;
      var targetOrbitsPlanningBody = false;
      BodyId? targetSoiBody;

      if (targetBody != null) {
        final tgt = system.body(targetBody);
        if (tgt != null) {
          targetSoiBody = tgt.id;
          targetWorldAt =
              (t) => ephemeris.positionRelativeToRoot(tgt, system, Epoch(t));
          final parent = system.parentOf(tgt);
          if (parent != null) {
            final rT =
                ephemeris.positionRelativeToParent(tgt, system, Epoch(tBurn));
            final vT =
                ephemeris.velocityRelativeToParent(tgt, system, Epoch(tBurn));
            final hT = rT.cross(vT);
            if (hT.length > 1e-9) hTarget = hT.normalized;
            targetOrbitsPlanningBody = parent.id == body.id;
          }
          ca = _closestApproach(
            postOrbit: postOrbit,
            patches: patches,
            system: system,
            tBurn: tBurn,
            frameBody: body,
            targetWorldAt: targetWorldAt,
            targetSoiBody: targetSoiBody,
          );
        }
      } else {
        final tc = targetCraft!;
        final tcBody = system.body(tc.body);
        if (tcBody != null) {
          final tcOrbit = converter.toOrbit(
              position: tc.position,
              velocity: tc.velocity,
              body: tcBody,
              epoch: epoch);
          final nTc = tcOrbit.elements.meanMotion(tcOrbit.mu);
          if (nTc.isFinite && nTc > 0) {
            targetWorldAt = (t) =>
                ephemeris.positionRelativeToRoot(tcBody, system, Epoch(t)) +
                converter.toStateVector(tcOrbit, Epoch(t)).position;
            final hT = tc.position.cross(tc.velocity);
            if (hT.length > 1e-9) hTarget = hT.normalized;
            targetOrbitsPlanningBody = tc.body == body.id;
            ca = _closestApproach(
              postOrbit: postOrbit,
              patches: patches,
              system: system,
              tBurn: tBurn,
              frameBody: body,
              targetWorldAt: targetWorldAt,
              targetSoiBody: null,
            );
          }
        }
      }

      if (hTarget != null) {
        final cosI = planeNormal.dot(hTarget).clamp(-1.0, 1.0);
        relInc = math.acos(cosI);
        if (targetOrbitsPlanningBody) {
          final line = planeNormal.cross(hTarget);
          if (line.length > 1e-6) nodeLine = line.normalized;
        }
      }
    }

    return EncounterPlan(
      node: ManeuverNode(executeAt: Epoch(tBurn), deltaV: node.deltaV),
      burnPosition: sBurn.position,
      patches: patches,
      postOrbit: postOrbit,
      planeNormal: planeNormal,
      closeApproach: ca,
      encounterBody: encounterBody,
      encounterEpochSeconds: encounterEpoch,
      relativeInclination: relInc,
      nodeLineDirection: nodeLine,
    );
  }

  // ---- Closest-approach search ----

  /// Global minimum of |craft(t) - target(t)| over the planned legs, root
  /// frame. The first leg is scanned analytically on [postOrbit] (coarse scan
  /// + golden-section refine); later legs — whose conics aren't carried by
  /// [ConicPatch] — are scanned through their sampled points (arcs are
  /// uniform in time). A leg INSIDE the target's own SOI reports distance to
  /// that leg's body centre directly (the encounter periapsis).
  CloseApproach? _closestApproach({
    required Orbit postOrbit,
    required List<ConicPatch> patches,
    required StarSystem system,
    required double tBurn,
    required CelestialBody frameBody,
    required Vector3 Function(double t) targetWorldAt,
    required BodyId? targetSoiBody,
  }) {
    Vector3 frameRootAt(double t) =>
        ephemeris.positionRelativeToRoot(frameBody, system, Epoch(t));

    double? bestDist;
    double? bestT;

    // Leg 0: analytic conic, so the scan and refine are exact.
    final first = patches.first;
    final closed = first.end == PatchEndKind.closed;
    final t0 = tBurn;
    final t1 = closed ? tBurn + postOrbit.period : first.endSeconds;
    if (t1 > t0 && t1.isFinite) {
      final legBodyCel = system.body(first.body) ?? frameBody;
      Vector3 craftWorldAt(double t) =>
          ephemeris.positionRelativeToRoot(legBodyCel, system, Epoch(t)) +
          converter.toStateVector(postOrbit, Epoch(t)).position;
      double dist(double t) => (craftWorldAt(t) - targetWorldAt(t)).length;

      const samples = 256;
      var coarseBestT = t0;
      var coarseBest = double.infinity;
      for (var i = 0; i <= samples; i++) {
        final t = t0 + (t1 - t0) * i / samples;
        final d = dist(t);
        if (d < coarseBest) {
          coarseBest = d;
          coarseBestT = t;
        }
      }
      // Golden-section refine one coarse cell either side of the best sample.
      final cell = (t1 - t0) / samples;
      var lo = math.max(t0, coarseBestT - cell);
      var hi = math.min(t1, coarseBestT + cell);
      const invPhi = 0.6180339887498949;
      var a = hi - (hi - lo) * invPhi;
      var b = lo + (hi - lo) * invPhi;
      var fa = dist(a), fb = dist(b);
      for (var i = 0; i < 40; i++) {
        if (fa < fb) {
          hi = b;
          b = a;
          fb = fa;
          a = hi - (hi - lo) * invPhi;
          fa = dist(a);
        } else {
          lo = a;
          a = b;
          fa = fb;
          b = lo + (hi - lo) * invPhi;
          fb = dist(b);
        }
      }
      final tMin = (lo + hi) / 2;
      final dMin = dist(tMin);
      bestDist = dMin;
      bestT = tMin;
    }

    // Later legs. Points are body-centred in the leg's own frame; arc legs are
    // sampled uniformly in time so index -> epoch is a lerp. A closed later
    // leg is only usable for the "inside the target's SOI" case (min radius).
    for (var k = 1; k < patches.length; k++) {
      final leg = patches[k];
      if (leg.points.length < 2) continue;
      final legBodyCel = system.body(leg.body);
      if (legBodyCel == null) continue;
      final insideTarget = targetSoiBody != null && leg.body == targetSoiBody;
      if (leg.end == PatchEndKind.closed && !insideTarget) continue;
      final m = leg.points.length - 1;
      for (var i = 0; i <= m; i++) {
        final t =
            leg.startSeconds + (leg.endSeconds - leg.startSeconds) * i / m;
        final double d;
        if (insideTarget) {
          d = leg.points[i].length; // distance to the target body's centre
        } else {
          final world =
              ephemeris.positionRelativeToRoot(legBodyCel, system, Epoch(t)) +
                  leg.points[i];
          d = (world - targetWorldAt(t)).length;
        }
        if (bestDist == null || d < bestDist) {
          bestDist = d;
          bestT = t;
        }
      }
    }

    if (bestDist == null || bestT == null) return null;
    final tCa = bestT;

    // Report positions in the planning body's centred frame. The craft world
    // position at the CA epoch comes from whichever leg owns that epoch.
    final frameRoot = frameRootAt(tCa);
    Vector3 craftWorld;
    final owner = patches.lastWhere(
      (p) => tCa >= p.startSeconds && tCa <= p.endSeconds,
      orElse: () => patches.first,
    );
    if (identical(owner, patches.first)) {
      final legBodyCel = system.body(owner.body) ?? frameBody;
      craftWorld =
          ephemeris.positionRelativeToRoot(legBodyCel, system, Epoch(tCa)) +
              converter.toStateVector(postOrbit, Epoch(tCa)).position;
    } else {
      final legBodyCel = system.body(owner.body);
      if (legBodyCel == null) return null;
      final m = owner.points.length - 1;
      final span = owner.endSeconds - owner.startSeconds;
      final idx = span <= 0
          ? 0
          : (((tCa - owner.startSeconds) / span) * m).round().clamp(0, m);
      craftWorld =
          ephemeris.positionRelativeToRoot(legBodyCel, system, Epoch(tCa)) +
              owner.points[idx];
    }
    // A leg inside the target's SOI measured distance to the leg body itself.
    final insideTarget = targetSoiBody != null && owner.body == targetSoiBody;
    final targetWorld = insideTarget
        ? ephemeris.positionRelativeToRoot(
            system.body(targetSoiBody)!, system, Epoch(tCa))
        : targetWorldAt(tCa);

    return CloseApproach(
      distanceMeters: bestDist,
      epochSeconds: tCa,
      craftPosition: craftWorld - frameRoot,
      targetPosition: targetWorld - frameRoot,
      frameBody: frameBody.id,
    );
  }
}
