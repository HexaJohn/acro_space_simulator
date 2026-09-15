// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_paving_check.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// The R2 paving and corridor-clearance checks (docs/plans/site-access.md
/// §2.4 geometry invariants, §3.7a): every starter plan passes; a plan whose
/// paving leaves its parcel ∪ corridor, a corridor across a built lot, a
/// corridor an at-grade road runs through, and a blocked slot each fail.
void main() {
  final city = starterKit();
  final g = city.roadGraph;
  final sites = siteContextsOf(city);
  final pump = sites.firstWhere((c) => c.siteId == 'lot-m3');

  SiteAccessPlan planOf(SiteContext ctx) {
    final b = PlanBuilder(graph: ctx.graph);
    expect(planSite(b, ctx), isNotNull);
    return b.build(validate: false).plan(0);
  }

  test('every starter plan passes', () {
    for (final ctx in sites) {
      expect(sitePavingViolations(ctx, planOf(ctx)), isEmpty,
          reason: ctx.siteId);
    }
  });

  test('the pump\'s corridor runs 56 m along its slot normal', () {
    final s = pump.slot0;
    final line = corridorLineOf(pump.frame!, s);
    expect(line, hasLength(2));
    expect(line[0].e, s.kerbE);
    expect(line[0].n, s.kerbN);
    expect(line[1].distanceTo(line[0]), closeTo(56, 1e-9));
    expect((line[1] - line[0]).normalized.dot(Vec2(s.normE, s.normN)),
        closeTo(1, 1e-12));
  });

  test('paving outside the parcel and every corridor is reported', () {
    final p = planOf(pump);
    // The same plan against the pump's lot cut to 30 m deep: its spine,
    // yard and car park now stand outside the parcel.
    final poly = pump.parcel.polygon;
    final front = pump.parcel.frontage!;
    final inward = pump.frame!.v;
    final shallow = Parcel(
      id: pump.parcel.id,
      polygon: [front.$1, front.$2, front.$2 + inward * 30, front.$1 + inward * 30],
      frontage: front,
      manual: true,
    );
    expect(poly, hasLength(4));
    final ctx = SiteContext.ofLot(g, shallow, pump.spec);
    final bad = sitePavingViolations(ctx, p);
    expect(bad, isNotEmpty);
    expect(bad.every((l) => l.startsWith('paving [lot-m3]')), isTrue,
        reason: bad.join('\n'));
  });

  test('a corridor across a built lot is reported', () {
    final p = planOf(pump);
    final crossed = g.lotNoOf('lot-r0x1-r5')!;
    final built = SiteContext.ofLot(g, pump.parcel, pump.spec,
        lotBuilt: (lot) => lot == crossed);
    final bad = sitePavingViolations(built, p);
    expect(bad, ['corridor clearance [lot-m3]: join 0 crosses the built lot '
        'lot-r0x1-r5']);
  });

  test('a blocked slot and an at-grade road through the corridor are reported',
      () {
    final p = planOf(pump);
    final s = pump.slot0;
    final blocked = JoinSlot(
      piece: s.piece,
      s: s.s,
      dirs: s.dirs,
      right: s.right,
      flags: s.flags | kJoinCorridorBlocked,
      roomM: s.roomM,
      kerbE: s.kerbE,
      kerbN: s.kerbN,
      normE: s.normE,
      normN: s.normN,
      crossLots: s.crossLots,
    );
    final bad = sitePavingViolations(
        SiteContext.debug(g, pump.parcel, pump.spec,
            slots: [blocked], slotRefs: [pump.slotRef(0)], graphLot: pump.graphLot),
        p);
    expect(bad, contains('corridor clearance [lot-m3]: join 0 uses a blocked '
        'corridor'));

    // The starter streets and a north–south road across the corridor at
    // e = −30 (the pump's corridor runs e −4 → −60 at n = 144).
    final layout = CityLayout();
    for (final r in g.roads) {
      layout.addRoad(r);
    }
    layout.addRoad(const RoadSpline(
        id: 'probe', controls: [Vec2(-30, 120), Vec2(-30, 170)]));
    final g2 = RoadGraph.of(layout);
    final withRoad = SiteContext.debug(g2, pump.parcel, pump.spec,
        slots: [s], slotRefs: [pump.slotRef(0)], graphLot: pump.graphLot);
    final hits = sitePavingViolations(withRoad, p);
    expect(hits.where((l) => l.contains('road probe')), isNotEmpty,
        reason: hits.join('\n'));
    // And without it, nothing.
    final without = SiteContext.debug(g, pump.parcel, pump.spec,
        slots: [s], slotRefs: [pump.slotRef(0)], graphLot: pump.graphLot);
    expect(sitePavingViolations(without, p), isEmpty);
  });

  test('a skewed lot whose frontage runs through the kerb (k = 0): the kerb '
      'corners are covered by the extension alone', () {
    final layout = CityLayout()
      ..addRoad(const RoadSpline(
          id: 'r0', controls: [Vec2(0, 0), Vec2(1000, 0)]));
    final street = RoadGraph.of(layout);
    late final int lot, ref;
    late final JoinSlot slot;
    for (var l = 0; l < street.lotCount; l++) {
      final r = street.joinRefOf(l, 0);
      final s = street.joinOfRef(r);
      if (s == null || s.flags & kJoinCut == 0) continue;
      if (s.s < 480 || s.s > 520 || s.roomM < 4.5) continue;
      lot = l;
      ref = r;
      slot = s;
      break;
    }
    for (final deg in const [-59.0, -25.0, -12.0, 12.0, 25.0, 40.0, 50.0, 59.0]) {
      final a = deg * math.pi / 180;
      final v0 = Vec2(0, slot.normN.sign);
      const u0 = Vec2(1, 0);
      final u = u0 * math.cos(a) + v0 * math.sin(a);
      final v = v0 * math.cos(a) - u0 * math.sin(a);
      final c0 = Vec2(slot.kerbE, slot.kerbN);
      final p0 = c0 - u * 100, p1 = c0 + u * 100;
      final parcel = Parcel(
          id: 'site',
          polygon: [p0, p1, p1 + v * 200, p0 + v * 200],
          frontage: (p0, p1));
      final ctx = SiteContext.debug(street, parcel, pump.spec,
          slots: [slot], slotRefs: [ref], graphLot: lot);
      expect(corridorLineOf(ctx.frame!, slot), hasLength(1));
      final p = planOf(ctx);
      expect(p.hasNetwork, isTrue, reason: '$deg°');
      expect(sitePavingViolations(ctx, p), isEmpty, reason: '$deg°');
    }
  });

  test('the run-on past the frontage line stops at the lot\'s side lines', () {
    final layout = CityLayout()
      ..addRoad(const RoadSpline(
          id: 'r0', controls: [Vec2(0, 0), Vec2(1000, 0)]));
    final street = RoadGraph.of(layout);
    late final int lot, ref;
    late final JoinSlot slot;
    for (var l = 0; l < street.lotCount; l++) {
      final r = street.joinRefOf(l, 0);
      final s = street.joinOfRef(r);
      if (s == null || s.flags & kJoinCut == 0) continue;
      if (s.s < 480 || s.s > 520) continue;
      lot = l;
      ref = r;
      slot = s;
      break;
    }
    const h = kAccessCorridorHalfM;
    final c0 = Vec2(slot.kerbE, slot.kerbN);
    final nrm = Vec2(slot.normE, slot.normN);

    /// A plan of one cut join on [slot] and one tiny pave ring around [p].
    SiteAccessPlan skeleton(Vec2 p) {
      final b = PlanBuilder(graph: street)
        ..beginSite('SKEW',
            program: SiteProgram.installation,
            flags: kPlanNetwork,
            graphStamp: street.structureStamp,
            graphLot: lot,
            frameE: 0,
            frameN: 0,
            frameUE: 1,
            frameUN: 0)
        ..join(
            slot: 0,
            ref: ref,
            piece: slot.piece,
            roadS: slot.s,
            right: slot.right,
            dirs: slot.dirs,
            roadNo: street.pieceRoad[slot.piece]);
      const r = 0.05;
      b
        ..pave([
          b.point(p.e - r, p.n - r),
          b.point(p.e + r, p.n - r),
          b.point(p.e + r, p.n + r),
          b.point(p.e - r, p.n + r),
        ])
        ..endSite();
      return b.build(validate: false).plan(0);
    }

    List<String> paving(List<String> lines) =>
        [for (final l in lines) if (l.startsWith('paving')) l];

    final checked = <double, int>{0: 0, 6: 0};
    for (final k in const [0.0, 6.0]) {
      for (final deg in const [-59.0, -40.0, 40.0, 59.0]) {
        for (final atLeft in const [true, false]) {
          final a = deg * math.pi / 180;
          final v0 = Vec2(0, slot.normN.sign);
          const u0 = Vec2(1, 0);
          final u = u0 * math.cos(a) + v0 * math.sin(a);
          final v = v0 * math.cos(a) - u0 * math.sin(a);
          // The kerb 1 m inside one side line, the frontage line k m behind
          // it along v (k = 0: through the kerb; k = 6: a set-back leg).
          final p0 = (atLeft ? c0 - u * 1 : c0 - u * 59) + v * k;
          final p1 = p0 + u * 60;
          final parcel = Parcel(
              id: 'site',
              polygon: [p0, p1, p1 + v * 80, p0 + v * 80],
              frontage: (p0, p1));
          final ctx = SiteContext.debug(street, parcel, pump.spec,
              slots: [slot], slotRefs: [ref], graphLot: lot);
          final frame = ctx.frame!;
          final line = corridorLineOf(frame, slot);
          expect(line, hasLength(k == 0 ? 1 : 2));
          final start = line.last;
          final ext = h * nrm.dot(frame.u).abs() / nrm.dot(frame.v);
          // Samples of the run-on rectangle: past a side line beyond the
          // frontage line, and in front of the frontage line.
          Vec2? past, front;
          for (var s = 0.2; s < ext - 0.2; s += 0.1) {
            for (var t = -h + 0.2; t < h - 0.2; t += 0.1) {
              final p = start + nrm * s + nrm.perp * t;
              final l = frame.toLocal(p);
              if (l.n > 0.3 && (l.e < -0.3 || l.e > frame.widthM + 0.3)) {
                past ??= p;
              }
              if (l.n < -0.3) front ??= p;
            }
          }
          if (past == null) continue;
          checked[k] = checked[k]! + 1;
          final bad = paving(sitePavingViolations(ctx, skeleton(past)));
          expect(bad, hasLength(1), reason: 'k $k, $deg° ${bad.join('\n')}');
          expect(bad.single, startsWith('paving [SKEW]: pave 0'));
          expect(paving(sitePavingViolations(ctx, skeleton(front!))), isEmpty,
              reason: 'k $k, $deg°');
        }
      }
    }
    expect(checked[0.0], greaterThanOrEqualTo(2));
    expect(checked[6.0], greaterThanOrEqualTo(2));
  });

  test('a kerbside plan has nothing to check', () {
    final b = PlanBuilder(graph: g);
    emitKerbOnly(b, pump);
    expect(sitePavingViolations(pump, b.build().plan(0)), isEmpty);
  });
}
