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
  AtmosphereShaderMaterial({super.fragmentShader})
      : super(isOpaqueOverride: false);

  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
    // Depth writes are already off in the translucent phase; comparing
    // against the opaque planet would cull the whole disc. The shader clips
    // rays against the planet sphere analytically.
    pass.setDepthCompareOperation(igpu.CompareFunction.always);
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
