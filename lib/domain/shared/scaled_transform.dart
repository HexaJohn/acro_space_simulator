// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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

  // NOT a const initializer list: a const PreciseVector3(...) cannot reference
  // the parameter, which is exactly how a previous version silently ignored
  // `granularity` and handed every caller a g=3 transform.
  ScaledTransform.identity({int granularity = 3})
      : translation = PreciseVector3.origin(granularity: granularity),
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
  ///
  /// The child's FULL translation participates — cell part included. (A
  /// previous version rotated only `child.translation.local`, silently
  /// dropping whole cells: any child sitting kilometres from its parent's
  /// origin composed wrong by exactly those kilometres.)
  ///
  /// Precision: an UNROTATED parent adds cells as integers — exact at any
  /// distance, the lattice promise kept. A rotated parent cannot (a rotation
  /// mixes axes off the lattice), so the child's cell offset necessarily
  /// passes through a double: at 1 AU that costs ~15 µm post-rotation, which
  /// is inherent to rotating a lattice, not to this implementation.
  ScaledTransform compose(ScaledTransform child) {
    final childT = child.translation.granularity == translation.granularity
        ? child.translation
        : child.translation.rebase(translation.granularity);

    final PreciseVector3 composedT;
    final isUnrotated =
        rotation.w == 1 && rotation.x == 0 && rotation.y == 0 && rotation.z == 0;
    if (isUnrotated) {
      composedT = PreciseVector3(
        cellX: translation.cellX + childT.cellX,
        cellY: translation.cellY + childT.cellY,
        cellZ: translation.cellZ + childT.cellZ,
        local: translation.local + childT.local,
        granularity: translation.granularity,
      ).normalized;
    } else {
      final s = childT.cellSize;
      final cellMeters = Vector3(
        childT.cellX * s,
        childT.cellY * s,
        childT.cellZ * s,
      );
      composedT =
          translation + rotation.rotate(cellMeters) + rotation.rotate(childT.local);
    }
    return ScaledTransform(
      composedT,
      (rotation * child.rotation).normalized,
    );
  }

  @override
  String toString() => 'ScaledTransform(t:$translation r:$rotation)';
}
