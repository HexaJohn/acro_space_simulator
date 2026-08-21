// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sprawling installations bring their own plot.
///
/// A subdivided street lot is about 24x32 m. The catalog's declared sites
/// start at 260 m and reach 3000 m for a quarry, so a solar farm is thirty
/// times wider than any lot could be. Placement used to shrink it to whatever
/// lot it landed on while the build ghost drew the real thing, and the two
/// disagreed by hundreds of metres.
void main() {
  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'claim',
      );

  CityBuildingSpec spec(String label) =>
      kUtilCatalog.firstWhere((s) => s.label == label);

  test('the sprawling specs claim, the ordinary ones do not', () {
    expect(spec('Solar Farm').claimsOwnSite, isTrue);
    expect(spec('Spaceport').claimsOwnSite, isTrue);
    // A zone building states no site of its own and keeps taking its lot.
    expect(kZoneSpecs['residential']![Density.low]!.claimsOwnSite, isFalse);
  });

  test('a claimed site is the size the ghost promised', () {
    final city = colony()
      ..stock['ore'] = 5000;
    city.commitRoad(const [Vec2(-600, -80), Vec2(600, -80)], RoadClass.street);
    final farm = spec('Solar Farm');

    // Clear of the road at n=-80, with its near edge just above it.
    final lot = city.claimSite(farm, const Vec2(0, 330));
    expect(lot, isNotNull, reason: city.blocked ?? '');
    final site = farm.siteMetres(cellM: CitySim.cellM);

    var minE = 1e30, maxE = -1e30, minN = 1e30, maxN = -1e30;
    for (final v in lot!.polygon) {
      if (v.e < minE) minE = v.e;
      if (v.e > maxE) maxE = v.e;
      if (v.n < minN) minN = v.n;
      if (v.n > maxN) maxN = v.n;
    }
    expect(maxE - minE, closeTo(site.width, 0.01));
    expect(maxN - minN, closeTo(site.depth, 0.01));
    expect(city.parcelBuildings[lot.id], farm);
  });

  test('a claimed site is CONNECTED when a road runs along its edge', () {
    // The reach test used to measure to the lot's CENTROID. A 780 m farm's
    // centre is 390 m from its own edge, so every big installation reported
    // itself cut off however well served it was.
    final city = colony()..stock['ore'] = 5000;
    city.commitRoad(const [Vec2(-600, -80), Vec2(600, -80)], RoadClass.street);
    final farm = spec('Solar Farm');
    final site = farm.siteMetres(cellM: CitySim.cellM);
    // Centre the farm so its near edge sits just off the road.
    final lot = city.claimSite(farm, Vec2(0, -80 + site.depth / 2 + 20))!;
    expect(city.siteConnected(lot.id), isTrue,
        reason: 'a road along its edge serves it');
  });

  test('a site out of reach of any road is refused, with a reason', () {
    final city = colony()..stock['ore'] = 5000;
    city.commitRoad(const [Vec2(-600, -80), Vec2(600, -80)], RoadClass.street);
    final farm = spec('Solar Farm');
    expect(city.claimSite(farm, const Vec2(0, 4000)), isNull);
    expect(city.blocked, contains('road'));
  });

  test('a site that would cross a road is refused', () {
    final city = colony()..stock['ore'] = 5000;
    city.commitRoad(const [Vec2(-600, 0), Vec2(600, 0)], RoadClass.street);
    // Centred ON the road: the footprint straddles it.
    expect(city.claimSite(spec('Solar Farm'), const Vec2(0, 0)), isNull);
    expect(city.blocked, isNotNull);
  });

  test('two claimed sites cannot overlap', () {
    final city = colony()..stock['ore'] = 20000;
    city.commitRoad(const [Vec2(-2000, -80), Vec2(2000, -80)], RoadClass.street);
    final farm = spec('Solar Farm');
    expect(city.claimSite(farm, const Vec2(0, 330)), isNotNull,
        reason: city.blocked ?? '');
    expect(city.claimSite(farm, const Vec2(100, 330)), isNull,
        reason: 'it lands on top of the first');
    expect(city.claimSite(farm, const Vec2(1200, 330)), isNotNull,
        reason: city.blocked ?? 'clear of it, so fine');
  });

  test('the blocked reason matches what placement will do', () {
    // The preview asks the same question the commit does, so a ghost that
    // reads placeable cannot then be refused.
    final city = colony()..stock['ore'] = 20000;
    city.commitRoad(const [Vec2(-600, -80), Vec2(600, -80)], RoadClass.street);
    final farm = spec('Solar Farm');
    for (final centre in [
      const Vec2(0, 330),
      const Vec2(0, 0),
      const Vec2(0, 4000),
      const Vec2(300, 200),
    ]) {
      final predicted = city.siteBlockedReason(farm, centre) == null;
      final actual = city.claimSite(farm, centre) != null;
      expect(actual, predicted, reason: 'disagreed at $centre');
    }
  });
}
