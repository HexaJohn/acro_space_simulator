// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/combat/base/base_modules.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/launch/snapshots.dart';
import 'package:acro_space_simulator/domain/combat/live/battle_raster.dart';
import 'package:acro_space_simulator/domain/combat/live/live_battle.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/resolver.dart';
import 'package:acro_space_simulator/domain/combat/resolver_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// Armour, heavy weapons and destruction: combat.md §7L.
void main() {
  SourceSnapshot source() {
    final s = a.source(troopers: 30);
    return SourceSnapshot(
      colonyId: s.colonyId,
      name: s.name,
      bodyId: s.bodyId,
      sources: s.sources,
      stock: {...s.stock, 'ore': 9999, 'steel': 500, 'electronics': 50},
      supportAvailable: 20,
      buildings: const ['barracks', 'gunfactory', 'spaceport', 'base'],
    );
  }

  Operation assault({Roe roe = Roe.restrained, BaseManifest? base}) {
    final src = source();
    return planColonyAssault(
      operationId: 1,
      target: a.independentTown(regulars: 6),
      sources: [src],
      draws: [for (final s in src.sources) TrooperDraw('src', s.siteId, s.available)],
      garrison: 2,
      kitDays: 6,
      roe: roe,
      base: base,
    ).operation!;
  }

  void until(Operation op, bool Function() done, {int max = 6000}) {
    for (var i = 0; i < max && !done(); i++) {
      op.advance(1);
    }
  }

  test('the vehicle bay needs the Fortress, then rolls out a crewed APC', () {
    final op = assault(
        base: const BaseManifest(materiel: 900, support: 16, steel: 200, doctrine: Doctrine.manual));
    final b = op.base!;
    until(op, () => b.deployed);
    expect(b.whyNot(ModuleKind.vehicleBay, 1), contains('Fortress'));
    expect(b.orderUpgrade(BaseTier.station), isTrue);
    until(op, () => b.core!.tier == BaseTier.station, max: 300);
    expect(b.orderUpgrade(BaseTier.fortress), isTrue);
    until(op, () => b.core!.tier == BaseTier.fortress, max: 300);
    expect(b.whyNot(ModuleKind.vehicleBay, 1), isNull);
    expect(b.orderBuild(ModuleKind.vehicleBay, 1), isTrue);
    until(op, () => b.apcsBuilt > 0 || op.resolved, max: 600);
    expect(b.apcsBuilt, 1);
    final apc = op.formations.lastWhere((f) => f.kind == FormationKind.armour);
    expect(apc.counterClass, CounterClass.arm);
    expect(apc.count, kApcCrew);
    expect(formationStrength(apc, op.tuning, armed: true),
        greaterThan(formationStrength(apc, op.tuning, armed: true) / op.tuning.armourPower * 3));
  });

  test('an AT turret is an anti-armour gun; the counters favour it against armour', () {
    final op = assault(base: const BaseManifest(materiel: 600, steel: 100, doctrine: Doctrine.manual));
    final b = op.base!;
    until(op, () => b.deployed);
    expect(b.orderBuild(ModuleKind.atTurret, 1), isTrue);
    until(op, () => b.countOf(ModuleKind.atTurret) == 1 && b.modules.any((m) => m.kind == ModuleKind.atTurret && m.formationId != null),
        max: 300);
    final m = b.modules.firstWhere((m) => m.kind == ModuleKind.atTurret);
    expect(op.formationById(m.formationId!)!.counterClass, CounterClass.empAt);
    expect(kCounters.factor(CounterClass.empAt, CounterClass.arm), greaterThan(1));
    expect(kCounters.factor(CounterClass.inf, CounterClass.arm), lessThan(1));
    expect(CounterTuning.byName('halo1').factor(CounterClass.inf, CounterClass.arm), 1,
        reason: 'an operation launched on the old table keeps it');
  });

  test('Heavy rules: harder fire, more civilians, the Seat strikeable, the fought-over razed', () {
    final heavy = assault(roe: Roe.heavy);
    final std = assault(roe: Roe.standard);
    for (final op in [heavy, std]) {
      until(op, () => op.resolved, max: 20000);
    }
    expect(heavy.razedSites, isNotEmpty);
    expect(std.razedSites, isEmpty);
    expect(heavy.razedSites, isNot(contains('farm')), reason: 'never life support');
    expect(heavy.strikeAllowed(heavy.graph.byId('seat')!), isTrue);
    expect(std.strikeAllowed(std.graph.byId('seat')!), isFalse);
    expect(heavy.civilianDead, greaterThan(0));
  });

  test('live: board an APC, drive it, and its cannon bursts on a defender; small arms barely scratch it', () {
    final op = assault();
    until(op, () => op.phase == OperationPhase.engaged);
    final lz = op.graph.byId(op.lzId)!;
    final apc = Formation(
      id: op.nextFormationId,
      side: CombatSide.attacker,
      faction: 'player',
      kind: FormationKind.armour,
      counterClass: CounterClass.arm,
      count: 3,
      quality: 1,
      morale: 0.9,
      at: op.lzId,
      arriveStep: op.clock.steps,
    );
    op.addAttacker(apc);
    final goal = op.graph.byId(op.goalId)!;
    final (ce, cn) = BattleRaster.centreFor(lz.e, lz.n, goal.e, goal.n);
    final r = BattleRaster(ce, cn);
    for (var k = 0; k < r.radii.length; k++) {
      r.put(k, 1737000);
    }
    final squad = op.formations.firstWhere((f) => f.side == CombatSide.attacker && f.kind == FormationKind.infantry);
    final live = LiveBattle(opId: op.id, seed: op.seed, playerFormationId: squad.id);
    live.sync(op, r, lz.e, lz.n);
    final v = live.units.firstWhere((u) => u.vehicle);
    expect(v.hp, 300, reason: '100 a crew member');
    expect(live.board(v.e + 2, v.n), isTrue);
    final start = (v.e, v.n);
    for (var i = 0; i < 30; i++) {
      live.drive(0.1, 1, 0);
    }
    expect(math.sqrt(math.pow(v.e - start.$1, 2) + math.pow(v.n - start.$2, 2)), greaterThan(5));
    // A defender straight ahead, 40 m out.
    final target = LiveUnit(999, 0, CombatSide.defender, FormationKind.militia, 'port', v.e + 40 * math.cos(v.heading),
        v.n + 40 * math.sin(v.heading))
      ..formationCount = 5;
    live.units.add(target);
    expect(live.fireCannon((math.cos(v.heading), math.sin(v.heading), -0.03)), isTrue);
    expect(live.fireCannon((1, 0, 0)), isFalse, reason: 'reloading');
    for (var i = 0; i < 20; i++) {
      live.step(0.05, eye: (v.e, v.n, 2.8), aim: (1, 0, 0), trigger: false, reload: false);
    }
    expect(live.units.contains(target), isFalse, reason: 'the round burst on it');
    expect(armourDamageScale(FormationKind.militia), 0.25);
    expect(armourDamageScale(FormationKind.emplacement, at: true), 1.6);
    expect(live.alight(), isNotNull);
    expect(live.driving, isNull);
  });
}
