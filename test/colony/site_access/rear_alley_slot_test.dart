// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Rear alley joins, slot 3 (docs/plans/site-access.md §3.2, §3.9, slice R8):
/// the machinery only — the rear-edge rule, the slot offered on request, its
/// join handle, the cache every copy of a graph shares, and the re-plan an
/// alley drawn behind a built lot triggers. Nothing EMITS an alley join yet,
/// so no plan changes here: what is pinned is the offer and the trigger.
library;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_access_book_fixtures.dart';

/// A street 0..400 m east, lots both sides; with [alley], an alley 45 m north
/// of it, which the north row's lots back onto.
///
/// The plat cuts the north lots to their configured 32 m depth (the alley's own
/// setback leaves 34.4 m of block, so the depth is not what caps them), so
/// their rear edge lies at n = 39 and the alley's carriageway edge at n = 42:
/// 3 m apart, inside [kRearAlleyReachM]. The south row backs onto nothing.
CityLayout _street({bool alley = true}) {
  final layout = CityLayout();
  layout.commitRoad(controls: const [Vec2(0, 0), Vec2(400, 0)]);
  if (alley) {
    layout.commitRoad(
        controls: const [Vec2(0, 45), Vec2(400, 45)],
        roadClass: RoadClass.alley);
  }
  return layout;
}

void main() {
  void sameSlot(JoinSlot? a, JoinSlot? b, String why) {
    expect(a == null, b == null, reason: why);
    if (a == null || b == null) return;
    expect([a.piece, a.s, a.dirs, a.right, a.flags, a.roomM, a.kerbE, a.kerbN,
      a.normE, a.normN, a.crossLots],
        [b.piece, b.s, b.dirs, b.right, b.flags, b.roomM, b.kerbE, b.kerbN,
          b.normE, b.normN, b.crossLots],
        reason: why);
  }

  group('the rear-edge rule and the slot it offers', () {
    test('a lot with an alley behind it is offered slot 3; one without is not',
        () {
      final layout = _street();
      final g = RoadGraph.of(layout);
      final alley = g.roads.firstWhere((r) => r.roadClass == RoadClass.alley);
      var behind = 0, facing = 0;
      for (final p in layout.autoParcels) {
        final i = g.lotNoOf(p.id)!;
        final north = p.centroid.n > 0;
        expect(g.hasRearAlley(i), north, reason: p.id);
        final s3 = g.rearAlleyJoinOf(i);
        if (!north) {
          facing++;
          expect(s3, isNull, reason: '${p.id}: its back faces open ground');
          continue;
        }
        behind++;
        expect(s3, isNotNull, reason: p.id);
        // The cut is on the ALLEY, flagged as one, and carries a real cut.
        expect(g.roads[g.pieceRoad[s3!.piece]].id, alley.id, reason: p.id);
        expect(s3.flags & kJoinAlley, kJoinAlley, reason: p.id);
        expect(s3.flags & kJoinCut, kJoinCut, reason: p.id);
        expect(s3.flags & (kJoinSideStreet | kJoinLegacy), 0, reason: p.id);
        expect(s3.dirs, joinDirsFor(alley, s3.right), reason: p.id);
        expect(g.kerbWindows.roomAt(s3.piece, s3.s), closeTo(s3.roomM, 1e-4),
            reason: p.id);
        // Slot 0 stays the FRONTAGE and stays kerbside-able: the alley is a
        // second offer, never a move (the invariant of the slice).
        final k0 = g.lotJoinStart[i];
        expect(g.roads[g.pieceRoad[g.joinPiece[k0]]].id, p.roadId,
            reason: p.id);
        expect(g.joinFlags[k0] & kJoinAlley, 0, reason: p.id);
        // Not packed: offered on request, then kept.
        expect(g.lotJoinStart[i + 1] - k0, lessThanOrEqualTo(2), reason: p.id);
        expect(identical(g.rearAlleyJoinOf(i), s3), isTrue,
            reason: '${p.id}: placed once, then kept');
      }
      expect(behind, greaterThan(0), reason: 'the north row backs on the alley');
      expect(facing, greaterThan(0));
    });

    test('with no alley behind them no lot has a candidate or a slot 3', () {
      final layout = _street(alley: false);
      final g = RoadGraph.of(layout);
      expect(layout.autoParcels, isNotEmpty);
      for (final p in layout.autoParcels) {
        final i = g.lotNoOf(p.id)!;
        expect(g.hasRearAlley(i), isFalse, reason: p.id);
        expect(g.rearAlleyJoinOf(i), isNull, reason: p.id);
        expect(g.joinRefOf(i, kJoinSlotAlley), kJoinRefNone, reason: p.id);
      }
    });

    test('a street behind a lot is no alley: only the alley class backs one',
        () {
      // The same geometry with a STREET at n = 45. It plats its own lots, so
      // the block is shared at the midline and nothing backs onto it.
      final layout = CityLayout();
      layout.commitRoad(controls: const [Vec2(0, 0), Vec2(400, 0)]);
      layout.commitRoad(controls: const [Vec2(0, 45), Vec2(400, 45)]);
      final g = RoadGraph.of(layout);
      for (final p in layout.autoParcels) {
        expect(g.hasRearAlley(g.lotNoOf(p.id)!), isFalse, reason: p.id);
      }
    });
  });

  group('the join handle (§2.3)', () {
    test('ref -> join -> ref round trips, and cannot collide with a side '
        'street', () {
      final layout = _street();
      final g = RoadGraph.of(layout);
      var seen = 0;
      for (var lot = 0; lot < g.lotCount; lot++) {
        final ref = g.joinRefOf(lot, kJoinSlotAlley);
        if (g.rearAlleyJoinOf(lot) == null) {
          expect(ref, kJoinRefNone, reason: 'lot $lot has no alley');
          continue;
        }
        seen++;
        expect(ref, kJoinRefAlleyBase - lot);
        expect(ref, lessThanOrEqualTo(kJoinRefAlleyBase));
        // The side-street form fills the negative space from the top: the two
        // never meet at any lot index an Int32 array can hold.
        expect(kJoinRefSideStreetBase - lot, greaterThan(kJoinRefAlleyBase));
        sameSlot(g.joinOfRef(ref), g.rearAlleyJoinOf(lot), 'lot $lot slot 3');
        // And back again: the handle the slot came from.
        expect(g.joinRefOf(kJoinRefAlleyBase - ref, kJoinSlotAlley), ref);
      }
      expect(seen, greaterThan(0));
      expect(g.joinOfRef(kJoinRefAlleyBase - g.lotCount), isNull);
      expect(g.joinRefOf(g.lotCount, kJoinSlotAlley), kJoinRefNone);
      expect(g.joinRefOf(-1, kJoinSlotAlley), kJoinRefNone);
    });

    test('every copy sharing the structure shares the cache and the answer',
        () {
      final layout = _street();
      final g = RoadGraph.of(layout);
      final lot = [
        for (var i = 0; i < g.lotCount; i++)
          if (g.hasRearAlley(i)) i
      ].first;
      // Asked on the ORIGINAL first: the copies read the same placement.
      final s3 = g.rearAlleyJoinOf(lot)!;
      final lit = g.withOverrides(
          [const JunctionOverride(at: Vec2(9999, 9999), lights: true)]);
      layout.renameRoad(g.roads.first.id, 'Main Street');
      final renamed = g.refreshedFor(layout)!;
      for (final copy in [lit, renamed]) {
        expect(identical(copy, g), isFalse);
        expect(copy.sharesStructureWith(g), isTrue);
        expect(identical(copy.rearAlleyJoinOf(lot), s3), isTrue);
        expect(copy.hasRearAlley(lot), isTrue);
        expect(copy.joinRefOf(lot, kJoinSlotAlley),
            g.joinRefOf(lot, kJoinSlotAlley));
      }
      // The other way round: a copy asked first answers for the original too.
      final fresh = RoadGraph.of(layout);
      final other = [
        for (var i = 0; i < fresh.lotCount; i++)
          if (fresh.hasRearAlley(i)) i
      ].first;
      final copy = fresh.withOverrides(
          [const JunctionOverride(at: Vec2(9999, 9999), lights: true)]);
      final placed = copy.rearAlleyJoinOf(other)!;
      expect(identical(fresh.rearAlleyJoinOf(other), placed), isTrue);
    });
  });

  group('the re-plan trigger (§4.2, §3.9)', () {
    test('an alley drawn behind a built lot re-plans it, and nothing in front '
        'of it', () {
      // Houses on a far street (e = 1500); an alley at e = 1545 backs the east
      // row only. The alley's own setback leaves the lots' 32 m depth alone,
      // so their polygons — and every slot they hold — come out unchanged: the
      // only input that moves is the alley-candidate bit.
      final city = town();
      final lots = houseStreet(city, const [Vec2(1500, -150), Vec2(1500, 150)]);
      final book = city.siteAccess;
      drain(city, book);
      final east = [for (final p in lots) if (p.centroid.e > 1500) p];
      final west = [for (final p in lots) if (p.centroid.e < 1500) p];
      expect(east, isNotEmpty);
      expect(west, isNotEmpty);
      final before = plansOf(book);

      commit(city,
          const FixtureRoad([Vec2(1545, -150), Vec2(1545, 150)],
              roadClass: RoadClass.alley));
      final g = city.roadGraph;
      // The lots are re-cut identically, and the alley stands behind the east
      // row alone.
      String shape(Parcel p) =>
          [for (final v in p.polygon) '${v.e},${v.n}'].join(' ');
      for (final p in [...east, ...west]) {
        final now = city.layout.parcelById(p.id)!;
        expect(shape(now), shape(p), reason: p.id);
        expect(g.hasRearAlley(g.lotNoOf(p.id)!), east.contains(p),
            reason: p.id);
      }

      drain(city, book);
      // Every east lot re-planned; the west row (inside the same dirty box)
      // only re-resolved, and no plan anywhere changed, since nothing emits an
      // alley join yet.
      expect(book.lastSync.generated, east.length);
      expect(book.lastSync.resolved, greaterThanOrEqualTo(west.length));
      expect(plansOf(book), before);
      for (final p in [...east, ...west]) {
        expect(book.isCurrentFor(p.id, g), isTrue, reason: p.id);
      }
      // And a second drain with nothing changed does nothing at all.
      drain(city, book);
      expect(book.lastSync.generated, 0);
      expect(book.lastSync.chunks, 0);
    });
  });
}

/// Plans every built site of [city] in one sync.
void drain(CitySim city, SiteAccessBook book) {
  expect(
      book.sync(city, city.roadGraph,
          maxUnits: SiteAccessBook.unlimited,
          maxChecks: SiteAccessBook.unlimited),
      isTrue);
}
