import 'dart:math' as math;

/// Classical Keplerian orbital elements (the conic) relative to one body.
///
/// Value object. Defines the shape, orientation, and phase of an orbit; the
/// body's [mu] and an epoch turn it into a propagatable [Orbit].
class OrbitalElements {
  final double semiMajorAxis; // a, m  (negative for hyperbolic)
  final double eccentricity; // e
  final double inclination; // i, rad
  final double longitudeOfAscendingNode; // RAAN, rad
  final double argumentOfPeriapsis; // omega, rad
  final double meanAnomalyAtEpoch; // M0, rad

  const OrbitalElements({
    required this.semiMajorAxis,
    required this.eccentricity,
    required this.inclination,
    required this.longitudeOfAscendingNode,
    required this.argumentOfPeriapsis,
    required this.meanAnomalyAtEpoch,
  });

  bool get isElliptical => eccentricity < 1.0;
  bool get isHyperbolic => eccentricity > 1.0;

  double get periapsis => semiMajorAxis * (1 - eccentricity);
  double get apoapsis =>
      isElliptical ? semiMajorAxis * (1 + eccentricity) : double.infinity;

  /// Orbital period (s). Infinite/undefined for escape trajectories.
  double period(double mu) => isElliptical
      ? 2 * math.pi * math.sqrt(math.pow(semiMajorAxis, 3) / mu)
      : double.infinity;

  /// Mean motion n = sqrt(mu / |a|^3), rad/s.
  double meanMotion(double mu) =>
      math.sqrt(mu / (semiMajorAxis.abs() * semiMajorAxis.abs() * semiMajorAxis.abs()));

  @override
  String toString() =>
      'OrbitalElements(a:${semiMajorAxis.toStringAsExponential(3)}, e:${eccentricity.toStringAsFixed(4)}, '
      'i:${inclination.toStringAsFixed(3)})';
}
