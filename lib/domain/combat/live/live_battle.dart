// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The live bubble (docs/plans/combat.md §7G): the battle the player has
/// joined as a soldier, drawn as units round their objectives.
///
/// A presenter over the operation, not a second battle: every unit is a
/// member of a formation the operation owns, and the bubble mirrors it each
/// frame — a member the resolver removes leaves the bubble. What the bubble
/// does to the battle (a defender shot dead, the player killed) leaves it
/// only as casualties for the view to send as commands, applied at the tick.
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

/// The rifle (§7G).
const double kRifleRate = 6; // rounds a second
const int kRifleMagazine = 30;
const double kRifleReloadS = 2;
const double kRifleDamage = 40;
const double kRifleRangeM = 300;

/// Defender fire: the chance a trained defender hits at 30 m or nearer,
/// scaled by its quality and falling with range.
const double kDefenderAccuracy = 0.35;
const double kDefenderRangeM = 200;
const double kDefenderDamage = 20;

/// A unit's target: a 0.45 m capsule from the ground to 1.8 m.
const double kUnitRadiusM = 0.45;
const double kUnitHeightM = 1.8;

const double kDeathCameraS = 5;
const int kLiveMaxPerSide = 24;

class LiveUnit {
  LiveUnit(this.formationId, this.member, this.side, this.kind, this.objectiveId, this.e, this.n);
  final int formationId;

  /// Which member of its formation: the bubble's key.
  final int member;
  final CombatSide side;
  final FormationKind kind;
  final String objectiveId;
  final double e, n;
  double hp = 100;

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
  LiveBattle({required this.opId, required this.seed, required this.playerFormationId});

  final int opId;
  final int seed;

  /// The squad the player fights as one of; changes on a redeploy.
  int playerFormationId;

  final List<LiveUnit> units = [];
  final List<Tracer> tracers = [];

  double hp = 100;
  int magazine = kRifleMagazine;
  double reloadS = 0;
  double _fireS = 0;

  /// Seconds left on the death camera; 0 alive.
  double deadS = 0;
  bool get dead => hp <= 0;

  /// Ready to redeploy (the death camera has run).
  bool get redeployReady => dead && deadS <= 0;

  /// Casualties for the view to send: a formation id per member killed —
  /// defenders the player shot, and the player's own squad when the player
  /// falls. Drained by the view.
  final List<int> casualties = [];

  /// Kills not yet seen in the formation's count: (formation, its count when
  /// the kill was made). Until the tick applies the command, the unit stays
  /// gone.
  final List<(int, int)> _pending = [];

  int kills = 0;

  int _pendingFor(Formation f) {
    _pending.removeWhere((p) => p.$1 == f.id && f.count < p.$2);
    var k = 0;
    for (final p in _pending) {
      if (p.$1 == f.id) k++;
    }
    return k;
  }

  /// Mirrors [op]: a unit for every member at an objective inside [raster],
  /// up to [kLiveMaxPerSide] a side, nearest objectives to ([pe], [pn])
  /// first. Units keep their hit points while their member stays.
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
    final want = <LiveUnit>[];
    final room = {CombatSide.attacker: kLiveMaxPerSide, CombatSide.defender: kLiveMaxPerSide};
    for (final o in objs) {
      for (final f in op.formations) {
        if (!f.presentAt(o.id, t)) continue;
        var count = f.count - _pendingFor(f);
        if (f.id == playerFormationId && !dead) count--; // the player is one of them
        for (var m = 0; m < count && room[f.side]! > 0; m++) {
          room[f.side] = room[f.side]! - 1;
          final have = _unit(f.id, m);
          if (have != null && have.objectiveId == o.id) {
            want.add(have
              ..formationCount = f.count
              ..quality = f.quality);
            continue;
          }
          final (e, n) = _slot(op, o, f, m);
          want.add(LiveUnit(f.id, m, f.side, f.kind, o.id, e, n)
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

  /// One frame of [dt] s. [eye] is the player's eye (east, north, height
  /// above the ground under it), [aim] a unit vector in the same frame.
  void step(
    double dt, {
    required (double, double, double) eye,
    required (double, double, double) aim,
    required bool trigger,
    required bool reload,
  }) {
    for (final tr in tracers) {
      tr.ageS += dt;
    }
    tracers.removeWhere((tr) => tr.ageS > 0.25);
    if (dead) {
      deadS = math.max(0, deadS - dt);
      return;
    }
    _defend(dt, eye);
    _rifle(dt, eye, aim, trigger, reload);
  }

  /// Each defender fires at the nearest attacker in range — the player, or
  /// one of the attackers standing in the bubble. Only a shot at the player
  /// does damage here: the others' losses are the resolver's, and counting
  /// them twice would bleed the attackers faster live than abstract.
  void _defend(double dt, (double, double, double) eye) {
    for (final u in units) {
      if (u.side != CombatSide.defender) continue;
      u.cooldownS -= dt;
      if (u.cooldownS > 0) continue;
      final rate = u.kind == FormationKind.emplacement ? 3.0 : 1.0;
      final key = u.formationId * 64 + u.member;
      u.cooldownS = (1.5 + combatUnit(seed, key, 1000 + u.shots)) / rate;
      final de = eye.$1 - u.e, dn = eye.$2 - u.n;
      final dPlayer = math.sqrt(de * de + dn * dn);
      LiveUnit? other;
      var dOther = double.infinity;
      for (final a in units) {
        if (a.side != CombatSide.attacker) continue;
        final d = math.sqrt((a.e - u.e) * (a.e - u.e) + (a.n - u.n) * (a.n - u.n));
        if (d < dOther) {
          dOther = d;
          other = a;
        }
      }
      final atPlayer = dPlayer <= dOther;
      final d = atPlayer ? dPlayer : dOther;
      if (d > kDefenderRangeM) continue;
      u.shots++;
      if (!atPlayer) {
        tracers.add(Tracer(u.e, u.n, 1.4, other!.e, other.n, 1.2, CombatSide.defender));
        continue;
      }
      final hit = combatUnit(seed, key, 2000 + u.shots) <
          kDefenderAccuracy * u.quality * math.min(1.0, 30 / math.max(d, 1));
      final miss = hit ? 0.0 : 1.5 + 2 * combatUnit(seed, key, 3000 + u.shots);
      tracers.add(Tracer(u.e, u.n, 1.4, eye.$1 + miss, eye.$2 - miss * 0.5, eye.$3 - 0.3, CombatSide.defender));
      if (hit) {
        hp -= kDefenderDamage;
        if (hp <= 0) {
          deadS = kDeathCameraS;
          casualties.add(playerFormationId);
          return;
        }
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
    final hit = rayHit(eye, aim);
    final reach = hit?.$2 ?? kRifleRangeM;
    tracers.add(Tracer(eye.$1, eye.$2, eye.$3 - 0.2, eye.$1 + aim.$1 * reach, eye.$2 + aim.$2 * reach,
        eye.$3 + aim.$3 * reach, CombatSide.attacker));
    final u = hit?.$1;
    if (u == null || u.side != CombatSide.defender) return;
    u.hp -= kRifleDamage;
    if (u.hp > 0) return;
    kills++;
    casualties.add(u.formationId);
    // Gone until the tick takes the member off its formation.
    _pending.add((u.formationId, u.formationCount));
    units.remove(u);
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
