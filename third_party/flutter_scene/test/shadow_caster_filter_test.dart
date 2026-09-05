// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Pure-Dart coverage for the encoder-layer instancing patches: the shadow
// encoder's caster filter (castsShadow, the view layer mask, opacity) and
// the "count a pack only when it was actually rebuilt" rule both encoders
// apply on top of the item's pack cache, including the traffic path where
// an InstancedMesh mutation bumps the version and forces a repack. Nothing
// here touches the GPU: the encoders themselves need a render pass, so the
// filter is pinned through the static predicate they call first.

import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/instanced_mesh.dart';
import 'package:flutter_scene/src/material/physically_based_material.dart'
    show AlphaMode;
import 'package:flutter_scene/src/material/unlit_material.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/render_layers.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/shadow_encoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

final _geometry = UnskinnedGeometry();

RenderItem _item({UnlitMaterial? material}) =>
    RenderItem(geometry: _geometry, material: material ?? UnlitMaterial())
      ..visible = true;

void main() {
  group('ShadowEncoder.isCaster', () {
    test('an ordinary visible opaque item casts on every layer', () {
      final item = _item();
      expect(ShadowEncoder.isCaster(item, kRenderLayerAll), isTrue);
      expect(ShadowEncoder.isCaster(item, 0x1), isTrue);
    });

    test('hidden and opted-out items do not cast', () {
      expect(
        ShadowEncoder.isCaster(_item()..visible = false, kRenderLayerAll),
        isFalse,
      );
      expect(
        ShadowEncoder.isCaster(_item()..castsShadow = false, kRenderLayerAll),
        isFalse,
      );
    });

    test('the layer mask gates casters like the colour pass', () {
      final item = _item()..layers = 0x4;
      expect(ShadowEncoder.isCaster(item, 0x4), isTrue);
      expect(ShadowEncoder.isCaster(item, 0x4 | 0x1), isTrue);
      expect(ShadowEncoder.isCaster(item, 0x1), isFalse);
      expect(ShadowEncoder.isCaster(item, 0), isFalse);
    });

    test('translucent materials do not cast', () {
      final blended = UnlitMaterial()..alphaMode = AlphaMode.blend;
      expect(
        ShadowEncoder.isCaster(_item(material: blended), kRenderLayerAll),
        isFalse,
      );
    });
  });

  group('encoder pack accounting', () {
    // Mirrors what the pre-pass does for an InstancedMeshComponent: stamp
    // the mesh version and the node transform onto the item.
    void stamp(RenderItem item, InstancedMesh mesh, Matrix4 world) {
      item
        ..instanceTransforms = mesh.instances
        ..instanceVersion = mesh.version;
      item.worldTransform.setFrom(world);
    }

    test('a static mesh packs once and is reused by later passes', () {
      final mesh = InstancedMesh(geometry: _geometry, material: UnlitMaterial())
        ..addInstance(Matrix4.translationValues(1, 0, 0))
        ..addInstance(Matrix4.translationValues(2, 0, 0));
      final item = _item();
      final world = Matrix4.translationValues(0, 10, 0);
      stamp(item, mesh, world);

      // First pass of the first frame: a real pack.
      var previous = item.packedCache;
      final colour = packedInstancesFor(item, mesh.instances);
      expect(identical(colour, previous), isFalse);
      expect(colour.ccwCount, 2);

      // Shadow cascades and the next frame's colour pass reuse it: the
      // identity test the encoders use to decide whether to count a pack
      // reports a hit.
      previous = item.packedCache;
      expect(identical(packedInstancesFor(item, mesh.instances), previous), isTrue);
      stamp(item, mesh, world);
      previous = item.packedCache;
      expect(identical(packedInstancesFor(item, mesh.instances), previous), isTrue);
    });

    test('the traffic path (setInstanceTransform) repacks with new values', () {
      final mesh = InstancedMesh(geometry: _geometry, material: UnlitMaterial())
        ..addInstance(Matrix4.translationValues(1, 0, 0));
      final item = _item();
      stamp(item, mesh, Matrix4.identity());
      final before = packedInstancesFor(item, mesh.instances);
      expect(before.ccw[12], 1.0);

      // A car advances: the mesh version moves, the pre-pass restamps, and
      // the next pack must be fresh and carry the new position.
      mesh.setInstanceTransform(0, Matrix4.translationValues(7, 0, 0));
      stamp(item, mesh, Matrix4.identity());
      final previous = item.packedCache;
      final after = packedInstancesFor(item, mesh.instances);
      expect(identical(after, previous), isFalse);
      expect(after.ccw[12], 7.0);
      expect(identical(packedInstancesFor(item, mesh.instances), after), isTrue);
    });

    test('a moved node or flipped parity repacks even with no mesh change', () {
      final mesh = InstancedMesh(geometry: _geometry, material: UnlitMaterial())
        ..addInstance(Matrix4.identity());
      final item = _item();
      stamp(item, mesh, Matrix4.identity());
      final first = packedInstancesFor(item, mesh.instances);

      stamp(item, mesh, Matrix4.translationValues(0, 0, 3));
      final moved = packedInstancesFor(item, mesh.instances);
      expect(identical(moved, first), isFalse);
      expect(moved.ccw[14], 3.0);

      item.windingFlipped = true;
      final flipped = packedInstancesFor(item, mesh.instances);
      expect(identical(flipped, moved), isFalse);
      expect(flipped.cwCount, 1, reason: 'node parity moves the instance to cw');
      expect(flipped.ccwCount, 0);
    });
  });
}
