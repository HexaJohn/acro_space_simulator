// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The studio's city has to be a REAL one.
///
/// A lookalike would profile the wrong thing and tune the wrong look. These
/// pin the properties that make a generated colony worth measuring: it is
/// built through the same editor paths a player uses, it is deterministic in
/// its seed, and it actually functions.
void main() {
  final bodies =
      RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  const gen = CityGenerator();

  CitySim build([CityGenSpec spec = const CityGenSpec()]) =>
      gen.generate(spec, bodies: bodies);

  test('it lays a real street network with real junctions', () {
    final city = build(const CityGenSpec(blocksAcross: 3));
    // Roads SPLIT at their crossings, so a 4x4 layout yields far more road
    // objects than the eight lines drawn — that split is the topology the
    // junction furniture and the lot subdivider both read.
    expect(city.layout.roads.length, greaterThan(8));
    expect(city.layout.autoParcels, isNotEmpty);
  });

  test('it builds most of what it subdivides, and orphans nothing', () {
    final city = build(const CityGenSpec(blocksAcross: 3));
    expect(city.parcelBuildings.length, greaterThan(20));
    // EVERY building sits on a lot the layout still knows about. Staking a big
    // plot re-cuts the subdivision around it and renames lots; a building left
    // keyed to a vanished one is invisible, unpowered and unreachable.
    for (final id in city.parcelBuildings.keys) {
      expect(city.parcelById(id), isNotNull, reason: 'orphan building $id');
    }
  });

  test('the same seed builds the same city', () {
    // The whole point of a profiling harness: two runs must be comparable.
    final a = build(const CityGenSpec(seed: 7, blocksAcross: 3));
    final b = build(const CityGenSpec(seed: 7, blocksAcross: 3));
    expect(b.layout.roads.length, a.layout.roads.length);
    expect(b.parcelBuildings.length, a.parcelBuildings.length);
    expect(b.layout.autoParcels.length, a.layout.autoParcels.length);
  });

  test('a different seed builds a different city', () {
    final a = build(const CityGenSpec(seed: 7, blocksAcross: 3));
    final b = build(const CityGenSpec(seed: 8, blocksAcross: 3));
    expect(b.parcelBuildings.keys.toSet(),
        isNot(equals(a.parcelBuildings.keys.toSet())));
  });

  test('blocksAcross is the performance dial it claims to be', () {
    final small = build(const CityGenSpec(blocksAcross: 2));
    final big = build(const CityGenSpec(blocksAcross: 4));
    expect(big.parcelBuildings.length,
        greaterThan(small.parcelBuildings.length));
  });

  test('the colony FUNCTIONS: connected, staffed, drawing power', () {
    // The aggregates live in `advance`, not `recompute`, so the generator
    // ticks once before handing the city back — otherwise it reports zero of
    // everything and reads as dead.
    final city = build(const CityGenSpec(blocksAcross: 3));
    // Something is wired to the network rather than a field of orphans.
    final served = city.parcelBuildings.keys
        .where((id) => city.siteConnected(id))
        .length;
    expect(served, greaterThan(10), reason: 'nothing reaches the road network');
    expect(city.powerDraw, greaterThan(0));
    expect(city.jobs + city.housing, greaterThan(0));
  });

  test('it advances on a tick without falling over', () {
    final city = build(const CityGenSpec(blocksAcross: 2));
    for (var i = 0; i < 20; i++) {
      city.advance(0.5);
    }
    expect(city.population, isNot(isNaN));
    expect(city.funds, isNot(isNaN));
  });

  test('sprawling installations claim their own plots outside the streets', () {
    final city = build(const CityGenSpec(blocksAcross: 3, installations: 3));
    final claimed = city.parcelBuildings.entries
        .where((e) => e.value.claimsOwnSite)
        .toList();
    expect(claimed, isNotEmpty, reason: 'no big installations placed');
    for (final e in claimed) {
      expect(city.parcelById(e.key)?.manual, isTrue,
          reason: 'a claimed site should be its own manual plot');
    }
  });

  test('it can be built on an airless world, and seals its roads there', () {
    final moon = build(const CityGenSpec(bodyId: 'moon', blocksAcross: 2));
    expect(moon.body.id, const BodyId('moon'));
    expect(moon.layout.roads.every((r) => r.sealed), isTrue,
        reason: 'vacuum outside — pedestrians need tubes');
  });

  test('a big city builds in seconds, not minutes', () {
    // A guard on the batching, not a benchmark. Laying a network used to
    // re-subdivide every lot on EVERY road commit, and staking a plot did it
    // again per plot: a full-size city took over two minutes and froze the app
    // solid while it worked. Deferring both re-cuts to one pass each brought
    // it to about twelve seconds. If this ever fails, a caller has started
    // re-cutting per operation again.
    final sw = Stopwatch()..start();
    build(const CityGenSpec(blocksAcross: 6, buildFraction: 1.0,
        installations: 10));
    sw.stop();
    expect(sw.elapsed.inSeconds, lessThan(20),
        reason: 'generation regressed to per-operation re-subdivision');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a deferred re-cut still produces the same city', () {
    // Batching must be an optimisation, not a different result.
    final a = build(const CityGenSpec(seed: 3, blocksAcross: 3));
    final b = build(const CityGenSpec(seed: 3, blocksAcross: 3));
    expect(b.layout.parcels.length, a.layout.parcels.length);
    expect(b.parcelBuildings.length, a.parcelBuildings.length);
    for (final id in a.parcelBuildings.keys) {
      expect(b.parcelBuildings.containsKey(id), isTrue);
      expect(b.parcelById(id), isNotNull, reason: 'orphan after batching');
    }
  });

  test('density steps DOWN from the middle to the outskirts', () {
    // A colony zoned at one density everywhere reads as a housing estate
    // however big it gets. Towers downtown, terraces around them, detached
    // houses at the edge.
    final city = build(const CityGenSpec(blocksAcross: 5, buildFraction: 1.0));
    final edge = const CityGenSpec(blocksAcross: 5).extentM * 0.5;

    var innerIntensity = 0.0, innerN = 0;
    var outerIntensity = 0.0, outerN = 0;
    for (final e in city.parcelBuildings.entries) {
      if (e.value.claimsOwnSite) continue; // installations are not zoned
      final lot = city.parcelById(e.key);
      if (lot == null) continue;
      final r = lot.centroid.length;
      final intensity = (e.value.housing + e.value.jobs).toDouble();
      if (r < edge * 0.35) {
        innerIntensity += intensity;
        innerN++;
      } else if (r > edge * 0.85) {
        outerIntensity += intensity;
        outerN++;
      }
    }
    expect(innerN, greaterThan(3), reason: 'need a downtown to measure');
    expect(outerN, greaterThan(3), reason: 'need an edge to measure');
    expect(innerIntensity / innerN, greaterThan(outerIntensity / outerN),
        reason: 'the middle must be denser than the outskirts');
  });

  test('a dense building takes more of its lot than a sparse one', () {
    // Setback and coverage both follow density, so the gap around a tower is
    // not the gap around a bungalow.
    final low = kZoneSpecs['residential']![Density.low]!;
    final high = kZoneSpecs['residential']![Density.high]!;
    expect(lotSetbackFor(high), lessThan(lotSetbackFor(low)));
    expect(lotCoverageFor(high), greaterThan(lotCoverageFor(low)));
    // And nothing is inset less than the terrace edge allows.
    for (final s in [low, high]) {
      expect(lotSetbackFor(s), greaterThanOrEqualTo(kLotSetbackM));
    }
  });

  test('a dense lot yields a bigger footprint than a sparse one', () {
    // The end result the two rules exist for, measured through the snapshot
    // the renderer actually reads.
    final city = build(const CityGenSpec(blocksAcross: 3, buildFraction: 1.0));
    final lot = city.layout.autoParcels.first;
    BuildingSnapshot snap(CityBuildingSpec s) {
      city.parcelBuildings[lot.id] = s;
      return BuildingSnapshot.ofParcel(city, lot, s, city.body,
          siteRadiusM: city.body.radius);
    }
    final low = snap(kZoneSpecs['residential']![Density.low]!);
    final high = snap(kZoneSpecs['residential']![Density.high]!);
    expect(high.siteWidthM * high.siteDepthM,
        greaterThan(low.siteWidthM * low.siteDepthM),
        reason: 'higher density should use more of the same lot');
  });

  test('an Earth colony is sited on LAND, not in the sea', () {
    // 0N 0E is the Gulf of Guinea. Sited there, a generated city stood on the
    // sea floor and the studio showed a grid of houses on open water.
    final earth = RealSolarSystem.build().require(const BodyId('earth'));
    final field = earth.terrainField!;
    for (final seed in [1, 2, 7, 40]) {
      final site = CityGenerator.dryLandNear(earth, seed: seed);
      final la = site.lat * math.pi / 180, lo = site.lon * math.pi / 180;
      final d = Vector3(math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo),
          math.sin(la));
      expect(field.groundRadiusAt(d.x, d.y, d.z), greaterThan(field.seaRadius),
          reason: 'seed $seed put the colony underwater');
    }
  });

  test('a generated Earth city stands above the waterline', () {
    final city = build(const CityGenSpec(bodyId: 'earth', blocksAcross: 2));
    final earth = RealSolarSystem.build().require(const BodyId('earth'));
    final field = earth.terrainField!;
    final la = city.cityLat * math.pi / 180, lo = city.cityLon * math.pi / 180;
    final d = Vector3(math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo),
        math.sin(la));
    expect(field.groundRadiusAt(d.x, d.y, d.z), greaterThan(field.seaRadius));
  });

  test('an airless world takes the first site it looks at', () {
    // No sea means every sample passes, so the search must not spin.
    final moon = RealSolarSystem.build().require(const BodyId('moon'));
    expect(() => CityGenerator.dryLandNear(moon, seed: 3), returnsNormally);
  });

  test('every zone type actually gets built', () {
    // Measured before this was fixed: 72% of the colony was `i-low`, and
    // `r-low`, `c-low`, `i-med` and `i-high` never appeared at all. Three
    // consequences, none obvious from reading the code: no low-density housing
    // anywhere, no heavy industry, and — because chain-link fencing is carried
    // only by `i-med` and `i-high` — not a single fenced yard in the city.
    final city = build(const CityGenSpec(blocksAcross: 5, buildFraction: 1.0));
    final counts = <String, int>{};
    for (final e in city.parcelBuildings.entries) {
      if (e.value.claimsOwnSite) continue;
      counts[e.value.type] = (counts[e.value.type] ?? 0) + 1;
    }
    for (final kind in ['r', 'c', 'i']) {
      for (final d in ['low', 'med', 'high']) {
        expect(counts['$kind-$d'] ?? 0, greaterThan(0),
            reason: '$kind-$d is never built');
      }
    }
    // And none of them runs away with the city.
    final total = counts.values.fold(0, (a, b) => a + b);
    for (final e in counts.entries) {
      expect(e.value / total, lessThan(0.4),
          reason: '${e.key} is ${(e.value / total * 100).round()}% of the city');
    }
  });
}
