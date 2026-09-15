// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_plan_fixtures.dart';

/// The R2 core generator end to end (docs/plans/site-access.md §3.3, §3.4,
/// §3.9): whole towns planned into chunks that pass V1–V13 (V1 against lane
/// graphs under every override kind), byte-identical twin runs, no ground
/// read, and the footprint kerbside pavement point V11 leaves to R2.
void main() {
  late CitySim starter;
  late CitySim built;
  late CitySim core;
  setUpAll(() {
    starter = starterKit();
    built = town();
    core = const CityGenerator()
        .generate(const CityGenSpec(blocksAcross: 4, seed: 5),
            bodies: fixtureBodies);
  });

  List<SiteViolation> violations(RoadGraph g, List<SiteAccessChunk> chunks) {
    final spans = SyntheticSites.laneSpansOf(g);
    return [
      for (final c in chunks)
        ...SitePlanValidator.validateChunk(c, graph: g, laneSpans: spans),
    ];
  }

  for (final (name, city) in <(String, CitySim Function())>[
    ('starter kit', () => starter),
    ('built town', () => built),
    ('generated town', () => core),
  ]) {
    test('$name: every plan passes V1–V13', () {
      final c = city();
      final g = c.roadGraph;
      final stats = SiteProgramStats();
      final chunks = planCity(c, stats: stats, validate: false);
      final bad = violations(g, chunks);
      expect(bad, isEmpty, reason: bad.take(20).join('\n'));
      final planned = chunks.fold<int>(0, (a, ch) => a + ch.siteCount);
      expect(planned, greaterThan(0));
      expect(
          stats.programs.fold<int>(0, (a, n) => a + n), planned,
          reason: '$stats');
      for (final ch in chunks) {
        expect(ch.siteCount, lessThanOrEqualTo(kSitesPerChunk));
        for (var k = 0; k < ch.siteCount; k++) {
          expect(ch.graphStamp(k), g.structureStamp);
        }
      }
      // ignore: avoid_print
      print('$name: $stats');
    });
  }

  test('the built town grows home driveways; demotions carry their flags', () {
    final stats = SiteProgramStats();
    final chunks = planCity(built, stats: stats, validate: false);
    expect(stats.programCount(SiteProgram.homeDriveway), greaterThan(0),
        reason: '$stats');
    // Row 0c carries kPlanAccessBlocked (the starter utilities' easement lots
    // are built on in this town); a kerb plan a home was demoted to carries
    // kPlanFallback; no home and no installation is ever a fallback (nothing
    // falls through TO them).
    var kerbFallback = 0, blocked = 0;
    for (final ch in chunks) {
      for (var k = 0; k < ch.siteCount; k++) {
        final p = ch.plan(k);
        if (p.flags & kPlanFallback != 0) {
          expect(p.program,
              isNot(anyOf(SiteProgram.homeDriveway, SiteProgram.installation)),
              reason: p.siteId);
          if (p.program == SiteProgram.kerbOnly) kerbFallback++;
        }
        if (p.flags & kPlanAccessBlocked != 0) {
          expect(p.program, SiteProgram.kerbOnly, reason: p.siteId);
          expect(p.flags & kPlanFallback, 0, reason: p.siteId);
          blocked++;
        }
      }
    }
    int d(SiteDemotion x) => stats.demotionCount(x);
    expect(blocked, d(SiteDemotion.accessBlocked));
    // R2 merge: the founded kit's book makes the four §3.7a lots easements
    // before the town zones, so `town()` builds none of them and no site is
    // blocked. A crossed lot built around the refusal (an old save) still
    // blocks its site, below.
    expect(blocked, 0, reason: '$stats');
    final old = starterKit();
    old.parcelBuildings['lot-r0x1-l10'] =
        kZoneSpecs['residential']![Density.low]!;
    final oldStats = SiteProgramStats();
    var oldBlocked = 0;
    for (final ch in planCity(old, stats: oldStats, validate: false)) {
      for (var k = 0; k < ch.siteCount; k++) {
        final p = ch.plan(k);
        if (p.flags & kPlanAccessBlocked == 0) continue;
        expect(p.program, SiteProgram.kerbOnly, reason: p.siteId);
        expect(p.flags & kPlanFallback, 0, reason: p.siteId);
        expect(p.siteId, 'lot-m0');
        oldBlocked++;
      }
    }
    expect(oldBlocked, 1);
    expect(oldStats.demotionCount(SiteDemotion.accessBlocked), 1);
    expect(
        kerbFallback,
        greaterThanOrEqualTo(d(SiteDemotion.homeRoad) +
            d(SiteDemotion.homeRoom) +
            d(SiteDemotion.homeSwingMargin) +
            d(SiteDemotion.homeSkew) +
            d(SiteDemotion.homeGeometry)));
  });

  test('twin runs give byte-identical chunks', () {
    Uint8List bytesOf(List<SiteAccessChunk> chunks) {
      final out = BytesBuilder();
      for (final c in chunks) {
        for (final o in c.debugRetained) {
          if (o is TypedData) {
            out.add(o.buffer.asUint8List(o.offsetInBytes, o.lengthInBytes));
          } else if (o is List<String>) {
            out.add(o.join('|').codeUnits);
          }
        }
      }
      return out.toBytes();
    }

    for (final city in [starter, built, core]) {
      final a = bytesOf(planCity(city, validate: false));
      final twin = planCity(city, validate: false);
      expect(bytesOf(twin), a);
    }
    // A second colony founded the same way plans the same bytes.
    expect(bytesOf(planCity(town(), validate: false)),
        bytesOf(planCity(built, validate: false)));
  });

  test('planning reads no ground', () {
    final before = WorldSnapshot.groundQueries;
    planCity(built, validate: false);
    planCity(core, validate: false);
    expect(WorldSnapshot.groundQueries, before);
    // And no plan source can: it imports nothing of the terrain, the
    // snapshot or a renderer, and names no ground function.
    final dir = Directory('lib/domain/colony/city/site_access');
    for (final f in dir.listSync().whereType<File>()) {
      final text = f.readAsStringSync();
      expect(RegExp(r"import '[^']*(terrain|snapshot|application|infrastructure)")
              .hasMatch(text),
          isFalse,
          reason: f.path);
      expect(RegExp(r'\bground(Under|For|At|Query)\b').hasMatch(text), isFalse,
          reason: f.path);
    }
  });

  test('a footprint kerbside plan puts its pavement point 1.5 m in from the '
      'attachFootprintJoins slot 0 kerb point (V11)', () {
    final g = starter.roadGraph;
    const polygon = SyntheticSites.footprintPolygon;
    final slots = g.attachFootprintJoins(polygon);
    expect(slots, isNotEmpty);
    final s0 = slots.first;
    // A megatower spec: row 2, kerbOnly outright.
    final parcel = Parcel(id: 'cell-probe', polygon: polygon);
    final ctx = SiteContext.ofFootprint(g, parcel, kMegatowerSpec);
    final b = PlanBuilder(graph: g);
    expect(planSite(b, ctx), SiteProgram.kerbOnly);
    final chunk = b.build();
    final p = chunk.plan(0);
    expect(p.graphLot, -1);
    expect(p.joinRef(0), kJoinRefNone);
    expect(p.joinKind(0), SiteJoinKind.kerbside);
    expect(p.joinPiece(0), s0.piece);
    expect(p.joinRoadS(0), s0.s);
    final pp = p.pavementPt;
    final de = p.ptE(pp) - s0.kerbE, dn = p.ptN(pp) - s0.kerbN;
    final d = (de * de + dn * dn);
    expect(d, closeTo(kPavementPointInsetM * kPavementPointInsetM, 1e-9));
    expect(kPavementPointInsetM, lessThanOrEqualTo(kPavementPointMaxM));
    // Into the lot, along the slot normal.
    expect(de * s0.normE + dn * s0.normN, closeTo(kPavementPointInsetM, 1e-9));
    expect(SitePlanValidator.validate(p, graph: g), isEmpty);
  });

  test('siteContextsOf walks cells in ascending anchor order, whatever the '
      'insertion history, and skips abandoned cells', () {
    final spec = kZoneSpecs['commercial']![Density.low]!;
    List<String> cellIds(List<int> insertOrder, {int? abandoned}) {
      final c = foundFlat(id: 'cells');
      for (final k in insertOrder) {
        c.utils[k] = spec;
      }
      if (abandoned != null) c.abandoned.add(abandoned);
      return [
        for (final ctx in siteContextsOf(c))
          if (ctx.graphLot < 0) ctx.siteId,
      ];
    }

    final live = foundFlat(id: 'cells');
    final base = live.grid * (live.grid ~/ 2) + live.grid ~/ 2;
    final keys = [base + 7, base + 2, base + 5];
    String idOf(int k) => live.parcelForCell(k, spec).id;
    final ascending = [for (final k in [base + 2, base + 5, base + 7]) idOf(k)];
    expect(cellIds(keys), ascending);
    expect(cellIds(keys.reversed.toList()), ascending);
    expect(cellIds(keys, abandoned: base + 5),
        [idOf(base + 2), idOf(base + 7)]);
  });

  test('unbuilt sites and sites with no slot store no plan (row 0a)', () {
    final g = starter.roadGraph;
    final lot = starter.layout.autoParcels.first;
    final stats = SiteProgramStats();
    final b = PlanBuilder(graph: g);
    expect(planSite(b, SiteContext.ofLot(g, lot, null), stats: stats), isNull);
    final far = Parcel(id: 'cell-far', polygon: const [
      Vec2(9000, 9000), Vec2(9030, 9000), Vec2(9030, 9030), Vec2(9000, 9030),
    ]);
    expect(
        planSite(b,
            SiteContext.ofFootprint(g, far, kZoneSpecs['commercial']![Density.low]!),
            stats: stats),
        isNull);
    expect(stats.unplanned, 2);
    expect(b.siteCount, 0);
  });
}
