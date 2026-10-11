// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The live bubble (docs/plans/combat.md §7G, §7H): the battle the player has
/// joined as a soldier, drawn as units round their objectives.
///
/// A presenter over the operation, not a second battle: every unit is a
/// member of a formation the operation owns, and the bubble mirrors it each
/// frame — a member the resolver removes leaves the bubble. What the bubble
/// does to the battle (a defender shot dead, one of the player's squad or the
/// player killed, where the squad got to) leaves it only as casualties and
/// arrivals for the view to send as commands, applied at the tick.
///
/// The player's own squad is live while they are joined (§7H): the resolver
/// leaves it to the bubble, where it follows orders and fights for real.
/// Everyone else's losses stay the resolver's; their shots here are tracers.
///
/// Flat local frame: colony east/north metres, and height above the battle
/// raster's ground. A 1.2 km square on the Moon curves 0.1 m at its edge.
library;

import 'dart:math' as math;

import '../combat_rng.dart';
import '../formation.dart';
import '../objective.dart';
import '../operation.dart';
import 'battle_raster.dart';
import 'nav_grid.dart';

/// The rifle (§7G).
const double kRifleRate = 6; // rounds a second
const int kRifleMagazine = 30;
const double kRifleReloadS = 2;
const double kRifleDamage = 40;
const double kRifleRangeM = 300;

/// Fire: the chance a trained soldier hits at 30 m or nearer, scaled by its
/// quality and falling with range.
const double kDefenderAccuracy = 0.35;
const double kDefenderRangeM = 200;
const double kDefenderDamage = 20;

/// A unit's target: a 0.45 m capsule from the ground to 1.8 m.
const double kUnitRadiusM = 0.45;
const double kUnitHeightM = 1.8;

const double kDeathCameraS = 5;
const int kLiveMaxPerSide = 24;

/// A soldier's pace across the battle, m/s (§7H).
const double kLiveWalkMps = 2.5;

/// The squad has reached an objective within this of its centre.
const double kSquadArriveM = 35;

/// What the player's squad is told (number keys 1, 2, 3).
enum SquadOrder { follow, hold, attack }

class LiveUnit {
  LiveUnit(this.formationId, this.member, this.side, this.kind, this.objectiveId, this.e, this.n)
      : te = e,
        tn = n;
  final int formationId;

  /// Which member of its formation: the bubble's key.
  final int member;
  final CombatSide side;
  final FormationKind kind;

  /// Where its formation is (or is going).
  String objectiveId;

  /// Where it stands, and where it is walking to.
  double e, n;
  double te, tn;

  /// Its objective's centre: what its flow field leads to.
  double oe = 0, on = 0;

  /// The cover it fights from (§7I): its objective's fortification while it
  /// holds its slot there — the resolver's `F_def` — or 1 in the open.
  double cover = 1;
  double hp = 100;

  /// One of the player's squad: live, its hits and wounds real.
  bool squad = false;

  /// 1.0 trained, 0.5 armed militia, 0.3 improvised: how well it shoots.
  double quality = 1;

  /// Its formation's count when last mirrored: a kill is pending until the
  /// count falls below it.
  int formationCount = 0;

  /// Seconds until it may fire.
  double cooldownS = 0;

  /// Shots fired, for its rolls.
  int shots = 0;
}

/// A round's track, for the renderer: local east/north/height, both ends.
class Tracer {
  Tracer(this.fromE, this.fromN, this.fromH, this.toE, this.toN, this.toH, this.side);
  final double fromE, fromN, fromH, toE, toN, toH;
  final CombatSide side;
  double ageS = 0;
}

class LiveBattle {
  LiveBattle({
    required this.opId,
    required this.seed,
    required this.playerFormationId,
    this.playerless = false,
    List<int>? squads,
  }) : squads = squads ?? [];

  final int opId;
  final int seed;

  /// The squad the player fights as one of; changes on a redeploy.
  int playerFormationId;

  /// No player at all: the calibration harness's AI-against-AI fights
  /// (§7I). Nobody aims, nobody is the target of a shot.
  final bool playerless;

  /// Further squads the bubble fights with besides the player's (the
  /// harness's: every attacking squad). They take the same orders.
  final List<int> squads;

  /// Every squad the bubble owns, the player's first.
  List<int> get _owned => [if (!playerless) playerFormationId, ...squads.where((id) => id != playerFormationId)];

  /// Squads that reached an objective this step: (formation, objective),
  /// for the view (or the harness) to tell the battle. Drained by it.
  final List<(int, String)> arrivals = [];
  final Map<int, String> _arrivedAt = {};

  /// Where units can walk and see; null (a test, a raster not yet
  /// navigated) walks straight and sees everything.
  NavGrid? nav;

  final List<LiveUnit> units = [];
  final List<Tracer> tracers = [];

  double hp = 100;
  int magazine = kRifleMagazine;
  double reloadS = 0;
  double _fireS = 0;

  /// Seconds left on the death camera; 0 alive.
  double deadS = 0;
  bool get dead => playerless || hp <= 0;

  /// Ready to redeploy (the death camera has run).
  bool get redeployReady => dead && deadS <= 0;

  /// The squad's order, the objective an attack is on, and where it holds.
  SquadOrder order = SquadOrder.follow;
  String? attackTarget;
  (double, double)? holdAt;

  /// The objective the squad has just reached, for the view to tell the
  /// battle; null when there is nothing new.
  String? squadArrived;
  String? _squadAt;

  /// Casualties for the view to send: a formation id per member killed —
  /// defenders the player or the squad shot, and the player's own squad when
  /// one of them (or the player) falls. Drained by the view.
  final List<int> casualties = [];

  /// Kills not yet seen in the formation's count: (formation, its count when
  /// the kill was made). Until the tick applies the command, the unit stays
  /// gone.
  final List<(int, int)> _pending = [];

  int kills = 0;

  /// The player, where the last step saw them.
  (double, double, double) _eye = (0, 0, 1.7);
  (double, double) _heading = (1, 0);
  Objective? _attackObjective;

  int _pendingFor(Formation f) {
    _pending.removeWhere((p) => p.$1 == f.id && f.count < p.$2);
    var k = 0;
    for (final p in _pending) {
      if (p.$1 == f.id) k++;
    }
    return k;
  }

  /// Mirrors [op]: a unit for every member at an objective inside [raster]
  /// or marching to one, up to [kLiveMaxPerSide] a side, nearest objectives
  /// to ([pe], [pn]) first, and every member of the player's squad. Units
  /// keep their place and hit points while their member stays.
  void sync(Operation op, BattleRaster raster, double pe, double pn) {
    final t = op.clock.steps;
    final objs = [
      for (final o in op.graph.objectives)
        if (raster.contains(o.e, o.n)) o
    ]..sort((a, b) {
        final da = (a.e - pe) * (a.e - pe) + (a.n - pn) * (a.n - pn);
        final db = (b.e - pe) * (b.e - pe) + (b.n - pn) * (b.n - pn);
        return da.compareTo(db);
      });
    _attackObjective = attackTarget == null ? null : op.graph.byId(attackTarget!);
    final want = <LiveUnit>[];
    final room = {CombatSide.attacker: kLiveMaxPerSide, CombatSide.defender: kLiveMaxPerSide};

    // The bubble's own squads first, wherever their formations stand: the
    // player's is with the player; any other appears at its objective.
    final owned = _owned;
    for (final id in owned) {
      final mine = op.formationById(id);
      if (mine == null || !mine.alive) continue;
      // Broken, a squad falls back out of the fight, as the resolver's do.
      if (mine.broken && !(!playerless && id == playerFormationId)) continue;
      final isPlayers = !playerless && id == playerFormationId;
      final count = mine.count - _pendingFor(mine) - (isPlayers && !dead ? 1 : 0);
      final at = op.graph.byId(mine.at);
      for (var m = 0; m < count && room[mine.side]! > 0; m++) {
        room[mine.side] = room[mine.side]! - 1;
        final have = _unit(mine.id, m);
        final (se, sn) = isPlayers || at == null ? (pe - 3 - m * 1.5, pn - 2 + (m % 3) * 1.5) : _slot(op, at, mine, m);
        final u = have ??
            (LiveUnit(mine.id, m, mine.side, mine.kind, mine.at, se, sn)
              ..cooldownS = 1 + 2 * combatUnit(seed, mine.id, m));
        want.add(u
          ..squad = true
          ..formationCount = mine.count
          ..quality = mine.quality);
      }
    }

    for (final o in objs) {
      for (final f in op.formations) {
        if (owned.contains(f.id)) continue;
        final marching = f.at == o.id && t < f.arriveStep && f.fromAt != null;
        if (!f.presentAt(o.id, t) && !marching) continue;
        final count = f.count - _pendingFor(f);
        for (var m = 0; m < count && room[f.side]! > 0; m++) {
          room[f.side] = room[f.side]! - 1;
          final (se, sn) = _slot(op, o, f, m);
          final cover = f.side == CombatSide.defender ? o.fDef + (o.dugIn ? kDigInFortification : 0) : 1.0;
          final have = _unit(f.id, m);
          if (have != null) {
            want.add(have
              ..cover = cover
              ..objectiveId = o.id
              ..oe = o.e
              ..on = o.n
              ..te = se
              ..tn = sn
              ..formationCount = f.count
              ..quality = f.quality);
            continue;
          }
          // A marching squad appears where it set out from.
          final from = marching ? op.graph.byId(f.fromAt!) : null;
          final (be, bn) = from != null && raster.contains(from.e, from.n) ? _slot(op, from, f, m) : (se, sn);
          want.add(LiveUnit(f.id, m, f.side, f.kind, o.id, be, bn)
            ..cover = cover
            ..oe = o.e
            ..on = o.n
            ..te = se
            ..tn = sn
            ..formationCount = f.count
            ..quality = f.quality
            ..cooldownS = 1 + 2 * combatUnit(seed, f.id, m));
        }
      }
    }
    units
      ..clear()
      ..addAll(want);
  }

  LiveUnit? _unit(int formationId, int member) {
    for (final u in units) {
      if (u.formationId == formationId && u.member == member) return u;
    }
    return null;
  }

  /// Where a member stands: defenders in a ring 12–40 m round the objective,
  /// attackers 55–85 m out on the side facing the LZ.
  (double, double) _slot(Operation op, Objective o, Formation f, int m) {
    final lz = op.graph.byId(op.lzId);
    final toLz = lz == null ? 0.0 : math.atan2(lz.n - o.n, lz.e - o.e);
    final u = combatUnit(seed, f.id * 64 + m, 7);
    if (f.side == CombatSide.defender) {
      final a = 2 * math.pi * (m * 0.618 + f.id * 0.31) + 0.4 * u;
      final r = 12 + 28 * combatUnit(seed, f.id * 64 + m, 8);
      return (o.e + r * math.cos(a), o.n + r * math.sin(a));
    }
    final a = toLz + (u - 0.5) * 1.2;
    final r = 55 + 30 * combatUnit(seed, f.id * 64 + m, 9);
    return (o.e + r * math.cos(a), o.n + r * math.sin(a));
  }

  /// The player's order to their squad (§7H): 1 follow, 2 hold where the
  /// player stands, 3 take [objectiveId].
  void command(SquadOrder o, {String? objectiveId}) {
    order = o;
    attackTarget = o == SquadOrder.attack ? objectiveId : null;
    holdAt = o == SquadOrder.hold ? (_eye.$1, _eye.$2) : null;
  }

  /// One frame of [dt] s. [eye] is the player's eye (east, north, height
  /// above the ground under it), [aim] a unit vector in the same frame.
  void step(
    double dt, {
    required (double, double, double) eye,
    required (double, double, double) aim,
    required bool trigger,
    required bool reload,
  }) {
    _eye = eye;
    final hl = math.sqrt(aim.$1 * aim.$1 + aim.$2 * aim.$2);
    if (hl > 1e-6) _heading = (aim.$1 / hl, aim.$2 / hl);
    for (final tr in tracers) {
      tr.ageS += dt;
    }
    tracers.removeWhere((tr) => tr.ageS > 0.25);
    _squadTargets();
    _move(dt);
    _defend(dt, eye);
    _squadFire(dt);
    _squadArrival();
    if (dead) {
      deadS = math.max(0, deadS - dt);
      return;
    }
    _rifle(dt, eye, aim, trigger, reload);
  }

  bool _sees((double, double, double) a, (double, double, double) b) => nav?.lineOfSight(a, b) ?? true;

  void _squadTargets() {
    final squad = [for (final u in units) if (u.squad) u];
    final (fe, fn) = _heading;
    for (var i = 0; i < squad.length; i++) {
      final u = squad[i];
      // With no player to follow, a squad holds where it stands until sent.
      if (playerless && order != SquadOrder.attack) continue;
      final back = 4.0 + 3 * (i ~/ 3), side = ((i % 3) - 1) * 3.0;
      switch (order) {
        case SquadOrder.follow:
          u
            ..te = _eye.$1 - fe * back - fn * side
            ..tn = _eye.$2 - fn * back + fe * side;
        case SquadOrder.hold:
          final (he, hn) = holdAt ?? (_eye.$1, _eye.$2);
          u
            ..te = he - fe * back - fn * side
            ..tn = hn - fn * back + fe * side;
        case SquadOrder.attack:
          final o = _attackObjective;
          if (o == null) break;
          final a = 2 * math.pi * i / math.max(1, squad.length);
          u
            ..te = o.e + 15 * math.cos(a)
            ..tn = o.n + 15 * math.sin(a);
      }
    }
  }

  /// Every unit a step nearer its target: straight when it is near or in
  /// plain sight, else down a flow field — its objective's, or (the squad
  /// following or holding) the player's cell's, a few kept at a time.
  void _move(double dt) {
    final reach = kLiveWalkMps * dt;
    final g = nav;
    for (final u in units) {
      if (u.kind == FormationKind.emplacement) continue;
      final de = u.te - u.e, dn = u.tn - u.n;
      final d = math.sqrt(de * de + dn * dn);
      if (d < 0.3) continue;
      (double, double)? next;
      if (g != null && d > 20 && !g.lineOfSight((u.e, u.n, 1.0), (u.te, u.tn, 1.0))) {
        if (u.squad && order != SquadOrder.attack) {
          final cell = g.cellOf(u.te, u.tn);
          if (cell != null) {
            next = g.step(g.flowTo('p$cell', u.te, u.tn, transient: true), u.e, u.n, reach, (u.te, u.tn));
          }
        } else {
          final o = u.squad ? _attackObjective : null;
          final (ge, gn) = o == null ? (u.oe, u.on) : (o.e, o.n);
          final id = o?.id ?? u.objectiveId;
          next = g.step(g.flowTo('o$id', ge, gn), u.e, u.n, reach, (u.te, u.tn));
        }
      }
      next ??= d <= reach ? (u.te, u.tn) : (u.e + de / d * reach, u.n + dn / d * reach);
      u
        ..e = next.$1
        ..n = next.$2;
    }
  }

  /// Each defender fires at the nearest attacker it can see in range — the
  /// player, the player's squad, or another attacker. A shot at the player
  /// or the squad is real; the rest are tracers, their losses the resolver's.
  void _defend(double dt, (double, double, double) eye) {
    for (final u in [...units]) {
      if (u.side != CombatSide.defender || !units.contains(u)) continue;
      u.cooldownS -= dt;
      if (u.cooldownS > 0) continue;
      final rate = u.kind == FormationKind.emplacement ? 3.0 : 1.0;
      final key = u.formationId * 64 + u.member;
      u.cooldownS = (1.5 + combatUnit(seed, key, 1000 + u.shots)) / rate;
      final from = (u.e, u.n, 1.4);
      var d = double.infinity;
      LiveUnit? other;
      var atPlayer = false;
      if (!dead) {
        final dp = math.sqrt((eye.$1 - u.e) * (eye.$1 - u.e) + (eye.$2 - u.n) * (eye.$2 - u.n));
        if (dp <= kDefenderRangeM && _sees(from, eye)) {
          d = dp;
          atPlayer = true;
        }
      }
      for (final a in units) {
        if (a.side != CombatSide.attacker) continue;
        final da = math.sqrt((a.e - u.e) * (a.e - u.e) + (a.n - u.n) * (a.n - u.n));
        if (da < d && da <= kDefenderRangeM && _sees(from, (a.e, a.n, 1.2))) {
          d = da;
          other = a;
          atPlayer = false;
        }
      }
      if (!atPlayer && other == null) continue;
      u.shots++;
      final hit = combatUnit(seed, key, 2000 + u.shots) <
          kDefenderAccuracy * u.quality * math.min(1.0, 30 / math.max(d, 1));
      final miss = hit ? 0.0 : 1.5 + 2 * combatUnit(seed, key, 3000 + u.shots);
      if (atPlayer) {
        tracers.add(Tracer(u.e, u.n, 1.4, eye.$1 + miss, eye.$2 - miss * 0.5, eye.$3 - 0.3, CombatSide.defender));
        if (hit) {
          hp -= kDefenderDamage;
          if (hp <= 0) {
            deadS = kDeathCameraS;
            casualties.add(playerFormationId);
          }
        }
        continue;
      }
      final a = other!;
      tracers.add(Tracer(u.e, u.n, 1.4, a.e + miss, a.n - miss * 0.5, 1.2, CombatSide.defender));
      if (hit && a.squad) _wound(a, kDefenderDamage);
    }
  }

  /// The squad fires like a defender does, at the nearest defender it sees.
  void _squadFire(double dt) {
    for (final u in [...units]) {
      if (!u.squad || !units.contains(u)) continue;
      u.cooldownS -= dt;
      if (u.cooldownS > 0) continue;
      final key = u.formationId * 64 + u.member;
      u.cooldownS = 1.5 + combatUnit(seed, key, 4000 + u.shots);
      LiveUnit? target;
      var d = double.infinity;
      for (final v in units) {
        if (v.side != CombatSide.defender) continue;
        final dv = math.sqrt((v.e - u.e) * (v.e - u.e) + (v.n - u.n) * (v.n - u.n));
        if (dv < d && dv <= kDefenderRangeM && _sees((u.e, u.n, 1.4), (v.e, v.n, 1.2))) {
          d = dv;
          target = v;
        }
      }
      if (target == null) continue;
      u.shots++;
      // A defender at its slot is behind its objective's works.
      final dug = (target.e - target.te).abs() + (target.n - target.tn).abs() < 1 ? target.cover : 1.0;
      final hit = combatUnit(seed, key, 5000 + u.shots) <
          kDefenderAccuracy * u.quality * math.min(1.0, 30 / math.max(d, 1)) / dug;
      tracers.add(Tracer(u.e, u.n, 1.4, target.e, target.n, hit ? 1.2 : 2.6, CombatSide.attacker));
      if (hit) _wound(target, kDefenderDamage);
    }
  }

  /// [u] takes [damage]; dead, it leaves the bubble and the battle loses
  /// the member.
  void _wound(LiveUnit u, double damage) {
    u.hp -= damage;
    if (u.hp > 0) return;
    if (u.side == CombatSide.defender) kills++;
    casualties.add(u.formationId);
    _pending.add((u.formationId, u.formationCount));
    units.remove(u);
  }

  /// Each squad's centre on its objective: tell the battle, once.
  void _squadArrival() {
    final o = _attackObjective;
    if (o == null) return;
    for (final id in _owned) {
      var ce = 0.0, cn = 0.0, k = 0;
      for (final u in units) {
        if (u.formationId != id || !u.squad) continue;
        ce += u.e;
        cn += u.n;
        k++;
      }
      if (k == 0) continue;
      ce /= k;
      cn /= k;
      if (math.sqrt((o.e - ce) * (o.e - ce) + (o.n - cn) * (o.n - cn)) >= kSquadArriveM) continue;
      if (_arrivedAt[id] == o.id) continue;
      _arrivedAt[id] = o.id;
      arrivals.add((id, o.id));
      if (!playerless && id == playerFormationId && _squadAt != o.id) {
        _squadAt = o.id;
        squadArrived = o.id;
      }
    }
  }

  void _rifle(double dt, (double, double, double) eye, (double, double, double) aim, bool trigger,
      bool reload) {
    if (reloadS > 0) {
      reloadS -= dt;
      if (reloadS <= 0) magazine = kRifleMagazine;
      return;
    }
    if (reload && magazine < kRifleMagazine) {
      reloadS = kRifleReloadS;
      return;
    }
    _fireS = math.max(0, _fireS - dt);
    if (!trigger || _fireS > 1e-9) return;
    if (magazine <= 0) {
      reloadS = kRifleReloadS;
      return;
    }
    magazine--;
    _fireS = 1 / kRifleRate;
    var hit = rayHit(eye, aim);
    // A wall or a hill in the way stops the round.
    if (hit != null) {
      final t = hit.$2;
      if (!_sees(eye, (eye.$1 + aim.$1 * t, eye.$2 + aim.$2 * t, (eye.$3 + aim.$3 * t).clamp(0.2, 3.0)))) {
        hit = null;
      }
    }
    final reach = hit?.$2 ?? kRifleRangeM;
    tracers.add(Tracer(eye.$1, eye.$2, eye.$3 - 0.2, eye.$1 + aim.$1 * reach, eye.$2 + aim.$2 * reach,
        eye.$3 + aim.$3 * reach, CombatSide.attacker));
    final u = hit?.$1;
    if (u == null || u.side != CombatSide.defender) return;
    _wound(u, kRifleDamage);
  }

  /// The nearest unit along the ray from [eye] in [aim] within rifle range,
  /// and how far, or null.
  (LiveUnit, double)? rayHit((double, double, double) eye, (double, double, double) aim) {
    (LiveUnit, double)? best;
    final h2 = aim.$1 * aim.$1 + aim.$2 * aim.$2;
    for (final u in units) {
      final ve = u.e - eye.$1, vn = u.n - eye.$2;
      // Closest approach of the ray to the unit's vertical axis, in plan.
      final t = h2 < 1e-12 ? 0.0 : (ve * aim.$1 + vn * aim.$2) / h2;
      if (t <= 0 || t > kRifleRangeM) continue;
      final pe = eye.$1 + aim.$1 * t - u.e, pn = eye.$2 + aim.$2 * t - u.n;
      if (pe * pe + pn * pn > kUnitRadiusM * kUnitRadiusM) continue;
      final h = eye.$3 + aim.$3 * t;
      if (h < 0 || h > kUnitHeightM) continue;
      if (best == null || t < best.$2) best = (u, t);
    }
    return best;
  }

  /// Back on your feet as a trooper of [formationId].
  void redeploy(int formationId) {
    playerFormationId = formationId;
    hp = 100;
    deadS = 0;
    magazine = kRifleMagazine;
    reloadS = 0;
  }
}
