// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The R2 acceptance items that only hold once every track is merged
/// (docs/plans/site-access.md §9 row "R2 Generator + book"), read through
/// the colony's own `SiteAccessBook` rather than the dispatcher: the four
/// starter sites (56 m throat `K→F` with vias, yard, gate `G` on the fence
/// line, ≥ 12 stalls), exactly the four §3.7a easement lots, no site
/// `kPlanAccessBlocked`; twin colonies advanced alike, one captured into a
/// `WorldSnapshot` every tick, keep identical plans; and on a generated town
/// with home demotions, the
/// book's drain site for site the dispatch's, demotions carried as
/// `kerbOnly` + `kPlanFallback`.
library;

import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_access_book_fixtures.dart';
import 'site_plan_fixtures.dart';

Vec2 _local(SiteAccessPlan p, double e, double n) {
  final de = e - p.frameE, dn = n - p.frameN;
  return Vec2(
      de * p.frameUE + dn * p.frameUN, de * p.frameVE + dn * p.frameVN);
}

void main() {
  const installations = ['lot-m0', 'lot-m1', 'lot-m2', 'lot-m3'];
  const easementLots = {
    'lot-r0x1-l10',
    'lot-r0x0-l0',
    'lot-r0x0-r1',
    'lot-r0x1-r5',
  };

  group('the founded starter kit, through its book', () {
    final city = starterKit();
    final book = city.siteAccess;
    final g = city.roadGraph;
    final spans = SyntheticSites.laneSpansOf(g);

    for (final id in installations) {
      test('$id: 56 m throat K→F with vias, yard, gate on the fence line, '
          '≥ 12 stalls, current and valid', () {
        expect(book.isCurrentFor(id, g), isTrue);
        final p = book.planOf(id)!;
        expect(SitePlanValidator.validate(p, graph: g, laneSpans: spans),
            isEmpty);
        expect(p.program, SiteProgram.installation);
        expect(p.flags & (kPlanFallback | kPlanAccessBlocked), 0);
        expect(p.graphStamp, g.structureStamp);

        // K→F: segment 0, 56 m, vias at 24 and 48 m, F on the frontage line.
        expect(p.joinThroatSeg(0), 0);
        expect(p.segFrom(0), p.joinKerbNode(0));
        expect(p.segLenM(0), closeTo(56, 1e-6));
        expect(p.segViaCount(0), 2);
        final f = p.segTo(0);
        final fl = _local(p, p.nodeE(f), p.nodeN(f));
        expect(fl.n, closeTo(0, 1e-6));

        // The yard Y: a truck circle on the gate's axis.
        var y = -1;
        for (var n = 0; n < p.nodeCount; n++) {
          if (p.nodeTurnKind(n) == TurnaroundKind.circle) y = n;
        }
        expect(y, isNot(-1));
        expect(p.nodeTurnR(y), kInstallationCircleRadiusM);
        expect(p.admitsTrucks, isTrue);
        expect(p.bayCount, greaterThan(0));

        // G on the fence line: the envelope's front edge, the entrance.
        var gate = -1;
        for (var n = 0; n < p.nodeCount; n++) {
          if (p.nodeFlags(n) & kNodeGate != 0) gate = n;
        }
        expect(gate, isNot(-1));
        final gl = _local(p, p.nodeE(gate), p.nodeN(gate));
        expect(gl.n, closeTo(p.envY0, 1e-4));
        expect(gl.e, closeTo(fl.e, 1e-6));
        expect(p.entranceNode, gate);

        expect(p.stallCount, greaterThanOrEqualTo(12));
      });
    }

    test('exactly the four §3.7a easement lots, and no site blocked', () {
      final found = <String, String>{
        for (final p in city.layout.autoParcels)
          if (book.easementOf(p.id) != null) p.id: book.easementOf(p.id)!,
      };
      expect(found.keys.toSet(), easementLots);
      expect(found.values.toSet(), installations.toSet());
      expect(found['lot-r0x1-l10'], 'lot-m0');
      expect(found['lot-r0x1-r5'], 'lot-m3');
      // 78 of the 82 auto lots stay zonable.
      expect(city.layout.autoParcels.length - found.length, 78);
      for (final c in book.chunks) {
        for (var k = 0; k < c.siteCount; k++) {
          expect(c.flags(k) & kPlanAccessBlocked, 0, reason: c.siteId(k));
        }
      }
      // The colony refuses them, and names the site.
      for (final lot in easementLots) {
        expect(city.layout.setUse(lot, ParcelUse.residential), isFalse);
        expect(city.placeOnParcel(lot, house), isFalse);
        expect(city.lotInspectorNote(lot),
            'access easement for ${city.siteSpec(found[lot]!)!.label}');
      }
      expect(city.layout.setUse('lot-r0x1-l9', ParcelUse.residential), isTrue);
    });
  });

  test('twin colonies advanced alike keep identical plans, one of them '
      'captured into a WorldSnapshot every tick', () {
    final system = RealSolarSystem.build();
    final a = town(grown: true), b = town(grown: true);
    var captured = 0;
    void step(int tick) {
      for (final c in [a, b]) {
        c.advance(0.5);
      }
      WorldSnapshot.capture(tick, InMemoryVesselRepository(const []),
          system: system, cities: InMemoryCityRepository([a]));
      captured++;
      expect(a.siteAccess.sitesRev, b.siteAccess.sitesRev, reason: 'tick $tick');
      expect(plansJsonOf(a.siteAccess), plansJsonOf(b.siteAccess),
          reason: 'tick $tick');
    }

    var tick = 0;
    for (var i = 0; i < 10; i++) {
      step(tick++);
    }
    // A road edit and a street of new houses, the same on both, mid-run.
    for (final c in [a, b]) {
      houseStreet(c, const [Vec2(900, -150), Vec2(900, 150)]);
    }
    for (var i = 0; i < 40; i++) {
      step(tick++);
    }
    expect(captured, 50);
    expect(a.siteAccess.chunks, isNotEmpty);
    for (final c in [a, b]) {
      expect(c.siteAccess.sync(c, c.roadGraph), isTrue);
    }
    expect(plansJsonOf(a.siteAccess), plansJsonOf(b.siteAccess));
  });

  test('a generated town: the book drains what the dispatch plans, home '
      'demotions carried as kerbOnly fallbacks', () {
    final city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5),
        bodies: fixtureBodies);
    final book = SiteAccessBook(validate: true);
    expect(
        book.sync(city, city.roadGraph,
            maxUnits: SiteAccessBook.unlimited,
            maxChecks: SiteAccessBook.unlimited),
        isTrue);
    final stats = SiteProgramStats();
    final fresh = planCity(city, stats: stats);
    // Site for site (the book's slot order follows its priority walk, so its
    // rows need not sit in the dispatch's order).
    expect(plansJsonOf(book), {
      for (final c in fresh)
        for (var k = 0; k < c.siteCount; k++)
          c.siteId(k): jsonEncode(sitePlanJson(c.plan(k))),
    });
    expect(plansOf(book), {
      for (final c in fresh)
        for (var k = 0; k < c.siteCount; k++)
          c.siteId(k): '${c.program(k).name} ${c.rev(k)} ${keysOf(c.plan(k))}',
    });
    final homeDemotions = [
      SiteDemotion.homeRoad,
      SiteDemotion.homeRoom,
      SiteDemotion.homeSwingMargin,
      SiteDemotion.homeSkew,
      SiteDemotion.homeGeometry,
    ].fold<int>(0, (a, d) => a + stats.demotionCount(d));
    expect(homeDemotions, greaterThan(0), reason: '$stats');
    expect(stats.programCount(SiteProgram.homeDriveway), greaterThan(0));
    var kerbFallback = 0;
    for (final c in book.chunks) {
      for (var k = 0; k < c.siteCount; k++) {
        if (c.program(k) == SiteProgram.kerbOnly &&
            c.flags(k) & kPlanFallback != 0) {
          kerbFallback++;
        }
      }
    }
    expect(kerbFallback, greaterThanOrEqualTo(homeDemotions));
  });
}
