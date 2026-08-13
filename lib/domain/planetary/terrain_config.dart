// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../terrain/terrain_edits.dart';
import '../terrain/terrain_feature.dart';
import '../terrain/terrain_field.dart';
import '../terrain/terrain_profile.dart';

/// Per-body voxel-terrain parameters — immutable reference data alongside
/// [CelestialBody.surface]/`atmosphere`. Deterministic: the [seed] fully
/// determines the relief, so collision and the renderer agree.
///
/// Non-deformable foundation: relief only (no edit deltas yet). Cave/overhang
/// content is a later addition to [TerrainField]; the config gains cave params
/// then without touching callers.
class TerrainConfig {
  const TerrainConfig({
    required this.seed,
    required this.amplitude,
    required this.featureScale,
    this.seaLevel = 0,
    this.octaves = 5,
    this.grassAmount = 0,
    this.sandAmount = 0,
    this.erodedDetail = false,
    this.profile,
  });

  /// Noise seed (independent of [PlanetSurface.seed], which drives biomes).
  final int seed;

  /// Peak relief either side of the datum radius (m).
  final double amplitude;

  /// World wavelength (m) of the largest terrain feature.
  final double featureScale;

  /// Sea level as metres above the datum radius (0 = at the datum).
  final double seaLevel;

  /// fBm octaves (detail layers).
  final int octaves;

  /// Vegetation cover (0 = barren/regolith, 1 = fully vegetated). The renderer
  /// blends grass into temperate lowlands up to this cap; 0 on airless bodies.
  final double grassAmount;

  /// Desert/sand cover (0..1). Blended into hot, low, dry latitudes up to this
  /// cap; 0 on airless bodies.
  final double sandAmount;

  /// Opt in to the erosion-aware detail layer (control fields + composable
  /// features) instead of the original single-fBm relief.
  ///
  /// Off by default, and migrated per body rather than flipped globally:
  /// turning it on gives the SAME SEED different ground, so anything anchored
  /// to the old surface — spawn presets, placed colonies, landed craft in a
  /// save — moves with it.
  final bool erodedDetail;

  /// Which landform vocabulary this body was built with. Null falls back to
  /// [TerrainProfile.barren] — plain eroded relief and nothing characteristic.
  final TerrainProfile? profile;

  /// Build the sampler for a body of the given datum [radius] (m), optionally
  /// composing that body's accumulated deformations on top of the relief.
  TerrainField fieldFor(double radius, {TerrainEdits? edits}) => TerrainField(
        radius: radius,
        amplitude: amplitude,
        featureScale: featureScale,
        seaLevel: seaLevel,
        seed: seed,
        octaves: octaves,
        edits: edits,
        detail: erodedDetail ? detailFor(radius) : null,
      );

  /// The composed detail layer for this body, assembled by its [profile].
  ///
  /// [amplitude] doubles as the control field's relief SCALE, which keeps it an
  /// exact bound on the RELIEF feature's output — the `[-amplitude, +amplitude]`
  /// contract the mesher's shell sizing and the collision raymarch depend on.
  /// Features that legitimately exceed it (a crater digs below the local
  /// relief) declare that through `TerrainDetail.maxMagnitude`.
  TerrainDetail detailFor(double radius) =>
      (profile ?? TerrainProfile.barren).detailFor(
        seed: seed,
        radiusM: radius,
        amplitudeM: amplitude,
        featureScaleM: featureScale,
        octaves: octaves + 1,
      );
}
