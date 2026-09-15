// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// `site_plan_revision_test` (docs/plans/site-access.md §8.3, §3.9, V12):
/// a generated plan's `rev` is its columns' hash, never 0; it survives
/// re-resolving the same site against another graph (a copy sharing the
/// structure, or a graph whose structure changed elsewhere), while
/// `graphStamp` follows the graph; and it moves when the plan's geometry
/// does.
void main() {
  Map<String, SiteAccessPlan> plansOf(List<SiteAccessChunk> chunks) => {
        for (final c in chunks)
          for (var k = 0; k < c.siteCount; k++) c.siteId(k): c.plan(k),
      };

  test('rev is the columns\' hash and never 0', () {
    final chunks = planCity(town(), validate: false);
    var n = 0;
    for (final c in chunks) {
      for (var k = 0; k < c.siteCount; k++) {
        expect(c.rev(k), c.revisionOf(k), reason: c.siteId(k));
        expect(c.rev(k), isNot(0));
        expect(c.rev(k), inInclusiveRange(-0x80000000, 0x7FFFFFFF));
        n++;
      }
    }
    expect(n, greaterThan(0));
  });

  test('re-resolving against a copy that shares the structure keeps rev and '
      'graphStamp', () {
    final city = town();
    final g = city.roadGraph;
    final lit = g.withOverrides([
      for (final node in g.nodes)
        if (node.legs.length >= 3) JunctionOverride(at: node.at, lights: true),
    ]);
    expect(lit.sharesStructureWith(g), isTrue);
    final a = plansOf(planCity(city, validate: false));
    final b = plansOf(planCity(city, graph: lit, validate: false));
    expect(b.keys.toList(), a.keys.toList());
    for (final id in a.keys) {
      expect(b[id]!.rev, a[id]!.rev, reason: id);
      expect(b[id]!.graphStamp, a[id]!.graphStamp, reason: id);
    }
  });

  test('a structure change elsewhere moves graphStamp, not rev', () {
    final city = town();
    final a = plansOf(planCity(city, validate: false));
    final stampA = city.roadGraph.structureStamp;
    // A street far from every lot: pieces, nodes and lot indices change.
    commit(city, const FixtureRoad([Vec2(-6000, 6000), Vec2(-5800, 6000)]));
    final g = city.roadGraph;
    expect(g.structureStamp, isNot(stampA));
    final b = plansOf(planCity(city, validate: false));
    var same = 0;
    for (final id in a.keys) {
      final pb = b[id];
      if (pb == null) continue;
      same++;
      expect(pb.rev, a[id]!.rev, reason: id);
      expect(pb.graphStamp, g.structureStamp, reason: id);
      expect(a[id]!.graphStamp, stampA, reason: id);
    }
    expect(same, a.length, reason: 'every site is still built and planned');
  });

  test('rev moves with the geometry', () {
    final layout = CityLayout()
      ..addRoad(
          const RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(400, 0)]));
    final g = RoadGraph.of(layout);
    final lot = layout.parcelById('lot-r0-l3')!;
    final slot = g.joinOfRef(g.joinRefOf(g.lotNoOf(lot.id)!, 0))!;
    final sn = slot.normN.sign;
    final yF = slot.kerbN + 3 * sn;
    Parcel lotOf(double w, double d) {
      Vec2 at(double s, double depth) => Vec2(s, yF + depth * sn);
      return Parcel(
          id: lot.id,
          polygon: [at(108 - w, 0), at(108, 0), at(108, d), at(108 - w, d)],
          roadId: 'r0',
          frontage: (at(108 - w, 0), at(108, 0)));
    }

    int revOf(Parcel p, CityBuildingSpec spec) {
      final b = PlanBuilder(graph: g);
      expect(planSite(b, SiteContext.ofLot(g, p, spec)), isNotNull);
      return b.build(validate: false).rev(0);
    }

    final rLow = kZoneSpecs['residential']![Density.low]!;
    final base = revOf(lotOf(24, 32), rLow);
    expect(revOf(lotOf(24, 32), rLow), base, reason: 'same inputs, same rev');
    // A deeper lot: the house envelope moves.
    expect(revOf(lotOf(24, 40), rLow), isNot(base));
    // Tandem instead of side by side.
    expect(revOf(lotOf(17, 32), rLow), isNot(base));
    // A megatower on the same lot: kerbside.
    expect(revOf(lotOf(24, 32), kMegatowerSpec), isNot(base));
  });
}
