import '../shared/vector3.dart';
import '../universe/celestial_body.dart';

/// Determines whether a vessel is in a body's shadow (eclipse). Domain service.
///
/// Cylindrical-shadow model (no penumbra): the body casts an infinite shadow
/// cylinder of its own radius pointing directly away from the sun. A vessel is
/// dark only if it is (a) on the anti-sun side of the body centre, and (b)
/// within the body radius of the sun-shadow axis. Cheap and adequate for the
/// thermal tick; a conical umbra/penumbra can replace [litFraction] later.
class EclipseService {
  const EclipseService();

  /// 1.0 = fully lit, 0.0 = fully shadowed. [bodyCentredPosition] is the vessel
  /// position in the body's inertial frame; [sunDirection] is the unit vector
  /// from the body toward the sun.
  double litFraction({
    required Vector3 bodyCentredPosition,
    required CelestialBody body,
    required Vector3 sunDirection,
  }) {
    final s = sunDirection.normalized;
    final p = bodyCentredPosition;

    // Component of position along the sun axis. Positive = sunward side.
    final along = p.dot(s);
    if (along >= 0) return 1.0; // sunward hemisphere is always lit

    // Perpendicular distance from the shadow axis.
    final axial = s * along;
    final perpendicular = (p - axial).length;

    // Inside the shadow cylinder behind the body -> dark.
    return perpendicular < body.radius ? 0.0 : 1.0;
  }
}
