// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The terrain shaper and the road tool: a road on the ground is graded to
/// the ground, keyed by its width so an upgrade re-grades it; a raised or
/// sunk road is graded to its DECK where it runs near the ground, and the
/// ground is left alone under its piers and over its tunnel.
library;

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  CitySim colony() => CitySim.found(
        const CityConfig(
            bodyId: 'earth', gridSize: 20, latitude: 0, longitude: 0),
        bodies: bodies,
        id: 'c',
        name: 'c',
      );
  const shaper = CityTerrainShaper();

  /// The road brushes pending on a flat site AT the datum.
  List<({String key, TerrainBrush brush})> roadBrushes(CitySim city) {
    final r = city.body.radius;
    return [
      for (final p
          in shaper.pending(city, bodyRadiusM: r, groundRadiusAt: (_) => r))
        if (p.key.startsWith('road:')) p,
    ];
  }

  test('a road on the ground is keyed by its width, so an upgrade re-grades',
      () {
    final city = colony()..funds = 1e6;
    city.commitRoad(const [Vec2(0, 0), Vec2(240, 0)], RoadClass.street);
    final first = roadBrushes(city);
    expect(first, hasLength(10), reason: '240 m in 24 m segments');
    expect(first.every((p) => p.key.startsWith('road:r0:4.00:')), isTrue);
    for (final p in first) {
      city.shapedTerrain.add(p.key);
    }
    expect(roadBrushes(city), isEmpty, reason: 'each segment once');
    city.upgradeRoad('r0', RoadType.byId('four-lane')!);
    final wider = roadBrushes(city);
    expect(wider, hasLength(10));
    expect(wider.every((p) => p.key.startsWith('road:r0:8.00:')), isTrue);
    expect(wider.first.brush.radiusM, 8);
  });

  test('a tunnel leaves the ground alone, and is never asked about again',
      () {
    final city = colony();
    city.commitRoad(const [Vec2(0, 0), Vec2(240, 0)], RoadClass.street,
        deck: const RoadDeck(
            startM: -12,
            endM: -12,
            startOffsetM: -12,
            endOffsetM: -12,
            tunnels: [(0, 240)]));
    expect(roadBrushes(city), isEmpty,
        reason: 'a cut-and-fill over a tunnel is a trench to the sky');
    expect(city.shapedTerrain.where((k) => k.startsWith('road:r0:')),
        hasLength(10));
    expect(roadBrushes(city), isEmpty);
  });

  test('a raised road is graded to its deck on the ground, not under piers',
      () {
    final city = colony();
    final r = city.body.radius;
    // 0 m to 12 m over 480 m, on piers from 100 m along.
    const deck = RoadDeck(
        startM: 0, endM: 12, endOffsetM: 12, structures: [(100, 480)]);
    city.commitRoad(const [Vec2(0, 0), Vec2(480, 0)], RoadClass.street,
        deck: deck);
    final brushes = roadBrushes(city);
    // The 24 m segments whose midpoints (12, 36, 60, 84) fall short of the
    // piers.
    expect(brushes.map((p) => p.key), [
      'road:r0:4.00:1',
      'road:r0:4.00:2',
      'road:r0:4.00:3',
      'road:r0:4.00:4',
    ]);
    for (var i = 0; i < brushes.length; i++) {
      final b = brushes[i].brush;
      expect(b.datumRadiusM, closeTo(r + deck.heightAt(24.0 * i, 480), 1e-6));
      expect(b.datumRadiusEndM,
          closeTo(r + deck.heightAt(24.0 * (i + 1), 480), 1e-6));
      expect(b.depthM, greaterThanOrEqualTo(40),
          reason: 'the bound reaches past the fill');
      expect(b.falloffM, greaterThanOrEqualTo(shaper.roadFalloffM));
    }
    // The sixteen on piers are settled with no brush.
    expect(city.shapedTerrain.where((k) => k.startsWith('road:r0:')),
        hasLength(16));
  });
}
