// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/preview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'combat_fixtures.dart';

/// The auto-resolved operation: docs/plans/combat.md §7.
void main() {
  String snap(Operation op) => jsonEncode(op.toJson());

  group('lifecycle', () {
    test('musters a quarter day, crosses in half a day, lands at the LZ', () {
      final op = portOperation();
      op.advance(29);
      expect(op.phase, OperationPhase.mustering);
      op.advance(2);
      expect(op.phase, OperationPhase.transit);
      op.advance(60);
      expect(op.phase, OperationPhase.engaged);
      expect(op.formations.where((f) => f.side == CombatSide.attacker).every((f) => f.at == 'lz'),
          isTrue);
    });

    test('from another body the crossing takes a day and a half', () {
      final op = portOperation(sameBody: false);
      op.advance(31 + 179);
      expect(op.phase, OperationPhase.transit);
      op.advance(2);
      expect(op.phase, OperationPhase.engaged);
    });
  });

  group('endings', () {
    test('a strong force retakes a lightly held port', () {
      final op = portOperation(troopers: 32, holders: 6);
      runOp(op);
      expect(op.outcome, OperationOutcome.won);
      expect(op.band, anyOf(OutcomeBand.decisiveVictory, OutcomeBand.closeVictory));
      expect(op.graph.byId('port')!.control, greaterThanOrEqualTo(0.9));
      expect(op.attackerAlive, greaterThan(16));
    });

    test('a hopeless force holds at the LZ and the battle ends in a ceasefire, '
        'not a massacre', () {
      final op = portOperation(troopers: 8, holders: 40, kitDays: 20);
      runOp(op, maxS: 2000);
      expect(op.outcome, OperationOutcome.ceasefire);
      expect(op.attackerRemoved, 0, reason: 'it never advanced into a fight it could not win');
    });

    test('the town sends its militia in waves while the port is attacked', () {
      final op = portOperation(troopers: 24, holders: 4, armedMilitia: 10, improvisedMilitia: 6);
      runOp(op);
      final militiaFormations = op.formations
          .where((f) => f.side == CombatSide.defender && f.kind == FormationKind.militia)
          .length;
      expect(militiaFormations, greaterThan(1), reason: 'the holders plus at least one wave');
      expect(op.defenderRaised, greaterThan(4));
    });

    test('a force that lands with no kit loses after two days', () {
      final op = portOperation(troopers: 8, holders: 40, kitDays: 0);
      runOp(op);
      expect(op.outcome, OperationOutcome.lost);
      expect(op.resolvedAtStep - op.engagedAtStep, inInclusiveRange(239, 241));
    });

    test('demoralised defenders surrender and are returned alive', () {
      final op = portOperation(troopers: 32, holders: 10, holderMorale: 0.17);
      runOp(op);
      expect(op.outcome, OperationOutcome.won);
      expect(op.defenderSurrendered, greaterThan(0));
    });

    test('withdrawing in contact costs a tenth of the survivors', () {
      final op = portOperation(troopers: 24, holders: 20, armedMilitia: 40);
      // Run until the attackers are at the port and fighting.
      var guard = 0;
      while (op.attackerRemoved == 0 && guard++ < 2000) {
        op.advance(1);
      }
      final before = op.attackerAlive;
      var cost = 0;
      for (final f in op.formations) {
        if (f.side == CombatSide.attacker && f.alive) cost += (f.count * 0.1).round();
      }
      op.withdraw();
      expect(op.outcome, OperationOutcome.withdrawn);
      expect(cost, greaterThan(0));
      expect(op.attackerAlive, before - cost, reason: 'a tenth of each squad, rounded');
    });

    test('casualties are half dead, half wounded, and charged home', () {
      final op = portOperation(troopers: 32, holders: 12, armedMilitia: 16);
      runOp(op);
      expect(op.attackerRemoved, greaterThan(0));
      expect((op.attackerDead - op.attackerWounded).abs(), lessThanOrEqualTo(4),
          reason: 'one odd member per squad at most');
      final homes = op.attackerByHome();
      expect(homes.single.home, 'colony-src');
      expect(homes.single.dead, op.attackerDead);
      expect(homes.single.alive, op.attackerAlive);
    });
  });

  group('determinism', () {
    test('twin runs agree to the byte', () {
      final a = portOperation(troopers: 24, holders: 10, armedMilitia: 12);
      final b = portOperation(troopers: 24, holders: 10, armedMilitia: 12);
      runOp(a);
      runOp(b);
      expect(snap(a), snap(b));
    });

    test('how time is chopped does not matter: 0.02 s, 0.5 s and 0.37 s ticks '
        'run the same steps', () {
      Operation run(double dt) {
        final op = portOperation(troopers: 24, holders: 10, armedMilitia: 12);
        final n = (900 / dt).round();
        for (var i = 0; i < n; i++) {
          op.advance(dt);
        }
        return op;
      }

      final fine = run(0.02), coarse = run(0.5);
      expect(snap(fine), snap(coarse));
      final odd = portOperation(troopers: 24, holders: 10, armedMilitia: 12);
      var fed = 0.0;
      while (fed < 900 - 1e-9) {
        final dt = (900 - fed) < 0.37 ? 900 - fed : 0.37;
        odd.advance(dt);
        fed += dt;
      }
      expect(odd.clock.steps, fine.clock.steps);
      expect(jsonEncode(odd.formations.map((f) => f.toJson()).toList()),
          jsonEncode(fine.formations.map((f) => f.toJson()).toList()));
    });

    test('save, load and carry on equals carrying on', () {
      final straight = portOperation(troopers: 24, holders: 10, armedMilitia: 12);
      final saved = portOperation(troopers: 24, holders: 10, armedMilitia: 12);
      for (var i = 0; i < 400; i++) {
        straight.advance(0.5);
        saved.advance(0.5);
      }
      final resumed = Operation.fromJson(
          (jsonDecode(snap(saved)) as Map).cast<String, dynamic>());
      runOp(straight);
      runOp(resumed);
      expect(snap(resumed), snap(straight));
    });

    test('the seed comes from the target and the operation id, not the tick', () {
      final a = portOperation(opId: 3), b = portOperation(opId: 3);
      expect(a.seed, b.seed);
      expect(portOperation(opId: 4).seed, isNot(a.seed));
    });
  });

  group('preview', () {
    test('runs other seeds, never touches the operation, and is repeatable', () {
      final op = portOperation(troopers: 24, holders: 12, armedMilitia: 12);
      final before = snap(op);
      final p1 = OperationPreview(op)..runAll();
      final p2 = OperationPreview(op)..runAll();
      expect(snap(op), before);
      expect(p1.results.length, 32);
      expect([for (final r in p1.results) r.band], [for (final r in p2.results) r.band]);
      var total = 0;
      for (final b in OutcomeBand.values) {
        total += p1.countOf(b);
      }
      expect(total, 32);
      // ignore: avoid_print
      print('preview 24 v 12+12: ${p1.wins}/32 won, attacker lost p10–p90 '
          '${p1.quantile((r) => r.attackerLost, 0.1)}–${p1.quantile((r) => r.attackerLost, 0.9)}');
    });

    test('at true parity chance decides, and the preview shows a spread', () {
      // Equal numbers, quality and morale: morale breaks by the share of a
      // squad lost, so only the fuzz can tip it.
      final op = portOperation(
          troopers: 16, holders: 16, holderQuality: 1, holderMorale: 0.8,
          holderSquads: true, kitDays: 10);
      final p = OperationPreview(op)..runAll();
      final losses = {for (final r in p.results) r.attackerLost};
      final bands = {for (final r in p.results) r.band};
      // ignore: avoid_print
      print('even odds: ${p.wins}/32 won, bands $bands, attacker lost '
          '${p.quantile((r) => r.attackerLost, 0.1)}–${p.quantile((r) => r.attackerLost, 0.9)}');
      expect(losses.length, greaterThanOrEqualTo(2));
      expect(bands.length, greaterThanOrEqualTo(2));
      expect(p.wins, inInclusiveRange(4, 28), reason: 'neither side a certainty');
    });

    test('weight of numbers: 16 troopers against 50 rebels of equal strength '
        'break first, every time', () {
      // Each loss is a bigger share of the smaller force, so its morale goes
      // first: the preview says so plainly instead of pretending it is a coin.
      final op = portOperation(troopers: 16, holders: 50, kitDays: 10);
      final p = OperationPreview(op)..runAll();
      expect(p.wins, 0);
    });

    test('in counted steps it finishes in about a second of frames', () {
      final op = portOperation(troopers: 24, holders: 12, armedMilitia: 12);
      final p = OperationPreview(op);
      var frames = 0;
      while (!p.advance(2000)) {
        frames++;
      }
      expect(p.done, isTrue);
      expect(frames, lessThan(120));
    });
  });
}
