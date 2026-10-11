// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/launch/snapshots.dart';
import 'package:acro_space_simulator/domain/combat/live/battle_raster.dart';
import 'package:acro_space_simulator/domain/combat/live/live_battle.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// The live bubble: combat.md §7G.
void main() {
  Operation engaged() {
    final src = a.source(troopers: 30);
    final op = planColonyAssault(
      operationId: 1,
      target: a.independentTown(regulars: 10, emplacements: const [EmplacementSite('gun-1', 280, 30, 4)]),
      sources: [src],
      draws: [for (final s in src.sources) TrooperDraw('src', s.siteId, s.available)],
      garrison: 2,
      kitDays: 6,
    ).operation!;
    op.setOrder(OrderKind.hold);
    for (var i = 0; i < 5000 && op.phase != OperationPhase.engaged; i++) {
      op.advance(1);
    }
    return op;
  }

  BattleRaster flat(Operation op) {
    final lz = op.graph.byId(op.lzId)!, goal = op.graph.byId(op.goalId)!;
    final (ce, cn) = BattleRaster.centreFor(lz.e, lz.n, goal.e, goal.n);
    final r = BattleRaster(ce, cn);
    for (var k = 0; k < r.radii.length; k++) {
      r.put(k, 1737000);
    }
    return r;
  }

  LiveBattle join(Operation op) {
    final squad = op.formations.firstWhere(
        (f) => f.side == CombatSide.attacker && f.kind == FormationKind.infantry && f.at == op.lzId);
    return LiveBattle(opId: op.id, seed: op.seed, playerFormationId: squad.id);
  }

  (double, double, double) aimAt(LiveUnit u, (double, double, double) eye) {
    final de = u.e - eye.$1, dn = u.n - eye.$2, dh = 1.0 - eye.$3;
    final l = math.sqrt(de * de + dn * dn + dh * dh);
    return (de / l, dn / l, dh / l);
  }

  test('the bubble mirrors the battle: every member at an objective in the square, '
      'the player one of their own squad', () {
    final op = engaged();
    final live = join(op);
    live.sync(op, flat(op), 0, 0);
    final t = op.clock.steps;
    final defenders = [
      for (final f in op.formations)
        if (f.side == CombatSide.defender && op.graph.objectives.any((o) => f.presentAt(o.id, t))) f.count
    ].fold(0, (s, v) => s + v);
    expect(live.units.where((u) => u.side == CombatSide.defender).length,
        math.min(defenders, kLiveMaxPerSide));
    final mine = op.formationById(live.playerFormationId)!;
    expect(live.units.where((u) => u.formationId == mine.id).length, mine.count - 1);
    final gun = live.units.firstWhere((u) => u.kind == FormationKind.emplacement);
    expect(gun.objectiveId, 'port');
    expect(math.sqrt(math.pow(gun.e - 300, 2) + math.pow(gun.n, 2)), lessThan(41));
  });

  test('a defender shot dead leaves the bubble at once and the battle at the tick', () {
    final op = engaged();
    final live = join(op);
    final raster = flat(op);
    live.sync(op, raster, 0, 0);
    final target = live.units.firstWhere((u) => u.side == CombatSide.defender);
    final f = op.formationById(target.formationId)!;
    final before = f.count;
    final eye = (target.e - 15, target.n, 1.7);
    for (var i = 0; i < 60 && live.casualties.isEmpty; i++) {
      live.step(1 / 30, eye: eye, aim: aimAt(target, eye), trigger: true, reload: false);
    }
    expect(live.casualties, [f.id]);
    expect(live.kills, 1);
    live.sync(op, raster, 0, 0);
    expect(live.units.where((u) => u.formationId == f.id).length,
        lessThan(math.min(before, kLiveMaxPerSide)), reason: 'still gone before the tick');
    for (final id in live.casualties) {
      op.liveCasualty(id);
    }
    live.casualties.clear();
    expect(f.count, before - 1);
    live.sync(op, raster, 0, 0);
    expect(live.units.where((u) => u.formationId == f.id).length, lessThanOrEqualTo(before - 1));
  });

  test('the defence shoots back: the player falls, the squad loses a member, and redeploys', () {
    final op = engaged();
    final live = join(op);
    live.sync(op, flat(op), 0, 0);
    final gun = live.units.firstWhere((u) => u.kind == FormationKind.emplacement);
    final eye = (gun.e + 20, gun.n, 1.7);
    var s = 0;
    for (; s < 3000 && !live.dead; s++) {
      live.step(1 / 30, eye: eye, aim: (1, 0, 0), trigger: false, reload: false);
    }
    expect(live.dead, isTrue);
    expect(live.casualties, [live.playerFormationId]);
    expect(live.redeployReady, isFalse);
    for (var i = 0; i < 6 * 30; i++) {
      live.step(1 / 30, eye: eye, aim: (1, 0, 0), trigger: false, reload: false);
    }
    expect(live.redeployReady, isTrue);
    live.redeploy(live.playerFormationId);
    expect(live.hp, 100);
  });

  test('the magazine empties and reloads', () {
    final op = engaged();
    final live = join(op);
    live.sync(op, flat(op), 0, 0);
    for (var i = 0; i < kRifleMagazine * 7; i++) {
      live.step(1 / 30, eye: (-500, -500, 1.7), aim: (0, -1, 0), trigger: true, reload: false);
    }
    expect(live.reloadS > 0 || live.magazine == kRifleMagazine, isTrue);
    for (var i = 0; i < 90; i++) {
      live.step(1 / 30, eye: (-500, -500, 1.7), aim: (0, -1, 0), trigger: false, reload: false);
    }
    expect(live.magazine, kRifleMagazine);
  });

  test('same seed, same inputs, same fight', () {
    double run() {
      final op = engaged();
      final live = join(op);
      live.sync(op, flat(op), 0, 0);
      final gun = live.units.firstWhere((u) => u.kind == FormationKind.emplacement);
      final eye = (gun.e + 40, gun.n + 10, 1.7);
      for (var i = 0; i < 600; i++) {
        live.step(1 / 30, eye: eye, aim: aimAt(gun, eye), trigger: i % 3 == 0, reload: false);
      }
      return live.hp * 1000 + live.kills;
    }

    expect(run(), run());
  });
}
