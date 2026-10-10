// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What colonies do to a planet's air, and what the planet does back,
/// integrated against its real inventory (docs/plans/terraforming.md §3.3,
/// §4, §5.2).
library;

import 'dart:math' as math;

import 'atmosphere_flows.dart';
import 'atmospheric_composition.dart';
import 'atmospheric_escape.dart';
import 'planet_atmosphere.dart';
import 'volatile_reservoir.dart';

export 'atmosphere_flows.dart';
export 'atmospheric_escape.dart' show AtmosphericEscape, EscapeTuning;

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
    this.harvesterMolesPerStockUnit = 4.4e8,
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

  /// Moles of the sky's O2 behind one unit of a colony's oxygen STOCK, for
  /// the Atmospheric Harvester (user request, 2026-10-10: harvesting thins
  /// the sky).
  ///
  /// A stock unit is abstract, so this is a choice, and the one made is
  /// symmetry with the tower: the Terraforming Tower vents [oxygenatorRate]
  /// (2.2e8 mol/s) into the sky for every 0.5 stock/s it puts in the store,
  /// so one stock unit stands for 4.4e8 mol either way. A harvester (2 stock/s
  /// at full run) then draws 8.8e8 mol/s — it undoes four towers, which is
  /// what pulling oxygen OUT of a sky someone is filling should cost. On
  /// Earth that is ~0.07% of the oxygen per harvester-year; the honest
  /// alternative — a stock unit as the hundredth of a mole a colonist
  /// breathes — would make the harvester invisible to any planet.
  final double harvesterMolesPerStockUnit;

  /// Moles of O2 per second one tower vents at full throttle.
  double get oxygenatorRate => oxygenatorMolesPerSecond * terraformRateScale;
}

/// Integrates [AtmosphereFlows] — and the planet's own response — into a
/// [PlanetAtmosphere].
///
/// The colonies' flows (industry, scrubbing, towers, harvesters) are held as
/// constant RATES over the step. The planet then answers in two ways
/// (§3.3, phase 2):
///  * **escape** — each gas leaks at its Jeans rate ([AtmosphericEscape]),
///    integrated together with the flows in closed form
///    (`n = S/k + (n₀ − S/k) e^(−kh)`), so a tower holding the Moon's sky
///    against a leak lands on the same equilibrium in one year-long step as
///    in a million short ones;
///  * **volatile exchange** — each reservoir (Mars's caps, its soil) relaxes
///    the sky toward the pressure it would hold at the current temperature,
///    exponentially over its own lag. The temperature it is judged at is the
///    one the step itself is changing — the runaway loop — so a long step is
///    cut into sub-steps of at most a sixty-fourth of the shortest lag, each
///    taken with targets from its midpoint (second order), and one long warp
///    step follows the path many short ones do to a part in a thousand.
/// Every term is unconditionally stable: exponential relaxation cannot
/// overshoot, sinks stop at zero, and a reservoir gives up no more than it
/// holds. The haze relaxes exponentially as it always has.
class PlanetAtmosphereService {
  const PlanetAtmosphereService({
    this.tuning = const TerraformTuning(),
    this.escape = const AtmosphericEscape(),
    this.feedbacks = true,
    this.molesPerPollutionSecond = 5.0e3,
    this.aerosolRisePerPollution = 4.0e-5,
    this.aerosolSettleRate = 0.004,
    this.o2PerScrubbedPollution = 0.35,
  });

  /// The phase-1 ledger alone: colonies' flows, no escape and no reservoirs.
  /// For pinning what the colonies themselves put in and take out.
  const PlanetAtmosphereService.ledgerOnly({
    this.tuning = const TerraformTuning(),
    this.molesPerPollutionSecond = 5.0e3,
    this.aerosolRisePerPollution = 4.0e-5,
    this.aerosolSettleRate = 0.004,
    this.o2PerScrubbedPollution = 0.35,
  })  : escape = const AtmosphericEscape(),
        feedbacks = false;

  final TerraformTuning tuning;
  final AtmosphericEscape escape;

  /// Whether the planet answers: escape and volatile exchange.
  final bool feedbacks;

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

  /// Sub-steps per shortest reservoir lag (see the class comment).
  static const int stepsPerLag = 64;

  /// No step is cut finer than this many sub-steps; past it they lengthen,
  /// trading accuracy (never stability) for a bounded cost on absurd steps.
  static const int maxSubsteps = 4096;

  /// Below this many moles, a gas the reference air never had is gone — so
  /// a leaked-out Moon returns to its exact (empty) reference and rests.
  static const double traceMoles = 1.0;

  /// Advance [state] by [dt] seconds under [flows].
  void advance(PlanetAtmosphere state, AtmosphereFlows flows,
      {required double dt}) {
    if (dt <= 0) {
      _applyAmounts(state, flows);
      return;
    }

    // 1. Haze tracks current activity: it rises with emissions and settles
    // out continuously, so it cannot ratchet upward the way the gases do.
    // The emission RATE is the flows over the span they were produced in,
    // not over this step: a frame of held colony ticks lands in one step.
    final span = flows.seconds;
    final riseRate =
        span > 0 ? flows.emission / span * aerosolRisePerPollution : 0.0;
    final equilibrium =
        aerosolSettleRate > 0 ? riseRate / aerosolSettleRate : riseRate;
    final decay = math.exp(-aerosolSettleRate * dt);
    var haze = math.max(
        0.0, equilibrium + (state.aerosolBurden - equilibrium) * decay);
    // An exponential never reaches zero; a sky this clean is clean.
    if (haze < 1e-12) haze = 0;
    state.aerosolBurden = haze;

    // 2. The colonies' flows, as rates held over the step.
    final rates = _Rates(
      co2: flows.pollution * molesPerPollutionSecond / dt,
      vent: flows.oxygenatorRun * tuning.oxygenatorRate / dt,
      harvest: flows.o2Harvested * tuning.harvesterMolesPerStockUnit / dt,
    );

    var steps = 1;
    if (feedbacks && state.reservoirs.isNotEmpty) {
      var lag = double.infinity;
      for (final r in state.reservoirs) {
        lag = math.min(lag, r.relaxSeconds);
      }
      if (lag.isFinite && lag > 0) {
        steps = (dt / (lag / stepsPerLag)).ceil().clamp(1, maxSubsteps);
      }
    }
    final h = dt / steps;
    for (var i = 0; i < steps; i++) {
      _flowsAndEscape(state, rates, h);
      if (feedbacks) _exchange(state, h);
    }
    if (feedbacks) state.pruneTrace(traceMoles);
  }

  /// The degenerate zero-length step: whatever amounts are waiting land as
  /// they are, with no time for the planet to answer.
  void _applyAmounts(PlanetAtmosphere state, AtmosphereFlows flows) {
    final co2 = flows.pollution * molesPerPollutionSecond;
    if (co2 > 0) {
      state.add(AtmosphereGas.carbonDioxide, co2);
    } else if (co2 < 0) {
      final removed = -state.add(AtmosphereGas.carbonDioxide, co2);
      state.add(AtmosphereGas.oxygen, removed * o2PerScrubbedPollution);
    }
    state.add(AtmosphereGas.oxygen,
        -flows.o2Harvested * tuning.harvesterMolesPerStockUnit);
    final vent = flows.oxygenatorRun * tuning.oxygenatorRate;
    if (vent > 0) {
      state.add(AtmosphereGas.oxygen, math.min(vent, oxygenHeadroom(state)));
    }
  }

  /// Per-gas escape constants (1/s) for [state] now, suppression applied.
  Map<AtmosphereGas, double> escapeRates(PlanetAtmosphere state) {
    final out = <AtmosphereGas, double>{};
    if (!feedbacks) return out;
    final keep = 1 - state.escapeSuppression.clamp(0.0, 1.0);
    if (keep <= 0) return out;
    final n = state.totalMoles;
    final exo = escape.exobaseTemperature(
      equilibriumK: state.equilibriumTemperatureK,
      solarFlux: state.solarFlux,
      co2Fraction:
          n <= 0 ? 0 : state.molesOf(AtmosphereGas.carbonDioxide) / n,
    );
    for (final g in AtmosphereGas.values) {
      final k = escape.rate(
        molarMassKgPerMol: AtmosphericComposition.molarMass[g]!,
        mu: state.mu,
        radiusM: state.bodyRadiusM,
        exobaseK: exo,
      );
      if (k > 0) out[g] = k * keep;
    }
    return out;
  }

  /// One sub-step of the colonies' flows and escape, each gas in closed form
  /// for its source and leak held constant.
  void _flowsAndEscape(PlanetAtmosphere state, _Rates rates, double h) {
    final k = escapeRates(state);

    // Industry and scrubbing: CO2 in, or CO2 out with oxygen returned for
    // what was REALLY removed — the difference the scrubbers made to where
    // the CO2 would otherwise have ended up.
    final co2Rate = rates.co2;
    final kc = k[AtmosphereGas.carbonDioxide] ?? 0;
    final co2Before = state.molesOf(AtmosphereGas.carbonDioxide);
    final co2After = _sourceAndLeak(co2Before, co2Rate, kc, h);
    var scrubbedO2 = 0.0;
    if (co2Rate < 0) {
      final unscrubbed = _sourceAndLeak(co2Before, 0, kc, h);
      scrubbedO2 = math.max(0.0, unscrubbed - co2After) * o2PerScrubbedPollution;
    }
    state.add(AtmosphereGas.carbonDioxide, co2After - co2Before);

    // Oxygen: towers vent toward the target and stop at it — judged against
    // the air after this sub-step's industry — harvesters draw it out, and
    // it leaks like any gas. The cap is a ceiling on what VENTING may
    // reach: harvesting below it, or a sky already past it, is untouched.
    final o2Before = state.molesOf(AtmosphereGas.oxygen);
    final cap = state.molesForPartialPressure(
        state.moles, AtmosphereGas.oxygen, tuning.oxygenTargetPa);
    final venting = rates.vent > 0 && o2Before < cap;
    final ko = k[AtmosphereGas.oxygen] ?? 0;
    var o2After = _sourceAndLeak(
        o2Before, (venting ? rates.vent : 0) - rates.harvest, ko, h);
    if (venting && o2After > cap) o2After = cap;
    state.add(AtmosphereGas.oxygen, o2After - o2Before + scrubbedO2);

    // Every other gas only leaks.
    for (final e in k.entries) {
      final g = e.key;
      if (g == AtmosphereGas.carbonDioxide || g == AtmosphereGas.oxygen) {
        continue;
      }
      final n = state.molesOf(g);
      if (n <= 0) continue;
      state.add(g, _sourceAndLeak(n, 0, e.value, h) - n);
    }
  }

  /// `dn/dt = S − k n` from [n0] over [h], exactly, never below zero.
  static double _sourceAndLeak(double n0, double s, double k, double h) {
    final x = k * h;
    if (x <= 0) return math.max(0.0, n0 + s * h);
    final kept = math.exp(-x);
    // (1 − e^−x)/k without the cancellation (no expm1 in dart:math).
    final span = x < 1e-5 ? h * (1 - x / 2 + x * x / 6) : (1 - kept) / k;
    return math.max(0.0, n0 * kept + s * span);
  }

  /// One sub-step of volatile exchange: every reservoir relaxes the sky toward
  /// the pressure it would hold it at, judged at the sub-step's midpoint.
  void _exchange(PlanetAtmosphere state, double h) {
    final res = state.reservoirs;
    if (res.isEmpty) return;
    // Half a step from the start on the start's targets, to find the
    // midpoint's temperature and pressures; then the full step from the
    // start toward the midpoint's targets. The midpoint lends the CLIMATE
    // (temperature, the sky's pressures); each store's holding stays the
    // start's — a cap the half step emptied would otherwise read as having
    // nothing to give, and never give it.
    final start = state.moles;
    final held = [for (final r in res) r.moles];
    final mid = Map<AtmosphereGas, double>.of(start);
    _relax(state, mid, _targets(state, start), h / 2);
    for (var i = 0; i < res.length; i++) {
      res[i].moles = held[i];
    }
    final targets = _targets(state, mid);
    final end = Map<AtmosphereGas, double>.of(start);
    _relax(state, end, targets, h);
    for (final g in AtmosphereGas.values) {
      final d = (end[g] ?? 0) - (start[g] ?? 0);
      if (d != 0) state.add(g, d);
    }
  }

  /// For each reservoir, the moles of its gas the sky [m] is relaxing toward
  /// and which way: a release target while the sky is below what the store
  /// would hold it at, a condense target while above, neither in between.
  List<_Target> _targets(
      PlanetAtmosphere state, Map<AtmosphereGas, double> m) {
    final t = state.temperatureFor(m);
    final tRef = state.referenceTemperatureK;
    final out = <_Target>[];
    for (final r in state.reservoirs) {
      final eq = r.equilibriumPa(
        surfaceK: t,
        referenceSurfaceK: tRef,
        referencePartialPa: state.referencePartialPressurePa(r.gas),
      );
      final p = state.partialPressureFor(m, r.gas);
      if (p < eq.release && r.moles > 0) {
        out.add(_Target(
            state.molesForPartialPressure(m, r.gas, eq.release), true));
      } else if (p > eq.condense) {
        out.add(_Target(
            state.molesForPartialPressure(m, r.gas, eq.condense), false));
      } else {
        out.add(const _Target.none());
      }
    }
    return out;
  }

  /// Move gas between the sky [m] and each reservoir toward [targets] over
  /// [h]: `(target − n)(1 − e^(−h/τ))`, sublimation no more than the store
  /// holds, condensation no more than the sky has.
  void _relax(PlanetAtmosphere state, Map<AtmosphereGas, double> m,
      List<_Target> targets, double h) {
    final res = state.reservoirs;
    for (var i = 0; i < res.length; i++) {
      final r = res[i];
      final t = targets[i];
      if (!t.active) continue;
      final n = m[r.gas] ?? 0;
      final f = 1 - math.exp(-h / r.relaxSeconds);
      final double d;
      if (t.release) {
        d = math.min(math.max(0.0, (t.moles - n) * f), math.max(0.0, r.moles));
      } else {
        d = math.max(math.min(0.0, (t.moles - n) * f), -n);
      }
      if (d == 0) continue;
      m[r.gas] = n + d;
      r.moles = math.max(0.0, r.moles - d);
    }
  }

  /// Moles of O2 that can still be vented before the surface O2 partial
  /// pressure reaches [TerraformTuning.oxygenTargetPa]; 0 at or past it.
  ///
  /// Closed form ([PlanetAtmosphere.molesForPartialPressure]) rather than
  /// stepped, so the cap does not depend on how time was chopped.
  double oxygenHeadroom(PlanetAtmosphere state) {
    if (tuning.oxygenTargetPa <= 0) return 0;
    final cap = state.molesForPartialPressure(
        state.moles, AtmosphereGas.oxygen, tuning.oxygenTargetPa);
    return math.max(0.0, cap - state.molesOf(AtmosphereGas.oxygen));
  }

  /// The reservoirs a body holds, for callers that want them without the
  /// state (a planner, a panel).
  static List<VolatileReservoir> reservoirsFor(String bodyId) =>
      VolatileReservoir.forBody(bodyId);
}

/// Where one reservoir is taking the sky's share of its gas: [moles] of it,
/// by [release] (from the store) or condensing (into it).
class _Target {
  const _Target(this.moles, this.release) : active = true;
  const _Target.none()
      : moles = 0,
        release = false,
        active = false;

  final double moles;
  final bool release;
  final bool active;
}

/// The colonies' flows over one step, as rates (mol/s).
class _Rates {
  const _Rates({required this.co2, required this.vent, required this.harvest});

  /// Net industrial CO2 (negative = scrubbing).
  final double co2;

  /// Tower oxygen at full output, before the cap.
  final double vent;

  /// Oxygen the harvesters take out.
  final double harvest;
}
