// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_lod.dart';
import 'package:flutter_test/flutter_test.dart';

const double _radius = 1.7374e6; // Moon-ish datum
const int _resolution = 24;

TerrainBrush _crater(Vector3 dir, {double radiusM = 16, double minVoxelM = 0}) =>
    TerrainBrush.crater(
      contactBF: dir.normalized * _radius,
      normalBF: dir.normalized,
      radiusM: radiusM,
      depthM: radiusM * 0.4,
      rimHeightM: radiusM * 0.08,
      minVoxelM: minVoxelM,
    );

/// Selection that never splits, so anything below is forced refinement alone.
double _noSplit(ChunkKey k) => 0;

void main() {
  group('levelForVoxelSize', () {
    test('finds a level meeting the target and no coarser one', () {
      final dir = const Vector3(0.3, 0.4, 0.86).normalized;
      const target = 1.0; // metres per voxel
      final level = levelForVoxelSize(dir, _radius, _resolution, target);
      double voxelAt(int l) =>
          chunkAt(dir, l).circumradiusM(_radius) * 2.0 / _resolution;
      expect(voxelAt(level), lessThanOrEqualTo(target));
      expect(voxelAt(level - 1), greaterThan(target),
          reason: 'should be the SHALLOWEST level that qualifies');
    });

    test('deepens as the target shrinks', () {
      final dir = Vector3.unitZ;
      var previous = -1;
      for (final target in [1000.0, 100.0, 10.0, 1.0]) {
        final level = levelForVoxelSize(dir, _radius, _resolution, target);
        expect(level, greaterThan(previous));
        previous = level;
      }
    });

    test('a metre-scale crater needs far more depth than LOD ever selects', () {
      // The whole reason forced refinement exists: the default selection cap is
      // 12, and a 16 m crater needs well past it to move a single vertex.
      final level = levelForVoxelSize(Vector3.unitZ, _radius, _resolution, 4.0);
      expect(level, greaterThan(TerrainLodTree().maxLevel));
    });

    test('clamps at maxLevel instead of looping forever', () {
      expect(
        levelForVoxelSize(Vector3.unitZ, _radius, _resolution, 1e-9,
            maxLevel: 14),
        14,
      );
    });

    // The corners and seams are where the cube-to-sphere map is least
    // uniform, so they go in alongside the random sample.
    final awkward = [
      const Vector3(1, 1, 1).normalized,
      const Vector3(-1, 1, -1).normalized,
      const Vector3(1, 1, 0).normalized,
      const Vector3(0, -1, 1).normalized,
      Vector3.unitX,
      -Vector3.unitY,
    ];
    Vector3 randomDir(math.Random rng) {
      while (true) {
        final d = Vector3(rng.nextDouble() * 2 - 1, rng.nextDouble() * 2 - 1,
            rng.nextDouble() * 2 - 1);
        if (d.length > 0.1) return d.normalized;
      }
    }

    test('cell size never grows with depth along a direction', () {
      // The property the estimate-and-walk relies on: a child sits inside
      // its parent, so its circumradius is no larger. Without it a local
      // walk could settle on a level the full scan would not.
      final rng = math.Random(11);
      final dirs = [...awkward, for (var i = 0; i < 300; i++) randomDir(rng)];
      for (final dir in dirs) {
        var previous = double.infinity;
        for (var level = 0; level <= 20; level++) {
          final r = chunkAt(dir, level).circumradiusM(_radius);
          expect(r, lessThanOrEqualTo(previous),
              reason: 'level $level grew along $dir');
          previous = r;
        }
      }
    });

    test('the walk agrees with an exhaustive scan from level 0', () {
      // REGRESSION GUARD: levelForVoxelSize used to scan up from level 0 —
      // ~15 chunk lookups per call, nine calls per brush, a million for a
      // city. It now starts from a log2 estimate and walks; this pins that
      // the answer is unchanged everywhere, including where the estimate
      // is off by a level or two.
      int scan(Vector3 dir, double target, int maxLevel) {
        for (var level = 0; level <= maxLevel; level++) {
          final v =
              chunkAt(dir, level).circumradiusM(_radius) * 2.0 / _resolution;
          if (v <= target) return level;
        }
        return maxLevel;
      }

      final rng = math.Random(7);
      final dirs = [...awkward, for (var i = 0; i < 300; i++) randomDir(rng)];
      for (final dir in dirs) {
        // Body-scale down to sub-voxel, log-uniform, plus the level-0 edge.
        final targets = [
          math.pow(10, rng.nextDouble() * 8 - 2).toDouble(),
          math.pow(10, rng.nextDouble() * 8 - 2).toDouble(),
          _radius * 10,
        ];
        for (final target in targets) {
          for (final maxLevel in const [6, 14, 20]) {
            expect(
              levelForVoxelSize(dir, _radius, _resolution, target,
                  maxLevel: maxLevel),
              scan(dir, target, maxLevel),
              reason: 'dir $dir target $target maxLevel $maxLevel',
            );
          }
        }
      }
    });
  });

  group('refinementsFor', () {
    test('covers the footprint, not just the centre', () {
      final dir = const Vector3(0.5, -0.2, 0.84).normalized;
      final targets = refinementsFor(_crater(dir), _radius, _resolution);
      expect(targets.length, greaterThan(1));
      // Every target is a real unit direction near the crater.
      for (final t in targets) {
        expect(t.direction.length, closeTo(1.0, 1e-9));
        expect(t.direction.dot(dir), greaterThan(0.999));
      }
      // The ring genuinely reaches other cells at the demanded depth, which is
      // the point — refining only the centre leaves the rim coarse.
      final level = targets.first.level;
      final cells = {for (final t in targets) chunkAt(t.direction, level)};
      expect(cells.length, greaterThan(1));
    });

    test('a bigger crater needs less depth', () {
      final dir = Vector3.unitX;
      final small = refinementsFor(_crater(dir, radiusM: 5), _radius, _resolution);
      final big = refinementsFor(_crater(dir, radiusM: 500), _radius, _resolution);
      expect(big.first.level, lessThan(small.first.level));
    });

    test('a voxel floor caps the depth a small brush can demand', () {
      final dir = Vector3.unitX;
      final fine = refinementsFor(_crater(dir), _radius, _resolution);
      final coarse =
          refinementsFor(_crater(dir, minVoxelM: 15), _radius, _resolution);
      expect(coarse.first.level, lessThan(fine.first.level));
      // The floor IS the target: the level a 15 m voxel needs, no deeper.
      expect(coarse.first.level,
          levelForVoxelSize(dir, _radius, _resolution, 15));
      // A floor finer than the radius already derives changes nothing — the
      // player's crater keeps the depth its size asks for.
      final noop =
          refinementsFor(_crater(dir, minVoxelM: 1), _radius, _resolution);
      expect(noop.first.level, fine.first.level);
    });

    test('a brush at the body centre is not refinable', () {
      final degenerate =
          TerrainBrush.sphere(centreBF: Vector3.zero, radiusM: 10);
      expect(refinementsFor(degenerate, _radius, _resolution), isEmpty);
    });
  });

  group('body-wide coverage', () {
    // Terrain covers the whole body now rather than a ring under the craft, so
    // the question that decides whether that is affordable is how many leaves
    // survive horizon culling at a realistic view. LOD is what makes it cheap:
    // distant chunks stay coarse, so the count grows far slower than area.

    /// Screen-space size of a chunk for an eye at [eyeBF], with a plausible
    /// focal length (a ~1000 px viewport over a 60-degree field).
    ChunkApparentPx projector(Vector3 eyeBF, double splitPx) => (k) {
          final radius = k.circumradiusM(_radius);
          if (isBeyondHorizon(k, eyeBF, _radius, marginM: radius)) return 0;
          final d = (k.centreDirection * _radius - eyeBF).length;
          if (d <= 0) return 0;
          return radius / d * 900.0;
        };

    /// Leaves this side of the horizon — what the renderer would mesh.
    int visibleCount(Set<ChunkKey> leaves, Vector3 eyeBF) {
      var n = 0;
      for (final k in leaves) {
        if (!isBeyondHorizon(k, eyeBF, _radius,
            marginM: k.circumradiusM(_radius))) {
          n++;
        }
      }
      return n;
    }

    test('stays within the resident cap from orbit down to the ground', () {
      // 512 is TerrainNodes.maxResidentChunks. Exceeding it is not fatal — the
      // renderer drops the farthest — but needing to would mean the horizon is
      // being truncated, which is exactly the artefact body-wide coverage is
      // supposed to remove.
      for (final altitude in [2.0e6, 4.0e5, 1.0e5, 2.0e4, 5.0e3, 500.0, 50.0]) {
        final eye = Vector3(_radius + altitude, 0, 0);
        final tree = TerrainLodTree(splitPx: 220);
        for (var frame = 0; frame < 12; frame++) {
          tree.update(projector(eye, 220));
        }
        final visible = visibleCount(tree.leaves, eye);
        expect(visible, lessThanOrEqualTo(1024),
            reason: 'altitude ${altitude.toStringAsFixed(0)} m needed '
                '$visible chunks');
        expect(visible, greaterThan(0));
        expect(isBalanced(tree.leaves), isTrue);
      }
    });

    test('the near hemisphere is fully covered, with no holes', () {
      // A complete tiling matters more with body-wide coverage than it did
      // with a ring: a gap now shows as a hole straight through the planet
      // rather than as terrain simply stopping.
      final eye = Vector3(_radius + 50000, 0, 0);
      final tree = TerrainLodTree(splitPx: 220);
      for (var frame = 0; frame < 12; frame++) {
        tree.update(projector(eye, 220));
      }
      final rng = math.Random(17);
      for (var i = 0; i < 400; i++) {
        var d = Vector3(rng.nextDouble() * 2 - 1, rng.nextDouble() * 2 - 1,
            rng.nextDouble() * 2 - 1);
        if (d.lengthSquared < 1e-6) continue;
        d = d.normalized;
        if (d.x < 0.2) continue; // only the side facing the eye
        expect(tree.leaves.where((k) => k.contains(d)).length, 1,
            reason: 'no single leaf covers $d');
      }
    });

    test('coarse far from the eye, fine beneath it', () {
      // The property that makes full coverage affordable at all.
      final eye = Vector3(_radius + 5000, 0, 0);
      final tree = TerrainLodTree(splitPx: 220);
      for (var frame = 0; frame < 16; frame++) {
        tree.update(projector(eye, 220));
      }
      final beneath = tree.leaves.firstWhere((k) => k.contains(Vector3.unitX));
      // "Far" has to be measured against the HORIZON, not against a fixed
      // angle. From 5 km up on a Moon-sized body the visible cap is only ~4.3
      // degrees across, so anything picked by a generous angular threshold is
      // already over the edge and culled.
      final cosHorizon = _radius / (_radius + 5000);
      final halfway = 1.0 - (1.0 - cosHorizon) * 0.5;
      final far = tree.leaves
          .where((k) =>
              !isBeyondHorizon(k, eye, _radius,
                  marginM: k.circumradiusM(_radius)) &&
              k.centreDirection.dot(Vector3.unitX) < halfway)
          .toList();
      expect(far, isNotEmpty);
      final coarsest = far.map((k) => k.level).reduce(math.min);
      expect(coarsest, lessThan(beneath.level),
          reason: 'distant terrain should be meshed at a coarser level');
    });
  });

  group('TerrainLodTree refinement', () {
    test('with no targets the tree is untouched', () {
      final tree = TerrainLodTree();
      expect(tree.update(_noSplit), {...ChunkKey.roots});
    });

    test('forces a leaf down to the demanded level', () {
      final dir = const Vector3(0.2, 0.5, 0.84).normalized;
      final tree = TerrainLodTree();
      final leaves = tree.update(_noSplit,
          refine: [TerrainRefinement(dir, 15)]);
      final owner = leafCovering(leaves, chunkAt(dir, 15));
      expect(owner, isNotNull);
      expect(owner!.level, greaterThanOrEqualTo(15));
    });

    test('refinement survives the merge pass', () {
      // Selection wants everything merged (apparentPx 0), so a refined island
      // only persists if refinement is applied AFTER selection. Run several
      // frames — a single frame could pass by accident.
      final dir = const Vector3(1, 0.3, 0.2).normalized;
      final tree = TerrainLodTree();
      for (var i = 0; i < 5; i++) {
        tree.update(_noSplit, refine: [TerrainRefinement(dir, 14)]);
      }
      final owner = leafCovering(tree.leaves, chunkAt(dir, 14));
      expect(owner!.level, greaterThanOrEqualTo(14));
    });

    test('drops the island once the targets stop arriving', () {
      final dir = Vector3.unitY;
      final tree = TerrainLodTree();
      tree.update(_noSplit, refine: [TerrainRefinement(dir, 13)]);
      expect(tree.leaves.length, greaterThan(6));
      for (var i = 0; i < 30; i++) {
        tree.update(_noSplit);
      }
      expect(tree.leaves, {...ChunkKey.roots},
          reason: 'a crater left behind should not pin a deep quadtree forever');
    });

    test('stays balanced and a complete tiling around the island', () {
      final dir = const Vector3(0.6, 0.6, 0.52).normalized;
      final tree = TerrainLodTree();
      final leaves = tree.update(_noSplit,
          refine: refinementsFor(_crater(dir), _radius, _resolution,
              maxLevel: 18));
      expect(isBalanced(leaves), isTrue);
      // Complete tiling: every sampled direction resolves to exactly one leaf.
      // Probes are deliberately off-axis — `ChunkKey.contains` is inclusive on
      // both edges, so a direction landing exactly on a cell boundary (a face
      // centre such as +X, or a cube corner) is legitimately reported by all
      // the cells meeting there.
      for (final probe in [
        dir,
        const Vector3(0.83, 0.31, -0.47).normalized,
        const Vector3(-0.21, 0.77, 0.60).normalized,
        const Vector3(-0.64, -0.53, 0.55).normalized,
        (-dir + const Vector3(0.03, 0.017, -0.021)).normalized,
      ]) {
        final owners = leaves.where((k) => k.contains(probe));
        expect(owners.length, 1, reason: 'no single leaf covers $probe');
      }
    });

    test('honours maxRefineLevel', () {
      final dir = const Vector3(0.31, 0.44, 0.84).normalized;
      final tree = TerrainLodTree(maxLevel: 8, maxRefineLevel: 9);
      final leaves =
          tree.update(_noSplit, refine: [TerrainRefinement(dir, 40)]);
      expect(leaves.map((k) => k.level).reduce((a, b) => a > b ? a : b), 9);
    });

    test('a quiet frame quiesces in one select iteration', () {
      // REGRESSION: the stored leaf set used to INCLUDE the 2:1 balance
      // staircase around a refined island — complete zero-px sibling quads
      // that are not pinned. Every quiet frame the merge pass collapsed that
      // staircase level by level (several full select iterations, each an
      // apparentPx scan of every leaf) and enforceBalance rebuilt it
      // identically. The staircase is derived state and must never feed the
      // next frame's selection.
      final dir = const Vector3(0.31, -0.22, 1).normalized;
      final refine = [TerrainRefinement(dir, 10)];
      final tree = TerrainLodTree();
      var calls = 0;
      double px(ChunkKey k) {
        calls++;
        return 0;
      }

      tree.update(px, refine: refine); // establish the island
      tree.update(px, refine: refine); // settle
      final before = tree.leaves;
      calls = 0;
      tree.update(px, refine: refine); // quiet frame
      expect(tree.leaves, before, reason: 'quiet frame must not move leaves');
      // One iteration costs about |leaves| (split scan) + |merge groups|.
      // The staircase churn measured ~2.3x the leaf count and 4+ iterations.
      expect(calls, lessThan(before.length * 2),
          reason: '$calls apparentPx calls for ${before.length} leaves — '
              'the select loop is re-churning the balance staircase');
    });

    test('several targets in one region do not fight each other', () {
      final dir = const Vector3(0.1, 0.2, 0.97).normalized;
      final tree = TerrainLodTree();
      final targets = refinementsFor(_crater(dir), _radius, _resolution,
          maxLevel: 17);
      final leaves = tree.update(_noSplit, refine: targets);
      for (final t in targets) {
        final owner = leafCovering(leaves, chunkAt(t.direction, t.level));
        expect(owner!.level, greaterThanOrEqualTo(t.level));
      }
      expect(isBalanced(leaves), isTrue);
    });
  });
}
