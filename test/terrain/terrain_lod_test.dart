// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_lod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every direction is covered by exactly one leaf — i.e. the set really is a
/// partition of the body, with no gap and no overlap.
void _expectTiling(Set<ChunkKey> leaves, {int samples = 400, int seed = 5}) {
  final rng = math.Random(seed);
  for (var i = 0; i < samples; i++) {
    final z = rng.nextDouble() * 2 - 1;
    final a = rng.nextDouble() * 2 * math.pi;
    final r = math.sqrt(1 - z * z);
    final d = Vector3(r * math.cos(a), r * math.sin(a), z);
    final hits = leaves.where((k) => k.contains(d)).length;
    expect(hits, 1, reason: 'direction $d covered $hits times');
  }
}

/// Split a random subset of leaves, [rounds] times — an arbitrary unbalanced
/// tree to throw at [enforceBalance].
Set<ChunkKey> _randomlyRefined(math.Random rng,
    {int rounds = 4, double p = 0.25, int maxLevel = 8}) {
  var leaves = {...ChunkKey.roots};
  for (var i = 0; i < rounds; i++) {
    final next = <ChunkKey>{};
    for (final k in leaves) {
      if (k.level < maxLevel && rng.nextDouble() < p) {
        next.addAll(k.children);
      } else {
        next.add(k);
      }
    }
    leaves = next;
  }
  return leaves;
}

void main() {
  group('leafCovering', () {
    test('finds the leaf itself, an ancestor, or nothing when finer', () {
      final roots = {...ChunkKey.roots};
      final root = ChunkKey.root(CubeFace.posZ);
      expect(leafCovering(roots, root), root);

      // A deep key is covered by its root while the tree is coarse.
      final deep = ChunkKey(CubeFace.posZ, 4, 3, 9);
      expect(leafCovering(roots, deep), root);

      // Once the root is split, a deep key resolves to the child above it:
      // (u,v) = (3,9) at level 4 shifts down 3 levels to (0,1).
      final split = {...roots}..remove(root);
      split.addAll(root.children);
      expect(leafCovering(split, deep), const ChunkKey(CubeFace.posZ, 1, 0, 1));
      // ...and the root itself is no longer covered by any single leaf: its
      // region is now subdivided finer than the key.
      expect(leafCovering(split, root), isNull);
    });
  });

  group('enforceBalance', () {
    test('roots alone are already balanced', () {
      expect(isBalanced({...ChunkKey.roots}), isTrue);
    });

    test('detects a 2-level step as unbalanced', () {
      // Refine one root twice down a single corner, leaving its neighbours at
      // level 0 — a 2:1 violation by construction.
      final leaves = {...ChunkKey.roots};
      final root = ChunkKey.root(CubeFace.posZ);
      leaves.remove(root);
      leaves.addAll(root.children);
      final child = root.children.first;
      leaves.remove(child);
      leaves.addAll(child.children);
      expect(isBalanced(leaves), isFalse);

      final fixed = enforceBalance(leaves);
      expect(isBalanced(fixed), isTrue);
      _expectTiling(fixed);
    });

    test('random split sequences always balance, and stay a tiling', () {
      // Plan §8: 2:1 balance invariant after random split/merge sequences.
      for (var seed = 0; seed < 25; seed++) {
        final rng = math.Random(seed);
        final raw = _randomlyRefined(rng, rounds: 4, p: 0.3, maxLevel: 7);
        _expectTiling(raw, samples: 60, seed: seed);

        final balanced = enforceBalance(raw);
        expect(isBalanced(balanced), isTrue, reason: 'seed $seed');
        _expectTiling(balanced, samples: 60, seed: seed);

        // Balancing only ever adds detail.
        expect(balanced.length, greaterThanOrEqualTo(raw.length),
            reason: 'seed $seed');
        for (final k in raw) {
          final owner = leafCovering(balanced, k);
          expect(owner == null || owner == k, isTrue,
              reason: 'seed $seed: $k was coarsened to $owner');
        }
      }
    });

    test('is idempotent', () {
      final rng = math.Random(31337);
      final once = enforceBalance(_randomlyRefined(rng, rounds: 5, p: 0.35));
      final twice = enforceBalance(once);
      expect(twice, once);
    });

    test('balances across face seams, not just within a face', () {
      // Refine deep in a corner cell so the violation is forced to propagate
      // onto the two adjacent faces.
      var leaves = {...ChunkKey.roots};
      var k = ChunkKey.root(CubeFace.posX);
      for (var i = 0; i < 4; i++) {
        leaves.remove(k);
        leaves.addAll(k.children);
        k = k.children.first; // walks toward the (s0,t0) face corner
      }
      final balanced = enforceBalance(leaves);
      expect(isBalanced(balanced), isTrue);
      // The refinement must have spilled onto other faces.
      final faces = balanced.where((c) => c.level > 0).map((c) => c.face).toSet();
      expect(faces.length, greaterThan(1),
          reason: 'corner refinement never crossed a seam: $faces');
    });
  });

  group('TerrainLodTree', () {
    /// Apparent size that grows as a chunk nears [focus] — a stand-in for a
    /// camera hovering over that direction.
    // gain is set so a level-0 face already clears the default 200 px split
    // threshold; below ~350 nothing ever refines and the tests are vacuous.
    ChunkApparentPx towards(Vector3 focus, {double gain = 600}) {
      return (k) {
        final cos = k.centreDirection.dot(focus).clamp(-1.0, 1.0);
        final ang = math.acos(cos);
        // Chunk angular size halves each level; nearer the focus reads bigger.
        final size = (math.pi / 2) / (1 << k.level);
        return gain * size / (1 + ang * 4);
      };
    }

    test('starts at the six roots', () {
      final tree = TerrainLodTree();
      expect(tree.leaves.length, 6);
      expect(tree.leaves, {...ChunkKey.roots});
    });

    test('refines toward the focus and stays a balanced tiling', () {
      final focus = const Vector3(0.2, -0.4, 0.9).normalized;
      final tree = TerrainLodTree(splitPx: 200);
      final leaves = tree.update(towards(focus));

      expect(leaves.length, greaterThan(6));
      expect(isBalanced(leaves), isTrue);
      _expectTiling(leaves);

      // The chunk under the focus is finer than one on the far side.
      final near = leaves.firstWhere((k) => k.contains(focus));
      final far = leaves.firstWhere((k) => k.contains(-focus));
      expect(near.level, greaterThan(far.level));
    });

    test('respects maxLevel', () {
      final tree = TerrainLodTree(splitPx: 1, maxLevel: 3);
      final leaves = tree.update(towards(const Vector3(0, 0, 1)));
      expect(leaves.every((k) => k.level <= 3), isTrue,
          reason: 'max was ${leaves.map((k) => k.level).reduce(math.max)}');
    });

    test('converges: a second update with the same view changes nothing', () {
      final focus = const Vector3(1, 0.2, 0.1).normalized;
      final tree = TerrainLodTree();
      final a = tree.update(towards(focus));
      final b = tree.update(towards(focus));
      expect(b, a);
    });

    test('hysteresis: a chunk on the split threshold does not thrash', () {
      // Park every chunk's apparent size between mergePx and splitPx. Nothing
      // should move, in either direction, on any frame.
      final tree = TerrainLodTree(splitPx: 200, mergeRatio: 2.2);
      final mid = (tree.splitPx + tree.mergePx) / 2;
      final before = tree.update((_) => mid);
      for (var frame = 0; frame < 10; frame++) {
        expect(tree.update((_) => mid), before, reason: 'frame $frame');
      }
    });

    test('merges back when the camera pulls away', () {
      final focus = const Vector3(0, 1, 0);
      final tree = TerrainLodTree();
      final refined = tree.update(towards(focus, gain: 600));
      expect(refined.length, greaterThan(6));

      // Everything now projects below the merge threshold.
      final collapsed = tree.update((_) => 0);
      expect(collapsed, {...ChunkKey.roots});
    });

    test('reset returns to the roots', () {
      final tree = TerrainLodTree();
      tree.update(towards(const Vector3(0, 0, 1), gain: 600));
      expect(tree.leaves.length, greaterThan(6));
      tree.reset();
      expect(tree.leaves, {...ChunkKey.roots});
    });

    test('a moving camera keeps the tree balanced every frame', () {
      final tree = TerrainLodTree();
      for (var i = 0; i < 24; i++) {
        final a = i / 24 * 2 * math.pi;
        final focus = Vector3(math.cos(a), math.sin(a), 0.3).normalized;
        final leaves = tree.update(towards(focus, gain: 500));
        expect(isBalanced(leaves), isTrue, reason: 'frame $i');
        _expectTiling(leaves, samples: 40, seed: i);
      }
    });
  });

  group('isBeyondHorizon', () {
    const r = 1.7374e6;

    test('the sub-eye chunk is visible, the antipode is not', () {
      final eye = const Vector3(0, 0, 1) * (r + 100000);
      final near = chunkAt(const Vector3(0, 0, 1), 4);
      final far = chunkAt(const Vector3(0, 0, -1), 4);
      expect(isBeyondHorizon(near, eye, r), isFalse);
      expect(isBeyondHorizon(far, eye, r), isTrue);
    });

    test('the horizon recedes as the eye climbs', () {
      final low = const Vector3(0, 0, 1) * (r + 1000);
      final high = const Vector3(0, 0, 1) * (r * 4);
      // A chunk 30 degrees off the sub-eye point: over the horizon from low
      // altitude, visible from high.
      final side =
          chunkAt(Vector3(math.sin(0.52), 0, math.cos(0.52)).normalized, 4);
      expect(isBeyondHorizon(side, low, r), isTrue);
      expect(isBeyondHorizon(side, high, r), isFalse);
    });

    test('an eye below the datum still sees the ground (DEM mare regression)', () {
      // Moon DEM: the maria sit kilometres BELOW the datum sphere, so a
      // landed camera has |eye| < radius. The old P.E >= R^2 test culled the
      // whole planet in that state — including the chunk underfoot.
      final eye = const Vector3(0, 0, 1) * (r - 2500);
      final near = chunkAt(const Vector3(0, 0, 1), 8);
      final far = chunkAt(const Vector3(0, 0, -1), 4);
      expect(isBeyondHorizon(near, eye, r, reliefM: 9000), isFalse,
          reason: 'the chunk underfoot must never cull');
      expect(isBeyondHorizon(far, eye, r, reliefM: 9000), isTrue,
          reason: 'the far side is still hidden by the body');
    });

    test('an eye at or under the lowest ground culls nothing', () {
      final buried = const Vector3(0, 0, 1) * (r - 20000);
      for (final k in ChunkKey.roots) {
        expect(isBeyondHorizon(k, buried, r, reliefM: 9000), isFalse);
      }
    });

    test('relief keeps a tall far peak visible', () {
      // A chunk whose centre has dipped just under the geometric horizon can
      // still show its peaks; reliefM must widen the kept set, never shrink.
      final eye = const Vector3(0, 0, 1) * (r + 5000);
      var culledFlat = 0, culledRelief = 0;
      for (var i = 1; i < 100; i++) {
        final ang = i * 0.01;
        final k = chunkAt(Vector3(math.sin(ang), 0, math.cos(ang)).normalized, 6);
        if (isBeyondHorizon(k, eye, r)) culledFlat++;
        if (isBeyondHorizon(k, eye, r, reliefM: 9000)) culledRelief++;
      }
      expect(culledRelief, lessThan(culledFlat));
    });

    test('margin keeps a chunk just past the edge alive', () {
      final eye = const Vector3(0, 0, 1) * (r + 50000);
      // Find a chunk that is exactly over the horizon with no margin.
      ChunkKey? edge;
      for (var i = 1; i < 200; i++) {
        final ang = i * 0.005;
        final k = chunkAt(Vector3(math.sin(ang), 0, math.cos(ang)).normalized, 5);
        if (isBeyondHorizon(k, eye, r)) {
          edge = k;
          break;
        }
      }
      expect(edge, isNotNull);
      expect(isBeyondHorizon(edge!, eye, r), isTrue);
      expect(isBeyondHorizon(edge, eye, r, marginM: 100000), isFalse);
    });
  });
}
