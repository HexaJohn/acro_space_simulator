import '../shared/vector3.dart';
import 'force_model.dart';
import 'mass_properties.dart';
import 'state_vector.dart';

/// Numeric ("physics mode") propagation: step a 6-DOF [StateVector] forward
/// under a [ForceModel]. Used whenever a vessel is perturbed (thrust, drag,
/// contact) and can't stay on Keplerian rails.
///
/// Port so the heavy inner loop can later move to Rust FFI without touching
/// callers — this is exactly the "super heavy calculation" boundary mentioned.
abstract class Integrator {
  StateVector step(
    StateVector state,
    ForceModel forces,
    MassProperties mass,
    double dt,
  );
}

/// Classic 4th-order Runge-Kutta over the translational state, with attitude
/// advanced from angular velocity. Good accuracy/cost tradeoff for short steps
/// under thrust; for long ballistic coasts the Kepler propagator is preferred.
class Rk4Integrator implements Integrator {
  const Rk4Integrator();

  @override
  StateVector step(
    StateVector state,
    ForceModel forces,
    MassProperties mass,
    double dt,
  ) {
    final m = mass.mass <= 0 ? 1.0 : mass.mass;

    // Derivative of (position, velocity) at a trial state.
    (Vector3, Vector3) deriv(Vector3 pos, Vector3 vel) {
      final trial = state.copyWith(position: pos, velocity: vel);
      final gf = forces.netForce(trial, mass);
      return (vel, gf.force / m); // dx/dt = v ; dv/dt = F/m
    }

    final (k1x, k1v) = deriv(state.position, state.velocity);
    final (k2x, k2v) = deriv(
      state.position + k1x * (dt / 2),
      state.velocity + k1v * (dt / 2),
    );
    final (k3x, k3v) = deriv(
      state.position + k2x * (dt / 2),
      state.velocity + k2v * (dt / 2),
    );
    final (k4x, k4v) = deriv(
      state.position + k3x * dt,
      state.velocity + k3v * dt,
    );

    final newPos = state.position +
        (k1x + k2x * 2 + k3x * 2 + k4x) * (dt / 6);
    final newVel = state.velocity +
        (k1v + k2v * 2 + k3v * 2 + k4v) * (dt / 6);

    // Rotational: integrate attitude from angular velocity, apply angular accel
    // from the net torque (about principal axes).
    final torque = forces.netForce(state, mass).torque;
    final newOmega = state.angularVelocity + mass.angularAccel(torque) * dt;
    final qDot = state.attitude.derivative(state.angularVelocity);
    final newAtt = (state.attitude + qDot.scaled(dt)).normalized;

    return StateVector(
      position: newPos,
      velocity: newVel,
      attitude: newAtt,
      angularVelocity: newOmega,
    );
  }
}

/// Semi-implicit (symplectic) Euler — cheaper than RK4 and energy-stable over
/// long runs, so it's the better default for many simultaneously-simulated
/// vessels. Kept alongside RK4 so the tick can choose per vessel.
class SymplecticEulerIntegrator implements Integrator {
  const SymplecticEulerIntegrator();

  @override
  StateVector step(
    StateVector state,
    ForceModel forces,
    MassProperties mass,
    double dt,
  ) {
    final m = mass.mass <= 0 ? 1.0 : mass.mass;
    final gf = forces.netForce(state, mass);
    final newVel = state.velocity + (gf.force / m) * dt;
    final newPos = state.position + newVel * dt; // uses updated velocity
    final newOmega = state.angularVelocity + mass.angularAccel(gf.torque) * dt;
    final qDot = state.attitude.derivative(newOmega);
    final newAtt = (state.attitude + qDot.scaled(dt)).normalized;
    return StateVector(
      position: newPos,
      velocity: newVel,
      attitude: newAtt,
      angularVelocity: newOmega,
    );
  }
}
