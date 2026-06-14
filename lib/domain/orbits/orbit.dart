import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import 'orbital_elements.dart';

/// A conic orbit about a specific [body], anchored at an [epoch]. Combines the
/// pure geometry ([elements]) with the body's gravity and a time anchor so it
/// can be propagated. Value object — propagation produces state, never mutates
/// the orbit.
class Orbit {
  final OrbitalElements elements;
  final BodyId body;
  final double mu;
  final Epoch epoch;

  const Orbit({
    required this.elements,
    required this.body,
    required this.mu,
    required this.epoch,
  });

  double get period => elements.period(mu);
  double get periapsis => elements.periapsis;
  double get apoapsis => elements.apoapsis;

  /// Mean anomaly at an arbitrary time, wrapped to [0, 2pi) for closed orbits.
  double meanAnomalyAt(Epoch t) {
    final dt = t.secondsSince(epoch);
    return elements.meanAnomalyAtEpoch + elements.meanMotion(mu) * dt;
  }

  @override
  String toString() => 'Orbit(body:$body, $elements)';
}
