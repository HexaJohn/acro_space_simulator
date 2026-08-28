// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'dart:math' as math;

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

  test('zoning is stepped, not one opaque call', () {
    // The zone-and-build loop is seconds of work on a big colony. Run as one
    // call between two yields, the studio painted "zoning and building" and
    // then nothing moved until "settling" — a freeze with a caption.
    final build = CityBuild(spec, bodies: bodies);
    var zoningSteps = 0;
    for (final p in build.run()) {
      if (p.phase == 'zoning and building') zoningSteps++;
    }
    expect(zoningSteps, greaterThan(10),
        reason: 'one yield per phase is a frozen label, not progress');
  });

  test('the live sim is peekable mid-zoning while the result stays null', () {
    // Slow mode draws the build as it happens, and it draws from `partial` —
    // the buildings have to be on it DURING zoning, while `city` (the
    // finished-colony contract) is still unpublished.
    final build = CityBuild(spec, bodies: bodies);
    var sawBuildingsArrive = false;
    for (final p in build.run()) {
      if (p.phase != 'zoning and building') continue;
      expect(build.city, isNull);
      final live = build.partial;
      expect(live, isNotNull);
      if (live!.parcelBuildings.isNotEmpty) sawBuildingsArrive = true;
    }
    expect(sawBuildingsArrive, isTrue,
        reason: 'nothing to watch: no building ever appeared on the live sim');
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

  test('a road drapes on ground sampled at the spacing it was GRADED at', () {
    // The drape used to query the ground every 6 m. A ground query on a built
    // colony marches through every brush covering the point — 8 ms each once
    // the shaper has laid ~1,800 of them — so a four-block city spent 43 s of
    // a 46 s generate here, all of it after the progress bar had finished.
    //
    // 24 m is not a coarser approximation: `CityTerrainShaper` lays one
    // cut-fill brush per 24 m of corridor, so the graded ground under a road
    // IS piecewise-linear at that spacing and nothing lives between the
    // samples to be missed.
    final sim = const CityGenerator()
        .generate(const CityGenSpec(seed: 2, blocksAcross: 2), bodies: bodies);
    final system = RealSolarSystem.build();
    final body = system.body(sim.body.id)!;
    final edits = InMemoryTerrainEditsRepository();
    for (final p in const CityTerrainShaper().pending(sim,
        bodyRadiusM: body.radius,
        groundRadiusAt: (d) {
          final f = body.terrainFieldWith(edits.forBody(body.id));
          return f == null ? body.radius : f.groundRadiusAt(d.x, d.y, d.z);
        })) {
      edits.record(body.id, p.brush);
      sim.shapedTerrain.add(p.key);
    }

    final snap = WorldSnapshot.capture(1, InMemoryVesselRepository(const []),
        system: system,
        cities: InMemoryCityRepository([sim]),
        terrainEdits: edits);
    expect(snap.roads, isNotEmpty);

    // The drape must still FOLLOW the ground rather than hold one height —
    // that is the whole reason it samples per point — and it must stay smooth,
    // because a road that steps between samples reads as a staircase.
    var draped = 0;
    for (final r in snap.roads) {
      final radii = <double>[];
      for (var i = 0; i + 2 < r.points.length; i += 3) {
        radii.add(math.sqrt(r.points[i] * r.points[i] +
            r.points[i + 1] * r.points[i + 1] +
            r.points[i + 2] * r.points[i + 2]));
      }
      if (radii.length < 3) continue;
      final lo = radii.reduce(math.min), hi = radii.reduce(math.max);
      if (hi - lo > 0.05) draped++;
      for (var i = 1; i < radii.length; i++) {
        expect((radii[i] - radii[i - 1]).abs(), lessThan(6.0),
            reason: 'the drape stepped: interpolation is not running');
      }
    }
    expect(draped, greaterThan(0),
        reason: 'every road came out dead flat — the drape is not sampling');
  });
}
