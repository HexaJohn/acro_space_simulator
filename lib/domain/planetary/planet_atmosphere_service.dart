// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What colonies do to a planet's air, integrated against its real inventory
/// (docs/plans/terraforming.md §4, §5.2).
library;

import 'dart:math' as math;

import 'atmosphere_flows.dart';
import 'atmospheric_composition.dart';
import 'planet_atmosphere.dart';

export 'atmosphere_flows.dart';

/// The one documented knob between honest per-tower physics and a timescale a
/// player can reach (§4 "Rates and time", §7 Q1).
///
/// Real terraforming takes centuries. A tower gets a physical gas flow
/// ([oxygenatorMolesPerSecond], a large industrial plant's worth), and
/// [terraformRateScale] multiplies it into game time. The default is sized so
/// that **50 towers at full throttle take Mars from reference air to
/// [oxygenTargetPa] of oxygen in about 30 Mars years**:
///
/// ```
/// Mars reference air            5.42e17 mol (610 Pa, g = 3.728 m/s²)
/// O2 to reach pO2 = 0.16 atm    1.94e19 mol (the sky ends up ~0.16 atm, mostly O2)
/// 30 Mars years                 1.781e9 s
/// per tower                     1.94e19 / (50 × 1.781e9) ≈ 2.2e8 mol/s
///                               = 1000 mol/s × 2.2e5
/// ```
///
/// About 30 minutes of play at the top 1,000,000× warp, a few hours at
/// 100,000×. Earth is untouched at the same scale: its sky already gives full
/// oxygen cover, so towers there vent nothing (see [oxygenTargetPa]), and the
/// industry and scrubbing a colony adds move a 1.8e20-mole atmosphere by parts
/// per million.
class TerraformTuning {
  const TerraformTuning({
    this.oxygenatorMolesPerSecond = 1000,
    this.terraformRateScale = 2.2e5,
    this.oxygenTargetPa = 0.16 * 101325,
  });

  /// Physical O2 output of one Terraforming Tower at full throttle (mol/s):
  /// about 32 kg/s, a large photolytic / electrolysis plant.
  final double oxygenatorMolesPerSecond;

  /// Game-time multiplier on every tower's gas flow (dimensionless).
  final double terraformRateScale;

  /// The oxygen partial pressure (Pa) towers vent toward and stop at.
  ///
  /// 0.16 atm is where the sky gives a person full oxygen cover (§3.4,
  /// `airO2 = pO2 / 0.16 atm`): past it, venting more buys nothing, so a
  /// tower's controller holds. That is also what makes Earth immovable by
  /// towers — it starts at 0.21 atm — and it bounds the inventory, so a
  /// forgotten tower programme cannot pump a planet into a fire hazard.
  final double oxygenTargetPa;

  /// Moles of O2 per second one tower vents at full throttle.
  double get oxygenatorRate => oxygenatorMolesPerSecond * terraformRateScale;
}

/// Integrates [AtmosphereFlows] into a [PlanetAtmosphere].
///
/// Every term is exact for flows held constant over the step, so one long warp
/// step lands where many short ones do:
///  * gas sources are linear in time, and sinks stop at zero;
///  * the oxygen vent stops at its target, solved in closed form;
///  * aerosols relax EXPONENTIALLY toward equilibrium.
/// The one coupling is the cap judged after the step's industry: while towers
/// hold at the target, heavy CO2 nudges the O2 partial pressure, and step size
/// moves the result by parts per million — not by a regime.
/// An explicit rise-minus-settle step goes unstable (and then negative) the
/// moment `settleRate × dt` exceeds 1, and under warp a step can be years.
class PlanetAtmosphereService {
  const PlanetAtmosphereService({
    this.tuning = const TerraformTuning(),
    this.molesPerPollutionSecond = 5.0e3,
    this.aerosolRisePerPollution = 4.0e-5,
    this.aerosolSettleRate = 0.004,
    this.o2PerScrubbedPollution = 0.35,
  });

  final TerraformTuning tuning;

  /// Moles of CO2 released per unit of the city's pollution rate per second.
  ///
  /// The city's pollution number is an abstract rate, so this is the one place
  /// that gives it physical units. Calibrated against the real thing: a heavy
  /// industrial colony emitting at rate ~40 works out near 6e12 mol/yr, about
  /// a hundredth of all human industry. That keeps Earth unmovable by one city
  /// (a few tenths of a ppm per decade) while a Mars-thin atmosphere shifts
  /// measurably over the same span, which is the interesting result.
  ///
  /// Deliberately NOT multiplied by [TerraformTuning.terraformRateScale]:
  /// that compresses a deliberate tower programme into reachable time, and
  /// industry is not one.
  final double molesPerPollutionSecond;

  /// Particulate loading added per unit pollution per second.
  final double aerosolRisePerPollution;

  /// Fraction of the aerosol burden that settles out per second.
  final double aerosolSettleRate;

  /// Moles of O2 returned per mole of CO2 a scrubber removes — photosynthesis
  /// and Sabatier-type processing both release oxygen when they take carbon
  /// out, so a terraforming colony brightens its own air twice over.
  final double o2PerScrubbedPollution;

  /// Advance [state] by [dt] seconds under [flows].
  void advance(PlanetAtmosphere state, AtmosphereFlows flows,
      {required double dt}) {
    // 1. Industry. CO2 in; scrubbing takes CO2 out — never more than is
    // there — and releases oxygen for what it really removed.
    final co2 = flows.pollution * molesPerPollutionSecond;
    if (co2 > 0) {
      state.add(AtmosphereGas.carbonDioxide, co2);
    } else if (co2 < 0) {
      final removed = -state.add(AtmosphereGas.carbonDioxide, co2);
      state.add(AtmosphereGas.oxygen, removed * o2PerScrubbedPollution);
    }

    // 2. Haze tracks current activity: it rises with emissions and settles
    // out continuously, so it cannot ratchet upward the way the gases do.
    // The emission RATE is the flows over the span they were produced in,
    // not over this step: a frame of held colony ticks lands in one step.
    if (dt > 0) {
      final span = flows.seconds;
      final riseRate =
          span > 0 ? flows.emission / span * aerosolRisePerPollution : 0.0;
      final equilibrium =
          aerosolSettleRate > 0 ? riseRate / aerosolSettleRate : riseRate;
      final decay = math.exp(-aerosolSettleRate * dt);
      state.aerosolBurden = math.max(
          0.0, equilibrium + (state.aerosolBurden - equilibrium) * decay);
    }

    // 3. Terraforming towers vent O2, up to the target and no further. After
    // the industry step, so the cap is judged against the air as it now is.
    final vent = flows.oxygenatorRun * tuning.oxygenatorRate;
    if (vent > 0) {
      state.add(AtmosphereGas.oxygen, math.min(vent, oxygenHeadroom(state)));
    }
  }

  /// Moles of O2 that can still be vented before the surface O2 partial
  /// pressure reaches [TerraformTuning.oxygenTargetPa]; 0 at or past it.
  ///
  /// Adding Δ moles of O2 raises both its mole fraction and the column mass,
  /// so `pO2(Δ) = k (n + Δ)(m + M Δ) / (N + Δ)` with k the pascals per
  /// kilogram — and `pO2(Δ) = target` is a quadratic with exactly one
  /// positive root while the sky is below target. Solved in closed form
  /// rather than stepped, so the cap does not depend on how time was chopped.
  double oxygenHeadroom(PlanetAtmosphere state) {
    final target = tuning.oxygenTargetPa;
    final k = state.pascalsPerKg;
    if (target <= 0 || k <= 0) return 0;
    final n = state.molesOf(AtmosphereGas.oxygen);
    final total = state.totalMoles;
    final m = state.massKg;
    final mo2 = AtmosphericComposition.molarMass[AtmosphereGas.oxygen]!;
    final a = k * mo2;
    final b = k * (m + mo2 * n) - target;
    final c = k * n * m - target * total;
    if (c >= 0) return 0; // already at or past the target
    final disc = math.sqrt(b * b - 4 * a * c);
    // The numerically stable form of each branch: no subtraction of nearly
    // equal terms whichever sign b has.
    return b <= 0 ? (-b + disc) / (2 * a) : (2 * c) / (-b - disc);
  }
}
