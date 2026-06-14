import 'planet_surface.dart';

/// Biome-aware surface-contact outcomes: water cushions a touchdown (a splash
/// tolerates far higher speed than a hard-ground impact) and quenches reentry
/// heat, while ice is firm-but-forgiving and rock/desert is unforgiving. Domain
/// service used by the tick's surface-contact handling.
class SplashdownService {
  final double landSafeSpeed; // m/s safe on solid ground
  final double waterSafeSpeed; // m/s safe on water

  const SplashdownService({
    this.landSafeSpeed = 12,
    this.waterSafeSpeed = 30,
  });

  /// Hard upper bound: nothing survives slamming into water this fast.
  static const double waterLethalSpeed = 80;

  /// Safe touchdown speed for a biome.
  double safeSpeedFor(Biome biome) {
    switch (biome) {
      case Biome.ocean:
        return waterSafeSpeed;
      case Biome.iceCap:
        return (landSafeSpeed + waterSafeSpeed) / 2; // firm but forgiving
      default:
        return landSafeSpeed;
    }
  }

  /// Whether a touchdown at [speed] onto [biome] is survivable.
  bool survives({required Biome biome, required double speed}) {
    if (biome == Biome.ocean && speed > waterLethalSpeed) return false;
    return speed <= safeSpeedFor(biome);
  }

  /// Fraction of a part's heat removed on contact (water quenches; land doesn't).
  double heatQuenchFraction(Biome biome) =>
      biome == Biome.ocean ? 0.7 : 0.0;

  /// Survives a touchdown at [speed] given an already-resolved [safeSpeed].
  bool survivesSpeed(double speed, double safeSpeed) => speed <= safeSpeed;
}
