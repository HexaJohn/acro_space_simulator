// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// A save keeps every HAND-PLACED building, whatever catalogue its spec came
/// from.
///
/// `toJson` writes a placed building as its spec's label and `fromJson` looks
/// the label up. The lookup used to search `kUtilCatalog` alone, so a placed
/// ZONE building — homes, shops, a workshop — came back as nothing at all,
/// silently: the site was gone on load, and anything that hung off it (a car
/// parked on its stall, §7.5) went with it. Found while capturing a save
/// fixture for the agent traffic session: 78 placed buildings loaded as 5.
void main() {
  CitySim founded() => CityStarterKit.found(
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        config: const CityConfig(bodyId: 'earth'),
        start: CityStart.relaxed,
      );

  test('a placed zone building survives a save, as a utility does', () {
    final sim = founded();
    final free = [
      for (final p in sim.layout.autoParcels)
        if (!sim.parcelBuildings.containsKey(p.id)) p.id,
    ];
    expect(free.length, greaterThan(3));

    final homes = kZoneSpecs['residential']![Density.low]!;
    final shops = kZoneSpecs['commercial']![Density.low]!;
    final works = kZoneSpecs['industrial']![Density.low]!;
    final utility = kUtilCatalog.first;
    // Not every free lot takes a building: the four access easements of the
    // starter kit refuse one (§3.7a), so walk until each spec has a home.
    final placed = <String, CityBuildingSpec>{};
    var next = 0;
    for (final spec in [homes, shops, works, utility]) {
      while (next < free.length && !sim.placeOnParcel(free[next], spec)) {
        next++;
      }
      expect(next, lessThan(free.length), reason: 'a lot for ${spec.label}');
      placed[free[next++]] = spec;
    }
    expect(placed, hasLength(4), reason: 'all four placed');

    final loaded = CitySim.fromJson(
      sim.toJson(),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
    );
    placed.forEach((id, spec) {
      expect(loaded.parcelBuildings[id]?.label, spec.label, reason: id);
    });
    expect(loaded.parcelBuildings.length, sim.parcelBuildings.length,
        reason: 'the starter kit\'s own placed buildings came back too');
  });

  test('a label no catalogue knows is skipped, not thrown', () {
    final sim = founded();
    final json = sim.toJson();
    final buildings = json['parcelBuildings'] as Map;
    final before = buildings.length;
    buildings['lot-does-not-exist'] = 'A Building From A Later Version';
    final loaded = CitySim.fromJson(
      json,
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
    );
    expect(loaded.parcelBuildings.length, before);
    expect(loaded.parcelBuildings.containsKey('lot-does-not-exist'), isFalse);
  });
}
