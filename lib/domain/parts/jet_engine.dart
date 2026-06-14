import 'dart:math' as math;

import '../universe/atmosphere_model.dart';

/// An air-breathing jet engine (turbojet/turbofan/ramjet). Unlike a rocket it
/// carries no oxidizer — it ingests atmospheric air, so thrust depends on air
/// density and forward speed (ram effect) and it flames out in vacuum or when
/// starved of intake air. Real-world grounded: thrust rises with Mach toward an
/// [optimalMach] (ram compression), then falls as the inlet can no longer slow
/// the flow efficiently.
class JetEngine {
  final String name;

  /// Static thrust (N) at sea-level density, zero airspeed, full throttle.
  final double maxStaticThrust;

  /// Mach number at which the ram boost peaks.
  final double optimalMach;

  /// Peak thrust multiplier at [optimalMach] (e.g. 2.5 = 2.5x static).
  final double machThrustMultiplier;

  /// Intake air (normalized units) the engine needs to run; below this it
  /// flames out. The vessel's intakes supply this.
  final double intakeAreaRequired;

  /// Sea-level reference density used to scale thrust with ambient density.
  final double referenceDensity;

  const JetEngine({
    required this.name,
    required this.maxStaticThrust,
    this.optimalMach = 1.0,
    this.machThrustMultiplier = 1.5,
    this.intakeAreaRequired = 0.0,
    this.referenceDensity = 1.225,
  });

  /// Thrust (N) for current conditions. Returns 0 on flame-out (no air / too
  /// little intake).
  double thrust({
    required AtmosphereSample ambient,
    required double machNumber,
    required double throttle,
    required double intakeAirAvailable,
  }) {
    if (ambient.density <= 0) return 0; // vacuum: no air to breathe
    if (intakeAirAvailable < intakeAreaRequired) return 0; // air-starved

    final densityRatio = (ambient.density / referenceDensity).clamp(0.0, 2.0);
    final ram = _ramFactor(machNumber);
    final thr = maxStaticThrust * densityRatio * ram * throttle.clamp(0.0, 1.0);
    return math.max(0, thr);
  }

  /// Mach -> thrust multiplier. 1.0 at static, peaks at [machThrustMultiplier]
  /// at [optimalMach], decaying back below 1 well past it (inlet unstart).
  double _ramFactor(double mach) {
    if (mach <= 0) return 1.0;
    if (mach <= optimalMach) {
      // Linear rise from 1.0 to the peak multiplier.
      final f = mach / optimalMach;
      return 1.0 + (machThrustMultiplier - 1.0) * f;
    }
    // Decay past optimal: lose the boost over the next ~optimalMach of Mach.
    final over = (mach - optimalMach) / optimalMach;
    final factor = machThrustMultiplier - (machThrustMultiplier) * over;
    return math.max(0.0, factor);
  }
}
