// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road menu on the milestone ladder: every road opens at exactly one
/// rung, and the milestone panel and the road menu agree about which.
library;

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_progression.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> at(int tier) => [
        for (final t
            in CityProgression.roadsUnlockedBy(CityProgression.all[tier]))
          t.id
      ];

  test('every road on the menu opens at exactly one milestone', () {
    final seen = <String, int>{};
    for (final m in CityProgression.all) {
      for (final t in CityProgression.roadsUnlockedBy(m)) {
        expect(seen.containsKey(t.id), isFalse, reason: '${t.id} listed twice');
        seen[t.id] = m.tier;
      }
    }
    expect(seen.keys.toSet(), {for (final t in kRoadCatalog) t.id});
  });

  test('the opening menu, and what Township and Small Town add', () {
    expect(at(0),
        containsAll(['gravel', 'two-lane', 'one-way', 'four-lane', 'six-lane']));
    expect(at(1), isEmpty, reason: 'the Outpost opens buildings, not roads');
    expect(at(4), containsAll(['highway', 'ramp'])); // Township, 200
    expect(at(5), containsAll(['two-lane-trees', 'highway-walls'])); // 300
  });

  test('the milestone panel and the road menu agree', () {
    final sim = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'ladder',
    );
    for (final m in CityProgression.all) {
      for (final t in CityProgression.roadsUnlockedBy(m)) {
        sim.population = m.population.toDouble();
        expect(sim.roadTypeUnlocked(t), isTrue, reason: t.id);
        if (m.population > 0) {
          sim.population = m.population - 1.0;
          expect(sim.roadTypeUnlocked(t), isFalse, reason: t.id);
        }
      }
    }
  });

  test('the building ladder is untouched', () {
    for (final m in CityProgression.all.skip(1)) {
      expect(CityProgression.unlockedBy(m), isNotEmpty, reason: m.name);
    }
  });
}
