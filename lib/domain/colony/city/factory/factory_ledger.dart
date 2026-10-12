// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a floor USED over a period (docs/plans/factory-floors.md §3
/// "Ownership and money").
///
/// Counters only, no prices: the economy (phase 5) multiplies them by a
/// colony's local prices to get a plant's unit cost and P&L. Because a better
/// layout really uses fewer worker-hours, less energy and shorter hauls, the
/// design reward and the money side are the same lever.
library;

import 'factory_handling.dart';

/// Whose hours a worker-second was.
enum WorkRole { station, handler, maintenance }

class FactoryLedger {
  /// Sim seconds the counters cover.
  double seconds = 0;

  /// Staffed worker-seconds by role (a station running with 2 of its 2
  /// workers for 10 s books 20).
  final Map<WorkRole, double> workerSeconds = {};

  /// Energy drawn, kilojoules (kW × s).
  double energyKJ = 0;

  /// Colony commodity units received and shipped, by commodity.
  final Map<String, double> received = {};
  final Map<String, double> shipped = {};

  /// Item-metres hauled by handlers (belts are free to run, not to build).
  double itemMetres = 0;

  /// Seconds each handler kind spent working (wear and depreciation).
  final Map<HandlerKind, double> equipmentSeconds = {};

  void addWork(WorkRole role, double s) =>
      workerSeconds[role] = (workerSeconds[role] ?? 0) + s;
  void addReceived(String c, double units) =>
      received[c] = (received[c] ?? 0) + units;
  void addShipped(String c, double units) =>
      shipped[c] = (shipped[c] ?? 0) + units;
  void addEquipment(HandlerKind k, double s) =>
      equipmentSeconds[k] = (equipmentSeconds[k] ?? 0) + s;

  double get totalWorkerSeconds =>
      workerSeconds.values.fold(0.0, (a, b) => a + b);

  /// Folds [o] into this (period roll-ups).
  void absorb(FactoryLedger o) {
    seconds += o.seconds;
    energyKJ += o.energyKJ;
    itemMetres += o.itemMetres;
    o.workerSeconds.forEach(addWork);
    o.received.forEach(addReceived);
    o.shipped.forEach(addShipped);
    o.equipmentSeconds.forEach(addEquipment);
  }

  void reset() {
    seconds = 0;
    energyKJ = 0;
    itemMetres = 0;
    workerSeconds.clear();
    received.clear();
    shipped.clear();
    equipmentSeconds.clear();
  }

  Map<String, Object?> toJson() => {
        's': seconds,
        'e': energyKJ,
        'm': itemMetres,
        if (workerSeconds.isNotEmpty)
          'w': {for (final e in workerSeconds.entries) e.key.name: e.value},
        if (received.isNotEmpty) 'in': {...received},
        if (shipped.isNotEmpty) 'out': {...shipped},
        if (equipmentSeconds.isNotEmpty)
          'eq': {for (final e in equipmentSeconds.entries) e.key.name: e.value},
      };

  static FactoryLedger fromJson(Map<String, Object?> j) {
    final l = FactoryLedger()
      ..seconds = (j['s'] as num?)?.toDouble() ?? 0
      ..energyKJ = (j['e'] as num?)?.toDouble() ?? 0
      ..itemMetres = (j['m'] as num?)?.toDouble() ?? 0;
    Map<String, Object?> m(Object? o) =>
        ((o as Map?) ?? const {}).cast<String, Object?>();
    m(j['w']).forEach(
        (k, v) => l.addWork(WorkRole.values.byName(k), (v as num).toDouble()));
    m(j['in']).forEach((k, v) => l.addReceived(k, (v as num).toDouble()));
    m(j['out']).forEach((k, v) => l.addShipped(k, (v as num).toDouble()));
    m(j['eq']).forEach((k, v) =>
        l.addEquipment(HandlerKind.values.byName(k), (v as num).toDouble()));
    return l;
  }
}
