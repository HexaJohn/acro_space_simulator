// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_build.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart'
    show Biome;
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// A colony road is drawn at the radii the frame drapes it at, and the
/// ground is drawn from the brushes the shaper graded it with: the two must
/// be one surface, or the road is drawn in and out of its own cutting.
///
/// The live case: on the dev colony's site (the starter kit, earth, as
/// `main_city_game_dev` founds it) a 48 m one-way road, reversed, its end
/// dragged in Adjust Roads into the pump's levelled field — re-laid 64.5 m
/// long, no deck. The frame drew it as three tilted slabs, half buried,
/// street lamps standing on bare ground between them: the drape sampled
/// every fourth 6 m point and drew straight lines between, where the
/// shaper had graded the road in segments of 21.5 m across the lot's edge.
void main() {
  setUpAll(registerBakedDemsForTest);

  final system = SampleWorld.realSystem();
  final earth = system.body(const BodyId('earth'))!;
  const shaper = CityTerrainShaper();

  ({CitySim city, InMemoryTerrainEditsRepository edits}) devColony() {
    final city = CityStarterKit.found(
      bodies: system.all.where((b) => !b.isStar).toList(),
      config: const CityConfig(
          bodyId: 'earth',
          latitude: -45.03,
          longitude: 168.66,
          biome: Biome.forest),
      id: 'city-dev',
    )..funds = 1e6;
    return (city: city, edits: InMemoryTerrainEditsRepository());
  }

  double groundRadius(InMemoryTerrainEditsRepository edits, Vector3 dir) {
    final f = earth.terrainFieldWith(edits.forBody(earth.id));
    return f == null ? earth.radius : f.groundRadiusAt(dir.x, dir.y, dir.z);
  }

  /// What the world tick does after the colony advances
  /// (`AdvanceSimulationTick._shapeCityTerrain`).
  void shape(CitySim city, InMemoryTerrainEditsRepository edits) {
    for (final p in shaper.pending(city,
        bodyRadiusM: earth.radius,
        groundRadiusAt: (d) => groundRadius(edits, d))) {
      edits.record(earth.id, p.brush);
      city.shapedTerrain.add(p.key);
    }
  }

  RoadSnapshot drawn(CitySim city, InMemoryTerrainEditsRepository edits,
          String id) =>
      WorldSnapshot.capture(1, InMemoryVesselRepository(const []),
              system: system,
              cities: InMemoryCityRepository([city]),
              terrainEdits: edits)
          .roads
          .singleWhere((r) => r.id == id);

  List<Vector3> pointsOf(RoadSnapshot r) => [
        for (var k = 0; k + 2 < r.points.length; k += 3)
          Vector3(r.points[k], r.points[k + 1], r.points[k + 2]),
      ];

  /// How far each point of [r] is drawn off the ground, in metres: its
  /// drape plus its lift, less the ground radius under it.
  List<double> offGround(RoadSnapshot r, InMemoryTerrainEditsRepository e) {
    final pts = pointsOf(r);
    return [
      for (var k = 0; k < pts.length; k++)
        pts[k].length +
            (r.lifts.isEmpty ? 0.0 : r.lifts[k]) -
            groundRadius(e, pts[k].normalized),
    ];
  }

  String fmt(List<double> xs) => xs.map((x) => x.toStringAsFixed(2)).join(', ');

  const tolM = 0.05;

  test('a one-way re-laid in Adjust is drawn on the ground it was graded to, '
      'at every point — the frame it is laid and after its corridor is cut',
      () {
    final c = devColony();
    shape(c.city, c.edits);
    double ground(Vec2 p) =>
        groundRadius(
            c.edits,
            c.city
                .localToBodyFixed(p, bodyRadiusM: earth.radius)
                .normalized) -
        earth.radius;

    // The road as the player drew it (the live run's two clicks).
    const from = Vec2(-40.53494707193965, 35.79178164252065);
    const to = Vec2(-59.22824161951971, 80.00219601467299);
    final built = c.city.buildRoad(
        RoadBuildRequest(
            controls: const [from, to], type: RoadType.byId('one-way')!),
        groundAt: ground);
    expect(built.quote.ok, isTrue, reason: built.quote.reason);
    final id = built.roadId!;
    shape(c.city, c.edits);
    final first = offGround(drawn(c.city, c.edits, id), c.edits);
    expect(first.every((d) => d.abs() < tolM), isTrue,
        reason: 'the 48 m road as built is graded every 16 m, not 24 '
            '(its length is a hair over 48): off by [${fmt(first)}] m');

    // Reversed, then its end dragged into the pump's levelled field.
    expect(c.city.reverseRoad(id), isTrue);
    const drop = Vec2(-89.63, 77.65);
    final moved =
        c.city.moveRoadEnd(id, atStart: false, to: drop, groundAt: ground);
    expect(moved.quote.ok, isTrue, reason: moved.quote.reason);
    // What the live run's reply said of it: on the ground, no structure.
    expect(moved.quote.deck, isNull);
    expect(moved.quote.structureM + moved.quote.tunnelM, 0);
    final relaid = moved.roadId!;
    final road = c.city.layout.roadById(relaid)!;
    expect(road.reversed, isTrue);
    expect(road.graded, isTrue);
    final lengthM = road.length(stepM: 1);
    expect(lengthM, closeTo(64.5, 0.5));
    expect((lengthM / CityTerrainShaper.corridorStepM) % 1, isNot(closeTo(0, 0.05)),
        reason: 'not a whole number of corridor steps: the knots fall '
            'between the drawn points');

    // The frame it is laid, before the tick cuts its corridor: drawn where
    // the corridor will be, not over the lot edge's cliff it is about to
    // cut through.
    final before = pointsOf(drawn(c.city, c.edits, relaid))
        .map((p) => p.length)
        .toList();
    shape(c.city, c.edits);
    final after = drawn(c.city, c.edits, relaid);
    final off = offGround(after, c.edits);
    expect(off.every((d) => d.abs() < tolM), isTrue,
        reason: 'drawn off its graded ground by [${fmt(off)}] m');
    final pts = pointsOf(after);
    final ahead = [
      for (var k = 0; k < pts.length; k++)
        before[k] - groundRadius(c.edits, pts[k].normalized),
    ];
    expect(ahead.every((d) => d.abs() < tolM), isTrue,
        reason: 'before its corridor was cut it was drawn '
            '[${fmt(ahead)}] m off the ground it was then graded to');

    // What makes this a test at all: the graded ground under the road is
    // not one straight grade — it bends by metres where it crosses the
    // field's edge, which is what a straight line between two points
    // 23.5 m apart missed.
    final r = [for (final p in pts) groundRadius(c.edits, p.normalized)];
    var bend = 0.0;
    for (var k = 1; k < r.length - 1; k++) {
      final line = r.first + (r.last - r.first) * k / (r.length - 1);
      bend = math.max(bend, (r[k] - line).abs());
    }
    expect(bend, greaterThan(1.0),
        reason: 'the site must bend the road\'s grade to prove anything');
  });

  test('ground laid outside the shaper moves the drape with it', () {
    final c = devColony();
    shape(c.city, c.edits);
    // The far end of a starter street, and the frame's height there.
    final end = drawn(c.city, c.edits, 'r0x0');
    final dir = pointsOf(end).first.normalized;
    expect(offGround(end, c.edits).first.abs(), lessThan(tolM));

    // A crater there — an impact, not the shaper: nothing it has shaped
    // changes, but the ground does.
    final at = dir * groundRadius(c.edits, dir);
    c.edits.record(
        earth.id,
        TerrainBrush.crater(
            contactBF: at, normalBF: dir, radiusM: 14, depthM: 4));
    expect(groundRadius(c.edits, dir), lessThan(at.length - 2),
        reason: 'the crater really is under the road\'s end');

    final off = offGround(drawn(c.city, c.edits, 'r0x0'), c.edits).first;
    expect(off.abs(), lessThan(tolM),
        reason: 'the road\'s end is drawn ${off.toStringAsFixed(2)} m off '
            'the ground the crater left');
  });
}
