// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/installation_access.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_paving_check.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_plan_fixtures.dart';

/// Installations (docs/plans/site-access.md §3.7), called on the generator
/// and through the dispatcher: the four starter sites (56 m throat `K→F`
/// with vias, `Y` at y = 15, four bays, gate `G` on the fence line, the staff
/// car park outside `x_G ± 15` with at least 12 stalls), a 130 m-deep site
/// (`Df = 40`, bays dropped, trucks not admitted), a spine near a lot side
/// (no yard, branch `B`), a dogleg, and a narrow slot that fits no 7 m
/// throat. Every plan passes V1–V13 (V1 under the five override kinds) and
/// the R2 paving checks.
void main() {
  final starter = starterKit();
  final sg = starter.roadGraph;
  final starterSites = {
    for (final c in siteContextsOf(starter).take(4)) c.siteId: c,
  };
  final starterSpans = SyntheticSites.laneSpansOf(sg);

  /// Frame metres of world point ([e], [n]) in [p]'s site frame.
  Vec2 local(SiteAccessPlan p, double e, double n) {
    final de = e - p.frameE, dn = n - p.frameN;
    return Vec2(de * p.frameUE + dn * p.frameUN,
        de * p.frameVE + dn * p.frameVN);
  }

  /// Plans [ctx] alone and returns its plan, checked against V1–V13 and the
  /// paving checks.
  SiteAccessPlan planOf(SiteContext ctx, List<SiteLaneSpans> spans,
      {SiteProgramStats? stats}) {
    final b = PlanBuilder(graph: ctx.graph);
    expect(planSite(b, ctx, stats: stats), isNotNull);
    final p = b.build(validate: false).plan(0);
    final bad = [
      for (final v
          in SitePlanValidator.validate(p, graph: ctx.graph, laneSpans: spans))
        '$v',
      ...sitePavingViolations(ctx, p),
    ];
    expect(bad, isEmpty, reason: bad.join('\n'));
    return p;
  }

  int nodeWith(SiteAccessPlan p, int flag) {
    for (var n = 0; n < p.nodeCount; n++) {
      if (p.nodeFlags(n) & flag != 0) return n;
    }
    return -1;
  }

  group('the four starter sites', () {
    for (final id in const ['lot-m0', 'lot-m1', 'lot-m2', 'lot-m3']) {
      test('$id: 56 m throat K→F with vias, yard, gate on the fence line, '
          '≥ 12 stalls', () {
        final ctx = starterSites[id]!;
        final generated = installationPlanOf(ctx);
        expect(generated, isNotNull);
        final stats = SiteProgramStats();
        final p = planOf(ctx, starterSpans, stats: stats);
        expect(p.program, SiteProgram.installation);
        expect(p.flags & (kPlanFallback | kPlanAccessBlocked), 0);
        expect(p.hasNetwork, isTrue);
        expect(stats.programCount(SiteProgram.installation), 1);

        // The throat: segment 0, 56 m from the kerb node to the frontage
        // node F (y = 0), vias at 24 and 48 m.
        expect(p.joinThroatSeg(0), 0);
        expect(p.segKind(0), SiteSegmentKind.accessRoad);
        expect(p.segWidthM(0), kInstallationThroatWidthM);
        expect(p.segLenM(0), closeTo(56, 1e-6));
        expect(p.segFrom(0), p.joinKerbNode(0));
        expect(p.segViaCount(0), 2);
        final k = p.segFrom(0), f = p.segTo(0);
        for (final (i, at) in const [(1, 24.0), (2, 48.0)]) {
          final pt = p.segPoint(0, i);
          final d = Vec2(p.ptE(pt) - p.nodeE(k), p.ptN(pt) - p.nodeN(k));
          expect(d.length, closeTo(at, 1e-6));
        }
        final fl = local(p, p.nodeE(f), p.nodeN(f));
        expect(fl.n, closeTo(0, 1e-6));
        final xG = fl.e;
        expect(p.segFlags(0) & kSegThroat, kSegThroat);

        // Y: the 13 m circle at (x_G, 15).
        var y = -1;
        for (var n = 0; n < p.nodeCount; n++) {
          if (p.nodeTurnKind(n) == TurnaroundKind.circle) y = n;
        }
        expect(y, isNot(-1));
        expect(p.nodeTurnR(y), kInstallationCircleRadiusM);
        final yl = local(p, p.nodeE(y), p.nodeN(y));
        expect(yl.e, closeTo(xG, 1e-6));
        expect(yl.n, closeTo(15, 1e-6));

        // Four bays beside Y→G, trucks admitted on the 13 m circle.
        expect(p.bayCount, 4);
        expect(p.admitsTrucks, isTrue);
        expect(p.truckTurnRadiusM, kInstallationTruckTurnM);
        for (var bay = 0; bay < p.bayCount; bay++) {
          final bl = local(p, p.bayE(bay), p.bayN(bay));
          final dx = (bl.e - xG).abs();
          expect(dx - kLoadingBayWidthM / 2,
              greaterThanOrEqualTo(kInstallationBayInnerX0M - 1e-6));
          expect(dx + kLoadingBayWidthM / 2,
              lessThanOrEqualTo(kInstallationBayOuterX1M + 1e-6));
          expect(bl.n, closeTo(15 + 13 + 7.5, 1e-6));
        }

        // G on the fence line y = Df, the envelope's front edge, the door.
        final g = nodeWith(p, kNodeGate);
        expect(g, isNot(-1));
        final gl = local(p, p.nodeE(g), p.nodeN(g));
        expect(gl.e, closeTo(xG, 1e-6));
        expect(gl.n, closeTo(p.envY0, 1e-4));
        expect(p.envFrontInset, closeTo(p.envY0, 1e-4));
        expect(p.envY0, greaterThanOrEqualTo(46 - 1e-4));
        expect(p.gateX, closeTo(xG, 1e-4));
        expect(p.nodeTurnKind(g), TurnaroundKind.hammerhead);
        expect(p.entranceNode, g);

        // The staff car park: at least 12 stalls, every stall outside
        // x_G ± 15 and at |x − x_G| ≥ 21.
        expect(p.stallCount, greaterThanOrEqualTo(kInstallationMinStalls));
        for (var i = 0; i < p.stallCount; i++) {
          final sl = local(p, p.stallE(i), p.stallN(i));
          final near = (sl.e - xG).abs() - kStallLengthM / 2;
          expect(near, greaterThanOrEqualTo(21 - 1e-4));
          expect(sl.n + kStallWidthM / 2, lessThanOrEqualTo(p.envY0 - 6 + 1e-4));
        }
        expect(generated!.carPark!.stallCount, p.stallCount);
      });
    }

    test('no starter site is access blocked, and each is planned alike twice',
        () {
      for (final ctx in starterSites.values) {
        final a = planOf(ctx, const []);
        final b = planOf(ctx, const []);
        expect(a.flags & kPlanAccessBlocked, 0);
        expect(b.rev, a.rev);
      }
    });
  });

  group('synthetic sites on a 1000 m street', () {
    final layout = CityLayout()
      ..addRoad(const RoadSpline(
          id: 'r0', controls: [Vec2(0, 0), Vec2(1000, 0)]));
    final g = RoadGraph.of(layout);
    final spans = SyntheticSites.laneSpansOf(g);
    final spec = starterSites['lot-m0']!.spec!; // the spaceport pad
    // A cut slot near the street's middle.
    late final int lot;
    late final int ref;
    late final JoinSlot slot;
    for (var l = 0; l < g.lotCount; l++) {
      final r = g.joinRefOf(l, 0);
      final s = g.joinOfRef(r);
      if (s == null || s.flags & kJoinCut == 0) continue;
      if (s.s < 480 || s.s > 520 || s.roomM < 4.5) continue;
      lot = l;
      ref = r;
      slot = s;
      break;
    }

    /// A lot from s − [back] to s + [ahead] along the street, [k] m behind
    /// the kerb, [depth] deep.
    Parcel lotOf(double back, double ahead, double depth, {double k = 3}) {
      final sn = slot.normN.sign;
      Vec2 at(double x, double yy) => Vec2(x, slot.kerbN + (k + yy) * sn);
      final x0 = slot.s - back, x1 = slot.s + ahead;
      return Parcel(
        id: 'site',
        polygon: [at(x0, 0), at(x1, 0), at(x1, depth), at(x0, depth)],
        frontage: (at(x0, 0), at(x1, 0)),
      );
    }

    SiteContext ctxOf(Parcel p, {JoinSlot? s, CityBuildingSpec? sp}) =>
        SiteContext.debug(g, p, sp ?? spec,
            slots: [s ?? slot], slotRefs: [ref], graphLot: lot);

    test('D = 130: Df = 40, the bays are dropped, trucks not admitted', () {
      final ctx = ctxOf(lotOf(100, 100, 130));
      expect(ctx.depthM, closeTo(130, 1e-6));
      final plan = installationPlanOf(ctx);
      expect(plan, isNotNull);
      expect(plan!.forecourtDepthM, closeTo(40, 1e-9));
      expect(plan.bays, isEmpty);
      expect(plan.admitsTrucks, isFalse);
      expect(plan.yard, isTrue);
      final p = planOf(ctx, spans);
      expect(p.program, SiteProgram.installation);
      expect(p.admitsTrucks, isFalse);
      expect(p.truckTurnRadiusM, 0);
      expect(p.bayCount, 0);
      expect(p.envY0, closeTo(40, 1e-4));
      // T at y = 12 − k = 9; the car park inside the band y ∈ [0.3, 34].
      expect(plan.spineY, closeTo(9, 1e-9));
      final cp = plan.carPark;
      expect(cp, isNotNull);
      expect(cp!.paveY0, greaterThanOrEqualTo(0.3 - 1e-9));
      expect(cp.depthM, lessThanOrEqualTo(34 + 1e-9));
      expect(p.stallCount, greaterThan(0));
    });

    test('a spine near a lot side: no yard, branch node B at yS + 7', () {
      final ctx = ctxOf(lotOf(10, 190, 200));
      final plan = installationPlanOf(ctx)!;
      expect(plan.yard, isFalse);
      expect(plan.bays, isEmpty);
      expect(plan.branchY, closeTo(plan.spineY + 7, 1e-9));
      final p = planOf(ctx, spans);
      for (var n = 0; n < p.nodeCount; n++) {
        expect(p.nodeTurnKind(n), isNot(TurnaroundKind.circle));
      }
      expect(p.bayCount, 0);
      expect(p.admitsTrucks, isFalse);
      expect(p.stallCount, greaterThanOrEqualTo(kInstallationMinStalls));
    });

    test('a dogleg (kJoinOffFrontage) follows the corridor K → T → Q → F', () {
      // The lot's frontage 20 m behind the kerb, wholly beside the slot.
      final parcel = lotOf(-50, 250, 200, k: 20);
      final off = JoinSlot(
        piece: slot.piece,
        s: slot.s,
        dirs: slot.dirs,
        right: slot.right,
        flags: slot.flags | kJoinOffFrontage,
        roomM: slot.roomM,
        kerbE: slot.kerbE,
        kerbN: slot.kerbN,
        normE: slot.normE,
        normN: slot.normN,
      );
      final ctx = ctxOf(parcel, s: off);
      final plan = installationPlanOf(ctx)!;
      expect(plan.dogleg, isNotNull);
      expect(plan.gateX, closeTo(kDoglegSideClearM, 1e-6));
      final p = planOf(ctx, spans);
      expect(p.segLenM(0), closeTo(kDoglegThroatM, 1e-6));
      final line = corridorLineOf(ctx.frame!, off);
      expect(line, hasLength(4));
      // Every corridor corner is a plan node, in order.
      for (final c in line) {
        var found = false;
        for (var n = 0; n < p.nodeCount; n++) {
          if (Vec2(p.nodeE(n), p.nodeN(n)).distanceTo(c) < 1e-6) found = true;
        }
        expect(found, isTrue, reason: '$c');
      }
    });

    test('a slot too narrow for a 7 m throat (room 4.0) falls back to kerbOnly',
        () {
      final narrow = JoinSlot(
        piece: slot.piece,
        s: slot.s,
        dirs: slot.dirs,
        right: slot.right,
        flags: slot.flags,
        roomM: 4.0,
        kerbE: slot.kerbE,
        kerbN: slot.kerbN,
        normE: slot.normE,
        normN: slot.normN,
      );
      final ctx = ctxOf(lotOf(100, 100, 300), s: narrow);
      expect(installationPlanOf(ctx), isNull);
      final stats = SiteProgramStats();
      final p = planOf(ctx, spans, stats: stats);
      expect(p.program, SiteProgram.kerbOnly);
      expect(p.flags & kPlanFallback, kPlanFallback);
      expect(stats.demotionCount(SiteDemotion.installationNoFit), 1);
      // The same lot with its real slot is an installation.
      expect(installationPlanOf(ctxOf(lotOf(100, 100, 300))), isNotNull);
    });
  });
}
