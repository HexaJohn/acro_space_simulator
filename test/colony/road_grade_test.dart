// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Roads have grade limits, and they are what make mountains cost something:
/// the highway has to go around, the dirt path can go over.
void main() {
  // A synthetic hillside: ground rises 1 m for every 10 m north. 10% grade.
  double hillside(Vec2 p) => 600000 + p.n * 0.1;

  // And a cliff: 30% northward.
  double cliff(Vec2 p) => 600000 + p.n * 0.3;

  List<Vec2> northRun() => const [Vec2(0, 0), Vec2(0, 200)];

  RoadGradeCheck check(double Function(Vec2) ground, RoadClass cls) =>
      RoadGradeCheck.of(
        RoadSpline(id: 't', controls: northRun(), roadClass: cls)
            .sample(stepM: 12),
        ground,
        cls,
      );

  test('grades are measured, and measured over the run', () {
    final flat = check((p) => 600000, RoadClass.street);
    expect(flat.maxPct, closeTo(0, 0.01));
    expect(flat.ok, isTrue);

    final hill = check(hillside, RoadClass.street);
    expect(hill.maxPct, closeTo(10, 0.5));
  });

  test('each tier draws its own line', () {
    // 10%: a street takes it, an avenue and a highway refuse.
    expect(check(hillside, RoadClass.street).ok, isTrue); // limit 12
    expect(check(hillside, RoadClass.avenue).ok, isFalse); // limit 8
    expect(check(hillside, RoadClass.highway).ok, isFalse); // limit 5

    // 30%: only the dirt path is honest about climbing it... and even it
    // refuses past 20.
    expect(check(cliff, RoadClass.path).ok, isFalse);
    expect(check((p) => 600000 + p.n * 0.18, RoadClass.path).ok, isTrue);
  });

  test('a contour road across the hillside is fine at any tier', () {
    // Running EAST across the same hillside: no climb at all.
    final samples = RoadSpline(
            id: 't',
            controls: const [Vec2(0, 0), Vec2(200, 0)],
            roadClass: RoadClass.highway)
        .sample(stepM: 12);
    final c = RoadGradeCheck.of(samples, hillside, RoadClass.highway);
    expect(c.maxPct, closeTo(0, 0.01));
    expect(c.ok, isTrue);
  });

  test('a too-steep commit is refused and commits nothing', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'steep',
    );
    final id = city.commitRoad(northRun(), RoadClass.highway,
        groundAt: hillside);
    expect(id, isNull);
    expect(city.layout.roads, isEmpty,
        reason: 'refusal must not leave a half-committed road');

    // The same route as a street goes through.
    final ok = city.commitRoad(northRun(), RoadClass.street,
        groundAt: hillside);
    expect(ok, isNotNull);
    expect(city.layout.roads, hasLength(1));
  });

  test('with no ground function the commit is ungated (headless callers)', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'nogate',
    );
    expect(city.commitRoad(northRun(), RoadClass.highway), isNotNull);
  });
}
