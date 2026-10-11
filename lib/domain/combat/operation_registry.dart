// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Every operation in the world, and the commands waiting for them
/// (docs/plans/combat.md §7.2, §7.4).
///
/// World state, not tick state: a cheat toggle rebuilds the tick, and a battle
/// must not care. The world's combat phase steps what is in here; a save
/// writes it whole.
library;

import '../multiplayer/command.dart';
import 'operation.dart';

/// A garrison the world keeps supplied: who holds whose port, what they eat.
class GarrisonRecord {
  GarrisonRecord({
    required this.targetColonyId,
    required this.homeColonyId,
    required this.opId,
    required this.count,
    required this.perTrooperDay,
    required this.nextRunUs,
  });
  final String targetColonyId;
  final String homeColonyId;
  final int opId;
  int count;
  final Map<String, double> perTrooperDay;

  /// When the next supply run leaves the home colony (world combat clock).
  int nextRunUs;

  Map<String, dynamic> toJson() => {
        'target': targetColonyId,
        'home': homeColonyId,
        'op': opId,
        'n': count,
        'per': _orderedKit(perTrooperDay),
        'next': nextRunUs,
      };

  static GarrisonRecord fromJson(Map j) => GarrisonRecord(
        targetColonyId: j['target'] as String,
        homeColonyId: j['home'] as String,
        opId: (j['op'] as num).toInt(),
        count: (j['n'] as num).toInt(),
        perTrooperDay: _readKit(j['per']),
        nextRunUs: (j['next'] as num).toInt(),
      );
}

/// A supply run on its way to a garrison.
class SupplyRun {
  SupplyRun(this.targetColonyId, this.amounts, this.arriveUs);
  final String targetColonyId;
  final Map<String, double> amounts;
  final int arriveUs;

  Map<String, dynamic> toJson() =>
      {'target': targetColonyId, 'amounts': _orderedKit(amounts), 'at': arriveUs};
  static SupplyRun fromJson(Map j) => SupplyRun(
      j['target'] as String, _readKit(j['amounts']), (j['at'] as num).toInt());
}

const List<String> _kitOrder = ['ammo', 'fuel', 'guns', 'rations'];

Map<String, double> _orderedKit(Map<String, double> m) =>
    {for (final k in _kitOrder) if (m[k] != null) k: m[k]!};

Map<String, double> _readKit(Object? v) => {
      if (v is Map)
        for (final k in _kitOrder)
          if (v[k] is num) k: (v[k] as num).toDouble(),
    };

/// Combat commands waiting for the next tick. The UI only ever enqueues here;
/// the world's combat phase applies them, so a battle depends on nothing a
/// widget did between ticks.
class CommandInbox {
  final List<CombatCommand> pending = [];

  void enqueue(CombatCommand c) => pending.add(c);

  /// Everything waiting, in arrival order, emptying the inbox.
  List<CombatCommand> drain() {
    final out = List<CombatCommand>.of(pending);
    pending.clear();
    return out;
  }
}

class OperationRegistry {
  /// Operations, running and recently resolved, in id order.
  final List<Operation> operations = [];

  /// Resolved operations whose results have been written back to colonies.
  final List<int> reported = [];

  /// The next operation's id. Saved, so a seed never repeats and a reload
  /// cannot reroll a launch.
  int nextOperationId = 1;

  /// World combat time, µs: what garrison supply runs are timed on.
  int clockUs = 0;

  final List<GarrisonRecord> garrisons = [];
  final List<SupplyRun> runs = [];

  /// The inbox the UI enqueues into. Its waiting commands are saved with the
  /// registry: a save taken between a click and the next tick keeps the click.
  final CommandInbox inbox = CommandInbox();

  /// Why the last launch was refused, for the planner. Not saved.
  String? lastRefusal;

  /// Resolved operations kept for after-action reports.
  static const int keepResolved = 8;

  bool get isEmpty =>
      operations.isEmpty && garrisons.isEmpty && runs.isEmpty && inbox.pending.isEmpty &&
      nextOperationId == 1;

  Operation? byId(int id) {
    for (final o in operations) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// The running operation against [colonyId], if any.
  Operation? runningAgainst(String colonyId) {
    for (final o in operations) {
      if (!o.resolved && o.targetColonyId == colonyId) return o;
    }
    return null;
  }

  /// Drops the oldest reported operations past [keepResolved].
  void trim() {
    var resolvedReported = 0;
    for (final o in operations) {
      if (o.resolved && reported.contains(o.id)) resolvedReported++;
    }
    while (resolvedReported > keepResolved) {
      final i = operations.indexWhere((o) => o.resolved && reported.contains(o.id));
      if (i < 0) break;
      reported.remove(operations[i].id);
      operations.removeAt(i);
      resolvedReported--;
    }
  }

  Map<String, dynamic>? toJson() => isEmpty
      ? null
      : {
          'next': nextOperationId,
          if (clockUs != 0) 'clock': clockUs,
          if (operations.isNotEmpty) 'ops': [for (final o in operations) o.toJson()],
          if (reported.isNotEmpty) 'reported': List<int>.of(reported),
          if (garrisons.isNotEmpty) 'garrisons': [for (final g in garrisons) g.toJson()],
          if (runs.isNotEmpty) 'runs': [for (final r in runs) r.toJson()],
          if (inbox.pending.isNotEmpty) 'pending': [for (final c in inbox.pending) c.toJson()],
        };

  /// Replaces everything with [j] (null: a save with no operations).
  void restore(Object? j) {
    operations.clear();
    reported.clear();
    garrisons.clear();
    runs.clear();
    inbox.pending.clear();
    nextOperationId = 1;
    clockUs = 0;
    lastRefusal = null;
    if (j is! Map) return;
    nextOperationId = (j['next'] as num?)?.toInt() ?? 1;
    clockUs = (j['clock'] as num?)?.toInt() ?? 0;
    for (final o in (j['ops'] as List? ?? const [])) {
      operations.add(Operation.fromJson((o as Map).cast<String, dynamic>()));
    }
    operations.sort((a, b) => a.id.compareTo(b.id));
    for (final r in (j['reported'] as List? ?? const [])) {
      if (r is num) reported.add(r.toInt());
    }
    for (final g in (j['garrisons'] as List? ?? const [])) {
      if (g is Map) garrisons.add(GarrisonRecord.fromJson(g));
    }
    for (final r in (j['runs'] as List? ?? const [])) {
      if (r is Map) runs.add(SupplyRun.fromJson(r));
    }
    for (final c in (j['pending'] as List? ?? const [])) {
      final cmd = CombatCommand.fromJson(c);
      if (cmd != null) inbox.pending.add(cmd);
    }
  }
}
