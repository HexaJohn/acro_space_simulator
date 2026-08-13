// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Per-body terrain ARCHETYPES — Stage 2's declarative face.
///
/// A single `amplitude` scalar cannot express the difference between the Moon
/// and Europa, because the difference is not one of scale: one is a saturated
/// cratered highland, the other an almost crater-free ice shell covered in
/// ridge networks with a few hundred metres of global relief. What actually
/// distinguishes bodies is WHICH LANDFORM PROCESSES ran on them.
///
/// So a profile is a recipe: which [TerrainFeature]s a body gets, and how its
/// [TerrainControl] is shaped. Twelve bodies in the catalogue have no usable
/// topography and will never have any, so authoring them has to be a handful of
/// parameters rather than a painted map — this is the shape that makes that
/// true.
library;

import 'terrain_control.dart';
import 'terrain_feature.dart';
import 'crater_feature.dart';
import 'exotic_features.dart';

/// The landform vocabulary a body was built with.
enum TerrainArchetype {
  /// Ancient, saturated, airless rock: relief plus a full crater population.
  /// Moon, Mercury, Callisto, Ceres.
  crateredHighland,

  /// A world with weather. Eroded relief and mountain belts, few surviving
  /// craters — anything that hits gets worn away. Earth, Mars, Titan's bedrock.
  weathered,

  /// Young ice shell: near-zero crater record, tiny relief, dominated by
  /// anisotropic ridge networks. Europa, Enceladus.
  icyLineated,

  /// Wind-worked: dune seas over a gentle substrate. Titan.
  duneSea,

  /// Resurfaced faster than it cratered — high isolated relief, no crater
  /// record at all. Io.
  volcanic,

  /// Plain eroded relief, nothing characteristic. The safe default for a body
  /// nobody has authored yet.
  barren,
}

/// A body's terrain recipe: an archetype plus the few numbers that scale it.
class TerrainProfile {
  const TerrainProfile({
    this.archetype = TerrainArchetype.barren,
    this.regionScaleM = 400000,
    this.slopeDamping = 1.0,
    this.craterLargestRadiusM = 40000,
    this.craterDecades = 4,
    this.craterDensity = 0.55,
    this.lineationStrength = 1.0,
    this.lineaSpacingM = 25000,
    this.duneWavelengthM = 3000,
    this.duneHeightM = 120,
  });

  final TerrainArchetype archetype;

  /// Wavelength (m) of the control fields — how big a "province" is.
  final double regionScaleM;

  /// Erosion damping for the relief feature.
  final double slopeDamping;

  final double craterLargestRadiusM;
  final int craterDecades;
  final double craterDensity;

  /// How strongly directional this body's surface is, `0..1`.
  final double lineationStrength;
  final double lineaSpacingM;
  final double duneWavelengthM;
  final double duneHeightM;

  /// Serialise for the render snapshot.
  ///
  /// The renderer rebuilds `TerrainField` from the descriptor, so the recipe
  /// has to cross with it. Seed and amplitude are not enough — they scale the
  /// surface but the profile decides which features exist at all.
  Map<String, dynamic> toJson() => {
        'arch': archetype.index,
        'region': regionScaleM,
        'damp': slopeDamping,
        'cR': craterLargestRadiusM,
        'cD': craterDecades,
        'cN': craterDensity,
        'lin': lineationStrength,
        'linS': lineaSpacingM,
        'dW': duneWavelengthM,
        'dH': duneHeightM,
      };

  factory TerrainProfile.fromJson(Map<String, dynamic> j) {
    final ai = (j['arch'] as num?)?.toInt() ?? 0;
    return TerrainProfile(
      archetype: TerrainArchetype
          .values[ai.clamp(0, TerrainArchetype.values.length - 1)],
      regionScaleM: (j['region'] as num?)?.toDouble() ?? 400000,
      slopeDamping: (j['damp'] as num?)?.toDouble() ?? 1.0,
      craterLargestRadiusM: (j['cR'] as num?)?.toDouble() ?? 40000,
      craterDecades: (j['cD'] as num?)?.toInt() ?? 4,
      craterDensity: (j['cN'] as num?)?.toDouble() ?? 0.55,
      lineationStrength: (j['lin'] as num?)?.toDouble() ?? 1.0,
      lineaSpacingM: (j['linS'] as num?)?.toDouble() ?? 25000,
      duneWavelengthM: (j['dW'] as num?)?.toDouble() ?? 3000,
      duneHeightM: (j['dH'] as num?)?.toDouble() ?? 120,
    );
  }

  /// Whether this archetype uses anisotropic (directional) features at all.
  bool get _anisotropic =>
      archetype == TerrainArchetype.icyLineated ||
      archetype == TerrainArchetype.duneSea;

  /// Build the composed detail layer for a body.
  ///
  /// [amplitudeM] doubles as the control's relief SCALE, which keeps it an
  /// exact bound on the relief feature's output — the `+/- amplitude` contract
  /// the mesher's shell sizing and the collision raymarch both depend on.
  /// Features that can exceed it (craters dig below the local relief) declare
  /// that through [TerrainDetail.maxMagnitude] instead.
  TerrainDetail detailFor({
    required int seed,
    required double radiusM,
    required double amplitudeM,
    required double featureScaleM,
    int octaves = 6,
  }) {
    final control = SyntheticControl(
      seed: seed,
      radiusM: radiusM,
      reliefScaleM: amplitudeM,
      regionScaleM: regionScaleM,
      lineation: _anisotropic ? lineationStrength : 0.0,
      // A young ice shell is smooth almost everywhere; an ancient highland is
      // broken almost everywhere. Roughness gates crater retention, so this one
      // number also decides whether craters survive.
      roughnessFloor: switch (archetype) {
        TerrainArchetype.crateredHighland => 0.55,
        TerrainArchetype.icyLineated => 0.02,
        TerrainArchetype.volcanic => 0.05,
        _ => 0.15,
      },
    );

    final features = <TerrainFeature>[
      ErodedReliefFeature(
        seed: seed,
        radiusM: radiusM,
        featureScaleM: featureScaleM,
        octaves: octaves,
        slopeDamping: slopeDamping,
      ),
    ];

    switch (archetype) {
      case TerrainArchetype.crateredHighland:
        features.add(CraterFeature(
          seed: seed,
          radiusM: radiusM,
          largestRadiusM: craterLargestRadiusM,
          decades: craterDecades,
          density: craterDensity,
        ));
      case TerrainArchetype.weathered:
        // Weather erases craters, so only the largest survive and only faintly.
        features.add(CraterFeature(
          seed: seed,
          radiusM: radiusM,
          largestRadiusM: craterLargestRadiusM,
          decades: 2,
          density: craterDensity * 0.25,
        ));
      case TerrainArchetype.icyLineated:
        features.add(LineaFeature(
          seed: seed,
          radiusM: radiusM,
          spacingM: lineaSpacingM,
        ));
      case TerrainArchetype.duneSea:
        features.add(DuneFeature(
          seed: seed,
          radiusM: radiusM,
          wavelengthM: duneWavelengthM,
          heightM: duneHeightM,
        ));
      case TerrainArchetype.volcanic:
      case TerrainArchetype.barren:
        break; // relief alone
    }

    return TerrainDetail(features, control);
  }

  // ---- Presets -------------------------------------------------------------

  /// Ancient airless rock. The Moon, Mercury, Callisto.
  ///
  /// The largest PROCEDURAL crater is ~16 km across, right at the
  /// simple-to-complex break. Bigger than that is landmark territory —
  /// Tycho, Copernicus — which belongs to real elevation data, not to a noise
  /// field: those are places, and a hash cannot put them where they are. It
  /// also keeps total relief in proportion; asking for 80 km craters
  /// procedurally piled up to nearly five times the body's configured relief.
  static const moonlike = TerrainProfile(
    archetype: TerrainArchetype.crateredHighland,
    regionScaleM: 600000,
    slopeDamping: 0.6, // little erosion on an airless world
    craterLargestRadiusM: 8000,
  );

  /// A world with an atmosphere and running or blowing material.
  static const terrestrial = TerrainProfile(
    archetype: TerrainArchetype.weathered,
    regionScaleM: 900000,
    slopeDamping: 1.3,
    craterLargestRadiusM: 6000,
  );

  /// Young ice shell dominated by ridge networks.
  static const icyShell = TerrainProfile(
    archetype: TerrainArchetype.icyLineated,
    regionScaleM: 500000,
    slopeDamping: 0.3,
    lineaSpacingM: 25000,
  );

  /// Equatorial dune seas over gentle bedrock.
  static const duneWorld = TerrainProfile(
    archetype: TerrainArchetype.duneSea,
    regionScaleM: 700000,
    slopeDamping: 1.1,
  );

  /// Constantly resurfaced — tall isolated relief, no crater record.
  static const volcanicWorld = TerrainProfile(
    archetype: TerrainArchetype.volcanic,
    regionScaleM: 400000,
    slopeDamping: 0.4,
  );

  static const barren = TerrainProfile();
}
