import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import '../flutter/texture_cache.dart';
import 'atmosphere_nodes.dart';
import 'body_nodes.dart';
import 'coord_convert.dart';
import 'environment_baker.dart';
import 'exhaust_nodes.dart';
import 'line_nodes.dart';
import 'ring_nodes.dart';
import 'scene_textures.dart';
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
    _lines = LineNodes(scene);
    _atmospheres = AtmosphereNodes(scene);
    _rings = RingNodes(scene, _textures);
    _environment = PlanetEnvironmentBaker(scene, _textures);
    _terrain = TerrainNodes(scene);
  }

  final fs.Scene scene;
  final SceneTextures _textures;
  late final BodyNodes _bodies;
  late final SkyboxNode _skybox;
  late final VesselNodes _vessels;
  late final ExhaustNodes _exhaust;
  late final LineNodes _lines;
  late final AtmosphereNodes _atmospheres;
  late final RingNodes _rings;
  late final PlanetEnvironmentBaker _environment;
  late final TerrainNodes _terrain;

  final FloatingOrigin origin = FloatingOrigin();

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
  }) {
    origin.focusWorld =
        focusWorldOverride ?? _focusWorld(snap, focusVesselId, focusBodyId);

    _bodies.update(snap, origin);
    if (!_noVessels) {
      _vessels.update(snap, origin, starWorld: _bodies.starWorld(snap));
      _exhaust.update(snap, origin);
    }
    if (!_noLines) {
      _lines.update(snap, origin,
          camera: camera,
          viewport: viewport,
          focusVesselId: focusVesselId,
          focusBodyId: focusBodyId);
    }
    if (!_noAtmo) {
      _atmospheres.update(
        snap,
        origin,
        cameraEye: camera?.eyeOffset ?? Vector3.zero,
        starWorld: _bodies.starWorld(snap),
      );
    }
    _rings.update(snap, origin,
        camera: camera, starWorld: _bodies.starWorld(snap));
    _terrain.update(
      snap,
      origin,
      cameraEye: camera?.eyeOffset ?? Vector3.zero,
      focusBodyId: focusBodyId,
      focusVesselId: focusVesselId,
      starWorld: _bodies.starWorld(snap),
    );
    _skybox.update(
        cameraRangeKm:
            camera == null ? 0 : camera.eyeOffset.length * kRenderScale);
    _updateSun(snap);
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
  /// what's framed: looking at the focus body's NIGHT side brightens (up
  /// to ~3.2x, like eyes adjusting to the dark), and the sun entering the
  /// frame pulls it down (glare). scene.exposure eases toward the target
  /// with a ~0.8 s time constant so transitions read as adaptation, not
  /// flicker.
  static bool autoExposure = true;
  static double lastExposure = 1.0;
  DateTime? _lastExposureTick;

  void _updateExposure(WorldSnapshot snap, SceneCamera? camera,
      String? focusVesselId, String? focusBodyId) {
    if (camera == null) return;
    final star = _bodies.starWorld(snap);
    double target = 1.0;
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
    }
    final now = DateTime.now();
    final dt = _lastExposureTick == null
        ? 0.016
        : (now.difference(_lastExposureTick!).inMicroseconds / 1e6)
            .clamp(0.0, 0.25);
    _lastExposureTick = now;
    final k = 1.0 - math.exp(-dt / 0.8);
    scene.exposure += (target - scene.exposure) * k;
    lastExposure = scene.exposure;
  }

  static double _smooth01(double x) {
    final t = x.clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  // Layer kill switches for artifact bisection, e.g.
  //   flutter run ... --dart-define=SCENE_NO_LINES=true
  static const bool _noLines = bool.fromEnvironment('SCENE_NO_LINES');
  static const bool _noAtmo = bool.fromEnvironment('SCENE_NO_ATMO');
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
  void _updateSun(WorldSnapshot snap) {
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
    final light = scene.directionalLight;
    if (light == null) {
      scene.directionalLight =
          fs.DirectionalLight(direction: dir, intensity: _sunIntensity);
    } else {
      light.direction = dir;
      light.intensity = _sunIntensity;
    }
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
