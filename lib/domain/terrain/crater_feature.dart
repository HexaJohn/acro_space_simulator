// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Procedural impact cratering — Stage 3.
///
/// The Moon reads as the Moon because of craters, not because of its fBm. No
/// amount of octave tuning produces a bowl with a raised rim and an ejecta
/// blanket, because those are not what noise makes; they are what a specific
/// physical event makes, repeatedly, at every scale.
///
/// ## Size-frequency distribution
///
/// Real crater populations follow a power law: roughly a hundred times as many
/// craters at a tenth the diameter. That is reproduced here by stacking
/// DECADES — independent lattices, each an order of magnitude finer and
/// proportionally denser — rather than by trying to sample one distribution.
/// Each decade is a jittered grid, so craters are irregularly placed but never
/// clump into unresolvable piles the way pure rejection sampling does.
///
/// ## Shared geometry with deformation
///
/// The radial profile is the same shape `terrain_brush.dart` cuts for a real
/// impact — bowl, raised rim, ejecta falloff. Written once, driven from a hash
/// here and from kinetic energy there, so an ancient crater and a fresh one
/// have the same anatomy.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';
import 'terrain_control.dart';
import 'terrain_feature.dart';

/// Analytic crater field over a body, evaluated per direction.
///
/// Pure and deterministic. Cost is `decades * 27` hash probes per sample, most
/// rejected on the first test — the density check is the cheapest thing in the
/// loop for exactly that reason.
class CraterFeature implements TerrainFeature {
  const CraterFeature({
    required this.seed,
    required this.radiusM,
    this.largestRadiusM = 40000,
    this.decades = 4,
    this.decadeRatio = 4.0,
    this.density = 0.55,
    this.depthRatio = 0.2,
    this.complexTransitionM = 15000,
    this.complexExponent = 0.3,
    this.rimRatio = 0.04,
    this.ejectaReach = 2.5,
    this.spacing = 2.2,
    this.minRadiusM = 0,
  })  : assert(decades > 0),
        assert(decadeRatio > 1),
        assert(density >= 0 && density <= 1);

  final int seed;

  /// Body datum radius (m) — sets the arc-length scale.
  final double radiusM;

  /// Rim radius (m) of the coarsest decade's craters.
  final double largestRadiusM;

  /// How many size decades to stack.
  final int decades;

  /// Size ratio between successive decades. 4 keeps the count growing roughly
  /// as the square of the inverse diameter, which is about right for a
  /// saturated surface.
  final double decadeRatio;

  /// Fraction of lattice cells that actually contain a crater.
  final double density;

  /// Depth as a fraction of DIAMETER for SIMPLE craters — ~1:5 when fresh.
  final double depthRatio;

  /// Diameter (m) at which craters stop being simple bowls.
  ///
  /// Above it depth grows far more slowly than diameter: the walls slump, the
  /// floor rebounds, and the result is a broad shallow basin rather than a
  /// scaled-up bowl. On the Moon that transition is around 15-20 km.
  ///
  /// Ignoring it is a big error, not a subtle one. At the default 80 km
  /// diameter a flat 1:5 ratio asks for a crater 16 km DEEP — several times the
  /// Moon's entire relief, and deep enough that the collision surface ends up
  /// tens of kilometres below the datum. Real 80 km craters are ~5 km deep.
  final double complexTransitionM;

  /// How depth scales with diameter beyond [complexTransitionM]. ~0.3 puts an
  /// 80 km crater near 5 km deep, which matches the observed population.
  final double complexExponent;

  /// Rim crest height as a fraction of diameter.
  final double rimRatio;

  /// How far the ejecta blanket reaches, in crater radii.
  final double ejectaReach;

  /// Lattice cell size in crater radii. Above 2 craters mostly stand apart;
  /// lower values saturate the surface into overlapping bowls.
  final double spacing;

  /// Craters below this rim radius (m) are skipped — the cutoff that stops
  /// finer decades costing work for relief no chunk can resolve.
  final double minRadiusM;

  /// The radial profile of a crater, as a multiple of its DEPTH.
  ///
  /// `x` is distance from the centre in rim radii. Returns negative inside the
  /// bowl, positive on the rim and through the ejecta blanket, zero beyond
  /// [ejectaReach]. Continuous at every join — a discontinuity here would show
  /// as a hard ring in the mesh.
  static double profile(double x, double rimOverDepth, double reach) {
    if (x >= reach) return 0.0;
    if (x < 1.0) {
      // Paraboloid bowl rising to the rim crest at x = 1.
      final bowl = -(1.0 - x * x);
      final rim = rimOverDepth * x * x * x * x; // steep, so it only bites near 1
      return bowl + rim;
    }
    // Outside: the crest decays into the ejecta blanket. Normalised so it is
    // exactly rimOverDepth at x = 1 and exactly 0 at x = reach.
    final t = (x - 1.0) / (reach - 1.0);
    final falloff = (1.0 - t) * (1.0 - t) * (1.0 - t);
    return rimOverDepth * falloff;
  }

  @override
  double heightAt(Vector3 dir, TerrainControl control) {
    // Crater retention scales with how rough/unresurfaced the ground is: young
    // volcanic plains keep almost none, ancient highlands keep everything.
    final retention = control.roughnessAt(dir);
    if (retention <= 0) return 0;

    var total = 0.0;
    var craterR = largestRadiusM;
    for (var d = 0; d < decades; d++) {
      if (craterR >= minRadiusM) {
        total += _decade(dir, craterR, d);
      }
      craterR /= decadeRatio;
    }
    return total * retention;
  }

  /// One decade's contribution: a jittered lattice of same-scale craters.
  double _decade(Vector3 dir, double craterR, int decade) {
    // Lattice pitch in radians of arc, expressed as a scale on the unit
    // direction. Cells the sphere passes through are the only ones sampled.
    final pitch = craterR * spacing;
    final scale = radiusM / pitch;
    final px = dir.x * scale, py = dir.y * scale, pz = dir.z * scale;
    final cx = px.floor(), cy = py.floor(), cz = pz.floor();

    final depth = depthForRadius(craterR);
    // Rim height stays a fixed fraction of diameter, so expressing it in units
    // of depth has to use this crater's ACTUAL depth, not the simple-crater
    // ratio — otherwise complex craters would get rims scaled for bowls they
    // are not.
    final rimOverDepth = depth <= 0 ? 0.0 : (craterR * 2 * rimRatio) / depth;

    var sum = 0.0;
    for (var ox = -1; ox <= 1; ox++) {
      for (var oy = -1; oy <= 1; oy++) {
        for (var oz = -1; oz <= 1; oz++) {
          final h = _hash(cx + ox, cy + oy, cz + oz, decade);
          // Cheapest possible rejection, first: most cells are empty.
          if (_unit(h) > density) continue;

          // Jittered centre within the cell, then projected onto the sphere.
          final jx = cx + ox + _unit(h * 0x9E3779B1);
          final jy = cy + oy + _unit(h * 0x85EBCA6B);
          final jz = cz + oz + _unit(h * 0xC2B2AE35);
          final len = math.sqrt(jx * jx + jy * jy + jz * jz);
          if (len < 1e-9) continue;
          final inv = 1.0 / len;

          // Arc distance from the sample to this crater's centre.
          final cosA =
              (dir.x * jx + dir.y * jy + dir.z * jz) * inv;
          final arc = math.acos(cosA.clamp(-1.0, 1.0)) * radiusM;

          // Size variation within the decade, so a decade does not read as a
          // grid of identical stamps.
          final r = craterR * (0.55 + 0.9 * _unit(h * 0x27220A95));
          final x = arc / r;
          if (x >= ejectaReach) continue;

          // Each crater takes its OWN depth from the scaling law rather than
          // scaling the decade's depth linearly. Past the simple-to-complex
          // break depth grows as D^0.3, so a linear stretch would over-deepen
          // the large end of the decade and break the bound below.
          sum += profile(x, rimOverDepth, ejectaReach) * depthForRadius(r);
        }
      }
    }
    // Clamp to what ONE crater of this decade could do. Cells are 2.2 crater
    // radii apart while ejecta reaches 2.5, so several craters of the same
    // decade legitimately cover one point and their summed bowls would dig a
    // pit deeper than any of them — unphysical (a later impact resets the
    // ground, it does not deepen it) and unbounded, which would break the
    // shell-sizing contract [maxMagnitude] owes the mesher.
    //
    // The clamp is C0, not smooth. That is fine here: normals come from
    // central-differencing the density field, and the CSG brushes already
    // introduce creases of exactly this kind.
    final deepest = depthForRadius(craterR * _sizeMax);
    return sum.clamp(-deepest, deepest * rimOverDepth);
  }

  /// Largest size multiplier a crater can draw within its decade — the top of
  /// the `0.55 + 0.9 * unit` range used above.
  static const double _sizeMax = 1.45;

  /// Depth (m) of a crater of rim radius [rM], following the simple-to-complex
  /// break.
  ///
  /// Below [complexTransitionM] diameter it is the flat [depthRatio] of a bowl.
  /// Above it, depth continues from that point as `D^complexExponent`, which is
  /// continuous at the transition and flattens thereafter.
  double depthForRadius(double rM) {
    final diameter = rM * 2;
    if (diameter <= complexTransitionM) return diameter * depthRatio;
    final atBreak = complexTransitionM * depthRatio;
    return atBreak *
        math.pow(diameter / complexTransitionM, complexExponent).toDouble();
  }

  /// Integer lattice hash, same avalanche mix the rest of the terrain code
  /// uses so the whole field shares one notion of "seeded".
  int _hash(int x, int y, int z, int decade) {
    var h = (seed ^ (decade * 0x9E3779B1)) & 0xffffffff;
    h = (h ^ (x * 0x9e3779b1)) & 0xffffffff;
    h = (h ^ (y * 0x85ebca6b)) & 0xffffffff;
    h = (h ^ (z * 0xc2b2ae35)) & 0xffffffff;
    h = (h ^ (h >> 15)) & 0xffffffff;
    h = (h * 0x2c1b3c6d) & 0xffffffff;
    h = (h ^ (h >> 12)) & 0xffffffff;
    h = (h * 0x297a2d39) & 0xffffffff;
    h = (h ^ (h >> 15)) & 0xffffffff;
    return h;
  }

  /// Re-mix an integer into `0..1`, so one hash can supply several independent
  /// decisions without four separate lattice lookups.
  static double _unit(int h) {
    var x = h & 0xffffffff;
    x = (x ^ (x >> 16)) & 0xffffffff;
    x = (x * 0x7feb352d) & 0xffffffff;
    x = (x ^ (x >> 15)) & 0xffffffff;
    x = (x * 0x846ca68b) & 0xffffffff;
    x = (x ^ (x >> 16)) & 0xffffffff;
    return x / 0xffffffff;
  }

  @override
  double maxMagnitude(double localReliefM) {
    // Each decade is clamped to one crater's worth, so the field bound is the
    // sum of those clamps. Decades CAN stack (a small crater inside a big one
    // is exactly what a real surface looks like), so this sum is reachable and
    // is not merely conservative.
    var sum = 0.0;
    var r = largestRadiusM;
    for (var d = 0; d < decades; d++) {
      if (r >= minRadiusM) sum += depthForRadius(r * _sizeMax);
      r /= decadeRatio;
    }
    return sum;
  }
}
