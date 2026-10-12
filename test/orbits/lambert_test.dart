// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/lambert.dart';
import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lambert's problem: the arc a silo's salvo flies (combat.md §7O).
void main() {
  final moon = SampleWorld.realSystem().require(SampleWorld.moon);
  const conv = StateVectorOrbitConverter();
  final r = moon.radius;

  Vector3 onGround(double latDeg, double lonDeg, [double h = 0]) {
    final la = latDeg * math.pi / 180, lo = lonDeg * math.pi / 180;
    return Vector3(math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo), math.sin(la)) * (r + h);
  }

  /// Where the departure velocity actually takes the body after [tof].
  Vector3 flown(Vector3 r1, Vector3 v1, double tof) {
    final orbit = conv.toOrbit(position: r1, velocity: v1, body: moon, epoch: Epoch.zero);
    return conv.toStateVector(orbit, Epoch(tof)).position;
  }

  for (final (name, from, to, tof) in [
    ('a short hop, 2 km', onGround(10, 20, 50), onGround(10, 20.066), 60.0),
    ('across a mare, 300 km', onGround(0, 0, 50), onGround(5, 8), 600.0),
    ('a quarter of the Moon', onGround(-20, 30, 50), onGround(30, 110), 2400.0),
  ]) {
    test('$name: the departure velocity arrives where it was aimed', () {
      final s = solveLambert(from, to, tof, moon.mu);
      expect(s, isNotNull);
      final got = flown(from, s!.departure, tof);
      expect((got - to).length, lessThan(1.0), reason: '${(got - to).length} m off');
      // Above the ground all the way: a ballistic arc, not a tunnel.
      final orbit = conv.toOrbit(position: from, velocity: s.departure, body: moon, epoch: Epoch.zero);
      for (var i = 1; i < 20; i++) {
        final p = conv.toStateVector(orbit, Epoch(tof * i / 20)).position;
        expect(p.length, greaterThan(r - 1), reason: 'under the datum at ${i * 5}%');
      }
    });
  }

  test('no answer for points in line with the centre', () {
    expect(solveLambert(onGround(0, 0), onGround(0, 180), 1000, moon.mu), isNull);
    expect(solveLambert(onGround(0, 0), onGround(0, 0) * 2, 1000, moon.mu), isNull);
  });
}
