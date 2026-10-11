// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/combat/combat_rng.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/objective.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/resolver.dart';
import 'package:acro_space_simulator/domain/combat/resolver_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tuning = ResolverTuning();

  test('with every counter at 1, pairwise losses are each side\'s share of the '
      'other\'s capped strength', () {
    for (var trial = 0; trial < 200; trial++) {
      double r(int k) => combatUnit(trial, k, 7) * 20 + 0.1;
      final nA = 1 + (combatUnit(trial, 1, 1) * 4).floor();
      final nD = 1 + (combatUnit(trial, 2, 2) * 4).floor();
      final attS = [for (var i = 0; i < nA; i++) r(10 + i)];
      final defS = [for (var j = 0; j < nD; j++) r(20 + j)];
      final width = r(99);
      const fuzz = 1.07, fDef = 1.3, fAtt = 1.1;
      final l = contactLosses(
        attS: attS,
        attC: [for (var i = 0; i < nA; i++) CounterClass.inf],
        defS: defS,
        defC: [for (var j = 0; j < nD; j++) CounterClass.inf],
        width: width,
        fDef: fDef,
        fAtt: fAtt,
        fuzz: fuzz,
        dt: 1,
        tuning: tuning,
      );
      final sumA = attS.reduce((a, b) => a + b);
      final sumD = defS.reduce((a, b) => a + b);
      final eA = sumA < width ? sumA : width;
      final eD = sumD < width ? sumD : width;
      for (var j = 0; j < nD; j++) {
        expect(l.defenderLoss[j],
            closeTo(tuning.alpha * fuzz / fDef * eA * defS[j] / sumD, 1e-12));
      }
      for (var k = 0; k < nA; k++) {
        expect(l.attackerLoss[k],
            closeTo(tuning.alpha * (2 - fuzz) / fAtt * eD * attS[k] / sumA, 1e-12));
      }
    }
  });

  test('a fair fight: two 16-strong squads at a port each break at the 7th '
      'member removed, about three minutes in (the calibration pin)', () {
    // No fuzz, nobody holding the objective, both squads already there: the
    // rules alone, stepped at 1 s.
    const calm = ResolverTuning(fuzzAmplitude: 0);
    Formation squad(int id, CombatSide side) => Formation(
          id: id,
          side: side,
          faction: side == CombatSide.attacker ? Factions.player : 'colony:t',
          kind: FormationKind.infantry,
          count: 16,
          quality: 1,
          morale: 0.8,
          kitDays: 100,
          at: 'port',
        );
    final op = Operation(
      id: 1,
      targetColonyId: 't',
      goalId: 'port',
      lzId: 'lz',
      graph: ObjectiveGraph(
          [Objective(id: 'port', kind: ObjectiveKind.port, value: 10, width: 24)], []),
      formations: [squad(0, CombatSide.attacker), squad(1, CombatSide.defender)],
      militia: MilitiaPool(),
      defenderFaction: 'colony:t',
      tuning: calm,
      phase: OperationPhase.engaged,
      phaseEndsStep: 0,
    );
    int? brokeAt;
    var removedAtBreak = 0;
    for (var s = 0; s < 400 && brokeAt == null; s++) {
      op.advance(1.0);
      if (op.formations[0].broken) {
        brokeAt = op.clock.steps;
        removedAtBreak = op.formations[0].removed;
      }
    }
    // ignore: avoid_print
    print('fair fight: broke at $brokeAt s with $removedAtBreak removed; '
        'defender removed ${op.formations[1].removed}');
    expect(removedAtBreak, 7);
    expect(brokeAt, inInclusiveRange(170, 180));
    expect(op.formations[1].removed, 7, reason: 'symmetric: the same moment');
  });

  test('the control swing is κ at total dominance and zero at parity', () {
    expect(controlSwing(5, 0, 1, tuning), closeTo(tuning.kappa, 1e-15));
    expect(controlSwing(0, 5, 1, tuning), closeTo(-tuning.kappa, 1e-15));
    expect(controlSwing(3, 3, 1, tuning), 0);
  });

  test('the counter table defaults to 1 everywhere', () {
    const m = CounterTuning.uniform();
    for (final a in CounterClass.values) {
      for (final b in CounterClass.values) {
        expect(m.factor(a, b), 1.0);
      }
    }
  });
}
