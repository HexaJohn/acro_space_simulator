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
/// Both in the body-fixed frame. A surface point `P` on a sphere of radius `R`
/// is visible from `E` exactly when `P·E >= R^2`; [marginM] pulls the cut back
/// so a chunk whose centre has just dipped under still counts (its near edge
/// is likely still visible).
bool isBeyondHorizon(
  ChunkKey chunk,
  Vector3 eyeBF,
  double radiusM, {
  double marginM = 0,
}) {
  final p = chunk.centreDirection * radiusM;
  return p.dot(eyeBF) < radiusM * (radiusM - marginM);
}

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
  for (var level = 0; level <= maxLevel; level++) {
    final voxelM = chunkAt(dir, level).circumradiusM(radiusM) * 2.0 / resolution;
    if (voxelM <= targetVoxelM) return level;
  }
  return maxLevel;
}

/// Refinement targets covering [brush]'s footprint on a body of [radiusM].
///
/// Returns the centre plus a ring on the footprint's edge rather than a single
/// point: a crater usually straddles several chunks at the depth it needs, and
/// refining only the one under its centre would leave the rim meshed at the
/// coarse rate. [voxelsAcrossBrush] is how many voxels should span the brush's
/// diameter — 8 is enough for a crater to read as a bowl rather than a dent.
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
  final targetVoxelM = brush.radiusM * 2.0 / voxelsAcrossBrush;
  final out = <TerrainRefinement>[
    TerrainRefinement(
        dir, levelForVoxelSize(dir, radiusM, resolution, targetVoxelM,
            maxLevel: maxLevel)),
  ];

  final alpha = math.asin((brush.boundingRadiusM / dist).clamp(0.0, 1.0));
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
        _leaves = {...ChunkKey.roots};

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

  Set<ChunkKey> _leaves;

  /// Pixel threshold below which a parent's four children collapse.
  double get mergePx => splitPx / mergeRatio;

  /// The current leaf set — always a complete tiling of the body.
  Set<ChunkKey> get leaves => Set.unmodifiable(_leaves);

  /// Reset to the six face roots.
  void reset() => _leaves = {...ChunkKey.roots};

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
        if (e.value.length == 4 && apparentPx(e.key) < mergePx) {
          leaves.removeAll(e.value);
          leaves.add(e.key);
          changed = true;
        }
      }

      if (!changed) break;
    }
    _leaves = enforceBalance(_applyRefinements(leaves, refine));
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
