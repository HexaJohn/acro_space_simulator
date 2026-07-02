import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import '../flutter/texture_cache.dart';
import 'atmosphere_nodes.dart';
import 'body_nodes.dart';
import 'coord_convert.dart';
import 'line_nodes.dart';
import 'scene_textures.dart';
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
    _bodies = BodyNodes(scene, _textures);
    _skybox = SkyboxNode(scene, _textures);
    _vessels = VesselNodes(scene);
    _lines = LineNodes(scene);
    _atmospheres = AtmosphereNodes(scene);
  }

  final fs.Scene scene;
  final SceneTextures _textures;
  late final BodyNodes _bodies;
  late final SkyboxNode _skybox;
  late final VesselNodes _vessels;
  late final LineNodes _lines;
  late final AtmosphereNodes _atmospheres;

  final FloatingOrigin origin = FloatingOrigin();

  /// Reconcile the scene with this frame's snapshot. [focusVesselId] /
  /// [focusBodyId]: exactly one is non-null (the camera lock target); the
  /// floating origin follows it.
  void update(
    WorldSnapshot snap, {
    String? focusVesselId,
    String? focusBodyId,
  }) {
    origin.focusWorld = _focusWorld(snap, focusVesselId, focusBodyId);

    _bodies.update(snap, origin);
    _vessels.update(snap, origin);
    _lines.update(snap, origin);
    _atmospheres.update(snap, origin);
    _skybox.update();
    _updateSun(snap);
  }

  /// Rebuild the camera-facing line strips for this frame's camera + viewport.
  /// Call after [update], before rendering (PolylineGeometry contract).
  void updateForCamera(fs.Camera camera, ui.Size viewport) =>
      _lines.updateForCamera(camera, viewport);

  /// Sunlight: aims from the star through the focus. Bodies/vessels away
  /// from the star get lit on the star-facing side. Falls back to a fixed
  /// direction until the star is known (first descriptor frame).
  void _updateSun(WorldSnapshot snap) {
    final star = _bodies.starWorld(snap);
    final dir = star == null
        ? vm.Vector3(-1.0, -0.2, -0.1)
        : (() {
            final rel = origin.worldToRel(star);
            final len = rel.length;
            if (len < 1.0) return vm.Vector3(-1.0, -0.2, -0.1);
            // Light TRAVELS from the star toward the focus: -starDir.
            final d = rel / len;
            return vm.Vector3(-d.x, -d.y, -d.z);
          })();
    final light = scene.directionalLight;
    if (light == null) {
      scene.directionalLight =
          fs.DirectionalLight(direction: dir, intensity: 5.0);
    } else {
      light.direction = dir;
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
