// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/colony_relief.dart';
import 'package:flutter_test/flutter_test.dart';

/// The map's contours (colony_relief.dart): filled a budget at a time, then
/// traced where the ground crosses each level.
void main() {
  test('a cone is drawn as rings at the radius of each level', () {
    final g = ReliefGrid.around(0, 0, halfM: 1000, stepM: 40);
    // 100 m at the peak, a metre lower every ten metres out.
    double cone(double e, double n) => 100 - math.sqrt(e * e + n * n) / 10;
    var rounds = 0;
    while (!g.fill(cone, 500)) {
      rounds++;
    }
    expect(rounds, 5, reason: '2601 points, 500 a time: five rounds short');
    expect(contoursOf(g, interval: 10), isNotEmpty);
    for (final c in contoursOf(g, interval: 10)) {
      final want = (100 - c.level) * 10;
      final s = c.segments;
      for (var k = 0; k < s.length; k += 2) {
        final r = math.sqrt(s[k] * s[k] + s[k + 1] * s[k + 1]);
        // Linear interpolation on a 40 m lattice: within a few metres.
        expect(r, closeTo(want, 6), reason: 'level ${c.level}');
      }
    }
    // Every fifth level is an index contour.
    final majors = contoursOf(g, interval: 10).where((c) => c.major);
    expect(majors.map((c) => c.level), containsAll([50.0]));
  });

  test('flat ground has no contours, and an interval suits the range', () {
    final g = ReliefGrid.around(0, 0, halfM: 200, stepM: 40);
    g.fill((e, n) => 12, 1 << 20);
    expect(contoursOf(g), isEmpty);
    expect(contourInterval(560), 25);
    expect(contourInterval(40), 2);
  });
}
