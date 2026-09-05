import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart';
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/material/physically_based_material.dart'
    show AlphaMode;

import 'package:vector_math/vector_math.dart';

/// A material that draws geometry with a flat color or texture, ignoring
/// scene lighting.
///
/// Useful for UI overlays, debug visualization, or stylized rendering.
/// The final color is `baseColorFactor * baseColorTexture`, optionally
/// blended with the per-vertex color via [vertexColorWeight].
///
/// Wraps the `UnlitFragment` shader from the base shader library.
/// {@category Materials}
class UnlitMaterial extends Material {
  /// Creates an [UnlitMaterial], optionally textured.
  ///
  /// When [colorTexture] is null a 1×1 white placeholder is used so the
  /// final color reduces to [baseColorFactor].
  UnlitMaterial({gpu.Texture? colorTexture}) : _baseColorSource = colorTexture {
    setFragmentShaderName('UnlitFragment');
  }

  Object? _baseColorSource;

  /// The raw slot source (a gpu.Texture, a RenderTexture, or null), for
  /// serialization, which must see the handle rather than the resolved
  /// frame.
  @internal
  Object? get baseColorTextureSource => _baseColorSource;

  /// The base color texture, sampled and multiplied by [baseColorFactor].
  ///
  /// Accepts a [gpu.Texture] or a `RenderTexture` (sampled live). The
  /// getter never returns null; an empty slot (or a render texture with
  /// no completed frame yet) resolves to a 1×1 white placeholder so the
  /// final color reduces to [baseColorFactor].
  gpu.Texture get baseColorTexture =>
      Material.whitePlaceholder(resolveTextureSource(_baseColorSource));
  set baseColorTexture(Object? value) =>
      _baseColorSource = checkTextureSource(value, 'baseColorTexture');

  /// How the material's alpha is interpreted. [AlphaMode.opaque] ignores
  /// alpha; [AlphaMode.blend] routes the material through the depth-sorted
  /// translucent pass with alpha blending (use for widget textures and
  /// other surfaces with transparency).
  // TODO(materials): support AlphaMode.mask for unlit (needs a cutoff
  // uniform and a discard in the unlit fragment shader); it currently
  // behaves like blend.
  AlphaMode alphaMode = AlphaMode.opaque;

  @override
  bool isOpaque() => alphaMode == AlphaMode.opaque;

  /// Linear RGBA tint multiplied with [baseColorTexture].
  Vector4 baseColorFactor = Colors.white;

  /// How strongly per-vertex colors influence the final color. `0`
  /// disables vertex color contribution; `1` (the default) fully
  /// applies it.
  double vertexColorWeight = 1.0;

  // PATCHED (acro_space_simulator): one FragInfo list per material, refilled
  // in place (emplace copies the bytes out), and one shared repeat sampler,
  // so a bind allocates nothing.
  final Float32List _fragInfo = Float32List(6);

  static final gpu.SamplerOptions _repeatSampler = gpu.SamplerOptions(
    widthAddressMode: gpu.SamplerAddressMode.repeat,
    heightAddressMode: gpu.SamplerAddressMode.repeat,
  );

  @override
  void bind(
    gpu.RenderPass pass,
    gpu.HostBuffer transientsBuffer,
    Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);

    final fragInfo = _fragInfo;
    fragInfo[0] = baseColorFactor.r; // color
    fragInfo[1] = baseColorFactor.g;
    fragInfo[2] = baseColorFactor.b;
    fragInfo[3] = baseColorFactor.a;
    fragInfo[4] = vertexColorWeight; // vertex_color_weight
    fragInfo[5] = lodFade; // fade
    pass.bindUniform(
      uniformSlot("FragInfo"),
      transientsBuffer.emplace(ByteData.sublistView(fragInfo)),
    );
    pass.bindTexture(
      uniformSlot('base_color_texture'),
      baseColorTexture,
      sampler: textureSourceSampler(_baseColorSource) ?? _repeatSampler,
    );
  }
}
