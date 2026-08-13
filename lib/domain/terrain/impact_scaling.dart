// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Turning an impact's kinetic energy into crater dimensions.
///
/// Pure reference math with no dependency on the rest of the terrain stack, so
/// the sizing law can be tuned and tested on its own.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';
import 'terrain_brush.dart';

/// The dimensions of a fresh simple crater (m).
class ImpactCrater {
  const ImpactCrater({
    required this.rimRadiusM,
    required this.depthM,
    required this.rimHeightM,
  });

  /// Radius of the rim crest — half the quoted crater "diameter".
  final double rimRadiusM;

  /// Bowl floor below the original surface.
  final double depthM;

  /// Rim crest above the original surface.
  final double rimHeightM;

  double get diameterM => rimRadiusM * 2;
}

/// Crater dimensions for an impact delivering [kineticEnergyJ] into a surface
/// with gravity [surfaceGravityMs2] and bulk density [targetDensityKgM3].
///
/// ## The law
///
/// Gravity-regime energy scaling, `D = k · (E / (ρ·g))^(1/4)`. The grouping
/// `E/(ρg)` has units of m⁴, so the quarter power is the dimensionally exact
/// one and [scalingCoefficient] is a true dimensionless constant rather than a
/// fudge carrying hidden units.
///
/// Full π-group scaling (Holsapple) puts the real exponent between about 0.22
/// and 0.29 depending on target strength and impact angle; 0.25 sits inside
/// that range and keeps the algebra honest. [scalingCoefficient] defaults to a
/// value calibrated against the Apollo S-IVB and LM ascent-stage lunar impacts
/// — roughly 4.6e10 J into regolith producing a ~30 m crater.
///
/// Returns null when the result would be smaller than [minRimRadiusM]: a crater
/// below the finest voxel any chunk will ever use is invisible geometry that
/// still costs a permanent entry in the edit list.
ImpactCrater? craterForImpact({
  required double kineticEnergyJ,
  required double surfaceGravityMs2,
  double targetDensityKgM3 = 1500,
  double scalingCoefficient = 0.5,
  double minRimRadiusM = 0.4,
  double maxRimRadiusM = 5000,
}) {
  if (!kineticEnergyJ.isFinite || kineticEnergyJ <= 0) return null;
  if (surfaceGravityMs2 <= 0 || targetDensityKgM3 <= 0) return null;

  final group = kineticEnergyJ / (targetDensityKgM3 * surfaceGravityMs2);
  final diameter = scalingCoefficient * math.pow(group, 0.25).toDouble();
  final rimRadius = (diameter * 0.5).clamp(0.0, maxRimRadiusM);
  if (rimRadius < minRimRadiusM) return null;

  // Fresh simple craters run about 1:5 depth-to-diameter, with a rim standing
  // ~4% of the diameter proud of the surrounding surface.
  return ImpactCrater(
    rimRadiusM: rimRadius,
    depthM: rimRadius * 2 * 0.2,
    rimHeightM: rimRadius * 2 * 0.04,
  );
}

/// Kinetic energy (J) of a body of [massKg] moving at [speedMs].
double kineticEnergy(double massKg, double speedMs) =>
    0.5 * massKg * speedMs * speedMs;

/// The crater brush a hard impact leaves, or null when the impact is too small
/// to be worth recording.
///
/// [contactBF] is the body-fixed contact point on the surface and [normalBF]
/// the outward surface normal there — for a body-radial descent onto a
/// height-field surface that is simply `contactBF.normalized`.
TerrainBrush? impactBrush({
  required Vector3 contactBF,
  required Vector3 normalBF,
  required double kineticEnergyJ,
  required double surfaceGravityMs2,
  double targetDensityKgM3 = 1500,
  double scalingCoefficient = 0.5,
  double minRimRadiusM = 0.4,
  double maxRimRadiusM = 5000,
  int tick = 0,
}) {
  final c = craterForImpact(
    kineticEnergyJ: kineticEnergyJ,
    surfaceGravityMs2: surfaceGravityMs2,
    targetDensityKgM3: targetDensityKgM3,
    scalingCoefficient: scalingCoefficient,
    minRimRadiusM: minRimRadiusM,
    maxRimRadiusM: maxRimRadiusM,
  );
  if (c == null) return null;
  return TerrainBrush.crater(
    contactBF: contactBF,
    normalBF: normalBF,
    radiusM: c.rimRadiusM,
    depthM: c.depthM,
    rimHeightM: c.rimHeightM,
    tick: tick,
  );
}
