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
    // LOCAL wind: noise-domain evolution rate. Weather MORPHS (forms and
    // dissipates in place) at this rate PER SIM-SECOND, so apparent motion
    // scales with the time-warp: gentle at 1x (realistic), a lively churn
    // at 50-100x. Old default (0.004) was a crawl below ~500x.
    this.wind = 0.015,
    // GLOBAL wind: eastward precession of the whole sample domain about the
    // spin axis (radians/sim-second) — the planet-scale advection that
    // carries weather systems across geography. Default preserves the old
    // hardwired drift of 1.5x the local wind.
    this.windGlobal = 0.0225,
    // Swirl: the domain warp that turns isotropic blobs into cyclonic
    // filaments. Strength is the warp drag (feature units), freq the warp
    // field's scale as a fraction of the base frequency (storm-system
    // scale), speed the scroll rate of the warp field's own domain — 0
    // keeps the arms frozen in the wind-carried domain (the old look),
    // higher values curl and reform the arms over time.
    this.swirlStrength = 5.0,
    this.swirlFreq = 0.28,
    this.swirlSpeed = 0.0,
    // Zonal wind bands: the global drift is multiplied by a latitude
    // profile of (1 - bandShear * equatorBump). Shear 0 keeps the drift
    // uniform (the old look); 1 stalls the equatorial band; >1 counter-
    // rotates it westward while the hemispheres run east (trade winds).
    // Width is the equatorial band's half-extent in radians of latitude.
    this.bandShear = 0.0,
    this.bandWidth = 0.35,
    // Ping-pong amplitude: radians of accumulated domain shear at the band
    // interface before the differential flow reverses. Bigger = longer
    // stretches with stronger distortion; smaller = gentler, quicker
    // oscillation.
    this.bandMaxShear = 1.2,
    // Coverage weather: the coverage knob becomes the MEAN of a slow
    // continent-scale noise field, so cloudiness itself varies by region
    // and evolves. Var 0 keeps coverage static (the old look); 1 swings
    // regions between fully clear and doubled. Freq is the field scale as
    // a fraction of the base noise frequency; speed its evolution rate.
    this.coverageVar = 0.0,
    this.coverageFreq = 0.15,
    this.coverageSpeed = 0.005,
    this.detail = 0.55,
    // Ambient is scattered SUNLIGHT — the shader gates it by day/night so the
    // night hemisphere stays dark; keep it low so the sun term (not flat fill)
    // shapes the clouds.
    this.ambient = 0.08,
    // Sun intensity must overcome the Henyey-Greenstein phase's 1/4pi
    // normalisation (~0.07 mid-lobe); ~16 lands lit clouds near white.
    this.intensity = 16.0,
    this.tintArgb = 0xFFF2F5FF,
    // Storm tint: dense samples blend from [tintArgb] toward this, so heavy
    // cores read grey-blue while thin wisps stay white. Mix 0 disables (the
    // single-tint look).
    this.tint2Argb = 0xFFB8C0D0,
    this.tintMix = 0.0,
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

  /// LOCAL wind: noise-domain scroll speed — weather morphing in place (the
  /// planet's own spin is handled separately by the orientation quaternion).
  double wind;

  /// GLOBAL wind: eastward precession of the sample domain about the spin
  /// axis (radians/sim-second) — planet-scale advection across geography.
  double windGlobal;

  /// Domain-warp drag in feature units — how hard the swirl field stretches
  /// blobs into cyclonic filaments.
  double swirlStrength;

  /// Warp field frequency as a fraction of the base noise frequency
  /// (storm-system scale).
  double swirlFreq;

  /// Scroll rate of the warp field's own domain — 0 freezes the arms in the
  /// wind-carried domain; higher values curl and reform them over time.
  double swirlSpeed;

  /// Zonal band shear: 0 = uniform global wind, 1 = equatorial band stalls,
  /// >1 = equator counter-flows westward while the hemispheres run east.
  double bandShear;

  /// Equatorial band half-extent, radians of latitude (profile blends over
  /// its outer half).
  double bandWidth;

  /// Ping-pong amplitude: accumulated interface shear (radians) before the
  /// differential band flow reverses direction.
  double bandMaxShear;

  /// Coverage-weather swing: 0 = static coverage, 1 = regions swing between
  /// fully clear and doubled coverage.
  double coverageVar;

  /// Coverage field scale, as a fraction of the base noise frequency
  /// (continent scale).
  double coverageFreq;

  /// Coverage field evolution rate (noise-domain scroll per sim-second).
  double coverageSpeed;

  /// Detail-erosion strength 0..1 — turns round blobs wispy at the edges.
  double detail;

  /// Ambient/sky fill on the shadowed side.
  double ambient;

  /// Sun scatter intensity.
  double intensity;

  /// Cloud tint (0xAARRGGBB, near-white); the alpha byte is ignored.
  int tintArgb;

  /// Storm tint (0xAARRGGBB) that dense cores blend toward; alpha ignored.
  int tint2Argb;

  /// Storm-tint blend strength 0..1; 0 keeps the single-tint look.
  double tintMix;

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
        'windGlobal': windGlobal,
        'swirlStrength': swirlStrength,
        'swirlFreq': swirlFreq,
        'swirlSpeed': swirlSpeed,
        'bandShear': bandShear,
        'bandWidth': bandWidth,
        'bandMaxShear': bandMaxShear,
        'coverageVar': coverageVar,
        'coverageFreq': coverageFreq,
        'coverageSpeed': coverageSpeed,
        'detail': detail,
        'ambient': ambient,
        'intensity': intensity,
        'tint': tintArgb.toRadixString(16),
        'tint2': tint2Argb.toRadixString(16),
        'tintMix': tintMix,
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
    // Tuned in CLOUDSCAPE 2026-08-14: deep 0-90 km shell, slow winds with
    // living swirl (speed 0.026) and full coverage weather, trade-wind band
    // shear past stall (1.26).
    'earth': CloudStyle(
      baseM: 40000,
      topM: 90000,
      coverage: 0.62,
      density: 0.4082,
      wind: 0.0001,
      windGlobal: 0.0001,
      swirlStrength: 4.5918,
      swirlFreq: 0.5832,
      swirlSpeed: 0.0263,
      bandShear: 1.2551,
      bandWidth: 0.4595,
      bandMaxShear: 0.4595,
      coverageVar: 1.0,
      coverageFreq: 0.1561,
      coverageSpeed: 0.05,
      detail: 0.55,
      ambient: 0.08,
      intensity: 16.0,
      tintArgb: 0xFFF2F5FF,
      tint2Argb: 0xFFB8C0D0,
      tintMix: 0.65,
      freq: 14.0,
    ),
    // Tuned in CLOUDSCAPE 2026-08-14: total sulfur overcast — coverage 1,
    // max swirl at full base frequency (the planet-wide V-chevron churn),
    // gentle wide bands, no coverage weather.
    'venus': CloudStyle(
      baseM: 48000,
      topM: 70000,
      coverage: 1.0,
      density: 2.8571,
      wind: 0.002,
      windGlobal: 0.003,
      swirlStrength: 10.0,
      swirlFreq: 1.0,
      swirlSpeed: 0.0003,
      bandShear: 0.2449,
      bandWidth: 0.8023,
      bandMaxShear: 0.5735,
      coverageVar: 0.0,
      coverageFreq: 0.3514,
      coverageSpeed: 0.0179,
      detail: 0.4286,
      ambient: 0.08,
      intensity: 16.0,
      tintArgb: 0xFFE8D8B0,
      tint2Argb: 0xFFB8C0D0,
      tintMix: 0.0,
      freq: 2.0,
    ),
    // Tuned in CLOUDSCAPE 2026-08-14: sparse methane wisps in a thin low
    // shell, heavily swirled, near-still global flow, frozen-in coverage
    // regions (var 1 at speed 0).
    'titan': CloudStyle(
      baseM: 4566,
      topM: 8719,
      coverage: 0.2653,
      density: 2.0408,
      wind: 0.0016,
      windGlobal: 0.0001,
      swirlStrength: 10.0,
      swirlFreq: 0.28,
      swirlSpeed: 0.0,
      bandShear: 0.0,
      bandWidth: 0.35,
      bandMaxShear: 1.2,
      coverageVar: 1.0,
      coverageFreq: 0.15,
      coverageSpeed: 0.0,
      detail: 0.4388,
      ambient: 0.08,
      intensity: 16.0,
      tintArgb: 0xFFD8A860,
      tint2Argb: 0xFFB8C0D0,
      tintMix: 0.0,
      freq: 10.5714,
    ),
    // Tuned in CLOUDSCAPE 2026-08-14: surface-hugging dust veil — huge
    // sparse systems (freq 2), no erosion, full coverage weather.
    'mars': CloudStyle(
      baseM: 0,
      topM: 16026,
      coverage: 0.398,
      density: 0.4082,
      wind: 0.006,
      windGlobal: 0.009,
      swirlStrength: 2.3469,
      swirlFreq: 0.4087,
      swirlSpeed: 0.0,
      bandShear: 0.0,
      bandWidth: 0.35,
      bandMaxShear: 1.2,
      coverageVar: 1.0,
      coverageFreq: 0.15,
      coverageSpeed: 0.005,
      detail: 0.0,
      ambient: 0.08,
      intensity: 16.0,
      tintArgb: 0xFFE8D0C0,
      tint2Argb: 0xFFB8C0D0,
      tintMix: 0.0,
      freq: 2.0,
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
        windGlobal: style.windGlobal,
        swirlStrength: style.swirlStrength,
        swirlFreq: style.swirlFreq,
        swirlSpeed: style.swirlSpeed,
        bandShear: style.bandShear,
        bandWidth: style.bandWidth,
        bandMaxShear: style.bandMaxShear,
        coverageVar: style.coverageVar,
        coverageFreq: style.coverageFreq,
        coverageSpeed: style.coverageSpeed,
        detail: style.detail,
        ambient: style.ambient,
        intensity: style.intensity,
        tintArgb: style.tintArgb,
        tint2Argb: style.tint2Argb,
        tintMix: style.tintMix,
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

  final Float32List _uniforms = Float32List(40); // 10 x vec4, std140

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
    required double windGlobal,
    required double swirlStrength,
    required double swirlFreq,
    required double swirlSpeed,
    required double bandShear,
    required double bandWidth,
    required double bandMaxShear,
    required double coverageVar,
    required double coverageFreq,
    required double coverageSpeed,
    required double detail,
    required double ambient,
    required double intensity,
    required int tintArgb,
    required int tint2Argb,
    required double tintMix,
    required double freq,
    required vm.Quaternion orient,
    // Editor-only field maps (see the shader's cov_info.w): 0 renders
    // clouds, 1..4 paint density/coverage/wind/swirl heatmaps. The sim
    // never passes this.
    double debugView = 0,
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
    // vec4 swirl_global: warp drag, warp frequency (x base freq), warp
    // domain scroll rate, global eastward wind (rad/sim-second).
    _uniforms[24] = swirlStrength;
    _uniforms[25] = swirlFreq;
    _uniforms[26] = swirlSpeed;
    _uniforms[27] = windGlobal;
    // vec4 band_info: zonal band shear + equatorial band half-width (rad).
    _uniforms[28] = bandShear;
    _uniforms[29] = bandWidth;
    _uniforms[30] = bandMaxShear;
    _uniforms[31] = 0;
    // vec4 cov_info: coverage-weather swing, field frequency (x base freq),
    // evolution rate.
    _uniforms[32] = coverageVar;
    _uniforms[33] = coverageFreq;
    _uniforms[34] = coverageSpeed;
    _uniforms[35] = debugView;
    // vec4 tint2_mix: storm tint rgb + blend strength.
    _uniforms[36] = ((tint2Argb >> 16) & 0xff) / 255.0;
    _uniforms[37] = ((tint2Argb >> 8) & 0xff) / 255.0;
    _uniforms[38] = (tint2Argb & 0xff) / 255.0;
    _uniforms[39] = tintMix;
    // All windings share the block; only the active set is in the scene.
    _inMaterial.setUniformBlockFromFloats('CloudInfo', _uniforms);
    _outMaterial.setUniformBlockFromFloats('CloudInfo', _uniforms);
    _surfMaterial.setUniformBlockFromFloats('CloudInfo', _uniforms);
  }
}

/// One cloud shell over a bare sphere for the CLOUDSCAPE editor — the cloud
/// sibling of the scatter lab's PropPreviewNodes. It drives the REAL
/// [_CloudShell] rig (same windings, same materials, same uniform packing),
/// so what the editor shows is exactly what the sim draws; only the world
/// plumbing (snapshot, floating origin, body orientation) is replaced by
/// direct values. The planet sits at the scene origin with identity
/// orientation, so the wind knob reads as pure noise-domain drift.
class CloudPreviewNodes {
  CloudPreviewNodes(this._scene);

  final fs.Scene _scene;
  _CloudShell? _shell;

  /// Positions the shell and pushes the style's uniforms. Safe to call every
  /// frame: a no-op while the shader bundle is still loading (the shell
  /// spawns on a later call) and while [style.enabled] is off.
  void update({
    required CloudStyle style,
    required double planetRadiusM,
    required double timeS,
    required Vector3 toSun,
    required vm.Vector3 cameraEyeScene,
    int debugView = 0,
  }) {
    final shader = CloudNodes._shader;
    if (shader == null) return;
    if (!style.enabled || style.topM <= style.baseM) {
      _shell?.removeFrom(_scene);
      _shell = null;
      return;
    }
    final shell = _shell ??= _CloudShell(shader, _scene);
    final planetScene = lengthToScene(planetRadiusM);
    final topScene = lengthToScene(planetRadiusM + style.topM);
    shell.setInside(cameraEyeScene.length < topScene * 1.02);
    shell.setTransforms(vm.Vector3.zero(), topScene, planetScene);
    shell.updateUniforms(
      centreScene: vm.Vector3.zero(),
      planetRadiusScene: planetScene,
      cloudTopScene: topScene,
      cloudBaseScene: lengthToScene(planetRadiusM + style.baseM),
      toSun: toSun,
      coverage: style.coverage,
      density: style.density,
      time: timeS,
      wind: style.wind,
      windGlobal: style.windGlobal,
      swirlStrength: style.swirlStrength,
      swirlFreq: style.swirlFreq,
      swirlSpeed: style.swirlSpeed,
      bandShear: style.bandShear,
      bandWidth: style.bandWidth,
      bandMaxShear: style.bandMaxShear,
      coverageVar: style.coverageVar,
      coverageFreq: style.coverageFreq,
      coverageSpeed: style.coverageSpeed,
      detail: style.detail,
      ambient: style.ambient,
      intensity: style.intensity,
      tintArgb: style.tintArgb,
      tint2Argb: style.tint2Argb,
      tintMix: style.tintMix,
      freq: style.freq,
      orient: vm.Quaternion.identity(),
      debugView: debugView.toDouble(),
    );
  }

  /// Pulls the shell out of the scene. Nodes/materials are dropped, not
  /// disposed — the same discipline as [CloudNodes.update]'s removeWhere
  /// (disposing GPU resources inline blanks the frame on web).
  void dispose() {
    _shell?.removeFrom(_scene);
    _shell = null;
  }
}
