import '../vessel/part.dart';

/// Temperature of one part. Lives in the thermal context keyed by [PartId] so
/// thermal concerns don't bloat the structural [Part]. Entity in the vessel's
/// thermal aggregate.
class PartThermalState {
  final PartId part;
  double temperature; // K
  final double heatCapacity; // J/K (mass * specific heat)
  final double maxTemperature; // K, destruction threshold
  final double emissivity; // 0..1 radiative
  final double surfaceArea; // m^2 for radiation/convection

  /// Remaining ablative heat-shield material (units). Burns off during reentry
  /// to absorb heat before it reaches the part.
  double ablator;

  /// Joules absorbed per unit of ablator consumed.
  final double ablationHeatPerUnit;

  PartThermalState({
    required this.part,
    required this.temperature,
    required this.heatCapacity,
    required this.maxTemperature,
    this.emissivity = 0.8,
    this.surfaceArea = 1.0,
    this.ablator = 0,
    this.ablationHeatPerUnit = 0,
  });

  bool get isOverheating => temperature > maxTemperature;
  bool get hasAblator => ablator > 0 && ablationHeatPerUnit > 0;

  /// Spend ablator to absorb up to [joules] of incoming heat; returns the heat
  /// (J) NOT absorbed (which still reaches the part).
  double absorbWithAblator(double joules) {
    if (!hasAblator || joules <= 0) return joules;
    final absorbable = ablator * ablationHeatPerUnit;
    if (joules <= absorbable) {
      ablator -= joules / ablationHeatPerUnit;
      return 0;
    }
    ablator = 0;
    return joules - absorbable;
  }

  /// Apply a net heat flux [watts] over [dt] seconds: dT = Q*dt / C.
  void applyHeat(double watts, double dt) {
    if (heatCapacity <= 0) return;
    temperature += watts * dt / heatCapacity;
    if (temperature < 2.7) temperature = 2.7; // cosmic floor
  }
}
