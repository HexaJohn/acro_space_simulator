// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// A colony you have just zoned holds no BUILDINGS — zones grow into those
/// over time — so a frame carrying only buildings rendered a fresh city as
/// empty ground. From the cockpit that reads as a broken editor.
void main() {
  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'patchy',
      );

  WorldSnapshot capture(CitySim city) => WorldSnapshot.capture(
        0,
        InMemoryVesselRepository(const []),
        system: SampleWorld.realSystem(),
        cities: InMemoryCityRepository([city]),
      );

  test('a zoned but unbuilt lot still reaches the frame', () {
    final city = colony();
    city.zones[city.hubKey + 1] =
        const CityZoneType('residential', Density.low);
    city.zones[city.hubKey + 2] =
        const CityZoneType('industrial', Density.high);

    final patches = capture(city).patches;
    final kinds = patches.map((p) => p.kind).toSet();
    expect(kinds, contains(CityPatchSnapshot.kindResidential));
    expect(kinds, contains(CityPatchSnapshot.kindIndustrial));
    for (final p in patches) {
      expect(p.sizeM, CitySim.cellM);
      expect(p.colonyId, 'patchy');
    }
  });

  test('roads laid with the in-flight tool reach the frame', () {
    final city = colony();
    city.addRoad(city.hubKey + 1);
    city.addRoad(city.hubKey + 2);

    final roads = capture(city)
        .patches
        .where((p) => p.kind == CityPatchSnapshot.kindRoad)
        .toList();
    // The founding hub is a road too, so at least the three.
    expect(roads.length, greaterThanOrEqualTo(3));
    final earth = SampleWorld.realSystem().body(city.body.id)!;
    for (final p in roads) {
      final r = _len(p.px, p.py, p.pz);
      expect(r, closeTo(earth.radius, earth.radius * 0.001));
    }
  });

  test('a grown lot is a building, not a patch — never both', () {
    final city = colony();
    final cell = city.hubKey + 1;
    city.zones[cell] = const CityZoneType('residential', Density.low);
    city.grown.add(cell);

    final snap = capture(city);
    expect(
      snap.patches.where((p) =>
          p.kind == CityPatchSnapshot.kindResidential &&
          _len(p.px, p.py, p.pz) > 0),
      isEmpty,
      reason: 'drawing both would z-fight the building against its own lot',
    );
    expect(snap.buildings, isNotEmpty);
  });

  test('a colony with patches but no buildings is a valid frame', () {
    // The case that crashed the whole scene build: zone a colony, build
    // nothing. Every consumer that reaches for "the first building" has to
    // cope, because there is not one.
    final city = colony();
    city.zones[city.hubKey + 1] =
        const CityZoneType('residential', Density.low);
    final snap = capture(city);

    expect(snap.buildings, isEmpty);
    expect(snap.patches, isNotEmpty);
    // Grouped by body the way the renderer groups them, the building list for
    // that body is EMPTY while the colony is plainly present.
    final byBody = <String, List<BuildingSnapshot>>{};
    for (final b in snap.buildings.values) {
      byBody.putIfAbsent(b.body, () => []).add(b);
    }
    for (final p in snap.patches) {
      byBody.putIfAbsent(p.body, () => []);
    }
    expect(byBody['earth'], isEmpty);
    expect(() => byBody['earth']!.first, throwsStateError,
        reason: 'this is the shape that took the frame down');
  });

  test('patches survive the wire', () {
    final city = colony()..addRoad(0);
    final snap = capture(city);
    final back = WorldSnapshot.fromJson(snap.toJson());
    expect(back.patches.length, snap.patches.length);
    expect(back.patches.first.kind, snap.patches.first.kind);
    expect(back.patches.first.sizeM, snap.patches.first.sizeM);
  });
}

double _len(double x, double y, double z) =>
    (x * x + y * y + z * z) <= 0 ? 0 : math.sqrt(x * x + y * y + z * z);
