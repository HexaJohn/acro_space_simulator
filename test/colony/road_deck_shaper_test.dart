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

  /// A cut-and-fill corridor's length, end to end (its centre is its
  /// midpoint).
  double lengthOf(TerrainBrush b) => (b.endBF! - b.centreBF).length * 2;

  test('a road on the ground is keyed by its width, so an upgrade re-grades',
      () {
    final city = colony()..funds = 1e6;
    city.commitRoad(const [Vec2(0, 0), Vec2(240, 0)], RoadClass.street);
    final first = roadBrushes(city);
    expect(first, hasLength(10), reason: '240 m in 24 m segments');
    expect(first.every((p) => p.key.startsWith('road:r0:4.00:')), isTrue);
    for (final p in first) {
      CityTerrainShaper.markShaped(city, p.key, p.brush);
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
    // The four 24 m segments short of the piers, and the fifth (96-120 m)
    // up to where they start: judged by its midpoint (108 m, on the piers)
    // it went unfilled, a slab floating 4 m short of its first pier.
    expect(brushes.map((p) => p.key), [
      'road:r0:4.00:1',
      'road:r0:4.00:2',
      'road:r0:4.00:3',
      'road:r0:4.00:4',
      'road:r0:4.00:5',
    ]);
    for (var i = 0; i < brushes.length; i++) {
      final b = brushes[i].brush;
      final s0 = 24.0 * i, s1 = i == 4 ? 100.0 : 24.0 * (i + 1);
      expect(b.datumRadiusM, closeTo(r + deck.heightAt(s0, 480), 1e-6));
      expect(b.datumRadiusEndM, closeTo(r + deck.heightAt(s1, 480), 1e-6));
      expect(lengthOf(b), closeTo(s1 - s0, 0.05),
          reason: 'the brush runs to the first pier, not past it');
      expect(b.depthM, greaterThanOrEqualTo(40),
          reason: 'the bound reaches past the fill');
      expect(b.falloffM, greaterThanOrEqualTo(shaper.roadFalloffM));
    }
    // The fifteen wholly on piers are settled with no brush.
    expect(city.shapedTerrain.where((k) => k.startsWith('road:r0:')),
        hasLength(15));
  });

  test('a segment is clipped at a portal and at a short span, and settled',
      () {
    final city = colony();
    final r = city.body.radius;
    // Out of a tunnel that ends 140 m along: the sixth segment (120-144 m,
    // its midpoint underground) is graded for its last 4 m.
    const sunk = RoadDeck(
        startM: -12, endM: 0, startOffsetM: -12, tunnels: [(0, 140)]);
    city.commitRoad(const [Vec2(0, 0), Vec2(240, 0)], RoadClass.street,
        deck: sunk);
    final out = roadBrushes(city);
    expect(out.map((p) => p.key), [
      for (var i = 6; i <= 10; i++) 'road:r0:4.00:$i',
    ]);
    expect(out.first.brush.datumRadiusM,
        closeTo(r + sunk.heightAt(140, 240), 1e-6),
        reason: 'from the portal, not from over the tunnel');
    expect(lengthOf(out.first.brush), closeTo(4, 0.05));

    // A 10 m span over a ditch inside the fifth segment (96-120 m): graded
    // up to it and on from it, in two pieces.
    const span = RoadDeck(
        startM: 3,
        endM: 3,
        startOffsetM: 3,
        endOffsetM: 3,
        structures: [(100, 110)]);
    city.commitRoad(const [Vec2(0, 300), Vec2(240, 300)], RoadClass.street,
        deck: span);
    final spanned = [
      for (final p in roadBrushes(city))
        if (p.key.startsWith('road:r1:')) p,
    ];
    expect(spanned.map((p) => p.key), [
      for (var i = 1; i <= 4; i++) 'road:r1:4.00:$i',
      'road:r1:4.00:5:0',
      'road:r1:4.00:5:1',
      for (var i = 6; i <= 10; i++) 'road:r1:4.00:$i',
    ]);
    final pieces = spanned.where((p) => p.key.startsWith('road:r1:4.00:5:'));
    expect([for (final p in pieces) lengthOf(p.brush).roundToDouble()],
        [4, 10]);

    // Recorded as the callers record them, nothing is graded twice.
    for (final p in roadBrushes(city)) {
      CityTerrainShaper.markShaped(city, p.key, p.brush);
    }
    expect(roadBrushes(city), isEmpty);
    expect(city.shapedTerrain, contains('road:r1:4.00:5'));
  });

  test("a suburb's draped street raised onto a deck is graded to it", () {
    final city = colony();
    // Adjust Roads keeps `graded`: a generated street, draped on the land,
    // dragged up onto a deck.
    city.commitRoad(const [Vec2(0, 0), Vec2(480, 0)], RoadClass.street,
        graded: false,
        deck: const RoadDeck(
            startM: 0, endM: 12, endOffsetM: 12, structures: [(100, 480)]));
    expect(roadBrushes(city).map((p) => p.key), [
      'road:r0:4.00:1',
      'road:r0:4.00:2',
      'road:r0:4.00:3',
      'road:r0:4.00:4',
      'road:r0:4.00:5',
    ]);
    // A draped street on the ground is still left to follow the land.
    city.commitRoad(const [Vec2(0, 300), Vec2(480, 300)], RoadClass.street,
        graded: false);
    expect(roadBrushes(city).where((p) => p.key.startsWith('road:r1:')),
        isEmpty);
  });
}
