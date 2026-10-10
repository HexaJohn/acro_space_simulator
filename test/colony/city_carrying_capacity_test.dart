// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// A colony that cannot supply everyone settles at the people it CAN supply.
///
/// Every test here was once a death spiral to the last settler: a fully built
/// starter town grew past its one pump, ran the tank dry and starved from
/// ~200 to 1, and an unbuilt one with no cemetery shrank a death at a time,
/// because each body held a home for good.
void main() {
  tearDown(AgentTuning.reset);

  test('a town short of water settles at what it can supply, not at nobody',
      () {
    // Eight hundred homes, one pump, and the generation of a starter kit:
    // the tank runs dry and stays dry.
    final city = town(agentTraffic: true);
    city.agents.debugSettle(people: 120);
    run(city, 900);
    expect(city.population, greaterThan(50),
        reason: 'the people the pump can water stay');
    expect(city.population, lessThan(city.supportablePop + 5),
        reason: 'and no more than that');
    expect(city.starved, isFalse);
  });

  test('life support is staffed and powered before anything else', () {
    // Nearly four hundred jobs and a hundred-odd people: the farm and the
    // pump are fully worked while every other job shares what is left.
    final city = town(agentTraffic: true);
    city.agents.debugSettle(people: 120);
    run(city, 60);
    expect(city.jobs, greaterThan(city.population * 2));
    expect(city.lifeThrottle, 1.0);
    expect(city.restThrottle, lessThan(0.5));
    expect(city.staffing, lessThan(1.0), reason: 'the readout is still the town');
  });

  test('the spaceport does not take the farm\'s workers', () {
    final port = kUtilCatalog.firstWhere((s) => s.type == 'spaceport');
    final farm = kUtilCatalog.firstWhere((s) => s.type == 'farm');
    expect(CitySim.isLifeSupport(port), isFalse,
        reason: 'its supplies are imports, and its forty jobs');
    expect(CitySim.isLifeSupport(farm), isTrue);
  });

  test('a starter town with no cemetery holds its people', () {
    final city = starterKit(agentTraffic: true);
    zoneAll(city, const [
      ParcelUse.residential,
      ParcelUse.residential,
      ParcelUse.commercial,
    ]);
    run(city, 240);
    final settled = city.population;
    expect(settled, greaterThan(15));
    run(city, 960);
    expect(city.population, greaterThanOrEqualTo(settled * 0.9),
        reason: 'the dead are buried by hand, and their homes let again');
    expect(city.corpses, lessThan(2));
  });

  test('a deathcare building on a lot clears the dead', () {
    final city = starterKit();
    final morgue = kUtilCatalog.firstWhere((s) => s.type == 'morgue');
    expect(freeLots(city).any((lot) => place(city, lot.id, morgue)), isTrue,
        reason: 'a street lot the morgue fits');
    city.corpses = 100;
    run(city, 10);
    expect(city.corpses, lessThan(100 - 10 * 1.0),
        reason: 'a morgue clears 1.5 a second; hand burial alone, 0.05');
  });
}
