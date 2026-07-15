// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../terrain/terrain_field.dart';

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

  /// Build the sampler for a body of the given datum [radius] (m).
  TerrainField fieldFor(double radius) => TerrainField(
        radius: radius,
        amplitude: amplitude,
        featureScale: featureScale,
        seaLevel: seaLevel,
        seed: seed,
        octaves: octaves,
      );
}
