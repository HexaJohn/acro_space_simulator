// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import '../universe/star_system.dart';
import 'orbit.dart';
import 'orbital_elements.dart';
import 'state_vector_converter.dart';

/// Computes where celestial bodies are at a given epoch. Domain service.
///
/// Bodies follow a full Keplerian orbit about their parent, defined by the
/// body's orbital elements ([CelestialBody.orbitRadius] = semi-major axis,
/// eccentricity, inclination, RAAN, argument of periapsis, and
/// [CelestialBody.orbitPhase] = mean anomaly at epoch 0). Propagation reuses the
/// same [StateVectorOrbitConverter] vessels use, so body and vessel motion share
/// one tested code path. A circular, equatorial orbit (e=0, i=0) reduces to the
/// original simple model.
class BodyEphemeris {
  final StateVectorOrbitConverter converter;
  const BodyEphemeris([this.converter = const StateVectorOrbitConverter()]);

  /// Body position relative to its parent's centre, at [epoch]. Root bodies
  /// (no parent) return the origin.
  Vector3 positionRelativeToParent(
    CelestialBody body,
    StarSystem system,
    Epoch epoch,
  ) {
    final parent = system.parentOf(body);
    if (parent == null || body.orbitRadius == 0) return Vector3.zero;
    return _toParentFrame(body, parent,
        converter.toStateVector(_orbitOf(body, parent), epoch).position);
  }

  /// Body orbital velocity relative to its parent, at [epoch].
  Vector3 velocityRelativeToParent(
    CelestialBody body,
    StarSystem system,
    Epoch epoch,
  ) {
    final parent = system.parentOf(body);
    if (parent == null || body.orbitRadius == 0) return Vector3.zero;
    return _toParentFrame(body, parent,
        converter.toStateVector(_orbitOf(body, parent), epoch).velocity);
  }

  /// Regular moons ([CelestialBody.orbitsParentEquator]) have their orbital
  /// elements referenced to the parent's EQUATOR: rotate the propagated
  /// vector by the parent's axial tilt (about +X, the same convention the
  /// body-orientation snapshot uses) to express it in the ecliptic frame.
  Vector3 _toParentFrame(
      CelestialBody body, CelestialBody parent, Vector3 v) {
    if (!body.orbitsParentEquator || parent.axialTilt == 0) return v;
    return Quaternion.axisAngle(Vector3.unitX, parent.axialTilt).rotate(v);
  }

  /// One full closed orbit of [body] about its parent, sampled into points in
  /// the PARENT's frame. Empty for root bodies (no parent / no orbit).
  ///
  /// Vertex 0 is the body's EXACT position at [epoch], and the rest are sampled
  /// at uniform eccentric anomaly from there. So the rail always passes through
  /// the body (no floating off between facets) AND is evenly spaced (no bunching
  /// near apoapsis). Pass [epoch] = the current sim epoch.
  List<Vector3> orbitPathRelativeToParent(
    CelestialBody body,
    StarSystem system, {
    // 96 left ~4°-kink facets on rails seen up close; 256 keeps joints
    // under 1.5° (the render also densifies long chords in screen space).
    int samples = 256,
    Epoch epoch = Epoch.zero,
  }) {
    final parent = system.parentOf(body);
    if (parent == null || body.orbitRadius == 0) return const [];
    final orbit = _orbitOf(body, parent, meanAnomaly: 0); // phase-0 ellipse
    final period =
        2 * math.pi * math.sqrt(math.pow(body.orbitRadius, 3) / parent.mu);
    final n = 2 * math.pi / period; // mean motion
    final e = orbit.elements.eccentricity;

    // The body's current mean -> eccentric anomaly, so sample 0 lands on it.
    final mNow = body.orbitPhase + n * epoch.seconds;
    final eNow = _solveKepler(mNow, e);

    // The ring's GEOMETRY in the parent frame is fixed by the body's orbital
    // elements — reference data — while [epoch] only decides which point of
    // it the body currently occupies. Uncached, every call re-solved Kepler
    // per vertex, and WorldSnapshot.capture calls this for every body every
    // frame on the flutter_scene backend: ~34 bodies x 257 vertices was ~20%
    // of the whole UI thread (measured, profile mode, landed on the Moon),
    // plus the GC bill for the churned lists. So: sample the closed ring
    // ONCE per body at uniform eccentric anomaly, and per call pay a single
    // Kepler solve for vertex 0 — kept EXACTLY on the body, the documented
    // invariant above — then walk the cached grid from the nearest offset.
    var ring = _ringCache[body];
    if (ring == null || ring.length != samples) {
      ring = List<Vector3>.generate(samples, (i) {
        final ecc = 2 * math.pi * i / samples;
        final m = ecc - e * math.sin(ecc);
        return _toParentFrame(body, parent,
            converter.toStateVector(orbit, Epoch(m / n)).position);
      }, growable: false);
      _ringCache[body] = ring;
    }

    final mExact = eNow - e * math.sin(eNow);
    final exactNow = _toParentFrame(body, parent,
        converter.toStateVector(orbit, Epoch(mExact / n)).position);
    final step = 2 * math.pi / samples;
    // Positive modulo: eNow from a large epoch can be far outside 0..2pi.
    final k = ((eNow / step).floor() % samples + samples) % samples;
    final pts = <Vector3>[exactNow];
    for (var i = 1; i < samples; i++) {
      pts.add(ring[(k + i) % samples]);
    }
    pts.add(exactNow); // close the loop, as the uncached version did
    return pts;
  }

  /// Per-body closed orbit ring at phase 0 (see [orbitPathRelativeToParent]).
  /// An [Expando] so a body object's cache lives and dies with it — a rebuilt
  /// system (tests, body switches) never sees another's rings, and nothing
  /// leaks.
  static final Expando<List<Vector3>> _ringCache =
      Expando<List<Vector3>>('orbitRingCache');

  /// Solve M = E - e*sinE for the eccentric anomaly (Newton-Raphson).
  double _solveKepler(double m, double e) {
    var ecc = e < 0.8 ? m : math.pi;
    for (var k = 0; k < 24; k++) {
      final f = ecc - e * math.sin(ecc) - m;
      final fp = 1 - e * math.cos(ecc);
      final d = f / fp;
      ecc -= d;
      if (d.abs() < 1e-10) break;
    }
    return ecc;
  }

  /// Body position relative to the SYSTEM ROOT, chaining up the parent tree.
  Vector3 positionRelativeToRoot(
    CelestialBody body,
    StarSystem system,
    Epoch epoch,
  ) {
    var pos = Vector3.zero;
    CelestialBody? cur = body;
    while (cur != null && system.parentOf(cur) != null) {
      pos = pos + positionRelativeToParent(cur, system, epoch);
      cur = system.parentOf(cur);
    }
    return pos;
  }

  Orbit _orbitOf(CelestialBody body, CelestialBody parent,
          {double? meanAnomaly}) =>
      Orbit(
        elements: OrbitalElements(
          semiMajorAxis: body.orbitRadius,
          eccentricity: body.orbitEccentricity,
          inclination: body.orbitInclination,
          longitudeOfAscendingNode: body.orbitLongitudeAscending,
          argumentOfPeriapsis: body.orbitArgPeriapsis,
          meanAnomalyAtEpoch: meanAnomaly ?? body.orbitPhase,
        ),
        body: parent.id,
        mu: parent.mu,
        epoch: Epoch.zero,
      );
}
