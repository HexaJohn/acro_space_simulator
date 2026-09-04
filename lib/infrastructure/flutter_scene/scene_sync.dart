// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/planner_overlay.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/terrain/terrain_lod.dart' show ViewCone;
import '../flutter/texture_cache.dart';
import 'atmosphere_nodes.dart';
import 'graphics_quality.dart';
import 'body_nodes.dart';
import 'cloud_nodes.dart';
import 'coord_convert.dart';
import 'environment_baker.dart';
import 'exhaust_nodes.dart';
import 'gravity_grid_nodes.dart';
import 'halo_ring_nodes.dart';
import 'impact_fx_nodes.dart';
import 'line_nodes.dart';
import 'planner_plane_nodes.dart';
import 'ring_nodes.dart';
import 'scene_textures.dart';
import 'star_bloom_nodes.dart';
import 'walker_nodes.dart';
import 'city/city_nodes.dart';
import 'scatter/scatter_nodes.dart';
import 'terrain/terrain_nodes.dart';
import 'vessel_nodes.dart';

/// Per-frame reconciliation of the flutter_scene graph against the
/// [WorldSnapshot] — the same 3D world feed the Unreal bridge serializes,
/// consumed in-process. Persistent nodes keyed by id: transforms update in
/// place; nodes are created/removed only when entities appear/vanish.
///
/// Owns the [FloatingOrigin]: the render origin follows the camera focus
/// (vessel or body) every frame, so all node transforms stay small and
/// float32-safe regardless of where in the system the camera is.
class SceneSync {
  SceneSync(this.scene, TextureCache textures, {void Function()? onTexture})
      : _textures = SceneTextures(textures, onReady: onTexture) {
    // Space is not a photo studio: the default image-based lighting
    // (environmentIntensity 1.0) washes every body in ambient white and
    // drowns the sun's terminator. A trace remains so night sides read as
    // dim spheres rather than voids.
    scene.environmentIntensity = 0.05;
    _bodies = BodyNodes(scene, _textures);
    _skybox = SkyboxNode(scene, _textures);
    _vessels = VesselNodes(scene);
    _exhaust = ExhaustNodes(scene);
    _impactFx = ImpactFxNodes(scene);
    _lines = LineNodes(scene);
    _plannerPlane = PlannerPlaneNodes(scene);
    _atmospheres = AtmosphereNodes(scene);
    _clouds = CloudNodes(scene);
    _rings = RingNodes(scene, _textures);
    _haloRings = HaloRingNodes(scene);
    _gravityGrid = GravityGridNodes(scene);
    _walker = WalkerNodes(scene);
    _environment = PlanetEnvironmentBaker(scene, _textures);
    _terrain = TerrainNodes(scene);
    _scatter = ScatterNodes(scene);
    _city = CityNodes(scene);
    _starBloom = StarBloomNodes(scene);
  }

  final fs.Scene scene;
  final SceneTextures _textures;
  late final BodyNodes _bodies;
  late final SkyboxNode _skybox;
  late final VesselNodes _vessels;
  late final ExhaustNodes _exhaust;
  late final ImpactFxNodes _impactFx;
  late final LineNodes _lines;
  late final PlannerPlaneNodes _plannerPlane;
  late final AtmosphereNodes _atmospheres;
  late final CloudNodes _clouds;
  late final RingNodes _rings;
  late final HaloRingNodes _haloRings;
  late final GravityGridNodes _gravityGrid;
  late final WalkerNodes _walker;
  late final PlanetEnvironmentBaker _environment;
  late final TerrainNodes _terrain;
  late final ScatterNodes _scatter;
  late final CityNodes _city;
  late final StarBloomNodes _starBloom;

  final FloatingOrigin origin = FloatingOrigin();

  /// This frame's cost per [update] stage (the same boundaries `mark` below
  /// already named for the >300ms console alert), in ms — readable by a perf
  /// overlay so a flight-session slowdown is attributable to a subsystem the
  /// same way the terrain studio's panel already is, without a DevTools
  /// trace. One instance per app, so static is fine (matches
  /// [autoExposure]/[lastExposure] and the rest of this class's read-from-
  /// anywhere statics).
  static final Map<String, double> stageMs = {};

  /// Scene graph census — draw calls, instances, node count — refreshed
  /// every [_censusEveryFrames] calls to [update] rather than every one:
  /// walking the whole graph is cheap but not free, and this is a diagnostic
  /// reading, not something anything renders against.
  static int censusDraws = 0, censusInstances = 0, censusNodes = 0;
  static const int _censusEveryFrames = 30;
  int _censusCountdown = 0;

  /// Reconcile the scene with this frame's snapshot. [focusVesselId] /
  /// [focusBodyId]: exactly one is non-null (the camera lock target); the
  /// floating origin follows it. [camera]/[viewport] drive apparent-size
  /// culling (distant orbit rails are skipped until zoomed way out).
  void update(
    WorldSnapshot snap, {
    SceneCamera? camera,
    ui.Size? viewport,
    String? focusVesselId,
    String? focusBodyId,
    Vector3? focusWorldOverride,
    PlannerOverlay? planner,
  }) {
    origin.focusWorld =
        focusWorldOverride ?? _focusWorld(snap, focusVesselId, focusBodyId);

    // Stage timing: recorded into [stageMs] every frame for the perf
    // overlay; a stage burning >300ms of the UI thread in one frame is ALSO
    // named in the console, so a load-time stall is attributable to a
    // subsystem without a DevTools trace even when nobody has the overlay
    // open.
    final sw = Stopwatch()..start();
    var lastUs = 0;
    void mark(String stage) {
      final nowUs = sw.elapsedMicroseconds;
      final ms = (nowUs - lastUs) / 1000.0;
      stageMs[stage] = ms;
      if (ms > 300) debugPrint('sceneSync: $stage ${ms.toStringAsFixed(0)}ms');
      lastUs = nowUs;
    }

    // Terrain's active body is last frame's (terrain syncs below); it only
    // changes on a focus switch, so the one-frame lag is harmless.
    _bodies.update(snap, origin, terrainBodyId: _terrain.activeBodyId);
    mark('bodies');
    if (!_noVessels) {
      _vessels.update(snap, origin, starWorld: _bodies.starWorld(snap));
      _exhaust.update(snap, origin);
    }
    // Terrain-impact dust/debris. Outside the vessel kill-switch: the effect
    // belongs to the ground, and its trigger vessel is already gone.
    _impactFx.update(snap, origin);
    mark('vessels');
    if (!_noLines) {
      _lines.update(snap, origin,
          camera: camera,
          viewport: viewport,
          focusVesselId: focusVesselId,
          focusBodyId: focusBodyId,
          planner: planner);
    }
    _plannerPlane.update(snap, origin, planner);
    mark('lines');
    if (!_noAtmo) {
      _atmospheres.update(
        snap,
        origin,
        cameraEye: camera?.eyeOffset ?? Vector3.zero,
        starWorld: _bodies.starWorld(snap),
      );
    }
    if (!_noClouds) {
      _clouds.update(
        snap,
        origin,
        cameraEye: camera?.eyeOffset ?? Vector3.zero,
        starWorld: _bodies.starWorld(snap),
        time: snap.epoch,
      );
    }
    _rings.update(snap, origin,
        camera: camera, starWorld: _bodies.starWorld(snap));
    // Megastructures: halo rings under construction (stage visuals + voxel
    // terrain cells near the camera).
    _haloRings.update(snap, origin, cameraEye: camera?.eyeOffset);
    // One sheet, under the body you're actually at — see GravityGridNodes.
    _gravityGrid.update(snap, origin,
        camera: camera,
        viewport: viewport,
        focusVesselId: focusVesselId,
        focusBodyId: focusBodyId);
    // The walker's own body. View state, not snapshot state — the static
    // fields are written by SimulationView the same frame it moves the anchor.
    _walker.update();
    mark('atmo+rings');
    // View culling (Options > Graphics quality): the camera's view cone,
    // from its pixel budget and the viewport. Perspective only — an ortho
    // camera has parallel rays and a placeholder focal length.
    final viewCone = GraphicsQuality.terrainFrustumCull &&
            camera != null &&
            camera.usesDistanceCull &&
            viewport != null &&
            viewport.height > 0 &&
            camera.focalPx > 0
        ? ViewCone.forViewport(
            forward: camera.forward,
            focalPx: camera.focalPx,
            widthPx: viewport.width,
            heightPx: viewport.height,
            marginRad: TerrainNodes.frustumMarginRad,
          )
        : null;
    _terrain.update(
      snap,
      origin,
      cameraEye: camera?.eyeOffset ?? Vector3.zero,
      camera: camera,
      viewCone: viewCone,
      focusBodyId: focusBodyId,
      focusVesselId: focusVesselId,
      starWorld: _bodies.starWorld(snap),
    );
    mark('terrain');
    // Immediately after terrain, and from the same inputs: props stand on the
    // ground the chunk above just meshed, so anything that changes one has to
    // reach the other in the same frame.
    _scatter.update(
      snap,
      origin,
      cameraEye: camera?.eyeOffset ?? Vector3.zero,
      camera: camera,
      focusBodyId: focusBodyId,
      focusVesselId: focusVesselId,
    );
    mark('scatter');
    // Colonies stand on the same ground the terrain and scatter passes just
    // built, so they belong in the same group — a city placed against last
    // frame's relief would visibly float after a chunk swap.
    _city.update(snap, origin, focusWorld: origin.focusWorld);
    mark('city');
    _skybox.update(
        cameraRangeKm:
            camera == null ? 0 : camera.eyeOffset.length * kRenderScale);
    // Occlusion is the depth buffer's job, not this call's position: the sprite
    // is translucent, so the engine draws it after every opaque record and the
    // terrain/vessel/body depth it tests against is already laid down.
    _starBloom.update(snap, origin, _bodies,
        camera: camera, viewport: viewport);
    _updateSun(snap, camera, focusVesselId, focusBodyId);
    _updateExposure(snap, camera, focusVesselId, focusBodyId);
    if (camera != null) {
      _environment.update(
        snap,
        eyeWorld: origin.focusWorld + camera.eyeOffset,
        focusBodyId: focusBodyId,
        focusVesselId: focusVesselId,
        starWorld: _bodies.starWorld(snap),
      );
    }
    _applyAa();
    mark('tail');
    _census();
  }

  void _census() {
    if (++_censusCountdown < _censusEveryFrames) return;
    _censusCountdown = 0;
    censusDraws = 0;
    censusInstances = 0;
    censusNodes = 0;
    _censusWalk(scene.root);
  }

  void _censusWalk(fs.Node n) {
    censusNodes++;
    for (final c in n.getComponents<fs.MeshComponent>()) {
      censusDraws += c.mesh.primitives.length;
    }
    for (final c in n.getComponents<fs.InstancedMeshComponent>()) {
      censusDraws += 1;
      censusInstances += c.instancedMesh.instanceCount;
    }
    for (final child in n.children) {
      _censusWalk(child);
    }
  }

  /// Anti-aliasing override (null = the engine's auto: MSAA where the
  /// backend supports offscreen MSAA, FXAA otherwise). Set from
  /// `ext.acro.camera?aa=msaa|fxaa|auto`; the HUD depth line reports what
  /// actually runs.
  static fs.AntiAliasingMode? aaRequest;
  static String effectiveAa = '?';

  void _applyAa() {
    final req = aaRequest;
    if (req != null && scene.antiAliasingMode != req) {
      scene.antiAliasingMode = req;
    }
    effectiveAa = scene.effectiveAntiAliasingMode.name;
  }

  /// Adaptive exposure — heuristic eye adaptation, no GPU luminance pass
  /// available (no compute on this stack). Target exposure derives from
  /// what's framed: looking at the focus body's NIGHT side brightens (like
  /// eyes adjusting to the dark), and the sun entering the frame pulls it
  /// down (glare). scene.exposure eases toward the target so transitions
  /// read as adaptation, not flicker.
  ///
  /// Every knob is a static so the debug panel and `ext.acro.camera` can
  /// drive it live. With [autoExposure] off, [manualExposure] becomes the
  /// target (still eased — a slider drag reads as adaptation, not a cut).
  static bool autoExposure = true;
  static double manualExposure = 1.0;

  /// Clamp on the AUTO target. Defaults bracket exactly what the heuristic
  /// could already produce (glare floor 1.0*0.55, night ceiling 1.0+2.2), so
  /// stock behaviour is unchanged; tightening them tames the adaptation.
  static double minExposure = 0.55;
  static double maxExposure = 3.2;

  /// Ease time constants (s). Brightening (walking into shadow) and
  /// darkening (sun swinging into frame) are separately tunable — real eyes
  /// dark-adapt far slower than they glare-adapt.
  static double adaptUpS = 0.8;
  static double adaptDownS = 0.8;

  /// Readouts: the eased exposure actually applied this frame, and the
  /// target it is chasing.
  static double lastExposure = 1.0;
  static double lastTarget = 1.0;
  DateTime? _lastExposureTick;

  void _updateExposure(WorldSnapshot snap, SceneCamera? camera,
      String? focusVesselId, String? focusBodyId) {
    if (camera == null) return;
    final star = _bodies.starWorld(snap);
    double target = autoExposure ? 1.0 : manualExposure;
    if (autoExposure && star != null) {
      final bodyId = focusBodyId ??
          (focusVesselId == null ? null : snap.vessels[focusVesselId]?.body);
      final b = bodyId == null ? null : snap.bodies[bodyId];
      final eyeWorld = origin.focusWorld + camera.eyeOffset;
      if (b != null && b.id != 'sun') {
        final bodyWorld = Vector3(b.px, b.py, b.pz);
        final toSun = (star - bodyWorld).normalized;
        final toCam = (eyeWorld - bodyWorld).normalized;
        // 1 = fully lit face toward the camera, 0 = looking at midnight.
        final litness = 0.5 + 0.5 * toSun.dot(toCam);
        target = 1.0 + 2.2 * (1.0 - _smooth01(litness / 0.35));
      }
      // Sun glare: the sun inside ~45 degrees of the view axis dims the
      // frame toward 55%.
      final sunDir = (star - eyeWorld).normalized;
      final glare = _smooth01((camera.forward.dot(sunDir) - 0.7) / 0.25);
      target *= 1.0 - 0.45 * glare;
      target = target.clamp(minExposure, maxExposure);
    }
    final now = DateTime.now();
    final dt = _lastExposureTick == null
        ? 0.016
        : (now.difference(_lastExposureTick!).inMicroseconds / 1e6)
            .clamp(0.0, 0.25);
    _lastExposureTick = now;
    final tau = target > scene.exposure ? adaptUpS : adaptDownS;
    final k = 1.0 - math.exp(-dt / math.max(0.01, tau));
    scene.exposure += (target - scene.exposure) * k;
    lastExposure = scene.exposure;
    lastTarget = target;
  }

  static double _smooth01(double x) {
    final t = x.clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  // Layer kill switches for artifact bisection, e.g.
  //   flutter run ... --dart-define=SCENE_NO_LINES=true
  static const bool _noLines = bool.fromEnvironment('SCENE_NO_LINES');
  static const bool _noAtmo = bool.fromEnvironment('SCENE_NO_ATMO');
  static const bool _noClouds = bool.fromEnvironment('SCENE_NO_CLOUDS');
  static const bool _noVessels = bool.fromEnvironment('SCENE_NO_VESSELS');

  /// Rebuild the camera-facing line strips for this frame's camera + viewport
  /// (copy-on-write; skips when camera, viewport, and content are unchanged).
  void updateForCamera(fs.PerspectiveCamera camera, ui.Size viewport) =>
      _lines.updateForCamera(camera, viewport);

  /// Intensity tuned against the tonemapper: 5.0 blows the lit hemisphere
  /// out to white (oceans wash pale); ~2.2 keeps the albedo readable across
  /// the disc like the software renderer.
  static const double _sunIntensity = 2.2;

  /// Sunlight: aims from the star through the focus. Bodies/vessels away
  /// from the star get lit on the star-facing side. Falls back to a fixed
  /// direction until the star is known (first descriptor frame). The GLOBAL
  /// light stays full strength — craft eclipse is applied per-vessel in
  /// [VesselNodes] so it never dims other bodies.
  void _updateSun(WorldSnapshot snap, SceneCamera? camera,
      String? focusVesselId, String? focusBodyId) {
    final star = _bodies.starWorld(snap);
    final dir = star == null
        ? vm.Vector3(-1.0, -0.2, -0.1)
        : (() {
            final rel = origin.worldToRel(star);
            final len = rel.length;
            if (len < 1.0) return vm.Vector3(-1.0, -0.2, -0.1);
            // Light TRAVELS from the star toward the focus (-starDir), per
            // the DirectionalLight docs. Verified against the software
            // renderer's terminator top-down A/B WITH the ambient IBL
            // killed — with it at full strength the terminator is invisible
            // and the sign cannot be judged (a first attempt inverted this
            // based on exactly that mistake).
            final d = rel / len;
            return vm.Vector3(-d.x, -d.y, -d.z);
          })();
    var light = scene.directionalLight;
    if (light == null) {
      light = fs.DirectionalLight(direction: dir, intensity: _sunIntensity);
      scene.directionalLight = light;
    } else {
      light.direction = dir;
      light.intensity = _sunIntensity;
    }
    _tuneShadows(light, snap, camera, focusVesselId, focusBodyId);
  }

  /// Highest eye-altitude (m above the datum) at which the directional light
  /// casts shadows. Above it there is no terrain to receive them and the craft
  /// is a sub-pixel speck, so the shadow pass is pure cost — skip it.
  static const double _shadowMaxAltM = 8000;

  /// Enable + scale the cascaded shadow map for the landing use-case. The sim
  /// renders in kilometres with metre-scale craft, so the engine's default
  /// world-unit shadow distances (150 u = 150 km) would smear a 15 m craft
  /// across one texel. Tie the cascade reach to eye altitude so a low craft
  /// casts a tight, crisp shadow; disable entirely away from a terrain surface.
  /// Dev kill switch for the cast-shadow pass (`ext.acro.camera?shadows=off`),
  /// for A/B comparison. Production leaves it on.
  static bool shadowsEnabled = true;

  void _tuneShadows(fs.DirectionalLight light, WorldSnapshot snap,
      SceneCamera? camera, String? focusVesselId, String? focusBodyId) {
    final bodyId = focusBodyId ??
        (focusVesselId == null ? null : snap.vessels[focusVesselId]?.body);
    final b = bodyId == null ? null : snap.bodies[bodyId];
    final d = bodyId == null ? null : snap.descriptors[bodyId];
    if (!shadowsEnabled ||
        camera == null ||
        b == null ||
        d == null ||
        !d.hasTerrain) {
      light.castsShadow = false;
      return;
    }
    final bodyWorld = Vector3(b.px, b.py, b.pz);
    final eyeWorld = origin.focusWorld + camera.eyeOffset;
    final altM = (eyeWorld - bodyWorld).length - b.radius;
    if (altM > _shadowMaxAltM) {
      light.castsShadow = false;
      return;
    }
    light.castsShadow = true;
    // Second-depth casting: solid, watertight voxel terrain + craft, so record
    // the far face and let the offset hide inside the solid (no grazing acne).
    light.shadowCasterFaces = fs.ShadowCasterFaces.back;
    // Cascades reach a few craft-heights out, growing with altitude; clamped so
    // a landed craft still shadows ~300 m of ground and a descent stays covered.
    final rangeM = (altM * 3.0 + 300.0).clamp(300.0, 6000.0);
    light.shadowMaxDistance = lengthToScene(rangeM);
    light.shadowFadeRange = lengthToScene(rangeM * 0.12);
    // Doubled off the engine's 1024 default: a landed craft's near cascade spans
    // ~30 m, so 2048 buys ~1.5 cm/texel — fine enough that the sun's true (few
    // cm) penumbra resolves as an edge instead of a filtered smear.
    light.shadowMapResolution = 2048;
    // Softness does double duty: the far-penumbra cap (scaled by
    // TerrainNodes.maxPenumbraFactor) AND the grazing-angle normal-offset bias
    // (sp0.z). Hold it at 1.5 m — the penumbra is cut via hardness, so dropping
    // this would only starve the bias and bring acne back.
    light.shadowSoftness = lengthToScene(1.5);
    light.shadowNormalBias = lengthToScene(1.0);
    light.shadowDepthBias = lengthToScene(1.0);
  }

  Vector3 _focusWorld(
      WorldSnapshot snap, String? vesselId, String? bodyId) {
    if (vesselId != null) {
      final v = snap.vessels[vesselId];
      if (v != null) {
        final b = snap.bodies[v.body];
        if (b != null) {
          return Vector3(b.px + v.px, b.py + v.py, b.pz + v.pz);
        }
        return Vector3(v.px, v.py, v.pz);
      }
    }
    if (bodyId != null) {
      final b = snap.bodies[bodyId];
      if (b != null) return Vector3(b.px, b.py, b.pz);
    }
    return origin.focusWorld; // keep last focus rather than jumping to root
  }
}
