// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import '../universe/star_system.dart';
import 'body_ephemeris.dart';
import 'orbit.dart';
import 'soi_transition_service.dart';
import 'state_vector_converter.dart';

/// Why a [ConicPatch] stops where it does.
enum PatchEndKind {
  /// A closed ellipse with no SOI event inside one revolution — the patch is
  /// the whole orbit and there is nothing after it.
  closed,

  /// The conic leaves the current body's sphere of influence; the next patch
  /// continues in the parent's frame.
  escape,

  /// The conic enters a child body's sphere of influence; the next patch
  /// continues in the child's frame.
  encounter,

  /// The conic intersects the body's surface. Prediction stops.
  impact,

  /// Ran out of prediction window (root-frame escape trajectories, or an SOI
  /// handoff the transition service declined at the boundary).
  horizon,
}

/// One conic leg of a patched-conic trajectory: the samples of a single
/// Keplerian arc in ONE body's centred-inertial frame, plus why it ended and
/// which frame the trajectory continues in.
class ConicPatch {
  /// The frame body this leg orbits. Points are centred on it.
  final BodyId body;

  /// Time-ordered body-centred inertial samples (metres). For a [PatchEndKind.closed]
  /// patch this is the full ellipse sampled at uniform eccentric anomaly from
  /// periapsis (fixed phase — vertices don't slide as the craft moves); for
  /// every other kind it runs from the craft's state at [startSeconds] to the
  /// boundary state at [endSeconds].
  final List<Vector3> points;

  final double startSeconds;
  final double endSeconds;
  final PatchEndKind end;

  /// The frame the NEXT patch lives in ([PatchEndKind.escape]/[PatchEndKind.encounter]).
  final BodyId? nextBody;

  const ConicPatch({
    required this.body,
    required this.points,
    required this.startSeconds,
    required this.endSeconds,
    required this.end,
    this.nextBody,
  });
}

/// Patched-conic trajectory prediction: propagates a craft's current conic to
/// the FIRST sphere-of-influence event (escape past the current body's SOI,
/// encounter with a child body's SOI, or surface impact), performs the same
/// Galilean frame handoff the live [SoiTransitionService] applies, and
/// continues the prediction as a new conic in the next frame — so the "where
/// will I go" line shows the handoff as an extension of the current orbit
/// instead of the orbit silently changing at the boundary.
///
/// Domain service, display-oriented: escape and impact epochs are solved
/// analytically from the conic (no sampling error); encounters — which depend
/// on where the child body will BE — are found by scanning the leg in time
/// against the real [BodyEphemeris] and refining the crossing by bisection.
/// Encounter search covers ONE revolution of the current conic (an encounter
/// three revolutions out is not predicted — matching how far the drawn line
/// can honestly claim to know the future under thrust and drift).
class PatchedConicService {
  final StateVectorOrbitConverter converter;
  final BodyEphemeris ephemeris;
  final SoiTransitionService soi;

  const PatchedConicService({
    this.converter = const StateVectorOrbitConverter(),
    this.ephemeris = const BodyEphemeris(),
    this.soi = const SoiTransitionService(),
  });

  /// Predict up to [maxPatches] conic legs starting from a body-centred state.
  ///
  /// [rootHorizonSeconds] bounds the final leg of a trajectory that escapes
  /// into a frame with no SOI edge to stop at (the root star): display only,
  /// so a year of coast is plenty.
  List<ConicPatch> predict({
    required Vector3 position,
    required Vector3 velocity,
    required CelestialBody body,
    required StarSystem system,
    required Epoch epoch,
    int maxPatches = 3,
    int pointsPerPatch = 96,
    int encounterScanSamples = 192,
    double rootHorizonSeconds = 3.15e7,
  }) {
    final patches = <ConicPatch>[];
    var pos = position;
    var vel = velocity;
    var cur = body;
    var t0 = epoch.seconds;

    for (var k = 0; k < maxPatches; k++) {
      final orbit = converter.toOrbit(
          position: pos, velocity: vel, body: cur, epoch: Epoch(t0));
      final el = orbit.elements;
      final n = el.meanMotion(orbit.mu);
      if (!n.isFinite || n <= 0) break; // degenerate (zero-radius) orbit

      final elliptical = el.eccentricity < 1.0;
      final period = orbit.period;

      // Analytic event epochs on this conic (absolute seconds, or null).
      final tEscape = _escapeEpoch(orbit, cur, system, t0);
      final tImpact = _impactEpoch(orbit, cur, t0);

      // The window an encounter must fall inside to beat the analytic events:
      // one revolution for a closed orbit, to the SOI exit for an open one,
      // capped by impact and (for the root frame) the display horizon.
      var scanEnd = elliptical ? t0 + period : t0 + rootHorizonSeconds;
      if (tEscape != null) scanEnd = math.min(scanEnd, tEscape);
      if (tImpact != null) scanEnd = math.min(scanEnd, tImpact);

      final enc = _firstEncounter(
          orbit, cur, system, t0, scanEnd, encounterScanSamples);

      // Earliest event wins.
      double? tEvent;
      var kind = PatchEndKind.closed;
      if (enc != null) {
        tEvent = enc;
        kind = PatchEndKind.encounter;
      }
      if (tImpact != null && (tEvent == null || tImpact < tEvent)) {
        tEvent = tImpact;
        kind = PatchEndKind.impact;
      }
      if (tEscape != null && (tEvent == null || tEscape < tEvent)) {
        tEvent = tEscape;
        kind = PatchEndKind.escape;
      }

      if (tEvent == null) {
        // No event: a closed ellipse is the whole story; an open root-frame
        // trajectory just runs out of window.
        if (elliptical) {
          patches.add(ConicPatch(
            body: cur.id,
            points: _closedEllipsePoints(orbit, t0, pointsPerPatch),
            startSeconds: t0,
            endSeconds: t0 + period,
            end: PatchEndKind.closed,
          ));
        } else {
          patches.add(ConicPatch(
            body: cur.id,
            points: _arcPoints(orbit, t0, scanEnd, pointsPerPatch),
            startSeconds: t0,
            endSeconds: scanEnd,
            end: PatchEndKind.horizon,
          ));
        }
        break;
      }

      if (kind == PatchEndKind.impact) {
        patches.add(ConicPatch(
          body: cur.id,
          points: _arcPoints(orbit, t0, tEvent, pointsPerPatch),
          startSeconds: t0,
          endSeconds: tEvent,
          end: PatchEndKind.impact,
        ));
        break;
      }

      // SOI handoff: hand the boundary state to the SAME service the live sim
      // uses, nudging forward across the boundary until it fires (the analytic
      // epoch sits exactly ON the edge, where resolve sees neither side).
      final res = _resolveAcrossBoundary(orbit, cur, system, t0, tEvent);
      if (res == null) {
        patches.add(ConicPatch(
          body: cur.id,
          points: _arcPoints(orbit, t0, tEvent, pointsPerPatch),
          startSeconds: t0,
          endSeconds: tEvent,
          end: PatchEndKind.horizon,
        ));
        break;
      }

      patches.add(ConicPatch(
        body: cur.id,
        points: _arcPoints(orbit, t0, res.epochSeconds, pointsPerPatch),
        startSeconds: t0,
        endSeconds: res.epochSeconds,
        end: kind,
        nextBody: res.result.newBody.id,
      ));

      pos = res.result.shiftedState.position;
      vel = res.result.shiftedState.velocity;
      cur = res.result.newBody;
      t0 = res.epochSeconds;
    }

    return patches;
  }

  // ---- Analytic event epochs ----

  /// Epoch at which the conic crosses the current body's SOI outbound, or null
  /// when it never does (bound orbit inside the SOI, or no SOI edge to cross —
  /// the root body with nothing to escape to).
  double? _escapeEpoch(
      Orbit orbit, CelestialBody cur, StarSystem system, double t0) {
    final rSoi = cur.soiRadius;
    if (!rSoi.isFinite || rSoi <= 0) return null;
    if (system.parentOf(cur) == null) return null; // nowhere to escape to
    final el = orbit.elements;
    final a = el.semiMajorAxis, e = el.eccentricity;
    final n = el.meanMotion(orbit.mu);

    if (e < 1.0) {
      if (el.apoapsis <= rSoi) return null; // never reaches the edge
      // r(E) = a(1 - e cos E) = rSoi -> E* on the outbound leg (0, pi).
      final eStar = math.acos(((1 - rSoi / a) / e).clamp(-1.0, 1.0));
      final mStar = eStar - e * math.sin(eStar);
      final m = _wrapTwoPi(orbit.meanAnomalyAt(Epoch(t0)));
      final dm = m <= mStar ? mStar - m : mStar + 2 * math.pi - m;
      return t0 + dm / n;
    }

    // Hyperbolic: always exits. cosh H* = (1 - rSoi/a)/e with a < 0, H* > 0.
    final coshH = math.max((1 - rSoi / a) / e, 1.0);
    final hStar = _acosh(coshH);
    final mStar = e * _sinh(hStar) - hStar;
    final m = orbit.meanAnomalyAt(Epoch(t0)); // unbounded, signed
    final dt = (mStar - m) / n;
    return t0 + math.max(dt, 0.0);
  }

  /// Epoch at which the conic descends through the body's surface radius, or
  /// null when the periapsis clears the surface (or the craft is already
  /// outbound past periapsis on an open trajectory).
  double? _impactEpoch(Orbit orbit, CelestialBody cur, double t0) {
    final r = cur.radius;
    if (r <= 0) return null;
    final el = orbit.elements;
    final a = el.semiMajorAxis, e = el.eccentricity;
    if (el.periapsis >= r) return null;
    final n = el.meanMotion(orbit.mu);

    if (e < 1.0) {
      // Underground band is |E| < Er around periapsis; the inbound crossing is
      // at E = 2pi - Er.
      final er = math.acos(((1 - r / a) / e).clamp(-1.0, 1.0));
      final eHit = 2 * math.pi - er;
      final mHit = eHit - e * math.sin(eHit);
      final m = _wrapTwoPi(orbit.meanAnomalyAt(Epoch(t0)));
      final dm = m <= mHit ? mHit - m : mHit + 2 * math.pi - m;
      return t0 + dm / n;
    }

    // Hyperbolic: only an INBOUND leg (M < 0) can still hit; the crossing is
    // at H = -Hr.
    final m = orbit.meanAnomalyAt(Epoch(t0));
    if (m >= 0) return null;
    final coshH = math.max((1 - r / a) / e, 1.0);
    final hr = _acosh(coshH);
    final mHit = -(e * _sinh(hr) - hr);
    final dt = (mHit - m) / orbit.elements.meanMotion(orbit.mu);
    return dt <= 0 ? t0 : t0 + dt;
  }

  // ---- Encounter search ----

  /// Earliest epoch in (t0, tEnd] at which the conic enters a child body's
  /// SOI, or null. Children whose orbital shell (orbit radius band +- SOI)
  /// cannot radially overlap the conic are rejected without any sampling.
  double? _firstEncounter(Orbit orbit, CelestialBody cur, StarSystem system,
      double t0, double tEnd, int samples) {
    if (tEnd <= t0) return null;
    final el = orbit.elements;
    final q = el.periapsis;
    final qMax = el.eccentricity < 1.0
        ? el.apoapsis
        : (cur.soiRadius.isFinite ? cur.soiRadius : double.infinity);

    final candidates = <CelestialBody>[
      for (final child in system.childrenOf(cur.id))
        if (child.soiRadius.isFinite &&
            child.soiRadius > 0 &&
            child.orbitRadius > 0 &&
            q <= child.orbitRadius * (1 + child.orbitEccentricity) +
                    child.soiRadius &&
            qMax >= child.orbitRadius * (1 - child.orbitEccentricity) -
                    child.soiRadius)
          child,
    ];
    if (candidates.isEmpty) return null;

    // Signed SOI-boundary distance to a child at epoch t (< 0 = inside).
    double dist(CelestialBody child, double t) {
      final craft = converter.toStateVector(orbit, Epoch(t)).position;
      final childPos =
          ephemeris.positionRelativeToParent(child, system, Epoch(t));
      return (craft - childPos).length - child.soiRadius;
    }

    final dt = (tEnd - t0) / samples;
    var tPrev = t0;
    for (var i = 1; i <= samples; i++) {
      final t = t0 + dt * i;
      double? best;
      for (final child in candidates) {
        if (dist(child, t) < 0) {
          // Bisect the crossing inside (tPrev, t].
          var lo = tPrev, hi = t;
          for (var j = 0; j < 48; j++) {
            final mid = (lo + hi) / 2;
            if (dist(child, mid) < 0) {
              hi = mid;
            } else {
              lo = mid;
            }
          }
          if (best == null || hi < best) best = hi;
        }
      }
      if (best != null) return best;
      tPrev = t;
    }
    return null;
  }

  // ---- Handoff ----

  /// Run [SoiTransitionService.resolve] at the boundary epoch, stepping the
  /// epoch forward in growing nudges until the propagated state is measurably
  /// PAST the boundary (the analytic crossing sits exactly on it).
  ({SoiTransitionResult result, double epochSeconds})? _resolveAcrossBoundary(
      Orbit orbit, CelestialBody cur, StarSystem system, double t0, double tX) {
    final scale = math.max(tX - t0, 1.0);
    for (final f in const [0.0, 1e-9, 1e-7, 1e-5, 1e-3]) {
      final t = tX + scale * f;
      final s = converter.toStateVector(orbit, Epoch(t));
      final res = soi.resolve(
          state: s, current: cur, system: system, epoch: Epoch(t));
      if (res != null) return (result: res, epochSeconds: t);
    }
    return null;
  }

  // ---- Sampling ----

  /// The full closed ellipse at uniform eccentric anomaly from periapsis
  /// (fixed phase, same convention as the single-conic path prediction).
  List<Vector3> _closedEllipsePoints(Orbit orbit, double t0, int samples) {
    final el = orbit.elements;
    final n = el.meanMotion(orbit.mu);
    final e = el.eccentricity;
    final periapsisEpoch = t0 - _wrapTwoPi(orbit.meanAnomalyAt(Epoch(t0))) / n;
    final pts = <Vector3>[];
    for (var i = 0; i <= samples; i++) {
      final eAnom = (i / samples) * 2 * math.pi;
      final t = periapsisEpoch + (eAnom - e * math.sin(eAnom)) / n;
      final p = converter.toStateVector(orbit, Epoch(t)).position;
      if (p.x.isFinite && p.y.isFinite && p.z.isFinite) pts.add(p);
    }
    return pts;
  }

  /// The conic arc from [tA] to [tB], sampled uniformly in time (bounded legs
  /// are short arcs; the renderers densify on screen where needed).
  List<Vector3> _arcPoints(Orbit orbit, double tA, double tB, int samples) {
    final pts = <Vector3>[];
    for (var i = 0; i <= samples; i++) {
      final t = tA + (tB - tA) * i / samples;
      final p = converter.toStateVector(orbit, Epoch(t)).position;
      if (p.x.isFinite && p.y.isFinite && p.z.isFinite) pts.add(p);
    }
    return pts;
  }

  static double _wrapTwoPi(double a) {
    final twoPi = 2 * math.pi;
    var r = a % twoPi;
    if (r < 0) r += twoPi;
    return r;
  }

  static double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;
  static double _acosh(double x) => math.log(x + math.sqrt(x * x - 1));
}
