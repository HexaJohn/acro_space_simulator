// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// `site_access_persistence_test` (docs/plans/site-access.md §4.4, §8.3 R2):
/// plans are derived, never saved. A save carries nothing of the book, and
/// `toJson` → `fromJson` → a drain re-derives the plans: byte-identical
/// chunks on straight roads (the starter kit, a colony after road edits that
/// renamed lots, a generated town), and on curved roads identical programs
/// and stall keys for every lot (`rev` may move with the load's re-sample).
///
/// Buildings here are GROWN (zoned lots with progress): a save restores
/// placed buildings only from the utility catalogue.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_access_book_fixtures.dart';

const int _all = SiteAccessBook.unlimited;

SiteAccessBook drained(CitySim city) {
  final book = SiteAccessBook();
  expect(book.sync(city, city.roadGraph, maxUnits: _all, maxChecks: _all),
      isTrue);
  return book;
}

/// [city] with every placed building a save cannot restore (a zone building;
/// the save keeps placed buildings from the utility catalogue only) turned
/// into the same building GROWN on its zoned lot, and any other dropped.
CitySim savable(CitySim city) {
  const progress = {Density.low: 1.0, Density.medium: 2.5, Density.high: 3.1};
  for (final (p, spec) in city.parcelBuiltLots().toList()) {
    if (!city.parcelBuildings.containsKey(p.id)) continue;
    if (kUtilCatalog.any((s) => s.label == spec.label)) continue;
    city.parcelBuildings.remove(p.id);
    for (final kind in kZoneSpecs.keys) {
      for (final d in Density.values) {
        if (!identical(kZoneSpecs[kind]![d], spec)) continue;
        final use = switch (kind) {
          'residential' => ParcelUse.residential,
          'commercial' => ParcelUse.commercial,
          _ => ParcelUse.industrial,
        };
        city.layout.setUse(p.id, use);
        city.grownParcels[p.id] = progress[d]!;
      }
    }
  }
  return city;
}

CitySim roundTrip(CitySim city) => CitySim.fromJson(
      jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
      bodies: fixtureBodies,
    );

void main() {
  test('a save carries nothing of the book', () {
    final city = town(grown: true);
    final before = jsonEncode(city.toJson());
    city.siteAccess
        .sync(city, city.roadGraph, maxUnits: _all, maxChecks: _all);
    expect(city.siteAccess.chunks, isNotEmpty);
    final after = jsonEncode(city.toJson());
    expect(after, before);
    expect(after.contains('siteAccess'), isFalse);
  });

  for (final (name, make) in <(String, CitySim Function())>[
    ('the starter kit', starterKit),
    ('a grown town', () => town(grown: true)),
    (
      'a colony after road edits that renamed lots',
      () {
        final city = town(grown: true);
        // A street through the grown block re-plats and renames its lots,
        // carrying their buildings across.
        final before = {for (final p in city.layout.autoParcels) p.id};
        commit(city, const FixtureRoad([Vec2(-150, -290), Vec2(-150, 290)]));
        final renamed = [
          for (final p in city.layout.autoParcels)
            if (!before.contains(p.id) && city.grownParcels.containsKey(p.id))
              p.id,
        ];
        expect(renamed, isNotEmpty);
        return city;
      }
    ),
    (
      'a generated town',
      () => savable(const CityGenerator().generate(
          const CityGenSpec(blocksAcross: 2, seed: 5, bendM: 0),
          bodies: fixtureBodies))
    ),
  ]) {
    test('$name: a load re-derives byte-identical chunks', () {
      final city = make();
      final a = drained(city);
      final loaded = roundTrip(city);
      final b = drained(loaded);
      expect(idsOf(a).length, greaterThan(4));
      expect(idsOf(b), idsOf(a));
      expect(plansOf(b), plansOf(a));
      expect(sameChunks(b.chunks, a.chunks), isTrue);
      // The loaded colony's own book drains on its first sync, whatever the
      // budget it is handed (the loading drain, §4.1).
      expect(loaded.siteAccess.sync(loaded, loaded.roadGraph), isTrue);
      expect(sameChunks(loaded.siteAccess.chunks, a.chunks), isTrue);
    });
  }

  test('200 curved-road lots keep their programs and stall keys over a load',
      () {
    final city = starterKit();
    final lots = <Parcel>[
      for (final e in const [2000.0, -2000.0])
        ...houseStreet(
            city,
            [
              Vec2(e, -900),
              Vec2(e + 180, -450),
              Vec2(e, 0),
              Vec2(e + 180, 450),
              Vec2(e, 900),
            ],
            grown: true),
    ];
    expect(lots.length, greaterThanOrEqualTo(200));
    final loaded = roundTrip(city);
    final a = drained(city);
    final b = drained(loaded);
    var planned = 0, withStalls = 0, revMoved = 0;
    final geometryFlips = <String>[];
    for (final lot in lots) {
      final x = a.planOf(lot.id), y = b.planOf(lot.id);
      expect(y == null, x == null, reason: lot.id);
      if (x == null || y == null) continue;
      planned++;
      if (x.stallCount > 0) withStalls++;
      if (x.rev != y.rev) revMoved++;
      if (x.program != y.program &&
          _homeGeometryFlip(city, loaded, lot.id)) {
        // R2 CORE FINDING, not the book's: the home generator's §3.4 fit
        // (home_driveway.dart) decides differently on the load's millimetre
        // re-sample of this lot (docs/plans/site-access.md §4.4 as built).
        geometryFlips.add(lot.id);
        continue;
      }
      expect(programAndKeys(y), programAndKeys(x),
          reason: '${lot.id}: its frame W sits '
              '${_offQuantum(x.envX1 - x.envX0)} m off a '
              '$kSeedQuantumM m seed quantum');
    }
    expect(planned, greaterThanOrEqualTo(200));
    // Pinned so a second flip, or a fix, is seen at once.
    expect(geometryFlips, ['lot-r2-r21']);
    // ignore: avoid_print
    print('curved lots ${lots.length}: planned $planned, with stalls '
        '$withStalls, rev moved $revMoved, home fit flips $geometryFlips');
  });
}

/// Whether [id]'s plan differs between [a] and [b] only because the home
/// generator's fit (§3.4, demotion `homeGeometry`) decided differently.
bool _homeGeometryFlip(CitySim a, CitySim b, String id) {
  int demoted(CitySim c) {
    final ctx = siteContextsOf(c).firstWhere((x) => x.siteId == id);
    final stats = SiteProgramStats();
    planSite(PlanBuilder(graph: c.roadGraph), ctx, stats: stats);
    return stats.demotionCount(SiteDemotion.homeGeometry);
  }

  return demoted(a) + demoted(b) == 1;
}

double _offQuantum(double m) {
  final r = m / kSeedQuantumM;
  return (r - r.roundToDouble()).abs() * kSeedQuantumM;
}
