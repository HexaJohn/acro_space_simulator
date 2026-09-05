import 'package:flutter_scene/src/geometry/geometry.dart'
    show UnskinnedFrameInfo;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart' show ShadowCasterFaces;
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/scene_encoder.dart'
    show SceneFrameStats, resolvePipeline;
import 'package:flutter_scene/src/shaders.dart';

/// Records each opaque shadow caster's depth into a shadow-map render
/// pass, from a directional light's point of view.
///
/// Reuses the engine's standard vertex shaders (so unskinned and skinned
/// geometry both cast shadows) paired with the `DepthOnlyFragment`
/// shader, supplying the light-space view-projection matrix in place of
/// the camera transform. Translucent materials don't cast shadows.
class ShadowEncoder {
  ShadowEncoder(
    this._renderPass,
    this._transientsBuffer,
    this._lightSpaceMatrix,
    ShadowCasterFaces casterFaces,
  ) {
    frustum = Frustum.matrix(_lightSpaceMatrix);
    // The light-space block is constant for the cascade: emplace it once and
    // rebind the view only when the bindings were cleared.
    _frameInfo = UnskinnedFrameInfo(
      _transientsBuffer,
      _lightSpaceMatrix,
      _cameraPositionPlaceholder,
    );
    _renderPass.setDepthWriteEnable(true);
    _renderPass.setColorBlendEnable(false);
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    // Cull the complement of the faces that should cast: rendering front faces
    // (the default) means culling back faces, and vice versa. With base CCW
    // winding (flipped per-item for mirrored casters below), back-face culling
    // keeps the light-facing faces. [ShadowCasterFaces.back] (second-depth)
    // suits solid geometry, recording the far face to avoid self-shadow acne.
    _renderPass.setCullMode(switch (casterFaces) {
      ShadowCasterFaces.front => gpu.CullMode.backFace,
      ShadowCasterFaces.back => gpu.CullMode.frontFace,
      ShadowCasterFaces.both => gpu.CullMode.none,
    });
    _renderPass.setWindingOrder(gpu.WindingOrder.counterClockwise);
  }

  final gpu.RenderPass _renderPass;
  final gpu.HostBuffer _transientsBuffer;
  final Matrix4 _lightSpaceMatrix;
  late final UnskinnedFrameInfo _frameInfo;

  static final gpu.Shader _depthShader =
      baseShaderLibrary['DepthOnlyFragment']!;
  static final Vector3 _cameraPositionPlaceholder = Vector3.zero();

  /// Frustum of the light-space view-projection, used for per-item
  /// culling.
  late final Frustum frustum;

  /// Reusable AABB for the per-item cull check.
  final Aabb3 cullScratchAabb = Aabb3();

  /// The pipeline currently bound on the render pass, or null before the
  /// first draw. `clearBindings` leaves the pipeline in place, so
  /// consecutive casters that share one only bind it once.
  gpu.RenderPipeline? _boundPipeline;

  // PATCHED (acro_space_simulator): bindings persist across draws until
  // `clearBindings`, so a position-only caster that follows one with the same
  // pipeline keeps the light-space block bound and rebinds only its position
  // stream, index buffer and instance transform. The bindings are cleared
  // when the pipeline changes, at an indexed/non-indexed boundary, and for
  // skinned casters (whose full bind sets joints and its own block per draw).
  bool _frameInfoBound = false;
  bool _runIndexed = false;
  // Pass state tracked so a caster only sets what changed. The winding is
  // relative to the counter-clockwise base set in the constructor: true when
  // flipped to clockwise for a mirrored caster.
  bool _windingFlipped = false;
  gpu.PrimitiveType? _boundPrimitive;

  void _setWinding(bool flipped) {
    if (flipped == _windingFlipped) return;
    _renderPass.setWindingOrder(
      flipped ? gpu.WindingOrder.clockwise : gpu.WindingOrder.counterClockwise,
    );
    _windingFlipped = flipped;
  }

  void _setPrimitiveType(gpu.PrimitiveType type) {
    if (type == _boundPrimitive) return;
    _renderPass.setPrimitiveType(type);
    _boundPrimitive = type;
  }

  /// Records [item]'s depth, unless it is hidden, translucent (no shadow),
  /// or culled by the light frustum.
  void submit(RenderItem item) {
    if (!item.visible) return;
    if (!item.material.isOpaque()) return;
    if (item.frustumCulled) {
      final bounds = item.cullBounds;
      if (bounds != null) {
        cullScratchAabb
          ..copyFrom(bounds)
          ..transform(item.worldTransform);
        if (!frustum.intersectsWithAabb3(cullScratchAabb)) return;
      }
    }
    final geometry = item.geometry;
    // Unskinned casters draw depth through a position-only shader and layout;
    // skinned geometry falls back to its full vertex shader and bind.
    final depthVertex = geometry.depthOnlyVertex;
    final pipeline = resolvePipeline(
      depthVertex?.shader ?? geometry.vertexShader,
      _depthShader,
      vertexLayout: depthVertex?.layout ?? geometry.instancedVertexLayout,
    );
    final indexed = geometry.isIndexed;
    if (depthVertex == null ||
        !identical(_boundPipeline, pipeline) ||
        indexed != _runIndexed) {
      _renderPass.clearBindings();
      _frameInfoBound = false;
      _runIndexed = indexed;
    }
    if (!identical(_boundPipeline, pipeline)) {
      _renderPass.bindPipeline(pipeline);
      _boundPipeline = pipeline;
    }
    _setPrimitiveType(geometry.primitiveType);
    final stats = SceneFrameStats.accumulating;

    // Binds the vertex/index buffers and the per-frame uniform for one draw.
    // The light-space matrix takes the place of the camera transform; the
    // camera position is unused by the shadow fragment shader.
    void bindDraw(Matrix4 worldTransform) {
      if (depthVertex != null) {
        geometry.bindPositionStream(_renderPass);
        if (!_frameInfoBound) {
          _frameInfo.bind(_renderPass, depthVertex.shader);
          _frameInfoBound = true;
        }
      } else {
        geometry.bind(
          _renderPass,
          _transientsBuffer,
          worldTransform,
          _lightSpaceMatrix,
          _cameraPositionPlaceholder,
        );
      }
    }

    final instances = item.instanceTransforms;
    if (instances != null) {
      if (geometry.instancedVertexLayout == null) {
        // Skinned geometry has no instance-attribute path; loop.
        for (final instanceTransform in instances) {
          bindDraw(item.worldTransform * instanceTransform);
          _setWinding(
            item.windingFlipped != (instanceTransform.determinant() < 0),
          );
          geometry.draw(_renderPass);
          stats.shadowDraws++;
        }
        return;
      }
      bindDraw(item.worldTransform);
      final packed = packInstanceTransforms(
        item.worldTransform,
        instances,
        nodeWindingFlipped: item.windingFlipped,
      );
      stats.packedInstances += instances.length;
      if (packed.ccwCount > 0) {
        bindInstanceTransforms(_renderPass, packed.ccw);
        _setWinding(false);
        geometry.draw(_renderPass, instanceCount: packed.ccwCount);
        stats.shadowDraws++;
      }
      if (packed.cwCount > 0) {
        bindInstanceTransforms(_renderPass, packed.cw);
        _setWinding(true);
        geometry.draw(_renderPass, instanceCount: packed.cwCount);
        stats.shadowDraws++;
      }
      return;
    }

    bindDraw(item.worldTransform);
    // Skip the model-transform instance buffer for geometry that supplies its
    // own per-instance buffer (see the color encoder), or it clobbers slot 1.
    if (geometry.instancedVertexLayout != null &&
        geometry.bindsModelTransformInstance) {
      bindSingleInstanceTransform(_renderPass, item.worldTransform);
    }
    // Mirrored casters reverse winding; flip the cull order so the same faces
    // that are visible also cast shadows.
    _setWinding(item.windingFlipped);
    geometry.draw(_renderPass);
    stats.shadowDraws++;
  }
}
