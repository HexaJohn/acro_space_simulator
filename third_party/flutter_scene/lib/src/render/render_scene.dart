import 'package:vector_math/vector_math.dart';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_scene/src/camera.dart';
import 'package:flutter_scene/src/components/camera_component.dart';
import 'package:flutter_scene/src/components/directional_light_component.dart';
import 'package:flutter_scene/src/components/environment_volume_component.dart';
import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/render/bvh.dart';
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/lod.dart';
import 'package:flutter_scene/src/render/render_layers.dart';

/// One drawable primitive in the flat render layer.
///
/// A [RenderItem] is created when a mesh-bearing node is mounted into a
/// scene and lives until that node is unmounted or its mesh changes. The
/// scene pre-pass refreshes [visible], [frustumCulled], and
/// [worldTransform] each frame; the render passes iterate the flat
/// [RenderScene] and never walk the node tree.
class RenderItem {
  RenderItem({required this.geometry, required this.material});

  /// Vertex and index data for this primitive.
  final Geometry geometry;

  /// Shader and per-material parameters.
  final Material material;

  /// Level-of-detail state, set by an [LodComponent] when the item is
  /// registered. When non-null the encoder picks one of its levels per view
  /// (or culls) from the item's projected screen size, instead of drawing
  /// [geometry] and [material]. Those serve as the highest-detail fallback
  /// and the source of [cullBounds].
  LodSelection? lod;

  /// The `Node` that owns this item, set once when the item is registered.
  ///
  /// Typed as `Object?` to keep the render layer free of a node import (the
  /// same reason [RenderScene.widgetComponents] is loosely typed). Consumers
  /// that need the node (the object-filtered draw's node predicate and
  /// per-node color) cast it back to `Node`.
  Object? sourceNode;

  /// Whether the owning node and all of its ancestors are visible.
  /// Refreshed each frame by the scene pre-pass.
  bool visible = false;

  /// Mirrors the owning node's frustum-cull opt-in, refreshed each frame.
  bool frustumCulled = true;

  /// The owning node's render layers (a 32-bit bitmask), refreshed each
  /// frame. A render pass skips this item when its view's layer mask does
  /// not intersect (`layers & layerMask == 0`).
  int layers = kRenderLayerAll;

  /// Whether the owning node's transform reverses triangle winding (a mirror
  /// up the chain). Refreshed each frame; the encoder flips cull winding when
  /// set so mirrored nodes don't render inside-out.
  bool windingFlipped = false;

  /// Mirrors the owning node's `castsShadow`, refreshed each frame. The
  /// shadow encoder skips an item with this cleared when it draws the
  /// light's depth pass.
  bool castsShadow = true;

  /// World-space transform, refreshed from the owning node whenever the
  /// node's transform version moves (see [transformVersion]).
  final Matrix4 worldTransform = Matrix4.identity();

  /// The owning node's transform version that [worldTransform] and
  /// [worldBounds] were last refreshed from, or `-1` before the first
  /// refresh. The pre-pass skips the matrix copy and the AABB transform
  /// while the node still reports the same version, which is the common
  /// case: a thousand static nodes under a moving camera.
  int transformVersion = -1;

  /// The `InstancedMesh` version the instance list and [instanceBounds]
  /// were last refreshed from, or `-1` before the first refresh. Unused for
  /// a non-instanced item.
  int instanceVersion = -1;

  /// The [Geometry.localBounds] object and [Geometry.localBoundsVersion]
  /// that [worldBounds] was last derived from. A caller-managed geometry
  /// can replace or re-set its bounds after the item is registered, and
  /// the pre-pass must still notice that when the transform is unchanged.
  Aabb3? seenLocalBounds;
  int seenLocalBoundsVersion = -1;

  /// Cached per-parity instance transform pack (see [packedInstancesFor]),
  /// valid while [packedVersion] matches the `InstancedMesh` version and
  /// [packedWorld] matches [worldTransform]. `null` until first packed.
  PackedInstanceTransforms? packedCache;

  /// The `InstancedMesh` version [packedCache] was built from.
  int packedVersion = -1;

  /// The node world transform [packedCache] was built from.
  final Matrix4 packedWorld = Matrix4.zero();

  /// The node winding parity [packedCache] was split by. It normally
  /// follows [packedWorld], but a node can be excluded from winding parity
  /// without its matrix changing.
  bool packedWindingFlipped = false;

  /// Whether this item is a leaf of the [RenderScene]'s current BVH.
  /// Owned by [RenderScene]; set on a full rebuild.
  bool bvhLeaf = false;

  /// Whether this item is a BVH leaf that was removed from the scene, or
  /// changed its BVH membership, after the tree was built. The query skips
  /// such leaves until the next full rebuild drops them. Owned by
  /// [RenderScene].
  bool bvhDead = false;

  /// The owning node's highlight color (linear RGBA), or null when the node
  /// is not highlighted. Refreshed each frame; the selection-outline pass
  /// draws only highlighted items, using this as the mask color.
  Vector4? highlightColor;

  /// Per-instance model transforms, or `null` for a non-instanced item.
  ///
  /// When set, this item draws [geometry] / [material] once per entry,
  /// each at `worldTransform * transform`. Refreshed each frame from the
  /// owning [InstancedMeshComponent].
  List<Matrix4>? instanceTransforms;

  /// Node-local aggregate AABB covering every instance, used to
  /// frustum-cull an instanced item as a single unit.
  ///
  /// `null` means the instanced item is unbounded and always drawn.
  /// Ignored for non-instanced items.
  Aabb3? instanceBounds;

  /// The local-space AABB this item is frustum-culled against, or `null`
  /// when it should be treated as always visible.
  ///
  /// An instanced item uses its [instanceBounds]; a regular item uses its
  /// geometry's local bounds.
  Aabb3? get cullBounds =>
      instanceTransforms != null ? instanceBounds : geometry.localBounds;

  /// World-space AABB ([cullBounds] transformed by [worldTransform]), or
  /// `null` when the item is unbounded.
  ///
  /// Refreshed each frame by [refreshWorldBounds] and consumed by the
  /// scene's spatial structure.
  Aabb3? worldBounds;

  // Reused across [refreshWorldBounds] calls so a steady-state refresh
  // allocates nothing.
  static final Aabb3 _worldBoundsScratch = Aabb3();

  /// Recomputes [worldBounds] from [cullBounds] and [worldTransform], and
  /// returns whether the value changed since the previous call.
  ///
  /// Call after refreshing [worldTransform]. The owning component uses
  /// the return value to know when the spatial structure is stale.
  bool refreshWorldBounds() {
    final local = cullBounds;
    if (local == null) {
      if (worldBounds == null) return false;
      worldBounds = null;
      return true;
    }
    _worldBoundsScratch
      ..copyFrom(local)
      ..transform(worldTransform);
    final current = worldBounds;
    if (current == null) {
      worldBounds = Aabb3.copy(_worldBoundsScratch);
      return true;
    }
    if (current.min == _worldBoundsScratch.min &&
        current.max == _worldBoundsScratch.max) {
      return false;
    }
    current.copyFrom(_worldBoundsScratch);
    return true;
  }
}

/// The retained render layer for a `Scene`: every [RenderItem], plus a
/// spatial structure the render passes cull against.
///
/// The node graph registers and unregisters items as mesh-bearing nodes
/// are mounted into and out of the scene. Bounded items are placed in a
/// [Bvh]; unbounded items (no [RenderItem.worldBounds], or
/// [RenderItem.frustumCulled] off) are always visited.
class RenderScene {
  /// Every registered render item, in no particular order.
  final List<RenderItem> items = [];

  /// The directional lights contributed by mounted
  /// [DirectionalLightComponent]s, in registration order. The renderer
  /// currently shades the first; the rest are collected for future
  /// multi-light support.
  final List<DirectionalLightComponent> directionalLights = [];

  /// Registers [light] as an active directional light. Called by a
  /// [DirectionalLightComponent] when its owning node mounts.
  void addDirectionalLight(DirectionalLightComponent light) {
    directionalLights.add(light);
  }

  /// The mounted widget components, in registration order. `SceneView`
  /// listens to [widgetComponentsChanged] and hosts each component's widget
  /// subtree invisibly.
  final List<Object> widgetComponents = [];

  /// Bumped whenever [widgetComponents] changes.
  final ValueNotifier<int> widgetComponentsChanged = ValueNotifier<int>(0);

  /// Registers a mounted widget component (typed as Object to keep this
  /// render-layer file free of a widgets dependency).
  void addWidgetComponent(Object component) {
    widgetComponents.add(component);
    widgetComponentsChanged.value++;
  }

  /// Unregisters an unmounted widget component.
  void removeWidgetComponent(Object component) {
    widgetComponents.remove(component);
    widgetComponentsChanged.value++;
  }

  /// Unregisters [light]. Called when its owning node unmounts.
  void removeDirectionalLight(DirectionalLightComponent light) {
    directionalLights.remove(light);
  }

  /// The environment volumes contributed by mounted
  /// [EnvironmentVolumeComponent]s, in registration order. Folded into the
  /// scene's environment blend by camera position each frame.
  final List<EnvironmentVolumeComponent> environmentVolumeComponents = [];

  /// Registers [volume] as an active environment volume. Called by an
  /// [EnvironmentVolumeComponent] when its owning node mounts.
  void addEnvironmentVolumeComponent(EnvironmentVolumeComponent volume) {
    environmentVolumeComponents.add(volume);
  }

  /// Unregisters [volume]. Called when its owning node unmounts.
  void removeEnvironmentVolumeComponent(EnvironmentVolumeComponent volume) {
    environmentVolumeComponents.remove(volume);
  }

  /// The mounted [CameraComponent]s, in mount order. The first is the
  /// auto-promoted primary when no [cameraOverride] is set.
  final List<CameraComponent> cameras = [];

  /// An explicit primary-camera override, set through `Scene.camera`. When
  /// non-null it wins over auto-promotion; when null the primary resolves to
  /// the first mounted [CameraComponent], or null when there are none.
  Camera? cameraOverride;

  /// Registers [camera] as a mounted camera. Called by a [CameraComponent]
  /// when its owning node mounts.
  void addCamera(CameraComponent camera) {
    cameras.add(camera);
  }

  /// Unregisters [camera]. Called when its owning node unmounts.
  void removeCamera(CameraComponent camera) {
    cameras.remove(camera);
  }

  /// The scene's primary camera: the explicit [cameraOverride] if set, else
  /// the first mounted [CameraComponent]'s camera, else null.
  Camera? get primaryCamera =>
      cameraOverride ?? (cameras.isEmpty ? null : cameras.first.toCamera());

  Bvh _bvh = Bvh.build([]);

  // Items that are neither BVH leaves nor pending: unbounded, or opted
  // out of frustum culling. Visited on every cull.
  final List<RenderItem> _alwaysVisible = [];

  // Items registered (or whose BVH membership changed) since the last full
  // rebuild. Visited on every cull, like [_alwaysVisible], until a rebuild
  // sorts them into the tree, so nothing that would have drawn is ever
  // culled while the rebuild is deferred.
  final List<RenderItem> _pending = [];

  // BVH leaves removed (or whose membership changed) since the last full
  // rebuild. Flagged [RenderItem.bvhDead] so the query skips them; kept
  // here so the rebuild can clear the flags on items it no longer sees.
  final List<RenderItem> _dead = [];

  // An explicit full-rebuild request ([markBvhStructureDirty]), or the
  // very first frame.
  bool _fullRebuildRequested = true;

  // A bounded item moved; the BVH can refit instead of rebuilding.
  bool _boundsDirty = false;

  // Frames [rebuildIfDirty] has run with pending or dead items and chosen
  // to defer. Caps how long a landed city tile is culled the slow way.
  int _deferredFrames = 0;

  /// Whether the most recent [rebuildIfDirty] rebuilt the whole BVH (as
  /// opposed to deferring, refitting, or doing nothing). For frame stats.
  bool lastRebuildWasFull = false;

  /// Items waiting for the next full rebuild to enter the BVH. Each is
  /// visited on every cull until then. For frame stats.
  int get pendingItems => _pending.length;

  /// BVH leaves flagged dead since the last full rebuild. For frame stats.
  int get deadItems => _dead.length;

  /// How many pending plus dead items a deferred rebuild tolerates before
  /// it runs: 32, or a tenth of the scene, whichever is larger. A single
  /// tile landing (a few dozen nodes) stays under it; a burst of them,
  /// or the initial load, does not.
  int get _rebuildThreshold {
    final tenth = items.length ~/ 10;
    return tenth > 32 ? tenth : 32;
  }

  /// Frames a deferred rebuild waits at most before running anyway.
  static const int _maxDeferredFrames = 120;

  void add(RenderItem item) {
    items.add(item);
    // An item re-registered while its old leaf is still in the tree keeps
    // that leaf dead (its bounds or membership may have changed in the
    // meantime) and is visited through the pending list until the next
    // rebuild, like any other newcomer.
    _pending.add(item);
  }

  void remove(RenderItem item) {
    items.remove(item);
    if (item.bvhLeaf) {
      if (!item.bvhDead) {
        item.bvhDead = true;
        _dead.add(item);
      }
      // A leaf whose membership changed is also queued as pending.
      _pending.remove(item);
      return;
    }
    if (!_pending.remove(item)) {
      _alwaysVisible.remove(item);
    }
  }

  /// Flags the BVH for a full rebuild on the next [rebuildIfDirty],
  /// bypassing the deferral. Kept for callers that changed something the
  /// item-level [markBvhMembershipChanged] does not describe; the engine
  /// components use the item-level call.
  void markBvhStructureDirty() {
    _fullRebuildRequested = true;
  }

  /// Notes that [item]'s BVH membership changed: its `frustumCulled` flag
  /// toggled, or it became bounded or unbounded. A leaf is retired to the
  /// dead list and re-queued as pending so it stays visible either way; an
  /// always-visible item moves to pending so the next rebuild reconsiders
  /// it. Called by the owning component during the pre-pass.
  void markBvhMembershipChanged(RenderItem item) {
    if (item.bvhLeaf) {
      if (item.bvhDead) return;
      item.bvhDead = true;
      _dead.add(item);
      _pending.add(item);
      return;
    }
    if (_alwaysVisible.remove(item)) {
      _pending.add(item);
    }
  }

  /// Flags the BVH for a refit. Called when a bounded item moved but the
  /// item set and membership are unchanged.
  void markBvhBoundsDirty() {
    _boundsDirty = true;
  }

  /// Brings the spatial structure up to date with the current items.
  /// Call once per frame, after the pre-pass and before the render
  /// passes.
  ///
  /// A full rebuild is deferred: added items sit in a pending list that
  /// every cull visits, removed leaves are skipped by the query, and the
  /// tree is only rebuilt when the pending and dead counts pass
  /// [_rebuildThreshold], when [_maxDeferredFrames] frames have gone by
  /// with the rebuild outstanding, or when one was requested outright.
  /// Otherwise a moved item refits the tree in place, and a quiet frame
  /// does nothing. Visibility is the same either way: a pending item is
  /// always visited and the encoder does its own per-item frustum test.
  void rebuildIfDirty() {
    lastRebuildWasFull = false;
    final structureChanged = _pending.isNotEmpty || _dead.isNotEmpty;
    if (structureChanged) _deferredFrames++;
    final rebuild =
        _fullRebuildRequested ||
        (structureChanged &&
            (_pending.length + _dead.length > _rebuildThreshold ||
                _deferredFrames >= _maxDeferredFrames));
    if (rebuild) {
      _rebuild();
    } else if (_boundsDirty) {
      _boundsDirty = false;
      _bvh.refit();
    }
  }

  void _rebuild() {
    _fullRebuildRequested = false;
    _boundsDirty = false;
    _deferredFrames = 0;
    lastRebuildWasFull = true;
    // Items that left the scene keep no stale leaf flags, or a later
    // re-add would revive a leaf the new tree does not have.
    for (final item in _dead) {
      item
        ..bvhLeaf = false
        ..bvhDead = false;
    }
    _dead.clear();
    _pending.clear();
    _alwaysVisible.clear();
    final bounded = <RenderItem>[];
    for (final item in items) {
      item.bvhDead = false;
      if (item.frustumCulled && item.worldBounds != null) {
        item.bvhLeaf = true;
        bounded.add(item);
      } else {
        item.bvhLeaf = false;
        _alwaysVisible.add(item);
      }
    }
    _bvh = Bvh.build(bounded, reuse: _bvh);
  }

  /// Visits every item potentially visible to [frustum]: the bounded
  /// items whose world AABB intersects it, plus every always-visible
  /// item, plus every item still pending a BVH rebuild.
  void cull(Frustum frustum, void Function(RenderItem) visit) {
    _bvh.query(frustum, visit);
    for (final item in _alwaysVisible) {
      visit(item);
    }
    for (final item in _pending) {
      visit(item);
    }
  }
}
