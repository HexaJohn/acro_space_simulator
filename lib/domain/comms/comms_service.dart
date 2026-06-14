import '../shared/vector3.dart';

/// Communication geometry: signal light-time delay, body occlusion (line of
/// sight), and inverse-square signal strength. Domain service — pure geometry.
///
/// At 1:1 scale, interplanetary distances make light-time non-trivial (minutes),
/// so autonomous craft must tolerate command lag — the same constraint real
/// deep-space missions face. Occlusion models a planet blocking the radio path.
class CommsService {
  static const double speedOfLight = 299792458.0; // m/s

  const CommsService();

  /// One-way signal delay (s) between two points.
  double signalDelaySeconds(Vector3 a, Vector3 b) =>
      (b - a).length / speedOfLight;

  /// Round-trip (command + ack) delay (s).
  double roundTripDelaySeconds(Vector3 a, Vector3 b) =>
      2 * signalDelaySeconds(a, b);

  /// True if a spherical body blocks the straight path from [a] to [b]. Tests
  /// the closest point on the segment to the body centre against its radius.
  bool isOccluded(
    Vector3 a,
    Vector3 b, {
    required Vector3 occluderCentre,
    required double occluderRadius,
  }) {
    final ab = b - a;
    final lenSq = ab.lengthSquared;
    if (lenSq == 0) return false;

    // Project the centre onto the segment, clamped to [0,1].
    final t = ((occluderCentre - a).dot(ab) / lenSq).clamp(0.0, 1.0);
    final closest = a + ab * t;
    return (occluderCentre - closest).length < occluderRadius;
  }

  /// Convenience: clear line of sight = not occluded.
  bool hasLineOfSight(
    Vector3 a,
    Vector3 b, {
    required Vector3 occluderCentre,
    required double occluderRadius,
  }) =>
      !isOccluded(a, b,
          occluderCentre: occluderCentre, occluderRadius: occluderRadius);

  /// Relative signal strength, inverse-square with distance. Unitless gameplay
  /// figure (transmitPower / distance^2); compare against a receiver threshold.
  double signalStrength({required double distance, required double transmitPower}) {
    if (distance <= 0) return double.infinity;
    return transmitPower / (distance * distance);
  }
}
