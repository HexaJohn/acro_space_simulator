// ignore_for_file: implementation_imports
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_scene/src/gpu/gpu.dart' as igpu;

/// Depth-state-aware materials.
///
/// flutter_scene's encoder sets the depth compare op ONCE per pass
/// (lessEqual) and materials never touch it — RenderPass depth state is
/// sticky across draws. The raymarched atmosphere shell needs
/// `CompareFunction.always` (its interior faces sit BEHIND the planet
/// surface, so lessEqual kills every fragment over the disc; occlusion is
/// analytic inside the shader instead). Setting that in `bind` leaks the
/// `always` op to every translucent record drawn after the shell in the
/// same frame — orbit rails would draw straight through planets. So:
///
///  * [AtmosphereShaderMaterial] — forces `always` for its own draw.
///  * [DepthSafeUnlitMaterial] — an [fs.UnlitMaterial] that restores
///    `lessEqual` as it binds; every other translucent material in the app
///    (lines, rings) uses this so draw order never inherits the shell's op.
class AtmosphereShaderMaterial extends fs.ShaderMaterial {
  AtmosphereShaderMaterial({super.fragmentShader, this.depthAlways = true})
      : super(isOpaqueOverride: false);

  /// True for the INTERIOR-faces shell (camera inside the atmosphere): its
  /// faces sit behind the planet, so comparing against the opaque planet
  /// would cull the whole disc — occlusion is analytic in the shader.
  /// False for the EXTERIOR-faces shell (camera outside): normal lessEqual
  /// keeps it depth-correct against opaque geometry INSIDE the scene —
  /// without it the haze composited over ring asteroids and vessels that
  /// were clearly in front of the atmosphere.
  final bool depthAlways;

  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
    pass.setDepthCompareOperation(depthAlways
        ? igpu.CompareFunction.always
        : igpu.CompareFunction.lessEqual);
  }
}

/// A custom-shader material for NORMAL depth-tested translucency (the ring
/// sheet): restores lessEqual like [DepthSafeUnlitMaterial], so it never
/// inherits the atmosphere shell's `always`.
class DepthSafeShaderMaterial extends fs.ShaderMaterial {
  DepthSafeShaderMaterial({super.fragmentShader})
      : super(isOpaqueOverride: false);

  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
    pass.setDepthCompareOperation(igpu.CompareFunction.lessEqual);
  }
}

class DepthSafeUnlitMaterial extends fs.UnlitMaterial {
  DepthSafeUnlitMaterial({super.colorTexture});

  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
    // Undo a preceding AtmosphereShaderMaterial draw's depth op.
    pass.setDepthCompareOperation(igpu.CompareFunction.lessEqual);
  }
}
