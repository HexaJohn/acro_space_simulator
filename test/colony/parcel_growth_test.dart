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
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// RCI demand grows buildings on zoned LOTS — the piece that makes a parcel
/// colony live rather than a hand-placed diorama.
void main() {
  CitySim withZonedStreet({ParcelUse use = ParcelUse.residential}) {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'grow',
    );
    city.layout.addRoad(const RoadSpline(
        id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
    for (final lot in city.layout.autoParcels) {
      city.layout.setUse(lot.id, use);
    }
    return city;
  }

  test('a served zoned lot under demand grows a building', () {
    final city = withZonedStreet()..resTarget = 1.0;
    for (var i = 0; i < 400; i++) {
      city.advanceParcelGrowth(0.1); // 40 s at full demand
    }
    final lot = city.layout.autoParcels.first;
    final spec = city.parcelGrownSpec(lot.id, lot.use);
    expect(spec, isNotNull);
    expect(spec!.type, 'r-low', reason: 'towers are earned, not instant');
  });

  test('no demand, no growth; demand collapse abandons the block', () {
    final city = withZonedStreet()..resTarget = 0.0;
    for (var i = 0; i < 200; i++) {
      city.advanceParcelGrowth(0.1);
    }
    expect(city.grownParcels, isEmpty);

    // Grow it, then kill demand: the block decays back to bare ground.
    city.resTarget = 1.0;
    for (var i = 0; i < 400; i++) {
      city.advanceParcelGrowth(0.1);
    }
    expect(city.grownParcels, isNotEmpty);
    city.resTarget = 0.0;
    for (var i = 0; i < 800; i++) {
      city.advanceParcelGrowth(0.1);
    }
    expect(city.grownParcels, isEmpty,
        reason: 'a dead district falls down, exactly as the cell one does');
  });

  test('an unserved lot never grows, whatever the demand', () {
    final city = withZonedStreet()..resTarget = 1.0;
    // A second, detached road with its own zoned lots.
    city.layout.addRoad(const RoadSpline(
        id: 'island', controls: [Vec2(3000, 3000), Vec2(3000, 3300)]));
    for (final lot
        in city.layout.autoParcels.where((p) => p.roadId == 'island')) {
      city.layout.setUse(lot.id, ParcelUse.residential);
    }
    for (var i = 0; i < 400; i++) {
      city.advanceParcelGrowth(0.1);
    }
    for (final lot
        in city.layout.autoParcels.where((p) => p.roadId == 'island')) {
      expect(city.parcelGrownSpec(lot.id, lot.use), isNull);
    }
  });

  test('sustained demand densifies in place: low, then medium, then high', () {
    final city = withZonedStreet()..resTarget = 1.0;
    final lot = city.layout.autoParcels.first;
    CityBuildingSpec? at(double progress) {
      city.grownParcels[lot.id] = progress;
      return city.parcelGrownSpec(lot.id, lot.use);
    }

    expect(at(0.1), isNull, reason: 'still under construction');
    expect(at(1.0)!.type, 'r-low');
    expect(at(2.1)!.type, 'r-med');
    expect(at(3.1)!.type, 'r-high');
  });

  test('grown buildings join the economy: housing, power draw, production', () {
    final city = withZonedStreet()..infiniteRobotics = true;
    final lot = city.layout.autoParcels.first;
    city.grownParcels[lot.id] = 1.0; // fully occupied low-density homes
    final before = city.housing;

    city.advance(0.02);

    expect(city.housing, greaterThan(before),
        reason: 'grown homes house people, not pixels');
    expect(city.powerDraw, greaterThan(0));
  });

  test('grown buildings reach the frame and their lot patch stands down', () {
    final city = withZonedStreet();
    final lot = city.layout.autoParcels.first;
    city.grownParcels[lot.id] = 1.0;

    final snap = WorldSnapshot.capture(
      0,
      InMemoryVesselRepository(const []),
      system: SampleWorld.realSystem(),
      cities: InMemoryCityRepository([city]),
    );
    expect(snap.buildings.keys, contains('grow/${lot.id}'));
    // The built lot no longer draws its zoning patch under the building.
    final builtPatches = snap.patches.where((p) =>
        p.kind == CityPatchSnapshot.kindResidential &&
        (p.sizeM - lot.buildableExtent.width).abs() < 0.5);
    expect(builtPatches.length, city.layout.autoParcels.length - 1);
  });

  test('a dense street congests; the same district on a highway does not', () {
    final city = withZonedStreet()..resTarget = 1.0;
    for (final lot in city.layout.autoParcels) {
      city.grownParcels[lot.id] = 3.1; // towers, everywhere
    }
    city.advanceParcelTraffic();
    final onStreet = city.parcelCongestion;
    expect(onStreet, greaterThan(0.5));

    // Rebuild the same district on a highway: same lots, four times the lanes.
    final wide = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'wide',
    );
    wide.layout.addRoad(const RoadSpline(
        id: 'hw',
        roadClass: RoadClass.highway,
        controls: [Vec2(0, -150), Vec2(0, 150)]));
    for (final lot in wide.layout.autoParcels) {
      wide.layout.setUse(lot.id, ParcelUse.residential);
      wide.grownParcels[lot.id] = 3.1;
    }
    wide.advanceParcelTraffic();
    expect(wide.parcelCongestion, lessThan(onStreet),
        reason: 'lanes are what a highway buys');
  });

  test('an unsuppressed fire takes the building; safety coverage saves it', () {
    final city = withZonedStreet();
    final lot = city.layout.autoParcels.first;
    city.grownParcels[lot.id] = 1.5;

    // No safety services at all: the fire burns the block out.
    city.lotFires[lot.id] = 0.3;
    for (var i = 0; i < 100; i++) {
      city.advanceParcelFires(0.1);
    }
    expect(city.grownParcels[lot.id], isNull, reason: 'burned out');
    expect(city.lotFires, isEmpty);

    // Same fire under blanket safety coverage: extinguished, building stands.
    city.grownParcels[lot.id] = 1.5;
    city.population = 100;
    city.services['safety'] = 400; // coverage ratio > 1
    city.lotFires[lot.id] = 0.3;
    for (var i = 0; i < 100; i++) {
      city.advanceParcelFires(0.1);
    }
    expect(city.grownParcels[lot.id], isNotNull);
    expect(city.lotFires, isEmpty);
  });

  test('a served parcel spaceport opens immigration', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'port',
    );
    expect(city.hasSpaceport, isFalse);
    city.layout.addRoad(const RoadSpline(
        id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
    final lot = city.layout.autoParcels.first;
    city.parcelBuildings[lot.id] =
        kUtilCatalog.firstWhere((s) => s.label == 'Spaceport');
    expect(city.hasSpaceport, isTrue,
        reason: 'a spaceport on a lot is a spaceport');
  });
}
