import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/components/component.dart';
import 'package:flutter_scene/src/mesh.dart';
import 'package:flutter_scene/src/node.dart';
import 'package:flutter_scene/src/render/render_scene.dart';

/// An engine [Component] that draws a [Mesh].
///
/// While the owning node is part of a live scene, a `MeshComponent`
/// registers one [RenderItem] per [MeshPrimitive] with the scene's flat
/// render layer, and refreshes those items each frame.
///
/// A node's [Node.mesh] getter and setter are a convenience over the
/// node's first `MeshComponent`.
/// {@category Scene graph}
class MeshComponent extends Component {
  /// Creates a component that draws [mesh].
  MeshComponent(this._mesh);

  Mesh _mesh;

  /// The mesh this component draws.
  ///
  /// Assigning a different mesh re-registers the render items when the
  /// owning node is part of a live scene.
  Mesh get mesh => _mesh;
  set mesh(Mesh value) {
    if (identical(_mesh, value)) return;
    _unregisterRenderItems();
    _mesh = value;
    _registerRenderItems();
    if (isAttached) node.markBoundsDirty();
  }

  // One render item per mesh primitive. Empty while the component is not
  // mounted.
  final List<RenderItem> _renderItems = [];

  /// The render items registered for this component's mesh primitives, empty
  /// while not mounted. Exposed so a subclass (the LOD component) can tag the
  /// items it just registered.
  @protected
  List<RenderItem> get renderItems => _renderItems;

  @override
  void onMount() => _registerRenderItems();

  @override
  void onUnmount() => _unregisterRenderItems();

  void _registerRenderItems() {
    if (!isMounted) return;
    final renderScene = node.internalRenderScene;
    if (renderScene == null) return;
    for (final primitive in _mesh.primitives) {
      final item = RenderItem(
        geometry: primitive.geometry,
        material: primitive.material,
      )..sourceNode = node;
      _renderItems.add(item);
      renderScene.add(item);
    }
  }

  void _unregisterRenderItems() {
    // Guard on attachment, not mount state: [Component.unmount] clears
    // the mounted flag before invoking [onUnmount], so checking
    // isMounted here would skip removal during teardown and leave the
    // render items in the scene forever. The owning node's render scene
    // is still reachable until after every component has unmounted.
    if (isAttached) {
      final renderScene = node.internalRenderScene;
      if (renderScene != null) {
        for (final item in _renderItems) {
          renderScene.remove(item);
        }
      }
    }
    _renderItems.clear();
  }

  /// Refreshes this component's render items from the owning node's
  /// current world transform, skin, and cull state. Called once per frame
  /// by the scene pre-pass while the node is visible.
  ///
  /// The cheap per-frame flags (visibility, layers, winding, highlight,
  /// shadow casting) are always refreshed. The world matrix copy and the
  /// AABB transform behind [RenderItem.worldBounds] run only when the
  /// node's [Node.transformVersion] or the geometry's bounds moved since
  /// the item last saw them; for a scene of static nodes that is the
  /// difference between touching a thousand matrices a frame and none.
  @internal
  void refreshRenderItems() {
    if (_renderItems.isEmpty) return;
    // Reading globalTransform refreshes the node's cache, and with it the
    // version the items are compared against.
    final worldTransform = node.globalTransform;
    final transformVersion = node.transformVersion;
    final windingFlipped = node.windingFlipped;

    // A skinned node uploads its joint matrices once per frame; both
    // render passes then sample the same joints texture.
    final skin = node.skin;
    if (skin != null) {
      final jointsTexture = skin.getJointsTexture();
      final jointsTextureWidth = skin.getTextureWidth();
      for (final item in _renderItems) {
        item.geometry.setJointsTexture(jointsTexture, jointsTextureWidth);
      }
    }

    final renderScene = node.internalRenderScene;
    final frustumCulled = node.frustumCulled;
    final layers = node.layers;
    final highlightColor = node.highlightColor;
    final castsShadow = node.castsShadow;
    for (final item in _renderItems) {
      item.visible = true;
      final frustumCulledChanged = item.frustumCulled != frustumCulled;
      item.frustumCulled = frustumCulled;
      item.layers = layers;
      item.windingFlipped = windingFlipped;
      item.highlightColor = highlightColor;
      item.castsShadow = castsShadow;

      // The item's world bounds derive from the node transform and the
      // geometry's local bounds; both are versioned, so an item that has
      // seen the current versions is already up to date.
      final geometry = item.geometry;
      final localBounds = geometry.localBounds;
      final localBoundsVersion = geometry.localBoundsVersion;
      final stale =
          item.transformVersion != transformVersion ||
          item.seenLocalBoundsVersion != localBoundsVersion ||
          !identical(item.seenLocalBounds, localBounds);
      bool membershipChanged = frustumCulledChanged;
      bool boundsChanged = false;
      if (stale) {
        item.worldTransform.setFrom(worldTransform);
        item.transformVersion = transformVersion;
        item.seenLocalBounds = localBounds;
        item.seenLocalBoundsVersion = localBoundsVersion;
        final wasBounded = item.worldBounds != null;
        boundsChanged = item.refreshWorldBounds();
        final isBounded = item.worldBounds != null;
        membershipChanged = membershipChanged || wasBounded != isBounded;
      }

      // A toggled cull flag or a bounded/unbounded transition changes the
      // BVH membership; a plain move only needs a refit.
      if (membershipChanged) {
        renderScene?.markBvhMembershipChanged(item);
      } else if (boundsChanged && item.frustumCulled) {
        renderScene?.markBvhBoundsDirty();
      }
    }
  }

  /// Keeps this component's render items out of the render passes.
  /// Called by the scene pre-pass while the owning node is hidden.
  @internal
  void hideRenderItems() {
    for (final item in _renderItems) {
      item.visible = false;
    }
  }
}
