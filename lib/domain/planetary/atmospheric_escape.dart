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
    this.co2CoolingColumnPa = 300,
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

  /// Surface pressure (Pa) below which the CO2 thermostat fades out, in
  /// proportion: the cooling is `co2Cooling · x_CO2 · min(1, P / this)`.
  ///
  /// CO2 cools a thermosphere by collisions: an O atom knocks a molecule
  /// into its 15 µm bend and it radiates the heat away. A trace exosphere
  /// has no collisional thermosphere to cool, so its gas leaks at the bare
  /// EUV-heated temperature. Counted on mole fraction alone, a Moon whose
  /// only air was lunar industry's CO2 got the full eightfold cooling, an
  /// exobase near 315 K and a CO2 leak of 4e-22/s — a permanent atmosphere
  /// growing without limit, which then locked in vented oxygen after the
  /// towers stopped (review, 2026-10-10).
  ///
  /// The thermostat is a positive loop — more CO2, a colder exobase, a
  /// slower leak, more CO2 — so a world can have two steady states: a thin
  /// leaking trace and a thick held sky. The leaking one is stable while
  /// `λ (1 + λ/(1+λ)) · |∂ln T_exo/∂ln P| < 1`, which on the Moon (λ ≈ 16
  /// for CO2) holds to about P ≈ this / 85. 300 Pa puts that edge near
  /// 3.5 Pa of lunar CO2: a heavy industrial colony (pollution ~40) holds
  /// ~0.15 Pa, and ten of them together still settle on the leaking branch
  /// at ~3 Pa (pinned in planet_feedbacks_test). At 100 Pa the edge was a
  /// third as high and pollution 300 ran away. A sky pumped
  /// past the edge crosses to the held one and keeps it, which is the
  /// physics, not a leak in the model: a real Moon would hold a dense CO2
  /// atmosphere for millions of years (see the library comment). 300 Pa,
  /// half of Mars's surface pressure, also keeps every world whose air
  /// carries much CO2 (Mars at ~600 Pa, Venus) at its full thermostat, so
  /// their reference exobases do not move.
  final double co2CoolingColumnPa;

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
  /// EUV-heated thermosphere, which [co2Fraction] cools — in a sky of
  /// [surfacePressurePa] thick enough to have a thermosphere
  /// ([EscapeTuning.co2CoolingColumnPa]).
  double exobaseTemperature({
    required double equilibriumK,
    required double solarFlux,
    required double co2Fraction,
    required double surfacePressurePa,
  }) {
    final skin = equilibriumK * math.pow(2, -0.25).toDouble();
    final column = tuning.co2CoolingColumnPa <= 0
        ? 1.0
        : (math.max(0.0, surfacePressurePa) / tuning.co2CoolingColumnPa)
            .clamp(0.0, 1.0);
    final euv = tuning.thermosphereHeatingK *
        math.sqrt(math.max(0.0, solarFlux) / 1361.0) /
        (1 + tuning.co2Cooling * co2Fraction.clamp(0.0, 1.0) * column);
    return skin + euv;
  }

  /// Fraction of a gas of molar mass [molarMassKgPerMol] lost per second
  /// (1/s) from a world of gravitational parameter [mu] (m³/s²) and radius
  /// [radiusM] at exobase temperature [exobaseK], before any suppression.
  ///
  /// The column is never taller than the world: `v₀ / (2√π · min(H, R))`.
  /// The Jeans form assumes `H ≪ R`, and since `H = R / λ` it goes to ZERO
  /// as λ does — on Phobos or Ryugu (λ ~ 10⁻³ … 10⁻⁷) it underrated the
  /// loss by 10⁵-10⁹, so an ordinary colony's industry held a published sky
  /// whose top reached past Phobos's orbit of Mars (review, 2026-10-10).
  /// Gas on a body that small is unbound and leaves in about `R / v₀` —
  /// seconds to minutes — which is what the capped column gives; for any
  /// world big enough to hold air (λ ≫ 1) the cap never binds.
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
    final column = math.min(kT / (m * g), radiusM);
    return tuning.escapeRateScale *
        v0 /
        (2 * math.sqrt(math.pi) * column) *
        (1 + lambda) *
        math.exp(-lambda);
  }
}
