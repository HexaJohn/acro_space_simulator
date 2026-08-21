// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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

  /// This conic carries NO angular momentum: the motion is a straight line
  /// through the body's centre — a craft dropped or thrown radially.
  ///
  /// It cannot be expressed by [eccentricity] alone. A rectilinear conic has
  /// `e == 1` exactly, which the element set may not store (`e` and `a` would
  /// then disagree about the conic family), so it is held a hair off 1 instead
  /// — and the perifocal semi-minor axis `a*sqrt(1 - e^2)` that falls out of
  /// that hair is METRES wide, not zero. Reconstructing position from it gives
  /// a craft falling dead straight a sideways nudge every tick, in whatever
  /// arbitrary plane the conversion happened to pick. The flag says "the
  /// off-axis extent really is zero", so the reconstruction can honour it.
  final bool rectilinear;

  const OrbitalElements({
    required this.semiMajorAxis,
    required this.eccentricity,
    required this.inclination,
    required this.longitudeOfAscendingNode,
    required this.argumentOfPeriapsis,
    required this.meanAnomalyAtEpoch,
    this.rectilinear = false,
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
