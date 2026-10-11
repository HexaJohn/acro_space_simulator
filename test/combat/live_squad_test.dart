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
import 'package:acro_space_simulator/domain/combat/live/nav_grid.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// Squads that move: combat.md §7H.
void main() {
  Operation engaged({List<EmplacementSite> guns = const []}) {
    final src = a.source(troopers: 30);
    final op = planColonyAssault(
      operationId: 1,
      target: a.independentTown(regulars: 6, emplacements: guns),
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
    final squad = op.formations
        .firstWhere((f) => f.side == CombatSide.attacker && f.kind == FormationKind.infantry);
    return LiveBattle(opId: op.id, seed: op.seed, playerFormationId: squad.id);
  }

  test('the squad follows, holds, and takes the objective it is sent to', () {
    final op = engaged();
    final r = flat(op);
    final live = join(op)..nav = NavGrid(r, const []);
    final lz = op.graph.byId(op.lzId)!;
    var eye = (lz.e, lz.n, 1.7);
    live.sync(op, r, eye.$1, eye.$2);
    final squad = [for (final u in live.units) if (u.squad) u];
    expect(squad, isNotEmpty);
    // Walk 60 m east; the squad comes too.
    for (var i = 0; i < 300; i++) {
      eye = (lz.e + 60 * i / 300, lz.n, 1.7);
      live.sync(op, r, eye.$1, eye.$2);
      live.step(0.1, eye: eye, aim: (1, 0, 0), trigger: false, reload: false);
    }
    double far() => [for (final u in live.units) if (u.squad) math.sqrt(math.pow(u.e - eye.$1, 2) + math.pow(u.n - eye.$2, 2))]
        .fold(0.0, math.max);
    expect(far(), lessThan(20), reason: 'they kept up');
    live.command(SquadOrder.hold);
    final held = eye;
    for (var i = 0; i < 200; i++) {
      eye = (held.$1 + 80 * i / 200, held.$2, 1.7);
      live.step(0.1, eye: eye, aim: (1, 0, 0), trigger: false, reload: false);
    }
    expect(far(), greaterThan(50), reason: 'they stayed put');
    final seat = op.graph.byId('seat')!;
    live.command(SquadOrder.attack, objectiveId: 'seat');
    live.sync(op, r, eye.$1, eye.$2);
    // A walk, not a fight: nobody in the way.
    live.units.removeWhere((u) => u.side == CombatSide.defender);
    for (var i = 0; i < 8000 && live.squadArrived == null; i++) {
      live.step(0.1, eye: eye, aim: (1, 0, 0), trigger: false, reload: false);
    }
    expect(live.squadArrived, 'seat');
    final centre = [for (final u in live.units) if (u.squad) u]
        .fold((0.0, 0.0), (s, u) => (s.$1 + u.e, s.$2 + u.n));
    expect(math.sqrt(math.pow(centre.$1 / squad.length - seat.e, 2) + math.pow(centre.$2 / squad.length - seat.n, 2)),
        lessThan(kSquadArriveM));
  });

  test('a building between them: no shot either way', () {
    final op = engaged(guns: const [EmplacementSite('gun-1', 280, 30, 4)]);
    final r = flat(op);
    final live = join(op);
    live.sync(op, r, 0, 0);
    final gun = live.units.firstWhere((u) => u.kind == FormationKind.emplacement);
    // Only the gun and the player.
    live.units.removeWhere((u) => u != gun);
    // The player 60 m west of the gun, a building between.
    final eye = (gun.e - 60, gun.n, 1.7);
    live.nav = NavGrid(r, [(gun.e - 30, gun.n, 10)]);
    for (var i = 0; i < 600; i++) {
      live.step(0.05, eye: eye, aim: (1, 0, 0), trigger: true, reload: false);
    }
    expect(live.hp, 100, reason: 'it never saw the player');
    expect(gun.hp, 100, reason: 'and the rounds hit the wall');
  });

  test('the live squad is the bubble\'s: the resolver neither fights nor marches it, and it takes '
      'an empty objective by standing on it', () {
    final op = engaged();
    final squad = op.formations.firstWhere((f) => f.side == CombatSide.attacker && f.kind == FormationKind.infantry);
    op.liveSquad(squad.id, own: true);
    final count = squad.count;
    op.setOrder(OrderKind.auto);
    for (var i = 0; i < 300; i++) {
      op.advance(1);
    }
    expect(squad.count, count, reason: 'no abstract losses');
    expect(squad.at, op.lzId, reason: 'never marched off');
    final power = op.graph.byId('power')!;
    for (final f in op.formations) {
      if (f.side == CombatSide.defender && f.at == 'power') f.count = 0;
    }
    final before = power.control;
    op.liveSquad(squad.id, own: true, at: 'power');
    for (var i = 0; i < 30; i++) {
      op.advance(1);
    }
    expect(power.control, greaterThan(before));
    op.liveSquad(squad.id, own: false);
    expect(op.liveOwned, isEmpty);
  });
}
