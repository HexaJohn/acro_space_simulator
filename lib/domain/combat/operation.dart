// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// An operation: one battle's whole state, stepped by the auto-resolver
/// (docs/plans/combat.md §2, §7).
///
/// Everything a battle is lives here — the formations, the objectives, the
/// militia the town has yet to send, the clock — so the battle has exactly one
/// truth. The planner's preview runs copies of it; a later live fight writes
/// into it; a save is its JSON. It reads no colony: what it needs from the
/// colonies is handed to it at launch, and what it does to them it reports
/// (docs/plans/combat.md §3, rule 3).
library;

import 'dart:math' as math;

import 'combat_rng.dart';
import 'formation.dart';
import 'objective.dart';
import 'operation_clock.dart';
import 'resolver.dart';
import 'resolver_tuning.dart';

/// Where an operation is in its life.
enum OperationPhase { mustering, transit, engaged, resolved }

/// How an operation ended. Append-only: saved by name.
enum OperationOutcome { won, lost, withdrawn, ceasefire, rejoined, overtaken }

/// Total War: Warhammer II's wording, by the share of each side lost.
enum OutcomeBand {
  decisiveVictory,
  closeVictory,
  pyrrhicVictory,
  valiantDefeat,
  closeDefeat,
  decisiveDefeat,
  none,
}

/// The town's militia, raised in waves while the port is fought over: sized
/// once at launch and spent from here, never from the live colony.
class MilitiaPool {
  MilitiaPool({this.armed = 0, this.improvised = 0, this.morale = 0.45});
  int armed;
  int improvised;

  /// Morale a wave turns out with: 0.45 + 0.35·resolve.
  final double morale;

  int get total => armed + improvised;

  Map<String, dynamic> toJson() => {
        if (armed != 0) 'armed': armed,
        if (improvised != 0) 'impro': improvised,
        'morale': morale,
      };
  factory MilitiaPool.fromJson(Map<String, dynamic>? j) => MilitiaPool(
        armed: (j?['armed'] as num?)?.toInt() ?? 0,
        improvised: (j?['impro'] as num?)?.toInt() ?? 0,
        morale: (j?['morale'] as num?)?.toDouble() ?? 0.45,
      );
}

class Operation {
  Operation({
    required this.id,
    required this.targetColonyId,
    required this.goalId,
    required this.lzId,
    required this.graph,
    required List<Formation> formations,
    required this.militia,
    required this.defenderFaction,
    this.sameBody = true,
    int? seed,
    OperationClock? clock,
    this.phase = OperationPhase.mustering,
    this.phaseEndsStep = -1,
    this.engagedAtStep = 0,
    this.nextFormationId = 0,
    this.outcome,
    this.band = OutcomeBand.none,
    this.resolvedAtStep = 0,
    this.kitOutS = 0,
    this.attackerRaised = 0,
    this.defenderRaised = 0,
    this.defenderSurrendered = 0,
    this.tuning = const ResolverTuning(),
    this.counters = const CounterTuning.uniform(),
  })  : seed = seed ?? combatSeed(targetColonyId, id),
        clock = clock ?? OperationClock(),
        formations = [...formations]..sort((a, b) => a.id.compareTo(b.id)) {
    var top = nextFormationId;
    for (final f in this.formations) {
      if (f.id >= top) top = f.id + 1;
    }
    nextFormationId = top;
    if (attackerRaised == 0 && defenderRaised == 0) {
      for (final f in this.formations) {
        if (f.side == CombatSide.attacker) {
          attackerRaised += f.count;
        } else {
          defenderRaised += f.count;
        }
      }
    }
    if (phaseEndsStep < 0) {
      phaseEndsStep = (tuning.musteringDays * tuning.daySec).round();
    }
  }

  /// From the saved operation counter.
  final int id;
  final int seed;
  final String targetColonyId;

  /// The objective the attacker came for (phase 1: the Port).
  final String goalId;

  /// The attacker's landing zone.
  final String lzId;
  final ObjectiveGraph graph;

  /// In id order, always.
  final List<Formation> formations;
  final MilitiaPool militia;
  final String defenderFaction;

  /// Transit is 0.5 day on the same body, 1.5 days from another.
  final bool sameBody;

  final OperationClock clock;
  OperationPhase phase;

  /// The step the current mustering or transit phase ends.
  int phaseEndsStep;
  int engagedAtStep;
  int nextFormationId;

  OperationOutcome? outcome;
  OutcomeBand band;
  int resolvedAtStep;

  /// Consecutive seconds every attacker has been out of kit.
  int kitOutS;

  /// Members ever fielded by each side (waves included): what loss shares and
  /// bands are measured against.
  int attackerRaised;
  int defenderRaised;

  /// Defenders who laid down their arms: returned alive.
  int defenderSurrendered;

  final ResolverTuning tuning;
  final CounterTuning counters;

  bool get resolved => phase == OperationPhase.resolved;

  /// Operation time, s.
  double get seconds => clock.seconds;

  /// Feeds [dt] seconds of the operation clock (the caller has already capped
  /// it at the colony clamp, without any colony's time-dilation) and runs the
  /// whole steps that are due.
  void advance(double dt) {
    if (resolved) return;
    final due = clock.feed(dt);
    for (var i = 0; i < due && !resolved; i++) {
      _step();
    }
  }

  /// The player's withdraw order. Survivors go home; if any attacker is in
  /// contact, a fighting withdrawal costs a share of what is left.
  void withdraw() {
    if (resolved) return;
    if (phase == OperationPhase.engaged && _attackersInContact()) {
      for (final f in formations) {
        if (f.side != CombatSide.attacker || !f.alive) continue;
        f.removeMembers((f.count * tuning.withdrawLoss).round());
      }
    }
    _resolve(OperationOutcome.withdrawn);
  }

  /// Ends the operation from outside: the target rejoined, or its allegiance
  /// changed under it (docs/plans/combat.md §7.6).
  void endFromOutside(OperationOutcome why) {
    if (resolved) return;
    _resolve(why);
  }

  // ---- the step ------------------------------------------------------------

  void _step() {
    final t = clock.steps;
    switch (phase) {
      case OperationPhase.mustering:
        if (t >= phaseEndsStep) {
          phase = OperationPhase.transit;
          final days = sameBody
              ? tuning.transitDaysSameBody
              : tuning.transitDaysOtherBody;
          phaseEndsStep = t + (days * tuning.daySec).round();
        }
      case OperationPhase.transit:
        if (t >= phaseEndsStep) _land(t);
      case OperationPhase.engaged:
        if ((t - engagedAtStep) % tuning.aiEveryS == 0) {
          _defenderAi(t);
          _attackerAi(t);
        }
        final inContact = List<bool>.filled(formations.length, false);
        for (final o in graph.objectives) {
          _fight(o, t, inContact);
        }
        _morale(t, inContact);
        _checkEnd(t);
      case OperationPhase.resolved:
        break;
    }
    clock.tick();
  }

  /// Landing is abstract in phase 1 and always succeeds: everyone in transit
  /// is at the LZ.
  void _land(int t) {
    for (final f in formations) {
      if (f.side == CombatSide.attacker && f.at == FormationAt.transit) {
        f.at = lzId;
        f.arriveStep = t;
      }
    }
    phase = OperationPhase.engaged;
    engagedAtStep = t;
  }

  void _fight(Objective o, int t, List<bool> inContact) {
    final att = <int>[], def = <int>[];
    for (var i = 0; i < formations.length; i++) {
      final f = formations[i];
      if (!f.presentAt(o.id, t)) continue;
      (f.side == CombatSide.attacker ? att : def).add(i);
    }
    const dt = kCombatStepS;
    if (att.isEmpty && def.isEmpty) {
      _holdClock(o);
      return;
    }
    if (att.isEmpty || def.isEmpty) {
      // Uncontested: the side that is there takes it.
      o.control = (o.control + (att.isEmpty ? -1 : 1) * tuning.kappa * dt)
          .clamp(-1.0, 1.0);
      _holdClock(o);
      return;
    }
    for (final i in [...att, ...def]) {
      inContact[i] = true;
      final f = formations[i];
      if (f.engagedMembers == 0) f.engagedMembers = f.count;
    }
    final attS = [
      for (final i in att)
        formationStrength(formations[i], tuning,
            armed: formations[i].kitDays > 0)
    ];
    final defS = [
      for (final i in def) formationStrength(formations[i], tuning, armed: true)
    ];
    final u = combatSigned(seed, combatKey(o.id), t ~/ tuning.fuzzRoundS);
    final fuzz = 1 + tuning.fuzzAmplitude * u;
    final losses = contactLosses(
      attS: attS,
      attC: [for (final i in att) formations[i].counterClass],
      defS: defS,
      defC: [for (final i in def) formations[i].counterClass],
      width: o.width,
      fDef: o.fDef,
      fAtt: o.fAtt,
      fuzz: fuzz,
      dt: dt,
      tuning: tuning,
      counters: counters,
    );
    for (var k = 0; k < att.length; k++) {
      _apply(formations[att[k]], losses.attackerLoss[k]);
    }
    for (var j = 0; j < def.length; j++) {
      _apply(formations[def[j]], losses.defenderLoss[j]);
    }
    o.control = (o.control + controlSwing(losses.a, losses.d, dt, tuning))
        .clamp(-1.0, 1.0);
    for (final i in att) {
      final f = formations[i];
      if (f.kitDays > 0) {
        f.kitDays = math.max(0.0, f.kitDays - dt / tuning.daySec);
      }
    }
    _holdClock(o);
  }

  void _holdClock(Objective o) {
    if (o.id != goalId) return;
    o.heldS = o.control >= tuning.winControl ? o.heldS + 1 : 0;
  }

  void _apply(Formation f, double loss) {
    f.lossCarry += loss;
    var n = f.lossCarry.floor();
    if (n > f.count) n = f.count;
    if (n <= 0) return;
    f.lossCarry -= n;
    f.removeMembers(n);
    final base = f.engagedMembers > 0 ? f.engagedMembers : 1;
    f.morale = (f.morale - tuning.moraleLossPerShare * n / base).clamp(0.0, 1.0);
  }

  void _morale(int t, List<bool> inContact) {
    const dt = kCombatStepS;
    for (var i = 0; i < formations.length; i++) {
      final f = formations[i];
      if (!f.alive) continue;
      var m = f.morale;
      if (!inContact[i]) m += tuning.recoverOutOfContact * dt;
      final o = graph.byId(f.at);
      if (o != null && !f.broken && t >= f.arriveStep) {
        final holds = f.side == CombatSide.attacker
            ? o.control >= tuning.holdingControl
            : o.control <= -tuning.holdingControl;
        if (holds) m += tuning.recoverHolding * dt;
      }
      if (f.side == CombatSide.attacker && f.kitDays <= 0) {
        m -= tuning.hungerDrain * dt;
      }
      f.morale = m.clamp(0.0, 1.0);
      if (!f.broken && f.morale < tuning.brokenBelow) {
        f.broken = true;
        f.at = FormationAt.reserve;
      } else if (f.broken && f.morale >= tuning.rallyAt) {
        f.broken = false;
      }
    }
  }

  // ---- the abstract AIs (docs/plans/combat.md §7.5) ------------------------

  /// The defender holds the goal: it feeds the town's militia to it in waves
  /// while it is under attack, and sends rallied squads back.
  void _defenderAi(int t) {
    final threatened = formations.any((f) =>
        f.side == CombatSide.attacker && f.alive && !f.broken && f.at == goalId);
    if (threatened && militia.total > 0) {
      final fromArmed = militia.armed > 0;
      final n = math.min(tuning.waveSize, fromArmed ? militia.armed : militia.improvised);
      if (fromArmed) {
        militia.armed -= n;
      } else {
        militia.improvised -= n;
      }
      formations.add(Formation(
        id: nextFormationId++,
        side: CombatSide.defender,
        faction: defenderFaction,
        kind: FormationKind.militia,
        count: n,
        quality: fromArmed ? 0.5 : 0.3,
        morale: militia.morale,
        at: goalId,
        arriveStep: t,
      ));
      defenderRaised += n;
    }
    for (final f in formations) {
      if (f.side == CombatSide.defender &&
          f.alive &&
          !f.broken &&
          f.at == FormationAt.reserve) {
        f.at = goalId;
        f.arriveStep = t + tuning.aiEveryS;
      }
    }
  }

  /// Attackers at the LZ advance on the goal when they are strong enough to
  /// take it, and hold for reinforcements when they are not. Rallied squads
  /// regroup at the LZ.
  void _attackerAi(int t) {
    for (final f in formations) {
      if (f.side == CombatSide.attacker &&
          f.alive &&
          !f.broken &&
          f.at == FormationAt.reserve) {
        f.at = lzId;
        f.arriveStep = t;
      }
    }
    final goal = graph.byId(goalId);
    if (goal == null) return;
    var ready = 0.0;
    final movers = <Formation>[];
    for (final f in formations) {
      if (f.side == CombatSide.attacker &&
          f.presentAt(lzId, t) &&
          f.morale >= tuning.pinnedBelow) {
        ready += formationStrength(f, tuning, armed: f.kitDays > 0);
        movers.add(f);
      }
    }
    if (movers.isEmpty) return;
    var held = 0.0;
    for (final f in formations) {
      if (f.side == CombatSide.defender && f.alive && !f.broken && f.at == goalId) {
        held += formationStrength(f, tuning, armed: true);
      }
    }
    final a = math.min(ready, goal.width) / goal.fDef;
    final d = math.min(held, goal.width) / goal.fAtt;
    if (a < tuning.advanceRatio * d) return;
    final march = graph.marchS(lzId, goalId);
    for (final f in movers) {
      f.at = goalId;
      f.arriveStep = t + march;
    }
  }

  // ---- endings --------------------------------------------------------------

  void _checkEnd(int t) {
    final goal = graph.byId(goalId);
    if (goal != null && goal.heldS >= tuning.winHoldS) {
      _resolve(OperationOutcome.won);
      return;
    }
    // The defender's side morale, strength-weighted; with nobody left in the
    // field and nobody left to send, the port is simply taken.
    var w = 0.0, wm = 0.0;
    for (final f in formations) {
      if (f.side != CombatSide.defender || !f.alive) continue;
      final s = formationStrength(f, tuning, armed: true);
      w += s;
      wm += s * f.morale;
    }
    if (w > 0 && wm / w < tuning.surrenderBelow) {
      for (final f in formations) {
        if (f.side == CombatSide.defender && f.alive) {
          defenderSurrendered += f.count;
          f.count = 0;
        }
      }
      // The militia still at home never took up arms: they are townsfolk, not
      // prisoners, and nobody counts them.
      _resolve(OperationOutcome.won);
      return;
    }
    var anyAlive = false, anyFit = false, anyKit = false;
    for (final f in formations) {
      if (f.side != CombatSide.attacker || !f.alive) continue;
      anyAlive = true;
      if (!f.broken) anyFit = true;
      if (f.kitDays > 0) anyKit = true;
    }
    if (!anyAlive || !anyFit) {
      _resolve(OperationOutcome.lost);
      return;
    }
    kitOutS = anyKit ? 0 : kitOutS + 1;
    if (kitOutS >= tuning.kitOutLossDays * tuning.daySec) {
      _resolve(OperationOutcome.lost);
      return;
    }
    if (t - engagedAtStep >= tuning.ceasefireDays * tuning.daySec) {
      _resolve(OperationOutcome.ceasefire);
    }
  }

  bool _attackersInContact() {
    final t = clock.steps;
    for (final o in graph.objectives) {
      var a = false, d = false;
      for (final f in formations) {
        if (!f.presentAt(o.id, t)) continue;
        if (f.side == CombatSide.attacker) {
          a = true;
        } else {
          d = true;
        }
      }
      if (a && d) return true;
    }
    return false;
  }

  void _resolve(OperationOutcome why) {
    // A won goal is the attacker's however it was won — held, or handed over
    // by a surrender — so what the colony is told matches the readout.
    if (why == OperationOutcome.won) graph.byId(goalId)?.control = 1.0;
    outcome = why;
    resolvedAtStep = clock.steps;
    phase = OperationPhase.resolved;
    band = _bandFor(why);
  }

  OutcomeBand _bandFor(OperationOutcome why) {
    final att = attackerRaised == 0 ? 0.0 : attackerRemoved / attackerRaised;
    final def = defenderRaised == 0 ? 0.0 : defenderRemoved / defenderRaised;
    switch (why) {
      case OperationOutcome.won:
        if (att >= tuning.pyrrhicLossShare) return OutcomeBand.pyrrhicVictory;
        if (att < tuning.decisiveLossShare) return OutcomeBand.decisiveVictory;
        return OutcomeBand.closeVictory;
      case OperationOutcome.lost:
        if (def >= tuning.valiantDefenderShare) return OutcomeBand.valiantDefeat;
        if (def < tuning.decisiveDefeatDefenderShare) {
          return OutcomeBand.decisiveDefeat;
        }
        return OutcomeBand.closeDefeat;
      default:
        return OutcomeBand.none;
    }
  }

  // ---- ledgers --------------------------------------------------------------

  int _sum(CombatSide side, int Function(Formation) of) {
    var n = 0;
    for (final f in formations) {
      if (f.side == side) n += of(f);
    }
    return n;
  }

  int get attackerDead => _sum(CombatSide.attacker, (f) => f.dead);
  int get attackerWounded => _sum(CombatSide.attacker, (f) => f.wounded);
  int get attackerRemoved => _sum(CombatSide.attacker, (f) => f.removed);
  int get attackerAlive => _sum(CombatSide.attacker, (f) => f.count);
  int get defenderDead => _sum(CombatSide.defender, (f) => f.dead);
  int get defenderWounded => _sum(CombatSide.defender, (f) => f.wounded);
  int get defenderRemoved => _sum(CombatSide.defender, (f) => f.removed);

  /// Attacker dead and wounded by home colony, in colony id order: what each
  /// home is charged when the operation reports back.
  List<({String home, int dead, int wounded, int alive})> attackerByHome() {
    final homes = <String>[];
    for (final f in formations) {
      final h = f.homeColonyId;
      if (f.side == CombatSide.attacker && h != null && !homes.contains(h)) {
        homes.add(h);
      }
    }
    homes.sort();
    return [
      for (final h in homes)
        (
          home: h,
          dead: _homeSum(h, (f) => f.dead),
          wounded: _homeSum(h, (f) => f.wounded),
          alive: _homeSum(h, (f) => f.count),
        )
    ];
  }

  int _homeSum(String home, int Function(Formation) of) {
    var n = 0;
    for (final f in formations) {
      if (f.side == CombatSide.attacker && f.homeColonyId == home) n += of(f);
    }
    return n;
  }

  // ---- persistence ----------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'seed': seed,
        'target': targetColonyId,
        'goal': goalId,
        'lz': lzId,
        'graph': graph.toJson(),
        'formations': [for (final f in formations) f.toJson()],
        'militia': militia.toJson(),
        'defFaction': defenderFaction,
        if (!sameBody) 'sameBody': false,
        'clock': clock.toJson(),
        'phase': phase.name,
        'phaseEnds': phaseEndsStep,
        if (engagedAtStep != 0) 'engagedAt': engagedAtStep,
        'nextFormation': nextFormationId,
        if (outcome != null) 'outcome': outcome!.name,
        if (band != OutcomeBand.none) 'band': band.name,
        if (resolvedAtStep != 0) 'resolvedAt': resolvedAtStep,
        if (kitOutS != 0) 'kitOut': kitOutS,
        'attRaised': attackerRaised,
        'defRaised': defenderRaised,
        if (defenderSurrendered != 0) 'surrendered': defenderSurrendered,
      };

  factory Operation.fromJson(Map<String, dynamic> j,
          {ResolverTuning tuning = const ResolverTuning(),
          CounterTuning counters = const CounterTuning.uniform(),
          int? seedOverride}) =>
      Operation(
        id: (j['id'] as num).toInt(),
        seed: seedOverride ?? (j['seed'] as num).toInt(),
        targetColonyId: j['target'] as String,
        goalId: j['goal'] as String,
        lzId: j['lz'] as String,
        graph: ObjectiveGraph.fromJson((j['graph'] as Map).cast<String, dynamic>()),
        formations: [
          for (final f in (j['formations'] as List))
            Formation.fromJson((f as Map).cast<String, dynamic>())
        ],
        militia: MilitiaPool.fromJson((j['militia'] as Map?)?.cast<String, dynamic>()),
        defenderFaction: j['defFaction'] as String,
        sameBody: j['sameBody'] != false,
        clock: OperationClock.fromJson((j['clock'] as Map?)?.cast<String, dynamic>()),
        phase: OperationPhase.values.byName(j['phase'] as String),
        phaseEndsStep: (j['phaseEnds'] as num).toInt(),
        engagedAtStep: (j['engagedAt'] as num?)?.toInt() ?? 0,
        nextFormationId: (j['nextFormation'] as num).toInt(),
        outcome: j['outcome'] == null
            ? null
            : OperationOutcome.values.byName(j['outcome'] as String),
        band: j['band'] == null
            ? OutcomeBand.none
            : OutcomeBand.values.byName(j['band'] as String),
        resolvedAtStep: (j['resolvedAt'] as num?)?.toInt() ?? 0,
        kitOutS: (j['kitOut'] as num?)?.toInt() ?? 0,
        attackerRaised: (j['attRaised'] as num).toInt(),
        defenderRaised: (j['defRaised'] as num).toInt(),
        defenderSurrendered: (j['surrendered'] as num?)?.toInt() ?? 0,
        tuning: tuning,
        counters: counters,
      );

  /// An independent copy (the preview runs these).
  Operation copy({int? seed}) =>
      Operation.fromJson(toJson(), tuning: tuning, counters: counters, seedOverride: seed);
}
