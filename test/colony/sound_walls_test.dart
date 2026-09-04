// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The walled variant of a highway: a road ATTRIBUTE, not a class of its
/// own, so a highway can be walled for a stretch and open for the next.
void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: bodies,
        id: 'walls',
      );

  test('only a highway can be walled', () {
    for (final c in RoadClass.values) {
      expect(c.canHaveSoundWalls,
          c.isExpressway || c == RoadClass.highway,
          reason: c.name);
    }
  });

  test('the flag survives the splits a commit makes, and a ramp cannot '
      'take it', () {
    final city = colony();
    city.commitRoad(const [Vec2(-400, 0), Vec2(400, 0)], RoadClass.expressway6,
        soundWalls: true);
    // A ramp meets an expressway at grade and cuts it (a street would pass
    // under a bridge and cut nothing).
    city.commitRoad(const [Vec2(0, -300), Vec2(0, 300)], RoadClass.ramp,
        soundWalls: true);
    final walled = city.layout.roads.where((r) => r.soundWalls).toList();
    expect(walled, isNotEmpty);
    expect(walled.every((r) => r.roadClass == RoadClass.expressway6), isTrue);
    // Both pieces of the expressway either side of the crossing keep it.
    expect(walled.length, greaterThanOrEqualTo(2));
    expect(city.layout.roads.where((r) => r.roadClass == RoadClass.ramp)
        .every((r) => !r.soundWalls), isTrue);
  });

  test('it survives a save and reaches the frame', () {
    final city = colony();
    city.commitRoad(const [Vec2(-400, 0), Vec2(400, 0)], RoadClass.expressway4,
        soundWalls: true);
    city.commitRoad(const [Vec2(-400, 200), Vec2(400, 200)], RoadClass.expressway4);
    final back = CitySim.fromJson(
        jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
        bodies: bodies);
    expect(back.layout.roads.where((r) => r.soundWalls).length, 1);
    expect(back.layout.roads.where((r) => !r.soundWalls).length, 1);
    final snap = WorldSnapshot.capture(0, InMemoryVesselRepository(const []),
        system: SampleWorld.realSystem(),
        cities: InMemoryCityRepository([city]));
    expect(snap.roads.where((r) => r.soundWalls).length, 1);
    final wire = WorldSnapshot.fromJson(snap.toJson());
    expect(wire.roads.where((r) => r.soundWalls).length, 1);
  });

  test('the generator walls an expressway where it runs past housing, and '
      'nowhere else', () {
    final city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 2, seed: 9, sprawlMiles: 8),
        bodies: bodies);
    final plan = city.sprawl!;
    SprawlSection? sectionAt(Vec2 p) {
      for (final s in plan.sections) {
        if ((p.e - s.centre.e).abs() <= s.halfM && (p.n - s.centre.n).abs() <= s.halfM) {
          return s;
        }
      }
      return null;
    }

    var walled = 0, open = 0;
    for (final r in city.layout.roads) {
      if (!r.roadClass.canHaveSoundWalls) {
        expect(r.soundWalls, isFalse, reason: r.id);
        continue;
      }
      if (!r.roadClass.isExpressway) continue;
      // The middle of the piece by its samples, which is what the
      // generator judges by.
      final rec = city.layout.roadIndex.byId(r.id)!;
      final mid = rec.sampleAt(rec.sampleCount ~/ 2);
      final s = sectionAt(mid);
      final housing = s != null && s.use == SprawlUse.residential && s.density >= 0.4;
      if (r.soundWalls) {
        walled++;
        expect(housing, isTrue, reason: '${r.id} walled past ${s?.use.name}');
      } else {
        open++;
      }
    }
    expect(walled, greaterThan(0));
    expect(open, greaterThan(0));
  });
}
