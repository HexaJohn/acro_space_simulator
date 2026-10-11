// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// Squads ordered by hand from the command view: combat.md §7J.
void main() {
  Operation engaged() {
    final src = a.source(troopers: 30);
    final op = planColonyAssault(
      operationId: 1,
      target: a.independentTown(),
      sources: [src],
      draws: [for (final s in src.sources) TrooperDraw('src', s.siteId, s.available)],
      garrison: 2,
      kitDays: 6,
    ).operation!;
    for (var i = 0; i < 5000 && op.phase != OperationPhase.engaged; i++) {
      op.advance(1);
    }
    return op;
  }

  List<Formation> infantry(Operation op) =>
      [for (final f in op.formations) if (f.side == CombatSide.attacker && f.kind == FormationKind.infantry) f];

  test('a squad sent to an objective marches there and holds it, whatever the plan says', () {
    final op = engaged();
    final sq = infantry(op);
    final mine = sq.first;
    expect(op.directSquads([mine.id], 'power'), isNull);
    expect(mine.at, 'power');
    for (var i = 0; i < 1500; i++) {
      op.advance(1);
    }
    expect(mine.at, 'power', reason: 'the plan never moved it on');
    expect(op.directed.single, (mine.id, 'power'));
  });

  test('hold keeps a squad where it stands; back to the plan releases it', () {
    final op = engaged();
    final mine = infantry(op).first;
    final at = mine.at;
    op.directSquads([mine.id], Operation.holdHere);
    for (var i = 0; i < 600; i++) {
      op.advance(1);
    }
    expect(mine.at, at);
    op.directSquads([mine.id], null);
    expect(op.directed, isEmpty);
  });

  test('orders are saved, and travel as a command', () {
    final op = engaged();
    final mine = infantry(op).first;
    op.directSquads([mine.id], 'seat');
    final back = Operation.fromJson((jsonDecode(jsonEncode(op.toJson())) as Map).cast<String, dynamic>());
    expect(back.directed, op.directed);
    final cmd = SquadOrderCommand(const PlayerId('player'), 0, 1, [mine.id], 'seat');
    final round = CombatCommand.fromJson(cmd.toJson())! as SquadOrderCommand;
    expect(round.formationIds, [mine.id]);
    expect(round.target, 'seat');
    expect(op.directSquads([mine.id], 'nowhere'), contains('No such'));
  });
}
