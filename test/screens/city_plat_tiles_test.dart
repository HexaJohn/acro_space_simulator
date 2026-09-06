// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart'
    show Vec2;
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_plat_tiles.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plat's culling is only as good as its buckets: a viewport must find
/// every cell it overlaps (and the ring around it, for straddlers), a
/// street cut into cells must not open a gap at an edge, and a lot's fan
/// must be the triangles the renderer expects.
void main() {
  const grid = PlatGrid(500);

  group('PlatGrid', () {
    test('keys are one int per cell and distinct across the sign', () {
      expect(grid.keyOf(0, 0), grid.keyOf(499.9, 499.9));
      expect(grid.keyOf(0, 0), isNot(grid.keyOf(500, 0)));
      expect(grid.keyOf(-0.1, 0), isNot(grid.keyOf(0, 0)));
      expect(grid.keyOf(-0.1, 0), grid.keyOf(-500, 0));
      expect(grid.keyOf(-1, -1), isNot(grid.keyOf(1, -1)));
    });

    test('a box finds every cell it overlaps, plus the margin ring', () {
      // 100..1100 spans cells 0..2 on each axis: nine cells.
      expect(grid.keysIn(100, 100, 1100, 1100).length, 9);
      expect(grid.keysIn(100, 100, 1100, 1100, margin: 1).length, 25);
      expect(grid.keysIn(10, 10, 20, 20).single, grid.keyOf(15, 15));
      expect(grid.keysIn(-10, -10, 10, 10).length, 4,
          reason: 'the origin is a corner of four cells');
    });

    test('a polyline is cut per cell with the crossing segment in both',
        () {
      final pts = [
        const Vec2(100, 100),
        const Vec2(400, 100),
        const Vec2(600, 100), // over the edge at 500
        const Vec2(900, 100),
      ];
      final runs = grid.splitPolyline(pts);
      expect(runs.length, 2);
      expect(runs[0].$1, grid.keyOf(100, 100));
      expect(runs[0].$2.map((p) => p.e), [100, 400, 600],
          reason: 'the first cell keeps the crossing segment');
      expect(runs[1].$1, grid.keyOf(600, 100));
      expect(runs[1].$2.map((p) => p.e), [400, 600, 900],
          reason: 'so does the second');
    });

    test('a polyline inside one cell is one run; empty is none', () {
      final runs =
          grid.splitPolyline([const Vec2(10, 10), const Vec2(20, 20)]);
      expect(runs.single.$2.length, 2);
      expect(grid.splitPolyline(const []), isEmpty);
    });
  });

  group('PlatTriangles', () {
    test('a quad fans into two triangles with y negated and its colour', () {
      final t = PlatTriangles();
      t.addFan(const [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)],
          0xFF112233);
      expect(t.vertexCount, 6);
      expect(t.positions, [0, 0, 10, 0, 10, -10, 0, 0, 10, -10, 0, -10]);
      // An Int32List stores ARGB with its alpha bit as the sign, the way
      // the engine reads it back.
      expect(t.colors.map((c) => c & 0xFFFFFFFF).toSet(), {0xFF112233});
    });

    test('a rect is six vertices; the buffer grows past its first block',
        () {
      final t = PlatTriangles();
      for (var i = 0; i < 100; i++) {
        t.addRect(i.toDouble(), 0, i + 1, 1, i);
      }
      expect(t.vertexCount, 600);
      expect(t.positions.length, 1200);
      expect(t.colors[599], 99);
      expect(t.positions[1196], 100, reason: "the last rect's right edge");
      expect(t.positions[1198], 99, reason: 'its left edge, last vertex');
    });

    test('a degenerate polygon adds nothing', () {
      final t = PlatTriangles();
      t.addFan(const [Vec2(0, 0), Vec2(1, 1)], 0);
      expect(t.isEmpty, isTrue);
    });
  });
}
