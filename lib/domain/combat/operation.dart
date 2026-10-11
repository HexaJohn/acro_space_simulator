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
import 'base/base_modules.dart';
import 'base/forward_base.dart';
import 'lander.dart';
import 'objective.dart';
import 'operation_clock.dart';
import 'powers/orbital.dart';
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

  /// Heavy weapons and destruction (§7L): heavier fire still, more
  /// civilians, strikes on the Seat, and the buildings fought over razed.
  heavy,
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
    List<LanderRecord>? landers,
    this.base,
    this.airless = false,
    this.chargeAt,
    this.chargeUntilStep = -1,
    this.chargeReadyStep = 0,
    this.supplyDropReadyStep = 0,
    this.medevacReadyStep = 0,
    OrbitalSupport? orbital,
    List<(int, String)>? directed,
    Map<String, double>? garrisonKit,
    this.tuning = const ResolverTuning(),
    this.counters = const CounterTuning.uniform(),
  })  : garrisonKit = garrisonKit ?? const {},
        orbital = orbital ?? OrbitalSupport(),
        directed = directed ?? [],
        landers = landers ?? [],
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

  /// The forward base at the LZ (§7C), or null for a light operation.
  final ForwardBase? base;

  /// The target's body has no air: jump jets work (§7D).
  final bool airless;

  /// Vessels assigned overhead, the strike called, rounds in flight and the
  /// craters they left (§7E).
  final OrbitalSupport orbital;

  /// A charge under way (§7D): the objective, and when it ends.
  String? chargeAt;
  int chargeUntilStep;

  /// When the next charge, supply drop and Medevac may be ordered.
  int chargeReadyStep;
  int supplyDropReadyStep;
  int medevacReadyStep;

  /// How long a charge lasts, and its rest; and the powers' cooldowns.
  static const int chargeS = 30;
  static const double chargeFire = 1.5;
  static const double chargeMoraleCost = 0.1;
  int get chargeCooldownS => (tuning.daySec * 2).round();
  int get supplyDropCooldownS => (tuning.daySec * 2).round();
  int get medevacCooldownS => tuning.daySec.round();

  /// Orders a charge at [objectiveId]: the squads there fight ×1.5 for 30 s,
  /// then pay for it in morale. Null, or why not.
  String? charge(String objectiveId) {
    if (resolved || phase != OperationPhase.engaged) return 'Not now.';
    final t = clock.steps;
    if (t < chargeReadyStep) return 'The squads are still catching their breath.';
    if (!formations.any((f) => f.side == CombatSide.attacker && f.presentAt(objectiveId, t))) {
      return 'No squads are there.';
    }
    chargeAt = objectiveId;
    chargeUntilStep = t + chargeS;
    chargeReadyStep = t + chargeCooldownS;
    return null;
  }

  /// A commander power (§7D): an emergency supply drop or a Medevac. Null, or
  /// why not.
  String? power(String name, {String? objectiveId}) {
    final b = base;
    if (resolved || b == null || !b.standing) return 'The base is not standing.';
    final t = clock.steps;
    switch (name) {
      case 'supplyDrop':
        if (t < supplyDropReadyStep) return 'The next supply drop is not ready.';
        b.supplyDrop(this);
        supplyDropReadyStep = t + supplyDropCooldownS;
        return null;
      case 'medevac':
        if (t < medevacReadyStep) return 'The Medevac is not ready.';
        if (!b.hospitalOnline) return 'Medevac needs a field hospital.';
        if (objectiveId == null) return 'Medevac from where?';
        b.medevac(this, objectiveId);
        medevacReadyStep = t + medevacCooldownS;
        return null;
    }
    return 'No such power.';
  }

  /// Calls an orbital strike on [objectiveId] (§7E): it fires at the first
  /// step an assigned vessel is overhead, armed and rested, while the uplink
  /// is online. Null, or why not.
  String? strike(String objectiveId) {
    final why = whyNotStrike(objectiveId);
    if (why == null) orbital.queued = objectiveId;
    return why;
  }

  /// Why a strike on [objectiveId] cannot be called now, or null.
  String? whyNotStrike(String objectiveId) {
    if (resolved || phase != OperationPhase.engaged) return 'Not now.';
    final o = graph.byId(objectiveId);
    if (o == null) return 'No such objective.';
    if (!orbital.any) return 'No orbital support is assigned.';
    if (base == null) return 'Strikes need the base\'s uplink, and this operation has no base.';
    if (orbital.queued != null) return 'A strike is already called.';
    if (!strikeAllowed(o)) return 'The rules of engagement do not allow a strike there.';
    if (!orbital.assigned.any((v) => (orbital.roundsAboard[v.id] ?? 0) > 0)) {
      return 'No assigned vessel has rounds aboard.';
    }
    return null;
  }

  /// Under [Roe.restrained] only where a gun emplacement stands; under
  /// [Roe.standard] also the Port, Power, Depot and Airfield. Never the Seat,
  /// Life support or the LZ.
  bool strikeAllowed(Objective o) {
    if (o.kind == ObjectiveKind.lz || o.kind == ObjectiveKind.lifeSupport) return false;
    if (o.kind == ObjectiveKind.seat) return roe == Roe.heavy;
    final gun = formations.any((f) =>
        f.side == CombatSide.defender && f.kind == FormationKind.emplacement && f.alive && f.at == o.id);
    if (gun) return true;
    return roe != Roe.restrained &&
        (o.kind == ObjectiveKind.port ||
            o.kind == ObjectiveKind.power ||
            o.kind == ObjectiveKind.depot ||
            o.kind == ObjectiveKind.airfield);
  }

  void _orbitalStep(int t) {
    final o = orbital;
    for (final s in [...o.inFlight]) {
      if (t < s.impactStep) continue;
      o.inFlight.remove(s);
      _impact(s, t);
    }
    final q = o.queued;
    if (q == null) return;
    final obj = graph.byId(q);
    if (obj == null || !strikeAllowed(obj)) {
      o.queued = null;
      o.notices.add('The strike was called off: nothing there the rules of engagement allow.');
      return;
    }
    if (!(base?.uplinkOnline(this) ?? false)) return;
    final v = o.ready(t);
    if (v == null) return;
    final seq = o.nextSeq++;
    o.inFlight.add(StrikeInFlight(seq, v.id, q, t + strikeFlightS(v.slantM), v.slantM));
    v.readyStep = t + kVesselCooldownS;
    o.fired.add(v.id);
    o.queued = null;
  }

  /// [x] members, the fraction by a seeded roll.
  int _whole(double x, int seq, int k) {
    final n = x.floor();
    return n + (combatUnit(seed, combatKey('strike'), seq * 8 + k) < x - n ? 1 : 0);
  }

  /// A round comes down at its objective (ref §10A.12, in the pools).
  void _impact(StrikeInFlight s, int t) {
    final obj = graph.byId(s.objectiveId);
    if (obj == null) return;
    final cep = strikeCepM(s.slantM);
    final d = orbital.craterM;
    final key = combatKey('strike');
    // Scatter: Rayleigh about the aim, σ = CEP / 1.1774.
    final u = combatUnit(seed, key, s.seq * 8).clamp(0.0, 0.999999);
    final a = combatUnit(seed, key, s.seq * 8 + 1) * 2 * math.pi;
    final r = cep / 1.1774 * math.sqrt(-2 * math.log(1 - u));
    final ie = obj.e + r * math.cos(a), in_ = obj.n + r * math.sin(a);
    // The emplacement there, else its largest defender formation.
    Formation? struck;
    for (final f in formations) {
      if (f.side != CombatSide.defender || !f.presentAt(obj.id, t)) continue;
      final gun = f.kind == FormationKind.emplacement;
      final best = struck;
      if (best == null ||
          (gun && best.kind != FormationKind.emplacement) ||
          (gun == (best.kind == FormationKind.emplacement) && f.count > best.count)) {
        struck = f;
      }
    }
    var killed = false;
    if (struck != null && struck.kind == FormationKind.emplacement) {
      if (combatUnit(seed, key, s.seq * 8 + 2) < strikeKillChance(d, cep)) {
        struck.removeMembers(struck.count);
        killed = true;
      }
    }
    final cover = obj.kind != ObjectiveKind.lz;
    if (struck != null && !killed) {
      struck.removeMembers(_whole(strikeAreaCasualties(struck.count, d, cep, cover: cover), s.seq, 3));
    }
    for (final f in formations) {
      if (f.side == CombatSide.defender && f.alive && f.at == obj.id) {
        f.morale = (f.morale - kStrikeMorale).clamp(0.0, 1.0);
      }
    }
    orbital.pin(obj.id, t + kPinnedS);
    // Danger close: squads of ours there take half the area rule.
    var k = 4;
    for (final f in formations) {
      if (f.side != CombatSide.attacker || !f.presentAt(obj.id, t)) continue;
      f.removeMembers(_whole(0.5 * strikeAreaCasualties(f.count, d, cep, cover: cover), s.seq, k));
      if (k < 7) k++;
    }
    if (orbital.craters.length < kMaxCraters) {
      final qe = (ie * 2).round() / 2, qn = (in_ * 2).round() / 2;
      final clear = !orbital.footprints.any((p) {
        final dx = p.$1 - qe, dy = p.$2 - qn;
        final reach = p.$3 + d / 2;
        return dx * dx + dy * dy < reach * reach;
      });
      orbital.craters.add(StrikeCrater(s.seq, qe, qn, d, t, brush: clear));
    }
    final what = struck == null
        ? 'nothing there'
        : (killed
            ? 'the gun emplacement destroyed'
            : (struck.kind == FormationKind.emplacement ? 'the emplacement survived' : 'the defenders pinned'));
    orbital.notices.add('Strike on ${obj.id}: $what (${cep.round()} m scatter).');
  }

  /// Squads the player has ordered by hand from the command view (§7J):
  /// (formation, objective id or [holdHere]). The attackers' AI leaves them
  /// alone; each marches to its objective and holds it until released.
  /// Saved: an order outlives a load.
  final List<(int, String)> directed;
  static const String holdHere = '#hold';

  /// Orders [ids] to [target] (an objective id), to hold where they are
  /// ([holdHere]), or back to the plan (null). Null, or why not.
  String? directSquads(List<int> ids, String? target) {
    if (resolved) return 'That operation is over.';
    if (target != null && target != holdHere) {
      final o = graph.byId(target);
      if (o == null) return 'No such objective.';
    }
    final t = clock.steps;
    for (final id in ids) {
      final f = formationById(id);
      if (f == null || f.side != CombatSide.attacker || f.kind == FormationKind.emplacement) continue;
      directed.removeWhere((d) => d.$1 == id);
      if (target == null) continue;
      directed.add((id, target));
      if (target != holdHere && f.at != target && graph.byId(f.at) != null && f.presentAt(f.at, t)) {
        f.marchTo(target, t, _marchFor(f, f.at, target));
      }
    }
    directed.sort((a, b) => a.$1.compareTo(b.$1));
    return null;
  }

  bool _isDirected(int id) => directed.any((d) => d.$1 == id);

  /// The squad the joined player fights in (§7H): live, so the resolver
  /// neither fights it nor marches it. Not saved — a load has no bubble.
  final List<int> liveOwned = [];

  /// Hands [formationId] to the bubble ([own]) or back to the resolver; with
  /// [at], the bubble's squad has reached that objective.
  void liveSquad(int formationId, {required bool own, String? at}) {
    final f = formationById(formationId);
    if (f == null || f.side != CombatSide.attacker) return;
    if (own) {
      if (!liveOwned.contains(formationId)) liveOwned.add(formationId);
    } else {
      liveOwned.remove(formationId);
    }
    final o = at == null ? null : graph.byId(at);
    if (o != null && f.at != o.id) {
      f
        ..fromAt = null
        ..at = o.id
        ..arriveStep = clock.steps;
    }
  }

  /// A member of [formationId] fell in the live bubble (§7G): off its
  /// formation, killed or wounded half and half, and its squad shaken as by
  /// any loss.
  void liveCasualty(int formationId) {
    if (resolved) return;
    final f = formationById(formationId);
    if (f == null || !f.alive) return;
    f.removeMembers(1);
    final base = f.engagedMembers > 0 ? f.engagedMembers : (f.count + 1);
    f.morale = (f.morale - tuning.moraleLossPerShare / base).clamp(0.0, 1.0);
  }

  Formation? formationById(int id) {
    for (final f in formations) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Adds an attacking formation raised in the field (a turret's crew, a
  /// squad formed at the base): the next id, counted among those raised.
  void addAttacker(Formation f) {
    formations.add(f);
    if (f.id >= nextFormationId) nextFormationId = f.id + 1;
    attackerRaised += f.count;
  }

  /// Troop landers flying the squads down (§7B); empty where landing is
  /// abstract. The transit waits on them.
  final List<LanderRecord> landers;

  /// A lander is still to come down.
  bool get landersAloft => landers.any((l) => !l.settled);

  LanderRecord? _lander(String vesselId) {
    for (final l in landers) {
      if (l.vesselId == vesselId) return l;
    }
    return null;
  }

  /// The world's lander flight: [vesselId] is down at the LZ, and its squads
  /// with it.
  void landerDown(String vesselId) {
    final l = _lander(vesselId);
    if (l == null || l.settled) return;
    l.state = LanderState.landed;
    final t = clock.steps;
    // The core rides the first lander (§7C).
    final b = base;
    if (b != null && identical(l, landers.first) && b.deployAtStep < 0) {
      b.deployAtStep = t + kDeployS;
    }
    for (final f in formations) {
      if (l.formationIds.contains(f.id) && f.at == FormationAt.transit) {
        f.at = lzId;
        f.arriveStep = t;
      }
    }
  }

  /// The world's lander flight: [vesselId] was lost before touchdown, and
  /// everyone aboard with it — dead, charged home (§7.6).
  void landerLost(String vesselId) {
    final l = _lander(vesselId);
    if (l == null || l.settled) return;
    l.state = LanderState.lost;
    if (identical(l, landers.first)) base?.loseCore();
    for (final f in formations) {
      if (!l.formationIds.contains(f.id) || f.at != FormationAt.transit) continue;
      f.dead += f.count;
      f.removed += f.count;
      f.count = 0;
    }
  }

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
        // With landers, the crossing ends when the last is down or lost.
        if (t >= phaseEndsStep && !landersAloft) _land(t);
      case OperationPhase.engaged:
        // Reinforcements land at the LZ on their own schedule — or with
        // their lander, when they have one.
        final flying = <int>[
          for (final l in landers)
            if (!l.settled) ...l.formationIds
        ];
        for (final f in formations) {
          if (f.side == CombatSide.attacker &&
              f.at == FormationAt.transit &&
              t >= f.arriveStep &&
              !flying.contains(f.id)) {
            f.at = lzId;
            f.arriveStep = t;
          }
        }
        base?.uplinkWanted = orbital.any;
        base?.step(this, t);
        _orbitalStep(t);
        _chargeEnd(t);
        _digIn(t);
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
    final b = base;
    if (b != null && b.deployAtStep < 0 && landers.isEmpty) b.deployAtStep = t + kDeployS;
  }

  void _fight(Objective o, int t, List<bool> inContact) {
    final att = <int>[], def = <int>[];
    var liveHere = false;
    for (var i = 0; i < formations.length; i++) {
      final f = formations[i];
      if (!f.presentAt(o.id, t)) continue;
      if (liveOwned.contains(f.id)) {
        // The player's squad fights in the bubble, not here (§7H).
        liveHere = true;
        continue;
      }
      (f.side == CombatSide.attacker ? att : def).add(i);
    }
    const dt = kCombatStepS;
    if (att.isEmpty && liveHere) {
      // Only the live squad is here: it takes the objective once nobody
      // holds it against them, and holds the line while they do.
      if (def.isEmpty) o.control = (o.control + tuning.kappa * dt).clamp(-1.0, 1.0);
      _holdClock(o);
      return;
    }
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
    final charging = chargeAt == o.id && t < chargeUntilStep;
    final fire = switch (roe) {
          Roe.restrained => 1.0,
          Roe.standard => tuning.standardFire,
          Roe.heavy => tuning.heavyFire,
        } *
        (charging ? chargeFire : 1.0);
    o.fought = true;
    final attS = [
      for (final i in att)
        formationStrength(formations[i], tuning,
                armed: formations[i].kitDays > 0) *
            fire
    ];
    final pinned = orbital.pinnedAt(o.id, t) ? kPinnedFire : 1.0;
    final defS = [
      for (final i in def) formationStrength(formations[i], tuning, armed: true) * pinned
    ];
    final u = combatSigned(seed, combatKey(o.id), t ~/ tuning.fuzzRoundS);
    final fuzz = 1 + tuning.fuzzAmplitude * u;
    final losses = contactLosses(
      attS: attS,
      attC: [for (final i in att) formations[i].counterClass],
      defS: defS,
      defC: [for (final i in def) formations[i].counterClass],
      width: o.width,
      fDef: o.fDef + (o.dugIn ? kDigInFortification : 0),
      fAtt: o.fAtt + (base?.fAttBonus(o.id, lzId) ?? 0),
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

  /// A charge spent: the squads that made it pay in morale.
  void _chargeEnd(int t) {
    final at = chargeAt;
    if (at == null || t < chargeUntilStep) return;
    for (final f in formations) {
      if (f.side == CombatSide.attacker && f.at == at && f.alive) {
        f.morale = (f.morale - chargeMoraleCost).clamp(0.0, 1.0);
      }
    }
    chargeAt = null;
  }

  /// Seconds unthreatened before a colony's defenders dig in at an objective.
  static const int digInAfterS = 120;

  /// Defenders of a colony dig in where nobody has come for them (§7D): an
  /// objective no attacker is at or marching on for two minutes fights from
  /// +0.3 until the attacker holds it. A colony assault's only: a port's
  /// rebels hold what they seized and no more.
  void _digIn(int t) {
    if (kind != OperationKind.colonyAssault) return;
    for (final o in graph.objectives) {
      if (o.kind == ObjectiveKind.lz) continue;
      if (o.control >= tuning.holdingControl) {
        o.dugIn = false;
        o.quietS = 0;
        continue;
      }
      final threatened = formations.any((f) =>
          f.side == CombatSide.attacker && f.alive && !f.broken && f.at == o.id);
      o.quietS = threatened ? 0 : o.quietS + 1;
      if (o.quietS >= digInAfterS) o.dugIn = true;
    }
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
      // A barracks pod at the LZ rallies broken squads twice as fast.
      if (f.broken && f.side == CombatSide.attacker && (base?.podOnline ?? false)) {
        m += tuning.recoverOutOfContact * dt;
      }
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
    var bestValue = 0.0;
    final raidable = base?.standing ?? false;
    for (final o in graph.objectives) {
      // The LZ is worth raiding only once a base stands on it (§7C).
      if (o.kind == ObjectiveKind.lz && !raidable) continue;
      final value = o.kind == ObjectiveKind.lz ? base!.lzValue() : o.value;
      final hit = formations.any((f) =>
          f.side == CombatSide.attacker && f.alive && !f.broken && f.at == o.id);
      if (hit && (best == null || value > bestValue)) {
        best = o;
        bestValue = value;
      }
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

  /// Jump jets: regulars cross airless ground 40% faster (§7D).
  int _marchFor(Formation f, String from, String to) {
    final s = graph.marchS(from, to);
    return airless && f.kind == FormationKind.regular ? (s * 0.6).round() : s;
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
          if (f.kind == FormationKind.emplacement || liveOwned.contains(f.id) || _isDirected(f.id)) continue;
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
          if (f.kind == FormationKind.emplacement || liveOwned.contains(f.id) || _isDirected(f.id)) continue;
          if (f.at == target.id || graph.byId(f.at) == null || !f.presentAt(f.at, t)) {
            continue;
          }
          f.marchTo(target.id, t, _marchFor(f, f.at, target.id));
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
      // A turret stands where it was built; the live squad goes where the
      // player sends it.
      if (f.kind == FormationKind.emplacement || liveOwned.contains(f.id) || _isDirected(f.id)) continue;
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
      f.marchTo(target.id, t, _marchFor(f, f.at, target.id));
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
      // A base's turrets hold the LZ; they take nothing, so they keep no
      // operation alive on their own.
      if (f.kind == FormationKind.emplacement) continue;
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
  int get civilianDead => roe == Roe.restrained
      ? 0
      : (defenderDead *
              (roe == Roe.heavy ? tuning.heavyCollateralShare : tuning.collateralShare) *
              (1 - shelterCover.clamp(0.0, 1.0)))
          .round();

  /// The buildings a Heavy operation razes when it ends (§7L): every
  /// objective fought over, never the LZ or life support; by site id.
  List<String> get razedSites => roe != Roe.heavy
      ? const []
      : [
          for (final o in graph.objectives)
            if (o.fought && o.siteId != null && o.kind != ObjectiveKind.lz && o.kind != ObjectiveKind.lifeSupport)
              o.siteId!
        ];

  /// Attacker dead and wounded by home colony, in colony id order: what each
  /// home is charged when the operation reports back. [exceptSite] leaves out
  /// formations drawn from that site (a base's support staff, reported with
  /// the base).
  List<({String home, int dead, int wounded, int alive})> attackerByHome({String? exceptSite}) {
    final homes = <String>[];
    for (final f in formations) {
      final h = f.homeColonyId;
      if (f.side == CombatSide.attacker && h != null && !homes.contains(h)) {
        if (exceptSite != null && f.homeSiteId == exceptSite) continue;
        homes.add(h);
      }
    }
    homes.sort();
    return [
      for (final h in homes)
        (
          home: h,
          dead: _homeSum(h, (f) => f.dead, exceptSite),
          wounded: _homeSum(h, (f) => f.wounded, exceptSite),
          alive: _homeSum(h, (f) => f.count, exceptSite),
        )
    ];
  }

  int _homeSum(String home, int Function(Formation) of, String? exceptSite) {
    var n = 0;
    for (final f in formations) {
      if (f.side != CombatSide.attacker || f.homeColonyId != home) continue;
      if (exceptSite != null && f.homeSiteId == exceptSite) continue;
      n += of(f);
    }
    return n;
  }

  /// The members of formations drawn from [site] (a base's support staff in
  /// turrets and formed squads): alive, wounded, dead.
  ({int alive, int wounded, int dead}) fromSite(String site) {
    var a = 0, w = 0, d = 0;
    for (final f in formations) {
      if (f.side != CombatSide.attacker || f.homeSiteId != site) continue;
      a += f.count;
      w += f.wounded;
      d += f.dead;
    }
    return (alive: a, wounded: w, dead: d);
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
        if (landers.isNotEmpty) 'landers': [for (final l in landers) l.toJson()],
        if (base != null) 'base': base!.toJson(),
        if (counters.name != 'uniform') 'counters': counters.name,
        if (airless) 'airless': true,
        if (chargeAt != null) 'chargeAt': chargeAt,
        if (chargeUntilStep >= 0) 'chargeUntil': chargeUntilStep,
        if (chargeReadyStep != 0) 'chargeReady': chargeReadyStep,
        if (supplyDropReadyStep != 0) 'dropReady': supplyDropReadyStep,
        if (medevacReadyStep != 0) 'medevacReady': medevacReadyStep,
        if (orderTarget != null) 'orderTarget': orderTarget,
        if (!orbital.isEmpty || orbital.centreBF != null) 'orbital': orbital.toJson(),
        if (directed.isNotEmpty) 'directed': [for (final d in directed) [d.$1, d.$2]],
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
        landers: [
          for (final l in (j['landers'] as List? ?? const []))
            LanderRecord.fromJson((l as Map).cast<String, dynamic>())
        ],
        base: j['base'] == null
            ? null
            : ForwardBase.fromJson((j['base'] as Map).cast<String, dynamic>()),
        airless: j['airless'] == true,
        chargeAt: j['chargeAt'] as String?,
        chargeUntilStep: (j['chargeUntil'] as num?)?.toInt() ?? -1,
        chargeReadyStep: (j['chargeReady'] as num?)?.toInt() ?? 0,
        supplyDropReadyStep: (j['dropReady'] as num?)?.toInt() ?? 0,
        medevacReadyStep: (j['medevacReady'] as num?)?.toInt() ?? 0,
        orbital: OrbitalSupport.fromJson((j['orbital'] as Map?)?.cast<String, dynamic>()),
        directed: [
          for (final d in (j['directed'] as List? ?? const []))
            (((d as List)[0] as num).toInt(), d[1] as String)
        ],
        garrisonKit: {
          for (final k in const ['ammo', 'fuel', 'guns', 'rations'])
            if ((j['garrisonKit'] as Map?)?[k] is num)
              k: ((j['garrisonKit'] as Map)[k] as num).toDouble(),
        },
        tuning: tuning,
        counters: j['counters'] == null ? counters : CounterTuning.byName(j['counters'] as String),
      );

  /// An independent copy (the preview runs these).
  Operation copy({int? seed}) =>
      Operation.fromJson(toJson(), tuning: tuning, counters: counters, seedOverride: seed);
}
