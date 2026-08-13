// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

const double _radius = 1.7374e6;

/// A field with real relief — for the paths where the base must show through.
TerrainField _rough({TerrainEdits? edits}) => TerrainField(
      radius: _radius,
      amplitude: 3000,
      featureScale: 18000,
      seed: 0x11A00,
      edits: edits,
    );

/// A perfect sphere, so every crater dimension has an exact expected value.
TerrainField _smooth({TerrainEdits? edits}) => TerrainField(
      radius: _radius,
      amplitude: 0,
      featureScale: 18000,
      seed: 0x11A00,
      edits: edits,
    );

double _ground(TerrainField f, Vector3 d) => f.groundRadiusAt(d.x, d.y, d.z);

double _density(TerrainField f, Vector3 p) => f.density(p.x, p.y, p.z);

void main() {
  group('pristine field', () {
    test('is byte-identical with no edits attached', () {
      final f = _rough();
      final rng = math.Random(11);
      for (var i = 0; i < 200; i++) {
        final d = Vector3(rng.nextDouble() * 2 - 1, rng.nextDouble() * 2 - 1,
                rng.nextDouble() * 2 - 1)
            .normalized;
        expect(_ground(f, d), f.baseGroundRadiusAt(d.x, d.y, d.z));
      }
    });

    test('is byte-identical with an empty store attached', () {
      final f = _rough(edits: TerrainEdits());
      final d = const Vector3(0.4, 0.5, 0.76).normalized;
      expect(_ground(f, d), f.baseGroundRadiusAt(d.x, d.y, d.z));
    });
  });

  group('crater on the surface', () {
    const dir = Vector3(0.36, -0.48, 0.8);
    final unit = dir.normalized;
    const depth = 20.0, radius = 50.0, rim = 4.0;

    TerrainField field() {
      final edits = TerrainEdits()
        ..add(TerrainBrush.crater(
          contactBF: unit * _radius,
          normalBF: unit,
          radiusM: radius,
          depthM: depth,
          rimHeightM: rim,
        ));
      return _smooth(edits: edits);
    }

    test('lowers the ground by exactly the bowl depth at its centre', () {
      expect(_ground(field(), unit), closeTo(_radius - depth, 0.05));
    });

    test('leaves the ground untouched a few radii away', () {
      final f = field();
      // Far enough out that the ray misses the brush entirely: the analytic
      // fast path must return, which shows up as EXACT equality with the base
      // (a raymarch would only ever get close).
      final away = _nudge(unit, radius * 40 / _radius);
      expect(_ground(f, away), f.baseGroundRadiusAt(away.x, away.y, away.z));
    });

    test('still reports the ground as a zero crossing of the density', () {
      final f = field();
      for (final frac in [0.0, 0.3, 0.7, 1.0, 1.6, 3.0]) {
        final d = _nudge(unit, radius * frac / _radius);
        final g = _ground(f, d);
        expect(_density(f, d * g).abs(), lessThan(1e-2),
            reason: 'density at the reported ground should be ~0 at $frac r');
        expect(_density(f, d * (g - 1.0)), lessThan(0), reason: 'below is rock');
        expect(_density(f, d * (g + 1.0)), greaterThan(0), reason: 'above is air');
      }
    });

    test('raises a rim above the surrounding datum', () {
      expect(_ground(field(), _nudge(unit, radius / _radius)),
          greaterThan(_radius + rim * 0.5));
    });

    test('is deterministic across identically built fields', () {
      final a = field(), b = field();
      final rng = math.Random(5);
      for (var i = 0; i < 50; i++) {
        final d = _nudge(unit, rng.nextDouble() * radius * 3 / _radius);
        expect(_ground(a, d), _ground(b, d));
      }
    });
  });

  test('a crater on rough terrain cuts from the local surface', () {
    final unit = const Vector3(0.1, 0.93, 0.35).normalized;
    final base = _rough();
    final ground = base.baseGroundRadiusAt(unit.x, unit.y, unit.z);
    final edits = TerrainEdits()
      ..add(TerrainBrush.crater(
        contactBF: unit * ground,
        normalBF: unit,
        radiusM: 60,
        depthM: 24,
        rimHeightM: 5,
      ));
    // The relief over a 60 m crater on an 18 km feature scale is small but not
    // zero, so this checks the depth against the LOCAL ground, with slack.
    expect(_ground(_rough(edits: edits), unit), closeTo(ground - 24, 2.0));
  });

  test('a fully buried void does not move the ground', () {
    final unit = const Vector3(0, 0.6, 0.8).normalized;
    final edits = TerrainEdits()
      ..add(TerrainBrush.sphere(
        centreBF: unit * (_radius - 50),
        radiusM: 10,
      ));
    // groundRadiusAt returns the OUTERMOST crossing, so a sealed cavity 50 m
    // down must leave the surface exactly where it was.
    expect(_ground(_smooth(edits: edits), unit), closeTo(_radius, 0.05));
  });

  test('overlapping craters compose without reopening the ground', () {
    final unit = const Vector3(0.7, 0.1, 0.7).normalized;
    final edits = TerrainEdits();
    for (var i = 0; i < 4; i++) {
      final d = _nudge(unit, i * 15.0 / _radius);
      edits.add(TerrainBrush.crater(
        contactBF: d * _radius,
        normalBF: d,
        radiusM: 40,
        depthM: 16,
        rimHeightM: 3,
        tick: i,
      ));
    }
    final f = _smooth(edits: edits);
    for (var i = 0; i < 4; i++) {
      final d = _nudge(unit, i * 15.0 / _radius);
      final g = _ground(f, d);
      expect(g, lessThan(_radius), reason: 'crater $i left no depression');
      expect(_density(f, d * (g + 1.0)), greaterThan(0));
      expect(_density(f, d * (g - 1.0)), lessThan(0));
    }
  });

  test('an edit at a cube corner behaves like any other', () {
    final unit = const Vector3(1, 1, 1).normalized;
    final edits = TerrainEdits()
      ..add(TerrainBrush.crater(
        contactBF: unit * _radius,
        normalBF: unit,
        radiusM: 50,
        depthM: 20,
        rimHeightM: 4,
      ));
    expect(_ground(_smooth(edits: edits), unit), closeTo(_radius - 20, 0.05));
  });
}

/// [unit] tilted by [angle] radians in a fixed, reproducible direction.
Vector3 _nudge(Vector3 unit, double angle) {
  if (angle == 0) return unit;
  final seed = unit.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
  final tangent = seed.cross(unit).normalized;
  return (unit * math.cos(angle) + tangent * math.sin(angle)).normalized;
}
