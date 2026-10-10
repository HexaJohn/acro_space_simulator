// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// An outbreak and its burial backlog are live sim state — disease takes
/// lives, corpses breed disease and sour the mood — so a save carries them.
/// Unsaved, a save and load cured a plague and emptied the morgue, and the
/// population (which weights reputation, hearts pressure and the dependency
/// check) drifted off the run that was never saved.
void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();

  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: bodies,
        id: 'plague',
      )..population = 1200;

  test('a save carries the outbreak and the backlog across a load', () {
    final city = colony()
      ..disease = 0.456
      ..corpses = 336;
    final back = CitySim.fromJson(city.toJson(), bodies: bodies);
    expect(back.disease, 0.456);
    expect(back.corpses, 336);
    // Saved again, it saves the same two values: nothing rounded away.
    final again = back.toJson();
    expect(again['disease'], 0.456);
    expect(again['corpses'], 336);
  });

  test('a healthy colony saves as it always has; an old save loads healthy',
      () {
    final json = colony().toJson();
    expect(json.containsKey('disease'), isFalse);
    expect(json.containsKey('corpses'), isFalse);

    final sick = (colony()
          ..disease = 0.3
          ..corpses = 12)
        .toJson()
      ..remove('disease')
      ..remove('corpses');
    final legacy = CitySim.fromJson(sick, bodies: bodies);
    expect(legacy.disease, 0);
    expect(legacy.corpses, 0);
  });

  test('a hand-edited save is held to the ranges the sim keeps', () {
    final json = colony().toJson()
      ..['disease'] = 3
      ..['corpses'] = -5;
    final back = CitySim.fromJson(json, bodies: bodies);
    expect(back.disease, 1.0);
    expect(back.corpses, 0);
  });
}
