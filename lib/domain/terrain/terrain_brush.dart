// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Subtractive 3D density brushes — the terrain deformation primitive.
///
/// A brush is an analytic CSG operation on the density field, NOT a stored
/// voxel delta. That choice is what makes deformation survive LOD: an SDF
/// evaluates correctly at any sample rate, so a crater looks right whether the
/// chunk meshing it is 2 m or 2 km per voxel. A voxel delta recorded at one
/// level would have to be correctly downsampled into every coarser level or the
/// crater silently vanishes as the camera pulls away.
///
/// Brushes are 3D rather than height offsets because impacts happen at
/// arbitrary geometry. A height brush is by definition an offset along the
/// radial, so a craft that hits a cliff face would excavate a dimple downward
/// from the sky above the cliff. A subtracted sphere at the contact point does
/// the right thing at any orientation, and it is the same primitive mining and
/// tunnelling need.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';

/// How far inside the rim crest the excavated cavity opens, as a fraction of
/// the crest radius.
///
/// The rim is unioned onto the field and the bowl is then subtracted from it,
/// so the two cannot share a radius — the subtraction would remove the crest.
/// 0.87 leaves the crest clear of the cavity by a comfortable margin at the
/// standard 1:5 depth-to-diameter ratio while keeping the visible mouth close
/// to the quoted crater size.
const double _bowlMouthFactor = 0.87;

/// What shape a [TerrainBrush] cuts.
enum TerrainBrushKind {
  /// A plain subtracted ball — excavation, mining, generic digging.
  sphere,

  /// An impact crater: a subtracted spherical bowl plus a smoothly unioned
  /// raised rim, oriented against the surface normal at the contact point.
  crater,
}

/// One analytic edit to a body's density field, in the BODY-FIXED frame.
///
/// ## Sign convention
///
/// [TerrainField]'s density is negative inside solid, positive in air, with the
/// isosurface at 0 — and near the surface its magnitude is metres along the
/// radial, so brush dimensions in metres compose naturally with it.
///
/// Carving is therefore standard SDF CSG: subtracting shape `S` is
/// `max(d, -sdf_S)`, unioning it is `min(d, sdf_S)`.
///
/// ## Order matters
///
/// `max`/`min` do not commute, so a list of brushes is an ORDERED sequence, not
/// a set. [TerrainEdits] preserves insertion order, which is tick order in the
/// authoritative sim — that is what keeps the composed field deterministic.
class TerrainBrush {
  TerrainBrush({
    required this.kind,
    required this.centreBF,
    required this.axisBF,
    required this.radiusM,
    this.depthM = 0,
    this.rimHeightM = 0,
    this.tick = 0,
  })  : assert(radiusM > 0, 'a zero-radius brush cuts nothing'),
        _axis = axisBF.normalized {
    // Bowl geometry, solved from the cavity mouth radius and the depth. A
    // sphere of radius `rs` whose centre sits `h0` ABOVE the contact plane
    // meets that plane in a circle of radius `mouth` and reaches `depthM`
    // below it:
    //   rs - h0 = depthM         (depth below the plane)
    //   rs^2 - h0^2 = mouth^2    (the intersection circle)
    // which solves directly. Expressing the bowl this way means the caller
    // specifies what it can actually observe — how wide and how deep — instead
    // of an abstract sphere placement.
    //
    // The mouth opens INSIDE the crest ([_bowlMouthFactor]), because the bowl
    // is subtracted after the rim is unioned. Were the two the same radius the
    // excavation would swallow the crest it is supposed to be ringed by, and
    // the crater would come out as a plain divot with no raised lip.
    if (kind == TerrainBrushKind.crater && depthM > 0) {
      final mouth = radiusM * _bowlMouthFactor;
      final k = mouth * mouth / depthM;
      _bowlRadius = (depthM + k) * 0.5;
      _bowlOffset = (k - depthM) * 0.5;
    } else {
      _bowlRadius = radiusM;
      _bowlOffset = 0;
    }

    // Influence bound. Deliberately a little larger than the primitives reach
    // (see [boundingRadiusM]) so the hard cutoff in [apply] can never land ON a
    // primitive's own surface and fabricate an isosurface there.
    final reach = kind == TerrainBrushKind.crater
        ? math.max(_bowlOffset + _bowlRadius, radiusM + rimHeightM)
        : radiusM;
    boundingRadiusM = reach * 1.08 + 1.0;
  }

  /// A plain subtracted ball centred at [centreBF].
  factory TerrainBrush.sphere({
    required Vector3 centreBF,
    required double radiusM,
    int tick = 0,
  }) =>
      TerrainBrush(
        kind: TerrainBrushKind.sphere,
        centreBF: centreBF,
        // Unused by a ball, but the field must stay non-degenerate.
        axisBF: centreBF.lengthSquared > 0 ? centreBF : Vector3.unitZ,
        radiusM: radiusM,
        tick: tick,
      );

  /// An impact crater seated on the surface at [contactBF], opening along
  /// [normalBF] (the outward surface normal there — for a body-radial impact
  /// that is just `contactBF.normalized`).
  ///
  /// [radiusM] is the rim CREST radius, [depthM] the bowl floor below the
  /// contact plane, [rimHeightM] the crest above it. See `impact_scaling.dart`
  /// for deriving all three from an impact's kinetic energy.
  factory TerrainBrush.crater({
    required Vector3 contactBF,
    required Vector3 normalBF,
    required double radiusM,
    required double depthM,
    double rimHeightM = 0,
    int tick = 0,
  }) =>
      TerrainBrush(
        kind: TerrainBrushKind.crater,
        centreBF: contactBF,
        axisBF: normalBF,
        radiusM: radiusM,
        depthM: depthM,
        rimHeightM: rimHeightM,
        tick: tick,
      );

  final TerrainBrushKind kind;

  /// Body-fixed centre (m). For a crater this is the contact point ON the
  /// surface, not the impactor's position.
  final Vector3 centreBF;

  /// Body-fixed orientation — the surface normal at contact for a crater. Not
  /// required to be unit length; it is normalised on construction.
  final Vector3 axisBF;

  /// Rim crest radius for a crater, ball radius for a sphere (m).
  final double radiusM;

  /// Bowl floor below the contact plane (m). Craters only.
  final double depthM;

  /// Rim crest above the contact plane (m). Craters only; 0 disables the rim.
  final double rimHeightM;

  /// Simulation tick the edit was made on. Ordering/provenance only — the
  /// composed field depends on list ORDER, not on this value.
  final int tick;

  /// Radius (m) beyond which this brush provably changes nothing, measured
  /// from [centreBF]. [apply] hard-cuts here, and [TerrainEdits] indexes on it.
  ///
  /// The margin above the primitives' true reach is load-bearing. Outside the
  /// cut, `apply` returns the input unchanged; just inside, it returns the CSG
  /// result. That step is only safe where both sides have the SAME SIGN, which
  /// holds strictly outside every primitive but degenerates exactly on one
  /// (there `-sdf == 0`, and `max(d, 0)` would read as an isosurface in solid
  /// rock). Keeping the cut clear of the primitives keeps the step buried in
  /// deep solid or open air, where nothing samples the gradient.
  late final double boundingRadiusM;

  late final Vector3 _axis;
  late final double _bowlRadius;
  late final double _bowlOffset;

  /// Bowl sphere radius (m) — solved from [radiusM] and [depthM].
  double get bowlRadiusM => _bowlRadius;

  /// How far the bowl sphere's centre sits above the contact plane (m).
  double get bowlOffsetM => _bowlOffset;

  /// Whether [p] (body-fixed metres) is inside this brush's influence.
  bool affects(Vector3 p) =>
      (p - centreBF).lengthSquared <= boundingRadiusM * boundingRadiusM;

  /// Compose this brush onto [density] at body-fixed point [p].
  ///
  /// Returns [density] untouched outside [boundingRadiusM].
  double apply(double density, Vector3 p) {
    final w = p - centreBF;
    if (w.lengthSquared > boundingRadiusM * boundingRadiusM) return density;

    var d = density;
    if (kind == TerrainBrushKind.crater && rimHeightM > 0) {
      // Rim first, bowl second: the crest is material thrown UP around the
      // hole, so the excavation has to win wherever the two overlap.
      d = _smin(d, _rimSdf(w), rimHeightM);
    }
    return math.max(d, -_bowlSdf(w));
  }

  /// Signed distance to the excavated bowl. [w] is relative to [centreBF].
  double _bowlSdf(Vector3 w) =>
      (w - _axis * _bowlOffset).length - _bowlRadius;

  /// Signed distance to the rim torus: major radius [radiusM] on the contact
  /// plane, minor radius [rimHeightM], so the crest stands exactly
  /// [rimHeightM] proud of the surface.
  double _rimSdf(Vector3 w) {
    final along = w.dot(_axis);
    final lateral = (w - _axis * along).length;
    final a = lateral - radiusM;
    return math.sqrt(a * a + along * along) - rimHeightM;
  }

  @override
  String toString() => 'TerrainBrush(${kind.name}, r=${radiusM.toStringAsFixed(1)}m, '
      'd=${depthM.toStringAsFixed(1)}m @ $centreBF)';
}

/// Polynomial smooth minimum (Quílez). Blends two SDFs over a width [k] instead
/// of creasing them together, so a rim meets the surrounding ground in a fillet
/// rather than a fold. Degrades to plain `min` as [k] goes to zero.
double _smin(double a, double b, double k) {
  if (k <= 0) return math.min(a, b);
  final h = (0.5 + 0.5 * (b - a) / k).clamp(0.0, 1.0);
  return b * (1.0 - h) + a * h - k * h * (1.0 - h);
}
