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
/// a kerbside plan, a slot crossing a built lot (per slot) or a plan resolved against
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
    // The pump's own network plan on the lot has one (so this fails on a
    // stub that always answers none) ...
    final pump = sites.firstWhere((c) => c.siteId == 'lot-m3');
    final crossed = g.lotNoOf('lot-r0x1-r5')!;
    final network = planOf(pump);
    expect(network.hasNetwork, isTrue);
    expect(easementOf(g, network, pump.lotBuilt).lots, [crossed]);
    // ... and a megatower on the same lot (its slot 0 crosses the same lot)
    // is kerbOnly outright (row 2): none.
    final kerb = planOf(SiteContext.ofLot(g, pump.parcel, kMegatowerSpec));
    expect(kerb.hasNetwork, isFalse);
    expect(easementOf(g, kerb, pump.lotBuilt).isEmpty, isTrue);
  });

  test('a plan resolved against another structure stamp has none', () {
    final pump = sites.firstWhere((c) => c.siteId == 'lot-m3');
    final crossed = g.lotNoOf('lot-r0x1-r5')!;
    // The same site resolved against the current stamp has its easement ...
    final current = planOf(SiteContext.ofLot(g, pump.parcel, pump.spec,
        graphStamp: g.structureStamp));
    expect(current.graphStamp, g.structureStamp);
    expect(easementOf(g, current, pump.lotBuilt).lots, [crossed]);
    // ... and none against another.
    final stale = SiteContext.ofLot(g, pump.parcel, pump.spec,
        graphStamp: g.structureStamp ^ 1);
    final p = planOf(stale);
    expect(p.hasNetwork, isTrue);
    expect(easementOf(g, p, pump.lotBuilt).isEmpty, isTrue);
  });

  test('a slot crossing a built lot drops only its own lots (rule 2 per slot)',
      () {
    // A network plan with two cut joins: the pump's slot 0 (crosses
    // lot-r0x1-r5) and the spaceport's slot 0 (crosses lot-r0x1-l10), as a
    // second join. Easement handling reads only the joins, so the skeleton
    // carries nothing else.
    final pumpLot = g.lotNoOf('lot-m3')!, portLot = g.lotNoOf('lot-m0')!;
    final pumpRef = g.joinRefOf(pumpLot, 0), portRef = g.joinRefOf(portLot, 0);
    final pumpSlot = g.joinOfRef(pumpRef)!, portSlot = g.joinOfRef(portRef)!;
    final r5 = g.lotNoOf('lot-r0x1-r5')!, l10 = g.lotNoOf('lot-r0x1-l10')!;
    expect(pumpSlot.crossLots, [r5]);
    expect(portSlot.crossLots, [l10]);

    final b = PlanBuilder(graph: g)
      ..beginSite('TWO_JOINS',
          program: SiteProgram.installation,
          flags: kPlanNetwork,
          graphStamp: g.structureStamp,
          graphLot: pumpLot,
          frameE: 0,
          frameN: 0,
          frameUE: 1,
          frameUN: 0);
    for (final (k, ref, s) in [(0, pumpRef, pumpSlot), (1, portRef, portSlot)]) {
      b.join(
          slot: k,
          ref: ref,
          piece: s.piece,
          roadS: s.s,
          right: s.right,
          dirs: s.dirs,
          roadNo: g.pieceRoad[s.piece]);
    }
    b.endSite();
    final p = b.build(validate: false).plan(0);

    expect(easementOf(g, p, (lot) => false).lots, [l10, r5]..sort());
    // The second join's lot is built: slot 0's easement stays.
    expect(easementOf(g, p, (lot) => lot == l10).lots, [r5]);
    // Slot 0's lot is built: the second join's stays.
    expect(easementOf(g, p, (lot) => lot == r5).lots, [l10]);
    expect(easementOf(g, p, (lot) => lot == r5 || lot == l10).isEmpty, isTrue);
  });
}
