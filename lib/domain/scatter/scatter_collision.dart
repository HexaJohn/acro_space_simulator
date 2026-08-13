// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/vector3.dart';
import '../terrain/cubed_sphere.dart';
import 'prop_catalog.dart';
import 'scatter_instance.dart';
import 'scatter_layer.dart';
import 'scatter_placement.dart';

/// The proxy shape a prop is solid as.
enum ColliderShape {
  /// Passes straight through. Grass and ferns are not obstacles.
  none,

  /// An upright capsule-less cylinder about the prop's own up axis — a trunk.
  trunk,

  /// A ball centred above the prop's base — a boulder.
  boulder,
}

/// How solid one kind of prop is.
///
/// Collision proxies are derived ANALYTICALLY from the kind and the instance's
/// scale, never from its generated mesh. Collision has to answer "what is near
/// this craft" every physics tick, potentially off the render thread entirely,
/// and growing a few thousand trees to ask how wide their trunks are is not a
/// thing the simulation can afford. The profiles below are calibrated against
/// the real geometry and a test holds them to it (see
/// `scatter_collision_test.dart`), so the cheap answer stays the true one.
///
/// A tree is solid at the TRUNK only. Its canopy is leaves: something that
/// brushes through it should keep going, and a proxy that stopped a craft dead
/// several metres from the bark would feel broken in exactly the way invisible
/// walls always do.
class ColliderProfile {
  const ColliderProfile({
    required this.shape,
    required this.radiusFactor,
    required this.heightFactor,
    required this.centreFactor,
  });

  final ColliderShape shape;

  /// Proxy radius as a fraction of the instance's nominal size.
  final double radiusFactor;

  /// Proxy height as a fraction of the instance's nominal size ([trunk] only).
  final double heightFactor;

  /// Centre height above the base, as a fraction of nominal size ([boulder]).
  final double centreFactor;

  static const _passThrough = ColliderProfile(
    shape: ColliderShape.none,
    radiusFactor: 0,
    heightFactor: 0,
    centreFactor: 0,
  );

  /// The profile for [kind].
  ///
  /// Tree radii track the generators' trunk radius (`height * 0.024` for a
  /// broadleaf, `* 0.017` for a conifer, and so on) with a little added so the
  /// proxy is never thinner than the bark it stands for. Heights run short of
  /// the full canopy on purpose — see the class note on trunks versus leaves.
  static ColliderProfile of(PropKind kind) => switch (kind) {
        PropKind.broadleafTree => const ColliderProfile(
            shape: ColliderShape.trunk,
            radiusFactor: 0.035,
            heightFactor: 0.55,
            centreFactor: 0,
          ),
        PropKind.coniferTree => const ColliderProfile(
            shape: ColliderShape.trunk,
            radiusFactor: 0.026,
            heightFactor: 0.85,
            centreFactor: 0,
          ),
        PropKind.palmTree => const ColliderProfile(
            shape: ColliderShape.trunk,
            radiusFactor: 0.030,
            heightFactor: 0.80,
            centreFactor: 0,
          ),
        PropKind.deadSnag => const ColliderProfile(
            shape: ColliderShape.trunk,
            radiusFactor: 0.045,
            heightFactor: 0.70,
            centreFactor: 0,
          ),
        // Ground cover is soft. Walking or driving through it must not stop
        // anything, and a shrub is not an obstacle either.
        PropKind.grassTuft ||
        PropKind.fern ||
        PropKind.shrub ||
        PropKind.reeds =>
          _passThrough,
        // Rocks are modelled part-buried, so the ball sits low and is a touch
        // under the visual radius: a proxy that stuck out past the stone would
        // stop a craft in mid-air beside it.
        PropKind.boulder => const ColliderProfile(
            shape: ColliderShape.boulder,
            radiusFactor: 0.95,
            heightFactor: 0,
            centreFactor: 0.55,
          ),
        PropKind.rockShard => const ColliderProfile(
            shape: ColliderShape.boulder,
            radiusFactor: 0.80,
            heightFactor: 0,
            centreFactor: 0.85,
          ),
        PropKind.rockSlab => const ColliderProfile(
            shape: ColliderShape.boulder,
            radiusFactor: 1.05,
            heightFactor: 0,
            centreFactor: 0.20,
          ),
        PropKind.rockCluster => const ColliderProfile(
            shape: ColliderShape.boulder,
            radiusFactor: 1.30,
            heightFactor: 0,
            centreFactor: 0.40,
          ),
      };
}

/// A contact between a probe and a prop.
class ScatterHit {
  const ScatterHit({
    required this.instance,
    required this.depthM,
    required this.normalBF,
    required this.pointBF,
  });

  final ScatterInstance instance;

  /// How far the probe has penetrated (m). Always positive.
  final double depthM;

  /// Unit surface normal at the contact, pointing OUT of the prop — the
  /// direction the probe must move to separate.
  final Vector3 normalBF;

  /// Contact point on the prop's surface (body-fixed metres).
  final Vector3 pointBF;
}

/// One prop's solid proxy, positioned in the body-fixed frame.
class ScatterCollider {
  ScatterCollider(this.instance)
      : profile = ColliderProfile.of(instance.kind),
        _sizeM = instance.kind.defaultSizeM * instance.scale;

  final ScatterInstance instance;
  final ColliderProfile profile;
  final double _sizeM;

  bool get isSolid => profile.shape != ColliderShape.none;

  double get radiusM => _sizeM * profile.radiusFactor;
  double get heightM => _sizeM * profile.heightFactor;

  /// Radius of a sphere at [instance].positionBF containing the whole proxy —
  /// the broad-phase bound.
  double get boundingRadiusM => switch (profile.shape) {
        ColliderShape.none => 0.0,
        ColliderShape.trunk => math.sqrt(radiusM * radiusM + heightM * heightM),
        ColliderShape.boulder => _sizeM * profile.centreFactor + radiusM,
      };

  /// Test a sphere of [probeRadiusM] centred at [pointBF] against this proxy.
  ///
  /// Returns null when there is no contact. A sphere probe rather than a point
  /// because everything that will ask — a craft's hull, a wheel, a foot — has
  /// size, and inflating the query is far cheaper than meshing the caller.
  ScatterHit? probe(Vector3 pointBF, {double probeRadiusM = 0.0}) {
    switch (profile.shape) {
      case ColliderShape.none:
        return null;

      case ColliderShape.boulder:
        final centre = instance.positionBF + instance.upBF * (_sizeM * profile.centreFactor);
        final delta = pointBF - centre;
        final dist = delta.length;
        final reach = radiusM + probeRadiusM;
        if (dist >= reach) return null;
        // A probe exactly at the centre has no defined direction; push it out
        // along the prop's up axis rather than returning a zero normal.
        final normal = dist < 1e-9 ? instance.upBF : delta / dist;
        return ScatterHit(
          instance: instance,
          depthM: reach - dist,
          normalBF: normal,
          pointBF: centre + normal * radiusM,
        );

      case ColliderShape.trunk:
        final axis = instance.upBF;
        final base = instance.positionBF;
        final along = (pointBF - base).dot(axis);
        // Clamp to the trunk's span, so the ends behave as flat caps rather
        // than extending the cylinder to infinity.
        final clamped = along.clamp(0.0, heightM);
        final onAxis = base + axis * clamped;
        final radial = pointBF - onAxis;
        final dist = radial.length;
        final reach = radiusM + probeRadiusM;
        if (dist >= reach) return null;
        // Above the top or below the base, the nearest surface is the cap, and
        // the separating direction is along the axis.
        if (along > heightM || along < 0.0) {
          final capNormal = along < 0.0 ? -axis : axis;
          final overshoot = along < 0.0 ? -along : along - heightM;
          if (overshoot >= probeRadiusM) return null;
          return ScatterHit(
            instance: instance,
            depthM: probeRadiusM - overshoot,
            normalBF: capNormal,
            pointBF: onAxis + radial,
          );
        }
        final normal = dist < 1e-9
            ? _anyPerpendicular(axis)
            : radial / dist;
        return ScatterHit(
          instance: instance,
          depthM: reach - dist,
          normalBF: normal,
          pointBF: onAxis + normal * radiusM,
        );
    }
  }

  static Vector3 _anyPerpendicular(Vector3 axis) {
    final seed = axis.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    return seed.cross(axis).normalized;
  }
}

/// Answers "what solid props are near this point" by regenerating them.
///
/// Nothing is cached and nothing is stored. [ScatterPlacement] is a pure
/// function of the cell, so the collision system and the renderer can each ask
/// independently and are guaranteed the same answer — the same guarantee, for
/// the same reason, that lets terrain collision and the terrain mesher share
/// one density field. **The rock you crash into is the rock you can see.**
///
/// Only layers with at least one solid kind are consulted, so a query never
/// pays to generate the grass it would immediately discard.
class ScatterColliders {
  ScatterColliders(this.placement, {List<ScatterLayer>? layers})
      : layers = [
          for (final l in layers ?? ScatterLayers.all)
            if (l.kinds.any((k) => ColliderProfile.of(k).shape != ColliderShape.none))
              l,
        ];

  final ScatterPlacement placement;

  /// The layers that can produce something solid.
  final List<ScatterLayer> layers;

  /// The largest bounding radius any prop of [layer] can have — how far outside
  /// the query sphere cells still have to be searched, or a tree whose trunk
  /// reaches in from just beyond the edge would be missed.
  static double _maxReachOf(ScatterLayer layer) {
    var reach = 0.0;
    final (_, maxScale) = layer.scaleRange;
    for (final kind in layer.kinds) {
      final profile = ColliderProfile.of(kind);
      if (profile.shape == ColliderShape.none) continue;
      final size = kind.defaultSizeM * maxScale;
      final r = switch (profile.shape) {
        ColliderShape.none => 0.0,
        ColliderShape.trunk => math.sqrt(
            math.pow(size * profile.radiusFactor, 2) +
                math.pow(size * profile.heightFactor, 2)),
        ColliderShape.boulder =>
          size * (profile.centreFactor + profile.radiusFactor),
      };
      if (r > reach) reach = r;
    }
    return reach;
  }

  /// Every solid prop whose proxy could reach within [radiusM] of [pointBF].
  ///
  /// Broad phase only — the caller narrows with [ScatterCollider.probe].
  List<ScatterCollider> near(Vector3 pointBF, double radiusM) {
    final len = pointBF.length;
    if (len < 1e-6) return const [];
    final dir = pointBF / len;
    final bodyRadius = placement.field.radius;

    final out = <ScatterCollider>[];
    for (final layer in layers) {
      final level = layer.levelFor(bodyRadius);
      final search = radiusM + _maxReachOf(layer);
      for (final cell in _cellsNear(dir, search / bodyRadius, level)) {
        for (final instance in placement.instancesFor(cell, layer)) {
          final collider = ScatterCollider(instance);
          if (!collider.isSolid) continue;
          final gap = (instance.positionBF - pointBF).length;
          if (gap > radiusM + collider.boundingRadiusM) continue;
          out.add(collider);
        }
      }
    }
    return out;
  }

  /// The deepest contact between a sphere at [pointBF] and any solid prop.
  ///
  /// Deepest rather than first: a craft wedged between two boulders has to be
  /// pushed out of the one it is furthest into, and resolving an arbitrary one
  /// first can shove it deeper into the other.
  ScatterHit? deepestHit(Vector3 pointBF, {double probeRadiusM = 0.0}) {
    ScatterHit? worst;
    for (final collider in near(pointBF, probeRadiusM)) {
      final hit = collider.probe(pointBF, probeRadiusM: probeRadiusM);
      if (hit == null) continue;
      if (worst == null || hit.depthM > worst.depthM) worst = hit;
    }
    return worst;
  }

  /// Every contact for a sphere at [pointBF].
  List<ScatterHit> hits(Vector3 pointBF, {double probeRadiusM = 0.0}) => [
        for (final c in near(pointBF, probeRadiusM))
          ?c.probe(pointBF, probeRadiusM: probeRadiusM),
      ];

  /// Cells at [level] covering a spherical cap of [angularRadius] about [dir].
  ///
  /// Sampled through [chunkAt] rather than walked by cell adjacency, which is
  /// the trick `TerrainEdits.chunksTouchedBy` uses and for the same reason: a
  /// direction is a direction, so the cube's seams and corners never enter into
  /// it. Over-covering costs a redundant distance test; under-covering would
  /// silently drop a collider, so the sampling errs generous.
  static Set<ChunkKey> _cellsNear(Vector3 dir, double angularRadius, int level) {
    if (level == 0 || angularRadius >= 0.5) return {...ChunkKey.roots};
    final out = <ChunkKey>{chunkAt(dir, level)};
    if (angularRadius <= 0) return out;

    final seed = dir.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
    final tangent = seed.cross(dir).normalized;
    final bitangent = dir.cross(tangent);
    // Two rings is enough because the cap is small next to a cell in every
    // realistic query; the inner ring catches cells the outer one steps over
    // when the cap is comparable to the cell.
    const rings = [1.0, 0.55];
    const samples = 12;
    for (final ring in rings) {
      final sin = math.sin(angularRadius * ring);
      final cos = math.cos(angularRadius * ring);
      for (var i = 0; i < samples; i++) {
        final phi = 2 * math.pi * i / samples;
        final offset =
            tangent * (math.cos(phi) * sin) + bitangent * (math.sin(phi) * sin);
        out.add(chunkAt((dir * cos + offset).normalized, level));
      }
    }
    return out;
  }
}
