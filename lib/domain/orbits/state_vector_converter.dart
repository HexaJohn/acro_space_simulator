import 'dart:math' as math;

import '../dynamics/state_vector.dart';
import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import 'orbit.dart';
import 'orbital_elements.dart';

/// Converts between a Cartesian [StateVector] and Keplerian [Orbit] for a given
/// gravitational parameter. Domain service — stateless, pure math.
///
/// This is the bridge between the two propagation modes: "physics" mode lives
/// in state vectors; "on-rails" mode lives in orbital elements. When a vessel
/// goes on rails we [toOrbit]; when it leaves rails we [toStateVector].
class StateVectorOrbitConverter {
  const StateVectorOrbitConverter();

  /// Cartesian (body-centred inertial) -> Keplerian elements.
  Orbit toOrbit({
    required Vector3 position,
    required Vector3 velocity,
    required CelestialBody body,
    required Epoch epoch,
  }) {
    final mu = body.mu;
    final r = position;
    final v = velocity;
    final rMag = r.length;

    final h = r.cross(v); // specific angular momentum
    final hMag = h.length;

    // Degenerate: (near-)zero angular momentum — radial fall or a body at rest
    // in this frame. A conic is ill-defined; return a trivial circular orbit at
    // the current radius so propagation is a no-op rather than producing NaN.
    if (hMag < 1e-3 || rMag < 1e-6) {
      return Orbit(
        elements: OrbitalElements(
          semiMajorAxis: rMag,
          eccentricity: 0,
          inclination: 0,
          longitudeOfAscendingNode: 0,
          argumentOfPeriapsis: 0,
          meanAnomalyAtEpoch: 0,
        ),
        body: body.id,
        mu: mu,
        epoch: epoch,
      );
    }

    final n = Vector3.unitZ.cross(h); // node vector
    final nMag = n.length;

    // Eccentricity vector.
    final eVec =
        (r * (v.lengthSquared - mu / rMag) - v * r.dot(v)) * (1.0 / mu);
    final e = eVec.length;

    final energy = v.lengthSquared / 2 - mu / rMag;
    final a = (e - 1.0).abs() < 1e-12 ? double.infinity : -mu / (2 * energy);

    final i = math.acos((h.z / hMag).clamp(-1.0, 1.0));

    var raan = nMag < 1e-12 ? 0.0 : math.acos((n.x / nMag).clamp(-1.0, 1.0));
    if (n.y < 0) raan = 2 * math.pi - raan;

    var argP = (nMag < 1e-12 || e < 1e-12)
        ? 0.0
        : math.acos((n.dot(eVec) / (nMag * e)).clamp(-1.0, 1.0));
    if (eVec.z < 0) argP = 2 * math.pi - argP;

    // True anomaly -> eccentric -> mean, so the orbit can be propagated.
    var nu = e < 1e-12
        ? 0.0
        : math.acos((eVec.dot(r) / (e * rMag)).clamp(-1.0, 1.0));
    if (r.dot(v) < 0) nu = 2 * math.pi - nu;

    final m0 = _trueToMean(nu, e);

    return Orbit(
      elements: OrbitalElements(
        semiMajorAxis: a,
        eccentricity: e,
        inclination: i,
        longitudeOfAscendingNode: raan,
        argumentOfPeriapsis: argP,
        meanAnomalyAtEpoch: m0,
      ),
      body: body.id,
      mu: mu,
      epoch: epoch,
    );
  }

  /// Keplerian -> Cartesian state at time [t] (translational part only;
  /// attitude is left at identity — propagation is for the trajectory).
  StateVector toStateVector(Orbit orbit, Epoch t) {
    final el = orbit.elements;
    final mu = orbit.mu;
    final e = el.eccentricity;
    final m = orbit.meanAnomalyAt(t);
    final eccAnom = _solveKepler(m, e);

    // Perifocal coordinates.
    final a = el.semiMajorAxis;
    final cosE = math.cos(eccAnom);
    final sinE = math.sin(eccAnom);

    final xP = a * (cosE - e);
    final yP = a * math.sqrt(1 - e * e) * sinE;

    final n = el.meanMotion(mu);
    final rDot = (a * n) / (1 - e * cosE);
    final vxP = -rDot * sinE;
    final vyP = rDot * math.sqrt(1 - e * e) * cosE;

    // Rotate perifocal -> inertial via (RAAN, inclination, argP).
    final pos = _perifocalToInertial(Vector3(xP, yP, 0), el);
    final vel = _perifocalToInertial(Vector3(vxP, vyP, 0), el);

    return StateVector(position: pos, velocity: vel);
  }

  Vector3 _perifocalToInertial(Vector3 p, OrbitalElements el) {
    final cosO = math.cos(el.longitudeOfAscendingNode);
    final sinO = math.sin(el.longitudeOfAscendingNode);
    final cosI = math.cos(el.inclination);
    final sinI = math.sin(el.inclination);
    final cosW = math.cos(el.argumentOfPeriapsis);
    final sinW = math.sin(el.argumentOfPeriapsis);

    final r11 = cosO * cosW - sinO * sinW * cosI;
    final r12 = -cosO * sinW - sinO * cosW * cosI;
    final r21 = sinO * cosW + cosO * sinW * cosI;
    final r22 = -sinO * sinW + cosO * cosW * cosI;
    final r31 = sinW * sinI;
    final r32 = cosW * sinI;

    return Vector3(
      r11 * p.x + r12 * p.y,
      r21 * p.x + r22 * p.y,
      r31 * p.x + r32 * p.y,
    );
  }

  /// Solve M = E - e sin E for eccentric anomaly via Newton-Raphson.
  double _solveKepler(double m, double e, {int maxIter = 32}) {
    m = _wrap(m);
    var ecc = e < 0.8 ? m : math.pi;
    for (var k = 0; k < maxIter; k++) {
      final f = ecc - e * math.sin(ecc) - m;
      final fp = 1 - e * math.cos(ecc);
      final d = f / fp;
      ecc -= d;
      if (d.abs() < 1e-12) break;
    }
    return ecc;
  }

  double _trueToMean(double nu, double e) {
    final eccAnom =
        2 * math.atan2(math.sqrt(1 - e) * math.sin(nu / 2), math.sqrt(1 + e) * math.cos(nu / 2));
    return _wrap(eccAnom - e * math.sin(eccAnom));
  }

  double _wrap(double a) {
    final twoPi = 2 * math.pi;
    var r = a % twoPi;
    if (r < 0) r += twoPi;
    return r;
  }
}
