// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// Operational orders and reinforcements: combat.md §7B.
void main() {
  Operation engaged({int troopers = 45}) {
    final op = a.plan(a.independentTown(), troopers: troopers).operation!;
    while (op.phase != OperationPhase.engaged) {
      op.advance(1);
    }
    return op;
  }

  List<Formation> attackers(Operation op) =>
      [for (final f in op.formations) if (f.side == CombatSide.attacker) f];

  test('objectives carry where they stand, and the LZ lands 450 m out', () {
    final op = a.plan(a.independentTown()).operation!;
    final port = op.graph.byId('port')!, lz = op.graph.byId('lz')!;
    expect((port.e, port.n), (300.0, 0.0));
    expect(lz.e, closeTo(750, 1e-9));
    expect(lz.n, closeTo(0, 1e-9));
    final back = Operation.fromJson(
        (jsonDecode(jsonEncode(op.toJson())) as Map).cast<String, dynamic>());
    expect(back.graph.byId('lz')!.e, lz.e);
  });

  test('a march remembers where it set out from, for drawing', () {
    final op = engaged();
    for (var i = 0; i < 40; i++) {
      op.advance(1);
    }
    final f = attackers(op).first;
    expect(f.fromAt, 'lz');
    expect(f.at, op.path[1]);
    expect(f.arriveStep, greaterThan(f.departStep));
  });

  test('hold keeps them at the LZ; auto lets them go again', () {
    final op = engaged()..setOrder(OrderKind.hold);
    for (var i = 0; i < 200; i++) {
      op.advance(1);
    }
    expect(attackers(op).every((f) => f.at == 'lz'), isTrue);
    op.setOrder(OrderKind.auto);
    for (var i = 0; i < 60; i++) {
      op.advance(1);
    }
    expect(attackers(op).any((f) => f.at != 'lz'), isTrue);
  });

  test('attack sends them straight at the objective, then the plan resumes', () {
    final op = engaged()..setOrder(OrderKind.attack, target: 'power');
    for (var i = 0; i < 40; i++) {
      op.advance(1);
    }
    expect(attackers(op).every((f) => f.at == 'power'), isTrue);
    var guard = 0;
    while (op.graph.byId('power')!.control < 0.5 && guard++ < 4000) {
      op.advance(1);
    }
    for (var i = 0; i < 40; i++) {
      op.advance(1);
    }
    expect(op.order, OrderKind.auto, reason: 'taken, the order is done');
  });

  test('an attack on the LZ or on nothing is no order', () {
    final op = engaged()..setOrder(OrderKind.attack, target: 'lz');
    expect(op.order, OrderKind.auto);
    op.setOrder(OrderKind.attack, target: 'nowhere');
    expect(op.order, OrderKind.auto);
  });

  test('fall back brings them to the LZ and holds them there', () {
    final op = engaged();
    for (var i = 0; i < 40; i++) {
      op.advance(1);
    }
    expect(attackers(op).any((f) => f.at != 'lz'), isTrue);
    op.setOrder(OrderKind.fallBack);
    for (var i = 0; i < 900; i++) {
      op.advance(1);
    }
    expect(op.order, OrderKind.hold);
    expect(attackers(op).where((f) => f.alive && !f.broken).every((f) => f.at == 'lz'),
        isTrue);
  });

  test('reinforcements land at the LZ a mustering and a crossing later', () {
    final op = engaged(troopers: 15);
    final before = op.attackerRaised;
    final planned = planReinforcements(
      op: op,
      targetBodyId: 'moon',
      sources: [a.source(troopers: 15)],
      draws: const [TrooperDraw('src', 'b0', 15)],
    );
    expect(planned.refusal, isNull);
    final fresh = planned.formations;
    expect(fresh.first.id, greaterThanOrEqualTo(before > 0 ? 1 : 0));
    final lands = fresh.first.arriveStep;
    expect(lands - op.clock.steps, op.reinforcementDelaySteps);
    op.reinforce(fresh);
    expect(op.attackerRaised, before + 15);
    while (op.clock.steps < lands - 1) {
      op.advance(1);
    }
    expect(fresh.every((f) => f.at == FormationAt.transit), isTrue);
    op.advance(1);
    op.advance(1);
    expect(fresh.every((f) => f.at != FormationAt.transit), isTrue);
    // Ids stay unique and in order.
    final ids = [for (final f in op.formations) f.id];
    expect(ids, [...ids]..sort());
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('orders and reinforcements survive a save', () {
    final op = engaged()..setOrder(OrderKind.attack, target: 'power');
    final back = Operation.fromJson(
        (jsonDecode(jsonEncode(op.toJson())) as Map).cast<String, dynamic>());
    expect(back.order, OrderKind.attack);
    expect(back.orderTarget, 'power');
  });
}
