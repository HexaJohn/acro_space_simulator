// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:flutter_test/flutter_test.dart';

const double _radius = 1.7374e6; // Moon-ish datum

/// A tangent frame around [dir], for walking a cap of directions.
({Vector3 t, Vector3 b}) _frame(Vector3 dir) {
  final seed = dir.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
  final t = seed.cross(dir).normalized;
  return (t: t, b: dir.cross(t));
}

/// [count] directions on a cone of half-angle [angle] around [dir].
List<Vector3> _cone(Vector3 dir, double angle, int count) {
  final f = _frame(dir);
  final sin = math.sin(angle), cos = math.cos(angle);
  return [
    for (var i = 0; i < count; i++)
      (dir * cos +
              f.t * (math.cos(2 * math.pi * i / count) * sin) +
              f.b * (math.sin(2 * math.pi * i / count) * sin))
          .normalized,
  ];
}

TerrainBrush _craterAt(Vector3 dir, {double radiusM = 40, int tick = 0}) =>
    TerrainBrush.crater(
      contactBF: dir.normalized * _radius,
      normalBF: dir.normalized,
      radiusM: radiusM,
      depthM: radiusM * 0.4,
      rimHeightM: radiusM * 0.08,
      tick: tick,
    );

void main() {
  group('empty store', () {
    test('looks up nothing and applies nothing', () {
      final e = TerrainEdits();
      expect(e.isEmpty, isTrue);
      expect(e.at(Vector3.unitZ), isEmpty);
      expect(e.apply(-3.5, const Vector3(0, 0, _radius)), -3.5);
      expect(e.maxBoundingRadiusM, 0);
    });
  });

  group('lookup', () {
    test('finds a brush from its own direction', () {
      final dir = const Vector3(0.3, -0.7, 0.5).normalized;
      final e = TerrainEdits()..add(_craterAt(dir));
      expect(e.at(dir), hasLength(1));
    });

    test('does not find it from the antipode', () {
      final dir = const Vector3(0.3, -0.7, 0.5).normalized;
      final e = TerrainEdits()..add(_craterAt(dir));
      expect(e.at(-dir), isEmpty);
    });

    test('covers the whole angular footprint', () {
      final dir = const Vector3(0.2, 0.9, -0.35).normalized;
      final brush = _craterAt(dir, radiusM: 120);
      final e = TerrainEdits()..add(brush);
      final alpha = math.asin(brush.boundingRadiusM / _radius);
      // Every direction inside the cap must resolve to a cell the brush was
      // inserted into — an under-covering index would silently drop the edit
      // for part of its own crater.
      for (final f in [0.0, 0.25, 0.5, 0.75, 0.99]) {
        for (final d in _cone(dir, alpha * f, 24)) {
          expect(e.at(d), hasLength(1),
              reason: 'missed at ${(f * 100).round()}% of the footprint');
        }
      }
    });

    test('survives a brush sitting on a cube corner', () {
      // Face corners are where the cubed sphere's addressing is most awkward:
      // three faces meet and cell adjacency stops being index arithmetic. The
      // index samples directions rather than walking neighbours precisely so
      // this case needs no special handling — verify that holds.
      final dir = const Vector3(1, 1, 1).normalized;
      final brush = _craterAt(dir, radiusM: 200);
      final e = TerrainEdits()..add(brush);
      final alpha = math.asin(brush.boundingRadiusM / _radius);
      for (final f in [0.0, 0.4, 0.8, 0.99]) {
        for (final d in _cone(dir, alpha * f, 32)) {
          expect(e.at(d), hasLength(1), reason: 'lost the edit at a cube corner');
        }
      }
    });

    test('survives a brush sitting on a cube edge', () {
      final dir = const Vector3(1, 0, 1).normalized;
      final brush = _craterAt(dir, radiusM: 200);
      final e = TerrainEdits()..add(brush);
      final alpha = math.asin(brush.boundingRadiusM / _radius);
      for (final f in [0.0, 0.5, 0.99]) {
        for (final d in _cone(dir, alpha * f, 32)) {
          expect(e.at(d), hasLength(1), reason: 'lost the edit at a cube edge');
        }
      }
    });

    test('separates edits that do not overlap', () {
      final a = const Vector3(0, 0, 1).normalized;
      final b = const Vector3(0, 1, 0).normalized;
      final e = TerrainEdits()
        ..add(_craterAt(a, tick: 1))
        ..add(_craterAt(b, tick: 2));
      expect(e.at(a).single.tick, 1);
      expect(e.at(b).single.tick, 2);
    });
  });

  group('ordering', () {
    test('overlapping edits come back in insertion order', () {
      final dir = Vector3.unitZ;
      final e = TerrainEdits();
      for (var i = 0; i < 5; i++) {
        e.add(_craterAt(dir, radiusM: 30.0 + i, tick: i));
      }
      expect([for (final b in e.at(dir)) b.tick], [0, 1, 2, 3, 4]);
    });

    test('order survives edits bucketed at different levels', () {
      // A big brush and a small one at the same spot land in different levels,
      // which is exactly the case where a naive merge would scramble order.
      final dir = Vector3.unitZ;
      final e = TerrainEdits()
        ..add(_craterAt(dir, radiusM: 2000, tick: 1))
        ..add(_craterAt(dir, radiusM: 8, tick: 2))
        ..add(_craterAt(dir, radiusM: 400, tick: 3));
      expect([for (final b in e.at(dir)) b.tick], [1, 2, 3]);
    });
  });

  group('bookkeeping', () {
    test('version bumps on every mutation', () {
      final e = TerrainEdits();
      final v0 = e.version;
      e.add(_craterAt(Vector3.unitZ));
      expect(e.version, greaterThan(v0));
      final v1 = e.version;
      e.clear();
      expect(e.version, greaterThan(v1));
      expect(e.isEmpty, isTrue);
      expect(e.at(Vector3.unitZ), isEmpty);
    });

    test('tracks the largest bounding radius', () {
      final e = TerrainEdits()
        ..add(_craterAt(Vector3.unitZ, radiusM: 10))
        ..add(_craterAt(Vector3.unitX, radiusM: 90))
        ..add(_craterAt(Vector3.unitY, radiusM: 25));
      expect(e.maxBoundingRadiusM, e.all[1].boundingRadiusM);
    });

    test('rebuilds from a replicated sequence', () {
      final source = TerrainEdits()
        ..add(_craterAt(Vector3.unitZ, tick: 7))
        ..add(_craterAt(Vector3.unitX, tick: 9));
      final copy = TerrainEdits.of(source.all);
      expect([for (final b in copy.all) b.tick], [7, 9]);
      expect(copy.at(Vector3.unitZ).single.tick, 7);
    });
  });

  group('index level', () {
    test('coarsens as the brush grows', () {
      var previous = 1 << 30;
      for (final r in [1.0, 10.0, 100.0, 1000.0, 10000.0]) {
        final level = TerrainEdits.indexLevelFor(_craterAt(Vector3.unitZ, radiusM: r));
        expect(level, lessThanOrEqualTo(previous));
        previous = level;
      }
    });

    test('a brush swallowing the body indexes at the roots', () {
      final huge = TerrainBrush.sphere(
        centreBF: const Vector3(0, 0, 10),
        radiusM: 1000,
      );
      expect(TerrainEdits.indexLevelFor(huge), 0);
      expect(TerrainEdits.chunksTouchedBy(huge, 0), hasLength(6));
    });
  });
}
