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
    // Semi-major axis from vis-viva. Exactly-parabolic energy (a -> inf) is a
    // measure-zero edge that used to poison propagation with NaN (inf * 0);
    // clamp to a huge finite conic of the right family instead.
    var a = -mu / (2 * energy);
    if (!a.isFinite || a.abs() > 1e18) a = energy <= 0 ? 1e18 : -1e18;

    final i = math.acos((h.z / hMag).clamp(-1.0, 1.0));

    var raan = nMag < 1e-12 ? 0.0 : math.acos((n.x / nMag).clamp(-1.0, 1.0));
    if (n.y < 0) raan = 2 * math.pi - raan;

    // Argument of periapsis. For an inclined orbit it's the node->periapsis
    // angle. For an EQUATORIAL orbit the node vector is zero (n = Z x h = 0), so
    // we instead take the periapsis longitude straight from the eccentricity
    // vector — otherwise argP was forced to 0 and the periapsis snapped to +X,
    // teleporting any vessel on an equatorial orbit whose periapsis lies
    // elsewhere (e.g. right after a burn flips AP/PE).
    double argP;
    if (e < 1e-9) {
      argP = 0.0; // circular: periapsis undefined, anomaly carries position
    } else if (nMag >= 1e-9) {
      argP = math.acos((n.dot(eVec) / (nMag * e)).clamp(-1.0, 1.0));
      if (eVec.z < 0) argP = 2 * math.pi - argP;
    } else {
      // Equatorial: longitude of periapsis from +X, sign by the cross product
      // direction relative to the orbit normal (h.z).
      argP = math.atan2(eVec.y, eVec.x);
      if (h.z < 0) argP = 2 * math.pi - argP; // retrograde equatorial
      argP = _wrap(argP);
    }

    // True anomaly. For an eccentric orbit it's measured from periapsis (the
    // eccentricity vector). For a (near-)circular orbit the periapsis direction
    // is undefined, so we instead use the position angle measured from a stable
    // reference — the ascending node (argument of latitude), or the +X axis for
    // an equatorial circular orbit. WITHOUT this, a circular orbit always
    // reported anomaly 0 (vessel pinned at "periapsis"), so on-rails propagation
    // round-trips lost the vessel's position and it appeared frozen.
    double nu;
    if (e >= 1e-9) {
      nu = math.acos((eVec.dot(r) / (e * rMag)).clamp(-1.0, 1.0));
      if (r.dot(v) < 0) nu = 2 * math.pi - nu;
    } else if (nMag >= 1e-9) {
      // Circular inclined: argument of latitude (node -> position).
      nu = math.acos((n.dot(r) / (nMag * rMag)).clamp(-1.0, 1.0));
      if (r.z < 0) nu = 2 * math.pi - nu;
    } else {
      // Circular equatorial: true longitude from +X.
      nu = math.acos((r.x / rMag).clamp(-1.0, 1.0));
      if (r.y < 0) nu = 2 * math.pi - nu;
    }

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
    final a = el.semiMajorAxis;
    final n = el.meanMotion(mu);

    double xP, yP, vxP, vyP;
    if (e >= 1.0) {
      // Hyperbolic (escape) conic: a < 0, anomaly is the hyperbolic H from
      // M = e sinh H - H. Exactly-parabolic e is nudged hyperbolic so the
      // formulas stay finite (sqrt(e^2 - 1) = 0 would collapse the y axis).
      final eH = math.max(e, 1.0 + 1e-9);
      final hAnom = _solveKeplerHyperbolic(m, eH);
      final coshH = _cosh(hAnom);
      final sinhH = _sinh(hAnom);
      final r = a * (1 - eH * coshH); // > 0 since a < 0
      xP = a * (coshH - eH);
      yP = -a * math.sqrt(eH * eH - 1) * sinhH;
      vxP = -n * a * a * sinhH / r;
      vyP = n * a * a * math.sqrt(eH * eH - 1) * coshH / r;
    } else {
      final eccAnom = _solveKepler(m, e);

      // Perifocal coordinates.
      final cosE = math.cos(eccAnom);
      final sinE = math.sin(eccAnom);

      xP = a * (cosE - e);
      yP = a * math.sqrt(1 - e * e) * sinE;

      final rDot = (a * n) / (1 - e * cosE);
      vxP = -rDot * sinE;
      vyP = rDot * math.sqrt(1 - e * e) * cosE;
    }

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

  /// Solve the hyperbolic Kepler equation M = e sinh H - H via Newton-Raphson.
  /// M is unbounded (no wrap); sign carries inbound (< 0) vs outbound (> 0).
  double _solveKeplerHyperbolic(double m, double e, {int maxIter = 64}) {
    var h = _asinh(m / e);
    for (var k = 0; k < maxIter; k++) {
      final f = e * _sinh(h) - h - m;
      var fp = e * _cosh(h) - 1;
      if (fp < 1e-12) fp = 1e-12; // near-parabolic: f' -> 0 at H ~ 0
      final d = f / fp;
      h -= d;
      if (d.abs() < 1e-12 * (1 + h.abs())) break;
    }
    return h;
  }

  double _trueToMean(double nu, double e) {
    if (e >= 1.0) {
      // Hyperbolic: H from true anomaly via robust sinh form (avoids the
      // tan(nu/2) blowup near the asymptotes), then M = e sinh H - H.
      // NOT wrapped — hyperbolic mean anomaly is unbounded and signed.
      final eH = math.max(e, 1.0 + 1e-9);
      final denom = 1 + eH * math.cos(nu);
      final sinhH =
          math.sqrt(eH * eH - 1) * math.sin(nu) / math.max(denom, 1e-12);
      final h = _asinh(sinhH);
      return eH * sinhH - h;
    }
    final eccAnom =
        2 * math.atan2(math.sqrt(1 - e) * math.sin(nu / 2), math.sqrt(1 + e) * math.cos(nu / 2));
    return _wrap(eccAnom - e * math.sin(eccAnom));
  }

  // dart:math has no hyperbolic functions.
  double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;
  double _cosh(double x) => (math.exp(x) + math.exp(-x)) / 2;
  double _asinh(double x) => math.log(x + math.sqrt(x * x + 1));

  double _wrap(double a) {
    final twoPi = 2 * math.pi;
    var r = a % twoPi;
    if (r < 0) r += twoPi;
    return r;
  }
}
