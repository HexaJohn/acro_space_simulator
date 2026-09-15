// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_easement.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// Access easements (docs/plans/site-access.md §3.7a rule 2), the pure half
/// (`easementOf`): the starter kit's four easement lots exactly, and none for
/// a kerbside plan, a plan crossing a built lot or a plan resolved against
/// another road-graph structure. The book's half (the `CityLayout` hook,
/// `setUse` / `placeOnParcel` / growth refusal, the inspector string) is the
/// book track's.
void main() {
  final city = starterKit();
  final g = city.roadGraph;
  final sites = siteContextsOf(city);

  /// [ctx] planned alone.
  SiteAccessPlan planOf(SiteContext ctx) {
    final b = PlanBuilder(graph: g);
    expect(planSite(b, ctx), isNotNull);
    return b.build(validate: false).plan(0);
  }

  test('the starter kit\'s easements are exactly the four §3.7a lots', () {
    final easements = <String>[];
    for (final ctx in sites) {
      final p = planOf(ctx);
      expect(p.flags & kPlanAccessBlocked, 0, reason: ctx.siteId);
      for (final lot in easementOf(g, p, ctx.lotBuilt).lots) {
        easements.add('${g.lotIds[lot]} for ${ctx.siteId}');
      }
    }
    easements.sort();
    expect(easements, [
      'lot-r0x0-l0 for lot-m1',
      'lot-r0x0-r1 for lot-m2',
      'lot-r0x1-l10 for lot-m0',
      'lot-r0x1-r5 for lot-m3',
    ]);
    // 78 of the 82 auto lots stay zonable.
    final auto = city.layout.autoParcels.length;
    expect(auto, 82);
    expect(auto - easements.length, 78);
  });

  test('lots come out ascending and once, as graph lot indices', () {
    final pump = sites.firstWhere((c) => c.siteId == 'lot-m3');
    final e = easementOf(g, planOf(pump), pump.lotBuilt);
    expect(e.lots, [g.lotNoOf('lot-r0x1-r5')]);
    expect(e.isEmpty, isFalse);
  });

  test('a crossed lot that is built gives no easement', () {
    final pump = sites.firstWhere((c) => c.siteId == 'lot-m3');
    final p = planOf(pump);
    final crossed = g.lotNoOf('lot-r0x1-r5')!;
    expect(easementOf(g, p, (lot) => lot == crossed).isEmpty, isTrue);
    expect(easementOf(g, p, (lot) => false).lots, [crossed]);
  });

  test('a kerbside plan has no easement', () {
    // A megatower on the pump's own lot (its slot 0 crosses lot-r0x1-r5) is
    // kerbOnly outright (row 2).
    final pump = sites.firstWhere((c) => c.siteId == 'lot-m3');
    final kerb = planOf(SiteContext.ofLot(g, pump.parcel, kMegatowerSpec));
    expect(kerb.hasNetwork, isFalse);
    expect(easementOf(g, kerb, pump.lotBuilt).isEmpty, isTrue);
  });

  test('a plan resolved against another structure stamp has none', () {
    final pump = sites.firstWhere((c) => c.siteId == 'lot-m3');
    final stale = SiteContext.ofLot(g, pump.parcel, pump.spec,
        graphStamp: g.structureStamp ^ 1);
    final p = planOf(stale);
    expect(p.hasNetwork, isTrue);
    expect(easementOf(g, p, pump.lotBuilt).isEmpty, isTrue);
  });
}
