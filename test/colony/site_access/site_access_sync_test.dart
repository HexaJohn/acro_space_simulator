// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// `site_access_sync_test` (docs/plans/site-access.md §4.1–§4.3, §8.3 R2):
/// the book's resumable sync. A full drain packs what the dispatch packs; a
/// road edit queues only the built lots in its dirty box; a stale plan still
/// draws but is not current, so traffic reads it as kerbside; the
/// easement-priority sites are checked first, outside the budgets; budgets
/// are counted, and a budgeted sync ends byte-identical to a drain; chunks
/// are copy-on-write; renames keep `rev` and slots; clears drop at once.
///
/// Written against dispatch behaviour that holds for the generator stubs and
/// the real generators alike.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:acro_space_simulator/domain/colony/city/spatial_index.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_access_book_fixtures.dart';
import 'site_plan_fixtures.dart';

const int _all = SiteAccessBook.unlimited;

void drain(CitySim city, SiteAccessBook book) {
  expect(book.sync(city, city.roadGraph, maxUnits: _all, maxChecks: _all),
      isTrue);
}

/// The built lots of [city], by id.
List<String> builtLots(CitySim city) => [
      for (final (p, _) in city.parcelBuiltLots()) p.id,
    ];

void main() {
  group('a drain', () {
    test('plans every built site, packed byte for byte as the dispatch packs',
        () {
      final city = town();
      final book = SiteAccessBook(validate: true);
      drain(city, book);
      final fresh = planCity(city);
      expect(idsOf(book), [for (final c in fresh) ...c.siteIds]);
      expect(sameChunks(book.chunks, fresh), isTrue);
      // Every plan passes V1–V13 at the graph it was resolved against.
      final g = city.roadGraph;
      final spans = SyntheticSites.laneSpansOf(g);
      for (final c in book.chunks) {
        for (var k = 0; k < c.siteCount; k++) {
          final p = c.plan(k);
          expect(SitePlanValidator.validate(p, graph: g, laneSpans: spans),
              isEmpty,
              reason: p.siteId);
          expect(book.isCurrentFor(p.siteId, g), isTrue);
          expect(book.slotOf(p.siteId), k);
        }
      }
      // A second sync with nothing changed does nothing.
      final before = book.chunks.toList();
      final rev = book.sitesRev;
      expect(book.sync(city, city.roadGraph), isTrue);
      expect(book.lastSync.generated, 0);
      expect(book.lastSync.chunks, 0);
      expect(book.sitesRev, rev);
      for (var i = 0; i < before.length; i++) {
        expect(identical(book.chunks[i], before[i]), isTrue);
      }
    });

    test('the starter kit drains inside CityStarterKit.found', () {
      final city = starterKit();
      final book = city.siteAccess;
      expect(idsOf(book), [for (final c in planCity(city)) ...c.siteIds]);
      for (final id in builtLots(city)) {
        expect(book.isCurrentFor(id, city.roadGraph), isTrue, reason: id);
      }
    });
  });

  group('budgets (§4.3, counted)', () {
    test('a budgeted sync resumes, and ends byte-identical to a drain', () {
      final a = town(), b = town();
      drain(a, a.siteAccess);
      var ticks = 0;
      var done = false;
      while (!done) {
        done = b.siteAccess.sync(b, b.roadGraph, maxUnits: 16, maxChecks: 24);
        final s = b.siteAccess.lastSync;
        // At least one plan per call; never over the budget otherwise.
        expect(s.checks, lessThanOrEqualTo(24));
        if (s.generated > 1) expect(s.units, lessThanOrEqualTo(16));
        ticks++;
        expect(ticks, lessThan(500));
      }
      expect(ticks, greaterThan(4));
      expect(idsOf(b.siteAccess), idsOf(a.siteAccess));
      expect(sameChunks(b.siteAccess.chunks, a.siteAccess.chunks), isTrue);
    });

    test('a check budget under one hashed check still finishes a road edit',
        () {
      final city = town();
      houseStreet(city, const [Vec2(1500, -150), Vec2(1500, 150)]);
      drain(city, city.siteAccess);
      commit(city, const FixtureRoad([Vec2(1650, -150), Vec2(1650, 150)]));
      var done = false;
      for (var tick = 0; tick < 20000 && !done; tick++) {
        done = city.siteAccess.sync(city, city.roadGraph, maxChecks: 1);
      }
      expect(done, isTrue);
    });

    test('the default budget is 128 units and 4096 checks', () {
      expect(SiteAccessBook.defaultUnitsPerTick, 128);
      expect(SiteAccessBook.defaultChecksPerTick, 4096);
      final city = town();
      city.siteAccess.sync(city, city.roadGraph);
      expect(city.siteAccess.lastSync.units, lessThanOrEqualTo(128));
    });
  });

  group('a road edit (§4.2)', () {
    // Houses on a far street X (e = 1500); a second street Y (e = 1650)
    // then puts only X's east row inside Y's dirty box.
    (CitySim, List<Parcel>, List<Parcel>) setUp() {
      final city = town();
      final x = houseStreet(city, const [Vec2(1500, -150), Vec2(1500, 150)]);
      drain(city, city.siteAccess);
      final east = [for (final p in x) if (p.centroid.e > 1500) p];
      final west = [for (final p in x) if (p.centroid.e < 1500) p];
      expect(east, isNotEmpty);
      expect(west, isNotEmpty);
      commit(city, const FixtureRoad([Vec2(1650, -150), Vec2(1650, 150)]));
      return (city, east, west);
    }

    test('queues only the built lots in its dirty box', () {
      final (city, east, west) = setUp();
      final book = city.siteAccess;
      final g = city.roadGraph;
      book.sync(city, g, maxChecks: 0, maxUnits: 0);
      for (final p in east) {
        expect(book.isStale(p.id), isTrue, reason: p.id);
      }
      for (final p in west) {
        expect(book.isStale(p.id), isFalse, reason: p.id);
      }
      // The starter town is far from both streets.
      for (final id in builtLots(city)) {
        if (id.startsWith('lot-r2')) continue;
        expect(book.isStale(id), isFalse, reason: id);
      }
      // What the rule says, from the geometry: the queued lots meet the new
      // road's box inflated by the corridor reach; the others do not.
      final road = g.roads.last;
      final reach = SiteAccessBook.dirtyReachM;
      final roadBox =
          Box2.of(road.controls).grow(reach + road.roadClass.halfWidth);
      for (final p in east) {
        expect(Box2.of(p.polygon).within(roadBox, 0), isTrue);
      }
      for (final p in west) {
        expect(Box2.of(p.polygon).within(roadBox, 0), isFalse);
      }
    });

    test('a stale plan still draws but is not current; a re-check makes it '
        'current', () {
      final (city, east, west) = setUp();
      final book = city.siteAccess;
      final g = city.roadGraph;
      book.sync(city, g, maxChecks: 0, maxUnits: 0);
      for (final p in [...east, ...west]) {
        // The old plan is still there to draw...
        expect(book.planOf(p.id), isNotNull, reason: p.id);
        // ...but traffic reads it as kerbside at g's slot 0.
        expect(book.isCurrentFor(p.id, g), isFalse, reason: p.id);
      }
      expect(book.sync(city, g, maxUnits: _all, maxChecks: _all), isTrue);
      for (final id in builtLots(city)) {
        expect(book.isCurrentFor(id, g), isTrue, reason: id);
        expect(book.isStale(id), isFalse);
      }
    });

    test('checks the easement-priority sites first, outside both budgets', () {
      final (city, east, _) = setUp();
      final book = city.siteAccess;
      final g = city.roadGraph;
      final priority = [
        for (var lot = 0; lot < g.lotCount; lot++)
          if (g.lotJoinStart[lot] < g.lotJoinStart[lot + 1] &&
              g.joinFlags[g.lotJoinStart[lot]] & kJoinEasement != 0)
            g.lotIds[lot],
      ];
      // The four starter installations sit behind their auto-lot rows.
      expect(priority, hasLength(4));
      book.sync(city, g, maxChecks: 0, maxUnits: 0);
      expect(book.lastSync.priorityChecks, 4);
      for (final id in priority) {
        expect(book.isCurrentFor(id, g), isTrue, reason: id);
      }
      expect(book.isCurrentFor(east.first.id, g), isFalse);
    });

    test('an easement-priority site inside the dirty box is current after its '
        'priority check, and costs the queue nothing', () {
      // A street through the grown block puts the starter installations
      // behind it inside its dirty box.
      final city = town(grown: true);
      final book = city.siteAccess;
      drain(city, book);
      commit(city, const FixtureRoad([Vec2(-150, -290), Vec2(-150, 290)]));
      final g = city.roadGraph;
      final priority = [
        for (var lot = 0; lot < g.lotCount; lot++)
          if (g.lotJoinStart[lot] < g.lotJoinStart[lot + 1] &&
              g.joinFlags[g.lotJoinStart[lot]] & kJoinEasement != 0)
            g.lotIds[lot],
      ];
      expect(priority, hasLength(4));
      book.sync(city, g, maxChecks: 0, maxUnits: 0);
      expect(book.lastSync.priorityChecks, 4);
      expect(book.lastSync.checks, 0);
      for (final id in priority) {
        expect(book.isStale(id), isFalse, reason: id);
        expect(book.isCurrentFor(id, g), isTrue, reason: id);
      }
      // Some other lot of the box is still waiting.
      expect(builtLots(city).where(book.isStale), isNotEmpty);
      final before = {
        for (final id in priority) id: (book.planOf(id)!.rev, book.slotOf(id)),
      };
      drain(city, book);
      for (final id in priority) {
        expect((book.planOf(id)!.rev, book.slotOf(id)), before[id]);
        expect(book.isCurrentFor(id, g), isTrue, reason: id);
      }
    });

    test('a re-check that finds the same inputs keeps rev and slot', () {
      final (city, _, west) = setUp();
      final book = city.siteAccess;
      final before = {
        for (final p in west) p.id: (book.planOf(p.id)!.rev, book.slotOf(p.id)),
      };
      drain(city, book);
      for (final p in west) {
        final plan = book.planOf(p.id)!;
        expect((plan.rev, book.slotOf(p.id)), before[p.id]);
        expect(plan.graphStamp, city.roadGraph.structureStamp);
        expect(plan.graphLot, city.roadGraph.lotNoOf(p.id));
      }
    });
  });

  group('a road edit on a two-chunk town (§4.2 bench levers, R2 integration)',
      () {
    // A generated town of 1,420 sites: two chunks, so a tick can re-publish
    // one chunk while the other waits.
    (CitySim, SiteAccessBook) edited() {
      final city = const CityGenerator().generate(
          const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 4),
          bodies: fixtureBodies);
      final book = SiteAccessBook();
      drain(city, book);
      expect(book.chunks.length, 2);
      commit(city, const FixtureRoad([Vec2(-400, 55), Vec2(400, 55)]));
      return (city, book);
    }

    test('the tick that diffs a structure change checks nothing else', () {
      final (city, book) = edited();
      expect(book.sync(city, city.roadGraph), isFalse);
      expect(book.lastSync.checks, 0);
      expect(book.lastSync.generated, 0);
    });

    test('budgeted ticks hash at most 4096 / 8 sites, re-pack at most one '
        'chunk whole, share the columns a re-resolution keeps, and end equal '
        'to a fresh drain', () {
      final (city, book) = edited();
      final g = city.roadGraph;
      var ticks = 0, shared = 0, done = false;
      while (!done) {
        final before = book.chunks.toList();
        final copies = [for (final c in before) copyOf(c)];
        done = book.sync(city, g);
        final s = book.lastSync;
        expect(
            s.checks, lessThanOrEqualTo(SiteAccessBook.defaultChecksPerTick));
        expect(s.resolved, lessThanOrEqualTo(4096 ~/ 8));
        var whole = 0;
        for (var i = 0; i < before.length; i++) {
          final now = book.chunks[i];
          // A published chunk is never written, whatever replaced it.
          expect(unchanged(before[i], copies[i]), isTrue);
          if (identical(now, before[i])) continue;
          final keptF64 =
              identical(now.debugRetained[0], before[i].debugRetained[0]);
          if (keptF64) {
            shared++;
          } else {
            whole++;
          }
        }
        expect(whole, lessThanOrEqualTo(1),
            reason: 'tick $ticks: ${s.toJson()}');
        ticks++;
        expect(ticks, lessThan(500));
      }
      expect(shared, greaterThan(0));
      final fresh = SiteAccessBook();
      drain(city, fresh);
      expect(plansJsonOf(book), plansJsonOf(fresh));
      for (final id in plansJsonOf(fresh).keys) {
        expect(book.isCurrentFor(id, g), isTrue, reason: id);
      }
    });
  });

  group('a live book agrees with a fresh drain', () {
    test('after a decoration upgrade of a house avenue (back-out rule 1)', () {
      final city = town();
      final lots = houseStreet(
          city, const [Vec2(1500, -300), Vec2(1500, 300)],
          roadClass: RoadClass.avenue);
      expect(lots.length, greaterThan(8));
      final book = city.siteAccess;
      drain(city, book);
      int homes(SiteAccessBook b) => [
            for (final p in lots)
              if (b.planOf(p.id)?.program == SiteProgram.homeDriveway) p,
          ].length;
      // An undivided avenue at 50 km/h takes home drives...
      expect(homes(book), greaterThan(0));
      upgrade(city, city.layout.parcelById(lots.first.id)!.roadId!,
          'four-lane-grass');
      drain(city, book);
      final fresh = SiteAccessBook();
      drain(city, fresh);
      // ...a planted median refuses them (§3.3 rule 1), live and fresh alike.
      expect(homes(fresh), 0);
      expect(plansJsonOf(book), plansJsonOf(fresh));
      for (final id in plansJsonOf(fresh).keys) {
        expect(book.isCurrentFor(id, city.roadGraph), isTrue, reason: id);
      }
    });

    test('after a burnout and a growth start in the same tick (§4.2)', () {
      final city = town(grown: true);
      final book = city.siteAccess;
      // A zoned lot with nothing grown on it yet.
      final bare = freeLots(city)
          .firstWhere((p) => city.grownParcels.containsKey(p.id));
      city.grownParcels.remove(bare.id);
      drain(city, book);
      final victim = idsOf(book).firstWhere((id) =>
          city.grownParcels.containsKey(id) &&
          book.planOf(id)!.program == SiteProgram.homeDriveway);
      // One building starts growing; another burns out: every count the
      // cheap key reads is as it was.
      final placed = city.parcelBuildings.length,
          grownLots = city.grownParcels.length;
      city.grownParcels[bare.id] = 0.01;
      city.lotFires[victim] = 5.0;
      city.advanceParcelFires(1.0);
      expect(city.grownParcels.containsKey(victim), isFalse);
      expect(
          (city.parcelBuildings.length, city.grownParcels.length),
          (placed, grownLots));
      drain(city, book);
      expect(book.planOf(victim), isNull);
      final fresh = SiteAccessBook();
      drain(city, fresh);
      expect(plansJsonOf(book), plansJsonOf(fresh));
    });

    test('every building removal without a layout bump moves the built key',
        () {
      final city = town(grown: true);
      final lots = idsOf(city.siteAccess);
      var rev = city.siteBuiltRevision;
      void moved(String what) {
        expect(city.siteBuiltRevision, greaterThan(rev), reason: what);
        rev = city.siteBuiltRevision;
      }

      city.lotFires[lots[0]] = 5.0;
      city.advanceParcelFires(1.0);
      moved('burned out');
      city.clearParcel(lots[1]);
      moved('cleared');
      final cell = city.hubKey + 1;
      city.flattenAt(cell);
      moved('flattened');
      city.clearCell(cell);
      moved('bulldozed');
    });
  });

  group('chunks', () {
    test('are copy-on-write: only the changed site\'s chunk is republished',
        () {
      final city = starterKit();
      final book = city.siteAccess;
      final old = book.chunks.first;
      final copy = copyOf(old);
      final slots = {for (final id in old.siteIds) id: book.slotOf(id)};
      final rev = book.sitesRev;
      // A lot no access corridor crosses: building on a crossed lot also
      // re-plans the site behind it (§3.7a rule 1).
      final g = city.roadGraph;
      final crossed = {
        for (final lot in g.joinCrossLot) g.lotIds[lot],
      };
      final lot = freeLots(city).firstWhere((p) => !crossed.contains(p.id));
      expect(city.placeOnParcel(lot.id, house), isTrue);
      expect(book.sync(city, city.roadGraph), isTrue);
      expect(identical(book.chunks.first, old), isFalse);
      // The published chunk a holder kept is untouched.
      expect(unchanged(old, copy), isTrue);
      for (final e in slots.entries) {
        expect(book.slotOf(e.key), e.value);
      }
      expect(book.planOf(lot.id), isNotNull);
      expect(book.sitesRev, rev + 1);
      expect(book.changedSince(rev), [lot.id]);
      expect(book.changedSince(book.sitesRev), isEmpty);
    });

    test('a cleared site drops at once, and its slot is reused lowest first',
        () {
      final city = town();
      final book = city.siteAccess;
      drain(city, book);
      final victim = book.chunks.first.siteId(20);
      final other = book.chunks.first.siteId(30);
      final slot = book.slotOf(victim);
      final rev = book.sitesRev;
      city.clearParcel(victim);
      expect(book.planOf(victim), isNull);
      expect(book.slotOf(victim), -1);
      expect(book.sitesRev, rev + 1);
      expect(book.changedSince(rev), [victim]);
      city.clearParcel(other);
      expect(book.changedSince(rev), [victim, other]);
      // The next site to appear takes the lowest freed slot.
      city.placeOnParcel(other, house);
      drain(city, book);
      expect(book.slotOf(other), slot);
      expect(book.planOf(victim), isNull);
    });

    test('renames keep rev, slot and row; only the ids change', () {
      final city = town();
      final book = city.siteAccess;
      drain(city, book);
      final c = book.chunks.first;
      final a = c.siteId(5), b = c.siteId(6);
      final revA = c.rev(5), slotA = book.slotOf(a), slotB = book.slotOf(b);
      final sitesRev = book.sitesRev;
      // A swap, which only an order-independent rename survives.
      book.onLotsRenamed({a: b, b: a});
      expect(book.slotOf(b), slotA);
      expect(book.slotOf(a), slotB);
      expect(book.planOf(b)!.rev, revA);
      expect(book.chunks.first.siteId(5), b);
      expect(book.sitesRev, sitesRev);
      book.onLotsRenamed({a: 'lot-renamed'});
      expect(book.planOf(a), isNull);
      expect(book.planOf('lot-renamed'), isNotNull);
    });

    test('the change log answers null once it is older than its window', () {
      final book = SiteAccessBook();
      expect(book.changedSince(0), isEmpty);
      expect(book.sitesRev, 0);
      final city = town();
      drain(city, book);
      expect(book.changedSince(0), idsOf(book));
      expect(book.changedSince(-SiteAccessBook.changeLogSize - 1), isNull);
    });

    test('the dev hook dumps a plan as JSON', () {
      final city = town();
      drain(city, city.siteAccess);
      final id = city.siteAccess.chunks.first.siteId(4);
      final json = sitePlanJson(city.siteAccess.planOf(id)!);
      final back = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      expect(back['siteId'], id);
      expect(back['joins'], isNotEmpty);
      expect(SiteProgram.values.map((p) => p.name), contains(back['program']));
      expect(back['pavement'], hasLength(2));
    });
  });

  group('CitySim rename hooks (§4.1, §7.6: a renamed lot keeps its handle)', () {
    /// Every auto lot id of [city], every planned site's slot, and sitesRev.
    (Set<String>, Set<int>, int) snapshot(CitySim city) {
      final book = city.siteAccess;
      return (
        {for (final p in city.layout.autoParcels) p.id},
        {for (final id in idsOf(book)) book.slotOf(id)},
        book.sitesRev,
      );
    }

    /// The built auto lots [city] has that [oldIds] did not: the renamed ones.
    List<String> renamedBuilt(CitySim city, Set<String> oldIds) => [
          for (final p in city.layout.autoParcels)
            if (!oldIds.contains(p.id) && city.grownParcels.containsKey(p.id))
              p.id,
        ];

    void expectCarried(CitySim city, (Set<String>, Set<int>, int) was) {
      final (oldIds, oldSlots, rev) = was;
      final book = city.siteAccess;
      final renamed = renamedBuilt(city, oldIds);
      expect(renamed, isNotEmpty);
      // Before any sync: the plans already answer under the new ids, in
      // slots they held before, and no plan appeared, went or changed.
      final taken = <int>{};
      for (final id in renamed) {
        final slot = book.slotOf(id);
        expect(slot, greaterThanOrEqualTo(0), reason: id);
        expect(oldSlots.contains(slot), isTrue, reason: id);
        expect(taken.add(slot), isTrue, reason: id);
        expect(book.planOf(id)!.siteId, id);
      }
      expect(book.sitesRev, rev);
    }

    test('a road commit carries renamed lots\' plans (_carryRenamedLots)', () {
      final city = town(grown: true);
      drain(city, city.siteAccess);
      final was = snapshot(city);
      commit(city, const FixtureRoad([Vec2(-150, -290), Vec2(-150, 290)]));
      expectCarried(city, was);
    });

    test('a claimed plot carries renamed lots\' plans (_carryLotsAcross)', () {
      // A batch road (no re-cut) splits the grown block's roads; the next
      // plot staked (the same frame, before any sync) re-cuts the plat, and
      // the claim path carries the renames.
      final city = town(grown: true)..stock['ore'] = 1e9;
      drain(city, city.siteAccess);
      final was = snapshot(city);
      city.commitRoad(
          const [Vec2(-150, -290), Vec2(-150, 290)], RoadClass.street,
          regenerateLots: false);
      expect(city.claimSite(house, const Vec2(1500, 0), checkAccess: false),
          isNotNull);
      expectCarried(city, was);
    });
  });

  test('a book re-packs published rows exactly as PlanBuilder packed them', () {
    final city = town();
    final chunks = planCity(city);
    final c = chunks.first;
    final again =
        SiteAccessBook.debugRepack([for (var k = 0; k < c.siteCount; k++) (c, k)]);
    expect(sameChunk(again, c), isTrue);
    final some = SiteAccessBook.debugRepack([(c, 3), (c, 1)]);
    expect(some.siteIds, [c.siteId(3), c.siteId(1)]);
    expect(some.rev(0), c.rev(3));
    expect(some.revisionOf(0), c.rev(3));
    expect(some.revisionOf(1), c.rev(1));
  });
}
