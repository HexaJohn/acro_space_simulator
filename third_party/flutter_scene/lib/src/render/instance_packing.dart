import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show SceneFrameStats;
import 'package:vector_math/vector_math.dart';

/// Per-instance world transforms packed for the instance-rate vertex buffer
/// (slot 1), split by winding parity.
///
/// Hardware instancing draws a whole group with one fixed winding order, but
/// a mirrored (negative-determinant) instance reverses triangle winding, so
/// instances are partitioned into the counter-clockwise group ([ccw], the
/// default front-face winding) and the clockwise group ([cw], mirrored).
/// Each list is the instances' world transforms (node transform times
/// instance transform) as consecutive column-major mat4s, 16 floats per
/// instance, exactly the byte layout the `model_transform_0..3` instance
/// attributes consume.
class PackedInstanceTransforms {
  PackedInstanceTransforms(this.ccw, this.cw);

  final Float32List ccw;
  final Float32List cw;

  int get ccwCount => ccw.length ~/ 16;
  int get cwCount => cw.length ~/ 16;
}

/// Packs `nodeTransform * instances[i]` into per-parity instance buffers.
///
/// [nodeWindingFlipped] is the parity of the node's own world transform;
/// each instance's own determinant combines with it, matching the
/// per-instance winding flip the looping path applied.
PackedInstanceTransforms packInstanceTransforms(
  Matrix4 nodeTransform,
  List<Matrix4> instances, {
  bool nodeWindingFlipped = false,
}) {
  var cwCount = 0;
  final flipped = List<bool>.filled(instances.length, false);
  for (var i = 0; i < instances.length; i++) {
    final flip = nodeWindingFlipped != (instances[i].determinant() < 0);
    flipped[i] = flip;
    if (flip) cwCount++;
  }
  final ccw = Float32List((instances.length - cwCount) * 16);
  final cw = Float32List(cwCount * 16);
  var ccwIndex = 0, cwIndex = 0;
  final world = Matrix4.zero();
  for (var i = 0; i < instances.length; i++) {
    world.setFrom(nodeTransform);
    world.multiply(instances[i]);
    if (flipped[i]) {
      cw.setAll(cwIndex * 16, world.storage);
      cwIndex++;
    } else {
      ccw.setAll(ccwIndex * 16, world.storage);
      ccwIndex++;
    }
  }
  return PackedInstanceTransforms(ccw, cw);
}

/// The packed instance transforms for [item], reusing the pack cached on
/// the item while nothing it depends on has changed.
///
/// [instances] must be the item's own instance list
/// ([RenderItem.instanceTransforms]); the cache is keyed by the
/// `InstancedMesh` version the pre-pass stamped into
/// [RenderItem.instanceVersion], the item's world transform, and its
/// winding parity, and is rebuilt with [packInstanceTransforms] when any of
/// them moved. A static instanced mesh is therefore packed once rather than
/// once per pass per frame; a mesh whose instances move every frame repacks
/// exactly as before.
///
/// The cached `Float32List` is still emplaced into the frame's host buffer
/// on every pass ([bindInstanceTransforms]), so the GLES upload race
/// (flutter/flutter#187931) is neither widened nor narrowed by the cache:
/// the bytes the GPU reads come from the same per-frame transient buffer
/// as before, only the CPU-side multiply is skipped.
PackedInstanceTransforms packedInstancesFor(
  RenderItem item,
  List<Matrix4> instances,
) {
  final cached = item.packedCache;
  if (cached != null &&
      item.packedVersion == item.instanceVersion &&
      item.packedWindingFlipped == item.windingFlipped &&
      item.packedWorld == item.worldTransform) {
    return cached;
  }
  final packed = packInstanceTransforms(
    item.worldTransform,
    instances,
    nodeWindingFlipped: item.windingFlipped,
  );
  item
    ..packedCache = packed
    ..packedVersion = item.instanceVersion
    ..packedWindingFlipped = item.windingFlipped
    ..packedWorld.setFrom(item.worldTransform);
  return packed;
}

/// Uploads a single world transform as a one-element instance buffer and
/// binds it to the instance-rate vertex buffer slot.
///
/// Every draw through the unskinned vertex shader needs this: the model
/// matrix arrives via instance attributes whether or not the draw is
/// instanced.
void bindSingleInstanceTransform(
  gpu.RenderPass pass,
  Matrix4 worldTransform, {
  int slot = 1,
}) {
  bindInstanceTransforms(
    pass,
    Float32List.fromList(worldTransform.storage),
    slot: slot,
  );
}

/// Uploads [packed] transforms and binds them to the instance-rate slot.
///
/// The transforms are emplaced into [instanceTransformBuffers], a `HostBuffer`
/// dedicated to instance vertex data, separate from the per-frame transient
/// uniform `HostBuffer`. The split dates from debugging stale instance
/// transforms on the GLES backend, which turned out to be an engine bug
/// (flutter/flutter#187931, buffer writes racing the GL upload) that a
/// dedicated buffer does not actually avoid. Kept for now since it is
/// harmless and the engine fix has not shipped in the SDK yet.
void bindInstanceTransforms(
  gpu.RenderPass pass,
  Float32List packed, {
  int slot = 1,
}) {
  // TODO(gles-dirty-range): fold instance transforms back into the shared
  // transients HostBuffer once flutter/flutter#187931 is fixed in the SDK.
  if (packed.isEmpty) return;
  pass.bindVertexBuffer(
    instanceTransformBuffers.emplace(ByteData.sublistView(packed)),
    slot: slot,
  );
}

/// PATCHED (acro_space_simulator): which uploads of a [RenderItem]'s packed
/// instances the passes of ONE frame may share.
///
/// A view is handed back only while both the pack OBJECT and the frame are
/// the ones it was emplaced for: a repack (an instance moved, the node moved,
/// the winding flipped) makes a new pack, and a new frame cycles the host
/// buffer's storage, so either must upload again or a draw would read bytes
/// that have been overwritten. Pure, so the rule is testable without a GPU.
class PackedViewCache {
  Object? _ccw;
  Object? _cw;
  Object? _of;
  int _frame = -1;

  /// The view of [packed]'s [ccw] parity already emplaced in [frame], or
  /// null when it must be uploaded again (which also drops both parities).
  Object? viewFor(Object packed, int frame, {required bool ccw}) {
    if (!identical(_of, packed) || _frame != frame) {
      _of = packed;
      _frame = frame;
      _ccw = null;
      _cw = null;
      return null;
    }
    return ccw ? _ccw : _cw;
  }

  /// Remembers [view] as the upload of the current pack's [ccw] parity.
  void remember(Object view, {required bool ccw}) {
    if (ccw) {
      _ccw = view;
    } else {
      _cw = view;
    }
  }
}

/// PATCHED (acro_space_simulator): binds [item]'s packed instances, uploading
/// them at most ONCE per frame however many passes draw the item.
///
/// The depth pre-pass and the colour pass draw the same instances of the same
/// item at the same world transform, so their instance bytes are identical;
/// each emplacing its own copy doubled the traffic through the shared
/// instance host buffer (a city at close range measured ~4 MB a frame, and
/// shadow draws outnumbered colour draws two to one). The views are cached on
/// the item against the pack OBJECT and the current [frameId], so a repack
/// (any instance moved, the node moved, winding flipped) or a new frame
/// uploads again — a stale upload can never be drawn.
///
/// Returns nothing; binds the parity [ccw] asks for, if it has instances.
void bindPackedInstances(
  gpu.RenderPass pass,
  RenderItem item,
  PackedInstanceTransforms packed, {
  required bool ccw,
  int slot = 1,
}) {
  final data = ccw ? packed.ccw : packed.cw;
  if (data.isEmpty) return;
  final frame = instanceTransformBuffers.frameId;
  var view = item.packedViews.viewFor(packed, frame, ccw: ccw);
  if (view == null) {
    view = instanceTransformBuffers.emplace(ByteData.sublistView(data));
    item.packedViews.remember(view, ccw: ccw);
    SceneFrameStats.accumulating.instanceUploads += data.length ~/ 16;
  }
  pass.bindVertexBuffer(view as gpu.BufferView, slot: slot);
}

/// A `HostBuffer` dedicated to instance-rate transform vertex data, kept
/// apart from the uniform transients buffer (see [bindInstanceTransforms]
/// for why). [beginFrame] cycles it to the next frame's backing storage
/// and is driven once per frame from the render setup.
class InstanceTransformBuffers {
  // Created lazily: the GPU context initializes on the raster thread after
  // the first frame on some backends, so it isn't available at startup.
  gpu.HostBuffer? _buffer;
  gpu.HostBuffer get _host => _buffer ??= gpu.gpuContext.createHostBuffer();

  // PATCHED (acro_space_simulator): a frame counter, so a pack emplaced by
  // one pass can be re-bound by the next pass of the SAME frame instead of
  // being uploaded again (see [bindPackedInstances]). It only ever moves
  // forward, and a view cached against an older frame is never reused: the
  // storage behind it is cycled by [beginFrame].
  int _frameId = 0;
  int get frameId => _frameId;

  /// Cycles to the next frame's backing storage. Call once per frame
  /// before any [emplace].
  void beginFrame() {
    _frameId++;
    _host.reset();
  }

  /// Emplaces [data] and returns a view to bind as the instance-rate
  /// vertex buffer.
  gpu.BufferView emplace(ByteData data) => _host.emplace(data);
}

/// The process-wide instance-transform vertex buffer. One GPU context per
/// process, so a single buffer serves every scene; [beginFrame] is driven
/// from the per-frame render setup.
// TODO(instance-buffer-ownership): a single process-wide buffer means two
// Scenes rendering in the same frame both reset it; make it per-Surface if
// multi-scene-per-frame becomes common.
final InstanceTransformBuffers instanceTransformBuffers =
    InstanceTransformBuffers();
