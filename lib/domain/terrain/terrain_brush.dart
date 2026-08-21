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

  /// A levelled building pad: forces the surface to a target radius inside a
  /// disc, easing back to the natural ground over a falloff ring. Cuts hills
  /// AND fills hollows, which is what "level the site" actually means.
  pad,

  /// An open-pit mine: a levelled floor with concentric benches stepping up to
  /// the rim, so the excavation reads as a worked quarry rather than a dent.
  steppedPit,

  /// A road corridor: levels a strip between two points to a datum that
  /// interpolates along it, cutting through rises and filling dips so the
  /// carriageway holds a constant grade.
  cutFill,

  /// A levelled building pad shaped like its LOT: an oriented rectangle rather
  /// than a disc.
  ///
  /// [pad] circumscribes the lot, so for a 24x32 m parcel it is a 26 m disc —
  /// wider than the 24 m spacing between neighbours. Every pad therefore
  /// re-levelled its neighbours' lots to its own datum, the last one emitted
  /// won, and each building ended up standing on a patchwork 5-7 m deep: flush
  /// at its centre, buried at one corner, hanging off another. A rectangle
  /// tiles the way lots actually tile, so a pad levels its own lot and stops.
  ///
  /// APPENDED, not inserted: the kind is serialised by index.
  padBox,

  /// A levelled building pad cut to the LOT'S OWN POLYGON.
  ///
  /// Every parcel a subdivider produces is a polygon, not a rectangle — lots
  /// taper wherever a road bends, and every road bends somewhere. A rectangle
  /// approximating one either overhangs its neighbour (and re-levels it) or
  /// falls short of its own corners; no size does neither. The polygon levels
  /// exactly the ground the lot owns.
  padPoly,
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
    this.datumRadiusM = 0,
    this.datumRadiusEndM = 0,
    this.falloffM = 0,
    this.benches = 1,
    this.endBF,
    this.polygonBF = const [],
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

    // Rim band half-width: how far the raised ring extends either side of the
    // crest radius before fading to nothing. Proportional to the crater, not
    // to the rim height — a wide crater throws a wide apron.
    _rimWidth = radiusM * 0.35;

    // Influence bound. Deliberately a little larger than the primitives reach
    // (see [boundingRadiusM]) so the hard cutoff in [apply] can never land ON a
    // primitive's own surface and fabricate an isosurface there. The rim's
    // falloff reaches zero AT radiusM + _rimWidth, so the cutoff beyond it
    // steps over nothing.
    final reach = switch (kind) {
      TerrainBrushKind.crater =>
        math.max(_bowlOffset + _bowlRadius, radiusM + _rimWidth),
      // A levelling brush reaches its disc plus the easing ring. Vertically it
      // reaches as far as the ground it is moving, so the bound also has to
      // clear the cut/fill itself — a pad sliced into a hillside rewrites
      // density well above and below its own datum.
      TerrainBrushKind.pad => radiusM + falloffM + depthM,
      TerrainBrushKind.padBox => _boxDiagonalM + falloffM + depthM,
      TerrainBrushKind.padPoly => _polyReachM + falloffM + depthM,
      TerrainBrushKind.steppedPit => radiusM + falloffM + depthM,
      // centreBF is the corridor MIDPOINT, so half its length is the reach
      // along the axis (see [TerrainBrush.cutFill]).
      TerrainBrushKind.cutFill => (endBF == null ? 0.0 : (endBF! - centreBF).length) +
          radiusM +
          falloffM +
          depthM,
      TerrainBrushKind.sphere => radiusM,
    };
    boundingRadiusM = reach * 1.08 + 1.0;

    // Lateral reach: how far from the brush AXIS a sign change (surface
    // created or removed) can occur. Much tighter than [boundingRadiusM] for
    // the levelling kinds, whose bound is inflated by their vertical cut
    // budget (a 12 m pad with the default 60 m maxCut has a ~92 m bounding
    // sphere but levels nothing outside radius + falloff). The crater term is
    // the bowl SPHERE radius, not the crest: on a hillside the bowl's
    // equator can gouge ground that rises to the height of its centre, and
    // the sphere's full lateral extent is exactly [_bowlRadius].
    final lateral = switch (kind) {
      TerrainBrushKind.sphere => radiusM,
      TerrainBrushKind.crater => math.max(radiusM + _rimWidth, _bowlRadius),
      TerrainBrushKind.pad => radiusM + falloffM,
      TerrainBrushKind.padBox => _boxDiagonalM + falloffM,
      TerrainBrushKind.padPoly => _polyReachM + falloffM,
      TerrainBrushKind.steppedPit => radiusM + falloffM,
      // centreBF is the corridor midpoint, so |endBF - centreBF| is already
      // the half-length (same convention as the bounding reach above).
      TerrainBrushKind.cutFill =>
        (endBF == null ? 0.0 : (endBF! - centreBF).length) +
            radiusM +
            falloffM,
    };
    lateralReachM = lateral * 1.05 + 1.0;
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

  /// A levelled building pad centred on [centreBF] (a point ON the surface).
  ///
  /// [datumRadiusM] is the finished floor level, measured from the body centre;
  /// pass the natural ground radius at the site to level it in place, or offset
  /// it to raise/sink the platform. [maxCutM] only sizes the influence bound —
  /// it should be at least as large as the relief being flattened.
  factory TerrainBrush.pad({
    required Vector3 centreBF,
    required double radiusM,
    required double datumRadiusM,
    double falloffM = 12,
    double maxCutM = 60,
    int tick = 0,
  }) =>
      TerrainBrush(
        kind: TerrainBrushKind.pad,
        centreBF: centreBF,
        axisBF: centreBF.lengthSquared > 0 ? centreBF : Vector3.unitZ,
        radiusM: radiusM,
        depthM: maxCutM,
        datumRadiusM: datumRadiusM,
        falloffM: falloffM,
        tick: tick,
      );

  /// A levelled building pad shaped like the LOT it serves.
  ///
  /// [forwardBF] is the lot's depth axis in body-fixed metres (its frontage
  /// normal); [halfWidthM] runs across the frontage and [halfDepthM] back from
  /// it. Stored as a far-end point the way a corridor is, so the brush needs no
  /// field the snapshot does not already carry.
  factory TerrainBrush.padBox({
    required Vector3 centreBF,
    required Vector3 forwardBF,
    required double halfWidthM,
    required double halfDepthM,
    required double datumRadiusM,
    double falloffM = 12,
    double maxCutM = 60,
    int tick = 0,
  }) =>
      TerrainBrush(
        kind: TerrainBrushKind.padBox,
        centreBF: centreBF,
        axisBF: centreBF.lengthSquared > 0 ? centreBF : Vector3.unitZ,
        radiusM: halfWidthM,
        depthM: maxCutM,
        datumRadiusM: datumRadiusM,
        falloffM: falloffM,
        endBF: centreBF + forwardBF.normalized * math.max(halfDepthM, 0.01),
        tick: tick,
      );

  /// A levelled pad cut to [polygonBF] — the lot's own outline, body-fixed and
  /// lying on the ground.
  factory TerrainBrush.padPoly({
    required Vector3 centreBF,
    required List<Vector3> polygonBF,
    required double datumRadiusM,
    double falloffM = 12,
    double maxCutM = 60,
    int tick = 0,
  }) =>
      TerrainBrush(
        kind: TerrainBrushKind.padPoly,
        centreBF: centreBF,
        axisBF: centreBF.lengthSquared > 0 ? centreBF : Vector3.unitZ,
        // A nominal radius keeps the "a zero-radius brush cuts nothing" assert
        // meaningful; the footprint itself comes from the polygon.
        radiusM: math.max(1.0, _polyRadiusOf(centreBF, polygonBF)),
        depthM: maxCutM,
        datumRadiusM: datumRadiusM,
        falloffM: falloffM,
        polygonBF: polygonBF,
        tick: tick,
      );

  static double _polyRadiusOf(Vector3 centre, List<Vector3> poly) {
    var far = 0.0;
    for (final v in poly) {
      final d = (v - centre).length;
      if (d > far) far = d;
    }
    return far;
  }

  /// An open-pit mine at [centreBF]: a floor [depthM] below [datumRadiusM],
  /// with [benches] terraces stepping up to the rim at [radiusM].
  factory TerrainBrush.steppedPit({
    required Vector3 centreBF,
    required double radiusM,
    required double datumRadiusM,
    required double depthM,
    int benches = 6,
    double falloffM = 30,
    int tick = 0,
  }) =>
      TerrainBrush(
        kind: TerrainBrushKind.steppedPit,
        centreBF: centreBF,
        axisBF: centreBF.lengthSquared > 0 ? centreBF : Vector3.unitZ,
        radiusM: radiusM,
        depthM: depthM,
        datumRadiusM: datumRadiusM,
        benches: math.max(1, benches),
        falloffM: falloffM,
        tick: tick,
      );

  /// A levelled road corridor from [startBF] to [endBF], [radiusM] to either
  /// side of the centreline, grading from [datumRadiusM] to [datumRadiusEndM].
  factory TerrainBrush.cutFill({
    required Vector3 startBF,
    required Vector3 endBF,
    required double radiusM,
    required double datumRadiusM,
    required double datumRadiusEndM,
    double falloffM = 8,
    double maxCutM = 40,
    int tick = 0,
  }) {
    // Stored centre is the MIDPOINT so the spherical influence bound (and the
    // spatial index built on it) actually encloses the whole corridor.
    final mid = (startBF + endBF) * 0.5;
    return TerrainBrush(
      kind: TerrainBrushKind.cutFill,
      centreBF: mid,
      axisBF: mid.lengthSquared > 0 ? mid : Vector3.unitZ,
      radiusM: radiusM,
      depthM: maxCutM,
      datumRadiusM: datumRadiusM,
      datumRadiusEndM: datumRadiusEndM,
      falloffM: falloffM,
      endBF: endBF,
      tick: tick,
    );
  }

  final TerrainBrushKind kind;

  /// Body-fixed centre (m). For a crater this is the contact point ON the
  /// surface, not the impactor's position; for a cut/fill corridor it is the
  /// MIDPOINT of the run.
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

  /// Target surface radius from the body centre (m) for the levelling kinds.
  ///
  /// A RADIUS, not a height offset, because that is what makes a pad flat: a
  /// constant radius over a disc is a level surface, whereas a constant offset
  /// from the existing ground just reproduces the hill it was cut into.
  final double datumRadiusM;

  /// Datum at [endBF] for a [TerrainBrushKind.cutFill] corridor. The datum
  /// interpolates along the segment, which is how a road holds a steady grade
  /// through rolling ground instead of stepping between flat benches.
  final double datumRadiusEndM;

  /// Width of the ring over which a levelled surface eases back into natural
  /// ground (m). Zero would leave a vertical wall at the pad edge.
  final double falloffM;

  /// Bench count for [TerrainBrushKind.steppedPit]. 1 is a flat-bottomed hole.
  final int benches;

  /// Footprint of a [TerrainBrushKind.padPoly], body-fixed and on the ground.
  /// Empty for every other kind.
  final List<Vector3> polygonBF;

  /// Farthest polygon vertex from the centre, for the bounds.
  double get _polyReachM {
    var far = 0.0;
    for (final v in polygonBF) {
      final d = (v - centreBF).length;
      if (d > far) far = d;
    }
    return far;
  }

  /// Half-diagonal of a [TerrainBrushKind.padBox] footprint, for its bounds.
  double get _boxDiagonalM {
    final halfDepth = endBF == null ? 0.0 : (endBF! - centreBF).length;
    return math.sqrt(radiusM * radiusM + halfDepth * halfDepth);
  }

  /// Far end of a [TerrainBrushKind.cutFill] corridor (body-fixed metres).
  final Vector3? endBF;

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

  /// Distance from the brush AXIS (m) beyond which this brush provably cannot
  /// move the isosurface. Tighter than [boundingRadiusM] — that sphere also
  /// covers regions where only deep-solid density VALUES shift (which never
  /// moves a surface) and, for the levelling kinds, the vertical cut budget.
  ///
  /// Drives the spatial-index footprint, deformation refinement rings, and
  /// the mesher's "is this column edited" candidacy — the places where an
  /// over-wide bound multiplies work rather than merely wasting one test.
  late final double lateralReachM;

  late final Vector3 _axis;
  late final double _bowlRadius;
  late final double _bowlOffset;
  late final double _rimWidth;

  /// Bowl sphere radius (m) — solved from [radiusM] and [depthM].
  double get bowlRadiusM => _bowlRadius;

  /// How far the bowl sphere's centre sits above the contact plane (m).
  double get bowlOffsetM => _bowlOffset;

  /// Whether [p] (body-fixed metres) is inside this brush's influence.
  bool affects(Vector3 p) =>
      (p - centreBF).lengthSquared <= boundingRadiusM * boundingRadiusM;

  /// The absolute radial interval (m from the body centre) the composed
  /// SURFACE can occupy under this brush, given that the base ground spans
  /// `[groundLoM, groundHiM]` over the region being meshed.
  ///
  /// This is what the mesher's radial band needs — the old `centre ±
  /// boundingRadiusM` bound answered a different (3D) question and cost a
  /// band tens of metres tall for a crater whose relief is four:
  ///
  ///  * a subtracted ball's cavity walls lie ON the ball, and a cavity roof
  ///    is always below the ground above it;
  ///  * a crater floor cannot descend below the bowl sphere's own bottom,
  ///    and its rim lifts the local ground by at most [rimHeightM];
  ///  * the levelling kinds blend the surface TOWARD their datum with a
  ///    0..1 smoothstep weight, which cannot overshoot either endpoint.
  ({double lo, double hi}) surfaceBand(double groundLoM, double groundHiM) {
    switch (kind) {
      case TerrainBrushKind.sphere:
        // Mining ball, possibly buried: the cavity floor is the ball bottom.
        // Subtraction never raises the surface, so the top stays at ground.
        return (
          lo: math.min(groundLoM, centreBF.length - radiusM),
          hi: groundHiM,
        );
      case TerrainBrushKind.crater:
        // Bowl bottom, exact and cheap (the sphere's inner radius from the
        // body centre) — correct even when the impact normal is tilted.
        final bowlLo = (centreBF + _axis * _bowlOffset).length - _bowlRadius;
        return (
          lo: math.min(groundLoM, bowlLo),
          hi: groundHiM + rimHeightM,
        );
      case TerrainBrushKind.pad:
      case TerrainBrushKind.padBox:
      case TerrainBrushKind.padPoly:
        return (
          lo: math.min(groundLoM, datumRadiusM),
          hi: math.max(groundHiM, datumRadiusM),
        );
      case TerrainBrushKind.steppedPit:
        return (
          lo: math.min(groundLoM, datumRadiusM - depthM),
          hi: math.max(groundHiM, datumRadiusM),
        );
      case TerrainBrushKind.cutFill:
        final dLo = math.min(datumRadiusM, datumRadiusEndM);
        final dHi = math.max(datumRadiusM, datumRadiusEndM);
        return (
          lo: math.min(groundLoM, dLo),
          hi: math.max(groundHiM, dHi),
        );
    }
  }

  /// Compose this brush onto [density] at body-fixed point [p].
  ///
  /// Returns [density] untouched outside [boundingRadiusM].
  double apply(double density, Vector3 p) {
    final w = p - centreBF;
    if (w.lengthSquared > boundingRadiusM * boundingRadiusM) return density;

    // ---- Levelling kinds ------------------------------------------------
    //
    // These do not carve a shape out of the field; they REPLACE it with the
    // distance to a target surface, blended out over the falloff ring. That is
    // what makes them cut and fill in one operation — above the datum the
    // replacement is positive (air where rock was), below it negative (rock
    // where air was) — and it is why they take a target RADIUS rather than a
    // depth offset. The blend keeps the seam continuous, so no isosurface
    // appears at the pad edge.
    if (kind == TerrainBrushKind.pad ||
        kind == TerrainBrushKind.padBox ||
        kind == TerrainBrushKind.padPoly ||
        kind == TerrainBrushKind.steppedPit ||
        kind == TerrainBrushKind.cutFill) {
      final ({double weight, double datum})? level = _levelAt(p, w);
      if (level == null || level.weight <= 0) return density;
      final target = p.length - level.datum;
      return density * (1 - level.weight) + target * level.weight;
    }

    var d = density;
    if (kind == TerrainBrushKind.crater && rimHeightM > 0) {
      // Rim first, bowl second: the crest is material thrown UP around the
      // hole, so the excavation has to win wherever the two overlap.
      //
      // The rim is a CONFORMAL ground lift, not a solid torus. Near the
      // surface, density magnitude IS metres along the radial, so subtracting
      // a ring-shaped bump raises the LOCAL surface by that bump — wherever
      // that surface happens to be. A torus seated on the contact plane was
      // the previous design, and on real DEM relief it floated: any hillside
      // (or just rough ground at crater scale) drops away from the plane by
      // more than the rim height, leaving the ring hanging in air on the low
      // side. Anchoring to the local density can't detach by construction.
      final along = w.dot(_axis);
      final lateral = (w - _axis * along).length;
      final t = 1.0 - (lateral - radiusM).abs() / _rimWidth;
      if (t > 0) {
        final s = t * t * (3 - 2 * t); // smooth crest, zero-sloped edges
        d -= rimHeightM * s;
      }
    }
    return math.max(d, -_bowlSdf(w));
  }

  /// Blend weight and target surface radius for the levelling kinds at [p]
  /// ([w] is `p - centreBF`). Null when this brush does not level.
  ({double weight, double datum})? _levelAt(Vector3 p, Vector3 w) {
    switch (kind) {
      case TerrainBrushKind.pad:
        // Lateral distance measured in the tangent plane, so a pad stays round
        // on the ground rather than being foreshortened by the body's curve.
        final lateral = _lateral(w);
        return (weight: _falloffWeight(lateral, radiusM), datum: datumRadiusM);

      case TerrainBrushKind.padPoly:
        final poly = _poly2;
        if (poly.length < 6) return null;
        final flat = w - _axis * w.dot(_axis);
        return (
          weight: _falloffWeight(
              _distanceOutside(poly, flat.dot(_t1), flat.dot(_t2)), 0),
          datum: datumRadiusM,
        );

      case TerrainBrushKind.padBox:
        // Distance OUTSIDE the oriented rectangle, measured in the tangent
        // plane: zero anywhere inside it, growing beyond its edges. Feeding
        // that to the falloff with a zero core gives weight 1 across the whole
        // lot and an even ease-off past its boundary.
        final end = endBF;
        if (end == null) return null;
        final fwd = end - centreBF;
        final halfDepth = fwd.length;
        if (halfDepth <= 1e-9) return null;
        final up = _axis;
        // Project into the tangent plane so the rectangle lies on the ground
        // rather than being foreshortened by the body's curve.
        final flat = w - up * w.dot(up);
        final f = (fwd - up * fwd.dot(up)).normalized;
        final side = up.cross(f);
        final along = (flat.dot(f)).abs() - halfDepth;
        final across = (flat.dot(side)).abs() - radiusM;
        final outside = math.sqrt(math.max(along, 0.0) * math.max(along, 0.0) +
            math.max(across, 0.0) * math.max(across, 0.0));
        return (weight: _falloffWeight(outside, 0), datum: datumRadiusM);

      case TerrainBrushKind.steppedPit:
        final lateral = _lateral(w);
        if (lateral > radiusM + falloffM) return (weight: 0, datum: datumRadiusM);
        // Benches step DOWN toward the centre. Quantising the normalised
        // radius gives each terrace a level floor and a vertical riser, which
        // is what a worked pit looks like; a smooth cone would read as a
        // sinkhole.
        final u = (lateral / radiusM).clamp(0.0, 1.0);
        final step = (u * benches).ceil().clamp(1, benches);
        final cut = depthM * (1 - (step - 1) / benches);
        return (
          weight: _falloffWeight(lateral, radiusM),
          datum: datumRadiusM - cut,
        );

      case TerrainBrushKind.cutFill:
        final end = endBF;
        if (end == null) return null;
        // centreBF is the midpoint, so the start mirrors the end through it.
        final start = centreBF * 2 - end;
        final axis = end - start;
        final len2 = axis.lengthSquared;
        if (len2 <= 1e-9) return null;
        final t = ((p - start).dot(axis) / len2).clamp(0.0, 1.0);
        final onAxis = start + axis * t;
        // Horizontal offset only. A 3D distance would make the corridor a
        // capsule, so a sample well above or below the carriageway would fall
        // outside it and never get levelled — the field would keep its natural
        // value there and the graded surface would be cut off at the ends.
        // Stripping the LOCAL radial component makes it a radially extruded
        // prism instead, which is what a road cutting actually is.
        final v = p - onAxis;
        final up = p.normalized;
        final lateral = (v - up * v.dot(up)).length;
        return (
          weight: _falloffWeight(lateral, radiusM),
          datum: datumRadiusM + (datumRadiusEndM - datumRadiusM) * t,
        );

      case TerrainBrushKind.sphere:
      case TerrainBrushKind.crater:
        return null;
    }
  }

  /// Tangent basis at the pad centre, and the footprint projected into it.
  /// Built once — [apply] runs per voxel, and re-projecting the outline on
  /// every sample would dominate the meshing cost.
  late final Vector3 _t1 = () {
    final seed = _axis.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
    return _axis.cross(seed).normalized;
  }();
  late final Vector3 _t2 = _axis.cross(_t1);
  late final List<double> _poly2 = () {
    final out = <double>[];
    for (final v in polygonBF) {
      final w = v - centreBF;
      final flat = w - _axis * w.dot(_axis);
      out..add(flat.dot(_t1))..add(flat.dot(_t2));
    }
    return out;
  }();

  /// Distance from (x, y) to the polygon [p] (coordinate pairs): zero anywhere
  /// inside it, the distance to the nearest edge outside.
  static double _distanceOutside(List<double> p, double x, double y) {
    final n = p.length ~/ 2;
    var inside = false;
    var best = double.infinity;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final xi = p[i * 2], yi = p[i * 2 + 1];
      final xj = p[j * 2], yj = p[j * 2 + 1];
      if ((yi > y) != (yj > y) &&
          x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
      final ex = xj - xi, ey = yj - yi;
      final len2 = ex * ex + ey * ey;
      final t = len2 <= 1e-12
          ? 0.0
          : (((x - xi) * ex + (y - yi) * ey) / len2).clamp(0.0, 1.0);
      final dx = x - (xi + ex * t), dy = y - (yi + ey * t);
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < best) best = d;
    }
    return inside ? 0.0 : best;
  }

  /// Distance from the brush axis, measured perpendicular to it.
  double _lateral(Vector3 w) {
    final along = w.dot(_axis);
    return (w - _axis * along).length;
  }

  /// 1 inside [core], easing to 0 at `core + falloffM`. Smoothstep so the
  /// levelled ground meets the natural ground with a matching slope — a linear
  /// ramp would leave a visible crease at both ends of the blend.
  double _falloffWeight(double lateral, double core) {
    if (lateral <= core) return 1;
    if (falloffM <= 0) return 0;
    final t = ((lateral - core) / falloffM).clamp(0.0, 1.0);
    final s = 1 - t;
    return s * s * (3 - 2 * s);
  }

  /// Signed distance to the excavated bowl. [w] is relative to [centreBF].
  double _bowlSdf(Vector3 w) =>
      (w - _axis * _bowlOffset).length - _bowlRadius;

  @override
  String toString() => 'TerrainBrush(${kind.name}, r=${radiusM.toStringAsFixed(1)}m, '
      'd=${depthM.toStringAsFixed(1)}m @ $centreBF)';
}
