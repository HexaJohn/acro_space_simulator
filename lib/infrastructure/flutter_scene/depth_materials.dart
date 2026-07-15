// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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

  /// `always` skips the depth test entirely for this draw. No shell uses
  /// it anymore — the camera-inside case is covered by a surface-hugging
  /// proxy sphere at correct depth (see _Shell) after `always` was found
  /// painting haze OVER the vessel in flight. Kept for debug bisection.
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

/// A [fs.SpriteMaterial] for NORMAL depth-tested billboards (the star bloom).
///
/// Sprites never write depth, but they must still be depth-TESTED: the bloom's
/// whole occlusion model is "the depth buffer hides it behind terrain, vessels
/// and planets", which silently breaks if it inherits an `always` op from a
/// shell drawn earlier in the frame. Restoring lessEqual here makes that
/// independent of draw order.
class DepthSafeSpriteMaterial extends fs.SpriteMaterial {
  DepthSafeSpriteMaterial({super.colorTexture});

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
