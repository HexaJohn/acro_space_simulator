import 'precise_vector3.dart';
import 'quaternion.dart';
import 'vector3.dart';

/// A rigid transform (rotation + precise translation) that carries a
/// **granularity** so transforms at wildly different scales compose without
/// losing precision.
///
/// This is the "transform matrix with an additional dimension for granularity".
/// Rather than a single 4x4 matrix in absolute metres (which would jitter at
/// km/AU scale), translation is stored as a [PreciseVector3] (integer cell +
/// double offset) and rotation as a unit [Quaternion]. Composition keeps the
/// integer cell parts as integers until the very last moment.
class ScaledTransform {
  final PreciseVector3 translation;
  final Quaternion rotation;

  const ScaledTransform(this.translation, this.rotation);

  ScaledTransform.identity({int granularity = 3})
      : translation = const PreciseVector3(
          cellX: 0,
          cellY: 0,
          cellZ: 0,
          local: Vector3.zero,
          granularity: 3,
        ),
        rotation = Quaternion.identity;

  /// Map a point given in *this frame's local coordinates* to world space.
  PreciseVector3 localToWorld(Vector3 localPoint) =>
      translation + rotation.rotate(localPoint);

  /// Map a world point into this frame's local coordinates (metres), relative
  /// to the frame origin. Small numbers out — safe for physics/rendering.
  Vector3 worldToLocal(PreciseVector3 world) =>
      rotation.conjugate.rotate(translation.vectorTo(world));

  /// Compose: result maps a point in [child]'s local frame to the world frame
  /// of `this`. `this` is the parent.
  ScaledTransform compose(ScaledTransform child) => ScaledTransform(
        translation + rotation.rotate(child.translation.local),
        (rotation * child.rotation).normalized,
      );

  @override
  String toString() => 'ScaledTransform(t:$translation r:$rotation)';
}
