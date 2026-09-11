// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/colony_ground.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road tool's ground: a raster filled lazily under a budget, read
/// bilinearly, dropped when the field changes.
void main() {
  const r = 1000.0;
  // A stand-in body: the "direction" carries the local point straight
  // through, and the surface is the datum plus whatever ground the test
  // wants.
  ColonyGroundSampler sampler({int budget = 1000}) => ColonyGroundSampler(
        toDirection: (p) => Vector3(p.e, p.n, 0),
        bodyRadiusM: r,
        fillBudget: budget,
      );

  test('is exact on a sloping plane', () {
    var calls = 0;
    final s = sampler()
      ..bind(1, surfaceRadiusAt: (x, y, z) {
        calls++;
        return r + 0.1 * x - 0.05 * y + 3;
      });
    s.beginFrame();
    for (final p in const [Vec2(3, 4), Vec2(-17.5, 40.25), Vec2(100, -100)]) {
      expect(s.heightAt(p), closeTo(0.1 * p.e - 0.05 * p.n + 3, 1e-9));
    }
    expect(s.exactHeightAt(const Vec2(10, 10)), closeTo(3.5, 1e-9));
    // A second read of warm ground asks the field nothing.
    final before = calls;
    s.heightAt(const Vec2(3, 4));
    expect(calls, before);
  });

  test('stays close to curved ground', () {
    final s = sampler()
      ..bind(1,
          surfaceRadiusAt: (x, y, z) => r + 20 * math.sin(x / 60) * math.cos(y / 80));
    s.beginFrame();
    for (var e = -100.0; e <= 100; e += 13.7) {
      final truth = 20 * math.sin(e / 60) * math.cos(35 / 80);
      expect(s.heightAt(Vec2(e, 35)), closeTo(truth, 0.2));
    }
  });

  test('spends no more than its budget per frame, then reads the base', () {
    var surfaceCalls = 0;
    final s = sampler(budget: 4)
      ..bind(1,
          surfaceRadiusAt: (x, y, z) {
            surfaceCalls++;
            return r + 10;
          },
          baseRadiusAt: (x, y, z) => r + 7);
    s.beginFrame();
    expect(s.heightAt(const Vec2(4, 4)), closeTo(10, 1e-9));
    expect(surfaceCalls, 4);
    // A far point: its corners are over budget, the base answers, nothing
    // is cached.
    expect(s.heightAt(const Vec2(400, 400)), closeTo(7, 1e-9));
    expect(s.warmAt(const Vec2(400, 400)), isFalse);
    // Next frame fills it.
    s.beginFrame();
    expect(s.heightAt(const Vec2(400, 400)), closeTo(10, 1e-9));
    expect(s.warmAt(const Vec2(400, 400)), isTrue);
  });

  test('drops everything when the field changes', () {
    final s = sampler()..bind(1, surfaceRadiusAt: (x, y, z) => r + 1);
    s.beginFrame();
    expect(s.heightAt(const Vec2(0, 0)), closeTo(1, 1e-9));
    expect(s.cachedCells, greaterThan(0));
    s.bind(1, surfaceRadiusAt: (x, y, z) => r + 99);
    expect(s.heightAt(const Vec2(0, 0)), closeTo(1, 1e-9),
        reason: 'same key: the same field');
    s.bind(2, surfaceRadiusAt: (x, y, z) => r + 99);
    expect(s.cachedCells, 0);
    s.beginFrame();
    expect(s.heightAt(const Vec2(0, 0)), closeTo(99, 1e-9));
  });

  test('reads zero before it is bound', () {
    expect(sampler().heightAt(const Vec2(5, 5)), 0);
    expect(sampler().exactHeightAt(const Vec2(5, 5)), 0);
  });
}
