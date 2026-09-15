// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_paving_check.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_plan_fixtures.dart';
import 'site_random_sites.dart';

/// Acceptance test A1 (docs/plans/site-access.md §7.9, slice R2): V1–V13 on
/// every generated plan of the starter kit, the small generated town, the
/// built town and 500 seeded random parcels × road classes, plus the R2
/// paving / corridor-clearance checks (`sitePavingViolations`).
///
/// Owned by R2 core; it plans through `planSite` only, so every generator a
/// track fills in is gated here the day it lands.
void main() {
  /// Plans [sites] over [g] and returns every breach, one line each, and the
  /// program counts.
  (List<String>, SiteProgramStats) check(RoadGraph g, List<SiteContext> sites) {
    final spans = SyntheticSites.laneSpansOf(g);
    final stats = SiteProgramStats();
    final bad = <String>[];
    var b = PlanBuilder(graph: g);
    var planned = <SiteContext>[];
    void flush() {
      if (b.siteCount == 0) return;
      final chunk = b.build(validate: false);
      for (var k = 0; k < chunk.siteCount; k++) {
        final p = chunk.plan(k);
        bad
          ..addAll([
            for (final v
                in SitePlanValidator.validate(p, graph: g, laneSpans: spans))
              '$v',
          ])
          ..addAll(sitePavingViolations(planned[k], p));
      }
      b = PlanBuilder(graph: g);
      planned = [];
    }

    for (final ctx in sites) {
      if (b.siteCount == kSitesPerChunk) flush();
      if (planSite(b, ctx, stats: stats) != null) planned.add(ctx);
    }
    flush();
    return (bad, stats);
  }

  for (final (name, make) in <(String, CitySim Function())>[
    ('starter kit', starterKit),
    ('small generated town', () => const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5), bodies: fixtureBodies)),
    ('built town', town),
  ]) {
    test('A1 $name: every plan passes V1–V13 and the paving checks', () {
      final city = make();
      final (bad, stats) = check(city.roadGraph, siteContextsOf(city));
      expect(bad, isEmpty, reason: bad.take(20).join('\n'));
      expect(stats.programs.fold<int>(0, (a, n) => a + n), greaterThan(0));
      // ignore: avoid_print
      print('A1 $name: $stats');
    });
  }

  test('A1 500 seeded random parcels × road classes', () {
    final sites = RandomSites.build();
    expect(sites, hasLength(RandomSites.count));
    final byGraph = <RoadGraph, List<SiteContext>>{};
    final graphs = <RoadGraph>[];
    for (final s in sites) {
      final list = byGraph[s.graph];
      if (list == null) {
        graphs.add(s.graph);
        byGraph[s.graph] = [s.context()];
      } else {
        list.add(s.context());
      }
    }
    final all = SiteProgramStats();
    final bad = <String>[];
    for (final g in graphs) {
      final (b, stats) = check(g, byGraph[g]!);
      bad.addAll(b);
      all.addAll(stats);
    }
    expect(bad, isEmpty, reason: bad.take(20).join('\n'));
    // The draw reaches homes, kerbside plans and the demotions between.
    expect(all.programCount(SiteProgram.homeDriveway), greaterThan(0),
        reason: '$all');
    expect(all.programCount(SiteProgram.kerbOnly), greaterThan(0));
    expect(all.demotionCount(SiteDemotion.homeRoad), greaterThan(0));
    expect(all.demotionCount(SiteDemotion.sliver), greaterThan(0));
    // ignore: avoid_print
    print('A1 random: $all');
  });

  test('the paving check reports nothing on the first starter site', () {
    final city = starterKit();
    final g = city.roadGraph;
    final ctx = siteContextsOf(city).first;
    final b = PlanBuilder(graph: g);
    expect(planSite(b, ctx), isNotNull);
    final SiteAccessPlan p = b.build().plan(0);
    expect(sitePavingViolations(ctx, p), isEmpty);
  });
}
