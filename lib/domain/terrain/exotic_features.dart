// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Terrain grammars for bodies that are not rocky cratered worlds.
///
/// The catalogue runs well past "noise plus craters". Europa is covered in
/// anisotropic double-ridge LINEAE, thousands of kilometres long, with almost
/// no crater record (its surface is tens of millions of years old, not
/// billions) and only a few hundred metres of global relief. Titan has
/// longitudinal DUNE fields sculpted by a prevailing wind. Enceladus has
/// parallel fractures at one pole. None of those is reachable by tuning an
/// isotropic noise sum, because their defining property is DIRECTION, and
/// isotropic noise has none by construction.
///
/// ## Why these do not steer off `TerrainControl.lineationAt` alone
///
/// The obvious construction — take the local lineation tangent, measure
/// distance across it, make that the ridge phase — does not work, and fails in
/// a way worth recording because it looks correct right up until it is tested.
///
/// A ridge is a level set of some scalar PHASE field, and the ridge direction
/// is that field's contour. Going the other way, from an arbitrary direction
/// field to a phase whose contours match it, means finding a scalar potential —
/// and a noise-driven direction field on a sphere generally has none. (The
/// naive attempt is worse still: any tangent built as `dir x l` has
/// `dir . (dir x l) == 0` identically, so the "distance across" coordinate is
/// not merely approximate, it is always zero.)
///
/// So each feature here OWNS its phase field, built to have a potential by
/// construction — fixed global axes for lineae, latitude for zonal dunes — and
/// reads [TerrainControl.lineationAt] for strength: where the anisotropic
/// structure appears, and how strongly. That keeps the control interface doing
/// what it can actually do.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';
import 'gradient_noise3.dart';
import 'terrain_control.dart';
import 'terrain_feature.dart';

/// Europa-style **lineae**: long, near-parallel double ridges, in several
/// crosscutting families.
///
/// Each family samples noise through an anisotropically scaled coordinate —
/// compressed along one fixed global axis, left alone across it — so its
/// structures run long in one direction and stay narrow in the other. Folding
/// (`1 - |n|`) turns the field's zero crossings into crests, which is what
/// makes the result a ridge network rather than a set of bumps.
///
/// Families are composited by MAX, not sum: on Europa a younger linea overlays
/// an older one rather than adding to it, and summation would pile the
/// intersections into spikes.
class LineaFeature implements TerrainFeature {
  LineaFeature({
    required int seed,
    required this.radiusM,
    this.spacingM = 25000,
    this.elongation = 10.0,
    this.reliefFraction = 1.0,
    this.families = 3,
    this.doubled = true,
    this.octaves = 3,
  })  : assert(elongation >= 1),
        assert(families > 0),
        _noise = GradientNoise3(seed ^ 0x1EAE1EAE),
        _seed = seed;

  final double radiusM;

  /// Typical spacing (m) between neighbouring ridges within a family.
  final double spacingM;

  /// How much longer than wide the structures run.
  final double elongation;

  /// Height as a fraction of the control's local relief.
  final double reliefFraction;

  /// Crosscutting ridge families. Europa's surface records several distinct
  /// episodes at different orientations; one family alone reads as corduroy.
  final int families;

  /// Split each crest into a ridge pair with a central trough — the signature
  /// of a Europan double ridge.
  final bool doubled;

  final int octaves;
  final GradientNoise3 _noise;
  final int _seed;

  /// A deterministic unit axis per family, spread over the sphere so families
  /// genuinely crosscut instead of nearly coinciding.
  Vector3 _axis(int family) {
    // Golden-angle spiral: even coverage without needing a random table.
    final golden = math.pi * (3.0 - math.sqrt(5.0));
    final i = family + (_seed & 0xff);
    final y = 1.0 - 2.0 * ((i % families) + 0.5) / families;
    final r = math.sqrt(math.max(0.0, 1.0 - y * y));
    final t = golden * i;
    return Vector3(math.cos(t) * r, y, math.sin(t) * r).normalized;
  }

  @override
  double heightAt(Vector3 dir, TerrainControl control) {
    final strength = control.lineationAt(dir).length;
    if (strength <= 1e-6) return 0;
    final relief = control.reliefAt(dir);
    if (relief <= 0) return 0;

    final scale = radiusM / spacingM;
    var best = 0.0;
    for (var f = 0; f < families; f++) {
      final axis = _axis(f);
      // Compress the coordinate ALONG the family axis. Points separated along
      // it map to nearly the same sample, so structures stretch that way;
      // points separated across it move fully, so structures stay narrow.
      // `dir . axis` is a genuine varying coordinate — unlike a tangent built
      // from `dir` itself, which cannot vary at all.
      final t = dir.dot(axis);
      final p = dir - axis * (t * (1.0 - 1.0 / elongation));
      final n = fbm3(_noise, p.x * scale + f * 53.7, p.y * scale + f * 91.3,
              p.z * scale + f * 17.9,
              octaves: octaves)
          .value;

      var crest = 1.0 - n.abs(); // fold: zero crossings become crests
      if (doubled) {
        // Narrow trough down the middle of the crest leaves two rails.
        final d = crest - 0.78;
        final split = 1.0 - 30.0 * d * d;
        crest = crest * 0.6 + crest * split.clamp(0.0, 1.0) * 0.4;
      }
      if (crest > best) best = crest;
    }
    return best * relief * reliefFraction * strength;
  }

  @override
  double maxMagnitude(double localReliefM) => localReliefM * reliefFraction;
}

/// Titan-style **longitudinal dunes**: long parallel sand ridges aligned to a
/// prevailing wind, with a regular crest spacing.
///
/// Zonal by construction — the dunes run east-west and the phase is LATITUDE,
/// which is a real scalar field with a real gradient and therefore a usable
/// ridge phase. That also happens to be physically right: Titan's dune seas are
/// equatorial and wind-aligned.
///
/// Unlike the lineae these are strongly PERIODIC. Dune fields have a
/// characteristic wavelength, and no fBm sum produces one — hence an explicit
/// sinusoid, with noise only bending and breaking it.
class DuneFeature implements TerrainFeature {
  DuneFeature({
    required int seed,
    required this.radiusM,
    this.wavelengthM = 3000,
    this.heightM = 120,
    this.meander = 0.35,
    this.latitudeLimit = 0.52, // ~30 degrees: dunes are an equatorial habit
    this.pole = Vector3.unitZ,
    this.octaves = 2,
  })  : assert(wavelengthM > 0),
        _noise = GradientNoise3(seed ^ 0x0D0E0D0E);

  final double radiusM;

  /// Crest-to-crest spacing (m). Titan's run 1-3 km.
  final double wavelengthM;

  /// Dune height (m) at full lineation strength.
  final double heightM;

  /// How far the crests wander, in wavelengths. Zero gives unnatural corduroy.
  final double meander;

  /// Dunes fade out beyond this |latitude| in radians.
  final double latitudeLimit;

  /// The body's spin axis, which sets the wind's zonal direction.
  final Vector3 pole;

  final int octaves;
  final GradientNoise3 _noise;

  @override
  double heightAt(Vector3 dir, TerrainControl control) {
    final strength = control.lineationAt(dir).length;
    if (strength <= 1e-6) return 0;

    final sinLat = dir.dot(pole).clamp(-1.0, 1.0);
    final lat = math.asin(sinLat);
    if (lat.abs() >= latitudeLimit) return 0;
    // Taper to nothing at the limit so the field has no hard edge.
    final band = 1.0 - (lat.abs() / latitudeLimit);

    // Phase runs with latitude — a true scalar field, so its contours are the
    // east-west lines the dunes follow.
    final phaseM = lat * radiusM;
    final meanderM =
        fbm3(_noise, dir.x * 8, dir.y * 8, dir.z * 8, octaves: octaves).value *
            meander *
            wavelengthM;
    final phase = (phaseM + meanderM) / wavelengthM * 2 * math.pi;

    // Asymmetric profile: sharpening |sin| toward its peak approximates a long
    // windward slope meeting a short slip face.
    final s = math.sin(phase).abs();
    return s * s * heightM * strength * band;
  }

  @override
  double maxMagnitude(double localReliefM) => heightM;
}
