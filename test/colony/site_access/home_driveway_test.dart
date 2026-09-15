// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/home_driveway.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

import 'site_plan_fixtures.dart';

/// The home driveway and pad (docs/plans/site-access.md §3.4) and the home
/// back-out eligibility (§3.3 rules 1–4), through the dispatcher.
///
/// The lots are drawn by hand on a real slot so the join sits EXACTLY 4.5 m
/// from its lot line (k = 3): lot-r0-l3 of a 400 m street joins at s = 103.5,
/// its drive end the lot line at s = 108 (§3.2), so a lot [108 − W, 108] deep
/// D behind the pavement is §3.4's auto lot with x_d = 4.5.
void main() {
  final rLow = kZoneSpecs['residential']![Density.low]!;
  final rMed = kZoneSpecs['residential']![Density.medium]!;

  CityLayout layoutOf(List<RoadSpline> roads) {
    final layout = CityLayout();
    for (final r in roads) {
      layout.addRoad(r);
    }
    return layout;
  }

  final street = RoadGraph.of(layoutOf(const [
    RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(400, 0)]),
  ]));
  final lot = street.lotNoOf('lot-r0-l3')!;
  final ref = street.joinRefOf(lot, 0);
  final slot = street.joinOfRef(ref)!;
  final spans = SyntheticSites.laneSpansOf(street);

  setUpAll(() {
    expect(slot.s, 103.5);
    expect(slot.flags, kJoinCut);
    expect(slot.normE, 0);
  });

  /// A lot of frontage [w] (s from 108 − w to 108) and depth [d] behind the
  /// pavement, or the [shape] given in (s, depth-into-lot) pairs.
  Parcel lotOf(double w, double d, {List<(double, double)>? shape}) {
    final sn = slot.normN.sign;
    final yF = slot.kerbN + 3 * sn;
    Vec2 at(double s, double depth) => Vec2(s, yF + depth * sn);
    final poly = shape == null
        ? [at(108 - w, 0), at(108, 0), at(108, d), at(108 - w, d)]
        : [for (final (s, dd) in shape) at(s, dd)];
    return Parcel(
      id: 'lot-r0-l3',
      polygon: poly,
      roadId: 'r0',
      frontage: (at(108 - w, 0), at(108, 0)),
    );
  }

  SiteContext ctxOf(Parcel p,
          {CityBuildingSpec? spec, JoinSlot? s, RoadGraph? g, int? r, int? l}) =>
      SiteContext.debug(g ?? street, p, spec ?? rLow,
          slots: [s ?? slot], slotRefs: [r ?? ref], graphLot: l ?? lot);

  /// Plans [ctx] alone; the chunk's one plan (validated unless [check] is
  /// false) and the stats.
  (SiteAccessPlan?, SiteProgramStats) plan(SiteContext ctx,
      {bool check = true, List<SiteLaneSpans>? laneSpans}) {
    final stats = SiteProgramStats();
    final b = PlanBuilder(graph: ctx.graph);
    final program = planSite(b, ctx, stats: stats);
    if (program == null) return (null, stats);
    final chunk = b.build(validate: false);
    final p = chunk.plan(0);
    if (check) {
      final bad = SitePlanValidator.validate(p,
          graph: ctx.graph, laneSpans: laneSpans ?? const []);
      expect(bad, isEmpty, reason: bad.join('\n'));
    }
    return (p, stats);
  }

  HomeVariant? variantOf(SiteAccessPlan p) {
    if (p.program != SiteProgram.homeDriveway) return null;
    final w = p.segWidthM(0);
    if ((w - kHomeSideBySideWidthM).abs() < 1e-4) return HomeVariant.sideBySide;
    return p.stallCount == 2 ? HomeVariant.tandem : HomeVariant.single;
  }

  group('§3.4 thresholds, exact at the boundaries (k = 3, x_d = 4.5)', () {
    test('the join is 4.5 m from its lot line', () {
      final ctx = ctxOf(lotOf(17.6, 32));
      final x = ctx.kerbLocal(slot);
      expect(math.min(x.e, ctx.widthM - x.e), closeTo(4.5, 1e-9));
      expect(-x.n, closeTo(3, 1e-9));
    });

    test('frontage: 16.59 kerb, 16.6 tandem, 17.59 tandem, 17.6 side by side',
        () {
      for (final (w, want) in [
        (16.5, null),
        (16.59, null),
        (16.6, HomeVariant.tandem),
        (17.5, HomeVariant.tandem),
        (17.59, HomeVariant.tandem),
        (17.6, HomeVariant.sideBySide),
        (24.0, HomeVariant.sideBySide),
      ]) {
        final (p, stats) = plan(ctxOf(lotOf(w, 32)), laneSpans: spans);
        expect(variantOf(p!), want, reason: 'W $w');
        if (want == null) {
          expect(p.program, SiteProgram.kerbOnly, reason: 'W $w');
          expect(p.flags & kPlanFallback, kPlanFallback);
          expect(stats.demotionCount(SiteDemotion.homeGeometry), 1);
        } else {
          expect(stats.programCount(SiteProgram.homeDriveway), 1);
        }
      }
    });

    test('depth: 14.99 kerb, 15 home', () {
      final (short, s1) = plan(ctxOf(lotOf(24, 14.99)));
      expect(short!.program, SiteProgram.kerbOnly);
      expect(s1.demotionCount(SiteDemotion.homeGeometry), 1);
      final (deep, _) = plan(ctxOf(lotOf(24, 15)), laneSpans: spans);
      expect(variantOf(deep!), HomeVariant.sideBySide);
      // The house stands to 3 m short of the rear line.
      expect(deep.envY1 - deep.envY0, closeTo(kHomeMinHouseM, 1e-6));
    });

    test('a single stall only where the drive\'s columns are under 14.9 m deep',
        () {
      // W 17 (tandem width): the drive's columns (s ≥ 101.4) are 12 m deep,
      // the house's 32 m.
      const shape = [
        (91.0, 0.0), (108.0, 0.0), (108.0, 12.0), (101.4, 12.0), (101.4, 32.0),
        (91.0, 32.0), //
      ];
      final (p, _) =
          plan(ctxOf(lotOf(17, 32, shape: shape)), laneSpans: spans);
      expect(variantOf(p!), HomeVariant.single);
      expect(p.stallCount, 1);
      // 14.9 m deep over the drive: tandem again.
      final deeper = [
        for (final (s, d) in shape) (s, d == 12.0 ? 14.9 : d),
      ];
      final (t, _) = plan(ctxOf(lotOf(17, 32, shape: deeper)));
      expect(variantOf(t!), HomeVariant.tandem);
    });

    test('r-med never gets a driveway', () {
      // (A car park, or kerb parking while that generator finds none.)
      final (p, stats) = plan(ctxOf(lotOf(24, 32), spec: rMed));
      expect(p!.program, isNot(SiteProgram.homeDriveway));
      expect(stats.programCount(SiteProgram.homeDriveway), 0);
      expect(
          classifyProgram(
                  spec: rMed,
                  slot0: slot,
                  widthM: 24,
                  depthM: 32,
                  hasFrame: true,
                  lotBuilt: (_) => false)
              .program,
          SiteProgram.carPark);
    });
  });

  test('a home plan is one straight run with inline stalls and no turnaround',
      () {
    for (final (w, variant) in [
      (24.0, HomeVariant.sideBySide),
      (17.0, HomeVariant.tandem),
    ]) {
      final (p, _) = plan(ctxOf(lotOf(w, 32)), laneSpans: spans);
      expect(variantOf(p!), variant);
      expect(p.flags & kPlanNetwork, kPlanNetwork);
      expect(p.flags & kPlanFallback, 0);
      expect(p.joinCount, 1);
      expect(p.joinCutHalfM(0), kHomeCutHalfM);
      expect(p.nodeCount, 3);
      expect(p.segCount, 2);
      for (var n = 0; n < p.nodeCount; n++) {
        expect(p.nodeTurnKind(n), TurnaroundKind.none);
      }
      expect(p.segKind(0), SiteSegmentKind.driveway);
      expect(p.segFlags(0) & kSegThroat, kSegThroat);
      expect(p.segFlags(0) & kSegCrossesPavement, kSegCrossesPavement);
      expect(p.segLenM(0), closeTo(7.0, 1e-9));
      expect(p.segKind(1), SiteSegmentKind.apron);
      expect(p.segLenM(1), closeTo(5.2 * variant.rows, 1e-9));
      expect(p.nodeFlags(2) & kNodeDeadEnd, kNodeDeadEnd);
      // Collinear along the road normal: K, H and P share the join's e.
      for (var n = 0; n < 3; n++) {
        expect(p.nodeE(n), closeTo(slot.kerbE, 1e-9));
      }
      expect(p.stallCount, 2);
      var lastS = -1.0;
      for (var i = 0; i < p.stallCount; i++) {
        expect(p.stallAngle(i), StallAngle.inline);
        expect(p.stallInDirs(i), kSiteDirFwd);
        expect(p.stallOutDirs(i), kSiteDirBwd);
        expect(p.stallSeg(i), 1);
        expect(p.stallS(i), greaterThanOrEqualTo(lastS));
        lastS = p.stallS(i);
        // Nose along +n, into the lot.
        expect(p.stallDirE(i) * slot.normE + p.stallDirN(i) * slot.normN,
            closeTo(1, 1e-6));
      }
      if (variant == HomeVariant.tandem) {
        expect(p.stallS(1), closeTo(5.2, 1e-6));
      }
    }
  });

  group('§3.3 back-out eligibility, demotions counted by rule', () {
    test('rule 1: road class, speed and median', () {
      final layout = layoutOf([
        for (final (i, cls, deco) in const [
          (0, RoadClass.street, RoadDecoration.none),
          (1, RoadClass.streetOneWay, RoadDecoration.none),
          (2, RoadClass.path, RoadDecoration.none),
          (3, RoadClass.avenue, RoadDecoration.none),
          (4, RoadClass.boulevard, RoadDecoration.none),
          (5, RoadClass.highway, RoadDecoration.none),
          (6, RoadClass.avenue, RoadDecoration.grass),
        ])
          RoadSpline(
              id: 'c$i',
              controls: [Vec2(0, 1000.0 * i), Vec2(400, 1000.0 * i)],
              roadClass: cls,
              decoration: deco),
      ]);
      final g = RoadGraph.of(layout);
      final all = SiteProgramStats();
      for (final (i, home) in const [
        (0, true), (1, true), (2, true), (3, true), //
        (4, false), (5, false), (6, false),
      ]) {
        final id = 'lot-c$i-l3';
        final parcel = layout.parcelById(id);
        expect(parcel, isNotNull, reason: id);
        expect(g.lotNoOf(id), isNotNull, reason: id);
        final ctx = SiteContext.ofLot(g, parcel!, rLow);
        final (p, stats) = plan(ctx);
        all.addAll(stats);
        expect(p!.program,
            home ? SiteProgram.homeDriveway : SiteProgram.kerbOnly,
            reason: '$id ${g.roads[g.pieceRoad[ctx.slot0.piece]].roadClass}');
        if (!home) expect(stats.demotionCount(SiteDemotion.homeRoad), 1);
        if (i == 3) {
          // An avenue's join holds only the near direction.
          expect(ctx.slot0.dirs, isNot(RoadGraph.forwardBit | RoadGraph.backwardBit));
        }
      }
      expect(all.demotionCount(SiteDemotion.homeRoad), 3);
      expect(homeRoadEligible(const RoadSpline(
              id: 'a', controls: [Vec2(0, 0), Vec2(1, 0)],
              roadClass: RoadClass.alley)),
          isTrue);
      for (final cls in [
        RoadClass.trunk, RoadClass.motorway, RoadClass.ramp, RoadClass.expressway4,
      ]) {
        expect(homeRoadEligible(RoadSpline(
                id: 'x', controls: const [Vec2(0, 0), Vec2(1, 0)],
                roadClass: cls)),
            isFalse,
            reason: '$cls');
      }
    });

    test('rule 1: an alley-only footprint gets its driveway', () {
      // A 24 × 32 m site 3 m off the kerb of a lone alley.
      final alley = RoadGraph.of(layoutOf(const [
        RoadSpline(
            id: 'al',
            controls: [Vec2(0, 0), Vec2(400, 0)],
            roadClass: RoadClass.alley),
      ]));
      final hw = RoadClass.alley.halfWidth;
      final y0 = hw + 3;
      final parcel = Parcel(id: 'cell-al', polygon: [
        Vec2(180, y0), Vec2(204, y0), Vec2(204, y0 + 32), Vec2(180, y0 + 32),
      ]);
      final ctx = SiteContext.ofFootprint(alley, parcel, rLow);
      expect(ctx.slotCount, greaterThan(0));
      final (p, stats) = plan(ctx);
      expect(p!.program, SiteProgram.homeDriveway, reason: '$stats');
      expect(p.segFlags(0) & kSegCrossesPavement, 0,
          reason: 'an alley has no pavement');
    });

    test('rule 2: slot room 3.9 is kerb, 4.0 is a home', () {
      JoinSlot withRoom(double room) => JoinSlot(
            piece: slot.piece, s: slot.s, dirs: slot.dirs, right: slot.right,
            flags: slot.flags, roomM: room, kerbE: slot.kerbE,
            kerbN: slot.kerbN, normE: slot.normE, normN: slot.normN);
      final (p, stats) = plan(ctxOf(lotOf(24, 32), s: withRoom(3.9)));
      expect(p!.program, SiteProgram.kerbOnly);
      expect(stats.demotionCount(SiteDemotion.homeRoom), 1);
      final (q, _) = plan(ctxOf(lotOf(24, 32), s: withRoom(4.0)));
      expect(q!.program, SiteProgram.homeDriveway);
    });

    test('rule 3: a swing margin 0.1 m short on a served side is kerb', () {
      final w = street.kerbWindows;
      final k0 = w.start[slot.piece];
      final lo = w.lo[k0], hi = w.hi[w.start[slot.piece + 1] - 1];
      JoinSlot at(double s, int dirs) => JoinSlot(
            piece: slot.piece, s: s, dirs: dirs, right: slot.right,
            flags: slot.flags, roomM: 4.5, kerbE: s, kerbN: slot.kerbN,
            normE: slot.normE, normN: slot.normN);
      final v = Vec2(slot.normE, slot.normN);
      const both = RoadGraph.forwardBit | RoadGraph.backwardBit;
      // Both directions: 6 m each side.
      expect(homeBackOutFailure(street, at(lo + 6, both), v), isNull);
      expect(homeBackOutFailure(street, at(lo + 5.9, both), v),
          SiteDemotion.homeSwingMargin);
      expect(homeBackOutFailure(street, at(hi - 6, both), v), isNull);
      expect(homeBackOutFailure(street, at(hi - 5.9, both), v),
          SiteDemotion.homeSwingMargin);
      // Forward only (a one-way street, an avenue's near side): its upstream
      // side, lower s, needs 6 m; downstream only the 4 m cut half.
      const fwd = RoadGraph.forwardBit, bwd = RoadGraph.backwardBit;
      expect(homeBackOutFailure(street, at(lo + 5.9, fwd), v),
          SiteDemotion.homeSwingMargin);
      expect(homeBackOutFailure(street, at(hi - 4, fwd), v), isNull);
      expect(homeBackOutFailure(street, at(hi - 3.9, fwd), v),
          SiteDemotion.homeSwingMargin);
      // Backward only: the mirror.
      expect(homeBackOutFailure(street, at(lo + 4, bwd), v), isNull);
      expect(homeBackOutFailure(street, at(hi - 5.9, bwd), v),
          SiteDemotion.homeSwingMargin);
      // Through the dispatcher: counted.
      final stats = SiteProgramStats();
      final ctx = SiteContext.debug(street, lotOf(24, 32), rLow,
          slots: [at(lo + 5.9, both)], graphLot: lot);
      final b = PlanBuilder(graph: street);
      expect(planSite(b, ctx, stats: stats), SiteProgram.kerbOnly);
      expect(stats.demotionCount(SiteDemotion.homeSwingMargin), 1);
    });

    test('rule 4: v 10.1° off the road normal is kerb, 9.9° a home', () {
      Parcel skewed(double deg) {
        final t = deg * math.pi / 180;
        final n = Vec2(slot.normE, slot.normN);
        final t0 = Vec2(-slot.normN, slot.normE); // along the road
        // The frame's v turned by t from the normal, u across it; the lot
        // centred on the join, its frontage line 3 m behind the kerb.
        final v = n * math.cos(t) + t0 * math.sin(t);
        final u = Vec2(v.n, -v.e);
        final o = Vec2(slot.kerbE, slot.kerbN) + n * 3;
        Vec2 at(double x, double y) => o + u * x + v * y;
        // 30 m wide: a drive skewed 9.9° drifts 2 m across its 14 m.
        return Parcel(
          id: 'lot-r0-l3',
          polygon: [at(-15, 0), at(15, 0), at(15, 32), at(-15, 32)],
          roadId: 'r0',
          frontage: (at(-15, 0), at(15, 0)),
        );
      }

      final (p, stats) = plan(ctxOf(skewed(10.1)));
      expect(p!.program, SiteProgram.kerbOnly);
      expect(stats.demotionCount(SiteDemotion.homeSkew), 1);
      final (q, _) = plan(ctxOf(skewed(9.9)), laneSpans: spans);
      expect(q!.program, SiteProgram.homeDriveway);
    });
  });
}
