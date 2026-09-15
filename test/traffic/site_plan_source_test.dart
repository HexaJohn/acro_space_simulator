// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The plan source seam (docs/plans/t4a-implementation.md §1.1): the
/// colony's book and the synthetic fixtures must look the same to traffic,
/// or everything built on the fixtures behaves differently on real plans.
library;

import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_plan_source.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';
import 'traffic_fixture.dart';

void main() {
  test('BookPlanSource answers exactly as the book does (starter kit)', () {
    final city = starterKit();
    final book = city.siteAccess;
    final g = city.roadGraph;
    final src = BookPlanSource(book);

    expect(src.sitesRev, book.sitesRev);
    expect(src.chunks.length, book.chunks.length);
    expect(src.chunks, isNotEmpty, reason: 'the founding drains the book');
    for (var c = 0; c < src.chunks.length; c++) {
      expect(identical(src.chunks[c], book.chunks[c]), isTrue,
          reason: 'chunks are compared by identity, so they must BE the '
              "book's");
    }
    var sites = 0;
    for (final chunk in src.chunks) {
      for (var k = 0; k < chunk.siteCount; k++) {
        final id = chunk.siteId(k);
        sites++;
        expect(src.slotOf(id), book.slotOf(id));
        expect(src.planOf(id)?.rev, book.planOf(id)?.rev);
        expect(src.planOf(id)?.siteId, id);
        expect(src.isCurrentFor(id, g), book.isCurrentFor(id, g));
        expect(src.isCurrentFor(id, g), isTrue);
      }
    }
    expect(sites, greaterThan(0));
    expect(src.planOf('no-such-lot'), isNull);
    expect(src.slotOf('no-such-lot'), -1);
  });

  group('FixturePlanSource', () {
    late FixturePlanSource src;
    late RoadGraph graph;

    setUp(() {
      final city = starterKit();
      graph = city.roadGraph;
      src = FixturePlanSource(graph, {'lot-r0x1-l7': SyntheticTemplate.strip});
    });

    test('a template stands on its lot, current, at slot 0', () {
      expect(src.sitesRev, 1);
      expect(src.slotOf('lot-r0x1-l7'), 0);
      expect(src.chunks, hasLength(1));
      final p = src.planOf('lot-r0x1-l7')!;
      expect(p.siteId, 'lot-r0x1-l7');
      expect(p.program, SiteProgram.carPark);
      expect(p.stallCount, greaterThan(0));
      expect(src.isCurrentFor('lot-r0x1-l7', graph), isTrue);
      expect(src.planOf('lot-r0x1-l4'), isNull);
      expect(src.slotOf('lot-r0x1-l4'), -1);
    });

    test('replace bumps sitesRev, republishes the chunk and keeps slots', () {
      final was = src.chunks[0];
      src.replace('lot-r0x1-l4', SyntheticTemplate.home);
      expect(src.sitesRev, 2);
      expect(identical(src.chunks[0], was), isFalse,
          reason: 'a changed site publishes a NEW chunk');
      expect(src.slotOf('lot-r0x1-l7'), 0, reason: 'a slot is kept for life');
      expect(src.slotOf('lot-r0x1-l4'), 1);
      expect(src.planOf('lot-r0x1-l4')!.program, SiteProgram.homeDriveway);
      expect(src.planOf('lot-r0x1-l7')!.program, SiteProgram.carPark);

      // The same template again is no change at all, as an unchanged site's
      // check is not.
      final rev = src.sitesRev;
      final chunk = src.chunks[0];
      src.replace('lot-r0x1-l4', SyntheticTemplate.home);
      expect(src.sitesRev, rev);
      expect(identical(src.chunks[0], chunk), isTrue);

      // Cleared: the plan goes, its slot frees, and the rows behind it move
      // up while every other slot stands.
      src.replace('lot-r0x1-l7', null);
      expect(src.sitesRev, rev + 1);
      expect(src.planOf('lot-r0x1-l7'), isNull);
      expect(src.slotOf('lot-r0x1-l7'), -1);
      expect(src.slotOf('lot-r0x1-l4'), 1);
      expect(src.planOf('lot-r0x1-l4')!.program, SiteProgram.homeDriveway);

      // The lowest free slot is taken again by the next site.
      src.replace('lot-r0x1-l5', SyntheticTemplate.homeTandem);
      expect(src.slotOf('lot-r0x1-l5'), 0);
      expect(src.planOf('lot-r0x1-l5')!.stallCount, 2);
    });

    test('a stale site is not current, and its plan is still readable', () {
      src.markStale('lot-r0x1-l7');
      expect(src.isCurrentFor('lot-r0x1-l7', graph), isFalse);
      expect(src.planOf('lot-r0x1-l7'), isNotNull,
          reason: 'cars inside it keep reading the old chunk (§0 Q5)');
      src.markStale('lot-r0x1-l7', stale: false);
      expect(src.isCurrentFor('lot-r0x1-l7', graph), isTrue);
    });

    test('an empty source is empty, and answers nothing', () {
      final empty = FixturePlanSource(graph, const {});
      expect(empty.sitesRev, 0);
      expect(empty.chunks, isEmpty);
      expect(empty.planOf('lot-r0x1-l7'), isNull);
      expect(empty.slotOf('lot-r0x1-l7'), -1);
      expect(empty.isCurrentFor('lot-r0x1-l7', graph), isFalse);
    });
  });
}
