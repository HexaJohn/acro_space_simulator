// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Building a colony as a sequence of steps, so a caller can paint between
/// them instead of freezing for fourteen seconds.
void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  const spec = CityGenSpec(seed: 4, blocksAcross: 2);

  test('the stepped build and the blocking one produce the same city', () {
    // The whole point of driving one implementation two ways. A second copy of
    // the pipeline behind the progress bar would drift, and the city you
    // watched being built would not be the city you got.
    final blocking = const CityGenerator().generate(spec, bodies: bodies);
    final stepped = CityBuild(spec, bodies: bodies);
    for (final _ in stepped.run()) {}

    final a = stepped.city!;
    expect(a.layout.roads.length, blocking.layout.roads.length);
    expect(a.layout.autoParcels.length, blocking.layout.autoParcels.length);
    expect(a.parcelBuildings.length, blocking.parcelBuildings.length);
    expect(a.layout.autoParcels.map((p) => p.id).toList(),
        blocking.layout.autoParcels.map((p) => p.id).toList());
  });

  test('progress only ever moves forward, and reaches 1', () {
    final build = CityBuild(spec, bodies: bodies);
    final seen = <CityGenProgress>[];
    for (final p in build.run()) {
      seen.add(p);
    }
    expect(seen, isNotEmpty);
    expect(seen.first.fraction, 0.0);
    expect(seen.last.fraction, 1.0);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].fraction, greaterThanOrEqualTo(seen[i - 1].fraction),
          reason: 'the bar went backwards at ${seen[i].phase}');
    }
    expect(seen.map((p) => p.phase).toSet().length, greaterThan(3),
        reason: 'a single phase name says nothing about what it is doing');
  });

  test('the bar spends its length where the TIME goes', () {
    // Platting is about thirteen of the fourteen seconds a six-block colony
    // takes. Weighting the phases evenly would park the bar at 20% for ten
    // seconds and then finish in a blink, which is worse than no bar.
    final build = CityBuild(spec, bodies: bodies);
    final platting = <double>[];
    for (final p in build.run()) {
      if (p.phase.contains('platting')) platting.add(p.fraction);
    }
    expect(platting, isNotEmpty);
    expect(platting.last - platting.first, greaterThan(0.6),
        reason: 'subdivision is most of the wait and must be most of the bar');
  });

  test('the city is only published when the run finishes', () {
    // A half-driven build must not be observable as a half-built city.
    final build = CityBuild(spec, bodies: bodies);
    final it = build.run().iterator;
    var steps = 0;
    while (it.moveNext() && it.current.fraction < 0.9) {
      expect(build.city, isNull, reason: 'a partial city escaped at step $steps');
      steps++;
    }
    expect(steps, greaterThan(2));
  });

  group('subdivision, one road at a time', () {
    CitySim twoStreets() {
      final c = CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: bodies,
        id: 'steps',
      );
      c.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
      c.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
      return c;
    }

    test('stepping it plats exactly what regenerate() does', () {
      final a = twoStreets()..layout.regenerate();
      final b = twoStreets();
      for (final _ in b.layout.regenerateSteps()) {}
      expect(b.layout.autoParcels.map((p) => p.id).toList(),
          a.layout.autoParcels.map((p) => p.id).toList());
    });

    test('the previous plat stands until the last step', () {
      final city = twoStreets();
      final before = city.layout.autoParcels.length;
      expect(before, greaterThan(0));
      final it = city.layout.regenerateSteps().iterator;
      it.moveNext();
      expect(city.layout.autoParcels.length, before,
          reason: 'a partially re-cut plat became visible');
      while (it.moveNext()) {}
      expect(city.layout.autoParcels.length, before);
    });
  });
}
