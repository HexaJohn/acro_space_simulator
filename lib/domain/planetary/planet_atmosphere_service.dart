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
import 'atmosphere_ledger.dart';
import 'atmospheric_composition.dart';
import 'atmospheric_escape.dart';
import 'planet_atmosphere.dart';
import 'volatile_reservoir.dart';

export 'atmosphere_flows.dart';
export 'atmosphere_ledger.dart';
export 'atmospheric_escape.dart' show AtmosphericEscape, EscapeTuning;
export 'terraform_towers.dart';

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
    this.co2FloorPa = 42,
    this.greenhouseFactoryMolesPerSecond = 0.5,
    this.warmingTargetK = 288,
    this.bakerTurnoverPerSecond = 1e-16,
    this.sequestratorMolesPerSecond = 1000,
    this.retentionPerArray = 0.5,
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
  /// what pulling oxygen OUT of a sky someone is filling should cost. Both
  /// sides are bare throttle: the tower vents on its run, and the colony
  /// reports its harvesters' run before bounty and events, and only for the
  /// share its store kept (`CitySim.o2HarvestRate`), so the four holds at
  /// any bounty and a full tank takes nothing. On
  /// Earth that is ~0.07% of the oxygen per harvester-year; the honest
  /// alternative — a stock unit as the hundredth of a mole a colonist
  /// breathes — would make the harvester invisible to any planet.
  final double harvesterMolesPerStockUnit;

  /// The CO2 below which nothing a colony runs takes any more out of the
  /// sky — neither the Oxygenator's photolysis nor a Carbon Sequestrator —
  /// as the weight of the CO2's own column (Pa, `n × M_CO2 × g / 4πR²`).
  ///
  /// 42 Pa of column is Earth's pre-industrial 280 ppm (a partial pressure
  /// of 28 Pa in Earth's lighter air). It is the Earth limit for the
  /// carbon-removing towers: a sequestrator programme can take an Earth's
  /// industrial CO2 back out, but not strip the greenhouse that keeps its
  /// oceans liquid (down to the floor costs Earth about a kelvin). It
  /// is also near where algae and photolysis stop paying: plants starve of
  /// carbon not far below it.
  ///
  /// A column, not a partial pressure, because a partial pressure's moles
  /// move with the rest of the sky: on a Mars filling with oxygen the same
  /// 28 Pa is fifteen times the CO2 it was on bare Mars, so a floor judged
  /// at the start of one long warp step and one judged step by step left
  /// different skies. A column is a fixed number of moles for the world.
  final double co2FloorPa;

  /// Physical agent output of one Greenhouse Factory at full throttle
  /// (mol/s): ~94 g/s of octafluoropropane, ~3,000 t a year — a large
  /// fluorochemical plant (Gerstell et al. 2001 size Mars's need at a few
  /// hundred such plants over a century).
  ///
  /// At the shared [terraformRateScale], ten factories put the pascal of
  /// agent that warms Mars ~25 K into its sky in about three Mars years.
  final double greenhouseFactoryMolesPerSecond;

  /// The mean surface temperature (K) the warming towers — Greenhouse
  /// Factories and Regolith Bakers — work toward and stop at.
  ///
  /// The Earth limit for both, the counterpart of [oxygenTargetPa]: Earth
  /// already stands at 288.15 K, so neither ever runs there, and no
  /// forgotten factory programme can cook a world past a temperate one.
  /// The factory stops in closed form (the agent's depth inverts exactly,
  /// `PlanetAtmosphere.agentMolesForTemperature`); a baker stops at the
  /// first sub-step that finds the world warm enough.
  final double warmingTargetK;

  /// Share of each bakeable store (carbonates, nitrates) one Regolith Baker
  /// works through per second at full throttle, physical: a ~2,000 kg/s
  /// kiln line against the ~2e19 kg of near-surface regolith the stores are
  /// spread through.
  ///
  /// The bake is a turnover, not a fixed flow: each kilogram of soil baked
  /// gives up its share of every store, so the release is `k × store` and
  /// empties a store exponentially — bounded by what the world holds, exact
  /// over any step. Fifty bakers at the shared scale work through an e-fold
  /// of the stores in ~15 Mars years.
  final double bakerTurnoverPerSecond;

  /// Physical CO2 one Carbon Sequestrator takes into rock at full throttle
  /// (mol/s): ~44 kg/s, a direct-air-capture and mineralisation plant of the
  /// size a whole national programme plans today. Stops at [co2FloorPa].
  final double sequestratorMolesPerSecond;

  /// Share of the world's escape one full Atmospheric Retention Array
  /// suppresses (§7 Q2). Arrays compound — N of them leave `(1 − s)^N` of
  /// the leak — so each array halves what is left: ten hold a lunar sky a
  /// thousand times longer. Never quite all of it: there is always some
  /// sputtering a field cannot turn.
  final double retentionPerArray;

  /// Moles of O2 per second one tower vents at full throttle.
  double get oxygenatorRate => oxygenatorMolesPerSecond * terraformRateScale;

  /// Moles of agent per second one Greenhouse Factory emits at full throttle.
  double get greenhouseRate =>
      greenhouseFactoryMolesPerSecond * terraformRateScale;

  /// Turnover (1/s) of every bakeable store per Regolith Baker at full
  /// throttle.
  double get bakerRate => bakerTurnoverPerSecond * terraformRateScale;

  /// Moles of CO2 per second one Carbon Sequestrator removes at full throttle.
  double get sequestratorRate =>
      sequestratorMolesPerSecond * terraformRateScale;

  /// Escape suppression (0..1) [arrays] Retention Arrays hold a world at.
  double suppressionFor(double arrays) {
    if (arrays <= 0 || retentionPerArray <= 0) return 0;
    if (retentionPerArray >= 1) return 1;
    return 1 - math.pow(1 - retentionPerArray, arrays).toDouble();
  }
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
/// The tower family (§4, phase 3) runs in the same sub-steps: the Oxygenator
/// splits the sky's CO2 into the O2 it vents, the Greenhouse Factory's agent
/// rises toward the warming target and breaks down over its lifetime, the
/// Regolith Baker works through the soil's bound stores as an exponential
/// turnover, and the Carbon Sequestrator takes CO2 down to its floor. The
/// Retention Arrays set the escape suppression the leak is integrated under.
/// Methane beyond the reference oxidises to CO2 and water.
///
/// Every term is unconditionally stable: exponential relaxation cannot
/// overshoot, sinks stop at zero, and a reservoir gives up no more than it
/// holds. The haze relaxes exponentially as it always has. What each process
/// moved is left on the world as its [AtmosphereLedger].
class PlanetAtmosphereService {
  const PlanetAtmosphereService({
    this.tuning = const TerraformTuning(),
    this.escape = const AtmosphericEscape(),
    this.feedbacks = true,
    this.molesPerPollutionSecond = 5.0e3,
    this.aerosolRisePerPollution = 4.0e-5,
    this.aerosolSettleRate = 0.004,
    this.o2PerScrubbedPollution = 0.35,
    this.methaneLifetimeSeconds = 12 * _year,
    this.agentLifetimeSeconds = 2600 * _year,
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
        feedbacks = false,
        methaneLifetimeSeconds = 12 * _year,
        agentLifetimeSeconds = 2600 * _year;

  static const double _year = 3.15576e7;

  final TerraformTuning tuning;
  final AtmosphericEscape escape;

  /// Whether the planet answers: escape, volatile exchange and chemistry
  /// (methane oxidising, the agent breaking down).
  final bool feedbacks;

  /// E-folding lifetime (s) of methane in a sky beyond what its reference
  /// air holds: it oxidises, `CH4 + 2 O2 → CO2 + 2 H2O`.
  ///
  /// Twelve years is Earth's perturbation lifetime (IPCC AR6). Only the
  /// EXCESS decays, so a reference Titan — whose methane its lakes resupply
  /// on timescales no game watches — and Earth's 1.9 ppm rest exactly.
  /// Where the sky has no free oxygen to burn it with, the oxygen comes from
  /// the photolysis of water and from surface oxidants, and the sky is
  /// charged only the O2 it has. 0 stops the decay.
  final double methaneLifetimeSeconds;

  /// E-folding lifetime (s) of the super-greenhouse agent: C3F8 breaks down
  /// over ~2,600 years (IPCC AR6). Real, not compressed — so a Greenhouse
  /// Factory programme fills a sky once and then only tops it up. 0 holds
  /// it for ever.
  final double agentLifetimeSeconds;

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

  /// Advance [state] by [dt] seconds under [flows], and leave where the gas
  /// went in [PlanetAtmosphere.ledger].
  void advance(PlanetAtmosphere state, AtmosphereFlows flows,
      {required double dt}) {
    // The arrays set the world's suppression while they run: each colony
    // that reported sets its own count (its arrays over its own span), and
    // the world is held at their sum. A colony that did not report on this
    // step (one whose replays land next frame, or a world nobody is on)
    // keeps the count it last reported.
    if (flows.seconds > 0) {
      for (final e in flows.byColony.entries) {
        final c = e.value;
        if (c.seconds > 0) state.reportArrays(e.key, c.retention / c.seconds);
      }
      state.escapeSuppression = tuning.suppressionFor(state.retentionArrays);
    }
    if (dt <= 0) {
      _applyAmounts(state, flows);
      return;
    }
    final ledger = AtmosphereLedger(seconds: dt);
    final t0 = state.surfaceTemperatureK;

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
      agent: flows.greenhouseRun * tuning.greenhouseRate / dt,
      bake: flows.bakerRun * tuning.bakerRate / dt,
      sequester: flows.sequestratorRun * tuning.sequestratorRate / dt,
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
      _flowsAndEscape(state, rates, h, ledger);
      _towers(state, rates, h, ledger);
      if (feedbacks) {
        _chemistry(state, h, ledger);
        _exchange(state, h, ledger);
      }
    }
    if (feedbacks) state.pruneTrace(traceMoles);
    _attribute(ledger, flows, dt);
    _publishLedger(state, ledger, dt, flows.seconds, t0);
  }

  /// Fold this integration's [step] into the world's ledger window, and
  /// publish the window unless the world is waiting on a colony's late
  /// report (see [AtmosphereLedgerWindow]).
  void _publishLedger(PlanetAtmosphere state, AtmosphereLedger step,
      double dt, double flowSeconds, double t0) {
    final window = state.ledgerWindow ??=
        AtmosphereLedgerWindow(startTemperatureK: t0);
    window.absorb(step, dt, flowSeconds);
    final waiting = flowSeconds <= 0 &&
        (state.ledger?.coloniesReported ?? false) &&
        window.steps < AtmosphereLedgerWindow.maxSteps;
    if (waiting) return;
    state.ledger = window.publish(state.surfaceTemperatureK);
    state.ledgerWindow = null;
  }

  /// Drop the Retention Arrays of every colony on [state]'s world not in
  /// [present], and let the world's suppression follow at once — a colony
  /// that is gone runs no arrays, and with nobody left to report the
  /// suppression would otherwise hold for ever.
  void forgetColonies(PlanetAtmosphere state, Set<String> present) {
    if (!state.forgetColoniesExcept(present)) return;
    state.escapeSuppression = tuning.suppressionFor(state.retentionArrays);
  }

  /// Share each process colonies run out among the colonies that ran it, by
  /// how much of it each ran: what the planet ACTUALLY took (after every
  /// cap, floor and empty store), not what each colony's towers asked for.
  /// Industry is the exception, credited at each colony's own nominal CO2,
  /// because one colony's scrubbing and another's smoke net out in the sky
  /// but not in who did what.
  void _attribute(AtmosphereLedger ledger, AtmosphereFlows flows, double dt) {
    final colonies = flows.byColony;
    if (colonies.isEmpty) return;
    void share(
        GasProcess p, double total, double Function(ColonyFlowAmounts) of) {
      final rates = ledger.totals[p];
      if (rates == null || total <= 0) return;
      for (final e in colonies.entries) {
        final f = of(e.value) / total;
        if (f <= 0) continue;
        for (final g in rates.entries) {
          ledger.addColonyRate(e.key, e.value.name, p, g.key, g.value * f);
        }
      }
    }

    share(GasProcess.oxygenator, flows.oxygenatorRun, (c) => c.oxygenator);
    share(GasProcess.harvester, flows.o2Harvested, (c) => c.harvest);
    share(GasProcess.greenhouse, flows.greenhouseRun, (c) => c.greenhouse);
    share(GasProcess.baker, flows.bakerRun, (c) => c.baker);
    share(GasProcess.sequestrator, flows.sequestratorRun,
        (c) => c.sequestrator);
    for (final e in colonies.entries) {
      final co2 = e.value.pollution * molesPerPollutionSecond / dt;
      if (co2 != 0) {
        ledger.addColonyRate(e.key, e.value.name, GasProcess.industry,
            AtmosphereGas.carbonDioxide.name, co2);
      }
    }
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
    final aboveFloor = co2AboveFloor(state);
    final vent = math.min(
        flows.oxygenatorRun * tuning.oxygenatorRate, oxygenHeadroom(state));
    if (vent > 0) {
      state.add(AtmosphereGas.oxygen, vent);
      state.add(AtmosphereGas.carbonDioxide, -math.min(vent, aboveFloor));
    }
    final agent = math.min(
        flows.greenhouseRun * tuning.greenhouseRate, agentHeadroom(state));
    if (agent > 0) state.greenhouseAgentMoles += agent;
    if (flows.bakerRun > 0 && _warmingWanted(state)) {
      _bake(state, flows.bakerRun * tuning.bakerRate, null);
    }
    final taken = math.min(flows.sequestratorRun * tuning.sequestratorRate,
        co2AboveFloor(state));
    if (taken > 0) state.add(AtmosphereGas.carbonDioxide, -taken);
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
      surfacePressurePa: state.surfacePressurePa,
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

  /// One sub-step of the colonies' industry, oxygen and escape, each gas in
  /// closed form for its source and leak held constant.
  void _flowsAndEscape(PlanetAtmosphere state, _Rates rates, double h,
      AtmosphereLedger ledger) {
    final k = escapeRates(state);
    void leaked(AtmosphereGas g, double n0, double s, double after) {
      // What the leak took: where the gas would have stood with its source
      // and no leak, less where it stands.
      final lost = math.max(0.0, n0 + s * h) - after;
      if (lost > 0) ledger.addAmount(GasProcess.escape, g.name, -lost);
    }

    // Industry and scrubbing: CO2 in, or CO2 out with oxygen returned for
    // what was REALLY removed — the difference the scrubbers made to where
    // the CO2 would otherwise have ended up.
    final co2Rate = rates.co2;
    final kc = k[AtmosphereGas.carbonDioxide] ?? 0;
    final co2Before = state.molesOf(AtmosphereGas.carbonDioxide);
    final co2After = _sourceAndLeak(co2Before, co2Rate, kc, h);
    var scrubbedO2 = 0.0;
    var industryCo2 = co2Rate * h;
    if (co2Rate < 0) {
      final unscrubbed = _sourceAndLeak(co2Before, 0, kc, h);
      scrubbedO2 = math.max(0.0, unscrubbed - co2After) * o2PerScrubbedPollution;
      industryCo2 = co2After - unscrubbed;
    }
    state.add(AtmosphereGas.carbonDioxide, co2After - co2Before);
    ledger.addAmount(
        GasProcess.industry, AtmosphereGas.carbonDioxide.name, industryCo2);
    if (kc > 0) leaked(AtmosphereGas.carbonDioxide, co2Before, co2Rate, co2After);

    // Oxygen: towers vent toward the target and stop at it — judged against
    // the air after this sub-step's industry — harvesters draw it out, and
    // it leaks like any gas. The cap is a ceiling on what VENTING may
    // reach: harvesting below it, or a sky already past it, is untouched.
    final o2Before = state.molesOf(AtmosphereGas.oxygen);
    final aboveFloor = rates.vent > 0 ? co2AboveFloor(state) : 0.0;
    final cap = rates.vent > 0
        ? oxygenCapMoles(state, aboveFloor)
        : state.molesForPartialPressure(
            state.moles, AtmosphereGas.oxygen, tuning.oxygenTargetPa);
    final venting = rates.vent > 0 && o2Before < cap;
    final ko = k[AtmosphereGas.oxygen] ?? 0;
    var o2After = _sourceAndLeak(
        o2Before, (venting ? rates.vent : 0) - rates.harvest, ko, h);
    final capped = venting && o2After > cap;
    if (capped) o2After = cap;
    state.add(AtmosphereGas.oxygen, o2After - o2Before + scrubbedO2);
    if (scrubbedO2 > 0) {
      ledger.addAmount(
          GasProcess.industry, AtmosphereGas.oxygen.name, scrubbedO2);
    }
    final harvested = math.min(rates.harvest * h, math.max(0.0, o2Before));
    if (harvested > 0) {
      ledger.addAmount(
          GasProcess.harvester, AtmosphereGas.oxygen.name, -harvested);
    }

    // The Oxygenator is CO2 → O2: what it vented came out of the sky's CO2
    // while there is any above the floor, a mole for a mole (the carbon goes
    // into the towers' biomass and carbonate). Past that it splits the
    // crust — lunar regolith is ~45% oxygen by mass, and molten-regolith
    // electrolysis is the route — so a world with no CO2 to spare still gets
    // its O2, and a world with some spends it.
    if (venting) {
      final unvented = _sourceAndLeak(o2Before, -rates.harvest, ko, h);
      final vented = math.max(0.0, o2After - unvented);
      if (ko > 0) {
        // Where the cap clipped the vent, the clip is not a leak: the gas
        // the towers would have put past it was never vented. Measured
        // against the clipped sky it booked that whole excess as escape —
        // several times the real leak on a world held at the cap, every
        // other step. The towers top the sky up to the cap from where it
        // would have leaked to unvented, so the leak is the unvented path's.
        if (capped) {
          leaked(AtmosphereGas.oxygen, o2Before, -rates.harvest, unvented);
        } else {
          leaked(AtmosphereGas.oxygen, o2Before, rates.vent - rates.harvest,
              o2After);
        }
      }
      if (vented > 0) {
        final fromSky = math.min(vented, aboveFloor);
        if (fromSky > 0) state.add(AtmosphereGas.carbonDioxide, -fromSky);
        ledger
          ..addAmount(GasProcess.oxygenator, AtmosphereGas.oxygen.name, vented)
          ..addAmount(GasProcess.oxygenator, AtmosphereGas.carbonDioxide.name,
              -fromSky);
      }
    } else if (ko > 0) {
      leaked(AtmosphereGas.oxygen, o2Before, -rates.harvest, o2After);
    }

    // Every other gas only leaks.
    for (final e in k.entries) {
      final g = e.key;
      if (g == AtmosphereGas.carbonDioxide || g == AtmosphereGas.oxygen) {
        continue;
      }
      final n = state.molesOf(g);
      if (n <= 0) continue;
      final after = _sourceAndLeak(n, 0, e.value, h);
      state.add(g, after - n);
      leaked(g, n, 0, after);
    }
  }

  /// One sub-step of the rest of the tower family: the Greenhouse Factory's
  /// agent, the Regolith Baker, the Carbon Sequestrator. Each stops at its
  /// Earth limit — the warming target, the CO2 floor — and none takes more
  /// than is there.
  void _towers(PlanetAtmosphere state, _Rates rates, double h,
      AtmosphereLedger ledger) {
    // The agent: emitted toward the warming target and stopped there (the
    // target in closed form), and breaking down over its lifetime, both
    // exactly over the sub-step.
    final a0 = state.greenhouseAgentMoles;
    final kd =
        feedbacks && agentLifetimeSeconds > 0 ? 1 / agentLifetimeSeconds : 0.0;
    if (rates.agent > 0 || (a0 > 0 && kd > 0)) {
      final undriven = _sourceAndLeak(a0, 0, kd, h);
      var after = undriven;
      if (rates.agent > 0) {
        final cap = a0 + agentHeadroom(state);
        if (a0 < cap) {
          after = math.max(undriven,
              math.min(cap, _sourceAndLeak(a0, rates.agent, kd, h)));
        }
      }
      state.greenhouseAgentMoles = after;
      final emitted = after - undriven;
      if (emitted > 0) {
        ledger.addAmount(GasProcess.greenhouse, agentGasKey, emitted);
      }
      final broke = a0 - undriven;
      if (broke > 0) {
        ledger.addAmount(GasProcess.chemistry, agentGasKey, -broke);
      }
    }

    // The baker, while the world is still colder than the target.
    if (rates.bake > 0 && _warmingWanted(state)) {
      _bake(state, rates.bake * h, ledger);
    }

    // The sequestrator, down to the floor.
    if (rates.sequester > 0) {
      final taken = math.min(rates.sequester * h, co2AboveFloor(state));
      if (taken > 0) {
        state.add(AtmosphereGas.carbonDioxide, -taken);
        ledger.addAmount(GasProcess.sequestrator,
            AtmosphereGas.carbonDioxide.name, -taken);
      }
    }
  }

  /// Bake a [turnover] (Σ rate × time) through every bakeable store: each
  /// gives up `1 − e^(−turnover)` of what it holds — every kilogram of soil
  /// baked gives up its share of every store — so a store empties
  /// exponentially and never past empty, whatever the step.
  void _bake(
      PlanetAtmosphere state, double turnover, AtmosphereLedger? ledger) {
    if (turnover <= 0) return;
    final f = 1 - math.exp(-turnover);
    for (final r in state.reservoirs) {
      if (!r.bakeable || r.moles <= 0) continue;
      final d = r.moles * f;
      r.moles = math.max(0.0, r.moles - d);
      state.add(r.gas, d);
      ledger?.addAmount(GasProcess.baker, r.gas.name, d);
    }
  }

  /// Whether the warming towers still have work: the world is colder than
  /// [TerraformTuning.warmingTargetK].
  bool _warmingWanted(PlanetAtmosphere state) =>
      state.surfaceTemperatureK < tuning.warmingTargetK;

  /// One sub-step of the sky's own chemistry: methane beyond the reference
  /// oxidises (`CH4 + 2 O2 → CO2 + 2 H2O`), exactly over the sub-step.
  void _chemistry(PlanetAtmosphere state, double h, AtmosphereLedger ledger) {
    if (methaneLifetimeSeconds <= 0) return;
    final excess = state.molesOf(AtmosphereGas.methane) -
        state.referenceMolesOf(AtmosphereGas.methane);
    if (excess <= 0) return;
    final d = excess * (1 - math.exp(-h / methaneLifetimeSeconds));
    if (d <= 0) return;
    state
      ..add(AtmosphereGas.methane, -d)
      ..add(AtmosphereGas.carbonDioxide, d)
      ..add(AtmosphereGas.water, 2 * d);
    final burned = -state.add(AtmosphereGas.oxygen, -2 * d);
    ledger
      ..addAmount(GasProcess.chemistry, AtmosphereGas.methane.name, -d)
      ..addAmount(GasProcess.chemistry, AtmosphereGas.carbonDioxide.name, d)
      ..addAmount(GasProcess.chemistry, AtmosphereGas.water.name, 2 * d)
      ..addAmount(GasProcess.chemistry, AtmosphereGas.oxygen.name, -burned);
  }

  /// Moles of CO2 the sky holds above [TerraformTuning.co2FloorPa]: what the
  /// carbon-removing towers may still take.
  double co2AboveFloor(PlanetAtmosphere state) {
    final n = state.molesOf(AtmosphereGas.carbonDioxide);
    if (n <= 0) return 0;
    final perMole = state.pascalsPerKg *
        AtmosphericComposition.molarMass[AtmosphereGas.carbonDioxide]!;
    final floor = perMole > 0 ? tuning.co2FloorPa / perMole : 0.0;
    return math.max(0.0, n - floor);
  }

  /// Moles of agent the Greenhouse Factories may still add before the world
  /// reaches [TerraformTuning.warmingTargetK]; 0 at or past it.
  double agentHeadroom(PlanetAtmosphere state) => math.max(
      0.0,
      state.agentMolesForTemperature(tuning.warmingTargetK) -
          state.greenhouseAgentMoles);

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
  void _exchange(PlanetAtmosphere state, double h, AtmosphereLedger ledger) {
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
      if (d != 0) {
        state.add(g, d);
        ledger.addAmount(GasProcess.exchange, g.name, d);
      }
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

  /// The O2 inventory (mol) at which the Oxygenators' vent reaches
  /// [TerraformTuning.oxygenTargetPa], given that the first [aboveFloor]
  /// moles it vents are SPLIT from the sky's CO2 — a mole of CO2 out for
  /// each mole of O2 in — and the rest comes from the crust.
  ///
  /// The split matters to where the cap falls. It leaves the mole count
  /// alone and lightens the column by `M_CO2 − M_O2` per mole, so the O2
  /// partial pressure `k (n + Δ)(m + (M_O2 − M_CO2) Δ) / N` is a quadratic in
  /// the vented Δ; solved against the ordinary mix, the cap overshot and the
  /// CO2 the vent then split pulled the sky back under the target. Past the
  /// sky's CO2 the remainder is the ordinary cap on the split-out mix.
  double oxygenCapMoles(PlanetAtmosphere state, double aboveFloor) {
    const o2 = AtmosphereGas.oxygen;
    const co2 = AtmosphereGas.carbonDioxide;
    final target = tuning.oxygenTargetPa;
    final m = state.moles;
    final n = m[o2] ?? 0;
    if (aboveFloor > 0) {
      final k = state.pascalsPerKg;
      final total = m.values.fold(0.0, (s, v) => s + v);
      final mass = state.massKg;
      final dm = AtmosphericComposition.molarMass[o2]! -
          AtmosphericComposition.molarMass[co2]!;
      if (k > 0 && total > 0) {
        final c = k * n * mass / total - target;
        if (c >= 0) return n; // already there
        final a = k * dm / total;
        final b = k * (n * dm + mass) / total;
        final disc = b * b - 4 * a * c;
        if (disc >= 0 && b > 0) {
          // The smaller positive root, in the stable form.
          final d = 2 * c / (-b - math.sqrt(disc));
          if (d >= 0 && d <= aboveFloor) return n + d;
        }
      }
      // The sky's CO2 runs out first: split all of it, then cap the rest.
      final split = Map<AtmosphereGas, double>.of(m)
        ..[co2] = math.max(0.0, (m[co2] ?? 0) - aboveFloor)
        ..[o2] = n + aboveFloor;
      return math.max(
          n + aboveFloor, state.molesForPartialPressure(split, o2, target));
    }
    return state.molesForPartialPressure(m, o2, target);
  }

  /// Moles of O2 that can still be vented before the surface O2 partial
  /// pressure reaches [TerraformTuning.oxygenTargetPa]; 0 at or past it.
  ///
  /// Closed form ([oxygenCapMoles]) rather than stepped, so the cap does not
  /// depend on how time was chopped.
  double oxygenHeadroom(PlanetAtmosphere state) {
    if (tuning.oxygenTargetPa <= 0) return 0;
    final cap = oxygenCapMoles(state, co2AboveFloor(state));
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

/// The colonies' flows over one step, as rates (mol/s; 1/s for the bake).
class _Rates {
  const _Rates({
    required this.co2,
    required this.vent,
    required this.harvest,
    required this.agent,
    required this.bake,
    required this.sequester,
  });

  /// Greenhouse agent the factories emit, before the warming target.
  final double agent;

  /// Turnover of every bakeable store (1/s).
  final double bake;

  /// CO2 the sequestrators take, before the floor.
  final double sequester;

  /// Net industrial CO2 (negative = scrubbing).
  final double co2;

  /// Tower oxygen at full output, before the cap.
  final double vent;

  /// Oxygen the harvesters take out.
  final double harvest;
}
