// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Buildings are generated from primitives and sized to their FUNCTION and the
/// land they were given — the same spec on a narrow lot and an open plot must
/// come out as different buildings.
void main() {
  const rules = BuildingMassingRules();
  const gen = BuildingGenerator();

  Parcel lot({required double width, required double depth}) => Parcel(
        id: 'lot',
        polygon: [
          Vec2(-width / 2, 0),
          Vec2(width / 2, 0),
          Vec2(width / 2, depth),
          Vec2(-width / 2, depth),
        ],
        frontage: (Vec2(-width / 2, 0), Vec2(width / 2, 0)),
      );

  CityBuildingSpec spec(String label) =>
      kUtilCatalog.firstWhere((s) => s.label == label);

  CityBuildingSpec zone(String kind, Density d) => kZoneSpecs[kind]![d]!;

  test('the same building goes tall on a narrow lot, low on a wide one', () {
    // A hospital, not a shed: industrial specs deliberately stay low-rise.
    final tower = spec('Hospital');
    final narrow = rules.massFor(tower, lot(width: 30, depth: 40));
    final wide = rules.massFor(tower, lot(width: 400, depth: 400));

    expect(narrow.height, greaterThan(wide.height));
    expect(wide.footprint.width, greaterThan(narrow.footprint.width));
    // Both still house the function they were sized for.
    for (final m in [narrow, wide]) {
      expect(m.floorArea, greaterThanOrEqualTo(rules.requiredArea(tower) * 0.85));
    }
  });

  test('a tall building steps back above its podium', () {
    final m = rules.massFor(zone('residential', Density.high),
        lot(width: 40, depth: 40));
    expect(m.volumes.length, greaterThan(1), reason: 'podium + tower expected');
    final podium = m.volumes.first;
    final tower = m.volumes[1];
    expect(tower.z, closeTo(podium.top, 1e-6));
    expect(tower.width, lessThan(podium.width));
  });

  test('parking is sized from demand and sits between building and street', () {
    final mall = spec('Data Center');
    final m = rules.massFor(mall, lot(width: 120, depth: 160));
    final lotArea = m.parking!;

    expect(lotArea.spaces, rules.parkingSpaces(mall));
    expect(lotArea.area,
        greaterThan(lotArea.spaces * rules.parkingSpaceM2 * 0.5));
    // The car park is on the street side (lower y) of the building.
    final building = m.volumes.first;
    expect(lotArea.y, lessThan(building.y));
    expect(lotArea.lampPosts, isNotEmpty);
  });

  test('a building with no staff or visitors gets no car park', () {
    final store = spec('Warehouse');
    final m = rules.massFor(store, lot(width: 40, depth: 40));
    expect(m.parking?.spaces ?? 0, 0);
    expect(m.parking, isNull);
  });

  test('generated geometry has walls, glazing and an interior', () {
    final b = gen.generate(zone('commercial', Density.high), lot(width: 60, depth: 60));

    expect(b.model.solid.triangleCount, greaterThan(0));
    expect(b.model.foliage.triangleCount, greaterThan(0),
        reason: 'window bands ride the alpha-masked channel');
    expect(b.windowCentres, isNotEmpty);

    // Interiors: dropping to the exterior tier must remove triangles.
    final shell = gen.generate(zone('commercial', Density.high),
        lot(width: 60, depth: 60), detail: BuildingDetail.exterior);
    expect(shell.model.solid.triangleCount,
        lessThan(b.model.solid.triangleCount));

    // And the distant tier is a silhouette only.
    final block = gen.generate(zone('commercial', Density.high),
        lot(width: 60, depth: 60), detail: BuildingDetail.block);
    expect(block.model.solid.triangleCount,
        lessThan(shell.model.solid.triangleCount));
    expect(block.model.foliage.triangleCount, 0);
  });

  test('geometry stands on the ground and within its lot', () {
    final b = gen.generate(zone('residential', Density.medium),
        lot(width: 50, depth: 60));
    final bounds = b.model.bounds;
    expect(bounds.min.z, greaterThanOrEqualTo(-0.01),
        reason: 'origin is the base — a building must not sink into its pad');
    expect(bounds.max.z, closeTo(b.massing.height, 0.01));
    // Nothing may hang over the property line.
    expect(bounds.min.x, greaterThanOrEqualTo(-25.01));
    expect(bounds.max.x, lessThanOrEqualTo(25.01));
  });

  test('a district of ten thousand buildings shares a few hundred meshes', () {
    final library = BuildingLibrary();
    final specs = [
      zone('residential', Density.low),
      zone('residential', Density.medium),
      zone('residential', Density.high),
      zone('commercial', Density.low),
      zone('industrial', Density.medium),
    ];

    for (var i = 0; i < 10000; i++) {
      // Lot sizes vary continuously, as parcels from a curving road do.
      final w = 18 + (i % 37) * 1.3;
      final d = 26 + (i % 23) * 1.7;
      library.get(specs[i % specs.length], lot(width: w, depth: d), seed: i);
    }

    final meshes = library.meshCount;
    expect(meshes, lessThan(2000),
        reason: 'archetype bucketing must collapse near-identical buildings');
    expect(meshes, greaterThan(20),
        reason: 'but not so coarse that every street looks cloned');

    // The real instancing guarantee: mesh count tracks how many distinct SHAPES
    // a city contains, not how many buildings. Another ten thousand over the
    // same range of lots is essentially free — it can only fill in bucket
    // combinations the first pass happened to miss, and is bounded by the
    // bucket space itself (9 width x 8 depth x 5 types x 4 variants).
    for (var i = 10000; i < 20000; i++) {
      final w = 18 + (i % 37) * 1.3;
      final d = 26 + (i % 23) * 1.7;
      library.get(specs[i % specs.length], lot(width: w, depth: d), seed: i);
    }
    expect(library.meshCount, lessThanOrEqualTo(9 * 8 * 5 * 4));
    expect(library.meshCount - meshes, lessThan(meshes ~/ 20));
  });

  test('the same archetype is served from cache, not regenerated', () {
    final library = BuildingLibrary();
    final s = zone('residential', Density.low);
    final a = library.get(s, lot(width: 24, depth: 30), seed: 1);
    final b = library.get(s, lot(width: 24, depth: 30), seed: 1);
    expect(identical(a, b), isTrue);
    expect(library.meshCount, 1);
  });

  test('an industrial shed is wide and tall-storeyed, not an office block', () {
    final shed = rules.massFor(spec('Steel Mill'), lot(width: 120, depth: 140));
    final office = rules.massFor(zone('commercial', Density.high),
        lot(width: 120, depth: 140));

    expect(shed.storeyM, greaterThan(office.storeyM));
    expect(shed.floors, lessThanOrEqualTo(2));
    // The shed covers far more of its plot than the office does.
    expect(shed.footprint.width, greaterThan(office.footprint.width));
  });
}
