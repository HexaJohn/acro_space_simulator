// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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

  /// How far `e` is held clear of exactly 1, so that it and the semi-major axis
  /// never disagree about which conic they describe. Small enough to be
  /// physically irrelevant (it moves a rectilinear periapsis by `a * 1e-12` —
  /// sub-micron at planetary scale), large enough to survive double rounding.
  static const double _familyEpsilon = 1e-12;

  /// Angular momentum, as a fraction of this radius's CIRCULAR value, below
  /// which a trajectory is treated as a straight line through the centre.
  ///
  /// Not a precision guard on `h` itself — a guard on the coordinate the
  /// general path measures phase with. That path carries phase in the TRUE
  /// anomaly, which on a near-radial trajectory barely moves: the craft is
  /// falling fast while sweeping almost no angle, so a tick advances the true
  /// anomaly by less than the error in recovering it, and the round trip stands
  /// still. Measured on a lunar drop, the general path is frozen solid below
  /// ~0.01 m/s of cross-track and still hundreds of metres out at 0.02.
  ///
  /// The rectilinear path measures phase from the RADIUS instead, which is
  /// exactly what changes fastest here, so it stays sharp all the way to zero.
  /// This threshold is where the handover happens: 1e-4 of circular is ~0.16
  /// m/s at a low lunar orbit, so what is given up is a tenth of a metre per
  /// second of cross-track on a trajectory already falling straight down.
  static const double _rectilinearFraction = 1e-4;

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

    // (Near-)zero angular momentum: a RECTILINEAR trajectory — a craft dropped
    // straight down, or thrown straight up. This is a real conic (the e -> 1
    // limit at finite a), not an error case, and it is handled below rather
    // than papered over.
    //
    // The threshold is relative to the circular angular momentum at this
    // radius, so it means the same thing on every body. Below it the periapsis
    // is a fraction of a millimetre from the body's CENTRE and the classical
    // element set stops carrying position: with e == 1 the conic equation
    // r = p/(1 + e cos v) degenerates to 0/0, so true anomaly — which the
    // general path below derives position from — encodes nothing. The
    // eccentric anomaly still does, so [_rectilinear] goes at it from there.
    if (rMag < 1e-6) return _zeroRadiusOrbit(body, mu, epoch);
    if (hMag < _rectilinearFraction * math.sqrt(mu * rMag)) {
      return _rectilinear(
          r: r, v: v, rMag: rMag, mu: mu, body: body, epoch: epoch);
    }

    final n = Vector3.unitZ.cross(h); // node vector
    final nMag = n.length;

    // Eccentricity vector.
    final eVec =
        (r * (v.lengthSquared - mu / rMag) - v * r.dot(v)) * (1.0 / mu);
    var e = eVec.length;

    final energy = v.lengthSquared / 2 - mu / rMag;
    // Semi-major axis from vis-viva. Exactly-parabolic energy (a -> inf) is a
    // measure-zero edge that used to poison propagation with NaN (inf * 0);
    // clamp to a huge finite conic of the right family instead.
    var a = -mu / (2 * energy);
    if (!a.isFinite || a.abs() > 1e18) a = energy <= 0 ? 1e18 : -1e18;

    // A conic too thin for the element set to carry.
    //
    // `e` comes out of a vector difference, so on a very eccentric orbit the
    // interesting quantity is `1 - e` — and once that falls under
    // [_familyEpsilon] the double simply has no room for it. Pinning `e` at
    // `1 -/+ _familyEpsilon` used to keep it merely agreeing with `a` about the
    // conic FAMILY, but the pinned value no longer describes this trajectory:
    // round-tripping state -> elements -> state then loses a little phase every
    // tick, and on a near-radial fall it loses ALL of it. The craft stops
    // descending in mid-air and hangs there.
    //
    // [_rectilinear] is the representation built for exactly this — a conic
    // with no width — and it round-trips exactly. Anything the general element
    // set cannot hold goes there instead of being pinned into a lie.
    if ((a > 0 && e >= 1.0 - _familyEpsilon) ||
        (a < 0 && e <= 1.0 + _familyEpsilon)) {
      return _rectilinear(
          r: r, v: v, rMag: rMag, mu: mu, body: body, epoch: epoch);
    }

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

  /// The conic for a RECTILINEAR trajectory — falling straight toward the
  /// body's centre, or rising straight away from it.
  ///
  /// Such a trajectory has no orbital PLANE: with `h = 0` the plane normal, the
  /// node vector, and therefore inclination and RAAN are all undefined. It is
  /// nonetheless a perfectly real conic — the degenerate ellipse `e = 1` at
  /// FINITE positive `a`, apoapsis `2a`, periapsis the centre itself. (The
  /// parabola is the other degenerate case, the one where `a` runs to infinity;
  /// conflating the two is what makes this look unrepresentable.)
  ///
  /// Two observations make the classical element set carry it anyway:
  ///
  ///  * Any plane containing the line of motion reproduces that motion exactly,
  ///    so one is synthesised deterministically. The choice cannot affect where
  ///    the craft ends up — it travels along the apsidal line either way.
  ///  * Position must come from the ECCENTRIC anomaly, solved from the radius.
  ///    True anomaly is useless here: at `e = 1` the conic equation
  ///    `r = p / (1 + e cos v)` has `p = 0`, so it degenerates to `0/0` and
  ///    every radius on the line reports the same anomaly.
  ///
  /// The perifocal x axis is `-r`: periapsis is at the centre, so a craft out
  /// at radius `r` sits on the apoapsis side of it.
  ///
  /// [toStateVector]'s elliptic branch then reproduces this EXACTLY, not
  /// approximately. At `e -> 1` it collapses to `xP = a(cos E - 1) = -r` and
  /// `yP = 0`, and `_solveKepler` is solving `E - sin E = M` — which is the
  /// radial Kepler equation itself.
  Orbit _rectilinear({
    required Vector3 r,
    required Vector3 v,
    required double rMag,
    required double mu,
    required CelestialBody body,
    required Epoch epoch,
  }) {
    final rHat = r * (1.0 / rMag);
    final vr = r.dot(v) / rMag; // signed radial speed; negative = falling

    final energy = v.lengthSquared / 2 - mu / rMag;
    var a = -mu / (2 * energy);
    if (!a.isFinite || a.abs() > 1e18) a = energy <= 0 ? 1e18 : -1e18;
    final e = a > 0 ? 1.0 - _familyEpsilon : 1.0 + _familyEpsilon;

    // Perifocal x: toward periapsis, which is straight down the radial.
    final xHat = -rHat;
    // Any plane through the line of motion; take the one it spans with +Z, and
    // fall back to +X when the motion is along the pole and that degenerates.
    var w = rHat.cross(Vector3.unitZ);
    if (w.lengthSquared < 1e-18) w = rHat.cross(Vector3.unitX);
    w = w.normalized;

    final i = math.acos(w.z.clamp(-1.0, 1.0));
    var nVec = Vector3.unitZ.cross(w);
    var raan = 0.0;
    if (nVec.lengthSquared < 1e-18) {
      nVec = Vector3.unitX; // equatorial plane: no node, anchor the frame at +X
    } else {
      nVec = nVec.normalized;
      raan = _wrap(math.atan2(nVec.y, nVec.x));
    }
    // Signed node -> periapsis angle, taken about the orbit normal.
    final argP = _wrap(math.atan2(nVec.cross(xHat).dot(w), nVec.dot(xHat)));

    // Phase from the RADIUS via the eccentric anomaly.
    double m0;
    if (a > 0) {
      // r = a(1 - e cos E). E runs 0 (periapsis) -> pi (apoapsis) -> 2pi, so
      // rising is E in (0, pi) and falling is (pi, 2pi).
      var eccAnom = math.acos((((1 - rMag / a) / e)).clamp(-1.0, 1.0));
      if (vr < 0) eccAnom = 2 * math.pi - eccAnom;
      m0 = _wrap(eccAnom - e * math.sin(eccAnom));
    } else {
      // r = a(1 - e cosh H) with a < 0. H < 0 inbound, H > 0 outbound.
      final coshH = math.max((1 - rMag / a) / e, 1.0);
      var hAnom = math.log(coshH + math.sqrt(coshH * coshH - 1));
      if (vr < 0) hAnom = -hAnom;
      m0 = e * _sinh(hAnom) - hAnom;
    }

    return Orbit(
      elements: OrbitalElements(
        semiMajorAxis: a,
        eccentricity: e,
        inclination: i,
        longitudeOfAscendingNode: raan,
        argumentOfPeriapsis: argP,
        meanAnomalyAtEpoch: m0,
        rectilinear: true,
      ),
      body: body.id,
      mu: mu,
      epoch: epoch,
    );
  }

  /// A craft at (or within a micron of) the body's CENTRE.
  ///
  /// There is no conic here — no radius, no direction — and no answer more
  /// correct than any other. The zero semi-major axis makes propagation
  /// non-finite, which the rails path already checks for and answers by holding
  /// the craft's current state for the tick. Unreachable in practice; kept
  /// total so [toOrbit] never divides by a zero radius.
  Orbit _zeroRadiusOrbit(CelestialBody body, double mu, Epoch epoch) => Orbit(
        elements: const OrbitalElements(
          semiMajorAxis: 0,
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
      vxP = -n * a * a * sinhH / r;
      // A rectilinear conic has no width. `sqrt(eH^2 - 1)` is a hair off zero
      // rather than zero, and that hair is metres of off-axis offset.
      yP = el.rectilinear ? 0.0 : -a * math.sqrt(eH * eH - 1) * sinhH;
      vyP = el.rectilinear
          ? 0.0
          : n * a * a * math.sqrt(eH * eH - 1) * coshH / r;
    } else {
      final eccAnom = _solveKepler(m, e);

      // Perifocal coordinates.
      final cosE = math.cos(eccAnom);
      final sinE = math.sin(eccAnom);

      xP = a * (cosE - e);

      final rDot = (a * n) / (1 - e * cosE);
      vxP = -rDot * sinE;
      // As above: on a straight-line conic the off-axis terms are exactly zero,
      // and the `sqrt(1 - e^2)` that stands in for them is not.
      yP = el.rectilinear ? 0.0 : a * math.sqrt(1 - e * e) * sinE;
      vyP = el.rectilinear ? 0.0 : rDot * math.sqrt(1 - e * e) * cosE;
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
