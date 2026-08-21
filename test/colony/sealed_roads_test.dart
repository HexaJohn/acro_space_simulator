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
import 'package:flutter_test/flutter_test.dart';

/// Where the air is not breathable, people travel in a tube.
///
/// The colony already said so for its GRID roads — `roadSealed` renders those
/// as pressurised transport tubes, captured at build time so terraforming does
/// not silently unseal a street built for vacuum. The spline roads the
/// in-world editor builds never carried the flag, so a lunar street was drawn
/// as open asphalt with a curb nobody could stand on.
void main() {
  CitySim on(String bodyId) => CitySim.found(
        CityConfig(bodyId: bodyId, gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'seal-$bodyId',
      );

  test('a road built on the Moon is sealed; on Earth it is not', () {
    final moon = on('moon')
      ..commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    expect(moon.breathable, isFalse);
    expect(moon.layout.roads.every((r) => r.sealed), isTrue,
        reason: 'vacuum outside — pedestrians need a tube');

    final earth = on('earth')
      ..commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    expect(earth.breathable, isTrue);
    expect(earth.layout.roads.any((r) => r.sealed), isFalse,
        reason: 'open air — an ordinary pavement will do');
  });

  test('splitting a sealed road keeps every piece sealed', () {
    final moon = on('moon')
      ..commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street)
      ..commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.avenue);
    expect(moon.layout.roads.length, greaterThanOrEqualTo(4));
    expect(moon.layout.roads.every((r) => r.sealed), isTrue,
        reason: 'a crossing must not unseal what it cuts');
  });

  test('the seal reaches the renderer', () {
    final moon = on('moon')
      ..commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    final snap = WorldSnapshot.capture(
      1,
      InMemoryVesselRepository(const []),
      system: SampleWorld.realSystem(),
      cities: InMemoryCityRepository([moon]),
    );
    expect(snap.roads, isNotEmpty);
    expect(snap.roads.every((r) => r.sealed), isTrue,
        reason: 'a flag the mesher never sees builds no tube');
  });

  test('the seal survives a save', () {
    final moon = on('moon')
      ..commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    final back = CitySim.fromJson(
      moon.toJson(),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
    );
    expect(back.layout.roads, isNotEmpty);
    expect(back.layout.roads.every((r) => r.sealed), isTrue);
  });
}
