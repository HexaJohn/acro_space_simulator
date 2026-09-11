// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The fixture's colonies are what every traffic test stands on, so they are
/// pinned first: a colony that stopped being the network its name promises
/// would fail every test built on it, for a reason that has nothing to do
/// with traffic.
void main() {
  test('a founded colony is quiet', () {
    final city = foundFlat();
    expect(city.hostility, 0);
    expect(city.autoDisasterTimer, greaterThanOrEqualTo(1e9));
    expect(starterKit().hostility, 0,
        reason: 'the starter kit is quiet whatever its difficulty says');
  });

  test('committed roads split where they cross', () {
    final city = foundFlat(roads: const [
      FixtureRoad([Vec2(0, -200), Vec2(0, 200)]),
      FixtureRoad([Vec2(-200, 0), Vec2(200, 0)]),
    ]);
    final g = city.roadGraph;
    expect(g.roadCount, 4, reason: 'each street split at the crossing');
    expect(g.nodeCount, 5);
    expect(g.edgeCount, 8);
    expect(g.nodeNear(const Vec2(0, 0))!.legs, hasLength(4));
  });

  test('a grid is four-leg crossings inside a rim of dead ends', () {
    final city = grid(3);
    final g = city.roadGraph;
    // Three roads each way, each cut into four by the three it crosses.
    expect(g.roadCount, 24);
    expect(g.edgeCount, 48);
    var crossings = 0, deadEnds = 0;
    for (final n in g.nodes) {
      if (n.legs.length == 4) crossings++;
      if (n.legs.length == 1) deadEnds++;
    }
    expect(crossings, 9);
    expect(deadEnds, 12, reason: 'every road overruns the rim at both ends');
    expect(g.nodeCount, 21);
    expect(city.layout.autoParcels, isNotEmpty,
        reason: 'the deferred lot re-cut ran');
  });

  test('signalised() lights its crossing', () {
    final g = signalised().roadGraph;
    expect(g.nodeNear(const Vec2(0, 0))!.control, JunctionControl.signals);
  });

  test('a town is zoned all three ways and its buildings stay built', () {
    final city = town();
    int built(ParcelUse use) => city.layout.autoParcels
        .where((p) => p.use == use && city.parcelBuildings.containsKey(p.id))
        .length;
    expect(built(ParcelUse.residential), greaterThan(built(ParcelUse.commercial)));
    expect(built(ParcelUse.commercial), greaterThan(0));
    expect(built(ParcelUse.industrial), greaterThan(0));
    expect(freeLots(city).where((p) => CitySim.zoneKindOf(p.use) != null),
        isEmpty,
        reason: 'every zoned lot got its building');

    final before = {...city.parcelBuildings.keys};
    run(city, 60);
    expect(city.housing, greaterThan(0), reason: 'the homes house people');
    expect({...city.parcelBuildings.keys}, before,
        reason: 'placed buildings neither decay nor densify');
  });

  test('a grown town is grown, not placed', () {
    final city = town(grown: true);
    final grown = [
      for (final lot in freeLots(city))
        if (CitySim.zoneKindOf(lot.use) != null) lot,
    ];
    expect(grown, isNotEmpty);
    for (final lot in grown) {
      expect(city.grownParcels[lot.id], 1.0);
      expect(city.parcelGrownSpec(lot.id, lot.use), isNotNull,
          reason: '1.0 is past the construction line: a standing building');
    }
  });

  test('lotNearest finds the lot beside a point on the crossroads', () {
    final city = starterKit();
    final lot = lotNearest(city, const Vec2(100, -20));
    expect(lot.centroid.distanceTo(const Vec2(100, -20)), lessThan(40));
  });
}
