// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Crossings are real topology, and the renderer can find them.
///
/// The complaint was that intersections "read as overlapping ribbons" — no
/// plate, no stop bars, nothing to say a driver yields. The topology was never
/// the problem: [CityLayout.addRoad] already splits every road it crosses, so
/// a crossing is a place where several road ENDS meet. These tests pin that
/// property, because the junction rendering derives itself from it — the way
/// street lamps already do — rather than from anything shipped in the frame.
void main() {
  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'junc',
      );

  /// Ends within 8 m of each other, the way the renderer clusters them.
  int legsAt(CitySim city, Vec2 at) {
    var legs = 0;
    for (final r in city.layout.roads) {
      final pts = r.sample(stepM: 12);
      if (pts.length < 2) continue;
      for (final e in [pts.first, pts.last]) {
        if ((e - at).length <= 8.0) legs++;
      }
    }
    return legs;
  }

  test('a crossing splits both roads, leaving four ends at the middle', () {
    final city = colony();
    city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    city.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
    expect(city.layout.roads.length, greaterThanOrEqualTo(4),
        reason: 'both roads split at the crossing');
    expect(legsAt(city, const Vec2(0, 0)), greaterThanOrEqualTo(3),
        reason: 'the renderer needs 3+ ends to call it a junction');
  });

  test('a T-junction is found too', () {
    final city = colony();
    city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.avenue);
    expect(legsAt(city, const Vec2(0, 0)), greaterThanOrEqualTo(3));
  });

  test('a road bending round a corner is NOT a junction', () {
    // Two ends meeting is a road carrying on, and drawing a plate there would
    // put a stop bar in the middle of an open curve.
    final city = colony();
    city.commitRoad(
        const [Vec2(-200, 0), Vec2(0, 0), Vec2(60, 90)], RoadClass.street);
    for (final r in city.layout.roads) {
      final pts = r.sample(stepM: 12);
      for (final e in [pts.first, pts.last]) {
        expect(legsAt(city, e), lessThan(3),
            reason: 'a bend is not a crossing');
      }
    }
  });

  test('two unrelated roads that never meet make no junction', () {
    final city = colony();
    city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    city.commitRoad(const [Vec2(-200, 400), Vec2(200, 400)], RoadClass.street);
    for (final r in city.layout.roads) {
      final pts = r.sample(stepM: 12);
      for (final e in [pts.first, pts.last]) {
        expect(legsAt(city, e), lessThan(3));
      }
    }
  });
}
