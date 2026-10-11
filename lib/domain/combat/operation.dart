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

/// What an operation is for. Append-only: saved by name.
enum OperationKind {
  /// Phase 1: take back a colony's seized spaceport.
  portRetake,

  /// Phase 2: take an independent colony, and occupy it.
  colonyAssault,
}

/// Rules of engagement (docs/plans/combat.md §7A). Append-only: saved by name.
enum Roe {
  /// Small arms, surrender accepted, nobody else harmed: the baseline every
  /// phase 1 number was calibrated on.
  restrained,

  /// Heavier fire, and the town pays for it: civilians die alongside the
  /// defenders, less the share in shelters.
  standard,
}

/// The player's standing order to the attackers (docs/plans/combat.md §7B).
/// Append-only: saved by name.
enum OrderKind {
  /// The abstract AI's own plan: the objectives on the way to the goal, in
  /// order, each when strong enough.
  auto,

  /// Go for one objective now, whatever the odds; back to [auto] once held.
  attack,

  /// Stay where they are.
  hold,

  /// Back to the landing zone, then hold there.
  fallBack,
}

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
    this.kind = OperationKind.portRetake,
    this.roe = Roe.restrained,
    this.shelterCover = 0,
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
    this.garrison = 0,
    this.order = OrderKind.auto,
    this.orderTarget,
    Map<String, double>? garrisonKit,
    this.tuning = const ResolverTuning(),
    this.counters = const CounterTuning.uniform(),
  })  : garrisonKit = garrisonKit ?? const {},
        seed = seed ?? combatSeed(targetColonyId, id),
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

  final OperationKind kind;
  final Roe roe;

  /// The share of the target's people a shelter or bunker holds, at launch:
  /// what spares civilians under [Roe.standard].
  final double shelterCover;
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

  /// Troopers the player chose to leave holding the port after a win, so the
  /// rebels cannot take it straight back (docs/plans/combat.md §7.6).
  final int garrison;

  /// What one garrison trooper eats and fires per operation day: their home
  /// building's inputs, recorded at launch so reporting reads no colony.
  final Map<String, double> garrisonKit;

  /// The player's standing order, and the objective an [OrderKind.attack]
  /// is for.
  OrderKind order;
  String? orderTarget;

  /// Gives the attackers [kind] (and, to attack, the objective [target]). An
  /// attack on an unknown objective, or on the LZ, is no order at all.
  void setOrder(OrderKind kind, {String? target}) {
    if (resolved) return;
    if (kind == OrderKind.attack) {
      final o = target == null ? null : graph.byId(target);
      if (o == null || o.kind == ObjectiveKind.lz) return;
    }
    order = kind;
    orderTarget = kind == OrderKind.attack ? target : null;
  }

  /// Adds [fresh] attacking squads to a running operation: reinforcements,
  /// in transit until their own arrival step, then at the LZ. Their ids must
  /// follow [nextFormationId] (the planner takes them from there).
  void reinforce(List<Formation> fresh) {
    if (resolved || fresh.isEmpty) return;
    for (final f in fresh) {
      formations.add(f);
      attackerRaised += f.count;
      if (f.id >= nextFormationId) nextFormationId = f.id + 1;
    }
    formations.sort((a, b) => a.id.compareTo(b.id));
  }

  /// Steps from now until squads launched now would land: mustering and the
  /// crossing, as for the first wave.
  int get reinforcementDelaySteps =>
      ((tuning.musteringDays +
                  (sameBody ? tuning.transitDaysSameBody : tuning.transitDaysOtherBody)) *
              tuning.daySec)
          .round();

  final ResolverTuning tuning;
  final CounterTuning counters;

  bool get resolved => phase == OperationPhase.resolved;

  /// Days of fighting before a ceasefire.
  double get ceasefireDays => kind == OperationKind.colonyAssault
      ? tuning.assaultCeasefireDays
      : tuning.ceasefireDays;

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
        // Reinforcements land at the LZ on their own schedule.
        for (final f in formations) {
          if (f.side == CombatSide.attacker &&
              f.at == FormationAt.transit &&
              t >= f.arriveStep) {
            f.at = lzId;
            f.arriveStep = t;
          }
        }
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
    final fire = roe == Roe.standard ? tuning.standardFire : 1.0;
    final attS = [
      for (final i in att)
        formationStrength(formations[i], tuning,
                armed: formations[i].kitDays > 0) *
            fire
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
        // A gun emplacement's crew abandon the gun, not the ground: it stays
        // where it was built, silent until they rally to it.
        if (f.kind != FormationKind.emplacement) f.at = FormationAt.reserve;
      } else if (f.broken && f.morale >= tuning.rallyAt) {
        f.broken = false;
      }
    }
  }

  // ---- the abstract AIs (docs/plans/combat.md §7.5) ------------------------

  /// The objective the defender most needs to hold now: the most valuable one
  /// an attacker is at or marching on (never the attacker's own LZ), or null
  /// with none threatened. With phase 1's graph that is the Port or nothing.
  Objective? _threatened() {
    Objective? best;
    for (final o in graph.objectives) {
      if (o.kind == ObjectiveKind.lz) continue;
      final hit = formations.any((f) =>
          f.side == CombatSide.attacker && f.alive && !f.broken && f.at == o.id);
      if (hit && (best == null || o.value > best.value)) best = o;
    }
    return best;
  }

  /// The defender holds what is threatened: it feeds the town's militia there
  /// in waves while it is under attack, and sends rallied squads back to it
  /// (or to the goal when nothing is). Emplacements never move.
  void _defenderAi(int t) {
    final threat = _threatened();
    if (threat != null && militia.total > 0) {
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
        at: threat.id,
        arriveStep: t,
      ));
      defenderRaised += n;
    }
    final rally = threat?.id ?? goalId;
    for (final f in formations) {
      if (f.side == CombatSide.defender &&
          f.alive &&
          !f.broken &&
          f.kind != FormationKind.emplacement &&
          f.at == FormationAt.reserve) {
        f.at = rally;
        f.arriveStep = t + tuning.aiEveryS;
      }
    }
  }

  List<String>? _pathCache;

  /// The shortest march from the LZ to the goal, by seconds, ties broken by
  /// id: the order the attacker takes objectives in. LZ first, goal last.
  /// Phase 1's graph gives `[lz, port]`.
  List<String> get path => _pathCache ??= _shortestPath();

  static const int _far = 1 << 40;

  List<String> _shortestPath() {
    final ids = [for (final o in graph.objectives) o.id];
    final dist = <String, int>{for (final id in ids) id: _far};
    final prev = <String, String>{};
    final done = <String>[];
    dist[lzId] = 0;
    while (done.length < ids.length) {
      String? u;
      for (final id in ids) {
        if (done.contains(id)) continue;
        if (u == null || dist[id]! < dist[u]!) u = id;
      }
      if (u == null || dist[u]! >= _far) break;
      done.add(u);
      for (final l in graph.links) {
        final v = l.a == u ? l.b : (l.b == u ? l.a : null);
        if (v == null || done.contains(v) || !dist.containsKey(v)) continue;
        final d = dist[u]! + l.marchS;
        if (d < dist[v]!) {
          dist[v] = d;
          prev[v] = u;
        }
      }
    }
    if (!prev.containsKey(goalId)) return [lzId, goalId];
    final out = <String>[goalId];
    while (out.last != lzId) {
      out.add(prev[out.last]!);
    }
    return out.reversed.toList();
  }

  /// The attacker takes the objectives on [path] in order: its target is the
  /// first one past the LZ it does not yet hold (the goal once the rest are
  /// held). Squads that have arrived at an objective behind the target
  /// advance on it when they are strong enough to take it, and hold for
  /// reinforcements when they are not. Rallied squads regroup at the LZ. On
  /// phase 1's graph that is: from the LZ, on the port.
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
    switch (order) {
      case OrderKind.hold:
        return;
      case OrderKind.fallBack:
        for (final f in formations) {
          if (f.side != CombatSide.attacker || !f.alive || f.broken) continue;
          if (f.at == lzId || graph.byId(f.at) == null) continue;
          f.marchTo(lzId, t, graph.marchS(f.at, lzId));
        }
        order = OrderKind.hold;
        return;
      case OrderKind.attack:
        final target = graph.byId(orderTarget ?? '');
        if (target == null ||
            (target.id != goalId && target.control >= tuning.holdingControl)) {
          // Taken (or gone): the plan resumes.
          order = OrderKind.auto;
          orderTarget = null;
          break;
        }
        for (final f in formations) {
          if (f.side != CombatSide.attacker || f.morale < tuning.pinnedBelow) continue;
          if (f.at == target.id || graph.byId(f.at) == null || !f.presentAt(f.at, t)) {
            continue;
          }
          f.marchTo(target.id, t, graph.marchS(f.at, target.id));
        }
        return;
      case OrderKind.auto:
        break;
    }
    final route = path;
    var k = 1;
    while (k < route.length - 1 &&
        (graph.byId(route[k])?.control ?? 1) >= tuning.holdingControl) {
      k++;
    }
    final target = graph.byId(route[k]);
    if (target == null) return;
    final behind = route.sublist(0, k);
    var ready = 0.0;
    final movers = <Formation>[];
    for (final f in formations) {
      if (f.side != CombatSide.attacker || f.morale < tuning.pinnedBelow) continue;
      var there = false;
      for (final id in behind) {
        if (f.presentAt(id, t)) there = true;
      }
      if (!there) continue;
      ready += formationStrength(f, tuning, armed: f.kitDays > 0);
      movers.add(f);
    }
    if (movers.isEmpty) return;
    var held = 0.0;
    for (final f in formations) {
      if (f.side == CombatSide.defender && f.alive && !f.broken && f.at == target.id) {
        held += formationStrength(f, tuning, armed: true);
      }
    }
    // Whole strengths, not width-capped ones: the width caps what either
    // side brings to bear, which is the losses' business. Capped here, two
    // sides that both fill a small objective compare width/F_def against
    // width/F_att, and behind any fortification the attacker never went in.
    final a = ready / target.fDef;
    final d = held / target.fAtt;
    if (a < tuning.advanceRatio * d) return;
    for (final f in movers) {
      f.marchTo(target.id, t, graph.marchS(f.at, target.id));
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
    if (t - engagedAtStep >= ceasefireDays * tuning.daySec) {
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
    _settleCarry();
    // A won goal is the attacker's however it was won — held, or handed over
    // by a surrender — so what the colony is told matches the readout.
    if (why == OperationOutcome.won) graph.byId(goalId)?.control = 1.0;
    outcome = why;
    resolvedAtStep = clock.steps;
    phase = OperationPhase.resolved;
    band = _bandFor(why);
  }

  /// Salt for the end-of-battle carry roll, apart from the fuzz rolls' rounds.
  static const int _settleSalt = 0x7fffffff;

  /// The fire each formation took but never paid for — under one member, so
  /// [_apply] carried it — is settled with one roll: a squad carrying 0.6 of
  /// a loss loses a member six times in ten. Floored and forgotten, it was up
  /// to a member a squad a battle, and a force split thin took no losses.
  void _settleCarry() {
    for (final f in formations) {
      if (f.alive && f.lossCarry > 0 && combatUnit(seed, f.id, _settleSalt) < f.lossCarry) {
        f.removeMembers(1);
      }
      f.lossCarry = 0;
    }
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

  /// Townsfolk killed alongside the defenders: none under [Roe.restrained];
  /// under [Roe.standard] a [ResolverTuning.collateralShare] of the defender
  /// dead again, less the share a shelter held.
  int get civilianDead => roe == Roe.standard
      ? (defenderDead * tuning.collateralShare * (1 - shelterCover.clamp(0.0, 1.0)))
          .round()
      : 0;

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
        if (kind != OperationKind.portRetake) 'kind': kind.name,
        if (roe != Roe.restrained) 'roe': roe.name,
        if (shelterCover != 0) 'shelter': shelterCover,
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
        if (garrison != 0) 'garrison': garrison,
        if (order != OrderKind.auto) 'order': order.name,
        if (orderTarget != null) 'orderTarget': orderTarget,
        if (garrisonKit.isNotEmpty)
          'garrisonKit': {
            for (final k in const ['ammo', 'fuel', 'guns', 'rations'])
              if (garrisonKit[k] != null) k: garrisonKit[k],
          },
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
        kind: j['kind'] == null
            ? OperationKind.portRetake
            : OperationKind.values.byName(j['kind'] as String),
        roe: j['roe'] == null ? Roe.restrained : Roe.values.byName(j['roe'] as String),
        shelterCover: (j['shelter'] as num?)?.toDouble() ?? 0,
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
        garrison: (j['garrison'] as num?)?.toInt() ?? 0,
        order: j['order'] == null ? OrderKind.auto : OrderKind.values.byName(j['order'] as String),
        orderTarget: j['orderTarget'] as String?,
        garrisonKit: {
          for (final k in const ['ammo', 'fuel', 'guns', 'rations'])
            if ((j['garrisonKit'] as Map?)?[k] is num)
              k: ((j['garrisonKit'] as Map)[k] as num).toDouble(),
        },
        tuning: tuning,
        counters: counters,
      );

  /// An independent copy (the preview runs these).
  Operation copy({int? seed}) =>
      Operation.fromJson(toJson(), tuning: tuning, counters: counters, seedOverride: seed);
}
