// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import 'foliage_atlas.dart';
import 'mesh_builder.dart';
import 'prop_imposter.dart';
import 'prop_model.dart';
import 'prop_random.dart';

/// The growth habits the generator knows how to draw. Each is a genuinely
/// different topology, not a parameter tweak: a conifer keeps one leader with
/// whorled side limbs, a broadleaf forks repeatedly, a palm has no branches at
/// all, and a snag is a broadleaf skeleton with its canopy gone.
enum TreeSpecies { broadleaf, conifer, palm, deadSnag }

/// Recipe for one tree. Everything is metres and radians; [seed] alone decides
/// which individual of the species you get.
class TreeParams {
  const TreeParams({
    required this.species,
    required this.seed,
    required this.heightM,
    required this.trunkRadiusM,
    required this.branchLevels,
    required this.branchesPerLimb,
    required this.branchPitch,
    required this.lengthFalloff,
    required this.radiusFalloff,
    required this.tropism,
    required this.wobble,
    required this.foliageSizeM,
    required this.foliageDensity,
    required this.leanRad,
  });

  final TreeSpecies species;
  final int seed;

  /// Overall height (m). Every other length scales off this.
  final double heightM;

  /// Trunk radius at the base (m).
  final double trunkRadiusM;

  /// Recursion depth: how many times a limb splits into child limbs.
  final int branchLevels;

  /// Child limbs per limb (jittered by +/-1 for irregularity).
  final int branchesPerLimb;

  /// Angle a child limb leaves its parent at (rad). Near `pi/2` gives the
  /// horizontal tiers of a spruce; ~0.6 gives a broadleaf's reaching fork.
  final double branchPitch;

  /// Child length as a fraction of the parent's.
  final double lengthFalloff;

  /// Child base radius as a fraction of the parent's.
  final double radiusFalloff;

  /// How hard a limb bends back toward vertical over its length (rad).
  /// Negative droops — conifer limbs and palm fronds sag.
  final double tropism;

  /// Random per-segment deviation (rad); the difference between a drawn tree
  /// and a grown one.
  final double wobble;

  /// Foliage cluster size (m) — the width of one cross-card cluster.
  final double foliageSizeM;

  /// Foliage amount, 0..1. Scales the number of clusters placed.
  final double foliageDensity;

  /// Whole-tree lean from vertical (rad).
  final double leanRad;

  TreeParams copyWith({
    int? seed,
    double? heightM,
    double? foliageDensity,
    double? leanRad,
  }) =>
      TreeParams(
        species: species,
        seed: seed ?? this.seed,
        heightM: heightM ?? this.heightM,
        trunkRadiusM: trunkRadiusM * (heightM ?? this.heightM) / this.heightM,
        branchLevels: branchLevels,
        branchesPerLimb: branchesPerLimb,
        branchPitch: branchPitch,
        lengthFalloff: lengthFalloff,
        radiusFalloff: radiusFalloff,
        tropism: tropism,
        wobble: wobble,
        foliageSizeM: foliageSizeM * (heightM ?? this.heightM) / this.heightM,
        foliageDensity: foliageDensity ?? this.foliageDensity,
        leanRad: leanRad ?? this.leanRad,
      );

  /// Field-tested defaults per species. Start here and vary [seed]/[heightM].
  factory TreeParams.of(TreeSpecies species, {int seed = 1, double? heightM}) {
    switch (species) {
      case TreeSpecies.broadleaf:
        final h = heightM ?? 12.0;
        return TreeParams(
          species: species,
          seed: seed,
          heightM: h,
          trunkRadiusM: h * 0.024,
          branchLevels: 4,
          branchesPerLimb: 3,
          branchPitch: 0.62,
          lengthFalloff: 0.72,
          radiusFalloff: 0.62,
          tropism: 0.42,
          wobble: 0.16,
          foliageSizeM: h * 0.20,
          foliageDensity: 1.0,
          leanRad: 0.04,
        );
      case TreeSpecies.conifer:
        final h = heightM ?? 18.0;
        return TreeParams(
          species: species,
          seed: seed,
          heightM: h,
          trunkRadiusM: h * 0.017,
          branchLevels: 2,
          branchesPerLimb: 2,
          // Nearly horizontal, then drooping — the spruce silhouette.
          branchPitch: 1.32,
          lengthFalloff: 0.48,
          radiusFalloff: 0.45,
          tropism: -0.55,
          wobble: 0.10,
          // Needle sprays have to be a decent fraction of a whole branch:
          // undersized, they leave the limbs showing as bare spars and the tree
          // reads as a dead pole with wisps on it rather than a spruce.
          foliageSizeM: h * 0.13,
          foliageDensity: 1.0,
          leanRad: 0.015,
        );
      case TreeSpecies.palm:
        final h = heightM ?? 9.0;
        return TreeParams(
          species: species,
          seed: seed,
          heightM: h,
          trunkRadiusM: h * 0.018,
          branchLevels: 0, // no branching at all; the crown is fronds
          branchesPerLimb: 0,
          branchPitch: 1.05,
          lengthFalloff: 1.0,
          radiusFalloff: 1.0,
          tropism: 0.0,
          wobble: 0.05,
          foliageSizeM: h * 0.46, // frond length
          foliageDensity: 1.0,
          leanRad: 0.20, // palms lean, and it reads as wind history
        );
      case TreeSpecies.deadSnag:
        final h = heightM ?? 8.0;
        return TreeParams(
          species: species,
          seed: seed,
          heightM: h,
          trunkRadiusM: h * 0.030,
          branchLevels: 3,
          branchesPerLimb: 2,
          branchPitch: 0.95,
          lengthFalloff: 0.60,
          radiusFalloff: 0.55,
          tropism: 0.10,
          wobble: 0.34, // gnarled
          foliageSizeM: 0.0,
          foliageDensity: 0.0,
          leanRad: 0.10,
        );
    }
  }
}

/// Per-LOD generation budget. LOD is applied at GENERATION time — a coarser
/// level regrows the tree with shallower recursion and fatter, fewer foliage
/// cards, rather than decimating a finished mesh. Regrowing keeps the
/// silhouette (which is what the eye tracks at range); a decimator would eat
/// the thin outer limbs first and hollow it out.
class _Budget {
  const _Budget({
    required this.trunkSides,
    required this.depthCut,
    required this.spineSegments,
    required this.foliagePlanes,
    required this.foliageScale,
    required this.foliageFraction,
    required this.limbStretch,
  });

  final int trunkSides;

  /// Levels of recursion removed from [TreeParams.branchLevels].
  final int depthCut;
  final int spineSegments;
  final int foliagePlanes;

  /// Foliage cards grow as they get fewer, so the canopy keeps its volume.
  final double foliageScale;

  /// Extra thinning of the clusters on each SURVIVING limb.
  ///
  /// Deliberately mild, because [depthCut] has already removed most of them —
  /// a level that drops two generations of branches has roughly a sixth of the
  /// tips left, and multiplying that by another 0.2 leaves a handful of tips
  /// rolling dice for a cluster each. Some trees then came out bald.
  final double foliageFraction;

  /// Terminal limbs are lengthened when recursion has been cut, so the crown
  /// keeps its REACH. Without this a species whose silhouette is its branches
  /// rather than its leaves — a dead snag above all — visibly shrinks inward at
  /// every LOD switch, because the outer generation of limbs that defined the
  /// spread is exactly what the cut removed. Same trade as [foliageScale]:
  /// fewer, bigger parts holding the same envelope.
  final double limbStretch;

  static const Map<PropLod, _Budget> forLod = {
    PropLod.lod0: _Budget(
      trunkSides: 8,
      depthCut: 0,
      spineSegments: 5,
      foliagePlanes: 3,
      foliageScale: 1.0,
      foliageFraction: 1.0,
      limbStretch: 1.0,
    ),
    PropLod.lod1: _Budget(
      trunkSides: 6,
      depthCut: 1,
      spineSegments: 3,
      foliagePlanes: 2,
      foliageScale: 1.75,
      foliageFraction: 0.8,
      limbStretch: 1.22,
    ),
    PropLod.lod2: _Budget(
      trunkSides: 4,
      depthCut: 2,
      spineSegments: 2,
      foliagePlanes: 2,
      foliageScale: 3.1,
      foliageFraction: 0.75,
      limbStretch: 1.5,
    ),
    PropLod.billboard: _Budget(
      trunkSides: 3,
      depthCut: 3,
      spineSegments: 1,
      foliagePlanes: 1,
      foliageScale: 4.0,
      foliageFraction: 0.5,
      limbStretch: 1.7,
    ),
  };
}

/// Build every LOD plus the matching imposter for one tree.
PropLodSet buildTreeLodSet(TreeParams params) {
  final lod0 = _TreeBuild(params, PropLod.lod0, withImposter: true);
  final model0 = lod0.run();
  final bounds = model0.bounds;
  return PropLodSet(
    levels: [
      model0,
      _TreeBuild(params, PropLod.lod1).run(),
      _TreeBuild(params, PropLod.lod2).run(),
    ],
    imposter: lod0.imposter!.build(
      // A canopy is wider than it is deep-ish; use the true horizontal extent
      // so the card never crops the silhouette it is standing in for.
      widthM: math.max(bounds.radiusM * 2, 0.2),
      heightM: math.max(bounds.heightM, 0.2),
    ),
    bounds: bounds,
  );
}

/// Build one tree at one detail level.
PropModel buildTree(TreeParams params, {PropLod lod = PropLod.lod0}) =>
    _TreeBuild(params, lod).run();

/// One generation pass. Holds the shared turtle, the RNG, and (for LOD0) the
/// imposter recorder, so the recursive limb walk can feed all three.
class _TreeBuild {
  _TreeBuild(this.p, this.lod, {bool withImposter = false})
      : budget = _Budget.forLod[lod]!,
        rnd = PropRandom(p.seed),
        imposter = withImposter ? ImposterBuilder() : null;

  final TreeParams p;
  final PropLod lod;
  final _Budget budget;
  final PropRandom rnd;
  final ImposterBuilder? imposter;
  final PropBuilder b = PropBuilder();

  int get maxDepth =>
      math.max(0, p.branchLevels - budget.depthCut);

  PropModel run() {
    // Whole-tree lean, in a random compass direction.
    b.roll(rnd.range(0, 2 * math.pi));
    b.pitch(p.leanRad * rnd.range(0.4, 1.0));

    switch (p.species) {
      case TreeSpecies.broadleaf:
      case TreeSpecies.deadSnag:
        _forking();
      case TreeSpecies.conifer:
        _conifer();
      case TreeSpecies.palm:
        _palm();
    }
    return b.build();
  }

  // ---- Habits -------------------------------------------------------------

  /// Broadleaf / snag: a short trunk that forks, and forks again.
  void _forking() {
    final trunkLen = p.heightM * (p.species == TreeSpecies.deadSnag ? 0.52 : 0.44);
    _limb(
      depth: 0,
      lengthM: trunkLen,
      radius0: p.trunkRadiusM,
      rnd: rnd.fork(1),
    );
  }

  /// Conifer: ONE leader running the full height, with whorls of side limbs
  /// whose length falls off toward the top. The conical envelope comes from
  /// that falloff, not from any explicit cone.
  void _conifer() {
    final sides = budget.trunkSides;
    final segs = math.max(3, budget.spineSegments + 3);
    final spine = <Vector3>[];
    final frames = <Quaternion>[];
    final radii = <double>[];
    _walkSpine(
      segments: segs,
      lengthM: p.heightM,
      radius0: p.trunkRadiusM,
      radiusTipFrac: 0.02,
      tropism: 0.05,
      wobble: p.wobble * 0.4,
      rnd: rnd.fork(2),
      spine: spine,
      frames: frames,
      radii: radii,
    );
    b.solid.tube(spine, radii, sides: sides, vPerMetre: 0.45, capEnd: true);
    _recordStroke(spine.first, spine.last, radii.first, radii.last);

    // Whorls: rings of limbs every so often up the trunk, starting a third of
    // the way up (below that a conifer is bare trunk).
    final whorls = math.max(3, 6 - budget.depthCut * 2);
    final perWhorl = math.max(3, 5 - budget.depthCut);
    final whorlRnd = rnd.fork(3);
    for (var w = 0; w < whorls; w++) {
      final t = 0.32 + 0.66 * (w / (whorls - 1).clamp(1, 99));
      final idx = (t * (spine.length - 1)).round().clamp(0, spine.length - 1);
      // Longest at the bottom whorl, shrinking to almost nothing at the tip.
      final limbLen = p.heightM * 0.34 * math.pow(1.0 - t, 0.75).toDouble();
      if (limbLen < 0.05) continue;
      for (var k = 0; k < perWhorl; k++) {
        b.push();
        b.move(spine[idx]);
        b.turn(frames[idx]);
        b.roll(goldenAngle * (w * perWhorl + k) + whorlRnd.jitter(0.25));
        b.pitch(p.branchPitch + whorlRnd.jitter(0.14));
        _limb(
          // One level short of terminal, so a side limb forks once before its
          // needles — a single unforked spar reads as a bottle brush.
          depth: math.max(0, maxDepth - 1),
          lengthM: limbLen,
          radius0: radii[idx] * 0.42,
          rnd: whorlRnd.fork(w * 31 + k),
          foliageAlongLimb: true,
        );
        b.pop();
      }
    }
  }

  /// Palm: a single arcing trunk and a crown of fronds. No recursion at all.
  void _palm() {
    final sides = budget.trunkSides;
    final segs = math.max(3, budget.spineSegments + 2);
    final spine = <Vector3>[];
    final frames = <Quaternion>[];
    final radii = <double>[];
    _walkSpine(
      segments: segs,
      lengthM: p.heightM,
      radius0: p.trunkRadiusM,
      radiusTipFrac: 0.62, // palms barely taper
      // Negative tropism on an already-leaning trunk gives the classic arc.
      tropism: -0.28,
      wobble: p.wobble,
      rnd: rnd.fork(4),
      spine: spine,
      frames: frames,
      radii: radii,
    );
    b.solid.tube(spine, radii, sides: sides, vPerMetre: 1.6, capEnd: true);
    _recordStroke(spine.first, spine.last, radii.first, radii.last);

    // Crown at the tip.
    b.push();
    b.move(spine.last);
    b.turn(frames.last);
    // Divide by the depth cut as well as the fraction: a palm has no branch
    // recursion for depthCut to bite on, so without this the crown stayed at
    // full frond count through every level and LOD2 cost as much as LOD0.
    final fronds =
        math.max(3, (12 * budget.foliageFraction / (1 + budget.depthCut)).round());
    final frondRnd = rnd.fork(5);
    for (var i = 0; i < fronds; i++) {
      b.push();
      b.roll(goldenAngle * i + frondRnd.jitter(0.2));
      // Fronds spray outward and then sag under their own weight.
      b.pitch(frondRnd.range(0.55, 1.35));
      _frond(
        lengthM: p.foliageSizeM * frondRnd.range(0.82, 1.15),
        halfWidthM: p.foliageSizeM * 0.16,
        rnd: frondRnd,
      );
      b.pop();
    }
    b.pop();

    // One canopy blob for the imposter — a palm crown reads as a single mass.
    final crown = b.toMesh(spine.last);
    imposter?.blob(
      x: crown.x,
      y: crown.y,
      z: crown.z,
      radius: p.foliageSizeM * 0.85,
    );
  }

  // ---- Limb recursion -----------------------------------------------------

  /// Grow one limb from the current turtle frame, then recurse.
  ///
  /// [foliageAlongLimb] distributes clusters down the whole limb (needles on a
  /// conifer branch) instead of bunching them at the tip (a broadleaf's leaves).
  void _limb({
    required int depth,
    required double lengthM,
    required double radius0,
    required PropRandom rnd,
    bool foliageAlongLimb = false,
  }) {
    if (lengthM < 0.02 || radius0 < 0.0008) return;

    // Thin outer limbs need fewer sides; an 8-gon on a 2 cm twig is pure waste.
    final sides = math.max(3, budget.trunkSides - depth);
    final segs = math.max(1, budget.spineSegments - (depth > 1 ? 1 : 0));
    final terminal = depth >= maxDepth;
    // A limb that is terminal only because recursion was cut short stands in
    // for the generation of limbs below it, so it reaches further.
    if (terminal && depth > 0 && budget.limbStretch != 1.0) {
      lengthM *= budget.limbStretch;
    }
    // A snag's limbs end broken — no taper to a point, so the tip reads as a
    // snapped stub rather than a twig.
    final broken = p.species == TreeSpecies.deadSnag && terminal;

    final spine = <Vector3>[];
    final frames = <Quaternion>[];
    final radii = <double>[];
    _walkSpine(
      segments: segs,
      lengthM: lengthM,
      radius0: radius0,
      radiusTipFrac: broken ? 0.55 : (terminal ? 0.14 : 0.34),
      tropism: p.tropism * (depth == 0 ? 0.35 : 1.0),
      wobble: p.wobble,
      rnd: rnd,
      spine: spine,
      frames: frames,
      radii: radii,
    );
    b.solid.tube(
      spine,
      radii,
      sides: sides,
      vPerMetre: 0.4 + depth * 0.35,
      capEnd: broken || terminal,
    );
    _recordStroke(spine.first, spine.last, radii.first, radii.last);

    if (terminal) {
      if (p.foliageDensity > 0 && p.foliageSizeM > 0) {
        if (foliageAlongLimb) {
          _needleRun(spine, frames, rnd);
        } else {
          _cluster(spine, frames, rnd);
        }
      }
      return;
    }

    // Children. Attach in the upper half of the parent — a limb sprouting from
    // its own base looks like two trunks, not a fork.
    final count = math.max(
      2,
      p.branchesPerLimb + (rnd.chance(0.35) ? 1 : 0) - (rnd.chance(0.2) ? 1 : 0),
    );
    for (var k = 0; k < count; k++) {
      final t = 0.5 + 0.5 * (k + 1) / count;
      final idx = (t * (spine.length - 1)).round().clamp(1, spine.length - 1);
      final childRnd = rnd.fork(k * 17 + depth);
      b.push();
      b.move(spine[idx]);
      b.turn(frames[idx]);
      b.roll(goldenAngle * k + childRnd.jitter(0.4));
      b.pitch(p.branchPitch * childRnd.range(0.72, 1.3));
      _limb(
        depth: depth + 1,
        lengthM: lengthM * p.lengthFalloff * childRnd.range(0.82, 1.12),
        radius0: radii[idx] * p.radiusFalloff,
        rnd: childRnd,
        foliageAlongLimb: foliageAlongLimb,
      );
      b.pop();
    }
  }

  /// Walk a limb's centreline, filling [spine]/[frames]/[radii] in the CURRENT
  /// frame's coordinates.
  ///
  /// Tropism is applied as a PRE-multiplied rotation (the axis lives in frame
  /// space, not limb space) and the wobble as a post-multiplied one; swapping
  /// them makes the limb corkscrew instead of bending.
  void _walkSpine({
    required int segments,
    required double lengthM,
    required double radius0,
    required double radiusTipFrac,
    required double tropism,
    required double wobble,
    required PropRandom rnd,
    required List<Vector3> spine,
    required List<Quaternion> frames,
    required List<double> radii,
  }) {
    final up = b.upInFrame;
    final step = lengthM / segments;
    var lp = Vector3.zero;
    var lq = Quaternion.identity;
    spine.add(lp);
    frames.add(lq);
    radii.add(radius0);
    for (var i = 1; i <= segments; i++) {
      final t = lq.rotate(Vector3.unitZ);
      final axis = t.cross(up);
      if (axis.length > 1e-6) {
        lq = (Quaternion.axisAngle(axis, tropism / segments) * lq).normalized;
      }
      if (wobble > 0) {
        lq = (lq *
                Quaternion.axisAngle(
                  Vector3(rnd.jitter(1.0), rnd.jitter(1.0), 0),
                  rnd.jitter(wobble) / segments * 2.0,
                ))
            .normalized;
      }
      lp = lp + lq.rotate(Vector3(0, 0, step));
      final f = i / segments;
      spine.add(lp);
      frames.add(lq);
      // Quadratic taper: real limbs are fat at the base and thin fast.
      radii.add(radius0 * (1.0 - (1.0 - radiusTipFrac) * f * f));
    }
  }

  // ---- Foliage ------------------------------------------------------------

  /// A ball of cross-cards at the limb tip — a broadleaf's leaf mass.
  void _cluster(
    List<Vector3> spine,
    List<Quaternion> frames,
    PropRandom rnd,
  ) {
    // Coarser levels keep only a fraction of the tips' clusters and grow the
    // survivors (see [_Budget.foliageScale]) — that pairing is what holds the
    // canopy's apparent volume while the card count collapses.
    if (!rnd.chance(p.foliageDensity * budget.foliageFraction)) return;
    final size = p.foliageSizeM * budget.foliageScale * rnd.range(0.8, 1.2);
    b.push();
    b.move(spine.last);
    b.turn(frames.last);
    // Stand the cluster part-way up: cards that lie flat along a horizontal
    // branch vanish edge-on from above, which is exactly the view a descending
    // craft has.
    b.alignToUp(0.65);
    _cards(size, rnd);
    b.pop();

    final at = b.toMesh(spine.last);
    imposter?.blob(x: at.x, y: at.y, z: at.z, radius: size * 0.5);
  }

  /// Cards spread down the length of a limb — conifer needles, which grow from
  /// the whole branch rather than only its tip.
  void _needleRun(
    List<Vector3> spine,
    List<Quaternion> frames,
    PropRandom rnd,
  ) {
    final steps =
        math.max(3, (spine.length * 1.4 * budget.foliageFraction).round());
    final size = p.foliageSizeM * budget.foliageScale;
    for (var i = 0; i < steps; i++) {
      final f = (i + 0.5) / steps;
      final idx = (f * (spine.length - 1)).round().clamp(0, spine.length - 1);
      b.push();
      b.move(spine[idx]);
      b.turn(frames[idx]);
      b.roll(goldenAngle * i);
      b.alignToUp(0.3);
      _cards(size * (1.15 - 0.45 * f) * rnd.range(0.85, 1.15), rnd);
      b.pop();
      if (i == steps ~/ 2) {
        final at = b.toMesh(spine[idx]);
        imposter?.blob(x: at.x, y: at.y, z: at.z, radius: size * 0.9);
      }
    }
  }

  /// The atlas cell this species' foliage is drawn from.
  FoliageCell get _cell => switch (p.species) {
        TreeSpecies.conifer => FoliageCell.needle,
        TreeSpecies.palm => FoliageCell.frond,
        _ => FoliageCell.broadleaf,
      };

  /// Emit one cluster's cross-cards, centred on the current frame origin.
  /// Half the clusters draw the cell mirrored, so a canopy of identical cards
  /// still reads as varied without a second texture.
  void _cards(double size, PropRandom rnd) {
    final (u0, v0, u1, v1) =
        FoliageAtlas.uv(_cell, mirror: rnd.chance(0.5));
    b.foliage.crossCards(
      width: size,
      height: size,
      planes: budget.foliagePlanes,
      u0: u0,
      v0: v0,
      u1: u1,
      v1: v1,
      baseOffset: -size * 0.5,
    );
  }

  /// One palm frond: a tapering ribbon that arcs over and droops.
  void _frond({
    required double lengthM,
    required double halfWidthM,
    required PropRandom rnd,
  }) {
    final segs = math.max(2, budget.spineSegments + 1);
    final spine = <Vector3>[];
    final widths = <double>[];
    var lp = Vector3.zero;
    var lq = Quaternion.identity;
    final droop = rnd.range(0.16, 0.30);
    for (var i = 0; i <= segs; i++) {
      final f = i / segs;
      spine.add(lp);
      // Fat in the middle, pointed at both ends — a pinnate leaf outline.
      widths.add(halfWidthM * math.sin(math.pi * math.pow(f, 0.65).toDouble()));
      if (i == segs) break;
      // Sag accumulates, so the tip hangs far lower than the base bends.
      lq = (lq * Quaternion.axisAngle(Vector3.unitX, droop)).normalized;
      lp = lp + lq.rotate(Vector3(0, 0, lengthM / segs));
    }
    // The frond cell is drawn to fill its tile lengthwise, so the ribbon maps
    // the cell 1:1 — across for width, along for length.
    final (u0, v0, u1, v1) = FoliageAtlas.uv(
      FoliageCell.frond,
      mirror: rnd.chance(0.5),
    );
    b.foliage.ribbon(spine, widths, u0: u0, u1: u1, v0: v0, v1: v1);
  }

  // ---- Imposter -----------------------------------------------------------

  void _recordStroke(Vector3 a, Vector3 c, double r0, double r1) {
    final im = imposter;
    if (im == null) return;
    final ma = b.toMesh(a), mc = b.toMesh(c);
    im.stroke(
      x0: ma.x,
      y0: ma.y,
      z0: ma.z,
      x1: mc.x,
      y1: mc.y,
      z1: mc.z,
      radius0: r0,
      radius1: r1,
    );
  }
}
