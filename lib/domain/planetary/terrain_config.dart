// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../terrain/dem_pyramid.dart';
import '../terrain/dem_registry.dart';
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
    this.ambient,
    this.erodedDetail = false,
    this.profile,
    this.demBodyId,
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

  /// Night-side ambient floor (0..1): the fraction of full sun the surface
  /// keeps where the sun term is zero. Null derives it from the atmosphere —
  /// sky scatter on atmospheric bodies, earthshine-scale on airless ones —
  /// so set it only where a body needs a hand-tuned look.
  final double? ambient;

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

  /// Body id of a baked DEM (`assets/terrain/<id>.acrodem`) that REPLACES the
  /// procedural base relief. Null = fully procedural.
  ///
  /// The pyramid itself lives in [DemRegistry] — this config is `const`
  /// catalogue data and cannot hold a decoded map. Declaring an id makes
  /// registration mandatory: [fieldFor] throws if the pyramid was never
  /// loaded, because a silent procedural fallback would put this peer's
  /// ground somewhere the server's is not.
  final String? demBodyId;

  /// Build the sampler for a body of the given datum [radius] (m), optionally
  /// composing that body's accumulated deformations on top of the relief.
  TerrainField fieldFor(double radius, {TerrainEdits? edits}) {
    final dem = demBodyId == null ? null : DemRegistry.require(demBodyId!);
    return TerrainField(
      radius: radius,
      amplitude: amplitude,
      featureScale: featureScale,
      seaLevel: seaLevel,
      seed: seed,
      octaves: octaves,
      edits: edits,
      dem: dem,
      detail: erodedDetail ? detailFor(radius, dem: dem) : null,
    );
  }

  /// The composed detail layer for this body, assembled by its [profile].
  ///
  /// [amplitude] doubles as the control field's relief SCALE, which keeps it an
  /// exact bound on the RELIEF feature's output — the `[-amplitude, +amplitude]`
  /// contract the mesher's shell sizing and the collision raymarch depend on.
  /// Features that legitimately exceed it (a crater digs below the local
  /// relief) declare that through `TerrainDetail.maxMagnitude`.
  ///
  /// With a [dem], the detail rides a [DemDerivedControl] instead: the same
  /// feature stack, steered and bounded by the DEM's own local relief.
  TerrainDetail detailFor(double radius, {DemPyramid? dem}) =>
      (profile ?? TerrainProfile.barren).detailFor(
        seed: seed,
        radiusM: radius,
        amplitudeM: amplitude,
        featureScaleM: featureScale,
        octaves: octaves + 1,
        control: dem == null ? null : DemDerivedControl(dem),
      );
}
