// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Screen-space LOD selection over the cubed-sphere quadtree (phase 4a).
///
/// The tree is a set of LEAVES that together tile the whole body. Each frame,
/// [TerrainLodTree.update] splits leaves that project larger than a pixel
/// budget, merges sibling groups that project small enough, and then restores
/// the 2:1 balance invariant.
///
/// Pure domain: no Flutter, no camera type. The projection arrives as a
/// callback so the renderer can hand over the SAME apparent-size function the
/// rail culls use (`SceneCamera.radiusPx`), which keeps LOD and culling from
/// disagreeing about what is on screen.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';
import 'cubed_sphere.dart';
import 'terrain_brush.dart';

/// Projected radius of [chunk] in pixels. Return 0 (or anything below the
/// merge threshold) to declare a chunk uninteresting — off-screen, beyond the
/// horizon — and it will collapse to its coarsest form instead of splitting.
typedef ChunkApparentPx = double Function(ChunkKey chunk);

/// The leaf covering [key] — [key] itself if it is a leaf, else the nearest
/// ancestor that is. Null when the region is subdivided FINER than [key], in
/// which case no single leaf covers it.
ChunkKey? leafCovering(Set<ChunkKey> leaves, ChunkKey key) {
  if (leaves.contains(key)) return key;
  for (final a in key.ancestors) {
    if (leaves.contains(a)) return a;
  }
  return null;
}

/// Whether [leaves] satisfies the 2:1 (restricted quadtree) invariant: no leaf
/// is more than one level apart from any edge-adjacent leaf.
bool isBalanced(Set<ChunkKey> leaves) {
  for (final k in leaves) {
    for (final e in ChunkEdge.values) {
      final owner = leafCovering(leaves, k.neighbour(e));
      if (owner != null && (k.level - owner.level) > 1) return false;
    }
  }
  return true;
}

/// Split coarse leaves until the 2:1 invariant holds, returning a new set.
///
/// Only ever splits — never merges — so it cannot undo a selection decision;
/// it only adds detail on the coarse side of an over-steep transition. That
/// terminates: a chunk is split only when a neighbour is at least two levels
/// finer, so no chunk can be pushed past the finest level already present.
Set<ChunkKey> enforceBalance(Set<ChunkKey> input, {int maxIterations = 64}) {
  final leaves = Set<ChunkKey>.of(input);
  for (var iter = 0; iter < maxIterations; iter++) {
    // Collect first, mutate after — splitting mid-iteration would invalidate
    // the very neighbour lookups the decision is based on.
    final toSplit = <ChunkKey>{};
    for (final k in leaves) {
      for (final e in ChunkEdge.values) {
        final owner = leafCovering(leaves, k.neighbour(e));
        if (owner != null && (k.level - owner.level) > 1) toSplit.add(owner);
      }
    }
    if (toSplit.isEmpty) return leaves;
    for (final k in toSplit) {
      leaves.remove(k);
      leaves.addAll(k.children);
    }
  }
  return leaves;
}

/// Whether the chunk centred at [chunk] is over the horizon from [eyeBF].
///
/// Both in the body-fixed frame. The occluder is NOT the datum sphere: relief
/// runs [reliefM] both ways around it, so the solid ball that can actually
/// hide a chunk has radius `radiusM - reliefM`, and the chunk's terrain can
/// stand as tall as `radiusM + reliefM`. Comparing arcs: the chunk is hidden
/// only when its angular distance from the eye exceeds the eye's horizon arc
/// over that inner ball plus the arc from which the chunk's HIGHEST point can
/// still peek over it. [marginM] adds the chunk's own angular extent so a
/// chunk whose centre has just dipped under keeps its visible near edge.
///
/// Using the datum as the occluder was a real bug: on a DEM body the maria
/// sit kilometres BELOW datum, so a landed camera had `|eye| < radiusM` and
/// every chunk on the planet — including the one underfoot — failed the old
/// `P·E >= R^2` test. An eye at or inside the inner ball culls nothing.
bool isBeyondHorizon(
  ChunkKey chunk,
  Vector3 eyeBF,
  double radiusM, {
  double marginM = 0,
  double reliefM = 0,
}) =>
    HorizonTest(eyeBF, radiusM, reliefM: reliefM)
        .hiddenAt(chunk.centreDirection, marginM: marginM);

/// [isBeyondHorizon] with the eye's half done once, for a pass over
/// thousands of chunks.
///
/// Everything that depends only on the eye — its horizon arc over the inner
/// ball, the peak allowance — folds into one arc here, with its cosine and
/// sine. The per-chunk compare is then done on cosines rather than angles:
/// `acos(cosA) > arc + marginArc` is `cosA < cos(arc + marginArc)`, and with
/// both halves' cosines and sines in hand that expands to two multiplies. A
/// chunk's margin arc is a constant of the chunk ([ChunkGeometry] keeps it),
/// so a cull is one dot product per chunk and no trig at all. The selection
/// pass used to run the full test — three inverse-trig calls and a fresh
/// centre direction — three to four times per leaf per reselect.
class HorizonTest {
  factory HorizonTest(Vector3 eyeBF, double radiusM, {double reliefM = 0}) {
    final inner = math.max(1e-6, radiusM - reliefM);
    final eye = eyeBF.length;
    if (eye <= inner) {
      // At or inside the inner ball there is no horizon over it: culls
      // nothing (a landed eye in a deep DEM basin sits here).
      return HorizonTest._(radiusM, Vector3.zero, double.infinity, 1, 0);
    }
    final peak = radiusM + reliefM;
    final arc = math.acos((inner / eye).clamp(0.0, 1.0)) +
        math.acos((inner / peak).clamp(0.0, 1.0));
    return HorizonTest._(
        radiusM, eyeBF / eye, arc, math.cos(arc), math.sin(arc));
  }

  const HorizonTest._(
      this.radiusM, this._eyeDir, this._arc, this._cosArc, this._sinArc);

  final double radiusM;
  final Vector3 _eyeDir;

  /// The eye's horizon arc plus the peak allowance; infinite when the eye
  /// is inside the inner ball and nothing can be hidden.
  final double _arc;
  final double _cosArc;
  final double _sinArc;

  /// Whether nothing is ever hidden from this eye.
  bool get cullsNothing => _arc == double.infinity;

  /// The chunk at [g] is over the horizon.
  bool hidden(ChunkGeometry g) =>
      _hidden(g.centreDir, g.marginArc, g.cosMarginArc, g.sinMarginArc);

  /// The chunk centred on unit [centreDir] with a [marginM] radius is over
  /// the horizon — the one-off form; [hidden] is the cached one.
  bool hiddenAt(Vector3 centreDir, {double marginM = 0}) {
    final m = math.asin((marginM / radiusM).clamp(0.0, 1.0));
    return _hidden(centreDir, m, math.cos(m), math.sin(m));
  }

  bool _hidden(Vector3 centreDir, double marginArc, double cosM, double sinM) {
    if (cullsNothing) return false;
    // acos never exceeds pi, so an arc past it hides nothing — and the
    // cosine compare below would wrap and lie there.
    if (_arc + marginArc >= math.pi) return false;
    final cosTotal = _cosArc * cosM - _sinArc * sinM;
    return centreDir.dot(_eyeDir) < cosTotal;
  }
}

/// The cone circumscribing a view frustum, for a cheap "is any of this chunk
/// in view" test.
///
/// A frustum's four planes are the exact answer; the cone through its corners
/// is the answer to within the corner slivers, costs one dot product and one
/// square root per chunk, and needs only the view direction — which every lens
/// the streamers see already carries. [marginRad] widens it so a turn has
/// coarse cover to refine from before the frustum edge arrives.
///
/// Out-of-view chunks are not DROPPED by the selection pass: the tree must go
/// on tiling the body or every turn opens holes. Their apparent size is
/// attenuated instead, so the quadtree merges them a few levels coarser on its
/// own (hysteresis keeps that from thrashing; the atomic LOD swap keeps it
/// from showing), and a turn streams detail back in through the ordinary
/// ladder.
class ViewCone {
  ViewCone(Vector3 forward, double halfAngle)
      : forward = forward.normalized,
        halfAngle = halfAngle.clamp(0.0, math.pi),
        _cos = math.cos(halfAngle.clamp(0.0, math.pi)),
        _sin = math.sin(halfAngle.clamp(0.0, math.pi));

  /// The cone through the corners of a frustum [fovRadiansY] tall at
  /// [aspect] (width over height), widened by [marginRad].
  factory ViewCone.circumscribing({
    required Vector3 forward,
    required double fovRadiansY,
    required double aspect,
    double marginRad = 0,
  }) {
    final t = math.tan(fovRadiansY / 2);
    return ViewCone(
        forward, math.atan(t * math.sqrt(1 + aspect * aspect)) + marginRad);
  }

  /// The same cone from a lens's pixel budget: `focalPx` is
  /// `(heightPx / 2) / tan(fov / 2)`, so the half-height tangent is
  /// `heightPx / (2 focalPx)`.
  factory ViewCone.forViewport({
    required Vector3 forward,
    required double focalPx,
    required double widthPx,
    required double heightPx,
    double marginRad = 0,
  }) {
    final t = heightPx / (2 * focalPx);
    final aspect = widthPx / heightPx;
    return ViewCone(
        forward, math.atan(t * math.sqrt(1 + aspect * aspect)) + marginRad);
  }

  /// Unit view direction, in whatever frame the caller tests in.
  final Vector3 forward;

  /// Half-angle of the cone, radians, in `[0, pi]`.
  final double halfAngle;
  final double _cos;
  final double _sin;

  /// Whether a sphere of [radiusM] centred at [centreRel] (relative to the
  /// eye) overlaps the cone — the eye inside the sphere counts.
  bool containsSphere(Vector3 centreRel, double radiusM) {
    final d2 = centreRel.lengthSquared;
    if (d2 <= radiusM * radiusM) return true;
    if (halfAngle >= math.pi) return true;
    final d = math.sqrt(d2);
    // The sphere's angular radius as seen from the eye, as sine and cosine.
    final sinA = radiusM / d;
    final cosA = math.sqrt(math.max(0.0, 1 - sinA * sinA));
    // In view when the centre is within halfAngle + angularRadius of
    // forward: acos(dot/d) <= halfAngle + a, i.e. dot/d >= cos(halfAngle + a)
    // while that sum stays under pi. Past pi everything is in view; only a
    // cone already wider than a half-space can get there.
    if (halfAngle >= math.pi / 2 && halfAngle + math.asin(sinA) >= math.pi) {
      return true;
    }
    final cosTotal = _cos * cosA - _sin * sinA;
    return centreRel.dot(forward) >= cosTotal * d;
  }
}

/// What every pass over a chunk needs of its geometry, computed once per key.
///
/// A key's centre direction and circumradius are pure functions of the key
/// and the body radius, yet the selection pass derived them three to four
/// times per leaf per reselect — each circumradius five normalisations and
/// a corner list — across the tree walk, the horizon cull and the distance
/// sort. [ChunkGeometryCache] hands the same [ChunkGeometry] to all of them.
class ChunkGeometry {
  factory ChunkGeometry(ChunkKey key, double radiusM) {
    final c = key.centreDirection;
    var maxChord = 0.0;
    for (final k in key.cornerDirections) {
      final d = (k - c).length;
      if (d > maxChord) maxChord = d;
    }
    // Same chord as [ChunkKey.circumradiusM]; the margin arc is what
    // [isBeyondHorizon] derived from it per call.
    final circ = maxChord * radiusM;
    final marginArc = math.asin(maxChord.clamp(0.0, 1.0));
    return ChunkGeometry._(
        c, c * radiusM, circ, marginArc, math.cos(marginArc), math.sin(marginArc));
  }

  const ChunkGeometry._(this.centreDir, this.centreBF, this.circumradiusM,
      this.marginArc, this.cosMarginArc, this.sinMarginArc);

  /// Unit direction through the cell centre, body-fixed.
  final Vector3 centreDir;

  /// The centre on the datum sphere, body-fixed metres.
  final Vector3 centreBF;

  /// [ChunkKey.circumradiusM] at the cache's radius.
  final double circumradiusM;

  /// The horizon margin the circumradius implies, with its cosine and sine
  /// for [HorizonTest.hidden].
  final double marginArc;
  final double cosMarginArc;
  final double sinMarginArc;
}

/// [ChunkGeometry] per key, kept across frames for one body radius.
///
/// Entries are constants of the key, so they never go stale — only
/// unbounded. [sweep] keeps the map to the live leaf set once it has grown
/// past [sweepAbove]: called every reselect, it costs nothing until it fires,
/// so a long flight around a body does not accumulate every cell it passed.
class ChunkGeometryCache {
  ChunkGeometryCache(this.radiusM, {this.sweepAbove = 8192});

  final double radiusM;
  final int sweepAbove;
  final Map<ChunkKey, ChunkGeometry> _byKey = {};

  int get length => _byKey.length;

  ChunkGeometry of(ChunkKey key) =>
      _byKey[key] ??= ChunkGeometry(key, radiusM);

  /// Drop every entry not in [live] if the cache has outgrown [sweepAbove].
  void sweep(Iterable<ChunkKey> live) {
    if (_byKey.length <= sweepAbove) return;
    final keep = <ChunkKey, ChunkGeometry>{};
    for (final k in live) {
      final g = _byKey[k];
      if (g != null) keep[k] = g;
    }
    _byKey
      ..clear()
      ..addAll(keep);
  }
}

/// How far the eye may move before selection must rerun.
///
/// Selection changes only when a chunk's apparent size crosses the split or
/// merge threshold, and apparent size moves with eye displacement over the
/// distance to the chunk — the nearest of which sits about [heightM] away,
/// the eye's height over the ground beneath it. So a [fraction] of the height
/// is a fraction of every apparent size, and with the split/merge hysteresis
/// at 2.2x a tenth flips only chunks that were already due.
///
/// [floorM] covers the ground: below it nothing near can split anyway (the
/// finest selectable cells are hundreds of metres across), and what does
/// change sits kilometres out. Height below the ground (an eye in a hill)
/// counts as zero.
///
/// Speed is not an input. Distance since the last selection integrates it: a
/// fast craft crosses the threshold in fewer frames, a slow one in more, which
/// is the whole effect wanted. The periodic reselect stays as the backstop for
/// what this gate is not about — the horizon's leading edge.
double reselectDistanceM({
  required double heightM,
  required double fraction,
  required double floorM,
}) =>
    math.max(floorM, fraction * math.max(0.0, heightM));

/// A demand for detail that screen-space selection would never produce on its
/// own: refine whatever leaf covers [direction] down to at least [level].
///
/// Deformation needs this. A 16 m crater sits far below the voxel size LOD
/// picks — at level 12 a Moon-sized body's cells are ~780 m across, or ~32 m
/// per voxel at resolution 24, so subtracting the crater from the field moves
/// no vertex at all. The fix is not a second mesher: it is meshing the SAME
/// cubed-sphere chunks several levels deeper right where the edit is, which the
/// quadtree already knows how to address.
class TerrainRefinement {
  const TerrainRefinement(this.direction, this.level);

  /// Unit direction in the body-fixed frame.
  final Vector3 direction;

  /// Minimum level the leaf covering [direction] must reach.
  final int level;
}

/// The shallowest level whose chunks at [dir] mesh at [targetVoxelM] or finer.
///
/// Cell size is a function of POSITION on the cubed sphere (a face-corner cell
/// subtends ~40% less angle than a face-centre one), so this walks the actual
/// chunks along [dir] rather than assuming a uniform level-to-metres map.
int levelForVoxelSize(
  Vector3 dir,
  double radiusM,
  int resolution,
  double targetVoxelM, {
  int maxLevel = 20,
}) {
  if (targetVoxelM <= 0 || radiusM <= 0 || resolution < 1) return maxLevel;
  double voxelAt(int level) =>
      chunkAt(dir, level).circumradiusM(radiusM) * 2.0 / resolution;
  // Cells halve (near enough) per level, so log2 of the level-0 ratio lands
  // within a level or two of the answer, and a short walk from there settles
  // it against the true cell sizes. Scanning up from level 0 cost ~15 chunk
  // lookups per call, and a city asks this nine times per brush. The walk
  // finds the same level the scan did because cell size never grows with
  // depth along a direction — a child sits inside its parent — which the
  // refinement tests pin.
  final v0 = voxelAt(0);
  if (v0 <= targetVoxelM) return 0;
  var level =
      (math.log(v0 / targetVoxelM) / math.ln2).floor().clamp(0, maxLevel);
  if (voxelAt(level) <= targetVoxelM) {
    while (level > 0 && voxelAt(level - 1) <= targetVoxelM) {
      level--;
    }
    return level;
  }
  while (level < maxLevel) {
    level++;
    if (voxelAt(level) <= targetVoxelM) return level;
  }
  return maxLevel;
}

/// Refinement targets for a whole EDIT SET, merged.
///
/// A crater is one small edit and deserves its own island of deep quadtree.
/// A city is not: it hands the terrain one brush per building, and a six-block
/// colony emits 1,719 of them asking for 15,471 targets down to level 17 —
/// most of it redundant, because the brushes sit on top of one another and
/// because a LEVELLED pad is a PLANE, which any level meshes exactly.
///
/// Two things collapse it:
///
///  * A levelling brush (pad, box, polygon, corridor) only needs resolution
///    where its surface CURVES, which is the falloff ring at its edge — the
///    interior is flat. So those contribute their rim, not their middle.
///  * Targets that would force the same leaf are the same target. Deduping
///    against the chunk each one lands in removes the overlap between
///    neighbouring lots, which is most of what a city produces.
///
/// Craters and excavations are untouched: they are curved everywhere, so they
/// still get the full centre-plus-ring treatment.
///
/// One-shot: every brush is walked. A caller that merges the same brushes
/// again and again — the renderer, every time its range gate moves — should
/// hold a [RefinementMemo] instead.
List<TerrainRefinement> mergedRefinementsFor(
  Iterable<TerrainBrush> brushes,
  double radiusM,
  int resolution, {
  double voxelsAcrossBrush = 8,
  int maxLevel = 20,
  int ringSamples = 8,
  int cap = 4096,
}) =>
    RefinementMemo(
      radiusM: radiusM,
      resolution: resolution,
      voxelsAcrossBrush: voxelsAcrossBrush,
      maxLevel: maxLevel,
      ringSamples: ringSamples,
    ).merged(brushes, cap: cap);

/// The fields of a brush that [refinementsFor] reads — nothing else about the
/// brush can change its targets, so two brushes agreeing here are the same
/// brush to the memo, whether or not they are the same object.
typedef _BrushKey = (
  TerrainBrushKind kind,
  double cx,
  double cy,
  double cz,
  double radiusM,
  double minVoxelM,
  double falloffM,
  double lateralReachM,
  double? ex,
  double? ey,
  double? ez,
);

_BrushKey _keyOf(TerrainBrush b) {
  final c = b.centreBF;
  final e = b.endBF;
  return (
    b.kind,
    c.x,
    c.y,
    c.z,
    b.radiusM,
    b.minVoxelM,
    b.falloffM,
    b.lateralReachM,
    e?.x,
    e?.y,
    e?.z,
  );
}

/// [mergedRefinementsFor] that remembers each brush's targets between calls.
///
/// The merge is a pure function of the brushes and the meshing knobs, and its
/// cost is almost entirely the per-brush [refinementsFor]: nine level walks
/// each, so a 5,500-brush city was around a million chunk lookups — 240 ms —
/// and the renderer reran it every kilometre the eye's ground track moved,
/// which under a moving camera was every frame. The brushes under its range
/// gate hardly ever change, so the walks were nearly all repeats.
///
/// Targets are keyed by the brush FIELDS [refinementsFor] reads, not by
/// object identity: the renderer rebuilds its brush objects from the snapshot
/// whenever the edit count changes, and a rebuilt pad is the same pad. A
/// brush the memo has seen costs a hash; only new ones are walked.
///
/// Every [merged] call drops the entries the brushes it was given did not
/// use, so the memo is bounded by the live set. A quarry pit that regrows
/// each quantum leaves no trail here, and a brush that drifts out of range
/// and back is simply walked again.
///
/// The knobs are fixed at construction: entries built for one resolution or
/// body radius answer a different question at another. Check [matches] and
/// replace the memo when they move.
class RefinementMemo {
  RefinementMemo({
    required this.radiusM,
    required this.resolution,
    this.voxelsAcrossBrush = 8,
    this.maxLevel = 20,
    this.ringSamples = 8,
  });

  final double radiusM;
  final int resolution;
  final double voxelsAcrossBrush;
  final int maxLevel;
  final int ringSamples;

  Map<_BrushKey, List<_Placed>> _cache = {};

  /// Brushes the last [merged] call answered from memory.
  int hits = 0;

  /// Brushes the last [merged] call had to walk.
  int misses = 0;

  /// Entries held: the distinct brushes of the last [merged] call.
  int get length => _cache.length;

  /// Whether entries built by this memo are valid for these knobs.
  bool matches({
    required double radiusM,
    required int resolution,
    required double voxelsAcrossBrush,
    required int maxLevel,
  }) =>
      radiusM == this.radiusM &&
      resolution == this.resolution &&
      voxelsAcrossBrush == this.voxelsAcrossBrush &&
      maxLevel == this.maxLevel;

  /// The merged targets for [brushes], walking only the ones not remembered.
  ///
  /// [cap] bounds the distinct leaves kept; see the loop below for who loses.
  List<TerrainRefinement> merged(Iterable<TerrainBrush> brushes,
      {int cap = 4096}) {
    hits = 0;
    misses = 0;
    final next = <_BrushKey, List<_Placed>>{};
    final perBrush = <List<_Placed>>[];
    for (final brush in brushes) {
      final key = _keyOf(brush);
      var targets = next[key];
      if (targets == null) {
        targets = _cache[key];
        if (targets == null) {
          misses++;
          targets = [
            for (final t in refinementsFor(
              brush,
              radiusM,
              resolution,
              voxelsAcrossBrush: voxelsAcrossBrush,
              maxLevel: maxLevel,
              ringSamples: ringSamples,
            ))
              (cell: chunkAt(t.direction, t.level), target: t),
          ];
        } else {
          hits++;
        }
        next[key] = targets;
      } else {
        hits++;
      }
      perBrush.add(targets);
    }
    _cache = next;
    return _mergeTargets(perBrush, cap: cap);
  }
}

/// A target with the leaf it forces, projected once when its brush is walked
/// so a merge does not re-project the tens of thousands it has seen before.
typedef _Placed = ({ChunkKey cell, TerrainRefinement target});

/// The merge proper, over each brush's targets in brush order. The lists are
/// shared with the memo and are read, never written.
List<TerrainRefinement> _mergeTargets(
  List<List<_Placed>> perBrush, {
  required int cap,
}) {
  // Keyed by the leaf a target would force, keeping the deepest level asked
  // for it. Two lots either side of a street want the same chunk refined once.
  final byLeaf = <ChunkKey, TerrainRefinement>{};
  // Newest first: brushes arrive in tick order, and when the cap bites it is
  // the most recent edits — the fresh impact the player is watching — that
  // must keep their refinement, not a colony built an hour ago.
  for (var i = perBrush.length - 1; i >= 0; i--) {
    for (final p in perBrush[i]) {
      final c = p.cell;
      final t = p.target;
      final prior = byLeaf[c];
      // At the cap, cells already present may still deepen but no new cell
      // enters. Never abandon the remaining brushes wholesale (the old
      // `break` did): in tick order the LAST brushes are the newest edits —
      // the fresh impact the player is watching — and dropping every one of
      // their targets because a colony elsewhere filled the budget left new
      // craters meshed at the coarse rate.
      if (prior == null && byLeaf.length >= cap) continue;
      if (prior == null || t.level > prior.level) byLeaf[c] = t;
    }
  }
  // Lineage collapse: a target whose cell is an ANCESTOR of another kept
  // target's cell is subsumed — the split walk toward the deeper cell passes
  // through the shallower cell, leaving every leaf of that region at least
  // one level past the shallow demand. The map above cannot express this:
  // its keys embed the level, so same-spot different-level targets (a small
  // crater inside a big one) never collide there.
  final subsumed = <ChunkKey>{};
  for (final c in byLeaf.keys) {
    for (final a in c.ancestors) {
      if (byLeaf.containsKey(a)) subsumed.add(a);
    }
  }
  return [
    for (final e in byLeaf.entries)
      if (!subsumed.contains(e.key)) e.value
  ];
}

/// Refinement targets covering [brush]'s footprint on a body of [radiusM].
///
/// Returns the centre plus a ring on the footprint's edge rather than a single
/// point: a crater usually straddles several chunks at the depth it needs, and
/// refining only the one under its centre would leave the rim meshed at the
/// coarse rate. [voxelsAcrossBrush] is how many voxels should span the brush's
/// diameter — 8 is enough for a crater to read as a bowl rather than a dent.
///
/// Reads only the brush's kind, centreBF, radiusM, minVoxelM, falloffM,
/// lateralReachM and endBF. [RefinementMemo] keys on exactly those; a new
/// dependency here must join its key or the memo serves stale targets.
List<TerrainRefinement> refinementsFor(
  TerrainBrush brush,
  double radiusM,
  int resolution, {
  double voxelsAcrossBrush = 8,
  int maxLevel = 20,
  int ringSamples = 8,
}) {
  final dist = brush.centreBF.length;
  if (dist <= 0 || radiusM <= 0) return const [];
  final dir = brush.centreBF.normalized;
  // A LEVELLED surface is a plane, and a plane meshes exactly at any level, so
  // its interior needs no refinement at all — only the falloff ring at its
  // edge, where the surface actually bends back into the natural ground. A
  // crater is curved throughout and keeps the fine interior it needs.
  final flatTopped = brush.kind == TerrainBrushKind.pad ||
      brush.kind == TerrainBrushKind.padBox ||
      brush.kind == TerrainBrushKind.padPoly ||
      brush.kind == TerrainBrushKind.cutFill;
  // The brush's own voxel floor wins over the radius-derived target: a
  // city's brushes ask to be meshed coarse on purpose (see
  // [TerrainBrush.minVoxelM]); a floor of 0 leaves the derivation alone.
  final targetVoxelM =
      math.max(brush.radiusM * 2.0 / voxelsAcrossBrush, brush.minVoxelM);

  // A cutFill corridor is ELONGATED: its lateralReachM includes the corridor
  // HALF-LENGTH, so the generic edge ring below would trace a circle around
  // the midpoint that clears the corridor entirely — every target lands on
  // untouched ground while the falloff shoulders along the corridor's length,
  // the only place a levelled cut actually curves, get no refinement at all.
  // Sample the two shoulder lines and the end caps instead.
  if (brush.kind == TerrainBrushKind.cutFill && brush.endBF != null) {
    final end = brush.endBF!;
    final start = brush.centreBF * 2.0 - end;
    final axis = end - start;
    final len = axis.length;
    final lat = brush.radiusM + brush.falloffM;
    if (len <= 0 || lat <= 0) return const [];
    final aDir = axis / len;
    final targets = <TerrainRefinement>[];
    void addAt(Vector3 p) {
      if (p.lengthSquared <= 0) return;
      final d = p.normalized;
      targets.add(TerrainRefinement(
          d,
          levelForVoxelSize(d, radiusM, resolution, targetVoxelM,
              maxLevel: maxLevel)));
    }

    // Shoulder samples spaced about one shoulder-width apart (bounded, so a
    // very long road stays a bounded list — mergedRefinementsFor dedupes the
    // overlap against the chunks they land in anyway).
    final n = (len / math.max(lat, len / 64)).ceil().clamp(1, 64);
    for (var i = 0; i <= n; i++) {
      final p = start + aDir * (len * i / n);
      var side = aDir.cross(p.normalized);
      final sl = side.length;
      if (sl < 1e-9) continue;
      side = side / sl;
      addAt(p + side * lat);
      addAt(p - side * lat);
    }
    addAt(start - aDir * lat);
    addAt(end + aDir * lat);
    return targets;
  }

  final out = <TerrainRefinement>[
    if (!flatTopped)
      TerrainRefinement(
          dir,
          levelForVoxelSize(dir, radiusM, resolution, targetVoxelM,
              maxLevel: maxLevel)),
  ];

  // Ring on the true surface footprint (lateral reach), not the bounding
  // sphere — a pad's bound is inflated by its vertical cut budget, and a ring
  // placed there refines chunks the pad never touches.
  final alpha = math.asin((brush.lateralReachM / dist).clamp(0.0, 1.0));
  if (alpha <= 0) return out;
  final seed = dir.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
  final tangent = seed.cross(dir).normalized;
  final bitangent = dir.cross(tangent);
  final sin = math.sin(alpha), cos = math.cos(alpha);
  for (var i = 0; i < ringSamples; i++) {
    final phi = 2 * math.pi * i / ringSamples;
    final d = (dir * cos +
            tangent * (math.cos(phi) * sin) +
            bitangent * (math.sin(phi) * sin))
        .normalized;
    out.add(TerrainRefinement(
        d,
        levelForVoxelSize(d, radiusM, resolution, targetVoxelM,
            maxLevel: maxLevel)));
  }
  return out;
}

/// A hysteretic quadtree over the six cube faces.
///
/// Hysteresis is not optional. With a single threshold, a chunk sitting on the
/// boundary splits and merges on alternate frames, and every flip is a remesh
/// plus a GPU upload. [mergeRatio] separates the two thresholds so a chunk has
/// to get materially smaller before it collapses again.
class TerrainLodTree {
  TerrainLodTree({
    this.splitPx = 200,
    this.mergeRatio = 2.2,
    this.maxLevel = 12,
    this.maxRefineLevel = 20,
  })  : assert(splitPx > 0),
        assert(mergeRatio > 1, 'merge must be below split or it will thrash'),
        assert(maxRefineLevel >= maxLevel),
        _leaves = {...ChunkKey.roots},
        _balanced = {...ChunkKey.roots};

  /// Split a leaf whose projected radius exceeds this many pixels.
  final double splitPx;

  /// Merge siblings once the parent projects below `splitPx / mergeRatio`.
  final double mergeRatio;

  /// Deepest level selection will descend to. At level 12 a Moon-sized body's
  /// cells are ~700 m across, so this is a safety stop, not the working limit.
  final int maxLevel;

  /// Deepest level a [TerrainRefinement] may force. Above [maxLevel] on
  /// purpose: screen-space selection has no reason to descend to metre-scale
  /// cells, but a crater does. Level 20 is ~1.5 m cells on a Moon-sized body,
  /// well past anything the impact sizing produces.
  final int maxRefineLevel;

  /// SELECTION state: the post-select, post-refinement set — WITHOUT the 2:1
  /// balance staircase. The staircase is derived per frame and never stored:
  /// storing it (the old behaviour) fed the next frame's merge pass a wall of
  /// zero-px sibling quads that were not pinned, so every quiet frame spent
  /// several select-loop iterations collapsing the staircase level by level
  /// only for enforceBalance to rebuild it identically — pure churn the
  /// pinned() guard was supposed to remove.
  Set<ChunkKey> _leaves;

  /// What callers see: [_leaves] with the balance staircase applied.
  Set<ChunkKey> _balanced;

  /// Pixel threshold below which a parent's four children collapse.
  double get mergePx => splitPx / mergeRatio;

  /// The current leaf set — always a complete tiling of the body, 2:1
  /// balanced.
  Set<ChunkKey> get leaves => Set.unmodifiable(_balanced);

  /// Reset to the six face roots.
  void reset() {
    _leaves = {...ChunkKey.roots};
    _balanced = {...ChunkKey.roots};
  }

  /// Re-select against this frame's projection and re-balance.
  ///
  /// Returns the new leaf set. [maxIterations] bounds one frame's worth of
  /// descent: a camera teleporting from orbit to the ground needs several
  /// split rounds, but the loop must never be unbounded.
  ///
  /// [refine] forces extra depth where deformation needs it, applied AFTER
  /// screen-space selection so the merge pass cannot immediately undo it — a
  /// crater's chunks project far below the merge threshold, which is exactly
  /// why they need forcing. The 2:1 balance then still runs over the result, so
  /// a refined island is joined to the coarse terrain around it by a legal
  /// staircase rather than a cliff.
  Set<ChunkKey> update(
    ChunkApparentPx apparentPx, {
    int maxIterations = 32,
    List<TerrainRefinement> refine = const [],
  }) {
    // A refined island's leaves project ~0 px, so without this guard the
    // merge pass collapsed the island level by level every frame and
    // `_applyRefinements` re-split it — a stable leaf set, but bought with
    // ~(levels-forced) iterations of the whole select loop per frame. A
    // parent that a refinement target still demands depth under is pinned:
    // its children never merge, the island persists, and on a quiet frame
    // the loop exits after one iteration having changed nothing.
    bool pinned(ChunkKey parent) {
      for (final t in refine) {
        if (parent.level < t.level.clamp(0, maxRefineLevel) &&
            parent.contains(t.direction)) {
          return true;
        }
      }
      return false;
    }

    final leaves = Set<ChunkKey>.of(_leaves);
    for (var iter = 0; iter < maxIterations; iter++) {
      var changed = false;

      final toSplit = [
        for (final k in leaves)
          if (k.level < maxLevel && apparentPx(k) > splitPx) k,
      ];
      for (final k in toSplit) {
        leaves.remove(k);
        leaves.addAll(k.children);
        changed = true;
      }

      // Group by parent; a group of four leaf siblings is a merge candidate.
      // Groups are disjoint (a leaf has one parent), so applying them all in
      // one pass is safe.
      final byParent = <ChunkKey, List<ChunkKey>>{};
      for (final k in leaves) {
        final p = k.parent;
        if (p != null) (byParent[p] ??= []).add(k);
      }
      for (final e in byParent.entries) {
        if (e.value.length == 4 &&
            apparentPx(e.key) < mergePx &&
            !pinned(e.key)) {
          leaves.removeAll(e.value);
          leaves.add(e.key);
          changed = true;
        }
      }

      if (!changed) break;
    }
    // Refinements become part of the persistent state (pinned() protects them
    // next frame); the balance staircase is derived, returned, and DISCARDED —
    // see [_leaves]. On a quiet frame the loop above finds nothing to do and
    // exits after one iteration, as the pinned() comment promises.
    _leaves = _applyRefinements(leaves, refine);
    _balanced = enforceBalance(_leaves);
    return this.leaves;
  }

  /// Split down to each target's demanded level.
  ///
  /// Walks the quadtree from whichever leaf currently covers the target toward
  /// the level-N cell containing it, splitting one level at a time. Using
  /// [leafCovering] against the deep key rather than scanning for a containing
  /// leaf keeps this a handful of map probes per target instead of a scan of
  /// the whole leaf set.
  Set<ChunkKey> _applyRefinements(
      Set<ChunkKey> leaves, List<TerrainRefinement> targets) {
    if (targets.isEmpty) return leaves;
    final out = Set<ChunkKey>.of(leaves);
    for (final t in targets) {
      final want = t.level.clamp(0, maxRefineLevel);
      final deep = chunkAt(t.direction, want);
      // At most one split per level, plus one probe to discover we are done.
      for (var i = 0; i <= want; i++) {
        final owner = leafCovering(out, deep);
        // Null means the region is ALREADY finer than the target — another
        // target got there first — so there is nothing left to force.
        if (owner == null || owner.level >= want) break;
        out.remove(owner);
        out.addAll(owner.children);
      }
    }
    return out;
  }
}
