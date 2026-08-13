// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../planetary/planet_surface.dart';
import '../shared/vector3.dart';
import '../terrain/cubed_sphere.dart';
import '../terrain/terrain_field.dart';
import 'prop_random.dart';
import 'scatter_instance.dart';
import 'scatter_layer.dart';

/// Places props on a body's surface, one cubed-sphere cell at a time.
///
/// ## Stateless by construction
///
/// [instancesFor] is a pure function of `(cell, layer, body seed)`. Nothing is
/// stored, nothing is streamed, and two machines — or the main isolate and a
/// mesher isolate — independently produce byte-identical results. That is what
/// lets scatter ride the terrain's existing cell lifecycle for free: a cell
/// that comes back into view is regenerated rather than remembered, and the
/// player cannot tell the difference because there is none.
///
/// It also means scatter needs no save data. A forest is not content; it is a
/// consequence of a seed.
///
/// ## Cost
///
/// Placement runs per candidate over a whole planet, so the fast path matters.
/// Candidates land on the BASE relief via [TerrainField.baseGroundRadiusAt] —
/// one fBm evaluation, analytic. The edit-aware [TerrainField.groundRadiusAt]
/// raymarches, so it is used ONLY for the handful of candidates that fall
/// inside a deformation's footprint (see [_settleOnEdits]). Deformations are
/// local and rare; the planet is neither.
class ScatterPlacement {
  const ScatterPlacement({
    required this.field,
    required this.surface,
    required this.bodySeed,
    required this.vegetationCap,
  });

  /// The body's terrain field, edits and all.
  final TerrainField field;

  /// Climate/biome model for the same body.
  final PlanetSurface surface;

  /// Distinguishes this body's scatter from every other body's.
  final int bodySeed;

  /// The body's vegetation cover cap (`TerrainConfig.grassAmount`), 0 on
  /// airless worlds. Gates every layer that requires vegetation.
  final double vegetationCap;

  /// Every prop [layer] puts in [cell].
  ///
  /// Returns empty when the cell is not at the layer's generation level, so a
  /// caller can hand every visible leaf to every layer and let this sort it
  /// out.
  List<ScatterInstance> instancesFor(ChunkKey cell, ScatterLayer layer) {
    if (cell.level != layer.levelFor(field.radius)) return const [];
    if (layer.kinds.isEmpty) return const [];

    // Candidate count from the cell's TRUE area, so rounding the generation
    // level shifts how many cells share the work but never the density.
    final areaM2 = _cellAreaM2(cell);
    final target = areaM2 * layer.densityPerKm2 / 1e6;
    if (target <= 0) return const [];
    // A jittered lattice rather than pure random points: uniform random
    // scattering clumps and leaves bald patches (it is a Poisson process, and
    // that is what one looks like). One candidate per sub-cell, jittered inside
    // it, reads as natural without the cost of a real Poisson-disc pass.
    final side = math.max(1, math.sqrt(target).round());
    final accepted = target / (side * side);

    final out = <ScatterInstance>[];
    final ds = (cell.s1 - cell.s0) / side;
    final dt = (cell.t1 - cell.t0) / side;

    for (var j = 0; j < side; j++) {
      for (var i = 0; i < side; i++) {
        final rnd = _candidateRandom(cell, layer, i, j);
        // Thin to the fractional target the lattice cannot express exactly.
        if (accepted < 1.0 && !rnd.chance(accepted)) continue;

        final s = cell.s0 + (i + rnd.next()) * ds;
        final t = cell.t0 + (j + rnd.next()) * dt;
        final dir = directionOf(cell.face, s, t);

        final placed = _place(dir, layer, rnd);
        if (placed != null) out.add(placed);
      }
    }
    return out;
  }

  /// Every layer's props for one cell, for callers that just want "what is in
  /// this cell".
  List<ScatterInstance> allInstancesFor(
    ChunkKey cell, {
    List<ScatterLayer> layers = ScatterLayers.all,
  }) =>
      [for (final l in layers) ...instancesFor(cell, l)];

  /// The levels any of [layers] generate at — the set a streamer must watch.
  Set<int> generationLevels({List<ScatterLayer> layers = ScatterLayers.all}) =>
      {for (final l in layers) l.levelFor(field.radius)};

  // ---- One candidate ------------------------------------------------------

  ScatterInstance? _place(Vector3 dir, ScatterLayer layer, PropRandom rnd) {
    final groundR = field.baseGroundRadiusAt(dir.x, dir.y, dir.z);
    final normal = _surfaceNormal(dir);
    final slopeCos = normal.dot(dir); // both unit; 1 = flat ground

    final lat = math.asin(dir.z.clamp(-1.0, 1.0));
    final lon = math.atan2(dir.y, dir.x);
    final biome = surface.biomeAt(latitude: lat, longitude: lon);

    final fit = layer.suitability(
      biome: biome,
      slopeCos: slopeCos,
      altitudeM: groundR - field.radius,
      vegetationCap: vegetationCap,
    );
    if (fit <= 0.0 || !rnd.chance(fit)) return null;

    final radius = _settleOnEdits(dir, groundR);
    if (radius == null) return null; // the ground here was carved away

    final (lo, hi) = layer.scaleRange;
    return ScatterInstance(
      kind: layer.kinds[rnd.intBelow(layer.kinds.length)],
      seed: rnd.nextInt32() & 0x3fffffff,
      positionBF: dir * radius,
      upBF: normal,
      yaw: rnd.range(0, 2 * math.pi),
      scale: rnd.range(lo, hi),
    );
  }

  /// Ground drop (m) that destroys a prop rather than re-seating it.
  ///
  /// Small, because the point is to distinguish "the ground was dug out from
  /// under this" from "the ground shifted slightly"; anything deeper than a
  /// footing is the former.
  static const double _excavationToleranceM = 0.75;

  /// Re-seat a candidate against any deformation covering it, or drop it.
  ///
  /// Returns the base radius untouched on the overwhelmingly common path where
  /// no edit is near — the whole reason placement can afford to be analytic.
  ///
  /// Where an edit IS near, the decision is made on how the ground MOVED, not
  /// on whether a brush touches the point. Those are different questions and
  /// conflating them is wrong in a way that only shows up on craters: a crater
  /// both excavates a bowl AND raises a rim, so "a brush affects this point"
  /// is equally true of ground that vanished and ground that was pushed up.
  /// Testing the displacement instead gets both right — excavated props are
  /// destroyed, props on the rim ride up with it — and needs to know nothing
  /// about brush kinds, so it stays correct as more are added.
  double? _settleOnEdits(Vector3 dir, double baseRadius) {
    final edits = field.edits;
    if (edits == null || edits.isEmpty) return baseRadius;
    if (edits.at(dir).isEmpty) return baseRadius;

    final exact = field.groundRadiusAt(dir.x, dir.y, dir.z);
    // Dug out from under: the prop has nothing left to stand on.
    if (exact < baseRadius - _excavationToleranceM) return null;
    // Unchanged, or raised — sit on wherever the ground ended up.
    return exact;
  }

  /// Outward surface normal of the base relief, by central differences in the
  /// local tangent plane.
  ///
  /// Sampled off the BASE relief deliberately: an edit's walls are near-vertical
  /// and would tip props over onto the rim of every crater, when what is wanted
  /// is props standing on the terrain the crater was cut into (and removed
  /// outright where it cut them away — see [_settleOnEdits]).
  Vector3 _surfaceNormal(Vector3 dir) {
    // Step a fixed arc so the estimate is scale-free across body sizes, and
    // wide enough not to be dominated by the fBm's finest octave.
    final h = math.max(field.featureScale * 0.02, 1.0);
    final ref = dir.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final east = ref.cross(dir).normalized;
    final north = dir.cross(east);

    final dEast = _radiusAlong(dir, east, h) - _radiusAlong(dir, east, -h);
    final dNorth = _radiusAlong(dir, north, h) - _radiusAlong(dir, north, -h);

    // Gradient of height over the tangent plane; the normal tilts away from
    // radial by that gradient.
    final n = dir - east * (dEast / (2 * h)) - north * (dNorth / (2 * h));
    final len = n.length;
    return len < 1e-9 ? dir : n / len;
  }

  double _radiusAlong(Vector3 dir, Vector3 axis, double arcM) {
    final d = (dir + axis * (arcM / field.radius)).normalized;
    return field.baseGroundRadiusAt(d.x, d.y, d.z);
  }

  /// Area of a cell (m^2), from the sphere's area shared equally between the
  /// level's cells.
  ///
  /// Equal-share rather than the true spherical quad: the cube-to-sphere map is
  /// not equal-area, so cells near a face centre are up to ~1.6x the corner
  /// ones. That biases density by that much across a face and is worth fixing
  /// when density tuning demands it — but it is a smooth, slowly varying bias,
  /// invisible next to the biome and slope variation on top of it.
  double _cellAreaM2(ChunkKey cell) {
    final sphere = 4.0 * math.pi * field.radius * field.radius;
    return sphere / (6.0 * (1 << cell.level) * (1 << cell.level));
  }

  /// A generator unique to this candidate.
  ///
  /// Keyed by cell AND lattice slot, so a candidate's whole life — whether it
  /// survives, which kind it is, its yaw and scale — is decided without
  /// reference to its neighbours. Deriving them from one per-cell stream
  /// instead would make every prop depend on how many candidates before it were
  /// rejected, so a density tweak would reshuffle the entire planet.
  PropRandom _candidateRandom(
    ChunkKey cell, ScatterLayer layer, int i, int j) {
    var h = bodySeed & 0xffffffff;
    h = (h ^ (cell.face.index * 0x9e3779b1)) & 0xffffffff;
    h = (h ^ (cell.level * 0x85ebca6b)) & 0xffffffff;
    h = (h ^ (cell.u * 0xc2b2ae35)) & 0xffffffff;
    h = (h ^ (cell.v * 0x27d4eb2f)) & 0xffffffff;
    h = (h ^ (layer.name.hashCode * 0x165667b1)) & 0xffffffff;
    h = (h ^ (i * 0x2545f491)) & 0xffffffff;
    h = (h ^ (j * 0x94d049bb)) & 0xffffffff;
    return PropRandom(h);
  }
}
