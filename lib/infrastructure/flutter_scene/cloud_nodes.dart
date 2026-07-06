import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';
import 'sphere_geometry_util.dart';

/// Per-body art styling for the raymarched volumetric cloud layer.
///
/// Values here are RENDER-side only (no physics/aero side effects) and the
/// statics are mutable so dev tooling (`ext.acro.clouds` in main_scene_dev)
/// can tune a live scene during an art pass; bake the tuned numbers back
/// into [CloudNodes.styles] defaults afterwards.
///
/// Cloud layer heights are METRES above the surface. Unlike the atmosphere
/// (whose shell is a stretched glow canvas), the cloud shell is a real thin
/// annulus — the raymarch fills [baseM]..[topM] with procedural density.
class CloudStyle {
  CloudStyle({
    this.enabled = true,
    this.baseM = 2000,
    // Cloud tops are EXAGGERATED (~30 km vs Earth's ~12 km): a physically thin
    // shell over a 6371 km globe gives the raymarch almost no vertical depth,
    // so clouds read as a flat pasted-on texture with no self-shadow. A taller
    // shell gives the sun-march room to build volume (same trick the
    // atmosphere's heightScale uses).
    this.topM = 30000,
    this.coverage = 0.62,
    this.density = 9.0,
    // Noise-domain evolution rate. Weather MORPHS (forms/dissipates) and
    // drifts at this rate PER SIM-SECOND, so apparent motion scales with the
    // time-warp: gentle at 1x (realistic), a lively churn at 50-100x. Old
    // default (0.004) was a crawl below ~500x.
    this.wind = 0.015,
    this.detail = 0.55,
    // Ambient is scattered SUNLIGHT — the shader gates it by day/night so the
    // night hemisphere stays dark; keep it low so the sun term (not flat fill)
    // shapes the clouds.
    this.ambient = 0.08,
    // Sun intensity must overcome the Henyey-Greenstein phase's 1/4pi
    // normalisation (~0.07 mid-lobe); ~16 lands lit clouds near white.
    this.intensity = 16.0,
    this.tintArgb = 0xFFF2F5FF,
    this.freq = 14.0,
  });

  bool enabled;

  /// Cloud BASE height (metres above surface) — flat bottoms build up here.
  double baseM;

  /// Cloud TOP height (metres above surface) — the outer shell the ray
  /// enters; wispy tops thin out toward it.
  double topM;

  /// Cloud/clear split 0..1; higher covers more sky.
  double coverage;

  /// Optical thickness multiplier (how opaque a full column reads).
  double density;

  /// Noise-domain scroll speed (slow evolution + drift; the planet's own
  /// spin is handled separately by the orientation quaternion).
  double wind;

  /// Detail-erosion strength 0..1 — turns round blobs wispy at the edges.
  double detail;

  /// Ambient/sky fill on the shadowed side.
  double ambient;

  /// Sun scatter intensity.
  double intensity;

  /// Cloud tint (0xAARRGGBB, near-white); the alpha byte is ignored.
  int tintArgb;

  /// Base noise frequency (cycles per planet radius) — lower = bigger
  /// weather systems.
  double freq;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'baseKm': baseM / 1000,
        'topKm': topM / 1000,
        'coverage': coverage,
        'density': density,
        'wind': wind,
        'detail': detail,
        'ambient': ambient,
        'intensity': intensity,
        'tint': tintArgb.toRadixString(16),
        'freq': freq,
      };
}

/// Raymarched volumetric clouds in a thin spherical shell over a planet —
/// the sibling of [AtmosphereNodes], running shaders/clouds.frag.
///
/// Each cloud body carries a shell sphere at the cloud TOP radius. The
/// fragment reconstructs the camera ray, marches the annulus between the
/// cloud base and top radii, and accumulates a fully PROCEDURAL density
/// field (no sampler3D on this backend) with Beer/powder self-shadowing
/// toward the sun. The planet is an analytic occluder, so no depth buffer is
/// consulted for the layer's own shape.
///
/// Same in/out/surface-proxy depth rig as [AtmosphereNodes] (see _CloudShell):
/// exterior faces when the camera is above the deck, interior faces plus a
/// surface-hugging proxy when flying inside it. Per-frame work is UNIFORMS
/// ONLY (no geometry churn).
class CloudNodes {
  CloudNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, _CloudShell> _shells = {};

  /// Art-pass styling per body id. Clouds are OPT-IN per body (only ids in
  /// this map spawn a shell) — the density field is procedural, so there is
  /// no data-driven cloud map to key off. Bodies with a full cloud deck
  /// (Venus, Titan) run near-total coverage; Earth is broken cumulus; Mars
  /// is a thin high haze.
  static final Map<String, CloudStyle> styles = {
    'earth': CloudStyle(),
    'venus': CloudStyle(
      baseM: 48000,
      topM: 70000,
      coverage: 0.95,
      density: 26.0,
      wind: 0.002,
      detail: 0.25,
      freq: 6.0,
      tintArgb: 0xFFE8D8B0,
    ),
    'titan': CloudStyle(
      baseM: 10000,
      topM: 40000,
      coverage: 0.9,
      density: 18.0,
      wind: 0.0015,
      detail: 0.3,
      freq: 8.0,
      tintArgb: 0xFFD8A860,
    ),
    'mars': CloudStyle(
      baseM: 6000,
      topM: 22000,
      coverage: 0.22,
      density: 6.0,
      wind: 0.006,
      detail: 0.5,
      freq: 16.0,
      tintArgb: 0xFFE8D0C0,
    ),
  };

  /// Runtime kill switch for ALL cloud shells — the debug panel's 'Clouds'
  /// layer toggle drives this (the compile-time SCENE_NO_CLOUDS dart-define
  /// still exists for bisection).
  static bool hidden = false;

  /// The compiled cloud fragment shader, loaded once per app from the bundle
  /// the build hook produces. Null until [loadShader] completes (shells
  /// simply don't spawn until then).
  static Object? _shader;
  static Future<void>? _loading;

  static Future<void> loadShader() => _loading ??= () async {
        final library = await gpu
            .loadShaderLibraryAsync('build/shaderbundles/acro.shaderbundle');
        _shader = library?['CloudFragment'];
        if (_shader == null) {
          throw StateError(
            'CloudFragment missing from acro.shaderbundle — the '
            'hook/build.dart shader compile should have produced it.',
          );
        }
      }();

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    Vector3 cameraEye = Vector3.zero,
    Vector3? starWorld,
    double time = 0,
  }) {
    final shader = _shader;
    if (shader == null) return; // bundle still loading
    // Hidden: seen stays empty, so the removeWhere below strips every live
    // shell this frame.
    final seen = <String>{};
    final bodies =
        hidden ? const Iterable<BodySnapshot>.empty() : snap.bodies.values;
    for (final b in bodies) {
      final style = styles[b.id];
      if (style == null || !style.enabled) continue;
      final d = snap.descriptors[b.id];
      if (d != null && d.kind == BodyKind.star) continue;
      if (style.topM <= style.baseM) continue;
      seen.add(b.id);

      final shell = _shells.putIfAbsent(b.id, () => _CloudShell(shader, _scene));

      final world = Vector3(b.px, b.py, b.pz);
      final rel = origin.worldToRel(world);
      final cloudTopM = b.radius + style.topM;
      final cloudBaseM = b.radius + style.baseM;

      // Camera inside the deck -> interior faces + a surface proxy (the
      // interior far wall alone sits behind the planet and loses the disc to
      // lessEqual). Outside -> exterior faces. Small hysteresis so the
      // boundary doesn't flicker. Same rig as AtmosphereNodes.
      final camDistM = (cameraEye - rel).length;
      shell.setInside(camDistM < cloudTopM * 1.02);

      // Draw-order bias so the ATMOSPHERE haze composites OVER the clouds
      // (aerial perspective: clouds pick up the soft blue tint instead of
      // reading as harsh white). flutter_scene sorts translucency back-to-
      // front by the distance from the camera to each node's ORIGIN
      // (scene_encoder _depthOf). The cloud shell and the atmosphere shell
      // are BOTH centred on the planet, so their depths TIE and the order
      // resolves unstably — letting clouds paint on top. Nudge the cloud
      // shell's rasterization origin a hair (0.02% of camera distance)
      // FARTHER from the camera so it always sorts behind. The raymarch
      // reads the TRUE centre from the uniforms below, and the nudge shifts
      // the covering sphere sub-pixel, so cloud shape is unaffected.
      final meshRel =
          camDistM > 1.0 ? rel + (rel - cameraEye) * 2e-4 : rel;
      shell.setTransforms(
        relToScene(meshRel),
        lengthToScene(cloudTopM),
        lengthToScene(b.radius),
      );

      final toSun =
          starWorld == null ? Vector3.unitX : (starWorld - world).normalized;
      final orient = quatToScene(Quaternion(b.qw, b.qx, b.qy, b.qz));

      shell.updateUniforms(
        centreScene: relToScene(rel),
        planetRadiusScene: lengthToScene(b.radius),
        cloudTopScene: lengthToScene(cloudTopM),
        cloudBaseScene: lengthToScene(cloudBaseM),
        toSun: toSun,
        coverage: style.coverage,
        density: style.density,
        time: time,
        wind: style.wind,
        detail: style.detail,
        ambient: style.ambient,
        intensity: style.intensity,
        tintArgb: style.tintArgb,
        freq: style.freq,
        orient: orient,
      );
    }

    _shells.removeWhere((id, shell) {
      if (seen.contains(id)) return false;
      shell.removeFrom(_scene);
      return true;
    });
  }
}

class _CloudShell {
  _CloudShell(Object shader, this._scene) {
    // The march only depends on the RAY; the rasterized geometry just decides
    // WHICH pixels get it and at WHAT depth the depth test runs. All windings
    // share the shader and depth-test lessEqual — an opaque craft in front of
    // the clouds always wins. Camera outside: exterior shell faces. Camera
    // inside: the shell's interior faces sit BEHIND the planet, so alone
    // they'd lose the disc to the depth test — a surface-hugging proxy sphere
    // rasterizes the disc pixels at the correct depth instead. (Verbatim the
    // atmosphere shell's rig — see depth_materials + atmosphere_nodes.)
    _inMaterial = AtmosphereShaderMaterial(
        fragmentShader: shader as gpu.Shader, depthAlways: false);
    _outMaterial =
        AtmosphereShaderMaterial(fragmentShader: shader, depthAlways: false);
    _surfMaterial =
        AtmosphereShaderMaterial(fragmentShader: shader, depthAlways: false);
    _inNode = fs.Node(
        mesh: fs.Mesh(uvSphereZUp(segments: 48, rings: 24, invert: true),
            _inMaterial));
    _outNode =
        fs.Node(mesh: fs.Mesh(uvSphereZUp(segments: 48, rings: 24), _outMaterial));
    _surfNode = fs.Node(
        mesh: fs.Mesh(uvSphereZUp(segments: 48, rings: 24), _surfMaterial));
    _scene.add(_outNode); // start outside
    _active = [_outNode];
  }

  final fs.Scene _scene;
  late final fs.Node _inNode, _outNode, _surfNode;
  late final AtmosphereShaderMaterial _inMaterial, _outMaterial, _surfMaterial;
  late List<fs.Node> _active;

  void setInside(bool inside) {
    final want = inside ? [_inNode, _surfNode] : [_outNode];
    if (want.length == _active.length &&
        identical(want.first, _active.first)) {
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
  /// cloud top; the surface proxy hugs the planet just above the surface
  /// (0.02% up: in FRONT of the opaque sphere in the depth buffer so the
  /// disc clouds survive the lessEqual test when flying inside the deck).
  void setTransforms(
      vm.Vector3 centreScene, double cloudTopScene, double planetRadiusScene) {
    final shellScale = vm.Matrix4.compose(
        centreScene, vm.Quaternion.identity(), vm.Vector3.all(cloudTopScene));
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

  final Float32List _uniforms = Float32List(24); // 6 x vec4, std140

  void updateUniforms({
    required vm.Vector3 centreScene,
    required double planetRadiusScene,
    required double cloudTopScene,
    required double cloudBaseScene,
    required Vector3 toSun,
    required double coverage,
    required double density,
    required double time,
    required double wind,
    required double detail,
    required double ambient,
    required double intensity,
    required int tintArgb,
    required double freq,
    required vm.Quaternion orient,
  }) {
    // vec4 center_radius: planet centre + radius (analytic occluder).
    _uniforms[0] = centreScene.x;
    _uniforms[1] = centreScene.y;
    _uniforms[2] = centreScene.z;
    _uniforms[3] = planetRadiusScene;
    // vec4 sun_top: unit direction TOWARD the sun + cloud top radius.
    _uniforms[4] = toSun.x;
    _uniforms[5] = toSun.y;
    _uniforms[6] = toSun.z;
    _uniforms[7] = cloudTopScene;
    // vec4 base_cov_dens_t.
    _uniforms[8] = cloudBaseScene;
    _uniforms[9] = coverage;
    _uniforms[10] = density;
    _uniforms[11] = time;
    // vec4 wind_detail_amb_int.
    _uniforms[12] = wind;
    _uniforms[13] = detail;
    _uniforms[14] = ambient;
    _uniforms[15] = intensity;
    // vec4 tint_freq: near-white straight rgb + base frequency.
    _uniforms[16] = ((tintArgb >> 16) & 0xff) / 255.0;
    _uniforms[17] = ((tintArgb >> 8) & 0xff) / 255.0;
    _uniforms[18] = (tintArgb & 0xff) / 255.0;
    _uniforms[19] = freq;
    // vec4 orient: body orientation quaternion (vector_math x,y,z,w) — the
    // shader inverse-rotates each sample by this so the noise co-rotates
    // with the surface instead of swimming across it as the planet spins.
    _uniforms[20] = orient.x;
    _uniforms[21] = orient.y;
    _uniforms[22] = orient.z;
    _uniforms[23] = orient.w;
    // All windings share the block; only the active set is in the scene.
    _inMaterial.setUniformBlockFromFloats('CloudInfo', _uniforms);
    _outMaterial.setUniformBlockFromFloats('CloudInfo', _uniforms);
    _surfMaterial.setUniformBlockFromFloats('CloudInfo', _uniforms);
  }
}
