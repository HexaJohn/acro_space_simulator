// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How fast a world loses its air to space (docs/plans/terraforming.md §3.3,
/// phase 2): Jeans escape, gas by gas.
///
/// At the exobase — where the air thins until a molecule moving up is more
/// likely to leave than to hit another — the fast tail of the Maxwell
/// distribution simply goes. The flux per molecule there depends on one
/// number, the escape parameter
///
/// ```
/// λ = v_esc² / v₀²  = G M m / (k T_exo r)        v₀ = √(2kT/m)
/// rate per molecule = v₀ / (2√π H) · (1 + λ) e^(−λ)
/// ```
///
/// for a column of scale height `H = kT / (m g)`. The `e^(−λ)` is everything:
/// it makes escape absurdly selective, so light gases go first, small warm
/// worlds leak and big cold ones do not. At the exobase temperatures below,
/// the Moon loses vented oxygen with an e-fold of months, Mercury in years,
/// Mars keeps everything but hydrogen, and Earth and Venus lose nothing a game
/// could ever measure (λ in the hundreds).
///
/// Treating the whole inventory as exposed is the generous upper bound: a
/// thick, collisional sky only shows its exobase, and on that reading the Moon
/// would hold a vented atmosphere for millions of years (Needham & Kring 2017
/// put the loss of its ancient volcanic one near 10 kg/s). The plan's call is
/// that small worlds leak (§7 Q2) and the late-game Retention Array is what
/// lets one hold air, so the exposed-column form is used and the honest
/// caveat recorded here; [EscapeTuning.escapeRateScale] turns the whole thing
/// up or down.
library;

import 'dart:math' as math;

/// The tunable constants of [AtmosphericEscape].
class EscapeTuning {
  const EscapeTuning({
    this.thermosphereHeatingK = 700,
    this.co2Cooling = 6.9,
    this.escapeRateScale = 1.0,
  });

  /// Kelvin of extreme-ultraviolet heating a thermosphere gets above the
  /// world's skin temperature at Earth's sunlight, scaling as √(flux).
  /// 700 K gives Earth's ~900 K mean exobase.
  final double thermosphereHeatingK;

  /// How strongly CO2 cools a thermosphere: `heating / (1 + c · x_CO2)`.
  /// CO2 radiates the heat away at 15 µm, which is why Venus (~300 K) and
  /// Mars (~200-350 K, MAVEN) have cold upper atmospheres despite their
  /// sunlight. 6.9 puts both there, and Titan's comes out ~145 K unaided.
  final double co2Cooling;

  /// Multiplier on every escape rate (dimensionless). 1 = the physics above.
  /// NOT `TerraformTuning.terraformRateScale`: the towers are sped up so a
  /// programme fits in reachable time, but at real rates the Moon already
  /// loses vented oxygen with an e-fold of ~80 days — sped up 2e5-fold it
  /// would lose it in a minute, and no Retention Array could matter.
  final double escapeRateScale;
}

/// Jeans escape rates for one world.
class AtmosphericEscape {
  const AtmosphericEscape([this.tuning = const EscapeTuning()]);

  final EscapeTuning tuning;

  static const double boltzmann = 1.380649e-23;
  static const double avogadro = 6.02214076e23;

  /// Exobase temperature (K): the skin temperature (`T_eq / 2^¼`, the
  /// temperature an optically thin upper layer settles at) plus the
  /// EUV-heated thermosphere, which [co2Fraction] cools.
  double exobaseTemperature({
    required double equilibriumK,
    required double solarFlux,
    required double co2Fraction,
  }) {
    final skin = equilibriumK * math.pow(2, -0.25).toDouble();
    final euv = tuning.thermosphereHeatingK *
        math.sqrt(math.max(0.0, solarFlux) / 1361.0) /
        (1 + tuning.co2Cooling * co2Fraction.clamp(0.0, 1.0));
    return skin + euv;
  }

  /// Fraction of a gas of molar mass [molarMassKgPerMol] lost per second
  /// (1/s) from a world of gravitational parameter [mu] (m³/s²) and radius
  /// [radiusM] at exobase temperature [exobaseK], before any suppression.
  double rate({
    required double molarMassKgPerMol,
    required double mu,
    required double radiusM,
    required double exobaseK,
  }) {
    if (mu <= 0 || radiusM <= 0 || exobaseK <= 0) return 0;
    final m = molarMassKgPerMol / avogadro;
    final kT = boltzmann * exobaseK;
    final g = mu / (radiusM * radiusM);
    final v0 = math.sqrt(2 * kT / m);
    final lambda = 2 * mu / radiusM / (v0 * v0);
    // e^(−700) underflows to zero anyway; stop well before and say so.
    if (lambda > 600) return 0;
    final scaleHeight = kT / (m * g);
    return tuning.escapeRateScale *
        v0 /
        (2 * math.sqrt(math.pi) * scaleHeight) *
        (1 + lambda) *
        math.exp(-lambda);
  }
}
