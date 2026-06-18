import 'dart:math' as math;

import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import 'state_vector_converter.dart';

/// Samples a vessel's future orbital path for display (the "where will I go"
/// line). Domain service — pure analytic propagation, so it is cheap and exact
/// for the conic, independent of the physics tick.
///
/// For a closed orbit it samples one full period; for an open (escape)
/// trajectory it samples a bounded time horizon ahead. Returns body-centred
/// inertial points the presenter projects to the screen.
class TrajectoryService {
  final StateVectorOrbitConverter converter;
  const TrajectoryService([this.converter = const StateVectorOrbitConverter()]);

  List<Vector3> predictPath({
    required Vector3 position,
    required Vector3 velocity,
    required CelestialBody body,
    required Epoch epoch,
    int samples = 48,
    double openHorizonSeconds = 6000,
  }) {
    final orbit = converter.toOrbit(
      position: position,
      velocity: velocity,
      body: body,
      epoch: epoch,
    );

    // Open (escape) orbits: the elliptical Kepler solver doesn't apply, so draw
    // a short gravity-aware ballistic preview instead of an analytic conic.
    if (orbit.elements.eccentricity >= 1.0) {
      return _ballisticPreview(
        position: position,
        velocity: velocity,
        body: body,
        samples: samples,
        horizon: openHorizonSeconds,
      );
    }

    // Sample at a FIXED phase (from periapsis) rather than from the craft's
    // current anomaly, so vertices don't slide around the ellipse as the craft
    // moves; the craft still lies on the line (converter round-trips position).
    final n = orbit.elements.meanMotion(orbit.mu);
    final periapsisEpoch = n.abs() < 1e-12
        ? epoch.seconds
        : epoch.seconds - orbit.elements.meanAnomalyAtEpoch / n;

    // Space samples uniformly in ECCENTRIC ANOMALY, not time. Uniform-time
    // spacing = uniform mean anomaly, which (Kepler's 2nd law) clusters points at
    // apoapsis and starves periapsis — exactly where a high-eccentricity orbit
    // bends hardest, giving the sharp facets. Uniform E spreads vertices evenly
    // around the ellipse geometrically. Each E maps to a time via Kepler:
    //   M = E - e*sin(E),  t = periapsisEpoch + M / n.
    final e = orbit.elements.eccentricity;
    final points = <Vector3>[];
    final hasN = n.abs() >= 1e-12;
    for (var i = 0; i <= samples; i++) {
      final eAnom = (i / samples) * 2 * math.pi; // 0..2pi from periapsis
      final tSec = hasN
          ? periapsisEpoch + (eAnom - e * math.sin(eAnom)) / n
          : periapsisEpoch;
      final s = converter.toStateVector(orbit, Epoch(tSec));
      if (s.position.x.isFinite && s.position.y.isFinite && s.position.z.isFinite) {
        points.add(s.position);
      }
    }
    return points;
  }

  /// Adaptive screen-space sampling: like [predictPath], but recursively
  /// subdivides each arc until its endpoints are within [maxSegPx] of each other
  /// ON SCREEN (via [projectPx], which maps a body-centred point to screen px, or
  /// null if culled). Detail concentrates automatically where the line is long on
  /// screen — near the craft when zoomed in, and at the sharp TURNING POINTS
  /// (periapsis especially) of a high-eccentricity orbit, where the curve bends
  /// hardest and a uniform sampling would facet. Stays sparse on far / straight
  /// arcs. [coarseSamples] seeds the recursion; [maxDepth] bounds it so a
  /// pathological case can't explode (a deeper cap lets the tight periapsis of an
  /// extreme ellipse resolve smoothly).
  List<Vector3> predictPathAdaptive({
    required Vector3 position,
    required Vector3 velocity,
    required CelestialBody body,
    required Epoch epoch,
    required ({double x, double y})? Function(Vector3) projectPx,
    double maxSegPx = 12,
    int coarseSamples = 24,
    int maxDepth = 10,
    double openHorizonSeconds = 6000,
  }) {
    final orbit = converter.toOrbit(
      position: position,
      velocity: velocity,
      body: body,
      epoch: epoch,
    );
    // Open trajectories: fall back to the (already fine) ballistic preview.
    if (orbit.elements.eccentricity >= 1.0) {
      return _ballisticPreview(
        position: position,
        velocity: velocity,
        body: body,
        samples: coarseSamples * 4,
        horizon: openHorizonSeconds,
      );
    }

    final n = orbit.elements.meanMotion(orbit.mu);
    final hasN = n.abs() >= 1e-12;
    final periapsisEpoch = hasN
        ? epoch.seconds - orbit.elements.meanAnomalyAtEpoch / n
        : epoch.seconds;
    final e = orbit.elements.eccentricity;

    // Body-centred point at eccentric anomaly E (0..2pi from periapsis).
    Vector3 at(double eAnom) {
      final tSec =
          hasN ? periapsisEpoch + (eAnom - e * math.sin(eAnom)) / n : periapsisEpoch;
      return converter.toStateVector(orbit, Epoch(tSec)).position;
    }

    bool finite(Vector3 v) => v.x.isFinite && v.y.isFinite && v.z.isFinite;
    double? sqDist(({double x, double y})? a, ({double x, double y})? b) {
      if (a == null || b == null) return null; // culled endpoint -> always split
      final dx = a.x - b.x, dy = a.y - b.y;
      return dx * dx + dy * dy;
    }

    final maxSq = maxSegPx * maxSegPx;
    final pts = <Vector3>[];

    // Recursively bisect [e0,e1] in eccentric anomaly until short on screen.
    void recurse(double e0, Vector3 p0, ({double x, double y})? s0, double e1,
        Vector3 p1, ({double x, double y})? s1, int depth) {
      final d = sqDist(s0, s1);
      // Split when too long on screen (or an endpoint is culled and we still have
      // depth) — null distance forces a split so a partly-visible arc fills in.
      final tooLong = d == null || d > maxSq;
      if (depth < maxDepth && tooLong) {
        final em = (e0 + e1) / 2;
        final pm = at(em);
        final sm = finite(pm) ? projectPx(pm) : null;
        recurse(e0, p0, s0, em, pm, sm, depth + 1);
        if (finite(pm)) pts.add(pm);
        recurse(em, pm, sm, e1, p1, s1, depth + 1);
      }
    }

    // Seed with a coarse uniform-E ring, then refine each coarse arc.
    var ePrev = 0.0;
    var pPrev = at(ePrev);
    var sPrev = finite(pPrev) ? projectPx(pPrev) : null;
    if (finite(pPrev)) pts.add(pPrev);
    for (var i = 1; i <= coarseSamples; i++) {
      final eCur = (i / coarseSamples) * 2 * math.pi;
      final pCur = at(eCur);
      final sCur = finite(pCur) ? projectPx(pCur) : null;
      recurse(ePrev, pPrev, sPrev, eCur, pCur, sCur, 0);
      if (finite(pCur)) pts.add(pCur);
      ePrev = eCur;
      pPrev = pCur;
      sPrev = sCur;
    }
    return pts;
  }

  /// Cheap forward Euler under point-mass gravity — a visual preview for open
  /// trajectories the conic solver can't propagate analytically.
  List<Vector3> _ballisticPreview({
    required Vector3 position,
    required Vector3 velocity,
    required CelestialBody body,
    required int samples,
    required double horizon,
  }) {
    final points = <Vector3>[];
    var p = position;
    var v = velocity;
    final dt = horizon / samples;
    for (var i = 0; i < samples; i++) {
      v = v + body.gravityAt(p) * dt;
      p = p + v * dt;
      if (p.x.isFinite && p.y.isFinite && p.z.isFinite) points.add(p);
    }
    return points;
  }
}
