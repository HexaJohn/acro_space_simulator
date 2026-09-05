// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Pure-Dart coverage for the scene-layer culling patches: the O(n log n)
// BVH build and its query against brute force, the deferred rebuild
// policy of RenderScene, the allocation-free instanced aggregate bounds,
// the instance pack cache, and the node transform version. Nothing here
// touches the GPU; geometry and material objects are constructed but
// never uploaded.

import 'dart:math';

import 'package:flutter_scene/src/components/mesh_component.dart';
import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/instanced_mesh.dart';
import 'package:flutter_scene/src/material/unlit_material.dart';
import 'package:flutter_scene/src/mesh.dart';
import 'package:flutter_scene/src/node.dart';
import 'package:flutter_scene/src/render/bvh.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

final _geometry = UnskinnedGeometry();
final _material = UnlitMaterial();

RenderItem _boundedItem(Aabb3 bounds) {
  return RenderItem(geometry: _geometry, material: _material)
    ..worldBounds = Aabb3.copy(bounds)
    ..visible = true;
}

Aabb3 _randomBox(Random rng, {double extent = 200, double maxSize = 12}) {
  final min = Vector3(
    (rng.nextDouble() * 2 - 1) * extent,
    (rng.nextDouble() * 2 - 1) * extent,
    (rng.nextDouble() * 2 - 1) * extent,
  );
  final size = Vector3(
    rng.nextDouble() * maxSize,
    rng.nextDouble() * maxSize,
    rng.nextDouble() * maxSize,
  );
  return Aabb3.minMax(min, min + size);
}

/// A perspective frustum from a random camera pose inside the item cloud,
/// the shape a render pass really queries with.
Frustum _randomFrustum(Random rng) {
  final eye = Vector3(
    (rng.nextDouble() * 2 - 1) * 150,
    (rng.nextDouble() * 2 - 1) * 150,
    (rng.nextDouble() * 2 - 1) * 150,
  );
  final target =
      eye +
      Vector3(
        rng.nextDouble() * 2 - 1,
        rng.nextDouble() * 2 - 1,
        rng.nextDouble() * 2 - 1,
      );
  final projection = makePerspectiveMatrix(
    0.4 + rng.nextDouble() * 1.2,
    1.0 + rng.nextDouble(),
    0.5,
    120 + rng.nextDouble() * 200,
  );
  final view = makeViewMatrix(eye, target, Vector3(0, 1, 0));
  return Frustum.matrix(projection * view);
}

/// An axis-aligned box query, the shape a shadow cascade or an
/// orthographic view queries with.
Frustum _boxFrustum(Random rng) {
  final box = _randomBox(rng, extent: 150, maxSize: 120);
  final projection = makeOrthographicMatrix(
    box.min.x,
    box.max.x,
    box.min.y,
    box.max.y,
    -box.max.z,
    -box.min.z,
  );
  return Frustum.matrix(projection);
}

Set<RenderItem> _bruteForce(Frustum frustum, List<RenderItem> items) {
  return {
    for (final item in items)
      if (frustum.intersectsWithAabb3(item.worldBounds!)) item,
  };
}

Set<RenderItem> _visited(Bvh bvh, Frustum frustum) {
  final seen = <RenderItem>{};
  var visits = 0;
  bvh.query(frustum, (item) {
    visits++;
    seen.add(item);
  });
  expect(visits, seen.length, reason: 'each item visited at most once');
  return seen;
}

void main() {
  group('Bvh.build', () {
    test('query matches brute force for random perspective frustums', () {
      final rng = Random(7);
      final items = [for (var i = 0; i < 1500; i++) _boundedItem(_randomBox(rng))];
      final bvh = Bvh.build(items);
      for (var q = 0; q < 60; q++) {
        final frustum = _randomFrustum(rng);
        expect(_visited(bvh, frustum), _bruteForce(frustum, items));
      }
    });

    test('query matches brute force for box-shaped queries', () {
      final rng = Random(11);
      final items = [for (var i = 0; i < 800; i++) _boundedItem(_randomBox(rng))];
      final bvh = Bvh.build(items);
      for (var q = 0; q < 60; q++) {
        final frustum = _boxFrustum(rng);
        expect(_visited(bvh, frustum), _bruteForce(frustum, items));
      }
    });

    test('handles tiny and empty inputs', () {
      final rng = Random(3);
      final empty = Bvh.build([]);
      expect(_visited(empty, _randomFrustum(rng)), isEmpty);
      for (var n = 1; n <= 5; n++) {
        final items = [for (var i = 0; i < n; i++) _boundedItem(_randomBox(rng))];
        final bvh = Bvh.build(items);
        for (var q = 0; q < 10; q++) {
          final frustum = _boxFrustum(rng);
          expect(_visited(bvh, frustum), _bruteForce(frustum, items));
        }
      }
    });

    test('co-located items (equal centroids) build and query correctly', () {
      // Every centroid identical: the median selection must neither loop
      // nor go quadratic on a run of equal keys.
      final box = Aabb3.minMax(Vector3(-1, -1, -1), Vector3(1, 1, 1));
      final items = [for (var i = 0; i < 4000; i++) _boundedItem(box)];
      final stopwatch = Stopwatch()..start();
      final bvh = Bvh.build(items);
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      final inside = Frustum.matrix(makeOrthographicMatrix(-2, 2, -2, 2, -2, 2));
      expect(_visited(bvh, inside).length, items.length);
      final outside = Frustum.matrix(makeOrthographicMatrix(5, 9, 5, 9, -9, -5));
      expect(_visited(bvh, outside), isEmpty);
    });

    test('refit follows moved items and a reused build is exact', () {
      final rng = Random(19);
      final items = [for (var i = 0; i < 600; i++) _boundedItem(_randomBox(rng))];
      var bvh = Bvh.build(items);
      // Move a third of the items and refit: still exact.
      for (var i = 0; i < items.length; i += 3) {
        items[i].worldBounds!.copyFrom(_randomBox(rng));
      }
      bvh.refit();
      for (var q = 0; q < 30; q++) {
        final frustum = _randomFrustum(rng);
        expect(_visited(bvh, frustum), _bruteForce(frustum, items));
      }
      // Rebuild over a different item set, recycling the old nodes.
      final others = [
        ...items.sublist(0, 200),
        for (var i = 0; i < 700; i++) _boundedItem(_randomBox(rng)),
      ];
      bvh = Bvh.build(others, reuse: bvh);
      for (var q = 0; q < 30; q++) {
        final frustum = _randomFrustum(rng);
        expect(_visited(bvh, frustum), _bruteForce(frustum, others));
      }
    });

    test('skips leaves flagged dead', () {
      final rng = Random(23);
      final items = [for (var i = 0; i < 300; i++) _boundedItem(_randomBox(rng))];
      final bvh = Bvh.build(items);
      final everything = Frustum.matrix(
        makeOrthographicMatrix(-300, 300, -300, 300, -300, 300),
      );
      expect(_visited(bvh, everything).length, items.length);
      items[5].bvhDead = true;
      items[77].bvhDead = true;
      final seen = _visited(bvh, everything);
      expect(seen.length, items.length - 2);
      expect(seen, isNot(contains(items[5])));
      expect(seen, isNot(contains(items[77])));
    });
  });

  group('RenderScene deferred rebuild', () {
    // Sees the whole item cloud, so a cull is a full census.
    final everything = Frustum.matrix(
      makeOrthographicMatrix(-300, 300, -300, 300, -300, 300),
    );
    // A query that intersects nothing the random boxes produce.
    final nothing = Frustum.matrix(
      makeOrthographicMatrix(900, 950, 900, 950, -950, -900),
    );

    Set<RenderItem> cull(RenderScene scene, Frustum frustum) {
      final seen = <RenderItem>{};
      var visits = 0;
      scene.cull(frustum, (item) {
        visits++;
        seen.add(item);
      });
      expect(visits, seen.length, reason: 'each item visited at most once');
      return seen;
    }

    test('first frame builds; a small add defers and still visits', () {
      final rng = Random(31);
      final scene = RenderScene();
      final items = [for (var i = 0; i < 500; i++) _boundedItem(_randomBox(rng))];
      items.forEach(scene.add);
      scene.rebuildIfDirty();
      expect(scene.lastRebuildWasFull, isTrue);
      expect(scene.pendingItems, 0);
      expect(cull(scene, everything), items.toSet());
      expect(cull(scene, nothing), isEmpty);

      // A tile's worth of new items: below the threshold, so deferred.
      final added = [for (var i = 0; i < 20; i++) _boundedItem(_randomBox(rng))];
      added.forEach(scene.add);
      scene.rebuildIfDirty();
      expect(scene.lastRebuildWasFull, isFalse);
      expect(scene.pendingItems, added.length);
      // Pending items are visited even by a query they do not intersect,
      // and everything a full build would visit is still visited.
      expect(cull(scene, nothing), added.toSet());
      final all = [...items, ...added];
      for (var q = 0; q < 20; q++) {
        final frustum = _randomFrustum(rng);
        final seen = cull(scene, frustum);
        final expected = _bruteForce(frustum, all);
        expect(seen.containsAll(expected), isTrue);
        // The only extras are pending items outside the frustum.
        expect(seen.difference(expected).every(added.contains), isTrue);
      }
    });

    test('removed leaves are skipped before the rebuild', () {
      final rng = Random(37);
      final scene = RenderScene();
      final items = [for (var i = 0; i < 400; i++) _boundedItem(_randomBox(rng))];
      items.forEach(scene.add);
      scene.rebuildIfDirty();
      scene.remove(items[3]);
      scene.remove(items[250]);
      scene.rebuildIfDirty();
      expect(scene.lastRebuildWasFull, isFalse);
      expect(scene.deadItems, 2);
      final seen = cull(scene, everything);
      expect(seen.length, items.length - 2);
      expect(seen, isNot(contains(items[3])));
      expect(seen, isNot(contains(items[250])));

      // Re-adding a dead item visits it through the pending list, once.
      scene.add(items[3]);
      scene.rebuildIfDirty();
      expect(cull(scene, everything), contains(items[3]));
      expect(cull(scene, nothing), {items[3]});
    });

    test('rebuilds past the threshold and after the frame cap', () {
      final rng = Random(41);
      final scene = RenderScene();
      final items = [for (var i = 0; i < 100; i++) _boundedItem(_randomBox(rng))];
      items.forEach(scene.add);
      scene.rebuildIfDirty();

      // 33 pending > max(32, 10% of 133): full rebuild.
      final burst = [for (var i = 0; i < 33; i++) _boundedItem(_randomBox(rng))];
      burst.forEach(scene.add);
      scene.rebuildIfDirty();
      expect(scene.lastRebuildWasFull, isTrue);
      expect(scene.pendingItems, 0);
      expect(cull(scene, nothing), isEmpty);
      expect(cull(scene, everything).length, items.length + burst.length);

      // One pending item: deferred for 119 frames, rebuilt on the 120th.
      scene.add(_boundedItem(_randomBox(rng)));
      for (var frame = 1; frame < 120; frame++) {
        scene.rebuildIfDirty();
        expect(scene.lastRebuildWasFull, isFalse, reason: 'frame $frame');
        expect(scene.pendingItems, 1);
      }
      scene.rebuildIfDirty();
      expect(scene.lastRebuildWasFull, isTrue);
      expect(scene.pendingItems, 0);
      expect(cull(scene, everything).length, items.length + burst.length + 1);

      // A quiet frame does nothing.
      scene.rebuildIfDirty();
      expect(scene.lastRebuildWasFull, isFalse);
    });

    test('membership changes keep an item visible either way', () {
      final rng = Random(43);
      final scene = RenderScene();
      final items = [for (var i = 0; i < 200; i++) _boundedItem(_randomBox(rng))];
      items.forEach(scene.add);
      scene.rebuildIfDirty();

      // A leaf opts out of culling: retired from the tree, always visited.
      final optOut = items[10]..frustumCulled = false;
      scene.markBvhMembershipChanged(optOut);
      scene.rebuildIfDirty();
      expect(cull(scene, nothing), {optOut});
      expect(cull(scene, everything).length, items.length);

      // Explicit structure-dirty forces the rebuild now; the opted-out item
      // becomes always-visible rather than pending.
      scene.markBvhStructureDirty();
      scene.rebuildIfDirty();
      expect(scene.lastRebuildWasFull, isTrue);
      expect(scene.pendingItems, 0);
      expect(cull(scene, nothing), {optOut});

      // Opting back in moves it to pending until the next rebuild.
      optOut.frustumCulled = true;
      scene.markBvhMembershipChanged(optOut);
      expect(scene.pendingItems, 1);
      scene.rebuildIfDirty();
      expect(cull(scene, nothing), {optOut});
      scene.remove(optOut);
      expect(cull(scene, everything).length, items.length - 1);
    });
  });

  group('InstancedMesh', () {
    test('version bumps on every mutation', () {
      final mesh = InstancedMesh(geometry: _geometry, material: _material);
      expect(mesh.version, 0);
      mesh.addInstance(Matrix4.identity());
      expect(mesh.version, 1);
      mesh.setInstanceTransform(0, Matrix4.translationValues(1, 2, 3));
      expect(mesh.version, 2);
      mesh.removeInstanceAt(0);
      expect(mesh.version, 3);
      mesh.clearInstances();
      expect(mesh.version, 4);
    });

    test('aggregateBounds matches the per-instance transformed hull', () {
      final rng = Random(53);
      final geometry = UnskinnedGeometry()
        ..setLocalBounds(
          Aabb3.minMax(Vector3(-1, -2, -0.5), Vector3(1.5, 2, 0.5)),
          null,
        );
      final mesh = InstancedMesh(geometry: geometry, material: _material);
      expect(mesh.aggregateBounds, isNull);
      final transforms = <Matrix4>[];
      for (var i = 0; i < 300; i++) {
        final t = Matrix4.compose(
          Vector3(
            (rng.nextDouble() * 2 - 1) * 50,
            (rng.nextDouble() * 2 - 1) * 50,
            (rng.nextDouble() * 2 - 1) * 50,
          ),
          Quaternion.random(rng),
          Vector3(
            0.2 + rng.nextDouble() * 3,
            // A mirrored instance now and then.
            (rng.nextBool() ? 1 : -1) * (0.2 + rng.nextDouble() * 3),
            0.2 + rng.nextDouble() * 3,
          ),
        );
        transforms.add(t);
        mesh.addInstance(t);
      }
      Aabb3? expected;
      for (final t in transforms) {
        final box = Aabb3.copy(geometry.localBounds!)..transform(t);
        expected = expected == null ? box : (expected..hull(box));
      }
      // Aabb3 stores float32; the reference path rounds through a center
      // and half-extent while the inline hull sums doubles, so agreement
      // is to float32 precision at this magnitude, not exact.
      final actual = mesh.aggregateBounds!;
      expect(actual.min.absoluteError(expected!.min), lessThan(1e-3));
      expect(actual.max.absoluteError(expected.max), lessThan(1e-3));

      // Cached until the next mutation.
      expect(identical(mesh.aggregateBounds, actual), isTrue);
      mesh.setInstanceTransform(0, Matrix4.translationValues(500, 0, 0));
      expect(mesh.aggregateBounds!.max.x, greaterThan(400));
    });
  });

  group('packedInstancesFor', () {
    test('caches by instance version, world transform and parity', () {
      final instances = [
        Matrix4.translationValues(1, 0, 0),
        Matrix4.diagonal3Values(-1, 1, 1),
      ];
      final item = RenderItem(geometry: _geometry, material: _material)
        ..instanceTransforms = instances
        ..instanceVersion = 3;
      item.worldTransform.setTranslationRaw(0, 5, 0);
      final first = packedInstancesFor(item, instances);
      expect(first.ccwCount, 1);
      expect(first.cwCount, 1);
      expect(first.ccw[13], 5.0, reason: 'node translation folded in');
      expect(identical(packedInstancesFor(item, instances), first), isTrue);

      item.instanceVersion = 4;
      final second = packedInstancesFor(item, instances);
      expect(identical(second, first), isFalse);
      expect(identical(packedInstancesFor(item, instances), second), isTrue);

      item.worldTransform.setTranslationRaw(0, 6, 0);
      final third = packedInstancesFor(item, instances);
      expect(identical(third, second), isFalse);
      expect(third.ccw[13], 6.0);

      item.windingFlipped = true;
      final fourth = packedInstancesFor(item, instances);
      expect(identical(fourth, third), isFalse);
      expect(fourth.cwCount, 1);
      expect(fourth.ccwCount, 1);
    });
  });

  group('Node transform version', () {
    test('moves only when the world matrix changes, down the chain', () {
      final parent = Node();
      final child = Node();
      parent.add(child);
      parent.globalTransform;
      child.globalTransform;
      final parentVersion = parent.transformVersion;
      final childVersion = child.transformVersion;

      // Re-assigning the same pose marks the cache stale but is no move.
      parent.localTransform = Matrix4.identity();
      parent.globalTransform;
      child.globalTransform;
      expect(parent.transformVersion, parentVersion);
      expect(child.transformVersion, childVersion);

      parent.localTransform = Matrix4.translationValues(1, 0, 0);
      parent.globalTransform;
      child.globalTransform;
      expect(parent.transformVersion, parentVersion + 1);
      expect(child.transformVersion, childVersion + 1);

      // Moving only the child leaves the parent's version alone.
      child.localTransform = Matrix4.translationValues(0, 1, 0);
      parent.globalTransform;
      child.globalTransform;
      expect(parent.transformVersion, parentVersion + 1);
      expect(child.transformVersion, childVersion + 2);
    });

    test('pre-pass refreshes items on a move and mirrors castsShadow', () {
      final geometry = UnskinnedGeometry()
        ..setLocalBounds(
          Aabb3.minMax(Vector3(-1, -1, -1), Vector3(1, 1, 1)),
          null,
        );
      final scene = RenderScene();
      final root = Node()..debugMountInto(scene);
      final node = Node(mesh: Mesh(geometry, _material));
      root.add(node);
      final item = scene.items.single;

      root.scenePrePass(0);
      expect(item.transformVersion, node.transformVersion);
      expect(item.worldBounds!.min, Vector3(-1, -1, -1));
      expect(item.castsShadow, isTrue);

      // Unchanged frame: the item still carries the same version and
      // bounds (the copy was skipped, which is invisible here, but the
      // values must be right either way).
      root.scenePrePass(0);
      expect(item.worldBounds!.max, Vector3(1, 1, 1));

      node.localTransform = Matrix4.translationValues(10, 0, 0);
      node.castsShadow = false;
      root.scenePrePass(0);
      expect(item.worldBounds!.min, Vector3(9, -1, -1));
      expect(item.worldTransform.getTranslation(), Vector3(10, 0, 0));
      expect(item.castsShadow, isFalse);

      // The mesh component listens to the geometry's bounds version too.
      geometry.setLocalBounds(
        Aabb3.minMax(Vector3(-2, -2, -2), Vector3(2, 2, 2)),
        null,
      );
      root.scenePrePass(0);
      expect(item.worldBounds!.min, Vector3(8, -2, -2));
      expect(node.getComponent<MeshComponent>(), isNotNull);
    });
  });
}
