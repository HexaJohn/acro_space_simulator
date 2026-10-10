// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A planet's surface temperature from its sunlight and its air
/// (docs/plans/terraforming.md §3.2-3.3, phase 2).
///
/// Phase 1 held every world at its reference temperature, so a Mars vented to
/// a sixth of an atmosphere was exactly as cold as the bare one. That is the
/// one feedback terraforming is built on: thicker, more absorbing air holds
/// more heat, and on Mars the heat releases the CO2 the caps and the soil
/// hold back, which thickens the air again. This is the smallest model that
/// carries that loop honestly:
///
/// ```
/// T_eq = (S (1 − A) / 4σ)^¼                         (radiative equilibrium)
/// τ    = Σ a_i (p_i / P0)^α_i (P / P0)^β  +  τ_agent (grey infrared depth)
/// T_s  = T_eq (1 + ¾ τ)^¼                           (Eddington grey atmosphere)
/// ```
///
/// The grey-atmosphere form is crude next to a line-by-line model, but it has
/// the two properties that matter here: absorption saturates (a square-root-
/// like response to each gas, so doubling CO2 is a few kelvin, not a
/// doubling), and it is PRESSURE-BROADENED (the β term), which is why the same
/// CO2 warms a thick sky far more than a thin one — the reason Mars's 96% CO2
/// air is barely a greenhouse at all and Venus's is an oven.
///
/// Calibrated, not fitted per world: three coefficients (CO2 against Earth and
/// Venus, H2O against Earth, CH4 against Titan) with the pressure exponent
/// chosen so present-day Mars comes out a few kelvin warm. The four reference
/// skies land within ~3 K on the physics alone, and [PlanetAtmosphere] keeps
/// that small residual as a per-body offset so every untouched world reads
/// back its reference temperature EXACTLY — the model only ever moves a world
/// something has changed.
library;

import 'dart:math' as math;

import 'atmospheric_composition.dart';

/// The tunable constants of [PlanetClimate].
class GreenhouseTuning {
  const GreenhouseTuning({
    this.co2Coefficient = 4.02,
    this.co2Exponent = 0.355,
    this.waterCoefficient = 2.316,
    this.waterExponent = 0.3,
    this.methaneCoefficient = 2.543,
    this.methaneExponent = 0.5,
    this.pressureBroadening = 0.45,
    this.agentDepthPerRootPascal = 0.7,
    this.aerosolAlbedo = 3e-6,
  });

  /// CO2's grey depth at one atmosphere of pure CO2 partial pressure — set so
  /// Earth's 0.04% carries a quarter of its infrared depth (CO2's share of the
  /// present-day greenhouse is a fifth to a quarter) and Venus's 92 bar comes
  /// out at its 737 K.
  final double co2Coefficient;

  /// Saturation of CO2's absorption with its own partial pressure. Near ⅓:
  /// the band centre is long saturated, so warming comes from the wings.
  final double co2Exponent;

  /// Water vapour's coefficient: set so Earth's ~1.3% humid mix supplies the
  /// remaining ~70% of its 33 K greenhouse.
  final double waterCoefficient;
  final double waterExponent;

  /// Methane's coefficient, set against Titan's +10 K over equilibrium. On
  /// Titan the warming is mostly collision-induced N2–CH4/H2 absorption; it
  /// is folded into the methane term rather than given its own, so a Titan
  /// that loses its methane loses its greenhouse, which is the right sign.
  final double methaneCoefficient;
  final double methaneExponent;

  /// The β of `(P / P0)^β`: how much a thicker sky broadens every band.
  final double pressureBroadening;

  /// Grey depth of the super-greenhouse agent (a PFC mix) per √Pa of its
  /// partial pressure. PFCs absorb in the 8-12 µm window the natural gases
  /// leave open, so they are not pressure-broadened here. 0.7 is about +25 K
  /// on present Mars from one pascal — the order Gerstell et al. (2001,
  /// PNAS 98, 2154) and Marinova et al. (2005, JGR 110, E03002) report for
  /// pascal-level partial pressures of their best mixes. The phase-3
  /// Greenhouse Factory is what fills it.
  final double agentDepthPerRootPascal;

  /// Planetary albedo added by the aerosol burden (§3.2's "aerosol
  /// cooling"): `aerosolAlbedo × b / (1 + b)` for burden b.
  ///
  /// Tiny, because the burden is one colony's REGIONAL haze: a saturated
  /// veil brightens what it covers by a few hundredths (0.03), and a
  /// colony's smoke covers of order 1e-4 of a planet, so spread over the
  /// world it is ~3e-6. Set at the veil's 0.03 the haze of one smoky Mars
  /// town cooled the whole planet half a kelvin and froze a tenth of its
  /// air onto the cap — more than its industry ever added. The term is here
  /// for a global aerosol source to drive (a planetary nuclear winter, a
  /// dust-storm season) at a coefficient that means one.
  final double aerosolAlbedo;
}

/// Surface temperature of a world from its sunlight and its air.
class PlanetClimate {
  const PlanetClimate([this.tuning = const GreenhouseTuning()]);

  final GreenhouseTuning tuning;

  static const double stefanBoltzmann = 5.670374419e-8;
  static const double earthPressurePa = 101325;

  /// Bond albedo of the bodies the solar system defines (NASA planetary fact
  /// sheets; Titan from Li et al. 2011). The reference bodies carry no albedo
  /// of their own, and it is climate data, not orbital data.
  static const Map<String, double> bondAlbedo = {
    'mercury': 0.068,
    'venus': 0.77,
    'earth': 0.306,
    'moon': 0.11,
    'mars': 0.25,
    'jupiter': 0.343,
    'saturn': 0.342,
    'uranus': 0.30,
    'neptune': 0.29,
    'titan': 0.265,
    'io': 0.63,
    'europa': 0.68,
    'ganymede': 0.43,
    'callisto': 0.22,
    'phobos': 0.071,
    'deimos': 0.068,
  };

  /// A body the table does not list: a typical rocky world.
  static const double defaultAlbedo = 0.3;

  static double albedoOf(String bodyId) => bondAlbedo[bodyId] ?? defaultAlbedo;

  /// Radiative-equilibrium temperature (K) of a fast-rotating sphere under
  /// [solarFlux] W/m² with Bond [albedo].
  static double equilibriumTemperature(double solarFlux, double albedo) {
    final absorbed = solarFlux * (1 - albedo.clamp(0.0, 0.99));
    if (absorbed <= 0) return 3; // the cosmic background, near enough
    return math.pow(absorbed / (4 * stefanBoltzmann), 0.25).toDouble();
  }

  /// The albedo with a colony's [aerosolBurden] veil added.
  double effectiveAlbedo(double albedo, double aerosolBurden) {
    final b = math.max(0.0, aerosolBurden);
    return (albedo + tuning.aerosolAlbedo * b / (1 + b)).clamp(0.0, 0.99);
  }

  /// Grey infrared optical depth of air at total [pressurePa] with the given
  /// [partialPressurePa] per gas, plus [agentPa] of super-greenhouse agent.
  double opticalDepth({
    required double pressurePa,
    required double Function(AtmosphereGas gas) partialPressurePa,
    double agentPa = 0,
  }) {
    final t = tuning;
    var tau = 0.0;
    if (pressurePa > 0) {
      final broadening = math
          .pow(pressurePa / earthPressurePa, t.pressureBroadening)
          .toDouble();
      double band(AtmosphereGas gas, double a, double alpha) {
        final p = partialPressurePa(gas);
        if (p <= 0) return 0;
        return a * math.pow(p / earthPressurePa, alpha).toDouble();
      }

      tau += broadening *
          (band(AtmosphereGas.carbonDioxide, t.co2Coefficient, t.co2Exponent) +
              band(AtmosphereGas.water, t.waterCoefficient, t.waterExponent) +
              band(AtmosphereGas.methane, t.methaneCoefficient,
                  t.methaneExponent));
    }
    if (agentPa > 0) tau += t.agentDepthPerRootPascal * math.sqrt(agentPa);
    return tau;
  }

  /// Model surface temperature (K): the Eddington grey-atmosphere warming of
  /// [equilibriumK] by optical depth [tau].
  static double greyTemperature(double equilibriumK, double tau) =>
      equilibriumK * math.pow(1 + 0.75 * math.max(0.0, tau), 0.25).toDouble();
}
