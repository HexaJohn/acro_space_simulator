// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The corridor a graded road was cut to, read back for its drape
/// ([CityTerrainShaper.corridorGround]): each point on the segment it runs
/// along, at that segment's grade.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const shaper = CityTerrainShaper();

  test('a road whose first metre doubles back is still read along the '
      'segment each point runs on', () {
    // A generated street's hook: it leaves its node a metre the wrong way
    // before turning up the street (the 4-block colony's r10x0). Every
    // later point lies BEHIND that first segment, and read as "the first
    // segment whose far knot it has not passed" the whole street was drawn
    // at its first datum — 0.6 m in the ground 100 m on.
    const knots = [
      Vec2(0, 0),
      Vec2(0, -1), // the hook
      Vec2(0, 20),
      Vec2(0, 44),
      Vec2(0, 68),
    ];
    final datumStart = Float64List.fromList([100, 100, 101, 102]);
    final datumEnd = Float64List.fromList([100, 101, 102, 103]);
    // The drawn points, which need not fall on the hook's far knot: the
    // frame carries the corridor into its own plane, a hair off the points
    // a few hundred metres out, and a point exactly on that knot was all
    // that ever moved the old reading on.
    final pts = [
      const Vec2(0, 0),
      for (var n = 2.0; n <= 68; n += 3) Vec2(0, n),
    ];
    final out = Float64List(pts.length);
    shaper.corridorGround(pts, knots, datumStart, datumEnd, 4, out);

    // Clear of the next segment's easing (half width + falloff back from
    // its first knot), a point is exactly its own segment's grade: the
    // segments before it are levelled over by its own.
    final reach = 4 + shaper.roadFalloffM;
    var checked = 0;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final seg = p.n <= 20 ? 1 : (p.n <= 44 ? 2 : 3);
      final clear = seg + 1 >= knots.length - 1 ||
          knots[seg + 1].distanceTo(p) > reach + 0.5;
      if (!clear || (seg == 3 && p.n > 68 - reach - 0.5)) continue;
      final t = (p.n - knots[seg].n) / (knots[seg + 1].n - knots[seg].n);
      final line = datumStart[seg] + (datumEnd[seg] - datumStart[seg]) * t;
      expect(out[i], closeTo(line, 1e-3),
          reason: 'point ${p.n} m up the street, on segment $seg');
      checked++;
    }
    expect(checked, greaterThan(6));
  });
}
