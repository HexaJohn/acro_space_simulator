import '../../domain/dynamics/force_model.dart';
import '../../domain/dynamics/integrator.dart';
import '../../domain/dynamics/mass_properties.dart';
import '../../domain/dynamics/state_vector.dart';
import '../../domain/orbits/kepler_propagator.dart';
import '../../domain/orbits/orbit.dart';
import '../../domain/simulation/epoch.dart';

/// The performance boundary.
///
/// All heavy numeric work the simulation needs is expressed through this port.
/// Today it is backed by the pure-Dart domain services; when profiling shows a
/// bottleneck (N-body batches, thousands of vessels, thermal grids), a single
/// adapter implementation can route these calls to Rust over flutter_rust_bridge
/// WITHOUT any caller changing. That is the whole point of putting it behind a
/// port instead of calling integrators/propagators directly from use cases.
abstract class ComputePort {
  /// Numeric 6-DOF step (physics mode).
  StateVector integrate(
    StateVector state,
    ForceModel forces,
    MassProperties mass,
    double dt,
  );

  /// Analytic Kepler step (on-rails mode).
  StateVector propagate(Orbit orbit, Epoch to);

  /// Batch propagate many orbits to one epoch — the obvious thing to vectorize
  /// in Rust. Default callers use this for all on-rails vessels at once.
  List<StateVector> propagateBatch(List<Orbit> orbits, Epoch to);
}

/// Default Dart implementation: delegates to the domain services. Swap for a
/// `RustComputeAdapter` later. Lives near the port (it is the reference impl).
class DartCompute implements ComputePort {
  final Integrator _integrator;
  final KeplerPropagator _kepler;

  DartCompute({
    Integrator? integrator,
    KeplerPropagator? kepler,
  })  : _integrator = integrator ?? const Rk4Integrator(),
        _kepler = kepler ?? const AnalyticKeplerPropagator();

  @override
  StateVector integrate(
    StateVector state,
    ForceModel forces,
    MassProperties mass,
    double dt,
  ) =>
      _integrator.step(state, forces, mass, dt);

  @override
  StateVector propagate(Orbit orbit, Epoch to) => _kepler.propagate(orbit, to);

  @override
  List<StateVector> propagateBatch(List<Orbit> orbits, Epoch to) =>
      [for (final o in orbits) _kepler.propagate(o, to)];
}
