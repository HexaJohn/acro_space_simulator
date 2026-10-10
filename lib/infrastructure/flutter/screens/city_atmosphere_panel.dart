// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony's planet's air, and who is changing it
/// (docs/plans/terraforming.md §6 phase 3).
///
/// Once towers changed a real gas inventory, a single "terraforming %" could
/// no longer tell a player anything they could act on. A Mars whose pressure
/// is falling might be leaking, freezing onto its cap, or being eaten by the
/// player's own Oxygenators — and each wants a different building. So this
/// shows the world's state (pressure, mix, temperature and its trend,
/// escape and how much of it is held, the stores in the ground) next to the
/// planetary ledger's rates, by process and by colony, all in pascals a year:
/// what each actually does to the column a person stands under.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/planetary/atmospheric_composition.dart';
import '../../../domain/planetary/planet_atmosphere.dart';
import '../../../domain/planetary/planet_atmosphere_service.dart';
import '../../../domain/planetary/volatile_reservoir.dart';
import 'app_theme.dart';

/// Seconds in a year, for the panel's per-year rates.
const double _year = 3.15576e7;

/// The atmosphere panel for [city]'s world. Reads the inventory the host
/// integrates ([CitySim.planetAir]); without one it shows the body's air
/// alone and says why nothing else is there.
class AtmospherePanel extends StatelessWidget {
  const AtmospherePanel({super.key, required this.city});

  final CitySim city;

  @override
  Widget build(BuildContext context) {
    final body = city.body;
    final air = body.atmosphere;
    final mix = body.composition;
    final state = city.planetAir;
    final sky = city.sky;
    final progress = city.terraform;
    final rows = <Widget>[
      _row('Surface pressure',
          air == null ? 'vacuum' : _pressure(air.seaLevelPressure),
          key: const Key('atmo-pressure')),
      _row('Surface temperature', _temperature(sky.temperatureK, state),
          key: const Key('atmo-temperature')),
      _meter('Progress to breathable', progress,
          progress >= 1 ? AppTheme.accent2 : AppTheme.accent,
          key: const Key('atmo-progress')),
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(_breathingNote(sky.o2Fraction, sky.pressureAtm,
                sky.toxicFraction, progress >= 1),
            style: AppTheme.dim.copyWith(fontSize: 11)),
      ),
    ];

    // The gas mix, biggest first.
    if (mix != null && air != null) {
      rows.add(_sub('GAS MIX'));
      final gases = mix.fractions.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in gases) {
        if (e.value < 1e-6) continue;
        rows.add(_row(_gasName(e.key),
            '${_percent(e.value)}  ${_pressure(e.value * air.seaLevelPressure)}',
            key: Key('atmo-gas-${e.key.name}')));
      }
    }
    if (state != null && state.greenhouseAgentMoles > 0) {
      rows.add(_row('Greenhouse agent (PFC)',
          _pressure(state.agentPartialPressurePa),
          key: const Key('atmo-agent')));
    }

    if (state == null) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
            "Nothing here integrates ${body.name}'s air, so its towers change "
            'no gas and the readouts above stay at the reference.',
            style: AppTheme.dim.copyWith(fontSize: 11)),
      ));
      return Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: rows);
    }

    final ledger = state.ledger;

    // Escape, and how much of it the Retention Arrays hold.
    rows.add(_sub('ESCAPE TO SPACE'));
    final leak = ledger == null ? 0.0 : _columnRate(state, ledger.totals[GasProcess.escape]);
    rows.add(_row('Lost to space',
        leak == 0 ? 'none measurable' : _paPerYear(leak),
        key: const Key('atmo-escape')));
    rows.add(_row('Held by Retention Arrays',
        '${(state.escapeSuppression * 100).toStringAsFixed(state.escapeSuppression > 0.99 ? 2 : 0)}%',
        key: const Key('atmo-suppression')));

    // The stores in the ground.
    if (state.reservoirs.isNotEmpty) {
      rows.add(_sub('STORES IN THE GROUND'));
      for (final r in state.reservoirs) {
        final share = r.referenceMoles > 0 ? r.moles / r.referenceMoles : 0.0;
        rows.add(_row(_storeName(r),
            '${_pressure(r.moles * AtmosphericComposition.molarMass[r.gas]! * state.pascalsPerKg)}'
            '  (${(share * 100).toStringAsFixed(share < 0.995 && share > 0.985 ? 1 : 0)}%)',
            key: Key('atmo-store-${r.name}')));
      }
    }

    // Who is doing what.
    rows.add(_sub('WHAT IS CHANGING IT'));
    if (ledger == null || ledger.totals.isEmpty) {
      rows.add(Text('Nothing is moving this sky.',
          style: AppTheme.dim.copyWith(fontSize: 11)));
    } else {
      for (final p in GasProcess.values) {
        final rates = ledger.totals[p];
        if (rates == null) continue;
        final line = _ratesLine(state, rates);
        if (line.isEmpty) continue;
        rows.add(_row(p.label, line, key: Key('atmo-process-${p.name}')));
      }
      final ids = ledger.colonies.keys.toList()..sort();
      if (ids.isNotEmpty) rows.add(_sub('BY COLONY'));
      for (final id in ids) {
        final c = ledger.colonies[id]!;
        final name = id == city.id
            ? '${c.name.isEmpty ? city.name : c.name} (this colony)'
            : (c.name.isEmpty ? id : c.name);
        final parts = <String>[];
        for (final p in GasProcess.values) {
          final rates = c.rates[p];
          if (rates == null) continue;
          final line = _ratesLine(state, rates);
          if (line.isNotEmpty) parts.add('${p.label}: $line');
        }
        if (parts.isEmpty) continue;
        rows.add(Padding(
          key: Key('atmo-colony-$id'),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: AppTheme.body),
            for (final s in parts)
              Text(s, style: AppTheme.mono.copyWith(fontSize: 11)),
          ]),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ---- formatting ----------------------------------------------------------

  static Widget _sub(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(t, style: AppTheme.dim.copyWith(fontSize: 11)),
      );

  static Widget _row(String k, String v, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(k, style: AppTheme.body)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.right,
                style: AppTheme.mono.copyWith(fontSize: 12)),
          ),
        ]),
      );

  static Widget _meter(String label, double ratio, Color color, {Key? key}) =>
      Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label, style: AppTheme.body)),
            Text('${(ratio * 100).floor()}%',
                style: AppTheme.mono.copyWith(color: color)),
          ]),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
                value: ratio.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: AppTheme.panelLight,
                color: color),
          ),
        ]),
      );

  /// What still stands between this sky and breathable: the tests it fails.
  static String _breathingNote(
      double o2, double atm, double toxic, bool breathable) {
    if (breathable) return 'Breathable: people walk outside unaided.';
    final miss = <String>[
      if (o2 < 0.15) 'oxygen ${_percent(o2)} of 15%',
      if (atm < 0.5) 'pressure ${atm.toStringAsFixed(atm < 0.1 ? 3 : 2)} of 0.5 atm',
      if (toxic >= 0.2) 'CO₂ and methane ${_percent(toxic)} (under 20%)',
    ];
    return 'Still short: ${miss.join('; ')}.';
  }

  static String _temperature(double k, PlanetAtmosphere? state) {
    final c = '${(k - 273.15).toStringAsFixed(0)} °C';
    final rate = state?.ledger?.temperatureRateKPerS ?? 0;
    final perYear = rate * _year;
    if (perYear.abs() < 1e-3) return c;
    final dir = perYear > 0 ? 'warming' : 'cooling';
    return '$c, $dir ${_significant(perYear.abs())} K/yr';
  }

  /// The column-weight rate (Pa/s) of a ledger entry: each gas's mol/s by
  /// its molar mass.
  static double _columnRate(PlanetAtmosphere state, Map<String, double>? rates) {
    if (rates == null) return 0;
    var s = 0.0;
    for (final e in rates.entries) {
      s += _paPerSecond(state, e.key, e.value);
    }
    return s;
  }

  static double _paPerSecond(PlanetAtmosphere state, String gas, double molPerSec) {
    if (gas == agentGasKey) {
      return molPerSec * PlanetAtmosphere.agentMolarMass * state.pascalsPerKg;
    }
    for (final g in AtmosphereGas.values) {
      if (g.name == gas) {
        return molPerSec * AtmosphericComposition.molarMass[g]! * state.pascalsPerKg;
      }
    }
    return 0;
  }

  /// "O₂ +1.2 kPa/yr, CO₂ −900 Pa/yr" for a ledger entry, gases that move
  /// less than a micropascal a year left out.
  static String _ratesLine(PlanetAtmosphere state, Map<String, double> rates) {
    final parts = <String>[];
    final keys = rates.keys.toList()..sort();
    for (final gas in keys) {
      final pa = _paPerSecond(state, gas, rates[gas]!) * _year;
      if (pa.abs() < 1e-6) continue;
      parts.add('${_gasKeyName(gas)} ${_paPerYear(pa / _year)}');
    }
    return parts.join(', ');
  }

  static String _gasKeyName(String key) {
    if (key == agentGasKey) return 'PFC';
    for (final g in AtmosphereGas.values) {
      if (g.name == key) return _gasName(g);
    }
    return key;
  }

  static String _gasName(AtmosphereGas g) => switch (g) {
        AtmosphereGas.nitrogen => 'N₂',
        AtmosphereGas.oxygen => 'O₂',
        AtmosphereGas.carbonDioxide => 'CO₂',
        AtmosphereGas.hydrogen => 'H₂',
        AtmosphereGas.helium => 'He',
        AtmosphereGas.methane => 'CH₄',
        AtmosphereGas.argon => 'Ar',
        AtmosphereGas.water => 'H₂O',
      };

  static String _storeName(VolatileReservoir r) => switch (r.name) {
        'polarCo2' => 'Polar CO₂ ice',
        'regolithCo2' => 'CO₂ held in the soil',
        'polarWater' => 'Polar water ice',
        'carbonates' => 'Carbonates (bakeable)',
        'nitrates' => 'Nitrates (bakeable)',
        _ => r.name,
      };

  static String _percent(double x) {
    final p = x * 100;
    if (p >= 10) return '${p.toStringAsFixed(1)}%';
    if (p >= 0.1) return '${p.toStringAsFixed(2)}%';
    return '${_significant(p)}%';
  }

  static String _pressure(double pa) {
    if (pa >= 1e5) return '${(pa / 101325).toStringAsFixed(2)} atm';
    if (pa >= 1e3) return '${(pa / 1e3).toStringAsFixed(1)} kPa';
    return '${_significant(pa)} Pa';
  }

  /// A rate in Pa/s as a signed column change per year.
  static String _paPerYear(double paPerSecond) {
    final y = paPerSecond * _year;
    final sign = y > 0 ? '+' : '−';
    final a = y.abs();
    final v = a >= 1e3 ? '${_significant(a / 1e3)} kPa' : '${_significant(a)} Pa';
    return '$sign$v/yr';
  }

  /// Three significant figures, without scientific notation for the ranges
  /// a panel shows.
  static String _significant(double v) {
    if (v == 0) return '0';
    final a = v.abs();
    if (a >= 100) return v.toStringAsFixed(0);
    if (a < 1e-3) return v.toStringAsExponential(1);
    final digits = (2 - (math.log(a) / math.ln10).floor()).clamp(0, 6);
    return v.toStringAsFixed(digits);
  }
}
