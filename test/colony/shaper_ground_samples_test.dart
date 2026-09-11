// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shaper runs inside the world tick, and every ground sample it asks
/// for is a march of the composed field through the brushes already laid
/// there — milliseconds each on real ground. A pad asked its centre and its
/// corners twice over, a road corridor each of its samples up to four
/// times, and neighbouring lots share corners: after a road edit the tick
/// asked 52 samples for 14 places and the UI froze. What is pinned: one
/// call asks each place once, and the answers are the ones it was given.
void main() {
  test('one call asks the ground about each place once', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'samples',
    );
    city.layout.addRoad(const RoadSpline(
      id: 'main',
      controls: [Vec2(0, 0), Vec2(0, 240)],
    ));
    city.layout.addRoad(const RoadSpline(
      id: 'cross',
      controls: [Vec2(-120, 120), Vec2(120, 120)],
    ));
    final homes = kZoneSpecs['residential']![Density.low]!;
    final lots = city.layout.autoParcels.toList();
    expect(lots.length, greaterThan(8));
    for (final lot in lots.take(8)) {
      city.parcelBuildings[lot.id] = homes;
    }

    const radius = 6.371e6;
    var asked = 0;
    final seen = <Vector3>{};
    var repeats = 0;
    double ground(Vector3 d) {
      asked++;
      if (!seen.add(d)) repeats++;
      // Rolling ground, a pure function of the direction.
      return radius + 12 * math.sin(d.x * 9e4) * math.cos(d.y * 7e4);
    }

    final out = const CityTerrainShaper()
        .pending(city, bodyRadiusM: radius, groundRadiusAt: ground);
    expect(out.where((p) => p.key.startsWith('pad:')).length, 8,
        reason: 'every built lot levelled');
    expect(out.where((p) => p.key.startsWith('road:')), isNotEmpty,
        reason: 'the streets graded');
    expect(asked, greaterThan(20));
    expect(repeats, 0,
        reason: '$asked samples asked, $repeats of them twice or more');
    expect(asked, seen.length);
  });
}
