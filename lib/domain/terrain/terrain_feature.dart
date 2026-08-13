// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Composable terrain features — the layer that lets one generator serve bodies
/// with genuinely different surface grammars.
///
/// "Noise plus craters" describes rocky airless worlds and nothing else. The
/// catalogue also contains Europa (anisotropic double-ridge lineae, chaos
/// blocks, essentially no craters, and only a few hundred metres of relief
/// globally), Titan (longitudinal dune fields, fluvial channels, methane seas),
/// Io (isolated tectonic mountains up to ~17 km with no crater record at all,
/// because it resurfaces faster than it accumulates one) and Iapetus (a single
/// 1300 km equatorial ridge). None of those is a parameter tweak away from fBm;
/// they are different landform vocabularies.
///
/// So the detail layer is a LIST of features, each contributing metres of
/// height, each weighting itself from the [TerrainControl] channels. Adding a
/// world with an unfamiliar surface means adding a feature, not editing a
/// switch — and bodies that do not want it simply never include it, paying
/// nothing.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';
import 'gradient_noise3.dart';
import 'terrain_control.dart';

/// One contributor to the terrain's height, in the body-fixed frame.
///
/// Implementations MUST be pure and deterministic — collision and the render
/// mesher evaluate these independently and must agree exactly — and must
/// return metres, signed, relative to the surface the base layer establishes.
abstract class TerrainFeature {
  /// Height contribution (m) along a unit direction.
  double heightAt(Vector3 dir, TerrainControl control);

  /// Largest magnitude this feature can return (m), given [control]'s local
  /// relief. Used to bound the meshing shell and the collision search band, so
  /// an over-estimate is safe and an under-estimate clips terrain.
  double maxMagnitude(double localReliefM);
}

/// The general-purpose relief feature: erosion-aware fBm blended against ridged
/// multifractal, over a domain-warped coordinate.
///
/// This is what replaces the old plain-fBm `heightInDirection`. Three things it
/// does that a bare fBm sum cannot:
///
///  * **Erosion asymmetry** — [erodedFbm] damps detail on already-steep ground,
///    so slopes come out scoured and flats come out textured. An fBm sum is
///    symmetric and cannot produce that.
///  * **Ridged blending** — mountain belts get sharp crests where the control
///    field asks for them, and only there. Ridges everywhere reads as
///    artificial exactly as fast as noise everywhere does.
///  * **Domain warping** — bends contours into sinuous shapes, breaking the
///    isotropy that makes plain fBm recognisable at a glance.
///
/// Amplitude and character come from [TerrainControl], so the same feature
/// produces an abyssal plain and a mountain belt on one body.
class ErodedReliefFeature implements TerrainFeature {
  ErodedReliefFeature({
    required int seed,
    required this.radiusM,
    required this.featureScaleM,
    this.octaves = 6,
    this.slopeDamping = 1.0,
    this.warpStrength = 0.35,
    this.lacunarity = 2.0,
    this.gain = 0.5,
  })  : assert(featureScaleM > 0),
        assert(radiusM > 0),
        _noise = GradientNoise3(seed),
        _warp = GradientNoise3(seed ^ 0x5BF03635);

  /// Body datum radius (m) — makes [featureScaleM] independent of body size.
  final double radiusM;

  /// World wavelength (m) of the largest detail feature.
  final double featureScaleM;

  final int octaves;

  /// Strength of the erosion damping. 0 is plain fBm; ~1 is strongly eroded.
  final double slopeDamping;

  /// Domain-warp displacement, in units of the noise-space coordinate.
  final double warpStrength;

  final double lacunarity;
  final double gain;

  final GradientNoise3 _noise;
  final GradientNoise3 _warp;

  double get _scale => radiusM / featureScaleM;

  @override
  double heightAt(Vector3 dir, TerrainControl control) {
    final relief = control.reliefAt(dir);
    if (relief <= 0) return 0;
    final roughness = control.roughnessAt(dir);
    final ridgedness = control.ridgednessAt(dir);

    final s = _scale;
    final w = domainWarp(
      _warp,
      dir.x * s,
      dir.y * s,
      dir.z * s,
      strength: warpStrength,
      frequency: 0.5,
    );

    final eroded = erodedFbm(
      _noise,
      w.x,
      w.y,
      w.z,
      octaves: octaves,
      lacunarity: lacunarity,
      gain: gain,
      slopeDamping: slopeDamping,
    ).value;

    // Ridged returns 0..1 (crests at 1), so re-centre it before blending or the
    // ridged regions would sit systematically higher than the eroded ones and
    // the blend would read as a terrace at the transition.
    final ridged = ridgedFbm(
          _noise,
          w.x,
          w.y,
          w.z,
          octaves: octaves,
          lacunarity: lacunarity,
          gain: gain,
        ) *
            2.0 -
        1.0;

    final blended = eroded * (1.0 - ridgedness) + ridged * ridgedness;
    // Roughness scales the DETAIL, never below a floor — a perfectly smooth
    // region would read as a rendering failure rather than as flat ground.
    final amplitude = relief * (0.35 + 0.65 * roughness);
    return (blended * amplitude).clamp(-relief, relief);
  }

  @override
  double maxMagnitude(double localReliefM) => localReliefM;
}

/// A sum of [TerrainFeature]s — the detail layer as a whole.
///
/// Order is irrelevant here (addition commutes), unlike the CSG brushes in
/// `terrain_brush.dart` where it is load-bearing. Features are additive
/// precisely so a body's feature list can be assembled declaratively without
/// anyone having to reason about sequencing.
class TerrainDetail {
  const TerrainDetail(this.features, this.control);

  /// Nothing at all — a perfectly smooth datum sphere.
  static const TerrainDetail none =
      TerrainDetail(<TerrainFeature>[], UniformControl(relief: 0));

  final List<TerrainFeature> features;
  final TerrainControl control;

  bool get isEmpty => features.isEmpty;

  /// Total height contribution (m) along a unit direction.
  double heightAt(Vector3 dir) {
    var sum = 0.0;
    for (final f in features) {
      sum += f.heightAt(dir, control);
    }
    return sum;
  }

  /// Conservative bound (m) on `|heightAt|` anywhere, for sizing the meshing
  /// shell and the collision search band. Over-estimating costs a slightly
  /// thicker voxel band; under-estimating clips terrain, so this errs high.
  double maxMagnitude(double localReliefM) {
    var sum = 0.0;
    for (final f in features) {
      sum += f.maxMagnitude(localReliefM);
    }
    return sum;
  }

  /// The largest relief [control] reports over a sampling of the sphere.
  ///
  /// A field-wide bound has to come from somewhere, and the control field is
  /// noise — there is no closed form for its maximum. [samples] directions on a
  /// Fibonacci sphere give an even, deterministic estimate; the caller pads it.
  double peakRelief({int samples = 512}) {
    var peak = 0.0;
    final golden = math.pi * (3.0 - math.sqrt(5.0));
    for (var i = 0; i < samples; i++) {
      final y = 1.0 - 2.0 * (i + 0.5) / samples;
      final r = math.sqrt(math.max(0.0, 1.0 - y * y));
      final theta = golden * i;
      final dir = Vector3(math.cos(theta) * r, y, math.sin(theta) * r);
      final v = control.reliefAt(dir);
      if (v > peak) peak = v;
    }
    return peak;
  }
}
