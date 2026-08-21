// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// A spaceport is addressable however it was placed.
///
/// The colony carries two placement models — the legacy cell grid and the
/// parcel layout the in-world editor builds on — and the traffic machinery used
/// to know only the first. A port built from the cockpit could take no
/// delivery, host no relief craft and berth no lander, because every one of
/// those was keyed on a grid cell it did not have.
void main() {
  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'moon', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'port',
      );

  CityBuildingSpec spec(String label) =>
      kUtilCatalog.firstWhere((s) => s.label == label);

  /// A colony with one road and a spaceport on the first lot it cuts — exactly
  /// what the in-world editor produces.
  (CitySim, String) lotPort([String label = 'Spaceport']) {
    final city = colony();
    city.layout.addRoad(const RoadSpline(
        id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
    final lot = city.layout.autoParcels.first;
    city.parcelBuildings[lot.id] = spec(label);
    return (city, lot.id);
  }

  test('a site id names a grid building and a lot building alike', () {
    final city = colony();
    city.placeUtil(city.hubKey, spec('Spaceport'));
    final gridSite = CitySim.siteIdOfCell(city.hubKey);

    expect(city.siteSpec(gridSite)?.type, 'spaceport');
    expect(CitySim.cellOfSiteId(gridSite), city.hubKey);
    // A lot id is not a cell, and must not be mistaken for one.
    expect(CitySim.cellOfSiteId('auto-main-3'), isNull);
    expect(CitySim.cellOfSiteId(null), isNull);
  });

  test('a lot-placed spaceport takes a delivery and dispatches it', () {
    final (city, site) = lotPort();
    expect(city.siteConnected(site), isTrue, reason: 'it fronts the road');

    city.deliveries[site] = [
      DeliverySchedule(
          resource: Commodity.ore, intervalSec: 30, amount: 200, timer: 0),
    ];
    city.stock[Commodity.ore] = 0;

    city.reliefTick(0.1);
    expect(city.craft, hasLength(1), reason: 'the run dispatched');
    expect(city.craft.single.site, site);

    // Fly the pad animation far enough for the payload to drop.
    for (var i = 0; i < 200 && city.craft.isNotEmpty; i++) {
      city.reliefTick(0.1);
    }
    expect(city.stockOf(Commodity.ore), greaterThan(0));
  });

  test('a one-time run clears itself; a recurring one rebooks', () {
    final (city, site) = lotPort();
    city.deliveries[site] = [
      DeliverySchedule(
          resource: Commodity.food, intervalSec: 30, amount: 100, timer: 0),
    ];
    city.reliefTick(0.1);
    expect(city.deliveries[site], isNull, reason: 'one-time run is spent');

    // Clear the pad the one-time run is sitting on: a schedule whose pad is
    // busy holds at zero rather than missing its cycle, which is a different
    // behaviour from the one under test here.
    city.craft.clear();
    final repeat = DeliverySchedule(
        resource: Commodity.food, intervalSec: 30, amount: 100, timer: 0)
      ..recurring = true;
    city.deliveries[site] = [repeat];
    city.reliefTick(0.1);
    expect(city.deliveries[site], hasLength(1));
    expect(repeat.timer, closeTo(30, 0.001));
  });

  test('pads are ordinals, so a lot port has as many as its footprint', () {
    final (city, site) = lotPort('Spaceport Complex (2×4)');
    expect(city.padCountOf(site), 8);
    expect(city.freePad(site), 0);

    // Fill every pad; the ninth caller finds none.
    for (var i = 0; i < 8; i++) {
      city.requestRelief(site);
      city.reliefCooldown = 0; // ignore the cooldown for this check
    }
    expect(city.craft, hasLength(8));
    expect(city.freePad(site), isNull);
    // A pinned pad that is taken yields nothing rather than double-booking.
    expect(city.padForSchedule(site, 3), isNull);
  });

  test('relief and the parked lander both address a lot port', () {
    final (city, site) = lotPort();
    city.requestRelief(site);
    expect(city.craft.single.isRelief, isTrue);
    expect(city.reliefCooldown, CitySim.reliefCooldownMax);

    city.landerPad = site;
    expect(city.landerPad, site);
  });

  test('demolishing a lot cancels everything booked against it', () {
    final (city, site) = lotPort();
    city.deliveries[site] = [
      DeliverySchedule(
          resource: Commodity.ore, intervalSec: 30, amount: 50, timer: 99),
    ];
    city.requestRelief(site);
    city.landerPad = site;

    city.clearParcel(site);

    expect(city.parcelBuildings[site], isNull);
    expect(city.deliveries[site], isNull, reason: 'no schedule without a port');
    expect(city.craft, isEmpty, reason: 'its visiting craft leave');
    expect(city.landerPad, isNull, reason: 'the berth is gone');
  });

  test('drawing a road past a port carries its bookings to the renamed lot',
      () {
    final (city, site) = lotPort();
    final booking = DeliverySchedule(
        resource: Commodity.water, intervalSec: 30, amount: 80, timer: 99);
    city.deliveries[site] = [booking];
    city.landerPad = site;

    // A cross street re-cuts the block, which renames the lots it splits.
    city.commitRoad(const [Vec2(-150, 40), Vec2(150, 40)], RoadClass.street);

    // Wherever the port ended up, its schedule went with it.
    final port = city.parcelBuildings.entries
        .where((e) => e.value.type == 'spaceport')
        .toList();
    expect(port, hasLength(1), reason: 'the port itself survived');
    expect(city.deliveries[port.single.key], contains(booking));
    expect(city.landerPad, port.single.key);
  });

  test('a disconnected port dispatches nothing', () {
    final city = colony();
    // A hand-drawn lot with no road frontage: built, but cut off.
    final island = city.layout.addManualParcel(const [
      Vec2(400, 400),
      Vec2(460, 400),
      Vec2(460, 460),
      Vec2(400, 460),
    ])!;
    city.parcelBuildings[island.id] = spec('Spaceport');
    expect(city.siteConnected(island.id), isFalse);

    city.deliveries[island.id] = [
      DeliverySchedule(
          resource: Commodity.ore, intervalSec: 30, amount: 200, timer: 0),
    ];
    city.reliefTick(0.1);
    expect(city.craft, isEmpty);
  });

  test('launch sites come from both models, and only when connected', () {
    final (city, site) = lotPort();
    expect(city.launchSites().map((e) => e.$1), [site]);

    // A grid port on the hub is connected too, so both are offered.
    city.placeUtil(city.hubKey, spec('Spaceport'));
    expect(city.launchSites().length, 2);
  });

  test('a site is found by the point it stands on', () {
    final (city, site) = lotPort();
    final lot = city.siteParcel(site)!;
    expect(city.siteAt(lot.centroid)?.$1, site);
    expect(city.siteAt(const Vec2(9000, 9000)), isNull);
  });
}
