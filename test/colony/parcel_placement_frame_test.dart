// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

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

/// Parcels only mean anything once a building placed on one reaches the frame
/// at that LOT's size and facing — otherwise the subdivision is bookkeeping.
void main() {
  CitySim withStreet() {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'street',
    );
    city.layout.addRoad(const RoadSpline(
      id: 'main',
      controls: [Vec2(0, -120), Vec2(0, 120)],
    ));
    return city;
  }

  WorldSnapshot capture(CitySim city) => WorldSnapshot.capture(
        0,
        InMemoryVesselRepository(const []),
        system: SampleWorld.realSystem(),
        cities: InMemoryCityRepository([city]),
      );

  test('empty lots are drawn, so you can see the subdivision', () {
    final city = withStreet();
    expect(city.layout.autoParcels, isNotEmpty);

    final patches = capture(city).patches;
    // One patch per lot, at the lot's real (non-square) extent.
    final lots = patches.where((p) => p.sizeM != p.depthM).toList();
    expect(lots, isNotEmpty);
    for (final p in lots) {
      expect(p.sizeM, greaterThan(5));
      expect(p.depthM, greaterThan(5));
    }
  });

  test('a building on a lot takes that lot size, not a grid cell', () {
    final city = withStreet();
    final lot = city.layout.autoParcels.first;
    final shop = kZoneSpecs['commercial']![Density.low]!;
    expect(city.placeOnParcel(lot.id, shop), isTrue);

    final b = capture(city).buildings.values.firstWhere((b) => b.id == lot.id);
    final extent = lot.buildableExtent;
    // The LOT's size, less the setback that keeps the building inside its own
    // levelled terrace, times the share of the plot its density takes. This
    // spec declares no site of its own, so the lot still governs — which is
    // the whole point: a parcel building is not cut to a grid cell.
    final back = lotSetbackFor(shop), cover = lotCoverageFor(shop);
    expect(b.siteWidthM, closeTo((extent.width - 2 * back) * cover, 0.01));
    expect(b.siteDepthM, closeTo((extent.depth - 2 * back) * cover, 0.01));
    // Not the 24 m cell the grid would have forced on it.
    expect(b.siteDepthM, isNot(closeTo(CitySim.cellM, 0.01)));
  });

  test('a building on a lot turns to face its street', () {
    final city = withStreet();
    final earth = SampleWorld.realSystem().body(city.body.id)!;
    // Lots on opposite sides of the road face opposite ways.
    final lots = city.layout.autoParcels;
    final east = lots.firstWhere((p) => p.centroid.e > 0);
    final west = lots.firstWhere((p) => p.centroid.e < 0);
    final shop = kZoneSpecs['commercial']![Density.low]!;
    city.placeOnParcel(east.id, shop);
    city.placeOnParcel(west.id, shop);

    final snap = capture(city);
    final bE = snap.buildings.values.firstWhere((b) => b.id == east.id);
    final bW = snap.buildings.values.firstWhere((b) => b.id == west.id);

    // A building's local +Y is its frontage direction; rotate it out and the
    // two must point at each other across the carriageway.
    final fE = _facing(bE);
    final fW = _facing(bW);
    expect(_dot(fE, fW), lessThan(-0.8),
        reason: 'lots either side of a street face opposite ways');
    // And both stand on the planet.
    expect(_len(bE.px, bE.py, bE.pz), closeTo(earth.radius, 12000));
  });
}

List<double> _facing(BuildingSnapshot b) {
  // Rotate local +Y (0,1,0) by the snapshot quaternion.
  final w = b.qw, x = b.qx, y = b.qy, z = b.qz;
  return [
    2 * (x * y - w * z),
    1 - 2 * (x * x + z * z),
    2 * (y * z + w * x),
  ];
}

double _dot(List<double> a, List<double> b) =>
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

double _len(double x, double y, double z) => math.sqrt(x * x + y * y + z * z);
