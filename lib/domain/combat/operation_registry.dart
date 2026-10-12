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
import 'powers/missile.dart';

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

/// The warp held while orbital support is assigned.
const double kOrbitalWarpCeiling = 10;

/// Rounds loaded aboard a vessel (combat.md §7E, the loadout route): paid
/// for by a colony, aboard from [readyUs]. Massless in v1.
class LoadedRounds {
  LoadedRounds(this.vesselId, this.rounds, this.readyUs);
  final String vesselId;
  int rounds;
  final int readyUs;

  Map<String, dynamic> toJson() => {'v': vesselId, 'n': rounds, 'at': readyUs};
  static LoadedRounds fromJson(Map j) =>
      LoadedRounds(j['v'] as String, (j['n'] as num).toInt(), (j['at'] as num).toInt());
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

  /// Rounds aboard the player's vessels, loading or loaded, in vessel id
  /// order then by when they are aboard.
  final List<LoadedRounds> loadout = [];

  /// Rounds aboard [vesselId] now.
  int roundsAboard(String vesselId) {
    var n = 0;
    for (final r in loadout) {
      if (r.vesselId == vesselId && r.readyUs <= clockUs) n += r.rounds;
    }
    return n;
  }

  /// Rounds still loading onto [vesselId].
  int roundsLoading(String vesselId) {
    var n = 0;
    for (final r in loadout) {
      if (r.vesselId == vesselId && r.readyUs > clockUs) n += r.rounds;
    }
    return n;
  }

  void loadRounds(String vesselId, int rounds, int readyUs) {
    if (rounds <= 0) return;
    loadout
      ..add(LoadedRounds(vesselId, rounds, readyUs))
      ..sort((a, b) => a.vesselId != b.vesselId
          ? a.vesselId.compareTo(b.vesselId)
          : a.readyUs.compareTo(b.readyUs));
  }

  /// One round leaves [vesselId].
  void spendRound(String vesselId) {
    for (final r in loadout) {
      if (r.vesselId == vesselId && r.readyUs <= clockUs && r.rounds > 0) {
        r.rounds--;
        break;
      }
    }
    loadout.removeWhere((r) => r.rounds <= 0);
  }

  /// Silo salvos (combat.md §7O): waiting to fly, in the air, and landed
  /// and not yet answered for; and the next one's id.
  final List<MissileShot> missiles = [];
  int nextMissileId = 1;

  /// A salvo is in the air.
  bool get missileAloft => missiles.any((m) => m.state == MissileState.flying);

  /// Strike craters already cut into the world this session, by key: a load
  /// within the session keeps its brushes (terrain edits are append-only), so
  /// they are never cut twice. Not saved, and kept across a restore.
  final Set<String> carvedCraters = {};

  /// The inbox the UI enqueues into. Its waiting commands are saved with the
  /// registry: a save taken between a click and the next tick keeps the click.
  final CommandInbox inbox = CommandInbox();

  /// Why the last refused order was refused (a launch, a strike, a power);
  /// null after one that went through. Not saved.
  String? get lastRefusal => _lastRefusal;
  set lastRefusal(String? why) {
    _lastRefusal = why;
    if (why != null) refusals++;
  }

  String? _lastRefusal;

  /// Orders refused this session: what a view counts to say each refusal
  /// once, even the same one twice running. Not saved.
  int refusals = 0;

  /// Resolved operations kept for after-action reports.
  static const int keepResolved = 8;

  bool get isEmpty =>
      operations.isEmpty && garrisons.isEmpty && runs.isEmpty && inbox.pending.isEmpty &&
      loadout.isEmpty && nextOperationId == 1 && missiles.isEmpty && nextMissileId == 1;

  Operation? byId(int id) {
    for (final o in operations) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// Some running operation has orbital support assigned: warp is held at
  /// [kOrbitalWarpCeiling] (combat.md §7E).
  bool get supportAssigned => operations.any((o) => !o.resolved && o.orbital.any);

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
          if (loadout.isNotEmpty) 'loadout': [for (final r in loadout) r.toJson()],
          if (inbox.pending.isNotEmpty) 'pending': [for (final c in inbox.pending) c.toJson()],
          if (missiles.isNotEmpty) 'missiles': [for (final m in missiles) m.toJson()],
          if (nextMissileId != 1) 'nextMissile': nextMissileId,
        };

  /// Replaces everything with [j] (null: a save with no operations).
  void restore(Object? j) {
    operations.clear();
    reported.clear();
    garrisons.clear();
    runs.clear();
    loadout.clear();
    inbox.pending.clear();
    missiles.clear();
    nextMissileId = 1;
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
    for (final r in (j['loadout'] as List? ?? const [])) {
      if (r is Map) loadout.add(LoadedRounds.fromJson(r));
    }
    for (final c in (j['pending'] as List? ?? const [])) {
      final cmd = CombatCommand.fromJson(c);
      if (cmd != null) inbox.pending.add(cmd);
    }
    for (final m in (j['missiles'] as List? ?? const [])) {
      final shot = MissileShot.fromJson(m);
      if (shot != null) missiles.add(shot);
    }
    nextMissileId = (j['nextMissile'] as num?)?.toInt() ?? 1;
  }
}
