// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The refusal half of `site_easement_test` (docs/plans/site-access.md §3.7a
/// rules 1, 2 and 5, §8.3 R2), owned by the book track: an access easement
/// lot refuses zoning (`CityLayout.setUse`), placement
/// (`CitySim.placeOnParcel`) and growth, and the inspector names its site; a
/// new plot over a live access corridor is refused; the book derives its
/// easements from its stored network plans, lifts them when the site is
/// cleared, and a crossed lot that is already built blocks the site.
///
/// Named apart from the installation track's pure `site_easement_test` so
/// the two land without colliding. The easement source here is a FAKE (the
/// real `easementOf` is that track's), as are the network plans behind it.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_easement.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_envelope.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_access_book_fixtures.dart';

const int _all = SiteAccessBook.unlimited;

/// A stand-in network plan: one straight access road from slot 0's kerb
/// point to the frontage line, where an access corridor runs (not a valid
/// §3.7 plan; the book is built with validation off).
class _FakeAccessRoad implements SiteGeneratedPlan {
  _FakeAccessRoad(this.program);

  @override
  final SiteProgram program;

  @override
  void emit(PlanBuilder b, SiteContext ctx, int dispatchFlags) {
    ctx.beginSite(b, program, dispatchFlags | kPlanNetwork, SiteEnvelope.empty);
    final slot = ctx.slot0;
    final j = ctx.addJoin(b, 0, cutHalfM: 4.5);
    final k = ctx.kerbNode(b, slot, j);
    final kl = ctx.kerbLocal(slot);
    final f = b.node(ctx.localPoint(b, kl.e, 0));
    final seg = b.segment(k, f,
        kind: SiteSegmentKind.accessRoad,
        mode: SiteLaneMode.twoWay,
        widthM: 7,
        flags: kSegThroat);
    b.setJoinNetwork(j, kerbNode: k, throatSeg: seg);
    ctx.finishPedestrians(
        b, ctx.localPoint(b, kl.e, 10), ctx.kerbsidePavementPoint(b),
        entranceNode: f);
    b.endSite();
  }
}

SiteGeneratedPlan? _road(SiteContext ctx) => ctx.slot0.flags & kJoinEasement != 0
    ? _FakeAccessRoad(SiteProgram.installation)
    : null;

/// The fake rule: a network plan's slot-0 crossed lots that are unbuilt.
SiteEasement _rule(RoadGraph g, SiteAccessPlan plan, bool Function(int) built) {
  if (!plan.hasNetwork) return SiteEasement.none;
  final slot = g.joinOfRef(plan.joinRef(0));
  if (slot == null) return SiteEasement.none;
  return SiteEasement([
    for (final lot in slot.crossLots)
      if (!built(lot)) lot,
  ]);
}

SiteAccessBook fakeBook(CitySim city) {
  final book = SiteAccessBook(
    generators: const SiteGenerators(installation: _road, yard: _road),
    easements: _rule,
  );
  expect(book.sync(city, city.roadGraph, maxUnits: _all, maxChecks: _all),
      isTrue);
  return book;
}

void main() {
  const spaceport = 'lot-m0', front = 'lot-r0x1-l10';

  group('a fake easement source', () {
    CitySim colony() {
      final city = starterKit();
      city.layout.easementOf = (id) => id == front ? spaceport : null;
      return city;
    }

    test('setUse refuses every zone but unzoned on an easement lot', () {
      final city = colony();
      expect(city.layout.setUse(front, ParcelUse.residential), isFalse);
      expect(city.layout.setUse(front, ParcelUse.commercial), isFalse);
      expect(city.layout.parcelById(front)!.use, ParcelUse.unzoned);
      expect(city.layout.setUse(front, ParcelUse.unzoned), isTrue);
      // Its neighbour zones as ever.
      expect(city.layout.setUse('lot-r0x1-l9', ParcelUse.residential), isTrue);
    });

    test('placeOnParcel refuses an easement lot', () {
      final city = colony();
      expect(city.placeOnParcel(front, house), isFalse);
      expect(city.parcelBuildings.containsKey(front), isFalse);
      expect(city.placeOnParcel('lot-r0x1-l9', house), isTrue);
    });

    test('growth skips an easement lot zoned before it became one', () {
      final city = starterKit()..infiniteDemand = true;
      city.layout.setUse(front, ParcelUse.residential);
      city.layout.setUse('lot-r0x1-l9', ParcelUse.residential);
      city.layout.easementOf = (id) => id == front ? spaceport : null;
      for (var i = 0; i < 200; i++) {
        city.advanceParcelGrowth(1);
      }
      expect(city.grownParcels['lot-r0x1-l9'], greaterThan(1));
      expect(city.grownParcels.containsKey(front), isFalse);
      // Its zoning stays, inert.
      expect(city.layout.parcelById(front)!.use, ParcelUse.residential);
    });

    test('the inspector names the site', () {
      final city = colony();
      expect(city.lotInspectorNote(front),
          'access easement for ${city.siteSpec(spaceport)!.label}');
      expect(city.lotInspectorNote('lot-r0x1-l9'), isNull);
    });
  });

  group('the book', () {
    test('derives the easements of its network plans', () {
      final city = starterKit();
      final book = fakeBook(city);
      final easements = <String, String>{
        for (final p in city.layout.autoParcels)
          if (book.easementOf(p.id) != null) p.id: book.easementOf(p.id)!,
      };
      // §3.7a's starter lots, one per installation, from R1's crossings.
      expect(easements.keys.toSet(),
          {'lot-r0x1-l10', 'lot-r0x0-l0', 'lot-r0x0-r1', 'lot-r0x1-r5'});
      expect(easements[front], spaceport);
      // The colony refuses them once the layout reads this book.
      city.layout.easementOf = book.easementOf;
      expect(city.layout.setUse(front, ParcelUse.residential), isFalse);
      expect(city.placeOnParcel(front, house), isFalse);
    });

    test('clearing the site lifts its easement at once', () {
      final city = starterKit();
      final book = fakeBook(city);
      city.layout.easementOf = book.easementOf;
      final rev = book.sitesRev;
      book.onLotCleared(spaceport);
      expect(book.easementOf(front), isNull);
      expect(book.sitesRev, rev + 1);
      expect(city.layout.setUse(front, ParcelUse.residential), isTrue);
    });

    test('a crossed lot that is already built blocks the site', () {
      final city = starterKit();
      // Built before any easement existed (an old save, §3.7a rule 1).
      expect(city.placeOnParcel(front, house), isTrue);
      final book = fakeBook(city);
      final plan = book.planOf(spaceport)!;
      expect(plan.program, SiteProgram.kerbOnly);
      expect(plan.flags & kPlanAccessBlocked, isNot(0));
      expect(book.easementOf(front), isNull);
    });

    test('a building appearing on a crossed lot re-plans the site behind it',
        () {
      final city = starterKit();
      final book = fakeBook(city);
      expect(book.planOf(spaceport)!.hasNetwork, isTrue);
      city.parcelBuildings[front] = house; // around the refusal, as a save can
      expect(book.sync(city, city.roadGraph), isTrue);
      expect(book.planOf(spaceport)!.flags & kPlanAccessBlocked, isNot(0));
      expect(book.easementOf(front), isNull);
    });

    test('a plot over a live access corridor is refused', () {
      final city = starterKit()..stock['ore'] = 1e9;
      final book = fakeBook(city);
      final lot = city.layout.parcelById(front)!;
      final k = book.planOf(spaceport)!;
      // The corridor runs from slot 0's kerb point to the frontage line.
      final kerb = Vec2(k.joinKerbE(0), k.joinKerbN(0));
      expect(lot.contains(Vec2(kerb.e + 16, kerb.n)), isTrue);
      final on = city.siteFootprint(house, Vec2(kerb.e + 16, kerb.n));
      final off = city.siteFootprint(house, Vec2(kerb.e + 16, kerb.n + 150));
      expect(book.corridorHits(on), [spaceport]);
      expect(book.corridorHits(off), isEmpty);
      expect(city.layout.canAddManualParcel(on), isTrue);

      city.siteAccess.debugCorridorHits = book.corridorHits;
      expect(city.claimSite(house, Vec2(kerb.e + 16, kerb.n), checkAccess: false),
          isNull);
      expect(city.blocked, contains('access road'));
      expect(city.siteBlockedReason(house, Vec2(kerb.e + 16, kerb.n)),
          contains('access road'));
      // With no corridor there, the same plot is staked.
      city.siteAccess.debugCorridorHits = null;
      expect(city.claimSite(house, Vec2(kerb.e + 16, kerb.n), checkAccess: false),
          isNotNull);
    });
  });
}
