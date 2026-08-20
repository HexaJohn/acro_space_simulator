// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The PHYSICAL shape of a halo-ring megastructure: a spun habitat band whose
/// inner surface carries voxel terrain.
///
/// Planets get their solidity from `TerrainField`, which models a FILLED BALL —
/// density is `|p| - (radius + h(dir))`, one ground radius per direction from
/// the centre. A ring is hollow: most directions from its centre hit nothing,
/// and the directions that do hit occupy a thin radial BAND, with the walkable
/// surface on the INSIDE (spin gravity presses outward, so "down" is away from
/// the spin axis). Rather than contort the planetary field, the ring gets its
/// own field in its own natural coordinates:
///
///   * cylindrical about the spin axis (+Z, ring body-fixed frame)
///   * terrain is a single-valued height field h(phi, z) on the floor datum
///     cylinder — exactly the planetary trick, rotated: "radial from centre"
///     becomes "radial from axis", and relief RAISES the floor toward the axis
///   * [TerrainEdits] compose on top as arbitrary 3D CSG, same convention as
///     planets (positive density = air, negative = solid, metres near the
///     surface), so mining brushes carve the ring the same way they carve an
///     asteroid.
///
/// Everything here is pure and deterministic (same spec + seed => same field),
/// so collision and render meshing can sample it independently and agree.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';
import '../terrain/noise3.dart';
import '../terrain/terrain_edits.dart';

/// Standard gravity the default spin rate targets at the terrain floor.
const double haloRingTargetGravity = 9.80665;

/// Geometry + terrain recipe for one halo ring. Immutable; the id/economy side
/// lives on `Megastructure`, which carries one of these for physical builds.
class HaloRingSpec {
  const HaloRingSpec({
    required this.radiusM,
    this.bandWidthM = 1.0e4,
    this.shellThicknessM = 300,
    this.wallHeightM = 1500,
    this.wallThicknessM = 200,
    this.terrainAmplitudeM = 60,
    this.terrainFeatureScaleM = 4000,
    this.terrainOctaves = 4,
    this.seed = 7,
    this.spinPeriodOverrideS = 0,
  });

  /// Cylindrical radius of the terrain floor DATUM (m) — the ring's defining
  /// dimension. Terrain relief and the structural shell hang off this.
  final double radiusM;

  /// Full width of the band along the spin axis (m).
  final double bandWidthM;

  /// Solid structure below the floor datum (m): regolith bed + hull. Mining
  /// can dig this deep before holing the ring.
  final double shellThicknessM;

  /// Rim walls rise this far above the floor datum toward the axis (m). They
  /// are what would hold an atmosphere in; terrain feathers to zero at their
  /// feet.
  final double wallHeightM;

  /// Radial thickness of each rim wall along the spin axis (m).
  final double wallThicknessM;

  /// Peak terrain relief either side of the floor datum (m).
  final double terrainAmplitudeM;

  /// World-space wavelength of the largest terrain feature (m).
  final double terrainFeatureScaleM;

  /// fBm octaves for the terrain height field.
  final int terrainOctaves;

  /// Noise seed — the whole surface is deterministic from this.
  final int seed;

  /// Explicit spin period (s); 0 derives the period that yields ~1 g of spin
  /// gravity at the floor datum.
  final double spinPeriodOverrideS;

  double get halfWidthM => bandWidthM / 2;

  /// Lateral half-extent of the terrain floor, wall feet excluded.
  double get interiorHalfWidthM => halfWidthM - wallThicknessM;

  /// Spin period (s). Defaults to the ~1 g period: omega = sqrt(g/R).
  double get spinPeriodS => spinPeriodOverrideS > 0
      ? spinPeriodOverrideS
      : 2 * math.pi * math.sqrt(radiusM / haloRingTargetGravity);

  /// Spin rate (rad/s) about the ring's +Z axis.
  double get spinAngularVelocity => 2 * math.pi / spinPeriodS;

  /// Centrifugal "surface gravity" at the floor datum (m/s^2).
  double get spinGravityMs2 =>
      spinAngularVelocity * spinAngularVelocity * radiusM;

  /// Outermost solid extent from the axis (m) — hull outer skin.
  double get outerRadiusM => radiusM + shellThicknessM;

  /// Innermost solid extent from the axis (m) — the wall crests.
  double get crestRadiusM => radiusM - wallHeightM;

  HaloRingField field({TerrainEdits? edits}) =>
      HaloRingField(this, edits: edits);
}

/// Signed solidity field for a halo ring in its body-fixed frame (spin axis
/// +Z, origin at ring centre). Convention matches `TerrainField`: negative =
/// inside solid, positive = air, isosurface at 0, magnitude ~metres near the
/// surface.
class HaloRingField {
  HaloRingField(this.spec, {TerrainEdits? edits})
      : _edits = edits,
        _noise = ValueNoise3(spec.seed);

  final HaloRingSpec spec;
  final TerrainEdits? _edits;
  final ValueNoise3 _noise;

  TerrainEdits? get edits => _edits;

  /// The same field with a different edit store composed on top. The base
  /// noise object is rebuilt (cheap — it is just a seed).
  HaloRingField withEdits(TerrainEdits? edits) =>
      HaloRingField(spec, edits: edits);

  /// Width of the feather band where terrain relief fades to zero before the
  /// rim wall feet, so hills never intersect the walls.
  static const double _featherM = 400;

  /// Terrain relief (m) above the floor datum at band coordinates
  /// ([phi] around the ring, [z] along the spin axis). Positive = toward the
  /// axis ("up" under spin gravity). Single-valued by construction — the
  /// planetary height-field trick in ring coordinates.
  double heightAt(double phi, double z) {
    final fs = spec.terrainFeatureScaleM;
    // Sample on the datum cylinder so the noise is seamless around the ring —
    // a (phi, z) parameterisation would need explicit wrap handling; the
    // embedded 3D point wraps for free.
    final px = math.cos(phi) * spec.radiusM / fs;
    final py = math.sin(phi) * spec.radiusM / fs;
    final pz = z / fs;
    final n = _noise.fbm(px, py, pz, octaves: spec.terrainOctaves);
    var h = (n * 2 - 1) * spec.terrainAmplitudeM;
    // Feather to the flat datum approaching the wall feet.
    final d = spec.interiorHalfWidthM - z.abs();
    if (d <= 0) return 0;
    if (d < _featherM) {
      final t = d / _featherM;
      h *= t * t * (3 - 2 * t);
    }
    return h;
  }

  /// Cylindrical radius of the terrain floor at ([phi], [z]) — base field
  /// only, edits excluded. Relief raises the floor TOWARD the axis, so hills
  /// have a smaller radius than valleys.
  double floorRadiusAt(double phi, double z) =>
      spec.radiusM - heightAt(phi, z);

  /// The body-fixed point on the terrain floor at ([phi], [z]).
  Vector3 surfacePointAt(double phi, double z) {
    final rho = floorRadiusAt(phi, z);
    return Vector3(math.cos(phi) * rho, math.sin(phi) * rho, z);
  }

  /// Pristine solidity, edits excluded. A max/min-of-parts SDF approximation:
  /// exact metres along each face's own normal, approximate at corners — the
  /// same fidelity class the planetary field provides, and all Surface Nets
  /// needs.
  double baseDensity(double x, double y, double z) {
    final rho = math.sqrt(x * x + y * y);
    final az = z.abs();
    // Shared bounds: nothing is solid beyond the hull skin or the band edge.
    final dOuter = rho - spec.outerRadiusM;
    final dAxial = az - spec.halfWidthM;
    // Terrain band: solid from the (relief-raised) floor out to the hull.
    final phi = math.atan2(y, x);
    final dFloor = (spec.radiusM - heightAt(phi, z)) - rho;
    final band = math.max(dFloor, math.max(dOuter, dAxial));
    // Rim walls: solid from the crest out to the hull, wall-thickness deep in
    // z. Union with the band closes the ring's U-shaped cross-section.
    final dCrest = spec.crestRadiusM - rho;
    final dInboard = (spec.halfWidthM - spec.wallThicknessM) - az;
    final wall =
        math.max(math.max(dCrest, dOuter), math.max(dAxial, dInboard));
    return math.min(band, wall);
  }

  /// Solidity with terrain edits composed on top (ordered CSG, identical
  /// convention to the planetary field). This is what meshing and future
  /// mining/collision must sample.
  double density(double x, double y, double z) {
    final base = baseDensity(x, y, z);
    final e = _edits;
    if (e == null || e.isEmpty) return base;
    return e.apply(base, Vector3(x, y, z));
  }
}

/// The visible construction stages of a halo ring, in build order. Derived
/// from `Megastructure.completedPhases`, so economy progress IS the geometry:
///
///  * [skeleton]  — phase 1 building: truss arcs reach around the circle
///  * [hull]      — phase 2 building: the closed band skins over the truss
///  * [terraform] — phase 3 building: terrain pours onto the inner surface
///  * [habitable] — phase 4 building/complete: habitat lights come on
enum HaloRingStage { skeleton, hull, terraform, habitable }

/// Snapshot of build progress translated into per-layer geometry coverage.
/// Coverage is an arc fraction 0..1 measured from phi = 0; a layer under
/// construction grows around the ring as its phase fills.
class HaloRingBuildState {
  const HaloRingBuildState._(this.stage, this.stageFraction);

  factory HaloRingBuildState.of(int completedPhases, double currentFraction) {
    final idx = completedPhases.clamp(0, HaloRingStage.values.length - 1);
    final done = completedPhases >= HaloRingStage.values.length;
    return HaloRingBuildState._(
      HaloRingStage.values[idx],
      done ? 1.0 : currentFraction.clamp(0.0, 1.0),
    );
  }

  final HaloRingStage stage;

  /// Progress 0..1 of the CURRENT stage (1.0 once the whole build completes).
  final double stageFraction;

  double _arcFor(HaloRingStage layer) {
    if (stage.index > layer.index) return 1;
    if (stage.index < layer.index) return 0;
    return stageFraction;
  }

  /// Truss skeleton arc coverage 0..1.
  double get trussArc => _arcFor(HaloRingStage.skeleton);

  /// Closed hull band arc coverage 0..1.
  double get hullArc => _arcFor(HaloRingStage.hull);

  /// Terrain arc coverage 0..1 (both the far strip and voxel chunks).
  double get terrainArc => _arcFor(HaloRingStage.terraform);

  /// Habitat lighting level 0..1.
  double get lightsLevel => _arcFor(HaloRingStage.habitable);
}
