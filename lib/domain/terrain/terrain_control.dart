// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What kind of ground is at a point — the layer that makes terrain
/// NON-STATIONARY.
///
/// Plain fBm is statistically identical everywhere, which is precisely why it
/// reads as uniform however many octaves it gets. Real bodies are not: the Moon
/// has maria and highlands, Earth has abyssal plains next to orogenic belts.
/// Fixing that means varying the GENERATOR'S OWN PARAMETERS across the surface,
/// and [TerrainControl] is the thing that says how.
///
/// ## Why this is an interface
///
/// There are two ways to know what kind of ground is somewhere, and they are
/// the same question:
///
///  * **Derive it** from a real elevation model — local roughness, gradient
///    magnitude, elevation band. Available for the Moon, Mars, Earth.
///  * **Synthesise it** from low-frequency noise. Necessary for the ~12 bodies
///    in the catalogue with no usable topography at all, and for anything
///    fictional.
///
/// Both feed the same downstream generator, so they belong behind one
/// interface rather than in two pipelines. That also means the detail layer can
/// be CALIBRATED against real data (fit its statistics to LOLA, where the
/// answer is checkable) and then reused on bodies that will never have any.
///
/// ## Continuous channels, not a terrain-type enum
///
/// Every channel here is continuous, and features weight themselves off them.
/// A closed enum of terrain types would have to be reopened for every body with
/// an unfamiliar surface — and there are plenty: Europa is dominated by
/// anisotropic ridge systems with almost no craters and only a few hundred
/// metres of global relief, Titan by dune fields, Io by isolated tectonic
/// mountains, Iapetus by a single equatorial ridge. Continuous channels plus
/// self-weighting features absorb those without touching this file.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';
import 'gradient_noise3.dart';

/// Per-direction terrain character, in the body-fixed frame.
///
/// All queries take a UNIT direction. Implementations must be pure and
/// deterministic: the collision path and the render mesher both consult this
/// and have to agree.
abstract class TerrainControl {
  /// Vertical relief scale here, in metres. Not the height — the amount of
  /// vertical range the ground varies over locally.
  ///
  /// This replaces the single global `amplitude` scalar, which cannot express
  /// an abyssal plain adjacent to a mountain belt. It also has to span bodies
  /// as different as Europa (a few hundred metres of relief globally) and the
  /// Moon (19 km).
  double reliefAt(Vector3 dir);

  /// How broken the ground is, `0..1`. Drives detail amplitude and octave
  /// weighting — a lava plain and a fractured highland differ here even at
  /// identical relief.
  double roughnessAt(Vector3 dir);

  /// How ridge-like the terrain is, `0..1`. 0 is rounded/depositional, 1 is
  /// sharp-crested. Blends ridged multifractal against eroded fBm.
  double ridgednessAt(Vector3 dir);

  /// Preferred direction of anisotropic features, as a TANGENT vector (already
  /// perpendicular to `dir`). Length is the strength: zero means isotropic.
  ///
  /// This channel is what makes non-rocky worlds expressible at all. Europa's
  /// lineae, Titan's longitudinal dunes, and Enceladus's tiger stripes are all
  /// strongly directional, and no amount of isotropic noise produces them.
  /// Isotropic implementations return [Vector3.zero] and cost nothing.
  Vector3 lineationAt(Vector3 dir);
}

/// A [TerrainControl] with no variation at all — one relief, one roughness,
/// everywhere. The behaviour of the old single-`amplitude` field, kept as an
/// explicit baseline for tests and for bodies deliberately left featureless.
class UniformControl implements TerrainControl {
  const UniformControl({
    required this.relief,
    this.roughness = 0.5,
    this.ridgedness = 0.0,
  });

  final double relief;
  final double roughness;
  final double ridgedness;

  @override
  double reliefAt(Vector3 dir) => relief;

  @override
  double roughnessAt(Vector3 dir) => roughness;

  @override
  double ridgednessAt(Vector3 dir) => ridgedness;

  @override
  Vector3 lineationAt(Vector3 dir) => Vector3.zero;
}

/// Control fields synthesised from low-frequency noise — the path for bodies
/// with no usable elevation data.
///
/// Three independent very-low-frequency fields, in the spirit of Minecraft
/// 1.18's terrain rewrite, each on its own decorrelated noise channel:
///
///  * **continentalness** — the large-scale high/low structure. Drives relief.
///  * **erosion** — how worn the region is. High erosion flattens and smooths;
///    low erosion leaves relief and roughness intact.
///  * **peaks-and-valleys** — how sharply crested the region is. Drives the
///    ridged/eroded blend.
///
/// They are deliberately much lower frequency than the terrain itself: these
/// decide what KIND of place this is over hundreds of kilometres, and the
/// detail layer decides what it looks like over hundreds of metres.
class SyntheticControl implements TerrainControl {
  SyntheticControl({
    required int seed,
    required this.radiusM,
    required this.reliefScaleM,
    this.regionScaleM = 400000,
    this.roughnessFloor = 0.15,
    this.reliefFloor = 0.05,
    this.lineation = 0.0,
    this.octaves = 3,
  })  : assert(reliefScaleM >= 0),
        assert(regionScaleM > 0),
        // Offsetting the seed keeps these three fields from correlating with
        // each other OR with the detail layer that shares the body's seed —
        // correlated control fields collapse into one, and the variety they
        // exist to create disappears.
        _continent = GradientNoise3(seed ^ 0x9E3779B9),
        _erosion = GradientNoise3(seed ^ 0x517CC1B7),
        _peaks = GradientNoise3(seed ^ 0x27220A95),
        _lineDir = GradientNoise3(seed ^ 0x6C078965);

  /// Body datum radius (m) — makes the region scale independent of body size.
  final double radiusM;

  /// Peak relief (m) a fully "continental" region reaches.
  final double reliefScaleM;

  /// Wavelength (m) of the control fields themselves. Hundreds of km: these
  /// decide provinces, not landforms.
  final double regionScaleM;

  /// Minimum roughness, so nowhere is perfectly glassy.
  final double roughnessFloor;

  /// Minimum relief as a fraction of [reliefScaleM], so the flattest province
  /// still has some structure.
  final double reliefFloor;

  /// Strength of the synthesised lineation field, `0..1`. 0 (the default)
  /// leaves terrain isotropic; raise it for worlds whose surface is dominated
  /// by directional features.
  final double lineation;

  final int octaves;

  final GradientNoise3 _continent;
  final GradientNoise3 _erosion;
  final GradientNoise3 _peaks;
  final GradientNoise3 _lineDir;

  /// Noise-space scale: region wavelength expressed in body radii.
  double get _scale => radiusM / regionScaleM;

  /// Sample [n] along [dir] and remap from `-1..1` to `0..1`.
  double _field(GradientNoise3 n, Vector3 dir) {
    final s = _scale;
    final v = fbm3(n, dir.x * s, dir.y * s, dir.z * s, octaves: octaves).value;
    return (v * 0.5 + 0.5).clamp(0.0, 1.0);
  }

  @override
  double reliefAt(Vector3 dir) {
    final continent = _field(_continent, dir);
    final erosion = _field(_erosion, dir);
    // Continents carry relief; erosion takes it away. Squaring the
    // continentalness biases toward flat, so highlands read as the exception
    // rather than the average — which is what makes them look like highlands.
    final raw = continent * continent * (1.0 - 0.75 * erosion);
    return reliefScaleM * (reliefFloor + (1.0 - reliefFloor) * raw);
  }

  @override
  double roughnessAt(Vector3 dir) {
    final erosion = _field(_erosion, dir);
    final raw = 1.0 - erosion; // heavily eroded ground is smooth ground
    return (roughnessFloor + (1.0 - roughnessFloor) * raw).clamp(0.0, 1.0);
  }

  @override
  double ridgednessAt(Vector3 dir) {
    final peaks = _field(_peaks, dir);
    final continent = _field(_continent, dir);
    // Sharp crests need both the tendency AND something to raise: ridges in a
    // basin read as noise, not mountains.
    return (peaks * continent).clamp(0.0, 1.0);
  }

  @override
  Vector3 lineationAt(Vector3 dir) {
    if (lineation <= 0) return Vector3.zero;
    // An angle field over the sphere, projected into the local tangent plane.
    final s = _scale;
    final a = fbm3(_lineDir, dir.x * s, dir.y * s, dir.z * s, octaves: octaves)
            .value *
        math.pi;
    // Build a tangent frame, then rotate within it by that angle.
    final seed = dir.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
    final t = seed.cross(dir).normalized;
    final b = dir.cross(t);
    return (t * math.cos(a) + b * math.sin(a)) * lineation;
  }
}
