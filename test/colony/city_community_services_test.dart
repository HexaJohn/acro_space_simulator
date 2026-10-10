// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// A village runs on its community; a town needs the formal services.
///
/// Below [CitySim.communityFullPop] everyone knows everyone, and safety,
/// health and leisure are covered informally; by [CitySim.communityFadePop]
/// (Dunbar's ~150) that is gone. A connected spaceport is the colony's
/// market town for health: medevac to orbit. Before this the starter kit,
/// which builds no services, sat at Mood 0% for good: no tax, and a
/// population pinned at 40% of its housing.
void main() {
  tearDown(AgentTuning.reset);

  test('the community covers everyone in a village and nobody in a town', () {
    expect(CitySim.communityShare(0), 1.0);
    expect(CitySim.communityShare(CitySim.communityFullPop), 1.0);
    expect(CitySim.communityShare(CitySim.communityFadePop), 0.0);
    expect(CitySim.communityShare(1000), 0.0);
    var last = 1.0;
    for (var p = 0.0; p <= 200; p += 5) {
      final s = CitySim.communityShare(p);
      expect(s, lessThanOrEqualTo(last), reason: 'it only fades, at $p');
      last = s;
    }
  });

  test('a starter colony with no services is content, and earns its tax', () {
    final city = starterKit();
    run(city, 120);
    expect(city.serviceCoverage(), 1.0);
    expect(city.happiness, greaterThan(0.3));
    expect(city.taxIncomeRate, greaterThan(0));
  });

  test('a town past the village size needs its own services', () {
    final city = starterKit();
    run(city, 1);
    city.population = CitySim.communityFadePop + 50;
    run(city, 0.5);
    expect(city.serviceCoverage(), 0.0,
        reason: 'no police and no park: the port only flies out the sick');
    expect(city.disease, greaterThan(0));
  });

  test('a connected spaceport covers some health: medevac to orbit', () {
    final city = starterKit();
    run(city, 1);
    expect(city.hasSpaceport, isTrue);
    expect(city.services['health'], CitySim.portMedevacPeople,
        reason: 'the kit builds no clinic, so this is the port');
  });

  test('a zoned starter town grows past its landing site', () {
    final city = starterKit(agentTraffic: true);
    zoneAll(city, const [
      ParcelUse.residential,
      ParcelUse.residential,
      ParcelUse.commercial,
    ]);
    run(city, 600);
    expect(city.population, greaterThan(30),
        reason: 'content settlers fill more than 40% of the homes');
    expect(city.starved, isFalse);
  });

  test('settlers keep their own lanes, and a town pays for its roads', () {
    final city = starterKit();
    run(city, 1);
    city.population = 40;
    final gross = city.roadUpkeepPerWeek / city.weekSec;
    expect(city.communityRoadPerWeek, greaterThan(0));
    expect(city.roadUpkeepRate, lessThan(gross));
    // ignore: avoid_print
    print('starter roads: gross ${gross.toStringAsFixed(3)} §/s, paid '
        '${city.roadUpkeepRate.toStringAsFixed(3)} §/s at 40 people');
    // Gravel-road standard only: the paving above it is still the town's.
    expect(city.communityRoadPerWeek,
        lessThan(city.roadUpkeepPerWeek * 0.19 / 0.32 + 1e-9));
    city.population = CitySim.communityFadePop;
    expect(city.communityRoadPerWeek, 0.0);
    expect(city.roadUpkeepRate, closeTo(gross, 1e-12));
  });
}
