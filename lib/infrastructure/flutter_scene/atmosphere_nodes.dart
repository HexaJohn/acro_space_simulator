import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';
import 'sphere_geometry_util.dart';

/// Raymarched planetary atmospheres (Nishita-style single scattering) —
/// the custom-shader equivalent of the Unreal HLSL atmosphere.
///
/// Each atmospheric body carries a shell sphere at the atmosphere top,
/// rendered BACKFACES-ONLY through [fs.ShaderMaterial] running
/// shaders/atmosphere.frag: the fragment reconstructs the camera ray,
/// intersects the shell and the (analytic) planet sphere, and integrates
/// Rayleigh scattering toward the sun. Back faces make the same math work
/// from outside, inside, and straight through the atmosphere boundary —
/// entry distance clamps to zero in the shader, so the surface transition
/// is seamless.
///
/// Per-frame work is UNIFORMS ONLY (no geometry churn): planet centre,
/// radii, sun direction, coefficients.
class AtmosphereNodes {
  AtmosphereNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, _Shell> _shells = {};

  /// Aerosol tint overrides for bodies whose visible haze is NOT their gas
  /// mix: Titan's orange is photochemical tholin smog — its N2 composition
  /// tints blue. Value: (argb, mix strength).
  static const Map<String, (int, double)> _hazeOverride = {
    'titan': (0xFFCC7A33, 0.85),
  };

  /// The compiled atmosphere fragment shader, loaded once per app from the
  /// bundle the build hook produces. Null until [loadShader] completes
  /// (shells simply don't spawn until then).
  static Object? _shader;
  static Future<void>? _loading;

  static Future<void> loadShader() => _loading ??= () async {
        final library = await gpu.loadShaderLibraryAsync(
          'build/shaderbundles/acro.shaderbundle',
        );
        _shader = library?['AtmosphereFragment'];
        if (_shader == null) {
          throw StateError(
            'AtmosphereFragment missing from acro.shaderbundle — the '
            'hook/build.dart shader compile should have produced it.',
          );
        }
      }();

  void update(WorldSnapshot snap, FloatingOrigin origin,
      {Vector3 cameraEye = Vector3.zero, Vector3? starWorld}) {
    final shader = _shader;
    if (shader == null) return; // bundle still loading
    final seen = <String>{};
    for (final b in snap.bodies.values) {
      final d = snap.descriptors[b.id];
      if (d == null || !d.atmoPresent || d.atmoThickness <= 0) continue;
      if (d.kind == BodyKind.star) continue;
      seen.add(b.id);

      final shell = _shells.putIfAbsent(b.id, () {
        final s = _Shell(shader);
        _scene.add(s.node);
        return s;
      });

      // Atmosphere top: physical thickness, padded so the exponential tail
      // doesn't clip visibly at the shell boundary.
      final world = Vector3(b.px, b.py, b.pz);
      final rel = origin.worldToRel(world);
      final atmoTopM = b.radius + d.atmoThickness * 3.0;

      shell.node.localTransform = vm.Matrix4.compose(
        relToScene(rel),
        vm.Quaternion.identity(),
        vm.Vector3.all(lengthToScene(atmoTopM)),
      );

      final toSun = starWorld == null
          ? Vector3.unitX
          : (starWorld - world).normalized;
      // Scattering strength relative to Earth sea level, from the body's
      // REAL surface density (Mars ~1.6% reads as milky Earth-glass
      // without this). Clamped: Venus' 65x must stay a translucent shroud,
      // not an opaque billiard ball.
      final density = d.atmoSeaLevelDensity > 0
          ? (d.atmoSeaLevelDensity / 1.225).clamp(0.04, 4.0).toDouble()
          : 1.0;
      final haze = _hazeOverride[b.id];
      shell.updateUniforms(
        centreScene: relToScene(rel),
        planetRadiusScene: lengthToScene(b.radius),
        atmoTopScene: lengthToScene(atmoTopM),
        toSun: toSun,
        scaleHeightScene:
            lengthToScene(d.atmoScaleHeight <= 0 ? 8500.0 : d.atmoScaleHeight),
        tintArgb: haze?.$1 ?? d.atmoScatterColorArgb,
        tintMix: haze?.$2,
        density: density,
      );
    }

    _shells.removeWhere((id, shell) {
      if (seen.contains(id)) return false;
      _scene.remove(shell.node);
      return true;
    });
  }
}

class _Shell {
  _Shell(Object shader) {
    // Depth compare ALWAYS (see depth_materials.dart): the interior faces
    // sit behind the planet's opaque surface, so the pass's lessEqual
    // would cull the entire disc — occlusion is analytic in the shader.
    _material = AtmosphereShaderMaterial(fragmentShader: shader as gpu.Shader);
    // INVERTED sphere + default backface culling = interior faces only:
    // exactly one raymarch fragment per pixel, and the shell keeps
    // rendering with the camera inside it (its exterior faces would sit
    // behind the eye).
    node = fs.Node(
      mesh: fs.Mesh(
          uvSphereZUp(segments: 48, rings: 24, invert: true), _material),
    );
  }

  late final fs.Node node;
  late final AtmosphereShaderMaterial _material;

  // Physical Earth Rayleigh coefficients, per KILOMETRE (scene unit):
  // beta = (5.8e-3, 1.35e-2, 3.31e-2). Non-Earth hues come from the
  // descriptor tint mixed in the shader.
  static const _betaR = 5.8e-3, _betaG = 1.35e-2, _betaB = 3.31e-2;

  final Float32List _uniforms = Float32List(20); // 5 x vec4, std140

  void updateUniforms({
    required vm.Vector3 centreScene,
    required double planetRadiusScene,
    required double atmoTopScene,
    required Vector3 toSun,
    required double scaleHeightScene,
    required int tintArgb,
    double? tintMix,
    double density = 1.0,
  }) {
    // vec4 center_radius
    _uniforms[0] = centreScene.x;
    _uniforms[1] = centreScene.y;
    _uniforms[2] = centreScene.z;
    _uniforms[3] = planetRadiusScene;
    // vec4 sun_atmo
    _uniforms[4] = toSun.x;
    _uniforms[5] = toSun.y;
    _uniforms[6] = toSun.z;
    _uniforms[7] = atmoTopScene;
    // vec4 rayleigh (+ scale height); density pre-multiplied into the betas
    // so the shader stays body-agnostic.
    _uniforms[8] = _betaR * density;
    _uniforms[9] = _betaG * density;
    _uniforms[10] = _betaB * density;
    _uniforms[11] = scaleHeightScene;
    // vec4 params: intensity, tint mix, tint r, tint g
    final hasTint = tintArgb != 0;
    _uniforms[12] = 22.0; // sun intensity (tonemapped downstream)
    _uniforms[13] = hasTint ? (tintMix ?? 0.5) : 0.0;
    _uniforms[14] = hasTint ? ((tintArgb >> 16) & 0xff) / 255.0 : 0.0;
    _uniforms[15] = hasTint ? ((tintArgb >> 8) & 0xff) / 255.0 : 0.0;
    // vec4 params2: tint b + padding
    _uniforms[16] = hasTint ? (tintArgb & 0xff) / 255.0 : 0.0;
    _uniforms[17] = 0.0;
    _uniforms[18] = 0.0;
    _uniforms[19] = 0.0;
    _material.setUniformBlockFromFloats('AtmosphereInfo', _uniforms);
  }
}
