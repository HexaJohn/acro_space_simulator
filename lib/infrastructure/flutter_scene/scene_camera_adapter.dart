import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;

import '../../adapters/presenters/camera_view.dart';
import '../../adapters/presenters/perspective_camera.dart' as domain;
import 'coord_convert.dart';

/// Maps the app's camera model onto a flutter_scene camera.
///
/// The scene graph is focus-relative (floating origin at the camera target),
/// so the flutter_scene camera always LOOKS AT THE ORIGIN: its position is
/// the domain camera's [SceneCamera.eyeOffset] (already focus-relative,
/// metres) scaled to scene units, and its `up` comes straight from the
/// domain camera basis — which bakes in azimuth/elevation/roll. Because
/// flutter_scene accepts an arbitrary `up` vector, the scene keeps the
/// domain's right-handed Z-up frame end to end (see coord_convert.dart).
///
/// Ortho mode: flutter_scene 0.18 has no orthographic camera, and
/// [OrthoCamera.eyeOffset] is ZERO (parallel rays, no finite eye) — feeding
/// that through lookAt makes position == target and the view matrix
/// singular (`Matrix4.inverted` throws downstream, e.g. in polyline
/// expansion). The map view therefore renders as a long-lens perspective
/// approximation: the eye is synthesized at the distance where the
/// perspective scale at the focus equals the ortho metres-per-pixel. The
/// software renderer remains the canonical ortho map.
fs.PerspectiveCamera toSceneCamera(
  SceneCamera cam, {
  double viewportH = 800,
  double fallbackFovY = 50 * math.pi / 180,
}) {
  final fovY = cam is domain.PerspectiveCamera ? cam.fovY : fallbackFovY;
  final near = cam is domain.PerspectiveCamera ? cam.near : 1.0;

  var eye = cam.eyeOffset;
  if (cam is OrthoCamera || eye.length < 1.0) {
    // Perspective-equivalent distance: px-per-metre at the focus matches
    // the ortho scale (focal_px / d == 1 / mpp).
    final mpp = cam is OrthoCamera ? cam.metresPerPixel : 1.0;
    final focalPx = (viewportH / 2) / math.tan(fovY / 2);
    final d = math.max(focalPx * mpp, 10.0); // metres; floor avoids d ~ 0
    eye = cam.forward * -d;
  }

  return fs.PerspectiveCamera(
    position: relToScene(eye),
    target: relToScene(eye * 0), // the focus == scene origin
    up: relToScene(cam.up * 1e3), // unit direction; scale cancels kRenderScale
    fovRadiansY: fovY,
    fovNear: lengthToScene(near).clamp(1e-4, double.infinity),
    // Far plane: cover the whole system from anywhere (Neptune-ish scales,
    // ~5e12 m). Depth precision at that ratio is fine between BODIES (they
    // are astronomically separated); near-field layering (vessel vs terrain)
    // concentrates depth near the near plane. Verified visually in WS0/WS6.
    fovFar: lengthToScene(5e12),
  );
}
