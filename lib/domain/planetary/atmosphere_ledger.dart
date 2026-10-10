// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a planet's gas went over its last integration, as rates
/// (docs/plans/terraforming.md §6 phase 3, the atmosphere panel).
///
/// The inventory says what the sky IS; this says what is DOING it. Without it
/// a player watching Mars's pressure fall has no way to tell that their own
/// Oxygenators are eating the CO2 their Regolith Bakers free, or that the
/// cap is freezing it out faster than either — and every one of those is a
/// different decision. A readout, not state: rebuilt as the world
/// integrates, never saved, never fingerprinted.
library;

import 'dart:math' as math;

/// What moved a gas.
enum GasProcess {
  /// Industry's CO2 and haze, net of the scrubbing negative-pollution
  /// buildings do (with the oxygen scrubbing returns).
  industry('Industry'),

  /// Terraforming Towers: CO2 → O2, and O2 from the crust where the sky has
  /// no CO2 left to split.
  oxygenator('Terraforming Towers'),

  /// Atmospheric Harvesters taking O2 into a colony's stock.
  harvester('O₂ Harvesters'),

  /// Greenhouse Factories' super-greenhouse agent.
  greenhouse('Greenhouse Factories'),

  /// Regolith Bakers freeing CO2 and N2 from the soil's carbonates and
  /// nitrates.
  baker('Regolith Bakers'),

  /// Carbon Sequestrators taking CO2 into rock.
  sequestrator('Carbon Sequestrators'),

  /// Gas lost to space.
  escape('Escape to space'),

  /// Caps and soil giving gas up (positive) or freezing it out (negative).
  exchange('Polar caps & soil'),

  /// Methane oxidising to CO2 and water, and the agent breaking down.
  chemistry('Chemistry');

  const GasProcess(this.label);

  /// The panel's name for it.
  final String label;

  /// Whether a colony runs it (so it can be attributed to one).
  bool get byColony =>
      this != escape && this != exchange && this != chemistry;
}

/// The gas key the ledger uses for the super-greenhouse agent, which is not
/// one of the air's gases.
const String agentGasKey = 'agent';

/// One colony's share of the ledger.
class ColonyGasLedger {
  ColonyGasLedger(this.name);

  /// The colony's name, as it recorded it.
  final String name;

  /// mol/s per gas (`AtmosphereGas.name`, or [agentGasKey]) per process;
  /// positive adds to the sky.
  final Map<GasProcess, Map<String, double>> rates = {};

  void _add(GasProcess p, String gas, double rate) {
    if (rate == 0 || !rate.isFinite) return;
    final m = rates.putIfAbsent(p, () => {});
    m[gas] = (m[gas] ?? 0) + rate;
  }
}

/// A body's gas flows over its last integration — or, where a colony's
/// flows land late, over the integrations since its last report (see
/// [AtmosphereLedgerWindow]).
class AtmosphereLedger {
  AtmosphereLedger({required this.seconds, this.coloniesReported = false});

  /// The span the rates are averaged over (s).
  final double seconds;

  /// Whether any colony's flows landed in the span. A world whose last
  /// ledger had them holds it through the integrations no colony reports on
  /// (see [AtmosphereLedgerWindow]).
  final bool coloniesReported;

  /// mol/s per gas per process over the whole world; positive adds to the
  /// sky.
  final Map<GasProcess, Map<String, double>> totals = {};

  /// Each colony's share of the processes colonies run, by colony id.
  final Map<String, ColonyGasLedger> colonies = {};

  /// How fast the mean surface temperature moved over the step (K/s).
  double temperatureRateKPerS = 0;

  /// Record [amount] mol of [gas] moved by [process] over [seconds].
  void addAmount(GasProcess process, String gas, double amount) {
    if (seconds <= 0 || amount == 0 || !amount.isFinite) return;
    final m = totals.putIfAbsent(process, () => {});
    m[gas] = (m[gas] ?? 0) + amount / seconds;
  }

  /// Record that colony [id] ([name]) moved [rate] mol/s of [gas] by
  /// [process].
  void addColonyRate(
      String id, String name, GasProcess process, String gas, double rate) {
    colonies.putIfAbsent(id, () => ColonyGasLedger(name))
        ._add(process, gas, rate);
  }

  /// World rate of [gas] by [process] (mol/s), 0 if none.
  double rate(GasProcess process, String gas) => totals[process]?[gas] ?? 0;

  /// Net rate of [gas] over every process (mol/s).
  double net(String gas) {
    var s = 0.0;
    for (final m in totals.values) {
      s += m[gas] ?? 0;
    }
    return s;
  }
}

/// Integrations accumulating toward the next published [AtmosphereLedger].
///
/// A frame-budgeted colony's replayed ticks all land in the first tick of
/// the next frame, so when a frame runs two ticks one integration carries
/// two ticks of its towers and the next carries none. Published per
/// integration, the panel's tower and colony lines alternated between twice
/// the real rate and nothing, the trend between warming twice as fast and
/// cooling — and the repaint, reading the frame's last tick, saw only the
/// empty one. So a world whose last ledger carried colony flows holds it
/// through the integrations no colony reports on, and the next report
/// publishes the whole window at once: the gas each process moved over it,
/// over its span.
class AtmosphereLedgerWindow {
  AtmosphereLedgerWindow({required this.startTemperatureK});

  /// Integrations a window may hold before it is published regardless —
  /// how long a world whose colonies have all gone keeps the last of their
  /// lines. Far past the most ticks one frame runs.
  static const int maxSteps = 64;

  /// The mean surface temperature when the window opened (K).
  final double startTemperatureK;

  /// Sim time integrated (s).
  double seconds = 0;

  /// Integrations taken.
  int steps = 0;

  /// The span of the colonies' steps whose flows landed in the window: the
  /// time the towers' share was PRODUCED over. A report can cover more time
  /// than the window (the first frame of replays lands in one tick), so the
  /// colony processes are rates over the longer of the two.
  double colonySeconds = 0;

  final Map<GasProcess, Map<String, double>> _amounts = {};
  final Map<String, ColonyGasLedger> _colonies = {};

  /// Add one integration of [dt] seconds whose rates are [step], and whose
  /// colony flows covered [flowSeconds] (0 when none reported).
  void absorb(AtmosphereLedger step, double dt, double flowSeconds) {
    if (dt <= 0) return;
    seconds += dt;
    steps++;
    colonySeconds += flowSeconds;
    for (final p in step.totals.entries) {
      final m = _amounts.putIfAbsent(p.key, () => {});
      for (final g in p.value.entries) {
        m[g.key] = (m[g.key] ?? 0) + g.value * dt;
      }
    }
    for (final c in step.colonies.entries) {
      final into =
          _colonies.putIfAbsent(c.key, () => ColonyGasLedger(c.value.name));
      for (final p in c.value.rates.entries) {
        for (final g in p.value.entries) {
          into._add(p.key, g.key, g.value * dt);
        }
      }
    }
  }

  /// The window as a ledger of rates, the trend read against
  /// [endTemperatureK].
  AtmosphereLedger publish(double endTemperatureK) {
    final ledger = AtmosphereLedger(
        seconds: seconds, coloniesReported: colonySeconds > 0);
    if (seconds <= 0) return ledger;
    final colonySpan = math.max(seconds, colonySeconds);
    for (final p in _amounts.entries) {
      final span = p.key.byColony ? colonySpan : seconds;
      final m = ledger.totals.putIfAbsent(p.key, () => {});
      for (final g in p.value.entries) {
        if (g.value != 0) m[g.key] = g.value / span;
      }
    }
    for (final c in _colonies.entries) {
      for (final p in c.value.rates.entries) {
        for (final g in p.value.entries) {
          ledger.addColonyRate(
              c.key, c.value.name, p.key, g.key, g.value / colonySpan);
        }
      }
    }
    ledger.temperatureRateKPerS =
        (endTemperatureK - startTemperatureK) / seconds;
    return ledger;
  }
}
