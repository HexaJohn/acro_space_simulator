import '../dynamics/state_vector.dart';
import '../simulation/epoch.dart';
import 'orbit.dart';
import 'state_vector_converter.dart';

/// Analytic ("on-rails") propagation: advance an [Orbit] to any epoch by
/// solving Kepler's equation. O(1) regardless of dt — this is what makes
/// timewarp and distant-vessel simulation cheap.
///
/// Port: implementations may swap in a faster solver (or a Rust FFI one) later
/// without callers changing. The default impl delegates to the converter.
abstract class KeplerPropagator {
  StateVector propagate(Orbit orbit, Epoch to);
}

class AnalyticKeplerPropagator implements KeplerPropagator {
  final StateVectorOrbitConverter _converter;
  const AnalyticKeplerPropagator(
      [this._converter = const StateVectorOrbitConverter()]);

  @override
  StateVector propagate(Orbit orbit, Epoch to) =>
      _converter.toStateVector(orbit, to);
}
