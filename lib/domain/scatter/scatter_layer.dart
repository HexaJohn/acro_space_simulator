// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../planetary/planet_surface.dart';
import 'prop_catalog.dart';

/// A population of one or more prop kinds sharing a density and a set of
/// habitat gates — "grass on temperate lowland", "boulders on any slope".
///
/// ## Why layers own a chunk LEVEL
///
/// Scatter is generated per cubed-sphere cell, and cell area falls by four with
/// every level. Generating grass at the level trees use would mean hundreds of
/// thousands of tufts in one cell; generating trees at the level grass uses
/// would mean a cell holds a fraction of a tree, so most cells hold none and
/// the forest comes out in clumps of one. A layer therefore picks the level
/// whose cell area, at its own density, yields a sane per-cell count — see
/// [levelFor] — and is generated at that level only.
class ScatterLayer {
  const ScatterLayer({
    required this.name,
    required this.kinds,
    required this.densityPerKm2,
    required this.minSlopeCos,
    this.biomeWeights = const {},
    this.requiresVegetation = false,
    this.scaleRange = (0.75, 1.35),
    this.maxAltitudeM = double.infinity,
    required this.viewDistanceM,
  });

  /// Label for debugging and the preview HUD.
  final String name;

  /// Kinds drawn from uniformly. Mixing related kinds in one layer is what
  /// stops a forest being one tree repeated.
  final List<PropKind> kinds;

  /// Individuals per square kilometre at full habitat suitability.
  final double densityPerKm2;

  /// Steepest ground this layer tolerates, as the cosine of the angle between
  /// the surface normal and straight up. 1.0 is flat; 0.7 is a 45-degree slope.
  ///
  /// A cosine rather than an angle because the test is then a dot product with
  /// no trigonometry — and this runs per candidate, of which a planet has
  /// rather a lot.
  final double minSlopeCos;

  /// Per-biome multipliers. A biome absent from the map scores 0, so a layer
  /// only appears where it is explicitly wanted.
  final Map<Biome, double> biomeWeights;

  /// Gate on the body actually supporting plant life. Rock layers leave this
  /// false and so scatter on airless worlds too.
  final bool requiresVegetation;

  /// Size multiplier range.
  final (double, double) scaleRange;

  /// Height above the datum (m) beyond which this layer stops — a tree line.
  final double maxAltitudeM;

  /// How far from the viewer this layer is drawn at all (m).
  ///
  /// This, not the cell size, is what bounds the instance count: a layer covers
  /// `pi * viewDistance^2 * density` props no matter how the cells are diced,
  /// so it is the one number to reach for when a field costs too much. Grass
  /// stops at conversational range because a tuft is a few pixels beyond it and
  /// the terrain's own material already reads as ground cover; trees carry much
  /// further because a treeline is a landmark.
  final double viewDistanceM;

  /// Candidates per cell to aim for when choosing a generation level.
  ///
  /// Low enough that one cell's worth of props fits comfortably inside an
  /// instanced draw's transform budget, high enough that the per-cell fixed
  /// costs (hashing, the field samples, the buffer swap) are amortised.
  static const int targetPerCell = 160;

  /// The cubed-sphere level this layer generates at, on a body of [radiusM].
  ///
  /// A level-`L` sphere has `6 * 4^L` cells, so cell area is
  /// `4*pi*R^2 / (6 * 4^L)`. Solving `cellArea * density == targetPerCell` for
  /// `L` gives the level below; rounding it is harmless because the actual
  /// candidate count is computed from the cell's true area, not from the
  /// target, so density stays honest either way.
  int levelFor(double radiusM, {int maxLevel = 22}) {
    final perM2 = densityPerKm2 / 1e6;
    if (perM2 <= 0) return 0;
    final want = 4.0 * math.pi * radiusM * radiusM * perM2 / (6.0 * targetPerCell);
    if (want <= 1.0) return 0;
    return (math.log(want) / math.log(4)).round().clamp(0, maxLevel);
  }

  /// Habitat suitability at a point, 0 (absent) to 1 (ideal).
  double suitability({
    required Biome biome,
    required double slopeCos,
    required double altitudeM,
    required double vegetationCap,
  }) {
    if (slopeCos < minSlopeCos) return 0.0;
    if (altitudeM > maxAltitudeM) return 0.0;
    final biomeWeight = biomeWeights[biome] ?? 0.0;
    if (biomeWeight <= 0.0) return 0.0;
    final veg = requiresVegetation ? vegetationCap : 1.0;
    if (veg <= 0.0) return 0.0;
    // Ease off toward the steepest tolerated slope instead of stopping dead at
    // it, so a hillside thins out rather than ending on a contour line.
    final slopeEase =
        ((slopeCos - minSlopeCos) / math.max(1.0 - minSlopeCos, 1e-6))
            .clamp(0.0, 1.0);
    return biomeWeight * veg * (0.35 + 0.65 * slopeEase);
  }
}

/// The default layer set. Deliberately small — the point is a working pipeline
/// end to end, not a complete ecology; adding a layer is one entry.
class ScatterLayers {
  ScatterLayers._();

  static const forest = ScatterLayer(
    name: 'forest',
    kinds: [PropKind.broadleafTree, PropKind.coniferTree, PropKind.deadSnag],
    densityPerKm2: 9000,
    minSlopeCos: 0.72, // up to ~44 degrees
    requiresVegetation: true,
    biomeWeights: {
      Biome.forest: 1.0,
      Biome.wetland: 0.55,
      Biome.grassland: 0.22,
      Biome.mountains: 0.30,
      Biome.tundra: 0.10,
      Biome.coastal: 0.30,
    },
    maxAltitudeM: 2600, // tree line
    viewDistanceM: 900,
  );

  static const palms = ScatterLayer(
    name: 'palms',
    kinds: [PropKind.palmTree],
    densityPerKm2: 2200,
    minSlopeCos: 0.88,
    requiresVegetation: true,
    biomeWeights: {Biome.coastal: 1.0, Biome.desert: 0.12},
    viewDistanceM: 700,
  );

  static const groundCover = ScatterLayer(
    name: 'ground cover',
    kinds: [PropKind.grassTuft, PropKind.fern, PropKind.shrub],
    // Ground cover is the layer that sells a surface, and it is also the one
    // that will dominate the instance budget; this is the number to tune first
    // once it is on screen.
    densityPerKm2: 900000,
    minSlopeCos: 0.62,
    requiresVegetation: true,
    scaleRange: (0.6, 1.5),
    biomeWeights: {
      Biome.grassland: 1.0,
      Biome.forest: 0.7,
      Biome.wetland: 0.85,
      Biome.tundra: 0.35,
      Biome.coastal: 0.5,
      Biome.mountains: 0.2,
    },
    viewDistanceM: 70,
  );

  static const reeds = ScatterLayer(
    name: 'reeds',
    kinds: [PropKind.reeds],
    densityPerKm2: 180000,
    minSlopeCos: 0.95, // only near-flat ground holds standing water
    requiresVegetation: true,
    biomeWeights: {Biome.wetland: 1.0, Biome.coastal: 0.4},
    viewDistanceM: 120,
  );

  /// Rock does NOT require vegetation, so it is the layer that populates the
  /// Moon and Mars — the bodies most likely to be landed on.
  static const rocks = ScatterLayer(
    name: 'rocks',
    kinds: [
      PropKind.boulder,
      PropKind.rockShard,
      PropKind.rockSlab,
      PropKind.rockCluster,
    ],
    densityPerKm2: 24000,
    minSlopeCos: 0.55,
    scaleRange: (0.45, 1.9),
    biomeWeights: {
      Biome.barren: 1.0,
      Biome.mountains: 0.9,
      Biome.desert: 0.55,
      Biome.volcanic: 0.7,
      Biome.tundra: 0.4,
      Biome.iceCap: 0.15,
      Biome.grassland: 0.12,
      Biome.forest: 0.12,
      Biome.coastal: 0.2,
      Biome.wetland: 0.05,
      Biome.volcano: 0.3,
    },
    viewDistanceM: 450,
  );

  static const List<ScatterLayer> all = [
    forest,
    palms,
    groundCover,
    reeds,
    rocks,
  ];
}
