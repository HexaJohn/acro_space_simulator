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

  Vector3 randomDir(math.Random rng) {
    while (true) {
      final d = Vector3(rng.nextDouble() * 2 - 1, rng.nextDouble() * 2 - 1,
          rng.nextDouble() * 2 - 1);
      if (d.length > 0.1) return d.normalized;
    }
  }

  group('HorizonTest', () {
    const r = 1.7374e6;

    // The per-chunk form as it stood before the split: three inverse-trig
    // calls per chunk. The cached compare must be the same predicate.
    double referenceSlack(Vector3 centreDir, Vector3 eye, double marginM,
        double reliefM) {
      final inner = math.max(1e-6, r - reliefM);
      final eyeLen = eye.length;
      // Inside the inner ball nothing is hidden — negative slack, always.
      if (eyeLen <= inner) return double.negativeInfinity;
      final peak = r + reliefM;
      final arc = math.acos((inner / eyeLen).clamp(0.0, 1.0)) +
          math.acos((inner / peak).clamp(0.0, 1.0)) +
          math.asin((marginM / r).clamp(0.0, 1.0));
      final cosA = (centreDir.dot(eye) / eyeLen).clamp(-1.0, 1.0);
      return math.acos(cosA) - arc; // > 0 means hidden
    }

    test('the cached, trig-free compare agrees with the per-chunk form', () {
      final rng = math.Random(3);
      var checked = 0, hiddenCount = 0;
      for (var i = 0; i < 200; i++) {
        // Altitudes from below the maria to well out in orbit.
        final alt = const [-2500.0, 100.0, 5000.0, 100000.0, r * 3][i % 5] *
            (0.5 + rng.nextDouble());
        final eye = randomDir(rng) * (r + alt);
        for (final relief in const [0.0, 9000.0]) {
          final cache = ChunkGeometryCache(r);
          final horizon = HorizonTest(eye, r, reliefM: relief);
          for (var j = 0; j < 40; j++) {
            final k = chunkAt(randomDir(rng), rng.nextInt(9));
            final g = cache.of(k);
            for (final margin in [g.circumradiusM, 0.0]) {
              final slack =
                  referenceSlack(k.centreDirection, eye, margin, relief);
              if (slack.abs() < 1e-9) continue; // on the knife edge
              final want = slack > 0;
              final got = margin == 0.0
                  ? horizon.hiddenAt(k.centreDirection)
                  : horizon.hidden(g);
              expect(got, want,
                  reason: 'eye $eye relief $relief chunk $k margin $margin');
              expect(
                  isBeyondHorizon(k, eye, r,
                      marginM: margin, reliefM: relief),
                  want,
                  reason: 'the one-off form must agree too');
              checked++;
              if (want) hiddenCount++;
            }
          }
        }
      }
      expect(checked, greaterThan(10000));
      expect(hiddenCount, greaterThan(1000), reason: 'both outcomes seen');
      expect(hiddenCount, lessThan(checked - 1000));
    });

    test('an eye inside the inner ball culls nothing', () {
      final buried = const Vector3(0, 0, 1) * (r - 20000);
      final horizon = HorizonTest(buried, r, reliefM: 9000);
      expect(horizon.cullsNothing, isTrue);
      final cache = ChunkGeometryCache(r);
      for (final k in ChunkKey.roots) {
        expect(horizon.hidden(cache.of(k)), isFalse);
      }
    });
  });

  group('ChunkGeometry', () {
    const r = 1.7374e6;

    test('matches the key\'s own centre and circumradius, computed once', () {
      final rng = math.Random(5);
      final cache = ChunkGeometryCache(r);
      for (var i = 0; i < 200; i++) {
        final k = chunkAt(randomDir(rng), rng.nextInt(13));
        final g = cache.of(k);
        expect((g.centreDir - k.centreDirection).length, lessThan(1e-15));
        expect(g.circumradiusM, closeTo(k.circumradiusM(r), 1e-6));
        expect((g.centreBF - k.centreDirection * r).length, lessThan(1e-6));
        expect(g.marginArc,
            closeTo(math.asin((g.circumradiusM / r).clamp(0.0, 1.0)), 1e-12));
        expect(identical(cache.of(k), g), isTrue,
            reason: 'computed once, handed out again');
      }
    });

    test('sweep keeps the live set once the cache outgrows its bound', () {
      final cache = ChunkGeometryCache(r, sweepAbove: 64);
      final live = [
        for (var u = 0; u < 8; u++)
          for (var v = 0; v < 8; v++) ChunkKey(CubeFace.posZ, 3, u, v),
      ];
      final first = cache.of(live[0]);
      for (final k in live) {
        cache.of(k);
      }
      cache.sweep(live);
      expect(cache.length, 64, reason: 'at the bound nothing is dropped');
      for (var u = 0; u < 16; u++) {
        cache.of(ChunkKey(CubeFace.negZ, 4, u, 0));
      }
      expect(cache.length, 80);
      cache.sweep(live);
      expect(cache.length, 64, reason: 'the cells passed by are gone');
      expect(identical(cache.of(live[0]), first), isTrue,
          reason: 'live entries survive as the same objects');
    });
  });

  group('ViewCone', () {
    test('circumscribes the frustum corners; margin and viewport forms agree',
        () {
      const fov = 0.8, aspect = 1.6;
      final cone = ViewCone.circumscribing(
          forward: Vector3.unitX, fovRadiansY: fov, aspect: aspect);
      final t = math.tan(fov / 2);
      expect(cone.halfAngle,
          closeTo(math.atan(t * math.sqrt(1 + aspect * aspect)), 1e-12));
      // A frustum corner direction lies exactly on the cone.
      final corner = Vector3(1, t * aspect, t).normalized;
      expect(math.acos(corner.dot(Vector3.unitX)),
          closeTo(cone.halfAngle, 1e-12));
      const h = 900.0;
      final fromViewport = ViewCone.forViewport(
          forward: Vector3.unitX,
          focalPx: h / 2 / t,
          widthPx: h * aspect,
          heightPx: h);
      expect(fromViewport.halfAngle, closeTo(cone.halfAngle, 1e-12));
      final wider = ViewCone.circumscribing(
          forward: Vector3.unitX,
          fovRadiansY: fov,
          aspect: aspect,
          marginRad: 0.2);
      expect(wider.halfAngle, closeTo(cone.halfAngle + 0.2, 1e-12));
    });

    test('a sphere is in view when any of it is', () {
      final cone = ViewCone(Vector3.unitX, 0.5);
      expect(cone.containsSphere(Vector3(100, 0, 0), 1), isTrue,
          reason: 'on axis');
      expect(cone.containsSphere(Vector3(-100, 0, 0), 1), isFalse,
          reason: 'behind');
      // 0.7 rad off axis: a small sphere is out; one whose angular radius
      // reaches back 0.2 rad to the cone edge is in.
      final off = Vector3(math.cos(0.7), math.sin(0.7), 0) * 100;
      final reach = 100 * math.sin(0.2);
      expect(cone.containsSphere(off, 1), isFalse);
      expect(cone.containsSphere(off, reach * 1.01), isTrue);
      expect(cone.containsSphere(off, reach * 0.99), isFalse);
      expect(cone.containsSphere(Vector3(-1, 0, 0), 5), isTrue,
          reason: 'the eye inside the sphere');
      expect(
          ViewCone(Vector3.unitX, math.pi).containsSphere(Vector3(-100, 0, 0), 1),
          isTrue,
          reason: 'a full cone hides nothing');
    });

    test('agrees with the angular form over random spheres', () {
      final rng = math.Random(9);
      var inView = 0, checked = 0;
      for (var i = 0; i < 4000; i++) {
        final half = rng.nextDouble() * math.pi;
        final cone = ViewCone(randomDir(rng), half);
        final c = randomDir(rng) * (1 + rng.nextDouble() * 1000);
        final r = rng.nextDouble() * 200;
        final d = c.length;
        bool want;
        if (d <= r) {
          want = true;
        } else {
          final total = half + math.asin(r / d);
          final ang = math.acos((c.dot(cone.forward) / d).clamp(-1.0, 1.0));
          if ((total - ang).abs() < 1e-9) continue; // knife edge
          want = total >= math.pi || ang <= total;
        }
        expect(cone.containsSphere(c, r), want,
            reason: 'half $half centre $c r $r');
        checked++;
        if (want) inView++;
      }
      expect(checked, greaterThan(3900));
      expect(inView, greaterThan(500));
      expect(inView, lessThan(checked - 500));
    });

    test('attenuating out-of-view chunks coarsens behind the eye, tiling intact',
        () {
      // Eye 3 km up looking along the horizon. Ground ahead is inside the
      // cone, ground behind is not; the tree must still tile the body and
      // stay balanced, and select coarser behind than ahead at like range.
      const r = 1.7374e6;
      final eye = Vector3(0, 0, r + 3000);
      final fwd = Vector3.unitX;
      final cone = ViewCone.circumscribing(
          forward: fwd, fovRadiansY: 0.8, aspect: 1.6, marginRad: 0.26);
      const focal = 800.0;
      final horizon = HorizonTest(eye, r);
      final geom = ChunkGeometryCache(r);
      double pxFor(ChunkKey k, {required bool cull}) {
        final g = geom.of(k);
        if (horizon.hidden(g)) return 0;
        final rel = g.centreBF - eye;
        final v = g.circumradiusM * focal / math.max(1.0, rel.length);
        if (!cull || cone.containsSphere(rel, g.circumradiusM)) return v;
        return v * 0.25;
      }

      Set<ChunkKey> settle(bool cull) {
        final tree = TerrainLodTree(splitPx: 220, maxLevel: 12);
        var leaves = <ChunkKey>{};
        for (var i = 0; i < 16; i++) {
          final next = tree.update((k) => pxFor(k, cull: cull));
          final same = next.length == leaves.length && next.containsAll(leaves);
          leaves = next;
          if (same) break;
        }
        return leaves;
      }

      final culled = settle(true);
      final plain = settle(false);
      _expectTiling(culled);
      expect(isBalanced(culled), isTrue);
      expect(culled.length, lessThan(plain.length),
          reason: 'fewer leaves with the ground behind the eye coarsened');

      // Deepest leaf within 3-12 km of the sub-point, ahead vs behind.
      int deepest(Set<ChunkKey> leaves, double sign) {
        var m = 0;
        final sub = Vector3(0, 0, r);
        for (final k in leaves) {
          final off = geom.of(k).centreBF - sub;
          final along = off.dot(fwd) * sign;
          final dist = off.length;
          if (dist < 3000 || dist > 12000) continue;
          if (along / dist < 0.8) continue;
          if (k.level > m) m = k.level;
        }
        return m;
      }

      expect(deepest(plain, 1), deepest(plain, -1),
          reason: 'without the cone the selection is symmetric');
      expect(deepest(culled, 1), greaterThanOrEqualTo(deepest(culled, -1) + 1),
          reason: 'behind the eye must be coarser than ahead');
      expect(deepest(culled, 1), deepest(plain, 1),
          reason: 'ahead is untouched by the cone');
    });
  });

  group('reselectDistanceM', () {
    test('scales with height over the ground, floored on the ground', () {
      double d(double h) =>
          reselectDistanceM(heightM: h, fraction: 0.1, floorM: 100);
      expect(d(400000), 40000, reason: 'orbit: tens of km between reselects');
      expect(d(5000), 500);
      expect(d(1000), 100, reason: 'low flight: a tenth, which is the floor');
      expect(d(2), 100, reason: 'a car: the floor');
      expect(d(-900), 100, reason: 'below ground counts as on it');
    });
  });
}
