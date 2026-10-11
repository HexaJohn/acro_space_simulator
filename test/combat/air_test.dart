// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/combat/base/base_modules.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/launch/snapshots.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/powers/air.dart';
import 'package:acro_space_simulator/domain/combat/powers/orbital.dart';
import 'package:acro_space_simulator/domain/combat/resolver_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// Pilot and strikes: combat.md §7M.
void main() {
  SourceSnapshot source(List<String> buildings) {
    final s = a.source(troopers: 30);
    return SourceSnapshot(
      colonyId: s.colonyId,
      name: s.name,
      bodyId: s.bodyId,
      sources: s.sources,
      stock: {...s.stock, 'ore': 9999, 'steel': 200, 'electronics': 50, 'fuel': 400},
      supportAvailable: 20,
      buildings: buildings,
    );
  }

  Operation assault({List<String> buildings = const ['barracks', 'gunfactory', 'spaceport', 'airfield', 'silo'],
      Roe roe = Roe.standard}) {
    final src = source(buildings);
    return planColonyAssault(
      operationId: 1,
      target: a.independentTown(regulars: 6, emplacements: const [EmplacementSite('gun-1', 280, 30, 4)]),
      sources: [src],
      draws: [for (final s in src.sources) TrooperDraw('src', s.siteId, s.available)],
      garrison: 2,
      kitDays: 6,
      roe: roe,
      base: const BaseManifest(materiel: 600, support: 16, fuel: 200, steel: 60, doctrine: Doctrine.manual),
    ).operation!;
  }

  void until(Operation op, bool Function() done, {int max = 6000}) {
    for (var i = 0; i < max && !done(); i++) {
      op.advance(1);
    }
  }

  test('a gunship makes a 30 s pass over an objective, strafing at first, then flies off', () {
    final op = assault();
    final b = op.base!;
    until(op, () => b.deployed);
    b.stockC[kBaseStock.indexOf('ammo')] = 20000;
    expect(op.power('gunship', objectiveId: 'lz'), contains('where'));
    expect(op.power('gunship', objectiveId: 'port'), isNull);
    expect(op.power('gunship', objectiveId: 'port'), contains('not ready'));
    final g = op.formations.firstWhere((f) => f.kind == FormationKind.air);
    expect(g.counterClass, CounterClass.air);
    expect(g.at, 'port');
    expect(op.air.strafing(g.id, op.clock.steps), isTrue);
    until(op, () => !op.air.strafing(g.id, op.clock.steps), max: 20);
    expect(g.alive || g.dead > 0, isTrue);
    until(op, () => op.air.passes.isEmpty, max: 40);
    expect(g.count, 0, reason: 'flown off');
    expect(kCounters.factor(CounterClass.empAa, CounterClass.air), 1.6);
    expect(kCounters.factor(CounterClass.inf, CounterClass.air), lessThan(0.5));
  });

  test('no Airfield, no gunship; an airpad halves the wait', () {
    final none = assault(buildings: const ['barracks', 'gunfactory', 'spaceport']);
    until(none, () => none.base!.deployed);
    expect(none.power('gunship', objectiveId: 'port'), contains('Airfield'));
    final op = assault();
    final b = op.base!;
    until(op, () => b.deployed);
    expect(b.orderBuild(ModuleKind.airpad, 1), isTrue);
    until(op, () => b.countOf(ModuleKind.airpad) == 1 && b.modules.any((m) => m.kind == ModuleKind.airpad),
        max: 200);
    b.stockC[kBaseStock.indexOf('ammo')] = 20000;
    final t = op.clock.steps;
    expect(op.power('gunship', objectiveId: 'seat'), isNull);
    expect(op.air.gunshipReadyStep - t, (op.gunshipCooldownS / 2).round());
  });

  test('a silo strike waits on the source\'s missiles, then lands in 60 s with a 30 m scatter', () {
    final op = assault();
    until(op, () => op.base!.deployed);
    expect(op.power('silo', objectiveId: 'seat'), contains('rules of engagement'), reason: 'Standard: not the Seat');
    expect(op.power('silo', objectiveId: 'port'), isNull);
    expect(op.air.pendingSilo, 'port');
    expect(op.power('silo', objectiveId: 'power'), isNotNull);
    op.siloFired('port', ok: true);
    final s = op.orbital.inFlight.single;
    expect(s.impactStep - op.clock.steps, kSiloFlightS);
    expect(strikeCepM(s.slantM), closeTo(30, 1e-9));
    until(op, () => op.orbital.inFlight.isEmpty, max: 70);
    expect(op.orbital.craters, hasLength(1));
    final back = Operation.fromJson((jsonDecode(jsonEncode(op.toJson())) as Map).cast<String, dynamic>());
    expect(back.air.siloReadyStep, op.air.siloReadyStep);
  });

  test('the rebels\' silo strikes the base once a day; AA turrets bring missiles down', () {
    double hits(int aa) {
      var hit = 0;
      for (var seed = 0; seed < 6; seed++) {
        final op = assault();
        op.air.rebelSilos = 1;
        final b = op.base!;
        until(op, () => b.deployed);
        for (var i = 0; i < aa; i++) {
          b.orderBuild(ModuleKind.aaTurret, i + 1);
        }
        b.orderBuild(ModuleKind.stores, 0);
        until(op, () => op.air.rebelSeq >= 3 || op.resolved, max: 2000);
        hit += op.air.notices.where((n) => n.startsWith('A rebel missile')).length;
      }
      return hit.toDouble();
    }

    expect(hits(2), lessThanOrEqualTo(hits(0)));
  });
}
