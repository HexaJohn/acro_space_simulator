// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parcels replace the fixed cell grid: land is cut from the road network at
/// whatever frontage/depth the player sets, with hand-drawn lots overriding it.
void main() {
  RoadSpline straight({double length = 200, RoadClass cls = RoadClass.street}) =>
      RoadSpline(
        id: 'main',
        roadClass: cls,
        controls: [const Vec2(0, 0), Vec2(0, length)],
      );

  test('a straight road subdivides into even lots on both sides', () {
    final layout = CityLayout(
      settings: const ParcelSettings(frontageM: 20, depthM: 30, cornerClearM: 0),
    )..addRoad(straight(length: 200));

    final lots = layout.autoParcels;
    // 200 m of frontage at 20 m per lot, both sides.
    expect(lots.length, 20);
    for (final lot in lots) {
      expect(lot.frontageWidth, closeTo(20, 0.5));
      expect(lot.area, closeTo(20 * 30, 30));
    }
  });

  test('lot frontage is set back off the carriageway, not on it', () {
    final layout = CityLayout(
      settings: const ParcelSettings(sidewalkM: 3, cornerClearM: 0),
    )..addRoad(straight(cls: RoadClass.avenue));

    final road = layout.roads.first;
    for (final lot in layout.autoParcels) {
      for (final v in lot.polygon) {
        expect(road.distanceTo(v), greaterThanOrEqualTo(road.halfWidth),
            reason: 'no part of a lot may sit in the carriageway');
      }
      // The frontage edge sits exactly at curb + sidewalk.
      expect(road.distanceTo(lot.frontageMidpoint!),
          closeTo(road.halfWidth + 3, 0.5));
    }
  });

  test('buildings on a lot face the road they front', () {
    final layout = CityLayout(settings: const ParcelSettings(cornerClearM: 0))
      ..addRoad(straight());

    for (final lot in layout.autoParcels) {
      // The road runs north; every lot must face east or west, toward it.
      final facing = lot.facing;
      expect(facing.n.abs(), lessThan(0.1));
      expect(facing.e.abs(), closeTo(1.0, 0.1));
      // And facing must point from the lot toward the street, not away.
      final toRoad = (lot.frontageMidpoint! - lot.centroid).normalized;
      expect(facing.dot(toRoad), closeTo(1.0, 1e-6));
    }
  });

  test('no two auto lots overlap, on a straight road or a curve', () {
    for (final controls in [
      [const Vec2(0, 0), const Vec2(0, 300)],
      // A bend and an S-curve, where naive parameter stepping would collide.
      [
        const Vec2(0, 0),
        const Vec2(40, 90),
        const Vec2(-30, 170),
        const Vec2(20, 260),
      ],
    ]) {
      final layout = CityLayout(
        settings: const ParcelSettings(frontageM: 25, depthM: 30),
      )..addRoad(RoadSpline(id: 'r', controls: controls));

      final lots = layout.autoParcels;
      expect(lots, isNotEmpty);
      for (var i = 0; i < lots.length; i++) {
        for (var j = i + 1; j < lots.length; j++) {
          expect(lots[i].overlaps(lots[j]), isFalse,
              reason: 'lot $i overlaps lot $j');
        }
      }
    }
  });

  test('changing the frontage setting re-cuts the same road', () {
    final layout = CityLayout(
      settings: const ParcelSettings(frontageM: 20, cornerClearM: 0),
    )..addRoad(straight(length: 200));
    final narrow = layout.autoParcels.length;

    layout.settings = const ParcelSettings(frontageM: 50, cornerClearM: 0);
    final wide = layout.autoParcels.length;

    expect(wide, lessThan(narrow));
    expect(layout.autoParcels.first.frontageWidth, closeTo(50, 1));
  });

  test('a manual lot blocks the auto lots that would overlap it', () {
    final layout = CityLayout(
      settings: const ParcelSettings(frontageM: 20, depthM: 30, cornerClearM: 0),
    )..addRoad(straight(length: 200));
    final before = layout.autoParcels.length;

    // A big industrial plot dropped over the east side of the street.
    final manual = layout.addManualParcel(const [
      Vec2(10, 40),
      Vec2(90, 40),
      Vec2(90, 140),
      Vec2(10, 140),
    ], use: ParcelUse.industrial);

    expect(manual, isNotNull);
    expect(layout.autoParcels.length, lessThan(before));
    for (final lot in layout.autoParcels) {
      expect(lot.overlaps(manual!), isFalse);
    }
    expect(layout.parcels, contains(manual));
  });

  test('a manual lot laid across a carriageway is refused', () {
    final layout = CityLayout()..addRoad(straight(length: 200));
    final onRoad = layout.addManualParcel(const [
      Vec2(-20, 60),
      Vec2(20, 60),
      Vec2(20, 100),
      Vec2(-20, 100),
    ]);
    expect(onRoad, isNull);
    expect(layout.manualParcels, isEmpty);
  });

  test('a huge manual lot carries the scale a grid cell never could', () {
    // A 2 km solar farm — the case the fixed grid could not express.
    final layout = CityLayout();
    final farm = layout.addManualParcel(const [
      Vec2(500, 500),
      Vec2(2500, 500),
      Vec2(2500, 2500),
      Vec2(500, 2500),
    ], use: ParcelUse.utility);

    expect(farm, isNotNull);
    expect(farm!.area, closeTo(4e6, 1)); // 4 km²
    final extent = farm.buildableExtent;
    expect(extent.width, closeTo(2000, 1));
    expect(extent.depth, closeTo(2000, 1));
  });
}
