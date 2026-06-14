import 'dart:math' as math;

/// Atmospheric gas species tracked by the composition model. Compact set —
/// expand freely as new chemistry is needed.
enum AtmosphereGas {
  nitrogen,
  oxygen,
  carbonDioxide,
  hydrogen,
  helium,
  methane,
  argon,
  water,
}

/// Bulk chemical composition of a planetary atmosphere: a map of gas species to
/// mole (volume) fractions, summing to 1. From the mix it derives the mean
/// molecular weight, which feeds scale-height, density, and aerodynamic /
/// life-support calculations elsewhere.
///
/// Pure value object — no Flutter/IO. The constructor normalises the supplied
/// fractions so they always sum to exactly 1 (within float precision), so
/// callers may pass rough percentages without pre-normalising.
class AtmosphericComposition {
  /// Mole fraction per gas; values sum to ~1. Empty species are omitted.
  final Map<AtmosphereGas, double> fractions;

  AtmosphericComposition(Map<AtmosphereGas, double> fractions)
      : fractions = _normalise(fractions);

  /// Molar mass (kg/mol) of each gas species.
  static const Map<AtmosphereGas, double> molarMass = {
    AtmosphereGas.nitrogen: 0.0280134, // N2
    AtmosphereGas.oxygen: 0.0319988, // O2
    AtmosphereGas.carbonDioxide: 0.0440095, // CO2
    AtmosphereGas.hydrogen: 0.00201588, // H2
    AtmosphereGas.helium: 0.0040026, // He
    AtmosphereGas.methane: 0.0160425, // CH4
    AtmosphereGas.argon: 0.039948, // Ar
    AtmosphereGas.water: 0.0180153, // H2O
  };

  /// Mean molecular weight (kg/mol): the mole-fraction-weighted average of the
  /// component molar masses.
  double get meanMolecularWeight {
    var sum = 0.0;
    fractions.forEach((gas, fraction) {
      sum += fraction * molarMass[gas]!;
    });
    return sum;
  }

  /// Reentry-heating multiplier relative to Earth air: heavier gases (CO2 on
  /// Mars/Venus) deposit more stagnation heat than light gases (H2/He) at equal
  /// density and speed. Normalised so Earth's ~0.029 kg/mol air gives ~1.0.
  double get reentryHeatingFactor {
    const earthMmw = 0.0289647; // kg/mol
    final mmw = meanMolecularWeight;
    if (mmw <= 0) return 1.0;
    // sqrt scaling keeps the effect moderate (factor ~1.2 for CO2, ~0.7 for H2).
    return math.sqrt(mmw / earthMmw);
  }

  /// Normalise raw fractions so they sum to 1; drops non-positive entries. An
  /// all-zero (or empty) input is returned empty rather than dividing by zero.
  static Map<AtmosphereGas, double> _normalise(
      Map<AtmosphereGas, double> raw) {
    final positive = <AtmosphereGas, double>{};
    var total = 0.0;
    raw.forEach((gas, fraction) {
      if (fraction > 0) {
        positive[gas] = fraction;
        total += fraction;
      }
    });
    if (total == 0) return const {};
    return positive.map((gas, fraction) => MapEntry(gas, fraction / total));
  }

  /// Earth: ~78% N2, ~21% O2, ~0.93% Ar, ~0.04% CO2.
  factory AtmosphericComposition.earth() => AtmosphericComposition(const {
        AtmosphereGas.nitrogen: 0.7808,
        AtmosphereGas.oxygen: 0.2095,
        AtmosphereGas.argon: 0.0093,
        AtmosphereGas.carbonDioxide: 0.0004,
      });

  /// Mars: ~96% CO2, ~1.9% Ar, ~1.9% N2.
  factory AtmosphericComposition.mars() => AtmosphericComposition(const {
        AtmosphereGas.carbonDioxide: 0.9597,
        AtmosphereGas.argon: 0.0193,
        AtmosphereGas.nitrogen: 0.0189,
        AtmosphereGas.oxygen: 0.0015,
      });

  /// Titan: ~95% N2, ~5% CH4.
  factory AtmosphericComposition.titan() => AtmosphericComposition(const {
        AtmosphereGas.nitrogen: 0.95,
        AtmosphereGas.methane: 0.05,
      });

  /// Venus: ~96.5% CO2, ~3.5% N2.
  factory AtmosphericComposition.venus() => AtmosphericComposition(const {
        AtmosphereGas.carbonDioxide: 0.965,
        AtmosphereGas.nitrogen: 0.035,
      });
}
