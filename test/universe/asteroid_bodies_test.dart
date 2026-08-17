// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The minable asteroids: present, physically plausible, and carrying
/// procedural voxel terrain that samples sanely at their (small) radii.
void main() {
  final system = RealSolarSystem.build();
  const ids = ['vesta', 'psyche', 'eros', 'ryugu'];

  test('all four asteroids exist, orbit the Sun, and have voxel terrain', () {
    for (final id in ids) {
      final b = system.require(BodyId(id));
      expect(b.parent, const BodyId('sun'), reason: id);
      expect(b.terrain, isNotNull, reason: '$id must be minable terrain');
      expect(b.terrain!.demBodyId, isNull,
          reason: '$id is fully procedural — no DEM bake exists');
      expect(b.soiRadius, greaterThan(b.radius), reason: id);
    }
  });

  test('bulk densities are asteroid-like, not gas-giant or degenerate', () {
    for (final id in ids) {
      final b = system.require(BodyId(id));
      expect(b.bulkDensity, inInclusiveRange(800, 4500), reason: id);
      expect(b.isGasGiant, isFalse, reason: id);
    }
  });

  test('terrain field samples sanely: bounded relief, solid core, air above',
      () {
    // Deterministic direction sweep (not a hot loop — a few dozen samples).
    final dirs = <List<double>>[];
    for (var i = 0; i < 8; i++) {
      for (var j = 0; j < 4; j++) {
        final lon = i * math.pi / 4;
        final lat = (j - 1.5) * 0.5;
        dirs.add([
          math.cos(lat) * math.cos(lon),
          math.cos(lat) * math.sin(lon),
          math.sin(lat),
        ]);
      }
    }

    for (final id in ids) {
      final b = system.require(BodyId(id));
      final f = b.terrainField!;
      // Detail features (craters) may legitimately exceed the configured
      // amplitude — TerrainDetail.maxMagnitude declares it — so bound with
      // slack rather than exactly.
      final relief = b.terrain!.amplitude * 2.5;
      for (final d in dirs) {
        final ground = f.baseGroundRadiusAt(d[0], d[1], d[2]);
        expect(ground, inInclusiveRange(b.radius - relief, b.radius + relief),
            reason: '$id ground at $d');
        // Deep inside: solid (negative). Well above the tallest relief: air.
        expect(f.density(d[0] * b.radius * 0.5, d[1] * b.radius * 0.5,
                d[2] * b.radius * 0.5),
            lessThan(0),
            reason: '$id core at $d');
        final high = b.radius + relief + 10;
        expect(f.density(d[0] * high, d[1] * high, d[2] * high), greaterThan(0),
            reason: '$id sky at $d');
      }
    }
  });
}
