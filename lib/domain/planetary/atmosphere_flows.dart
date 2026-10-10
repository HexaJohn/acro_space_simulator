// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Gas flows a body's colonies have produced and its air has not yet taken
/// (docs/plans/terraforming.md §5.2).
library;

import 'dart:math' as math;

/// Gas flows on one body, summed over every colony on it since its air was
/// last integrated.
///
/// Colonies on one body share one atmosphere (§7 Q5), so these are amounts
/// already integrated over each colony's own step (rate × dt) and simply
/// added: a frame-budgeted colony whose tick replays late adds its share
/// late, and nothing is lost or counted twice.
///
/// They wait on the body's `PlanetAtmosphere` rather than on the tick, and
/// are saved with it. A frame-budgeted colony's last frame of replays always
/// waits here for the next tick, so a tick-owned map would drop them on a
/// tick rebuild (every cheat toggle), leave them out of a save that was taken
/// after the replays the save forces, and pour the old session's flows into a
/// freshly loaded sky.
class AtmosphereFlows {
  AtmosphereFlows();

  /// Net industrial emissions, in the city's pollution units × seconds.
  /// Negative where scrubbing (terraformers carry negative pollution) wins.
  double pollution = 0;

  /// Positive emissions only, pollution units × seconds — what raises haze.
  /// Kept apart from [pollution] because one colony's scrubbers do not clear
  /// another colony's smoke.
  double emission = 0;

  /// Terraforming-tower running time: Σ throttle × seconds.
  double oxygenatorRun = 0;

  /// Seconds each colony's recorded steps cover, by colony id.
  final Map<String, double> _seconds = {};

  /// The span of sim time these flows were produced over: the longest any
  /// one colony recorded. Colonies on one body run side by side, so their
  /// spans overlap rather than add; one colony's held ticks run one after
  /// another, so its spans add.
  ///
  /// What a RATE is read against. The tick integrating the flows is not it:
  /// a frame-budgeted colony's whole frame of replayed ticks lands in one
  /// tick, and dividing by that one tick's dt read the haze source N times
  /// too strong.
  double get seconds {
    var s = 0.0;
    for (final v in _seconds.values) {
      s = math.max(s, v);
    }
    return s;
  }

  bool get isEmpty => pollution == 0 && emission == 0 && oxygenatorRun == 0;

  /// One step of the colony [colony]: [pollutionRate] (its `emissionRate`)
  /// and [oxygenatorRun] (Σ tower throttle) held for [dt] seconds.
  void addColony({
    required double pollutionRate,
    required double oxygenatorRun,
    required double dt,
    String colony = '',
  }) {
    if (dt <= 0) return;
    pollution += pollutionRate * dt;
    emission += math.max(0.0, pollutionRate) * dt;
    this.oxygenatorRun += math.max(0.0, oxygenatorRun) * dt;
    _seconds[colony] = (_seconds[colony] ?? 0) + dt;
  }

  Map<String, dynamic> toJson() => {
    'pollution': pollution,
    'emission': emission,
    'tower': oxygenatorRun,
    'seconds': {
      for (final id in (_seconds.keys.toList()..sort())) id: _seconds[id],
    },
  };

  factory AtmosphereFlows.fromJson(Map<String, dynamic> json) {
    double read(String k) => (json[k] as num?)?.toDouble() ?? 0;
    final f = AtmosphereFlows()
      ..pollution = read('pollution')
      ..emission = math.max(0.0, read('emission'))
      ..oxygenatorRun = math.max(0.0, read('tower'));
    final seconds = (json['seconds'] as Map?) ?? const {};
    for (final e in seconds.entries) {
      final v = e.value;
      if (v is num && v > 0) f._seconds[e.key as String] = v.toDouble();
    }
    return f;
  }
}
