// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/combat/live/battle_raster.dart';
import 'package:acro_space_simulator/domain/combat/live/nav_grid.dart';
import 'package:flutter_test/flutter_test.dart';

/// Navigation and sight: combat.md §7H.
void main() {
  BattleRaster flat({double Function(double e, double n)? height}) {
    final r = BattleRaster(0, 0, sideM: 400, cellM: 8);
    for (var k = 0; k < r.radii.length; k++) {
      final (e, n) = r.cellCentre(k);
      r.put(k, 1737000 + (height?.call(e, n) ?? 0));
    }
    return r;
  }

  test('a walk round a building reaches the far side', () {
    final nav = NavGrid(flat(), const [(0, 0, 40)]);
    final field = nav.flowTo('goal', 120, 0);
    var e = -120.0, n = 5.0;
    var steps = 0;
    while ((e - 120).abs() + n.abs() > 2 && steps < 400) {
      final next = nav.step(field, e, n, 2, (120, 0))!;
      e = next.$1;
      n = next.$2;
      steps++;
      expect(math.sqrt(e * e + n * n), greaterThan(38), reason: 'never through the walls');
    }
    expect(steps, lessThan(400));
  });

  test('sight is cut by a building and by a hill, not by open ground', () {
    final nav = NavGrid(flat(), const [(0, 0, 20)]);
    expect(nav.lineOfSight((-100, 50, 1.7), (100, 50, 1.2)), isTrue);
    expect(nav.lineOfSight((-100, 0, 1.7), (100, 0, 1.2)), isFalse);
    final hill = NavGrid(flat(height: (e, n) => 30 * math.exp(-(e * e + n * n) / (2 * 25 * 25))), const []);
    expect(hill.lineOfSight((-150, 0, 1.7), (150, 0, 1.7)), isFalse);
    expect(hill.lineOfSight((-150, 150, 1.7), (150, 150, 1.7)), isTrue);
  });

  test('a cliff is a wall', () {
    final nav = NavGrid(flat(height: (e, n) => e > 0 ? 50 : 0), const []);
    final field = nav.flowTo('up', 100, 0);
    final k = nav.cellOf(-100, 0)!;
    expect(field[k].isInfinite, isTrue, reason: 'no way up a 50 m step');
  });
}
