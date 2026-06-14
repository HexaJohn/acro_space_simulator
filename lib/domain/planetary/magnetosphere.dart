import 'dart:math' as math;

import '../shared/vector3.dart';

/// Magnetic-dipole model of a planet's magnetosphere, plus a trapped-particle
/// radiation belt (Van Allen) intensity field.
///
/// The body's magnetic field is approximated as a centred dipole aligned with
/// the spin axis (+Z by project convention). The field magnitude falls off as
/// 1/r^3 and is twice as strong over the poles as over the equator at the same
/// radius — the classic dipole signature.
///
/// The radiation belt is a toroidal shell of charged particles trapped by that
/// field. It is empty at the surface (particles precipitate into the
/// atmosphere) and empty far out (beyond the trapping region), peaking in a
/// shell a few body radii out.
///
/// Pure value object — no Flutter/IO. Field strength is returned in Tesla for a
/// body-centred position in metres; belt intensity is a dimensionless 0..1.
class Magnetosphere {
  /// Vacuum permeability mu0 (T*m/A).
  static const double _mu0 = 1.25663706212e-6;

  /// Magnetic dipole moment magnitude (A*m^2). Earth is ~8e22.
  final double dipoleMoment;

  /// Body radius (m) — used as the unit for the radiation-belt geometry.
  final double bodyRadius;

  /// Centre of the radiation-belt shell, in body radii.
  final double beltCenterRadii;

  /// Width (standard deviation) of the belt shell, in body radii. Controls how
  /// sharply intensity falls off either side of [beltCenterRadii].
  final double beltWidthRadii;

  const Magnetosphere({
    required this.dipoleMoment,
    required this.bodyRadius,
    this.beltCenterRadii = 3.0,
    this.beltWidthRadii = 0.8,
  });

  /// Dipole field strength (Tesla) at body-centred position [r] (m).
  ///
  /// B = (mu0 * m / 4*pi*r^3) * sqrt(1 + 3*cos^2(theta)), where theta is the
  /// magnetic colatitude (angle from the +Z dipole axis). Returns 0 at the
  /// origin (the dipole singularity).
  double fieldStrengthAt(Vector3 r) {
    final d2 = r.lengthSquared;
    if (d2 == 0) return 0;

    final d = math.sqrt(d2);
    final cosTheta = r.z / d; // dipole axis is +Z
    final geometry = math.sqrt(1 + 3 * cosTheta * cosTheta);

    return (_mu0 * dipoleMoment) / (4 * math.pi * d2 * d) * geometry;
  }

  /// Trapped-radiation (Van Allen belt) intensity in [0,1] at [r].
  ///
  /// Modelled as a Gaussian shell centred at [beltCenterRadii] body radii: ~0
  /// at the surface, peaking in the mid-altitude shell, and decaying to ~0 far
  /// away. Returns 0 at the origin.
  double radiationBeltIntensity(Vector3 r) {
    final d = r.length;
    if (d == 0) return 0;

    final radii = d / bodyRadius;
    final delta = (radii - beltCenterRadii) / beltWidthRadii;
    final intensity = math.exp(-0.5 * delta * delta);
    return intensity.clamp(0.0, 1.0);
  }
}
