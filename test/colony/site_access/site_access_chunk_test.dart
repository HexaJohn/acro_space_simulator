// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/hash32.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:flutter_test/flutter_test.dart';

import 'site_plan_fixtures.dart';

/// The chunk (docs/plans/site-access.md §2.3, §3.10): immutable once built,
/// ≤ 7 retained objects whatever its site count, site ids by instance, CSR
/// families whose rows are exactly what each site owns.
void main() {
  late RoadGraph g;

  setUpAll(() {
    g = SyntheticSites.starterCity().roadGraph;
  });

  int digest(SiteAccessChunk c) {
    var h = kFnvOffset32;
    for (final o in c.debugRetained.take(5)) {
      final t = o as TypedData;
      for (final b in t.buffer.asUint8List(t.offsetInBytes, t.lengthInBytes)) {
        h = fnv1aByte(h, b);
      }
    }
    return h;
  }

  test('a chunk retains 7 objects: itself, five typed lists, the site ids',
      () {
    for (final n in [1, 64, kSitesPerChunk]) {
      final drafts = [
        for (var i = 0; i < n; i++)
          SyntheticSites.draftAt(g, 'lot-r0x1-l${i % 11}', SyntheticTemplate.kerbside,
              siteId: 'site-$i'),
      ];
      final c = SyntheticSites.chunkOf(g, drafts);
      final retained = [c, ...c.debugRetained];
      expect(retained, hasLength(7));
      for (var i = 0; i < retained.length; i++) {
        for (var k = i + 1; k < retained.length; k++) {
          expect(identical(retained[i], retained[k]), isFalse);
        }
      }
      expect(c.siteCount, n);
      for (var i = 0; i < n; i++) {
        expect(identical(c.siteId(i), drafts[i].siteId), isTrue);
      }
      // ≤ 1 retained object per 100 sites once full.
      if (n == kSitesPerChunk) expect(7 * 100 / n, lessThanOrEqualTo(1));
    }
  });

  test('a chunk refuses a site past $kSitesPerChunk', () {
    final b = PlanBuilder();
    for (var i = 0; i < kSitesPerChunk; i++) {
      b
        ..beginSite('s$i',
            program: SiteProgram.kerbOnly, frameE: 0, frameN: 0, frameUE: 1, frameUN: 0)
        ..endSite();
    }
    expect(
        () => b.beginSite('one more',
            program: SiteProgram.kerbOnly, frameE: 0, frameN: 0, frameUE: 1, frameUN: 0),
        throwsStateError);
  });

  test('immutable after build: a later build, a mutated draft and reads '
      'change nothing', () {
    final b = PlanBuilder(graph: g);
    final drafts = SyntheticSites.starterDrafts(g);
    for (final d in drafts.take(3)) {
      SyntheticSites.emit(b, d);
    }
    final first = b.build();
    final before = digest(first);
    final revs = [for (var k = 0; k < first.siteCount; k++) first.rev(k)];
    // The builder goes on; the published chunk does not.
    for (final d in drafts.skip(3)) {
      SyntheticSites.emit(b, d);
    }
    final second = b.build();
    drafts[1].nodes[0].e += 100;
    drafts[1].stalls.clear();
    for (var k = 0; k < first.siteCount; k++) {
      final p = first.plan(k);
      for (var i = 0; i < p.stallCount; i++) {
        p.stallIndexOfKey(p.stallKey(i));
      }
    }
    expect(first.siteCount, 3);
    expect(second.siteCount, drafts.length);
    expect(digest(first), before);
    expect([for (var k = 0; k < first.siteCount; k++) first.rev(k)], revs);
    for (var k = 0; k < first.siteCount; k++) {
      expect(first.revisionOf(k), first.rev(k));
      expect(second.rev(k), first.rev(k));
    }
  });

  test('the column schema: 104 columns; CSR families own count + 1 rows per '
      'site', () {
    final c = SyntheticSites.starterChunk(g);
    expect(SiteCol.count, 104);
    for (var k = 0; k < c.siteCount; k++) {
      final p = c.plan(k);
      expect(c.rowsOf(SiteCol.ptE, k).$2, p.pointCount);
      expect(c.rowsOf(SiteCol.segViaStart, k).$2, p.segCount + 1);
      expect(c.rowsOf(SiteCol.viaPt, k).$2, p.viaCount);
      expect(c.rowsOf(SiteCol.paveStart, k).$2, p.paveCount + 1);
      expect(c.rowsOf(SiteCol.pathStart, k).$2, p.pathCount + 1);
      expect(c.rowsOf(SiteCol.stallKey, k).$2, p.stallCount);
      expect(c.rowsOf(SiteCol.rev, k), (k, 1));
      // Polylines start and end on their nodes' points.
      for (var s = 0; s < p.segCount; s++) {
        expect(p.segPoint(s, 0), p.nodePt(p.segFrom(s)));
        expect(p.segPoint(s, p.segPointCount(s) - 1), p.nodePt(p.segTo(s)));
      }
    }
  });

  // §3.10 asks ≤ 512 B per home site. The §2.3 column set cannot meet it: the
  // site row alone is ~137 B, two stalls 112 B, a point 26 B. The HOME
  // fixture (3 nodes, a 4-point pave, a 2-point path, door, pavement) packs
  // in 753 B. This pins the packing as built so it cannot grow unnoticed;
  // the 512 B target is R2's bench to settle (parametric home rows, §10.1).
  test('memory: a home site packs in ≤ 768 B (753 as built), a kerbside site '
      'in far less', () {
    int perSite(SyntheticTemplate t, String lot) {
      final drafts = [
        for (var i = 0; i < 64; i++)
          SyntheticSites.draftAt(g, lot, t, siteId: 'h$i'),
      ];
      return SyntheticSites.chunkOf(g, drafts, validate: false).byteLength ~/ 64;
    }

    final home = perSite(SyntheticTemplate.home, 'lot-r0x1-l4');
    final kerb = perSite(SyntheticTemplate.kerbside, 'lot-r0x1-l9');
    expect(home, lessThanOrEqualTo(768), reason: '$home B per home');
    expect(kerb, lessThan(home));
  });
}
