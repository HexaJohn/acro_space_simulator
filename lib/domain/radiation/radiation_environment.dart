import '../planetary/magnetosphere.dart';
import '../shared/vector3.dart';

/// Ionizing-radiation dose rate (sieverts/second) at a point in space, from the
/// three dominant sources for a crewed spacecraft:
///   * galactic cosmic-ray background — small, omnipresent;
///   * trapped-particle radiation belts (Van Allen) — large, near magnetized
///     bodies, peaks in a mid-altitude shell;
///   * solar particles — scales with local solar flux, spikes during a flare.
/// Shielding (0..1) linearly attenuates the total.
///
/// Domain service — pure. Tuned for gameplay-scale doses (a belt pass should be
/// dangerous over minutes, deep space survivable for a long mission).
class RadiationEnvironment {
  /// Galactic cosmic-ray background dose rate (Sv/s).
  final double cosmicBackground;

  /// Peak belt dose rate at full belt intensity (Sv/s).
  final double beltPeak;

  /// Solar dose coefficient: Sv/s per (W/m^2) of local solar flux.
  final double solarCoefficient;

  /// Extra multiplier on the solar term during a flare.
  final double flareMultiplier;

  const RadiationEnvironment({
    this.cosmicBackground = 1.0e-8, // ~0.3 Sv/yr deep-space GCR
    this.beltPeak = 5.0e-3, // belt pass is dangerous in minutes
    this.solarCoefficient = 5.0e-10,
    this.flareMultiplier = 50.0,
  });

  /// Dose rate (Sv/s). [solarFlare] in 0..1 scales an active flare's intensity.
  double doseRate({
    required Vector3 position,
    required Magnetosphere? magnetosphere,
    required double solarFlux,
    required double shielding,
    double solarFlare = 0,
  }) {
    var dose = cosmicBackground;

    // Trapped-belt contribution.
    if (magnetosphere != null) {
      dose += beltPeak * magnetosphere.radiationBeltIntensity(position);
    }

    // Solar particle contribution, amplified during a flare.
    final flare = 1.0 + solarFlare.clamp(0.0, 1.0) * (flareMultiplier - 1.0);
    dose += solarCoefficient * solarFlux * flare;

    // Shielding attenuates the total.
    final pass = (1.0 - shielding.clamp(0.0, 1.0));
    return dose * pass;
  }
}
