// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony with site access plans on the wire (docs/plans/site-access.md
/// §8.3 R3): the tests of the capture, the tile columns and the tile cut
/// share it.
library;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/universe/star_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';

import '../traffic/traffic_fixture.dart';

final CityBuildingSpec siteTownHouse = kZoneSpecs['residential']![Density.low]!;

/// The system the site town is captured in.
final StarSystem siteTownSystem = SampleWorld.realSystem();

/// The starter-kit town, a street of houses on a REVERSED one-way road, and
/// one on a two-way street, every plan drained.
CitySim siteTown() {
  final city = town();
  city
    ..funds = 1e12
    ..ignoreUnlocks = true;
  void street(FixtureRoad r) {
    final id = commit(city, r);
    for (final p in city.layout.autoParcels) {
      if (p.roadId == id && !city.parcelBuildings.containsKey(p.id)) {
        city.placeOnParcel(p.id, siteTownHouse);
      }
    }
  }

  street(const FixtureRoad([Vec2(900, -150), Vec2(900, 150)],
      roadClass: RoadClass.streetOneWay, reversed: true));
  street(const FixtureRoad([Vec2(-900, -150), Vec2(-900, 150)]));
  city.advance(0.5);
  final done = city.siteAccess.sync(city, city.roadGraph,
      maxUnits: SiteAccessBook.unlimited, maxChecks: SiteAccessBook.unlimited);
  if (!done) throw StateError('the site town did not drain');
  return city;
}

/// [city] captured into a frame.
WorldSnapshot captureSiteTown(CitySim city, {int tick = 0}) =>
    WorldSnapshot.capture(tick, InMemoryVesselRepository(const []),
        system: siteTownSystem, cities: InMemoryCityRepository([city]));
