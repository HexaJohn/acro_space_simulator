// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

/// The editor draws ROADS as splines and builds on the PARCELS they cut, which
/// is the whole point of parcels — a grid tile has no frontage, so nothing can
/// be subdivided from it.
void main() {
  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'draw',
      );

  test('drawing a road cuts parcels along it', () {
    final city = colony();
    final c = CityEditController()..set(CityEditTool.roadSpline);
    expect(city.layout.parcels, isEmpty);

    for (final p in const [Vec2(0, -150), Vec2(0, 0), Vec2(0, 150)]) {
      c.addSplinePoint(p);
    }
    c.commitSpline(city);

    expect(city.layout.roads, hasLength(1));
    expect(city.layout.autoParcels, isNotEmpty);
    expect(c.pending, isEmpty, reason: 'the drag is consumed on release');
  });

  test('the frontage setting is what the lots are cut at', () {
    final city = colony();
    final c = CityEditController()
      ..set(CityEditTool.roadSpline)
      ..frontageM = 40
      ..lotDepthM = 50;
    for (final p in const [Vec2(0, -200), Vec2(0, 200)]) {
      c.addSplinePoint(p);
    }
    c.commitSpline(city);

    for (final lot in city.layout.autoParcels) {
      expect(lot.frontageWidth, closeTo(40, 2));
    }
    expect(city.layout.settings.depthM, 50);
  });

  test('a jittery drag does not cusp the curve', () {
    final c = CityEditController()..set(CityEditTool.roadSpline);
    c.addSplinePoint(const Vec2(0, 0));
    // Points a hand-drag dumps almost on top of each other are dropped.
    c.addSplinePoint(const Vec2(1, 1));
    c.addSplinePoint(const Vec2(2, 0));
    expect(c.pending, hasLength(1));
    c.addSplinePoint(const Vec2(0, 60));
    expect(c.pending, hasLength(2));
  });

  test('a half-drawn road is discarded, not committed as a stub', () {
    final city = colony();
    final c = CityEditController()..set(CityEditTool.roadSpline);
    c.addSplinePoint(const Vec2(0, 0));
    c.commitSpline(city);
    expect(city.layout.roads, isEmpty);
    expect(c.pending, isEmpty);
  });

  test('building on a lot costs ore and takes the lot', () {
    final city = colony();
    final c = CityEditController()..set(CityEditTool.roadSpline);
    for (final p in const [Vec2(0, -150), Vec2(0, 150)]) {
      c.addSplinePoint(p);
    }
    c.commitSpline(city);

    final lot = city.layout.autoParcels.first;
    final spec = kUtilCatalog.firstWhere((s) => s.label == 'Clinic');
    c.pickUtil(spec);
    city.stock['ore'] = 500;

    c.applyToParcel(city, lot.id);
    expect(city.parcelBuildings[lot.id], spec);
    expect(city.stockOf('ore'), 500 - spec.buildCost);

    // The same lot twice is refused, with a reason the toolbar can show.
    c.applyToParcel(city, lot.id);
    expect(c.blocked, contains('taken'));
  });

  test('a lot you cannot afford is refused before it is taken', () {
    final city = colony();
    final c = CityEditController()..set(CityEditTool.roadSpline);
    for (final p in const [Vec2(0, -150), Vec2(0, 150)]) {
      c.addSplinePoint(p);
    }
    c.commitSpline(city);

    final lot = city.layout.autoParcels.first;
    c.pickUtil(kUtilCatalog.firstWhere((s) => s.label == 'Clinic'));
    city.stock['ore'] = 0;
    c.applyToParcel(city, lot.id);

    expect(city.parcelBuildings, isEmpty);
    expect(c.blocked, contains('ore'));
  });

  test('zoning acts on the lot, not on a cell', () {
    final city = colony();
    final c = CityEditController()..set(CityEditTool.roadSpline);
    for (final p in const [Vec2(0, -150), Vec2(0, 150)]) {
      c.addSplinePoint(p);
    }
    c.commitSpline(city);

    final lot = city.layout.autoParcels.first;
    c.pickZone('industrial', Density.high);
    c.applyToLot(city, lot.id);

    final zoned =
        city.layout.parcels.firstWhere((p) => p.id == lot.id);
    expect(zoned.use, ParcelUse.industrial);
    // And nothing was written to the cell grid.
    expect(city.zones, isEmpty);
  });

  test('clearing a lot frees it and unzones it', () {
    final city = colony();
    final c = CityEditController()..set(CityEditTool.roadSpline);
    for (final p in const [Vec2(0, -150), Vec2(0, 150)]) {
      c.addSplinePoint(p);
    }
    c.commitSpline(city);

    final lot = city.layout.autoParcels.first;
    city.stock['ore'] = 500;
    c.pickUtil(kUtilCatalog.firstWhere((s) => s.label == 'Clinic'));
    c.applyToLot(city, lot.id);
    expect(city.parcelBuildings[lot.id], isNotNull);

    c.set(CityEditTool.bulldoze);
    c.applyToLot(city, lot.id);
    expect(city.parcelBuildings[lot.id], isNull);
    expect(
        city.layout.parcels.firstWhere((p) => p.id == lot.id).use,
        ParcelUse.unzoned);
    // The lot itself survives — clearing a building is not deleting the land.
    expect(city.layout.parcels.any((p) => p.id == lot.id), isTrue);
  });

  test('the editor writes nothing to the cell grid at all', () {
    final city = colony();
    final before = city.roads.length; // the founding hub road
    final c = CityEditController()..set(CityEditTool.roadSpline);
    for (final p in const [Vec2(-100, -100), Vec2(0, 0), Vec2(120, 140)]) {
      c.addSplinePoint(p);
    }
    c.commitSpline(city);

    final lot = city.layout.autoParcels.first;
    city.stock['ore'] = 900;
    c.pickUtil(kUtilCatalog.firstWhere((s) => s.label == 'Clinic'));
    c.applyToLot(city, lot.id);
    c.pickZone('residential', Density.low);
    c.applyToLot(city, city.layout.autoParcels[1].id);

    expect(city.zones, isEmpty);
    expect(city.utils, isEmpty);
    expect(city.roads.length, before,
        reason: 'roads are splines now, not tiles');
  });
}
