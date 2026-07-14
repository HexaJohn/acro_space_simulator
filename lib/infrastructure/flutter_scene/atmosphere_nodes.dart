// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';
import 'sphere_geometry_util.dart';

/// Per-body art styling for the raymarched atmosphere.
///
/// Values here are RENDER-side only (no physics/aero side effects) and the
/// statics are mutable so dev tooling (`ext.acro.atmo` in main_scene_dev)
/// can tune a live scene during an art pass; bake the tuned numbers back
/// into [AtmosphereNodes.styles] defaults afterwards.
class AtmoStyle {
  AtmoStyle({
    this.enabled = true,
    this.heightScale = 6.0,
    this.falloff = 6.0,
    this.intensity = 22.0,
    this.density,
    this.tintArgb,
    this.tintMix,
    this.shellHeightM,
    this.twilightM,
  });

  bool enabled;

  /// Shell top = radius + thickness * heightScale — how far the raymarch
  /// canvas extends above the surface (room for the glow, not its shape).
  double heightScale;

  /// Multiplies the density scale height: the GLOW TALLNESS knob. The beta
  /// coefficients are divided by the same factor so the nadir haze over the
  /// disc stays constant while the limb fuzz grows.
  double falloff;

  /// Sun intensity feeding the scatter integral.
  double intensity;

  /// Scattering strength relative to Earth sea level; null = physical
  /// (descriptor sea-level density / 1.225, clamped).
  double? density;

  /// Haze tint override (0xAARRGGBB); null = the descriptor's gas-mix tint.
  int? tintArgb;

  /// Tint pull strength 0..1; null = 0.5 when a tint is present.
  double? tintMix;

  /// Synthetic atmosphere thickness (metres) for bodies WITHOUT a domain
  /// atmosphere (gas giants) — purely visual, adds no aero/heating.
  double? shellHeightM;

  /// Terminator blur band width (metres); null = 0.12 * body radius.
  double? twilightM;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'heightScale': heightScale,
    'falloff': falloff,
    'intensity': intensity,
    'density': density,
    'tint': tintArgb?.toRadixString(16),
    'tintMix': tintMix,
    'shellKm': shellHeightM == null ? null : shellHeightM! / 1000,
    'twilightKm': twilightM == null ? null : twilightM! / 1000,
  };
}

/// Raymarched planetary atmospheres (Nishita-style single scattering) —
/// the custom-shader equivalent of the Unreal HLSL atmosphere.
///
/// Each atmospheric body carries a shell sphere at the atmosphere top,
/// rendered as interior faces through [AtmosphereShaderMaterial] running
/// shaders/atmosphere.frag: the fragment reconstructs the camera ray,
/// intersects the shell and the (analytic) planet sphere, and integrates
/// Rayleigh scattering toward the sun. Entry distance clamps to zero in
/// the shader, so the surface transition is seamless.
///
/// Per-frame work is UNIFORMS ONLY (no geometry churn): planet centre,
/// radii, sun direction, coefficients.
class AtmosphereNodes {
  AtmosphereNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, _Shell> _shells = {};

  /// Art-pass styling per body id. Bodies with a domain atmosphere get a
  /// default entry on first sight; gas giants opt in via [AtmoStyle
  /// .shellHeightM] (their visible "atmosphere" is cloud deck + haze, not
  /// a thin gas skin the physical path could render). COLOUR comes from
  /// each body's gas composition (descriptor scatter tint, methane-potency
  /// weighted) — the only hand tint is Titan's, whose orange is
  /// photochemical tholin smog, not its N2 gas mix.
  static final Map<String, AtmoStyle> styles = {
    // Mars/Uranus/Neptune tints are keyed to their SURFACE TEXTURE colours
    // (art direction) rather than the composition-derived gas tint.
    'earth': AtmoStyle(heightScale: 4.0, falloff: 5.0, intensity: 14.0),
    'venus': AtmoStyle(falloff: 8.0, tintMix: 0.6),
    'mars': AtmoStyle(falloff: 8.0, tintArgb: 0xFFC97B4F, tintMix: 0.65),
    'titan': AtmoStyle(tintArgb: 0xFFCC7A33, tintMix: 0.85),
    // Giant densities look tiny but aren't: the synthetic shells are
    // hundreds of km thick, so vertical optical depth = density * beta *
    // (shell/10) — 0.04 on Jupiter's 2000 km shell matches Earth's haze.
    // Live-tuned via ext.acro.atmo (1.3-1.5 washed the discs to cream).
    'jupiter': AtmoStyle(shellHeightM: 2.0e6, heightScale: 3.0, falloff: 5.0, density: 0.04, tintMix: 0.8),
    'saturn': AtmoStyle(shellHeightM: 1.8e6, heightScale: 5, falloff: 1.0, density: 0.04, intensity: 10, tintMix: 0.8),
    'uranus': AtmoStyle(
      shellHeightM: 8.0e5,
      heightScale: 3.0,
      falloff: 2.0,
      density: 0.09,
      tintArgb: 0xFFA8D8DC,
      tintMix: 0.85,
    ),
    'neptune': AtmoStyle(
      shellHeightM: 8.0e5,
      heightScale: 3.0,
      falloff: 5.0,
      density: 0.07,
      tintArgb: 0xFF3D66E0,
      tintMix: 0.85,
    ),
  };

  /// Runtime kill switch for ALL shells — the debug panel's 'Atmo halo'
  /// layer toggle drives this for the 3D backend (the compile-time
  /// SCENE_NO_ATMO dart-define still exists for bisection).
  static bool hidden = false;

  /// The compiled atmosphere fragment shader, loaded once per app from the
  /// bundle the build hook produces. Null until [loadShader] completes
  /// (shells simply don't spawn until then).
  static Object? _shader;
  static Future<void>? _loading;

  static Future<void> loadShader() => _loading ??= () async {
    final library = await gpu.loadShaderLibraryAsync('build/shaderbundles/acro.shaderbundle');
    _shader = library?['AtmosphereFragment'];
    if (_shader == null) {
      throw StateError(
        'AtmosphereFragment missing from acro.shaderbundle — the '
        'hook/build.dart shader compile should have produced it.',
      );
    }
  }();

  void update(WorldSnapshot snap, FloatingOrigin origin, {Vector3 cameraEye = Vector3.zero, Vector3? starWorld}) {
    final shader = _shader;
    if (shader == null) return; // bundle still loading
    // Hidden: seen stays empty, so the removeWhere below strips every
    // live shell this frame.
    final seen = <String>{};
    final bodies =
        hidden ? const Iterable<BodySnapshot>.empty() : snap.bodies.values;
    for (final b in bodies) {
      final d = snap.descriptors[b.id];
      if (d == null || d.kind == BodyKind.star) continue;

      final hasPhysical = d.atmoPresent && d.atmoThickness > 0;
      var style = styles[b.id];
      if (style == null) {
        if (!hasPhysical) continue;
        style = styles[b.id] = AtmoStyle();
      }
      if (!style.enabled) continue;
      final thicknessM = hasPhysical ? d.atmoThickness : (style.shellHeightM ?? 0);
      if (thicknessM <= 0) continue;
      seen.add(b.id);

      final shell = _shells.putIfAbsent(b.id, () => _Shell(shader, _scene));

      final world = Vector3(b.px, b.py, b.pz);
      final rel = origin.worldToRel(world);
      final atmoTopM = b.radius + thicknessM * style.heightScale;

      // Camera inside the shell -> interior faces + depth ALWAYS (planet
      // occlusion is analytic; lessEqual would cull the disc). Outside ->
      // exterior faces + normal depth, so opaque geometry INSIDE the scene
      // (ring asteroids, vessels) correctly occludes/pokes through the
      // haze. Small hysteresis so the boundary doesn't flicker.
      final camDistM = (cameraEye - rel).length;
      shell.setInside(camDistM < atmoTopM * 1.02);

      shell.setTransforms(
        relToScene(rel),
        lengthToScene(atmoTopM),
        lengthToScene(b.radius),
      );

      final toSun = starWorld == null ? Vector3.unitX : (starWorld - world).normalized;
      // Scattering strength relative to Earth sea level, from the body's
      // REAL surface density unless the style overrides it. Clamped:
      // Venus' 65x must stay a translucent shroud, not a billiard ball.
      final baseDensity =
          style.density ??
          (d.atmoSeaLevelDensity > 0 ? (d.atmoSeaLevelDensity / 1.225).clamp(0.04, 4.0).toDouble() : 1.0);
      // Falloff invariance lives in the shader now: the density profile is
      // normalised by 1/falloff (params2.z), so stretching the scale
      // height grows the LIMB glow without thickening the nadir haze —
      // and the betas stay full strength (dividing them here collapsed
      // the halo brightness as falloff^1.5: no visible rim in space).
      final baseScaleHM = d.atmoScaleHeight > 0 ? d.atmoScaleHeight : thicknessM / 10.0;
      shell.updateUniforms(
        centreScene: relToScene(rel),
        planetRadiusScene: lengthToScene(b.radius),
        atmoTopScene: lengthToScene(atmoTopM),
        toSun: toSun,
        scaleHeightScene: lengthToScene(baseScaleHM * style.falloff),
        tintArgb: style.tintArgb ?? d.atmoScatterColorArgb,
        tintMix: style.tintMix,
        density: baseDensity,
        densityNorm: 1.0 / style.falloff,
        intensity: style.intensity,
        twilightScene: lengthToScene(style.twilightM ?? 0.12 * b.radius),
      );
    }

    _shells.removeWhere((id, shell) {
      if (seen.contains(id)) return false;
      shell.removeFrom(_scene);
      return true;
    });
  }
}

class _Shell {
  _Shell(Object shader, this._scene) {
    // The scatter integral only depends on the RAY (camera -> fragment
    // direction); the rasterized geometry just decides WHICH pixels get it
    // and at WHAT depth the depth test runs. All windings therefore share
    // the shader and depth-test lessEqual — an opaque craft in front of
    // the haze always wins. Camera outside: exterior shell faces. Camera
    // inside: the shell's interior faces sit BEHIND the planet, so alone
    // they'd lose the disc to the depth test — a surface-hugging proxy
    // sphere (just above the planet surface, correct depth) rasterizes the
    // disc pixels instead. (The old interior mode used depth ALWAYS, which
    // painted haze OVER the vessel while flying inside an atmosphere.)
    _inMaterial = AtmosphereShaderMaterial(fragmentShader: shader as gpu.Shader, depthAlways: false);
    _outMaterial = AtmosphereShaderMaterial(fragmentShader: shader, depthAlways: false);
    _surfMaterial = AtmosphereShaderMaterial(fragmentShader: shader, depthAlways: false);
    _inNode = fs.Node(mesh: fs.Mesh(uvSphereZUp(segments: 48, rings: 24, invert: true), _inMaterial));
    _outNode = fs.Node(mesh: fs.Mesh(uvSphereZUp(segments: 48, rings: 24), _outMaterial));
    _surfNode = fs.Node(mesh: fs.Mesh(uvSphereZUp(segments: 48, rings: 24), _surfMaterial));
    _scene.add(_outNode); // start outside
    _active = [_outNode];
  }

  final fs.Scene _scene;
  late final fs.Node _inNode, _outNode, _surfNode;
  late final AtmosphereShaderMaterial _inMaterial, _outMaterial, _surfMaterial;
  late List<fs.Node> _active;

  void setInside(bool inside) {
    // Inside: sky/limb pixels come from the shell's far interior wall,
    // disc pixels from the surface proxy (both lessEqual). Outside: the
    // exterior shell alone is depth-correct.
    final want = inside ? [_inNode, _surfNode] : [_outNode];
    if (want.length == _active.length && identical(want.first, _active.first)) {
      return;
    }
    for (final n in _active) {
      _scene.remove(n);
    }
    for (final n in want) {
      _scene.add(n);
    }
    _active = want;
  }

  /// Position/scale all windings for this frame. The shell nodes span the
  /// atmosphere top; the surface proxy hugs the planet just above the
  /// surface (0.02% up: below any terrain-scale feature, but in FRONT of
  /// the opaque sphere in the depth buffer so the disc haze survives the
  /// lessEqual test).
  void setTransforms(vm.Vector3 centreScene, double atmoTopScene, double planetRadiusScene) {
    final shellScale = vm.Matrix4.compose(centreScene, vm.Quaternion.identity(), vm.Vector3.all(atmoTopScene));
    _inNode.localTransform = shellScale;
    _outNode.localTransform = shellScale;
    _surfNode.localTransform = vm.Matrix4.compose(
      centreScene,
      vm.Quaternion.identity(),
      vm.Vector3.all(planetRadiusScene * 1.0002),
    );
  }

  void removeFrom(fs.Scene scene) {
    for (final n in _active) {
      scene.remove(n);
    }
  }

  // Physical Earth Rayleigh coefficients, per KILOMETRE (scene unit):
  // beta = (5.8e-3, 1.35e-2, 3.31e-2). Non-Earth hues come from the
  // style/descriptor tint mixed in the shader.
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
    double densityNorm = 1.0,
    double intensity = 22.0,
    double twilightScene = 0.0,
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
    _uniforms[12] = intensity;
    _uniforms[13] = hasTint ? (tintMix ?? 0.5) : 0.0;
    _uniforms[14] = hasTint ? ((tintArgb >> 16) & 0xff) / 255.0 : 0.0;
    _uniforms[15] = hasTint ? ((tintArgb >> 8) & 0xff) / 255.0 : 0.0;
    // vec4 params2: tint b, twilight softness (scene units), density norm
    _uniforms[16] = hasTint ? (tintArgb & 0xff) / 255.0 : 0.0;
    _uniforms[17] = twilightScene;
    _uniforms[18] = densityNorm;
    _uniforms[19] = 0.0;
    // All windings share the block; only the active set is in the scene.
    _inMaterial.setUniformBlockFromFloats('AtmosphereInfo', _uniforms);
    _outMaterial.setUniformBlockFromFloats('AtmosphereInfo', _uniforms);
    _surfMaterial.setUniformBlockFromFloats('AtmosphereInfo', _uniforms);
  }
}
