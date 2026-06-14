import 'dart:math' as math;

import '../shared/vector3.dart';

/// Gravitational acceleration field for an oblate (flattened) body, including
/// the dominant J2 zonal-harmonic perturbation.
///
/// Real planets are not perfect point masses: rotation flattens them at the
/// poles and bulges them at the equator. The J2 term is the largest correction
/// to the point-mass field and is what makes low orbits precess (nodal drift)
/// and what makes surface gravity slightly stronger at the poles. The spin axis
/// is +Z by project convention, so the oblateness is symmetric about Z.
///
/// Pure value object — no Flutter/IO. Acceleration is in m/s^2 for a
/// body-centred position [r] in metres.
class GravityField {
  /// Standard gravitational parameter mu = G*M (m^3/s^2).
  final double mu;

  /// Equatorial reference radius the J2 coefficient is defined against (m).
  final double equatorialRadius;

  /// Dimensionless J2 zonal harmonic coefficient (Earth ~1.08e-3). Zero gives a
  /// pure point-mass field.
  final double j2;

  const GravityField({
    required this.mu,
    required this.equatorialRadius,
    this.j2 = 0,
  });

  /// Gravitational acceleration (m/s^2) at body-centred position [r] (m).
  ///
  /// a = a_pointMass + a_J2, where the point-mass term is -mu*r/|r|^3 and the
  /// J2 term follows the standard zonal-harmonic gradient with the spin axis on
  /// +Z. Returns zero at the origin to avoid the singularity.
  Vector3 accelerationAt(Vector3 r) {
    final d2 = r.lengthSquared;
    if (d2 == 0) return Vector3.zero;

    final d = math.sqrt(d2);

    // Point-mass acceleration: -mu * r / |r|^3.
    final pointMass = r * (-mu / (d2 * d));

    if (j2 == 0) return pointMass;

    // J2 perturbation. With the spin axis on +Z, define z-ratio s = z/|r|.
    // The acceleration components are:
    //   factor = -1.5 * J2 * mu * Re^2 / r^5
    //   ax = factor * x * (1 - 5 z^2/r^2)
    //   ay = factor * y * (1 - 5 z^2/r^2)
    //   az = factor * z * (3 - 5 z^2/r^2)
    final re2 = equatorialRadius * equatorialRadius;
    final factor = -1.5 * j2 * mu * re2 / (d2 * d2 * d);
    final zRatioSq = (r.z * r.z) / d2;
    final lateral = 1 - 5 * zRatioSq;

    final perturbation = Vector3(
      factor * r.x * lateral,
      factor * r.y * lateral,
      factor * r.z * (3 - 5 * zRatioSq),
    );

    return pointMass + perturbation;
  }
}
