// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/independent_governor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// Where the two plans' third phases meet: the terraforming tower family
/// (docs/plans/terraforming.md §4) against the independent governor
/// (docs/plans/colony-secession.md §4).
///
/// The governor chooses what to build by what a building MAKES or TAKES —
/// food, water and oxygen, watts, garbage, the dead. A tower moves a planet's
/// gas, which none of those readings see, and an independent council that
/// put one up would be spending a seceded colony's ore on a world-scale act
/// (a 600-watt Retention Array, a Greenhouse Factory warming everyone's sky)
/// the plan never gave it. Nothing in the governor names the towers, so the
/// guard is the catalogue's shape; these pins trip if a tuning pass gives a
/// tower a reading the governor does act on.
void main() {
  final towers = [
    for (final s in kUtilCatalog)
      if (s.group == 'env' && s.type != 'shelter') s,
  ];

  test('the tower family is all there', () {
    expect(towers.map((s) => s.type).toSet(), {
      'terraformer',
      'greenhousefactory',
      'regolithbaker',
      'sequestrator',
      'retentionarray',
    });
  });

  test('no tower carries a reading the governor builds on', () {
    for (final s in towers) {
      expect(CitySim.isLifeSupport(s), isFalse,
          reason: '${s.label} would answer a shortage');
      expect(s.powerOutput, 0,
          reason: '${s.label} would answer a power cut');
      expect(s.inputs.containsKey(Commodity.garbage), isFalse,
          reason: '${s.label} would answer the rubbish');
      expect(s.deathcareRate, 0, reason: '${s.label} would bury the dead');
    }
  });

  test('a desperate, ore-rich council on Mars never raises a tower', () {
    final mars = fixtureBodies.firstWhere((b) => b.id.value == 'mars');
    final city = foundFlat();
    city.ignoreUnlocks = true; // every tower is on the menu
    city.stock[Commodity.ore] = 1e5;
    final hy = city.hubKey ~/ city.grid;
    for (var x = 0; x < city.grid; x++) {
      final k = hy * city.grid + x;
      if (k != city.hubKey) city.addRoad(k);
    }
    city.body = mars;
    city.recompute();
    run(city, 5);
    city
      ..population = 40
      ..lifeThrottle = 1
      ..wasteBacklog = 1
      ..corpses = 40;
    city.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..independentAtS = city.colonyTimeS;
    final acts = <GovernorAct>[];
    for (var i = 0; i < 30; i++) {
      acts.addAll(city.governIndependent(localNet: const {
        Commodity.food: 0,
        Commodity.water: 0,
        Commodity.oxygen: 0,
      }));
    }
    final log = acts.map((a) => a.text).join('; ');
    expect(acts.where((a) => a.text.startsWith('built')), isNotEmpty,
        reason: 'the council did build: $log');
    final types = towers.map((s) => s.type).toSet();
    expect(city.utils.values.where((s) => types.contains(s.type)), isEmpty,
        reason: log);
    for (final s in towers) {
      expect(log, isNot(contains(s.label)));
    }
  });
}
