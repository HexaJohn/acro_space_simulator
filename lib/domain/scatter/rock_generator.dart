// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/vector3.dart';
import '../terrain/noise3.dart';
import 'mesh_builder.dart';
import 'prop_imposter.dart';
import 'prop_mesh.dart';
import 'prop_model.dart';
import 'prop_random.dart';

/// Rock forms. Not a size ramp — each is a different *fracture* character, and
/// mixing them is what stops a scattered field reading as one shape rescaled.
enum RockSpecies {
  /// Rounded, weathered, wider than tall.
  boulder,

  /// Angular fractured stone, elongated, sharp-edged.
  shard,

  /// A flat plate lying on the ground.
  slab,

  /// A few smaller rocks sharing one base — a scree pile.
  cluster,
}

/// Recipe for one rock.
class RockParams {
  const RockParams({
    required this.species,
    required this.seed,
    required this.radiusM,
    required this.axisScale,
    required this.roughness,
    required this.noiseScale,
    required this.faceted,
    required this.sinkFraction,
  });

  final RockSpecies species;
  final int seed;

  /// Nominal radius (m) before [axisScale].
  final double radiusM;

  /// Per-axis squash, applied before the surface noise. Z is up.
  final Vector3 axisScale;

  /// Displacement depth, as a fraction of [radiusM]. 0 is a bare ellipsoid.
  final double roughness;

  /// Noise frequency over the unit sphere — high values give pitted stone, low
  /// values give a few big lobes.
  final double noiseScale;

  /// Flat-shade the faces. Angular stone needs it; a weathered boulder does not
  /// (and reads as a bad low-poly sphere with it).
  final bool faceted;

  /// How far into the ground the rock sits, as a fraction of its own height.
  /// The buried part is sheared flat rather than deleted, so the rock is closed
  /// and casts a correct shadow no matter what the ground under it does.
  final double sinkFraction;

  factory RockParams.of(
    RockSpecies species, {
    int seed = 1,
    double? radiusM,
  }) {
    switch (species) {
      case RockSpecies.boulder:
        return RockParams(
          species: species,
          seed: seed,
          radiusM: radiusM ?? 1.1,
          axisScale: const Vector3(1.0, 0.86, 0.72),
          roughness: 0.20,
          noiseScale: 1.7,
          faceted: false,
          sinkFraction: 0.22,
        );
      case RockSpecies.shard:
        return RockParams(
          species: species,
          seed: seed,
          radiusM: radiusM ?? 0.75,
          axisScale: const Vector3(0.55, 0.48, 1.35),
          roughness: 0.34,
          noiseScale: 1.1,
          faceted: true,
          sinkFraction: 0.16,
        );
      case RockSpecies.slab:
        return RockParams(
          species: species,
          seed: seed,
          radiusM: radiusM ?? 1.4,
          axisScale: const Vector3(1.15, 0.95, 0.24),
          roughness: 0.16,
          noiseScale: 2.1,
          faceted: true,
          sinkFraction: 0.30,
        );
      case RockSpecies.cluster:
        return RockParams(
          species: species,
          seed: seed,
          radiusM: radiusM ?? 0.95,
          axisScale: const Vector3(1.0, 0.9, 0.75),
          roughness: 0.24,
          noiseScale: 1.9,
          faceted: false,
          sinkFraction: 0.26,
        );
    }
  }

  RockParams copyWith({int? seed, double? radiusM}) => RockParams(
        species: species,
        seed: seed ?? this.seed,
        radiusM: radiusM ?? this.radiusM,
        axisScale: axisScale,
        roughness: roughness,
        noiseScale: noiseScale,
        faceted: faceted,
        sinkFraction: sinkFraction,
      );
}

/// Subdivision level per LOD. A rock is a closed blob, so unlike a tree it CAN
/// simply be rebuilt coarser: the geodesic at level n-1 samples the same
/// displacement field, so the silhouette survives even as the triangle count
/// drops fourfold.
const Map<PropLod, int> _subdivisionForLod = {
  PropLod.lod0: 3,
  PropLod.lod1: 2,
  PropLod.lod2: 1,
  PropLod.billboard: 0,
};

/// Build every LOD plus the imposter for one rock.
PropLodSet buildRockLodSet(RockParams params) {
  final build = _RockBuild(params, PropLod.lod0, withImposter: true);
  final model0 = build.run();
  final bounds = model0.bounds;
  return PropLodSet(
    levels: [
      model0,
      _RockBuild(params, PropLod.lod1).run(),
      _RockBuild(params, PropLod.lod2).run(),
    ],
    imposter: build.imposter!.build(
      widthM: math.max(bounds.radiusM * 2, 0.05),
      heightM: math.max(bounds.heightM, 0.05),
    ),
    bounds: bounds,
  );
}

/// Build one rock at one detail level.
PropModel buildRock(RockParams params, {PropLod lod = PropLod.lod0}) =>
    _RockBuild(params, lod).run();

class _RockBuild {
  _RockBuild(this.p, this.lod, {bool withImposter = false})
      : rnd = PropRandom(p.seed),
        // Seeded from the params so the same rock always has the same lumps —
        // and, crucially, the same lumps at EVERY LOD, which is what lets the
        // levels swap without the silhouette jumping.
        noise = ValueNoise3(p.seed * 2654435761 & 0x7fffffff),
        imposter = withImposter ? ImposterBuilder() : null;

  final RockParams p;
  final PropLod lod;
  final PropRandom rnd;
  final ValueNoise3 noise;
  final ImposterBuilder? imposter;
  final MeshBuilder b = MeshBuilder();

  int get subdivisions => _subdivisionForLod[lod]!;

  PropModel run() {
    if (p.species == RockSpecies.cluster) {
      _cluster();
    } else {
      _single(
        radiusM: p.radiusM,
        axisScale: p.axisScale,
        rnd: rnd,
        noiseOffset: 0.0,
      );
    }
    return PropModel(solid: b.build(), foliage: PropMesh.empty);
  }

  void _cluster() {
    // One dominant rock plus satellites; equal sizes read as marbles.
    final count = 3 + rnd.intBelow(3);
    for (var i = 0; i < count; i++) {
      final sub = rnd.fork(i);
      final scale = i == 0 ? 1.0 : sub.range(0.34, 0.62);
      final r = p.radiusM * scale;
      // Far enough out that the satellites read as separate stones. Closer in
      // they merge into the dominant rock and the cluster loses the broken-up
      // silhouette that is the entire reason for having it.
      final spread = p.radiusM * sub.range(0.85, 1.6);
      final angle = goldenAngle * i + sub.jitter(0.5);
      b.push();
      if (i > 0) {
        b.move(Vector3(
          math.cos(angle) * spread,
          math.sin(angle) * spread,
          0,
        ));
      }
      b.roll(sub.range(0, 2 * math.pi));
      _single(
        radiusM: r,
        axisScale: p.axisScale,
        rnd: sub,
        // Each satellite reads a different slice of the same noise field, so
        // they share a rock TYPE without being copies.
        noiseOffset: i * 13.7,
      );
      b.pop();
    }
  }

  void _single({
    required double radiusM,
    required Vector3 axisScale,
    required PropRandom rnd,
    required double noiseOffset,
  }) {
    // A little per-rock axis variation on top of the species' squash.
    final jx = rnd.range(0.85, 1.18),
        jy = rnd.range(0.85, 1.18),
        jz = rnd.range(0.88, 1.12);
    final axes = Vector3(
      axisScale.x * jx,
      axisScale.y * jy,
      axisScale.z * jz,
    );
    final halfHeight = radiusM * axes.z;
    final sink = halfHeight * 2.0 * p.sinkFraction;
    // Lift so the sheared-off base lands exactly on z = 0: props are placed by
    // their origin, and an origin floating inside the rock would bury or hover
    // every instance by a different amount.
    final centreZ = halfHeight - sink;

    b.push();
    b.move(Vector3(0, 0, centreZ));
    b.icosphere(
      radius: radiusM,
      subdivisions: subdivisions,
      axisScale: axes,
      displace: (dir) =>
          1.0 +
          p.roughness *
              (noise.fbm(
                    dir.x * p.noiseScale + noiseOffset,
                    dir.y * p.noiseScale + noiseOffset,
                    dir.z * p.noiseScale + noiseOffset,
                    octaves: 3,
                  ) *
                  2.0 -
                  1.0),
      warp: (v) => v.z < -centreZ ? Vector3(v.x, v.y, -centreZ) : v,
      faceted: p.faceted,
      // Tie texture density to world size so a pebble and a boulder show the
      // same grain rather than the same number of repeats.
      uScale: radiusM * 1.5,
    );
    b.pop();

    final at = b.toMesh(Vector3(0, 0, centreZ));
    imposter?.blob(
      x: at.x,
      y: at.y,
      z: at.z,
      radius: radiusM * math.max(axes.x, axes.y),
      ink: ImposterInk.rock,
    );
  }
}
