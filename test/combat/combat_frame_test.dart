// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/combat/combat_frame.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// The battle as drawn: combat.md §7B.
void main() {
  Operation engaged() {
    final op = a.plan(a.independentTown()).operation!;
    while (op.phase != OperationPhase.engaged) {
      op.advance(1);
    }
    return op;
  }

  test('a march glides from where it set out to where it is going', () {
    final op = engaged();
    for (var i = 0; i < 31; i++) {
      op.advance(1);
    }
    final f = op.formations.firstWhere((f) => f.side == CombatSide.attacker);
    expect(f.fromAt, 'lz');
    double distFromLz(CombatFrame fr) {
      final s = fr.squads.firstWhere((s) => s.id == f.id);
      final lz = op.graph.byId('lz')!;
      return math.sqrt(math.pow(s.e - lz.e, 2) + math.pow(s.n - lz.n, 2));
    }

    final early = CombatFrame.of(op);
    expect(early.squads.firstWhere((s) => s.id == f.id).marching, isTrue);
    op.advance(0.5); // half a step: the frame reads the sub-step too
    final half = distFromLz(CombatFrame.of(op));
    op.advance(60);
    final later = distFromLz(CombatFrame.of(op));
    expect(half, greaterThan(distFromLz(early)));
    expect(later, greaterThan(half));
  });

  test('where both sides fight, the objective is contested and hot', () {
    final op = engaged();
    var guard = 0;
    CombatFrame frame = CombatFrame.of(op);
    while (!frame.objectives.any((o) => o.contested) && guard++ < 3000) {
      op.advance(1);
      frame = CombatFrame.of(op);
    }
    final hot = frame.objectives.firstWhere((o) => o.contested);
    expect(hot.heat, greaterThan(0));
    expect(frame.objectives.where((o) => o.isGoal).single.id, 'seat');
    // Squads at one objective are spread round it, not stacked.
    final there = [
      for (final s in frame.squads)
        if (!s.marching && (s.e - hot.e).abs() < 60 && (s.n - hot.n).abs() < 60) s
    ];
    final spots = {for (final s in there) '${s.e.round()},${s.n.round()}'};
    expect(spots.length, there.length);
  });

  test('bounds take in every objective', () {
    final b = CombatFrame.of(engaged()).bounds;
    // The town fixture spans the seat at -300 to the LZ at +750 east.
    expect(b.e, closeTo(225, 1));
    expect(b.radius, greaterThanOrEqualTo(525));
  });
}
