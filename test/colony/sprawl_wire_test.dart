// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
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

  WorldSnapshot capture() => WorldSnapshot.capture(
      1, InMemoryVesselRepository(const []),
      system: system, cities: InMemoryCityRepository([city]));

  test('a generated colony carries a sprawl spec sized from the outline', () {
    final spec = city.sprawlSpec;
    expect(spec, isNotNull);
    expect(spec!.milesAcross, closeTo(6, 1e-9));
    expect(spec.coreRadiusM, greaterThan(200));
    expect(city.sprawl, isNotNull);
    expect(city.sprawl!.sections, isNotEmpty);
    // Same object back: zoned once and cached.
    expect(identical(city.sprawl, city.sprawl), isTrue);
  });

  test('the sprawl rides the wire as the colony\'s own roads and buildings',
      () {
    final snap = capture();
    // No second list: the expressways are roads like any other, with
    // their bridges and tapers.
    final expressways = snap.roads.where((r) =>
        RoadClass.values[r.roadClassIndex].isExpressway).toList();
    expect(expressways, isNotEmpty);
    expect(expressways.any((r) => r.bridges.isNotEmpty), isTrue);
    expect(expressways.any((r) => r.endHalfWidthM != null), isTrue);
    expect(snap.roads.any((r) => r.collector), isTrue);
    expect(snap.roads.any((r) => RoadClass.values[r.roadClassIndex] == RoadClass.ramp),
        isTrue);
    // The suburbs' houses are buildings of the frame.
    expect(snap.buildings.length, greaterThan(1000));
  });

  test('bridges, tapers and the collector flag survive the wire', () {
    final snap = capture();
    final back = WorldSnapshot.fromJson(
        jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>);
    expect(back.roads.length, snap.roads.length);
    final bridged = snap.roads.indexWhere((r) => r.bridges.isNotEmpty);
    expect(bridged, greaterThanOrEqualTo(0));
    expect(back.roads[bridged].bridges, snap.roads[bridged].bridges);
    final tapered = snap.roads.indexWhere((r) => r.endHalfWidthM != null);
    expect(back.roads[tapered].endHalfWidthM, snap.roads[tapered].endHalfWidthM);
    expect(back.roads.where((r) => r.collector).length,
        snap.roads.where((r) => r.collector).length);
    expect(back.copyWithEpoch(5).roads.length, snap.roads.length);
  });

  test('the spec survives the colony save', () {
    final back = CitySim.fromJson(
        jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
        bodies: bodies);
    expect(back.sprawlSpec, city.sprawlSpec);
    expect(back.layout.roads.length, city.layout.roads.length);
  });
}
