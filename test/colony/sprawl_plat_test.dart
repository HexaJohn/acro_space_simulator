// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The sprawl is plat: every section's streets, lots and buildings are the
/// layout's own, cut by the same subdivider as the downtown's.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final system = RealSolarSystem.build();
  final bodies = system.all.where((b) => !b.isStar).toList();
  const spec = CityGenSpec(blocksAcross: 2, seed: 9, sprawlMiles: 6);

  late CitySim city;
  late SprawlPlan plan;
  late int buildMs;
  setUpAll(() {
    final sw = Stopwatch()..start();
    city = const CityGenerator().generate(spec, bodies: bodies);
    buildMs = sw.elapsedMilliseconds;
    plan = city.sprawl!;
  });

  List<RoadSpline> suburban() =>
      city.layout.roads.where((r) => r.lotFrontageM != null).toList();

  test('the sections are streets, lots and houses of the layout', () {
    final streets = suburban();
    expect(streets.length, greaterThan(200));
    expect(streets.every((r) => r.roadClass == RoadClass.street), isTrue);
    expect(streets.any((r) => r.collector), isTrue);
    final ids = {for (final r in streets) CityGenerator.baseRoadId(r.id)};
    final lots = city.layout.autoParcels
        .where((p) =>
            p.roadId != null && ids.contains(CityGenerator.baseRoadId(p.roadId!)))
        .toList();
    expect(lots.length, greaterThan(2000));
    expect(lots.every((p) => p.use != ParcelUse.unzoned), isTrue);
    final built =
        lots.where((p) => city.parcelBuildings.containsKey(p.id)).length;
    expect(built, greaterThan(lots.length ~/ 4));
    // A house lot's frontage, not a downtown assemblage's.
    final houseLot = lots.firstWhere((p) => p.use == ParcelUse.residential);
    expect(houseLot.frontageWidth, lessThan(34));
  });

  test('a collector runs out to the county highway and ends on its junction',
      () {
    final highways = city.layout.roads
        .where((r) => r.roadClass == RoadClass.avenue && !r.platsLots)
        .toList();
    expect(highways, isNotEmpty);
    var joined = 0;
    for (final r in city.layout.roads.where((r) => r.collector)) {
      final s = city.layout.roadIndex.byId(r.id)!;
      for (final end in [s.sampleAt(0), s.sampleAt(s.sampleCount - 1)]) {
        // A highway piece ends where the collector does: a real junction.
        if (highways.any((h) {
          final hs = city.layout.roadIndex.byId(h.id)!;
          return hs.sampleAt(0).distanceTo(end) < 1.5 ||
              hs.sampleAt(hs.sampleCount - 1).distanceTo(end) < 1.5;
        })) {
          joined++;
        }
      }
    }
    expect(joined, greaterThan(4));
  });

  test('no street runs in an interstate corridor or over a staked plot', () {
    final corridors = city.layout.roads
        .where((r) => r.roadClass.isExpressway || r.roadClass == RoadClass.ramp)
        .map((r) => city.layout.roadIndex.byId(r.id)!.samples)
        .toList();
    expect(corridors, isNotEmpty);
    double toCorridor(Vec2 p) {
      var best = double.infinity;
      for (final c in corridors) {
        for (var i = 1; i < c.length; i++) {
          final a = c[i - 1], b = c[i];
          final ab = b - a;
          final len2 = ab.dot(ab);
          final t = len2 < 1e-12
              ? 0.0
              : ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
          final d = (a + ab * t).distanceTo(p);
          if (d < best) best = d;
        }
      }
      return best;
    }

    for (final r in suburban()) {
      for (final p in r.sample(stepM: 30)) {
        expect(toCorridor(p), greaterThan(30), reason: '${r.id} at $p');
        expect(plan.spec.inClearing(p), isFalse, reason: '${r.id} at $p');
      }
    }
  });

  test('farmland is quarter-section farms; the strip is malls on plots', () {
    final farms = city.parcelBuildings.values
        .where((s) => s.type == 'farm' && s.siteWidthM >= 700)
        .length;
    expect(farms, greaterThan(0));
    final strips = city.parcelBuildings.values
        .where((s) => identical(s, kStripMallSpec))
        .length;
    expect(strips, greaterThan(0));
    // A strip faces its arterial: its plot has a frontage.
    final strip = city.parcelBuildings.entries
        .firstWhere((e) => identical(e.value, kStripMallSpec));
    expect(city.parcelById(strip.key)!.frontage, isNotNull);
  });

  test('the sprawl is draped, not graded: the shaper lays nothing for it', () {
    final streets = suburban();
    expect(streets.every((r) => !r.graded), isTrue);
    final ids = {for (final r in streets) CityGenerator.baseRoadId(r.id)};
    final pending = const CityTerrainShaper().pending(city,
        bodyRadiusM: 6371000, groundRadiusAt: (_) => 6371000);
    expect(pending, isNotEmpty, reason: 'the downtown is still graded');
    for (final p in pending) {
      if (p.key.startsWith('road:')) {
        final rid = p.key.substring(5, p.key.lastIndexOf(':'));
        expect(ids.contains(CityGenerator.baseRoadId(rid)), isFalse,
            reason: '${p.key} grades a suburb street');
      } else if (p.key.startsWith('pad:')) {
        final lot = city.parcelById(p.key.substring(4))!;
        expect(lot.graded, isTrue, reason: '${p.key} levels a draped lot');
        expect(city.parcelBuildings[lot.id],
            isNot(same(kStripMallSpec)),
            reason: 'a strip mall follows the land');
      }
    }
    // A few thousand brushes for the downtown, not tens of thousands for
    // the sprawl: the terrain streamer refines around every one.
    expect(pending.length, lessThan(4000), reason: '${pending.length} brushes');
  });

  test('the same seed plats the same sprawl', () {
    final b = const CityGenerator().generate(spec, bodies: bodies);
    expect(b.layout.roads.length, city.layout.roads.length);
    expect(b.layout.autoParcels.length, city.layout.autoParcels.length);
    expect(b.parcelBuildings.length, city.parcelBuildings.length);
  });

  test('six miles of sprawl plats in seconds', () {
    expect(buildMs, lessThan(30000),
        reason: '${city.layout.roads.length} roads, '
            '${city.layout.autoParcels.length} lots in $buildMs ms');
  });
}
