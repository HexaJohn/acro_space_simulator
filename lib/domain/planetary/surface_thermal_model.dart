import 'dart:math' as math;

import 'planet_surface.dart';

/// Mutable thermal state of one surface cell — its current temperature, biome,
/// and whether an ocean cell has frozen over.
class SurfaceCellThermal {
  double temperature; // K
  final Biome biome;
  bool frozen;

  SurfaceCellThermal({
    required this.temperature,
    required this.biome,
    this.frozen = false,
  });
}

/// Evolves surface-cell temperature with thermal inertia. Oceans have an
/// enormous effective heat capacity (water's high specific heat + depth), so
/// they warm/cool slowly and MODERATE climate — buffering day/night and seasonal
/// swings — while deserts/rock respond almost immediately. Below the freezing
/// point an ocean cell turns to ice ([frozen]); it thaws once it warms back.
///
/// Model: exponential relaxation toward the [equilibriumTemperature] with a
/// biome-specific time constant tau (seconds). dT = (Teq - T) * (1 - exp(-dt/tau)).
class SurfaceThermalModel {
  const SurfaceThermalModel();

  static const double freezingPoint = 273.16; // K

  void advance(
    SurfaceCellThermal cell, {
    required double equilibriumTemperature,
    required double dt,
  }) {
    final tau = _timeConstant(cell.biome);
    final response = 1.0 - math.exp(-dt / tau);
    cell.temperature += (equilibriumTemperature - cell.temperature) * response;

    // Ocean freeze/thaw bookkeeping.
    if (cell.biome == Biome.ocean) {
      if (cell.temperature < freezingPoint) {
        cell.frozen = true;
      } else if (cell.temperature > freezingPoint + 0.5) {
        cell.frozen = false;
      }
    }
  }

  /// Thermal time constant (s) per biome — bigger = more inertia / moderation.
  double _timeConstant(Biome biome) {
    switch (biome) {
      case Biome.ocean:
        return 2.0e6; // ~23 days: deep water buffers strongly
      case Biome.iceCap:
        return 8.0e5;
      case Biome.tundra:
      case Biome.forest:
      case Biome.grassland:
      case Biome.wetland:
      case Biome.coastal:
        return 1.5e5;
      case Biome.mountains:
      case Biome.desert:
      case Biome.barren:
      case Biome.volcanic:
      case Biome.volcano:
        return 5.0e4; // dry rock/sand responds fast
    }
  }
}
