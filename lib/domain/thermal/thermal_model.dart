import 'dart:math' as math;

import '../shared/units.dart';
import '../universe/atmosphere_model.dart';
import 'thermal_state.dart';

/// Computes heat fluxes on a part and advances its temperature. Domain service.
/// Sources/sinks modelled:
///   * solar irradiance (absorbed fraction of incident flux),
///   * radiative cooling to space (Stefan-Boltzmann, T^4),
///   * aerodynamic/reentry heating (stagnation heating ~ rho * v^3),
///   * convective exchange with ambient atmosphere toward its temperature.
///
/// This is a heavy per-part loop at scale — a prime candidate to move behind
/// the compute port to Rust FFI later.
class ThermalModel {
  const ThermalModel();

  /// Net heat flux (W) on a part this tick, then integrate it into [state].
  void advance(
    PartThermalState state, {
    required double dt,
    required double solarFlux, // W/m^2 incident (0 in shadow)
    required double solarFacingFraction, // 0..1 of area lit
    required AtmosphereSample ambient,
    required double airspeed, // m/s relative to atmosphere
    double gasHeatingFactor = 1.0, // composition: heavier gas heats more
  }) {
    final a = state.surfaceArea;
    final t = state.temperature;

    // Absorbed solar.
    final qSolar = solarFlux * a * solarFacingFraction * state.emissivity;

    // Radiative cooling to ~2.7 K space: Q = eps * sigma * A * (T^4 - Tspace^4).
    final qRadiate = -state.emissivity *
        stefanBoltzmann *
        a *
        (math.pow(t, 4).toDouble() - math.pow(2.7, 4).toDouble());

    // Reentry stagnation heating: empirical q ~ k * rho * v^3, scaled by the
    // atmospheric gas-heating factor (a CO2-rich/heavy atmosphere transfers more
    // stagnation heat than a light H2/He one at the same density and speed).
    var qReentry = 0.0;
    if (ambient.density > 0 && airspeed > 0) {
      const k = 1.83e-4; // tuning constant for gameplay feel
      qReentry = k *
          math.sqrt(ambient.density) *
          math.pow(airspeed, 3).toDouble() *
          a *
          gasHeatingFactor;
    }

    // Ablative heat shield: spend ablator to soak up reentry heat before it
    // reaches the part. Operates on energy (W * dt); leftover passes through.
    if (qReentry > 0 && state.hasAblator) {
      final incoming = qReentry * dt; // J this step
      final passedThrough = state.absorbWithAblator(incoming);
      qReentry = dt > 0 ? passedThrough / dt : 0; // back to W
    }

    // Convective exchange toward ambient temperature. The convection
    // coefficient rises with airspeed (forced convection: faster airflow strips
    // the boundary layer, transferring heat faster ~ a + b*v).
    var qConvect = 0.0;
    if (ambient.density > 0) {
      const hStill = 20.0; // free-convection floor, W/m^2/K
      const hPerSpeed = 0.6; // forced-convection gain per m/s
      final h = hStill + hPerSpeed * airspeed.abs();
      qConvect = h * a * (ambient.temperature - t) * ambient.density;
    }

    final net = qSolar + qRadiate + qReentry + qConvect;
    state.applyHeat(net, dt);
  }

  /// Whether the part should be destroyed (over max temperature).
  bool exceedsLimit(PartThermalState state) =>
      Kelvin(state.temperature).exceeds(Kelvin(state.maxTemperature));
}
