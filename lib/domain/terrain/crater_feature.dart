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
import 'dart:typed_data';

import '../shared/vector3.dart';
import 'terrain_control.dart';
import 'terrain_feature.dart';

/// Analytic crater field over a body, evaluated per direction.
///
/// Pure and deterministic. Per decade the scan geometrically prunes a 7^3 cell
/// window down to the ~25 cells the sphere shell actually passes through
/// within ejecta reach, and only those are hashed — most are then rejected by
/// the density check. See the window note in `_decade`.
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

    // Rim height tracks DEPTH, not diameter: for a simple crater the two are
    // proportional and this is exactly `rimRatio * diameter`, but past the
    // complex transition depth grows only as D^0.3 and the rim must flatten
    // with it. A rim pinned to diameter gave an 80 km crater a 3.2 km crest on
    // a 5 km basin (real lunar rims there are ~1 km), and — worse — made big
    // craters NET-POSITIVE in volume, so a saturated surface built UP on
    // average. Impacts excavate; the profile integral must stay negative.
    final rimOverDepth = 2 * rimRatio / depthRatio;

    var sum = 0.0;
    // A crater EXISTS only if the sphere shell actually intersects its cell's
    // cube. That predicate depends on the cell alone — never on where the
    // sample sits — and it is what makes the field well-defined. The old scan
    // ("every cell in a window around the sample's cell") let cells displaced
    // almost RADIALLY from the sample contribute: a cell buried inside the
    // sphere still holds a jittered point whose PROJECTION lands right on the
    // surface, so its whole bowl popped in and out of the sum whenever the
    // sample slid across a radial-facing cell wall — kilometre-deep cliffs
    // along wall projections all over the body.
    //
    // The window must then cover every shell cell whose crater can reach the
    // sample. Reach: ejecta runs [ejectaReach] radii of a crater drawn up to
    // [_sizeMax] the decade radius -> `ejectaReach * _sizeMax / spacing`
    // (~1.65) pitches laterally; a shell cell's jitter sits within the cube
    // diagonal (sqrt(3)) of the shell radially. Those are orthogonal, so any
    // contributor lies within sqrt(reach^2 + 3) (~2.4) pitches of the sample:
    // +-3 covers it, and the two geometric prunes below reject nearly all of
    // the 343 cells before their hash is ever taken (the scan does LESS hash
    // work than the old +-1 window).
    final reachCells = ejectaReach * _sizeMax / spacing;
    final pruneSq = reachCells * reachCells + 3.0 + 1e-9;
    final scaleSq = scale * scale;
    // Per-axis pieces of (a) the sample-to-cube distance and (b) the cube's
    // nearest/farthest coordinate from the body centre, hoisted out of the
    // triple loop.
    final dp = Float64List(21), nearO = Float64List(21), farO = Float64List(21);
    for (var a = 0; a < 3; a++) {
      final p = a == 0 ? px : (a == 1 ? py : pz);
      final c = a == 0 ? cx : (a == 1 ? cy : cz);
      for (var o = -3; o <= 3; o++) {
        final lo = (c + o).toDouble(), hi = lo + 1.0;
        final i = a * 7 + o + 3;
        dp[i] = p < lo ? lo - p : (p > hi ? p - hi : 0.0);
        nearO[i] = lo > 0 ? lo : (hi < 0 ? -hi : 0.0);
        farO[i] = lo.abs() > hi.abs() ? lo.abs() : hi.abs();
      }
    }
    for (var ox = -3; ox <= 3; ox++) {
      final ix = ox + 3;
      for (var oy = -3; oy <= 3; oy++) {
        final iy = 7 + oy + 3;
        final dxy = dp[ix] * dp[ix] + dp[iy] * dp[iy];
        if (dxy > pruneSq) continue;
        for (var oz = -3; oz <= 3; oz++) {
          final iz = 14 + oz + 3;
          // Reach prune: no point of this cell is close enough to the sample
          // for any crater it could hold to touch it.
          if (dxy + dp[iz] * dp[iz] > pruneSq) continue;
          // Shell test: the sphere must pass through the cell's cube, or the
          // cell spawns nothing — this is the sample-independent existence
          // predicate above.
          final nearSq = nearO[ix] * nearO[ix] +
              nearO[iy] * nearO[iy] +
              nearO[iz] * nearO[iz];
          if (nearSq > scaleSq) continue; // wholly outside the sphere
          final farSq =
              farO[ix] * farO[ix] + farO[iy] * farO[iy] + farO[iz] * farO[iz];
          if (farSq < scaleSq) continue; // wholly inside the sphere
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
