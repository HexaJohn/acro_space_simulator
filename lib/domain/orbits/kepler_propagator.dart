// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
