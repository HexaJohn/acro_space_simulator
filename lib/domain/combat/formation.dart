// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Formations: squads kept as counts (docs/plans/combat.md §2, §7.3).
///
/// A formation is the unit of the whole combat model. The auto-resolver steps
/// its count, morale and kit; a later live fight spawns its members as units
/// and writes what happened back into the same numbers. Members are people:
/// troopers are colonists, and every one removed is charged to [homeColonyId].
library;

import 'combat_rng.dart';

/// Which side of an operation a formation fights on.
enum CombatSide { attacker, defender }

/// Who a side or formation belongs to. Plain strings, never a class with
/// `==`, so the hygiene test can ban `hashCode` under this directory:
/// `player`, `colony:<cityId>`, and a reserved `rival:<id>`.
abstract final class Factions {
  static const String player = 'player';
  static String colony(String cityId) => 'colony:$cityId';
  static String rival(String id) => 'rival:$id';

  /// Whether a vessel owner string means the player. Both `'player'` and
  /// `'player-1'` are in use in vessel saves (reference §4.4).
  static bool ownerIsPlayer(String? ownerId) =>
      ownerId == 'player' || ownerId == 'player-1';
}

/// What a formation is. Append-only: saved by name.
enum FormationKind { infantry, regular, militia, emplacement, armour, air }

/// What a formation counts as for the counter table (Halo Wars' triangle,
/// docs/plans/combat.md §2). Phase 1 uses only [inf] and [empHmg], with the
/// table at 1 everywhere, so counters change nothing yet; the column exists
/// so the base and vehicles add rows, not a save migration.
enum CounterClass { inf, empHmg, empAt, empAa, arm, air, structure }

/// Where a formation is when it is not at an objective.
abstract final class FormationAt {
  /// In flight to the battle.
  static const String transit = 'transit';

  /// Broken, out of the fight until it rallies.
  static const String reserve = 'reserve';
}

/// A squad kept as numbers.
class Formation {
  Formation({
    required this.id,
    required this.side,
    required this.faction,
    required this.kind,
    required this.count,
    required this.quality,
    required this.morale,
    required this.at,
    this.counterClass = CounterClass.inf,
    this.kitDays = 0,
    this.homeColonyId,
    this.homeSiteId,
    this.wounded = 0,
    this.dead = 0,
    this.removed = 0,
    this.lossCarry = 0,
    this.engagedMembers = 0,
    this.arriveStep = 0,
    this.broken = false,
    this.fromAt,
    this.departStep = 0,
  });

  /// A handle from the operation's saved counter.
  final int id;
  final CombatSide side;
  final String faction;
  final FormationKind kind;
  final CounterClass counterClass;

  /// Members alive and fit to fight.
  int count;

  /// Members wounded (alive, out of the fight). They go home at the end.
  int wounded;

  /// Members killed.
  int dead;

  /// Members ever removed (killed or wounded): what decides which half of the
  /// next removal is a death, so the split stays half and half however the
  /// removals fall.
  int removed;

  /// 1.0 trained, 0.5 armed militia, 0.3 improvised.
  final double quality;

  /// 0..1. Pinned below 0.35, broken below 0.2, rallies at 0.45.
  double morale;

  /// Days of ammo and rations carried (attackers). At 0 the formation fights
  /// at the tuning's no-ammo factor and loses morale for want of rations.
  double kitDays;

  /// An objective id, [FormationAt.transit] or [FormationAt.reserve].
  String at;

  /// The step it reaches [at]; before that it is on the march.
  int arriveStep;

  /// Broken: out of the fight in the reserve until morale rallies.
  bool broken;

  /// The objective a march to [at] set out from, and the step it set out:
  /// where a squad is drawn between two objectives. Null when it is not
  /// marching from anywhere (landed, raised in place, broken).
  String? fromAt;
  int departStep;

  /// Sends it to [to], arriving [marchS] seconds after [step].
  void marchTo(String to, int step, int marchS) {
    fromAt = at;
    departStep = step;
    at = to;
    arriveStep = step + marchS;
  }

  /// The colony its members live in, where their deaths are charged.
  final String? homeColonyId;

  /// The building they were drawn from, if any (its site factor falls while
  /// they are away). Cleared when that building is lost.
  String? homeSiteId;

  /// Fractional casualties carried between steps; whole members are removed.
  double lossCarry;

  /// Members when it first came into contact: what morale loss is measured
  /// against, so a squad that has already lost half does not break slower.
  int engagedMembers;

  /// Whether it has anyone left to fight.
  bool get alive => count > 0;

  /// Whether it is at an objective, arrived, and fit to fight there.
  bool presentAt(String objectiveId, int step) =>
      at == objectiveId && !broken && count > 0 && step >= arriveStep;

  /// Removes [n] members (killed or wounded), half of each, the odd one going
  /// by the running total so the split never drifts. Which way the odd one
  /// goes is the formation's own coin: always dead, and a fight of many small
  /// squads that each lost one had no wounded at all.
  void removeMembers(int n) {
    if (n <= 0) return;
    final take = n > count ? count : n;
    final odd = combatMix32(id) & 1;
    final deadBefore = (removed + odd) ~/ 2;
    removed += take;
    final deadAfter = (removed + odd) ~/ 2;
    final newDead = deadAfter - deadBefore;
    dead += newDead;
    wounded += take - newDead;
    count -= take;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'side': side.name,
        'faction': faction,
        'kind': kind.name,
        if (counterClass != CounterClass.inf) 'cc': counterClass.name,
        'count': count,
        if (wounded != 0) 'wounded': wounded,
        if (dead != 0) 'dead': dead,
        if (removed != 0) 'removed': removed,
        'quality': quality,
        'morale': morale,
        if (kitDays != 0) 'kit': kitDays,
        'at': at,
        if (arriveStep != 0) 'arrive': arriveStep,
        if (broken) 'broken': true,
        if (homeColonyId != null) 'home': homeColonyId,
        if (homeSiteId != null) 'site': homeSiteId,
        if (lossCarry != 0) 'carry': lossCarry,
        if (engagedMembers != 0) 'engaged': engagedMembers,
        if (fromAt != null) 'from': fromAt,
        if (departStep != 0) 'depart': departStep,
      };

  factory Formation.fromJson(Map<String, dynamic> j) => Formation(
        id: (j['id'] as num).toInt(),
        side: CombatSide.values.byName(j['side'] as String),
        faction: j['faction'] as String,
        kind: FormationKind.values.byName(j['kind'] as String),
        counterClass: j['cc'] == null
            ? CounterClass.inf
            : CounterClass.values.byName(j['cc'] as String),
        count: (j['count'] as num).toInt(),
        wounded: (j['wounded'] as num?)?.toInt() ?? 0,
        dead: (j['dead'] as num?)?.toInt() ?? 0,
        removed: (j['removed'] as num?)?.toInt() ?? 0,
        quality: (j['quality'] as num).toDouble(),
        morale: (j['morale'] as num).toDouble(),
        kitDays: (j['kit'] as num?)?.toDouble() ?? 0,
        at: j['at'] as String,
        arriveStep: (j['arrive'] as num?)?.toInt() ?? 0,
        broken: j['broken'] == true,
        homeColonyId: j['home'] as String?,
        homeSiteId: j['site'] as String?,
        lossCarry: (j['carry'] as num?)?.toDouble() ?? 0,
        engagedMembers: (j['engaged'] as num?)?.toInt() ?? 0,
        fromAt: j['from'] as String?,
        departStep: (j['depart'] as num?)?.toInt() ?? 0,
      );
}
