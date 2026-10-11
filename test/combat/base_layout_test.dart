// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/combat/launch/base_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nothing in the way: the LZ is straight out from the centre, every socket free', () {
    final l = layoutBase(anchorE: 100, anchorN: 0, distanceM: 450, obstacles: const [], pads: const []);
    expect(l.e, closeTo(550, 1e-9));
    expect(l.n, closeTo(0, 1e-9));
    expect(l.free, kLayoutModuleSockets + kLayoutTurretSockets);
    expect(l.facing, closeTo(math.pi, 1e-9), reason: 'it faces back toward the anchor');
  });

  test('a building on the straight-out ground turns the LZ to clear ground', () {
    final l = layoutBase(
        anchorE: 100, anchorN: 0, distanceM: 450, obstacles: const [(550, 0, 60)], pads: const []);
    expect(l.free, kLayoutModuleSockets + kLayoutTurretSockets);
    expect((l.e - 550).abs() + l.n.abs(), greaterThan(100));
  });

  test('an LZ keeps 400 m from every pad', () {
    final l = layoutBase(
        anchorE: 100, anchorN: 0, distanceM: 450, obstacles: const [], pads: const [(560, 0)]);
    expect(math.sqrt((l.e - 560) * (l.e - 560) + l.n * l.n), greaterThanOrEqualTo(kPadClearM));
  });

  test('ground crowded all round: the best bearing, with its blocked sockets named', () {
    final obstacles = [
      for (var k = 0; k < 8; k++)
        (100 + 450 * math.cos(k * math.pi / 4) + 40, 450 * math.sin(k * math.pi / 4), 20.0)
    ];
    final l = layoutBase(anchorE: 100, anchorN: 0, distanceM: 450, obstacles: obstacles, pads: const []);
    expect(l.blockedModules.length + l.blockedTurrets.length, greaterThan(0));
    final ring = socketRing(l.e, l.n, l.facing, turrets: false);
    for (final i in l.blockedModules) {
      expect(obstacles.any((o) {
        final d = math.sqrt(math.pow(o.$1 - ring[i].$1, 2) + math.pow(o.$2 - ring[i].$2, 2));
        return d < o.$3 + kModuleHalfM;
      }), isTrue);
    }
  });
}
