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
/// different decision. A readout, not state: rebuilt on every integration,
/// never saved, never fingerprinted.
library;

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

/// A body's gas flows over its last integration.
class AtmosphereLedger {
  AtmosphereLedger({required this.seconds});

  /// The step the rates are averaged over (s).
  final double seconds;

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
