// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// Roads reach the renderer as SAMPLED body-fixed points, not control points:
/// a client re-running the spline could put the tarmac somewhere the buildings
/// are not.
void main() {
  CitySim withRoad() {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'roads',
    );
    city.layout.addRoad(const RoadSpline(
      id: 'main',
      roadClass: RoadClass.avenue,
      controls: [Vec2(0, 0), Vec2(40, 120), Vec2(-20, 260)],
    ));
    return city;
  }

  WorldSnapshot capture(CitySim city) => WorldSnapshot.capture(
        0,
        InMemoryVesselRepository(const []),
        system: SampleWorld.realSystem(),
        cities: InMemoryCityRepository([city]),
      );

  test('a colony road reaches the frame, on the surface', () {
    final city = withRoad();
    final snap = capture(city);

    expect(snap.roads, hasLength(1));
    final road = snap.roads.first;
    expect(road.colonyId, 'roads');
    expect(road.body, 'earth');
    expect(road.points.length % 3, 0);
    expect(road.points.length ~/ 3, greaterThan(10),
        reason: 'the centreline is sampled, not just its control points');
    expect(road.halfWidthM, RoadClass.avenue.halfWidth);
    expect(road.roadClassIndex, RoadClass.avenue.index);

    // Every point sits on the host body's surface.
    final earth = SampleWorld.realSystem().body(city.body.id)!;
    for (var i = 0; i + 2 < road.points.length; i += 3) {
      final r = math.sqrt(road.points[i] * road.points[i] +
          road.points[i + 1] * road.points[i + 1] +
          road.points[i + 2] * road.points[i + 2]);
      expect(r, closeTo(earth.radius, earth.radius * 0.001));
    }
  });

  test('roads survive the wire', () {
    final snap = capture(withRoad());
    final back = WorldSnapshot.fromJson(snap.toJson());
    expect(back.roads, hasLength(1));
    expect(back.roads.first.points, snap.roads.first.points);
    expect(back.roads.first.roadClassIndex, snap.roads.first.roadClassIndex);
  });

  test('a colony with no roads ships none', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth'),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'bare',
    );
    expect(capture(city).roads, isEmpty);
  });
}
