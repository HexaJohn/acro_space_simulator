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
