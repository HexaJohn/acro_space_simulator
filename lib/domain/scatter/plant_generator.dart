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
import 'prop_mesh.dart';
import 'prop_model.dart';
import 'prop_random.dart';

/// Ground cover. These are the props that get scattered by the tens of
/// thousands, so every one of them is built to a much tighter triangle budget
/// than a tree — a grass tuft that costs 200 triangles is a grass tuft you
/// cannot afford a field of.
enum PlantSpecies {
  /// A splayed tuft of blades. The workhorse of any vegetated surface.
  grassTuft,

  /// Arching pinnate fronds from a common crown.
  fern,

  /// A small woody stem carrying a ball of leaf cards.
  shrub,

  /// Tall, near-vertical, narrow — wetland edges.
  reeds,
}

/// Recipe for one ground-cover plant.
class PlantParams {
  const PlantParams({
    required this.species,
    required this.seed,
    required this.heightM,
    required this.bladeCount,
    required this.bladeWidthM,
    required this.spreadRad,
    required this.droopRad,
    required this.stemRadiusM,
  });

  final PlantSpecies species;
  final int seed;

  /// Height of the tallest blade/frond (m).
  final double heightM;

  /// Blades, fronds or leaf cards at [PropLod.lod0].
  final int bladeCount;

  /// Blade half-width at its widest (m).
  final double bladeWidthM;

  /// How far from vertical the outermost blades splay (rad).
  final double spreadRad;

  /// Additional sag accumulated along a blade (rad).
  final double droopRad;

  /// Woody stem radius (m); zero for species with no solid geometry at all.
  final double stemRadiusM;

  factory PlantParams.of(
    PlantSpecies species, {
    int seed = 1,
    double? heightM,
  }) {
    switch (species) {
      case PlantSpecies.grassTuft:
        return PlantParams(
          species: species,
          seed: seed,
          heightM: heightM ?? 0.38,
          bladeCount: 11,
          bladeWidthM: 0.010,
          spreadRad: 0.62,
          droopRad: 0.85,
          stemRadiusM: 0.0,
        );
      case PlantSpecies.fern:
        return PlantParams(
          species: species,
          seed: seed,
          heightM: heightM ?? 0.62,
          bladeCount: 7,
          bladeWidthM: 0.075,
          spreadRad: 0.75,
          droopRad: 0.70,
          stemRadiusM: 0.0,
        );
      case PlantSpecies.shrub:
        return PlantParams(
          species: species,
          seed: seed,
          heightM: heightM ?? 0.95,
          bladeCount: 9,
          bladeWidthM: 0.26, // leaf-card size for this species
          spreadRad: 0.95,
          droopRad: 0.0,
          stemRadiusM: 0.022,
        );
      case PlantSpecies.reeds:
        return PlantParams(
          species: species,
          seed: seed,
          heightM: heightM ?? 1.45,
          bladeCount: 9,
          bladeWidthM: 0.014,
          spreadRad: 0.20,
          droopRad: 0.40,
          stemRadiusM: 0.0,
        );
    }
  }

  PlantParams copyWith({int? seed, double? heightM}) {
    final h = heightM ?? this.heightM;
    final k = h / this.heightM;
    return PlantParams(
      species: species,
      seed: seed ?? this.seed,
      heightM: h,
      bladeCount: bladeCount,
      bladeWidthM: bladeWidthM * k,
      spreadRad: spreadRad,
      droopRad: droopRad,
      stemRadiusM: stemRadiusM * k,
    );
  }
}

/// Per-LOD budget for ground cover.
///
/// The coarsest mesh level abandons individual blades entirely and draws a
/// couple of crossed cards wearing the blade atlas cell. That is not a
/// compromise — at the distance LOD2 covers, a real tuft occupies a handful of
/// pixels, and crossed cards reproduce it more faithfully (and far more
/// cheaply) than four surviving ribbons ever could.
class _Budget {
  const _Budget({
    required this.bladeFraction,
    required this.segments,
    required this.asCards,
    required this.cardPlanes,
  });

  final double bladeFraction;
  final int segments;
  final bool asCards;
  final int cardPlanes;

  static const Map<PropLod, _Budget> forLod = {
    PropLod.lod0:
        _Budget(bladeFraction: 1.0, segments: 4, asCards: false, cardPlanes: 0),
    PropLod.lod1:
        _Budget(bladeFraction: 0.55, segments: 3, asCards: false, cardPlanes: 0),
    PropLod.lod2:
        _Budget(bladeFraction: 0.0, segments: 1, asCards: true, cardPlanes: 2),
    PropLod.billboard:
        _Budget(bladeFraction: 0.0, segments: 1, asCards: true, cardPlanes: 1),
  };
}

/// Build every LOD plus the imposter for one plant.
PropLodSet buildPlantLodSet(PlantParams params) {
  final build = _PlantBuild(params, PropLod.lod0, withImposter: true);
  final model0 = build.run();
  final bounds = model0.bounds;
  return PropLodSet(
    levels: [
      model0,
      _PlantBuild(params, PropLod.lod1).run(),
      _PlantBuild(params, PropLod.lod2).run(),
    ],
    imposter: build.imposter!.build(
      widthM: math.max(bounds.radiusM * 2, 0.02),
      heightM: math.max(bounds.heightM, 0.02),
    ),
    bounds: bounds,
  );
}

/// Build one plant at one detail level.
PropModel buildPlant(PlantParams params, {PropLod lod = PropLod.lod0}) =>
    _PlantBuild(params, lod).run();

class _PlantBuild {
  _PlantBuild(this.p, this.lod, {bool withImposter = false})
      : budget = _Budget.forLod[lod]!,
        rnd = PropRandom(p.seed),
        imposter = withImposter ? ImposterBuilder() : null;

  final PlantParams p;
  final PropLod lod;
  final _Budget budget;
  final PropRandom rnd;
  final ImposterBuilder? imposter;
  final PropBuilder b = PropBuilder();

  /// Which atlas cell this species' cards and ribbons sample.
  FoliageCell get _cell => switch (p.species) {
        PlantSpecies.fern => FoliageCell.frond,
        PlantSpecies.shrub => FoliageCell.broadleaf,
        _ => FoliageCell.blade,
      };

  PropModel run() {
    b.roll(rnd.range(0, 2 * math.pi));

    if (budget.asCards) {
      _asCards();
    } else {
      switch (p.species) {
        case PlantSpecies.grassTuft:
        case PlantSpecies.reeds:
        case PlantSpecies.fern:
          _splay();
        case PlantSpecies.shrub:
          _shrub();
      }
    }

    final model = b.build();
    // One blob for the imposter: ground cover is a single mass at any distance
    // where the imposter is in play. Sized from what was actually built, not
    // from the nominal height — see [_measuredExtent].
    final bounds = model.bounds;
    imposter?.blob(
      x: 0,
      y: 0,
      z: bounds.centre.z,
      radius: math.max(bounds.radiusM, bounds.heightM * 0.5),
    );
    return model;
  }

  /// The coarse representation: crossed cards standing on the ground.
  void _asCards() {
    final (u0, v0, u1, v1) = FoliageAtlas.uv(_cell, mirror: rnd.chance(0.5));
    final extent = _measuredExtent();
    // Ground cover is wider than tall; a square card would leave the tuft
    // looking like a hedge at the exact distance the swap happens.
    b.foliage.crossCards(
      width: math.max(extent.radiusM * 2, extent.heightM * 0.35),
      height: extent.heightM,
      planes: budget.cardPlanes,
      u0: u0,
      v0: v0,
      u1: u1,
      v1: v1,
    );
  }

  /// The size the DETAILED plant actually occupies.
  ///
  /// A tuft never reaches its nominal [PlantParams.heightM]: its blades splay
  /// outward and then droop, so the tallest one tops out well short. Sizing the
  /// coarse card off the nominal height therefore made the LOD2 tuft a third
  /// taller than the LOD0 one it replaces — a very visible grow-on-switch
  /// across a whole meadow. Growing the detailed version once and measuring it
  /// costs a few hundred floats and cannot drift out of step the way a
  /// hand-tuned fudge factor per species would.
  PropBounds _measuredExtent() => _PlantBuild(p, PropLod.lod0).run().bounds;

  /// A crown of blades or fronds fanning out from the base.
  void _splay() {
    final count = math.max(3, (p.bladeCount * budget.bladeFraction).round());
    for (var i = 0; i < count; i++) {
      final sub = rnd.fork(i);
      b.push();
      // Golden-angle spin plus a small radial offset: blades all rising from
      // one mathematical point read as a firework, not a plant.
      b.roll(goldenAngle * i + sub.jitter(0.3));
      b.move(Vector3(sub.range(0.0, p.heightM * 0.07), 0, 0));
      b.pitch(p.spreadRad * sub.range(0.25, 1.0));
      _blade(
        lengthM: p.heightM * sub.range(0.62, 1.0),
        halfWidthM: p.bladeWidthM * sub.range(0.8, 1.25),
        droop: p.droopRad * sub.range(0.6, 1.4),
        rnd: sub,
      );
      b.pop();
    }
  }

  /// A woody stem carrying a ball of leaf cards.
  void _shrub() {
    final stemH = p.heightM * 0.42;
    b.solid.taperedCylinder(
      height: stemH,
      radiusBottom: p.stemRadiusM,
      radiusTop: p.stemRadiusM * 0.5,
      sides: lod == PropLod.lod0 ? 5 : 4,
      vPerMetre: 3.0,
      capEnd: true,
    );

    final count = math.max(3, (p.bladeCount * budget.bladeFraction).round());
    for (var i = 0; i < count; i++) {
      final sub = rnd.fork(i);
      b.push();
      b.forward(stemH * sub.range(0.55, 1.0));
      b.roll(goldenAngle * i + sub.jitter(0.4));
      b.pitch(p.spreadRad * sub.range(0.3, 1.0));
      b.move(Vector3(0, 0, p.heightM * sub.range(0.05, 0.22)));
      final size = p.bladeWidthM * sub.range(0.75, 1.3);
      final (u0, v0, u1, v1) = FoliageAtlas.uv(_cell, mirror: sub.chance(0.5));
      b.foliage.crossCards(
        width: size,
        height: size,
        planes: lod == PropLod.lod0 ? 2 : 1,
        u0: u0,
        v0: v0,
        u1: u1,
        v1: v1,
        baseOffset: -size * 0.5,
      );
      b.pop();
    }
  }

  /// One blade or frond: a ribbon that arcs over under its own weight.
  void _blade({
    required double lengthM,
    required double halfWidthM,
    required double droop,
    required PropRandom rnd,
  }) {
    final segs = budget.segments;
    final spine = <Vector3>[];
    final widths = <double>[];
    var lp = Vector3.zero;
    var lq = Quaternion.identity;
    // Bend accelerates toward the tip — a blade is stiff at the sheath and
    // limp at the end, so a constant per-segment angle looks like wire.
    for (var i = 0; i <= segs; i++) {
      final f = i / segs;
      spine.add(lp);
      widths.add(_widthProfile(f) * halfWidthM);
      if (i == segs) break;
      final bend = droop / segs * (0.35 + 1.6 * f);
      lq = (lq * Quaternion.axisAngle(Vector3.unitX, bend)).normalized;
      lp = lp + lq.rotate(Vector3(0, 0, lengthM / segs));
    }
    final (u0, v0, u1, v1) = FoliageAtlas.uv(_cell, mirror: rnd.chance(0.5));
    b.foliage.ribbon(spine, widths, u0: u0, u1: u1, v0: v0, v1: v1);
  }

  /// Half-width along a blade, 0..1 -> 0..1.
  double _widthProfile(double f) => switch (p.species) {
        // Grass and reeds are widest near the base and taper to a point.
        PlantSpecies.grassTuft ||
        PlantSpecies.reeds =>
          math.max(0.0, 1.0 - math.pow(f, 1.6).toDouble()),
        // A frond is pinnate: narrow at the stalk, full in the middle, pointed.
        _ => math.sin(math.pi * math.pow(f, 0.7).toDouble()),
      };
}
