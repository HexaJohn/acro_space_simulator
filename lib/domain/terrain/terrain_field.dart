// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'noise3.dart';

/// The deterministic terrain field for one body, in the body-centred Z-up
/// frame (metres). Pure and seeded: **the collision code and the render mesher
/// sample the same field**, so the ground you land on is the ground you see.
///
/// [density] is a signed scalar — **negative = inside solid, positive = air,
/// isosurface at 0** — the exact contract the Surface Nets mesher expects.
/// The API takes a full 3D position (not a lat/lon height), so caves and
/// overhangs are representable: the foundation's relief is a direction-based
/// height field (smooth terrain), and a 3D cave term can be subtracted later
/// without changing any caller.
class TerrainField {
  TerrainField({
    required this.radius,
    required this.amplitude,
    required this.featureScale,
    this.seaLevel = 0,
    required int seed,
    this.octaves = 5,
  }) : _noise = ValueNoise3(seed);

  /// Datum radius (m) — the mean surface; relief rides on top of this.
  final double radius;

  /// Peak relief either side of the datum (m). Surface height is `[-amplitude,
  /// +amplitude]` (fBm re-centred).
  final double amplitude;

  /// World wavelength (m) of the largest terrain feature; smaller detail comes
  /// from the fBm octaves. Independent of [radius].
  final double featureScale;

  /// Sea level as metres above the datum (used by the ocean shell + shading,
  /// not by the solid surface — the field dips below it for the ocean floor).
  final double seaLevel;

  final int octaves;
  final ValueNoise3 _noise;

  /// Terrain surface height above the datum along a unit direction (m), in
  /// `[-amplitude, +amplitude]`.
  double heightInDirection(double dx, double dy, double dz) {
    final n = directionFbm(_noise, dx, dy, dz, radius, featureScale,
        octaves: octaves);
    return (n * 2.0 - 1.0) * amplitude;
  }

  /// Signed density at a body-frame position (negative = solid). For the
  /// foundation this is a height field: `|p| - (radius + height(dir))`.
  /// (A future cave term would add a positive 3D noise lobe here to carve air.)
  double density(double x, double y, double z) {
    final r = math.sqrt(x * x + y * y + z * z);
    if (r < 1e-6) return -radius; // planet centre is deep solid
    final inv = 1.0 / r;
    final h = heightInDirection(x * inv, y * inv, z * inv);
    return r - (radius + h);
  }

  /// The outermost solid-surface radius along a direction (m) — what a lander
  /// rests on. Exact for the height-field foundation; when caves/overhangs are
  /// added this becomes the outermost zero-crossing of a radial raymarch.
  double groundRadiusAt(double dx, double dy, double dz) {
    final r = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (r < 1e-9) return radius;
    final inv = 1.0 / r;
    return radius + heightInDirection(dx * inv, dy * inv, dz * inv);
  }

  double get seaRadius => radius + seaLevel;
}
