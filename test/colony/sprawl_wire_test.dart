// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final system = RealSolarSystem.build();
  final bodies = system.all.where((b) => !b.isStar).toList();

  late CitySim city;
  setUpAll(() {
    city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 2, seed: 9, sprawlMiles: 6),
        bodies: bodies);
  });

  test('a generated colony carries a sprawl spec sized from the outline', () {
    final spec = city.sprawlSpec;
    expect(spec, isNotNull);
    expect(spec!.milesAcross, closeTo(6, 1e-9));
    expect(spec.coreRadiusM, greaterThan(200));
    expect(city.sprawl, isNotNull);
    expect(city.sprawl!.sections, isNotEmpty);
    // Same object back: grown once and cached.
    expect(identical(city.sprawl, city.sprawl), isTrue);
  });

  test('the sprawl reaches the wire draped, and drapes only once', () {
    WorldSnapshot capture() => WorldSnapshot.capture(
        1, InMemoryVesselRepository(const []),
        system: system, cities: InMemoryCityRepository([city]));
    final a = capture();
    // The plan's roads, plus the plat's own rights-of-way as corridors.
    expect(a.sprawlRoads.length, greaterThanOrEqualTo(city.sprawl!.roads.length));
    // Every road point sits at a real radius of the body — draped, not on
    // the datum sphere — and stays within a few hundred metres of it.
    final body = system.body(city.body.id)!;
    var lifted = 0;
    for (final r in a.sprawlRoads) {
      for (var i = 0; i + 2 < r.points.length; i += 3) {
        final radius = math.sqrt(r.points[i] * r.points[i] +
            r.points[i + 1] * r.points[i + 1] +
            r.points[i + 2] * r.points[i + 2]);
        expect((radius - body.radius).abs(), lessThan(9000));
        if ((radius - body.radius).abs() > 0.5) lifted++;
      }
    }
    expect(lifted, greaterThan(0), reason: 'the drape sampled no ground');
    // Interstates keep their bridges.
    final interstates = a.sprawlRoads
        .where((r) => r.kind == SprawlRoadKind.interstate.index)
        .toList();
    expect(interstates, isNotEmpty);
    expect(interstates.any((r) => r.overpasses.isNotEmpty), isTrue);
    // A second capture reuses the drape rather than sampling again.
    final b = capture();
    expect(identical(a.sprawlRoads.first, b.sprawlRoads.first), isTrue);
  });

  test('the plat\'s rights-of-way ride the wire as corridors', () {
    final snap = WorldSnapshot.capture(
        1, InMemoryVesselRepository(const []),
        system: system, cities: InMemoryCityRepository([city]));
    final corridors = snap.sprawlRoads
        .where((r) => r.kind == SprawlRoadKind.corridor.index)
        .toList();
    expect(corridors, isNotEmpty, reason: 'the arteries and the expressway');
  });

  test('the sections are plat: their streets ride the wire as roads', () {
    final snap = WorldSnapshot.capture(
        1, InMemoryVesselRepository(const []),
        system: system, cities: InMemoryCityRepository([city]));
    final collectors = snap.roads.where((r) => r.collector).toList();
    expect(collectors, isNotEmpty);
    final back = WorldSnapshot.fromJson(
        jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>);
    expect(back.roads.where((r) => r.collector).length, collectors.length);
    expect(back.sprawlRoads.length, snap.sprawlRoads.length);
    expect(back.sprawlRoads.first.overpasses, snap.sprawlRoads.first.overpasses);
    expect(back.copyWithEpoch(5).sprawlRoads.length, snap.sprawlRoads.length);
  });

  test('the spec survives the colony save', () {
    final back = CitySim.fromJson(
        jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
        bodies: bodies);
    expect(back.sprawlSpec, city.sprawlSpec);
  });
}
