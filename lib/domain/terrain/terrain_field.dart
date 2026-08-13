// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/vector3.dart';
import 'dem_pyramid.dart';
import 'noise3.dart';
import 'terrain_edits.dart';
import 'terrain_feature.dart';

/// The deterministic terrain field for one body, in the body-centred Z-up
/// frame (metres). Pure and seeded: **the collision code and the render mesher
/// sample the same field**, so the ground you land on is the ground you see.
///
/// [density] is a signed scalar — **negative = inside solid, positive = air,
/// isosurface at 0** — the exact contract the Surface Nets mesher expects.
/// The API takes a full 3D position (not a lat/lon height), so caves and
/// overhangs are representable: the foundation's relief is a direction-based
/// height field (smooth terrain), on top of which [edits] compose arbitrary 3D
/// CSG.
///
/// ## Base vs. edited
///
/// The BASE relief is a pure height field, so `baseGroundRadiusAt` is exact and
/// costs one fBm evaluation. [edits] break that guarantee — a subtracted bowl
/// can put several zero crossings on one radial — so [groundRadiusAt] falls
/// back to a raymarch, but only for rays that actually pass through an edit.
/// Everywhere else, which is essentially the whole planet, it stays analytic.
class TerrainField {
  TerrainField({
    required this.radius,
    required double amplitude,
    required this.featureScale,
    this.seaLevel = 0,
    required int seed,
    this.octaves = 5,
    this.edits,
    this.detail,
    DemPyramid? dem,
  })  : dem = dem,
        // With a DEM the height bound is the DEM's own span, not the config
        // scalar: the map decides the relief. The detail layer's ceiling is
        // its declared maxMagnitude at the largest control relief a
        // DemDerivedControl can report (detailFraction of the full elevation
        // span) — craters contribute absolute metres there, so a flat factor
        // would under-bound and clip terrain.
        amplitude = dem == null
            ? amplitude
            : math.max(dem.maxElevM.abs(), dem.minElevM.abs()) +
                (detail?.maxMagnitude((dem.maxElevM - dem.minElevM) *
                        DemDerivedControl.defaultDetailFraction) ??
                    0.0),
        _noise = ValueNoise3(seed);

  /// Datum radius (m) — the mean surface; relief rides on top of this.
  final double radius;

  /// Peak relief either side of the datum (m). Base surface height is
  /// `[-amplitude, +amplitude]` (fBm re-centred); [edits] may exceed it.
  /// When [dem] is present this is DERIVED from the DEM's elevation span and
  /// the constructor argument is ignored — real data outranks the config.
  final double amplitude;

  /// Baked real elevation, or null for a fully procedural body. When present
  /// it IS the base relief: the fBm base is not evaluated at all, and the
  /// [detail] layer (riding a `DemDerivedControl`) only adds structure below
  /// the DEM's ~texel resolution.
  final DemPyramid? dem;

  /// World wavelength (m) of the largest terrain feature; smaller detail comes
  /// from the fBm octaves. Independent of [radius].
  final double featureScale;

  /// Sea level as metres above the datum (used by the ocean shell + shading,
  /// not by the solid surface — the field dips below it for the ocean floor).
  final double seaLevel;

  final int octaves;

  /// Deformations composed on top of the base relief, or null for a pristine
  /// body. Null rather than an empty store so the untouched path allocates
  /// nothing and branches once.
  final TerrainEdits? edits;

  /// The composed detail layer — control fields plus features. When null the
  /// field falls back to the original single-fBm relief.
  ///
  /// Null is still the default because switching a body over CHANGES ITS
  /// TERRAIN: every seed produces different ground, so anything pinned to the
  /// old surface (spawn sites, placed colonies, saved landings) moves. Bodies
  /// are migrated deliberately, one at a time, not by upgrading this file.
  final TerrainDetail? detail;

  final ValueNoise3 _noise;

  /// Terrain surface height above the datum along a unit direction (m).
  ///
  /// With a [detail] layer this is its composed output, bounded by the local
  /// relief the control field reports. Without one it is the original fBm
  /// relief in `[-amplitude, +amplitude]`.
  ///
  /// Base relief only either way — [edits] are 3D CSG, not a height offset,
  /// and cannot be expressed here.
  double heightInDirection(double dx, double dy, double dz) {
    final dm = dem;
    final d = detail;
    if (dm != null) {
      final real = dm.elevationAt(Vector3(dx, dy, dz));
      return d == null ? real : real + d.heightAt(Vector3(dx, dy, dz));
    }
    if (d != null) return d.heightAt(Vector3(dx, dy, dz));
    final n = directionFbm(_noise, dx, dy, dz, radius, featureScale,
        octaves: octaves);
    return (n * 2.0 - 1.0) * amplitude;
  }

  /// Signed density of the BASE relief at a body-frame position, ignoring
  /// [edits]: `|p| - (radius + height(dir))`.
  double baseDensity(double x, double y, double z) {
    final r = math.sqrt(x * x + y * y + z * z);
    if (r < 1e-6) return -radius; // planet centre is deep solid
    final inv = 1.0 / r;
    final h = heightInDirection(x * inv, y * inv, z * inv);
    return r - (radius + h);
  }

  /// Signed density at a body-frame position (negative = solid), base relief
  /// with every covering edit composed on top.
  double density(double x, double y, double z) {
    final base = baseDensity(x, y, z);
    final e = edits;
    if (e == null || e.isEmpty) return base;
    return e.apply(base, Vector3(x, y, z));
  }

  /// The base relief's surface radius along a direction (m) — exact, one fBm
  /// evaluation, and unaware of [edits].
  double baseGroundRadiusAt(double dx, double dy, double dz) {
    final r = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (r < 1e-9) return radius;
    final inv = 1.0 / r;
    return radius + heightInDirection(dx * inv, dy * inv, dz * inv);
  }

  /// The outermost solid-surface radius along a direction (m) — what a lander
  /// rests on.
  ///
  /// Exact and analytic wherever no edit straddles the ray. Where one does, the
  /// radial can have several zero crossings and this returns the OUTERMOST,
  /// found by marching the composed field and bisecting the bracket. That is
  /// the right answer for a craft descending onto deformed ground, and the
  /// wrong one for a craft already inside a tunnel or under an overhang — that
  /// case wants the crossing nearest the craft and is not handled yet.
  double groundRadiusAt(double dx, double dy, double dz) {
    final len = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (len < 1e-9) return radius;
    final inv = 1.0 / len;
    final dir = Vector3(dx * inv, dy * inv, dz * inv);
    final base = radius + heightInDirection(dir.x, dir.y, dir.z);

    final e = edits;
    if (e == null || e.isEmpty) return base;
    final candidates = e.at(dir);
    if (candidates.isEmpty) return base;

    // Clip each candidate's influence sphere against the ray to get the radial
    // interval it can possibly change. Outside the union of those intervals the
    // composed field IS the base field, so the search only has to cover them.
    var lo = double.infinity, hi = double.negativeInfinity;
    var minFeature = double.infinity;
    for (final b in candidates) {
      final proj = b.centreBF.dot(dir);
      final perp2 = b.centreBF.lengthSquared - proj * proj;
      final rad2 = b.boundingRadiusM * b.boundingRadiusM;
      if (perp2 >= rad2) continue; // ray misses this brush entirely
      final half = math.sqrt(rad2 - perp2);
      if (proj - half < lo) lo = proj - half;
      if (proj + half > hi) hi = proj + half;
      // Radial detail to resolve: the shallowest thing the brush can carve, so
      // the march cannot step clean over a shallow scrape or a thin rim.
      if (b.radiusM < minFeature) minFeature = b.radiusM;
      if (b.depthM > 0 && b.depthM < minFeature) minFeature = b.depthM;
      if (b.rimHeightM > 0 && b.rimHeightM < minFeature) {
        minFeature = b.rimHeightM;
      }
    }
    if (hi < lo) return base; // every candidate's sphere missed the ray

    // Bracket ends must be provably air above and solid below. Above `hi` and
    // below `lo` the field equals the base field, whose sign is decided by
    // `base` alone — so pushing the ends past both `hi`/`lo` and `base`
    // guarantees it.
    final span = math.max(hi, base) - math.min(lo, base);
    final margin = math.max(span * 0.01, 1e-3);
    final rStart = math.max(hi, base) + margin;
    final rEnd = math.min(lo, base) - margin;

    // Step fine enough to resolve the shallowest carved feature, but bounded so
    // a pathological brush cannot turn one collision query into a long loop.
    final step = math.max(minFeature / 6.0, (rStart - rEnd) / 512.0);
    var rOuter = rStart;
    if (density(dir.x * rStart, dir.y * rStart, dir.z * rStart) <= 0) {
      return rStart; // outer end already solid: the bracket construction failed
    }
    var r = rStart;
    while (r > rEnd) {
      r = math.max(r - step, rEnd);
      if (density(dir.x * r, dir.y * r, dir.z * r) <= 0) {
        // Outermost air->solid transition; bisect the bracket [r, rOuter].
        return _bisect(dir, r, rOuter);
      }
      rOuter = r;
    }
    // Unreachable by construction — rStart is air and rEnd is solid, so a
    // crossing exists — unless the march stepped over a feature thinner than
    // `step`. Falling back to the base surface keeps the caller sane.
    return base;
  }

  /// Refine an air(outer)/solid(inner) bracket to the isosurface.
  double _bisect(Vector3 dir, double solid, double air) {
    var lo = solid, hi = air;
    for (var i = 0; i < 32; i++) {
      final mid = (lo + hi) * 0.5;
      if (density(dir.x * mid, dir.y * mid, dir.z * mid) <= 0) {
        lo = mid;
      } else {
        hi = mid;
      }
      if (hi - lo < 1e-4) break;
    }
    return (lo + hi) * 0.5;
  }

  double get seaRadius => radius + seaLevel;
}
