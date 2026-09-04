// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The megatower: the one building allowed past the ordinary height ceiling.
void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();

  Parcel megaParcel() => const Parcel(
        id: 'mega-test',
        polygon: [Vec2(-48, 0), Vec2(48, 0), Vec2(48, 88), Vec2(-48, 88)],
        frontage: (Vec2(-48, 0), Vec2(48, 0)),
      );

  test('a megatower rises past the ordinary ceiling', () {
    const rules =
        BuildingMassingRules(style: ArchitectureStyle.masonryStreet);
    final m = rules.massFor(kMegatowerSpec, megaParcel(), seed: 7);
    // The ordinary hard cap is maxFloors (60); zone targets keep regular
    // towers tighter still. A megatower must clear both by a distance, or
    // it is just another skyscraper with a grander name.
    expect(m.floors, greaterThan(60),
        reason: 'the mega branch must bypass maxFloors');
    expect(m.height, greaterThan(300),
        reason: '90+ storeys is over 300 m of building');
    // And it stays a block-filler, not a country-filler: the footprint is
    // bounded by the site the spec declares.
    final fp = m.footprint;
    expect(fp.width, lessThanOrEqualTo(96.1));
    expect(fp.depth, lessThanOrEqualTo(88.1));
    // No surface lot: eighteen thousand workers park in the podium.
    expect(m.parking, isNull);
  });

  test('two seeds are two different megatowers', () {
    const rules =
        BuildingMassingRules(style: ArchitectureStyle.masonryStreet);
    final a = rules.massFor(kMegatowerSpec, megaParcel(), seed: 1);
    final b = rules.massFor(kMegatowerSpec, megaParcel(), seed: 2);
    expect(a.floors, isNot(b.floors),
        reason: 'height is seeded — a skyline of identical megas is a wall');
  });

  test('the generator stakes them downtown, over whole blocks', () {
    final sim = const CityGenerator().generate(
      const CityGenSpec(seed: 5, blocksAcross: 3, megatowers: 2),
      bodies: bodies,
    );
    final megas = sim.parcelBuildings.entries
        .where((e) => e.value.type == 'mega')
        .toList();
    expect(megas.length, 2,
        reason: 'a three-block city has interior blocks for both');
    // Own-site parcels, near the centre — inside the street grid rather
    // than out past its edge with the installations.
    final extent = const CityGenSpec(blocksAcross: 3).extentM / 2;
    for (final e in megas) {
      final p = sim.layout.parcels.firstWhere((p) => p.id == e.key);
      // Downtown, allowing that the expressway corridor and its frontage
      // streets take the blocks along the central row: the nearest whole
      // block in a three-block town can be a little past the half extent.
      expect(p.centroid.length, lessThan(extent * 1.2),
          reason: 'a megatower is a downtown statement, not an outskirt');
    }
  });
}
