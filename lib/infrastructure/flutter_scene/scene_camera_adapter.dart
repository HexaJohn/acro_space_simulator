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

  // DEPTH PRECISION: perspective depth quantization grows as d^2/near. A
  // fixed 1 m near plane with a system-scale far plane leaves a depth
  // quantum of ~10,000 km at a planet seen from orbit — planet-sized, so
  // the sphere's own far side z-fights through as angular black shards
  // that shift with every camera matrix change. Scale the near plane with
  // the eye distance instead. d/20 (not the earlier d/2000): the closest
  // content is essentially never inside a twentieth of the framed range,
  // and the 100x larger near buys 100x finer far-field depth — at freecam
  // ranges of a few hundred metres INSIDE Saturn's rings, d/2000 put the
  // near plane at 1 m and the planet+ring stack 100,000 km away shimmered
  // in depth-quantum flicker while flying. Floor 1 m.
  final eyeDistanceM = eye.length;
  final adaptiveNearM = SceneCameraDebug.nearOverrideM ??
      math.max(1.0, eyeDistanceM / 20.0);

  return fs.PerspectiveCamera(
    position: relToScene(eye),
    target: relToScene(eye * 0), // the focus == scene origin
    up: relToScene(cam.up * 1e3), // unit direction; scale cancels kRenderScale
    fovRadiansY: fovY,
    fovNear: lengthToScene(math.max(near, adaptiveNearM)),
    // Far plane: cover the whole system from anywhere (Neptune-ish scales,
    // ~5e12 m), and GROW with extreme zoom-outs so the sky sphere (which
    // tracks camera range) always fits inside it. The adaptive near plane
    // keeps the depth quantum proportional to the framed scale regardless.
    fovFar: lengthToScene(
        SceneCameraDebug.farOverrideM ?? math.max(5e12, eyeDistanceM * 40)),
  );
}

/// Debug overrides for the adaptive depth planes (metres) — set from the
/// `ext.acro.camera?near=..&far=..` dev extension to pin depth-precision
/// issues live; null = adaptive formula. Values also surface in the HUD
/// depth diagnostics line.
class SceneCameraDebug {
  static double? nearOverrideM;
  static double? farOverrideM;
}
