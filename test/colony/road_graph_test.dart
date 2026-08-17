// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Intersections are TOPOLOGY, not two ribbons overlapping: committing a road
/// through another splits both at the junction.
void main() {
  test('a crossing splits both roads into four segments', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)]);
    expect(layout.roads, hasLength(1));

    layout.commitRoad(
        controls: const [Vec2(-200, 0), Vec2(200, 0)]);
    // Each arm of the X is its own segment now.
    expect(layout.roads, hasLength(4));

    // And every segment ends at (or starts from) the junction.
    var touching = 0;
    for (final r in layout.roads) {
      final ends = [r.controls.first, r.controls.last];
      if (ends.any((e) => e.length < 3)) touching++;
    }
    expect(touching, 4, reason: 'all four arms meet at the crossing');
  });

  test('an endpoint drawn near a road snaps onto it: a T junction', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)]);
    // A side street whose end stops 10 m short of the main road.
    layout.commitRoad(
        controls: const [Vec2(10, 50), Vec2(150, 50)]);

    // The main road is split in two by the T; the side road joins it exactly.
    expect(layout.roads, hasLength(3));
    final side =
        layout.roads.firstWhere((r) => r.controls.last.e > 100);
    expect(side.controls.first.e.abs(), lessThan(0.5),
        reason: 'the loose end landed ON the main road, not 10 m off it');
  });

  test('corner clearance now applies at real junctions', () {
    final layout = CityLayout(
        settings: const ParcelSettings(cornerClearM: 12));
    layout.commitRoad(controls: const [Vec2(0, -200), Vec2(0, 200)]);
    layout.commitRoad(controls: const [Vec2(-200, 0), Vec2(200, 0)]);

    // No lot's frontage may reach into the junction's mouth.
    for (final lot in layout.autoParcels) {
      final f = lot.frontage!;
      for (final p in [f.$1, f.$2]) {
        expect(p.length, greaterThan(10),
            reason: 'a frontage corner inside the junction mouth');
      }
    }
  });

  test('buildings survive their street being cut by a new road', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'cut',
    );
    city.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
    // Build on a lot well clear of where the crossing will land.
    final lot = city.layout.autoParcels
        .firstWhere((p) => p.centroid.n > 100);
    final clinic = kUtilCatalog.firstWhere((s) => s.label == 'Clinic');
    city.parcelBuildings[lot.id] = clinic;
    final ground = lot.centroid;

    // Cross the street far from the building.
    city.commitRoad(const [Vec2(-200, -100), Vec2(200, -100)], RoadClass.street);

    // The building still exists, keyed to the lot standing on its ground.
    expect(city.parcelBuildings.values, contains(clinic));
    final keyedLot = city.layout.parcels.firstWhere(
        (p) => city.parcelBuildings.containsKey(p.id));
    expect(keyedLot.contains(ground), isTrue,
        reason: 'the building moved lots in NAME only, not in place');
  });

  test('dirt paths are a real tier: narrow, unpaved, low capacity', () {
    expect(RoadClass.path.paved, isFalse);
    expect(RoadClass.path.width, lessThan(RoadClass.street.width));
    // Persisted by index: path must stay APPENDED or saves reclassify.
    expect(RoadClass.values.last, RoadClass.path);

    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'dirt',
    );
    city.commitRoad(const [Vec2(0, -150), Vec2(0, 150)], RoadClass.path);
    for (final lot in city.layout.autoParcels) {
      city.layout.setUse(lot.id, ParcelUse.residential);
      city.grownParcels[lot.id] = 1.0;
    }
    city.advanceParcelTraffic();
    final onPath = city.parcelCongestion;

    final paved = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'paved',
    );
    paved.commitRoad(const [Vec2(0, -150), Vec2(0, 150)], RoadClass.street);
    for (final lot in paved.layout.autoParcels) {
      paved.layout.setUse(lot.id, ParcelUse.residential);
      paved.grownParcels[lot.id] = 1.0;
    }
    paved.advanceParcelTraffic();

    expect(onPath, greaterThan(paved.parcelCongestion),
        reason: 'the same homes choke a track that a street carries');
  });
}
