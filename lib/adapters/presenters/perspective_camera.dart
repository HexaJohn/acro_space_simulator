import 'dart:math' as math;

import '../../domain/shared/vector3.dart';
import 'camera_view.dart';

/// A true 3D perspective camera that orbits a focus point. The eye sits at
/// [range] metres from the target, at the given azimuth/elevation, and looks at
/// the target. Points are projected with a real perspective divide (distant
/// things shrink, near things grow), unlike the orthographic [OrthoCamera].
///
/// Inputs to [projectPx] are WORLD positions already recentred on the target
/// (`world - targetWorld`) — the same camera-relative metres the painter uses.
///
/// World frame: X/Y ecliptic plane, +Z up (out of the ecliptic).
class PerspectiveCamera implements SceneCamera {
  @override
  final double azimuth; // spin about +Z
  @override
  final double elevation; // tilt above the ecliptic (+ = look down)
  final double range; // eye distance from the target, metres
  final double fovY; // vertical field of view, radians
  final double roll; // screen roll about the view axis
  final double viewportH; // screen height, px (sets focal length)
  final double near; // near-plane distance from the eye, metres

  const PerspectiveCamera({
    this.azimuth = 0,
    this.elevation = 0.5,
    this.range = 2.0e7,
    this.fovY = 50 * math.pi / 180,
    this.roll = 0,
    this.viewportH = 800,
    this.near = 1.0,
  });

  PerspectiveCamera copyWith({
    double? azimuth,
    double? elevation,
    double? range,
    double? fovY,
    double? roll,
    double? viewportH,
  }) =>
      PerspectiveCamera(
        azimuth: azimuth ?? this.azimuth,
        elevation: (elevation ?? this.elevation)
            .clamp(-math.pi / 2 + 0.02, math.pi / 2 - 0.02),
        range: (range ?? this.range).clamp(1.0, 1e13),
        fovY: fovY ?? this.fovY,
        roll: roll ?? this.roll,
        viewportH: viewportH ?? this.viewportH,
        near: near,
      );

  // --- Camera basis (world space) ---
  @override
  Vector3 get forward {
    final ce = math.cos(elevation), se = math.sin(elevation);
    final ca = math.cos(azimuth), sa = math.sin(azimuth);
    return Vector3(ce * sa, ce * ca, -se);
  }

  Vector3 get _rightBase {
    final ca = math.cos(azimuth), sa = math.sin(azimuth);
    return Vector3(ca, -sa, 0);
  }

  Vector3 get _upBase => _rightBase.cross(forward).normalized;

  @override
  Vector3 get right {
    if (roll == 0) return _rightBase;
    final cr = math.cos(roll), sr = math.sin(roll);
    return (_rightBase * cr + _upBase * sr).normalized;
  }

  @override
  Vector3 get up {
    if (roll == 0) return _upBase;
    final cr = math.cos(roll), sr = math.sin(roll);
    return (_upBase * cr - _rightBase * sr).normalized;
  }

  /// Eye position relative to the target (= -forward * range).
  Vector3 get _eyeRel => forward * -range;

  double get _focal => (viewportH / 2) / math.tan(fovY / 2);

  @override
  double depth(Vector3 rel) => (rel - _eyeRel).dot(forward);

  @override
  Vector3 viewDirTo(Vector3 rel) {
    final d = rel - _eyeRel;
    return d.length < 1e-9 ? forward : d.normalized;
  }

  @override
  ({double x, double y})? projectPx(Vector3 rel) {
    final fromEye = rel - _eyeRel;
    final z = fromEye.dot(forward); // depth into the screen
    if (z <= near) return null; // behind the camera / too close
    final f = _focal;
    return (x: fromEye.dot(right) / z * f, y: fromEye.dot(up) / z * f);
  }

  @override
  double radiusPx(Vector3 rel, double radiusM) {
    final fromEye = rel - _eyeRel;
    final z = fromEye.dot(forward);
    if (z <= near) return 0;
    // Apparent size depends on the EUCLIDEAN distance to the eye, not the planar
    // depth along the view axis — otherwise a body at the frame edge (smaller z
    // for the same distance) draws too large. Angular radius asin(R/d) projected
    // back through the focal length.
    final d = fromEye.length;
    if (d <= radiusM) return _focal * 4; // inside/at the sphere -> huge
    final theta = math.asin((radiusM / d).clamp(0.0, 1.0));
    return _focal * math.tan(theta);
  }

  @override
  bool get isTopish => false; // perspective never skips the tilted cull

  @override
  bool get usesDistanceCull => false; // distance shrink + near-plane handle it
}
