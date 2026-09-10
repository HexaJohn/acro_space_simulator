// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_progression.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The milestone ladder: what the city-builder mode's progression is made of.
void main() {
  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'ladder',
      );

  test('the ladder is ordered and starts at the founding state', () {
    expect(CityProgression.all.first.population, 0);
    for (var i = 1; i < CityProgression.all.length; i++) {
      expect(CityProgression.all[i].population,
          greaterThan(CityProgression.all[i - 1].population));
      expect(CityProgression.all[i].tier, i, reason: 'tier IS the index');
    }
  });

  test('every tier above the first opens something in the catalogue', () {
    for (final m in CityProgression.all.skip(1)) {
      expect(CityProgression.unlockedBy(m), isNotEmpty,
          reason: '${m.name} unlocks nothing — the ladder has drifted off the '
              'catalogue thresholds');
    }
  });

  test('unlocks agree with the gate the palette actually asks', () {
    final city = colony();
    for (final m in CityProgression.all) {
      city.population = m.population.toDouble();
      for (final s in CityProgression.unlockedBy(m)) {
        expect(city.unlocked(s), isTrue,
            reason: '${s.label} is listed at ${m.name} but still gated');
      }
    }
    // And the converse: nothing is listed before its gate opens.
    city.population = 0;
    for (final s in CityProgression.unlockedBy(CityProgression.all[3])) {
      if (s.unlockPop > 0) expect(city.unlocked(s), isFalse);
    }
  });

  test('reached / next / fraction read the population honestly', () {
    expect(CityProgression.reached(0).tier, 0);
    expect(CityProgression.reached(59).tier, 0);
    expect(CityProgression.reached(60).tier, 1);
    expect(CityProgression.next(60)!.population, 80);
    expect(CityProgression.fractionToNext(70), closeTo(0.5, 1e-9));
    // Top of the ladder: no next rung, and the bar reads full rather than empty.
    final top = CityProgression.all.last;
    expect(CityProgression.next(top.population.toDouble() + 1), isNull);
    expect(CityProgression.fractionToNext(top.population.toDouble() + 1), 1);
  });

  test('a tier pays out once, however many ticks pass over it', () {
    final city = colony()
      ..funds = 0
      ..stock[Commodity.ore] = 0;
    city.population = 65;
    city.claimMilestones();
    final paid = city.funds;
    final ore = city.stockOf(Commodity.ore);
    expect(paid, CityProgression.all[1].fundsGrant);
    expect(city.milestoneToasts.map((a) => a.milestone.tier), [1]);

    for (var i = 0; i < 5; i++) {
      city.claimMilestones();
    }
    expect(city.funds, paid, reason: 'no second payout for the same tier');
    expect(city.stockOf(Commodity.ore), ore);

    // Falling back below the threshold and climbing again is still one payout.
    city.population = 10;
    city.claimMilestones();
    city.population = 65;
    city.claimMilestones();
    expect(city.funds, paid);
  });

  test('a jump of several tiers collects each of them, in order', () {
    final city = colony()..funds = 0;
    city.population = 320;
    city.claimMilestones();
    expect(city.milestoneToasts.map((a) => a.milestone.tier), [1, 2, 3, 4, 5]);
    final expected = CityProgression.all
        .where((m) => m.population <= 320)
        .fold<double>(0, (a, m) => a + m.fundsGrant);
    expect(city.funds, expected);
  });

  test('tier 0 is recorded but raises no banner', () {
    final city = colony()..population = 0;
    city.claimMilestones();
    expect(city.milestonesReached, contains(0));
    expect(city.milestoneToasts, isEmpty);
  });

  test('a save round-trips the ledger; a pre-ladder save does not pay out', () {
    final bodies =
        RealSolarSystem.build().all.where((b) => !b.isStar).toList();
    final city = colony()..population = 210;
    city.claimMilestones();
    final json = city.toJson();

    final back = CitySim.fromJson(json, bodies: bodies);
    expect(back.milestonesReached, city.milestonesReached);

    // An old save has no ledger at all. Treating that as "nothing claimed"
    // would hand a grown city every grant on its first tick.
    json.remove('milestones');
    final legacy = CitySim.fromJson(json, bodies: bodies)..funds = 0;
    legacy.claimMilestones();
    expect(legacy.funds, 0);
    expect(legacy.milestonesReached, city.milestonesReached);
  });
}
