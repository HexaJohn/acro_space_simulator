// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Gas flows a body's colonies have produced and its air has not yet taken
/// (docs/plans/terraforming.md §5.2).
library;

import 'dart:math' as math;

import 'terraform_towers.dart';

/// One colony's share of [AtmosphereFlows]: the same amounts, kept apart so
/// the planet can say WHICH colony is doing what to its sky (the atmosphere
/// panel, phase 3). Colonies on one world share its air; they do not share
/// the credit, or the blame.
class ColonyFlowAmounts {
  ColonyFlowAmounts([this.name = '']);

  /// The colony's display name, for the panel (the id is the map key).
  String name;

  /// Seconds of the colony's steps these amounts cover.
  double seconds = 0;

  /// Pollution units × seconds (net, negative where it scrubs).
  double pollution = 0;

  /// Σ throttle × seconds, per tower kind.
  double oxygenator = 0;
  double greenhouse = 0;
  double baker = 0;
  double sequestrator = 0;
  double retention = 0;

  /// Stock units × seconds its harvesters kept.
  double harvest = 0;

  Map<String, dynamic> toJson() => {
        if (name.isNotEmpty) 'name': name,
        if (pollution != 0) 'pollution': pollution,
        if (oxygenator != 0) 'tower': oxygenator,
        if (greenhouse != 0) 'greenhouse': greenhouse,
        if (baker != 0) 'baker': baker,
        if (sequestrator != 0) 'sequestrator': sequestrator,
        if (retention != 0) 'retention': retention,
        if (harvest != 0) 'harvest': harvest,
      };

  void _read(Map<String, dynamic> j) {
    double read(String k) => math.max(0.0, (j[k] as num?)?.toDouble() ?? 0);
    name = j['name'] as String? ?? name;
    pollution = (j['pollution'] as num?)?.toDouble() ?? 0;
    oxygenator = read('tower');
    greenhouse = read('greenhouse');
    baker = read('baker');
    sequestrator = read('sequestrator');
    retention = read('retention');
    harvest = read('harvest');
  }
}

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

  /// Oxygenator (Terraforming Tower) running time: Σ throttle × seconds.
  double oxygenatorRun = 0;

  /// Oxygen the colonies' Atmospheric Harvesters drew out of the sky into
  /// their stock, in the city's stock units (Σ stock/s × seconds). The
  /// integration converts it to moles and takes it OUT of the air.
  double o2Harvested = 0;

  /// Greenhouse Factory running time, Σ throttle × seconds.
  double greenhouseRun = 0;

  /// Regolith Baker running time, Σ throttle × seconds.
  double bakerRun = 0;

  /// Carbon Sequestrator running time, Σ throttle × seconds.
  double sequestratorRun = 0;

  /// Atmospheric Retention Array running time, Σ throttle × seconds. Read as
  /// an array COUNT ([retentionArrays]), not an amount: suppression is a
  /// state of the world while the arrays run, not a quantity they pile up.
  double retentionRun = 0;

  /// Each colony's share, by colony id.
  final Map<String, ColonyFlowAmounts> _byColony = {};

  /// Each colony's share, by colony id, in id order. Read-only.
  Map<String, ColonyFlowAmounts> get byColony => {
        for (final id in (_byColony.keys.toList()..sort())) id: _byColony[id]!,
      };

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
    for (final v in _byColony.values) {
      s = math.max(s, v.seconds);
    }
    return s;
  }

  /// Retention Arrays running on the body, on average over [seconds]: the
  /// colonies' arrays run side by side, so their throttles add.
  double get retentionArrays {
    final s = seconds;
    return s > 0 ? retentionRun / s : 0;
  }

  bool get isEmpty =>
      pollution == 0 &&
      emission == 0 &&
      oxygenatorRun == 0 &&
      o2Harvested == 0 &&
      greenhouseRun == 0 &&
      bakerRun == 0 &&
      sequestratorRun == 0 &&
      retentionRun == 0;

  /// One step of the colony [colony]: [pollutionRate] (its `emissionRate`),
  /// [oxygenatorRun] (Σ tower throttle), [o2HarvestRate] (stock units/s
  /// its harvesters made) and the rest of its [towers] held for [dt]
  /// seconds. [towers]' own oxygenator total is not read: [oxygenatorRun]
  /// is the one the colony has always reported.
  void addColony({
    required double pollutionRate,
    required double oxygenatorRun,
    required double dt,
    double o2HarvestRate = 0,
    TowerRuns? towers,
    String colony = '',
    String colonyName = '',
  }) {
    if (dt <= 0) return;
    final c = _byColony.putIfAbsent(colony, () => ColonyFlowAmounts());
    if (colonyName.isNotEmpty) c.name = colonyName;
    c.seconds += dt;

    pollution += pollutionRate * dt;
    c.pollution += pollutionRate * dt;
    emission += math.max(0.0, pollutionRate) * dt;
    final tower = math.max(0.0, oxygenatorRun) * dt;
    this.oxygenatorRun += tower;
    c.oxygenator += tower;
    final harvest = math.max(0.0, o2HarvestRate) * dt;
    o2Harvested += harvest;
    c.harvest += harvest;
    if (towers == null) return;
    final g = math.max(0.0, towers.greenhouse) * dt;
    final b = math.max(0.0, towers.baker) * dt;
    final s = math.max(0.0, towers.sequestrator) * dt;
    final r = math.max(0.0, towers.retention) * dt;
    greenhouseRun += g;
    bakerRun += b;
    sequestratorRun += s;
    retentionRun += r;
    c
      ..greenhouse += g
      ..baker += b
      ..sequestrator += s
      ..retention += r;
  }

  Map<String, dynamic> toJson() {
    final ids = _byColony.keys.toList()..sort();
    final colonies = {
      for (final id in ids)
        if (_byColony[id]!.toJson() case final j when j.isNotEmpty) id: j,
    };
    return {
      'pollution': pollution,
      'emission': emission,
      'tower': oxygenatorRun,
      if (o2Harvested != 0) 'harvest': o2Harvested,
      if (greenhouseRun != 0) 'greenhouse': greenhouseRun,
      if (bakerRun != 0) 'baker': bakerRun,
      if (sequestratorRun != 0) 'sequestrator': sequestratorRun,
      if (retentionRun != 0) 'retention': retentionRun,
      'seconds': {for (final id in ids) id: _byColony[id]!.seconds},
      if (colonies.isNotEmpty) 'colonies': colonies,
    };
  }

  /// From [toJson]. A save from before the tower family (phase 3) has no
  /// per-colony amounts: its flows still integrate, only unattributed.
  factory AtmosphereFlows.fromJson(Map<String, dynamic> json) {
    double read(String k) => (json[k] as num?)?.toDouble() ?? 0;
    final f = AtmosphereFlows()
      ..pollution = read('pollution')
      ..emission = math.max(0.0, read('emission'))
      ..oxygenatorRun = math.max(0.0, read('tower'))
      ..o2Harvested = math.max(0.0, read('harvest'))
      ..greenhouseRun = math.max(0.0, read('greenhouse'))
      ..bakerRun = math.max(0.0, read('baker'))
      ..sequestratorRun = math.max(0.0, read('sequestrator'))
      ..retentionRun = math.max(0.0, read('retention'));
    final seconds = (json['seconds'] as Map?) ?? const {};
    for (final e in seconds.entries) {
      final v = e.value;
      if (v is num && v > 0) {
        f._byColony.putIfAbsent(e.key as String, () => ColonyFlowAmounts())
            .seconds = v.toDouble();
      }
    }
    final colonies = (json['colonies'] as Map?) ?? const {};
    for (final e in colonies.entries) {
      final v = e.value;
      if (v is! Map) continue;
      f._byColony
          .putIfAbsent(e.key as String, () => ColonyFlowAmounts())
          ._read(v.cast<String, dynamic>());
    }
    return f;
  }
}
