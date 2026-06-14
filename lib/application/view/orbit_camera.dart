import 'dart:math' as math;

import '../../domain/shared/vector3.dart';

/// Ultra-simple orbiting 3D camera, expressed in the same right-handed,
/// Z-up world frame as the domain ([Vector3]).
///
/// The camera looks at a [focus] point from a [distance] away, with its
/// position given by spherical coordinates ([yaw] about the world Z axis,
/// [pitch] above the XY plane). Every mutator returns a new camera, so this
/// is an immutable value object: pure math, no Flutter or IO.
class OrbitCamera {
  /// World-space point the camera looks at.
  final Vector3 focus;

  /// Distance from [focus] to the eye (m). Always within
  /// `[minDistance, maxDistance]`.
  final double distance;

  /// Azimuth about the world +Z axis (rad). Unbounded.
  final double yaw;

  /// Elevation above the world XY plane (rad). Clamped to
  /// `(-pitchLimit, pitchLimit)` so the camera never flips over the poles.
  final double pitch;

  /// Closest allowed [distance].
  final double minDistance;

  /// Farthest allowed [distance].
  final double maxDistance;

  /// Hard limit for [pitch] magnitude, just shy of vertical (rad).
  final double pitchLimit;

  const OrbitCamera({
    required this.focus,
    required this.distance,
    required this.yaw,
    required this.pitch,
    this.minDistance = 1.0,
    this.maxDistance = 1.0e9,
    this.pitchLimit = math.pi / 2 - 0.01,
  });

  OrbitCamera copyWith({
    Vector3? focus,
    double? distance,
    double? yaw,
    double? pitch,
  }) =>
      OrbitCamera(
        focus: focus ?? this.focus,
        distance: distance ?? this.distance,
        yaw: yaw ?? this.yaw,
        pitch: pitch ?? this.pitch,
        minDistance: minDistance,
        maxDistance: maxDistance,
        pitchLimit: pitchLimit,
      );

  /// Rotate the camera around the focus by [deltaYaw]/[deltaPitch] (rad).
  /// Pitch is clamped to keep the camera off the poles.
  OrbitCamera orbit({double deltaYaw = 0, double deltaPitch = 0}) {
    final newPitch =
        (pitch + deltaPitch).clamp(-pitchLimit, pitchLimit).toDouble();
    return copyWith(yaw: yaw + deltaYaw, pitch: newPitch);
  }

  /// Move the [focus] (and therefore the eye) by [delta], keeping the same
  /// orientation and distance.
  OrbitCamera pan(Vector3 delta) => copyWith(focus: focus + delta);

  /// Scale the [distance] by [factor] (e.g. 0.5 zooms in, 2.0 zooms out),
  /// clamped to `[minDistance, maxDistance]`.
  OrbitCamera zoom(double factor) {
    final scaled =
        (distance * factor).clamp(minDistance, maxDistance).toDouble();
    return copyWith(distance: scaled);
  }

  /// Spherical offset from the focus to the eye (m), in the world frame.
  Vector3 _offset() {
    final cp = math.cos(pitch);
    return Vector3(
      distance * cp * math.cos(yaw),
      distance * cp * math.sin(yaw),
      distance * math.sin(pitch),
    );
  }

  /// World-space position of the camera (eye).
  Vector3 eyePosition() => focus + _offset();

  /// Unit view direction, pointing from the eye toward the focus.
  Vector3 forward() => (focus - eyePosition()).normalized;

  @override
  bool operator ==(Object other) =>
      other is OrbitCamera &&
      other.focus == focus &&
      other.distance == distance &&
      other.yaw == yaw &&
      other.pitch == pitch &&
      other.minDistance == minDistance &&
      other.maxDistance == maxDistance &&
      other.pitchLimit == pitchLimit;

  @override
  int get hashCode => Object.hash(
        focus,
        distance,
        yaw,
        pitch,
        minDistance,
        maxDistance,
        pitchLimit,
      );

  @override
  String toString() =>
      'OrbitCamera(focus: $focus, distance: $distance, '
      'yaw: $yaw, pitch: $pitch)';
}
