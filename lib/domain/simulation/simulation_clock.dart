import 'epoch.dart';

/// The simulation's authoritative time and timewarp. Domain value/entity: maps
/// real wall-clock delta to simulation delta via [warpFactor], and counts fixed
/// ticks for determinism (multiplayer + replay need fixed-step).
class SimulationClock {
  Epoch epoch;
  int tick;

  /// Multiplier on real time. 1 = real-time; 1000 = heavy timewarp. Above a
  /// threshold the tick forces vessels onto Kepler rails (physics can't keep up).
  double warpFactor;

  /// Fixed physics step in simulation seconds (determinism). Render can be
  /// decoupled and interpolate between ticks.
  final double fixedStep;

  SimulationClock({
    this.epoch = Epoch.zero,
    this.tick = 0,
    this.warpFactor = 1.0,
    this.fixedStep = 0.02, // 50 Hz
  });

  /// Simulation seconds advanced per fixed step at the current warp.
  double get simStep => fixedStep * warpFactor;

  /// Advance one fixed tick; returns the dt (sim seconds) that elapsed.
  double advance() {
    final dt = simStep;
    epoch = epoch + dt;
    tick++;
    return dt;
  }

  /// Above this warp, real-time physics is abandoned for analytic rails.
  static const double railsWarpThreshold = 4.0;
  bool get forcesRails => warpFactor > railsWarpThreshold;
}
