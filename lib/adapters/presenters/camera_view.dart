import 'dart:math' as math;

import '../../domain/shared/vector3.dart';

/// A free-orbit camera around the focus point, defined by two angles. The render
/// is an orthographic projection of world positions onto the camera's screen
/// plane; the camera can be spun (azimuth) and tilted (elevation) freely with
/// the arrow keys, and the [CameraView] presets just snap these angles.
///
/// World frame: X/Y are the ecliptic plane, +Z is up (out of the ecliptic).
/// - azimuth: rotation about +Z (heading). 0 looks along −Y toward +Y up.
/// - elevation: tilt above the ecliptic. +pi/2 = straight down (top view).
class CameraOrbit {
  final double azimuth;
  final double elevation;
  final double roll; // rotation of the screen about the view axis
  const CameraOrbit(
      {this.azimuth = 0, this.elevation = math.pi / 2, this.roll = 0});

  /// Top-down default.
  static const CameraOrbit top = CameraOrbit(azimuth: 0, elevation: math.pi / 2);

  CameraOrbit copyWith({double? azimuth, double? elevation, double? roll}) =>
      CameraOrbit(
        azimuth: azimuth ?? this.azimuth,
        elevation: (elevation ?? this.elevation)
            .clamp(-math.pi / 2 + 0.01, math.pi / 2 - 0.01),
        roll: roll ?? this.roll,
      );

  /// Snap to one of the named presets.
  factory CameraOrbit.preset(CameraView v) {
    switch (v) {
      case CameraView.top:
        return const CameraOrbit(azimuth: 0, elevation: math.pi / 2);
      case CameraView.threeQuarter:
        return const CameraOrbit(azimuth: math.pi / 4, elevation: math.pi / 6);
    }
  }

  /// Whichever preset this orbit is closest to (for the gizmo label).
  CameraView get nearestPreset {
    var best = CameraView.top;
    var bestD = double.infinity;
    for (final v in CameraView.values) {
      final p = CameraOrbit.preset(v);
      final d = (p.azimuth - azimuth).abs() + (p.elevation - elevation).abs();
      if (d < bestD) {
        bestD = d;
        best = v;
      }
    }
    return best;
  }

  /// Roughly top-down (so depth-culling can be skipped — everything's in plane).
  bool get isTopish => elevation > math.pi / 2 - 0.05;

  // --- Camera basis in world space (public for the sphere renderer) ---
  // forward (into screen): points from camera toward the focus.
  // right (screen +x), up (screen +y).
  Vector3 get forward => _forward;
  Vector3 get right => _right;
  Vector3 get up => _up;

  Vector3 get _forward {
    final ce = math.cos(elevation), se = math.sin(elevation);
    final ca = math.cos(azimuth), sa = math.sin(azimuth);
    // At elevation 0, azimuth 0: forward = +Y (camera south of target looking N).
    return Vector3(ce * sa, ce * ca, -se);
  }

  // Base (un-rolled) horizontal right + up, then rolled about the view axis.
  Vector3 get _rightBase {
    final ca = math.cos(azimuth), sa = math.sin(azimuth);
    return Vector3(ca, -sa, 0); // horizontal, perpendicular to forward heading
  }

  Vector3 get _upBase => _rightBase.cross(_forward).normalized;

  Vector3 get _right {
    if (roll == 0) return _rightBase;
    final cr = math.cos(roll), sr = math.sin(roll);
    return (_rightBase * cr + _upBase * sr).normalized;
  }

  Vector3 get _up {
    if (roll == 0) return _upBase;
    final cr = math.cos(roll), sr = math.sin(roll);
    return (_upBase * cr - _rightBase * sr).normalized;
  }

  /// Project a world-frame position to screen (x: right, y: up). The painter
  /// flips Y for Flutter's downward axis.
  ({double x, double y}) project(Vector3 world) =>
      (x: world.dot(_right), y: world.dot(_up));

  /// Depth of a world position along the view direction (how far behind/in front
  /// of the focus plane). Used for distance-culling in tilted views.
  double depth(Vector3 world) => world.dot(_forward);
}

/// Named camera presets surfaced by the view gizmo. Backed by [CameraOrbit].
/// Only TOP and 3/4 — front/side are edge-on and useless in ortho; tilted
/// framing is the perspective camera's job.
enum CameraView {
  top,
  threeQuarter;

  String get label => switch (this) {
        CameraView.top => 'TOP',
        CameraView.threeQuarter => '3/4',
      };

  CameraView get next => CameraView.values[(index + 1) % CameraView.values.length];
}

/// A camera that projects target-relative WORLD positions (metres) to SCREEN
/// PIXELS (centre-origin, +x right, +y up; the painter flips Y for Flutter's
/// downward axis). Owns the metres->pixels mapping so the painter never divides
/// by metres-per-pixel — ortho and perspective differ only inside the camera.
abstract class SceneCamera {
  Vector3 get forward; // into the screen (eye -> target)
  Vector3 get right;
  Vector3 get up;
  double get azimuth; // orientation (skybox window + chase math)
  double get elevation;

  /// Target-relative world point -> screen px. Null when culled (behind the
  /// near plane); ortho never culls.
  ({double x, double y})? projectPx(Vector3 rel);

  /// On-screen radius (px) of a sphere of [radiusM] metres at [rel].
  double radiusPx(Vector3 rel, double radiusM);

  /// Depth along the view axis (front/back occlusion ordering). Bigger = farther.
  double depth(Vector3 rel);

  /// Unit direction from the eye toward a target-relative point. Ortho = forward
  /// (parallel rays); perspective = the actual eye->point ray, so the sphere
  /// renderer can map the visible hemisphere from the right angle (no texture
  /// sliding for off-axis bodies).
  Vector3 viewDirTo(Vector3 rel);

  /// The EYE position relative to the target/focus, in world metres. Perspective:
  /// pulled back along -forward by the range. Ortho: a finite eye is undefined
  /// (parallel rays), so it returns zero — callers gate eye-dependent effects
  /// (e.g. the near-surface horizon) on [usesDistanceCull] being false.
  Vector3 get eyeOffset;

  /// Skip the tilted-view distance cull when ~top-down (everything's in plane).
  bool get isTopish;

  /// Whether the presenter's tilted-view distance cull (hide everything but the
  /// active body + its moons when the active body is small on screen) applies.
  /// True for ortho — at a zoomed-out map scale distant planets swamp the frame
  /// and must be culled. False for perspective — it already shrinks distant
  /// bodies by distance and culls behind-eye points at the near plane, so the
  /// active-radius heuristic only wrongly hides the rest of the system.
  bool get usesDistanceCull;
}

/// Orthographic camera: the original flat map projection. Wraps a [CameraOrbit]
/// for orientation and a constant metres-per-pixel scale. Reproduces the legacy
/// behaviour exactly; never culls behind the camera.
class OrthoCamera implements SceneCamera {
  final CameraOrbit orbit;
  final double metresPerPixel;
  const OrthoCamera(this.orbit, this.metresPerPixel);

  @override
  Vector3 get forward => orbit.forward;
  @override
  Vector3 get right => orbit.right;
  @override
  Vector3 get up => orbit.up;
  @override
  double get azimuth => orbit.azimuth;
  @override
  double get elevation => orbit.elevation;

  @override
  ({double x, double y})? projectPx(Vector3 rel) =>
      (x: rel.dot(orbit.right) / metresPerPixel, y: rel.dot(orbit.up) / metresPerPixel);

  @override
  double radiusPx(Vector3 rel, double radiusM) => radiusM / metresPerPixel;

  @override
  double depth(Vector3 rel) => rel.dot(orbit.forward);

  @override
  Vector3 viewDirTo(Vector3 rel) => orbit.forward; // parallel rays

  @override
  Vector3 get eyeOffset => Vector3.zero; // no finite eye (parallel rays)

  @override
  bool get isTopish => orbit.isTopish;

  @override
  bool get usesDistanceCull => true; // legacy map-scale behaviour
}
