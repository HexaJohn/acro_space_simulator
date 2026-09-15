// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/car_park_packer.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_plan_fixtures.dart';
import 'site_random_sites.dart';

/// The car park / yard track of slice R2 (docs/plans/site-access.md §3.5,
/// §3.6, §3.8, §3.9, §7.2 asks 5, 7, 8 and 9, §8.3 `car_park_packer_test`).
void main() {
  final cLow = kZoneSpecs['commercial']![Density.low]!;
  final cMed = kZoneSpecs['commercial']![Density.medium]!;
  final cHigh = kZoneSpecs['commercial']![Density.high]!;
  final iMed = kZoneSpecs['industrial']![Density.medium]!;

  /// One street; its lot 3's slot 0 is the join of every hand-drawn lot.
  final layout = CityLayout()
    ..addRoad(const RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(400, 0)]));
  final g = RoadGraph.of(layout);
  final lotParcel = layout.parcelById('lot-r0-l3')!;
  final lot = g.lotNoOf(lotParcel.id)!;
  final ref = g.joinRefOf(lot, 0);
  final slot = g.joinOfRef(ref)!;
  late final List<SiteLaneSpans> spans = SyntheticSites.laneSpansOf(g);

  /// A lot drawn in local metres (x along the street, y into the lot, the
  /// frontage on y = 0, 3 m behind the kerb) with slot 0 at local x [xJ].
  Parcel drawn(List<(double, double)> local, double xJ) {
    final sn = slot.normN.sign;
    final yF = slot.kerbN + 3 * sn;
    Vec2 at(double x, double y) => Vec2(slot.s - xJ + x, yF + y * sn);
    var x0 = double.infinity, x1 = double.negativeInfinity;
    for (final (x, y) in local) {
      if (y != 0) continue;
      x0 = math.min(x0, x);
      x1 = math.max(x1, x);
    }
    return Parcel(
      id: lotParcel.id,
      polygon: [for (final (x, y) in local) at(x, y)],
      roadId: 'r0',
      frontage: (at(x0, 0), at(x1, 0)),
    );
  }

  Parcel rect(double w, double d, {double? xJ}) =>
      drawn([(0, 0), (w, 0), (w, d), (0, d)], xJ ?? w / 2);

  SiteContext on(Parcel p, CityBuildingSpec spec, {JoinSlot? withSlot}) =>
      SiteContext.debug(g, p, spec,
          slots: [withSlot ?? slot], slotRefs: [ref], graphLot: lot);

  /// Plans [ctx] through the dispatcher and validates it (V1–V13 with the
  /// lane spans of every override kind).
  (SiteAccessPlan, SiteProgramStats) plan(SiteContext ctx,
      {RoadGraph? graph, List<SiteLaneSpans>? laneSpans}) {
    final gr = graph ?? g;
    final stats = SiteProgramStats();
    final b = PlanBuilder(graph: gr);
    expect(planSite(b, ctx, stats: stats), isNotNull, reason: ctx.siteId);
    final p = b.build(validate: false).plan(0);
    final bad = SitePlanValidator.validate(p,
        graph: gr, laneSpans: laneSpans ?? (graph == null ? spans : const []));
    expect(bad, isEmpty, reason: '${ctx.siteId}: ${bad.join('\n')}');
    return (p, stats);
  }

  /// Every stall rectangle of [p] lies inside the lot (§3.8: stalls never
  /// outside, whatever the shape).
  void stallsInside(SiteContext ctx, SiteAccessPlan p) {
    final f = ctx.frame!;
    for (var i = 0; i < p.stallCount; i++) {
      final c = f.toLocal(Vec2(p.stallE(i), p.stallN(i)));
      final d = Vec2(p.stallDirE(i) * f.u.e + p.stallDirN(i) * f.u.n,
          p.stallDirE(i) * f.v.e + p.stallDirN(i) * f.v.n);
      final hx = d.e.abs() * kStallLengthM / 2 + d.n.abs() * kStallWidthM / 2;
      final hy = d.n.abs() * kStallLengthM / 2 + d.e.abs() * kStallWidthM / 2;
      const t = 1e-6;
      expect(
          f.profile.containsRect(
              SiteRect(c.e - hx + t, c.n - hy + t, c.e + hx - t, c.n + hy - t)),
          isTrue,
          reason: '${ctx.siteId} stall $i at $c');
    }
  }

  /// Frame corners of pave ring [q] of [p].
  List<Vec2> paveRing(SiteContext ctx, SiteAccessPlan p, int q) => [
        for (var i = p.paveStart(q); i < p.paveStart(q + 1); i++)
          ctx.frame!.toLocal(Vec2(p.ptE(p.pavePt(i)), p.ptN(p.pavePt(i)))),
      ];

  /// Every circle turnaround of [p]: its bounding square inside the lot
  /// (§3.7 step 4's rule) and inside one pave ring (§2.4: paving stays in
  /// the parcel, and the envelope keeps clear of it). Returns the circles.
  int circlesInsideAndPaved(SiteContext ctx, SiteAccessPlan p) {
    final f = ctx.frame!;
    var circles = 0;
    for (var n = 0; n < p.nodeCount; n++) {
      if (p.nodeTurnKind(n) != TurnaroundKind.circle) continue;
      circles++;
      final c = f.toLocal(Vec2(p.nodeE(n), p.nodeN(n)));
      final r = p.nodeTurnR(n);
      const t = 1e-6;
      expect(
          f.profile.containsRect(
              SiteRect(c.e - r + t, c.n - r + t, c.e + r - t, c.n + r - t)),
          isTrue,
          reason: '${ctx.siteId}: circle at $c leaves the lot');
      var paved = false;
      for (var q = 0; q < p.paveCount && !paved; q++) {
        final ring = paveRing(ctx, p, q);
        var x0 = double.infinity, y0 = double.infinity;
        var x1 = double.negativeInfinity, y1 = double.negativeInfinity;
        for (final v in ring) {
          x0 = math.min(x0, v.e);
          y0 = math.min(y0, v.n);
          x1 = math.max(x1, v.e);
          y1 = math.max(y1, v.n);
        }
        paved = x0 <= c.e - r + 1e-5 &&
            y0 <= c.n - r + 1e-5 &&
            x1 >= c.e + r - 1e-5 &&
            y1 >= c.n + r - 1e-5;
      }
      expect(paved, isTrue, reason: '${ctx.siteId}: circle at $c not paved');
    }
    return circles;
  }

  /// The footpath of [p] (§6.1 step 6): frame-axis-aligned legs from the
  /// pavement point on y = 0 to the door, crossing no stall or bay rectangle
  /// and running along no lane laid along v. Returns the crossings.
  List<String> footpathCrossings(SiteContext ctx, SiteAccessPlan p) {
    final f = ctx.frame!;
    final out = <String>[];
    Vec2 local(int pt) => f.toLocal(Vec2(p.ptE(pt), p.ptN(pt)));
    final pts = [
      for (var i = p.pathStart(0); i < p.pathStart(1); i++) local(p.pathPt(i)),
    ];
    expect(pts.first.n, closeTo(0, 1e-6), reason: ctx.siteId);
    final door = local(p.entrancePt);
    expect(pts.last.e, closeTo(door.e, 1e-9));
    expect(pts.last.n, closeTo(door.n, 1e-9));
    final rects = <(String, SiteRect)>[];
    for (var i = 0; i < p.stallCount; i++) {
      final ce = f.toLocal(Vec2(p.stallE(i), p.stallN(i)));
      final du = p.stallDirE(i) * f.u.e + p.stallDirN(i) * f.u.n;
      final ex = du.abs() > 0.5 ? kStallLengthM / 2 : kStallWidthM / 2;
      final ey = du.abs() > 0.5 ? kStallWidthM / 2 : kStallLengthM / 2;
      rects.add(('stall $i', SiteRect(ce.e - ex, ce.n - ey, ce.e + ex, ce.n + ey)));
    }
    for (var b = 0; b < p.bayCount; b++) {
      final ce = f.toLocal(Vec2(p.bayE(b), p.bayN(b)));
      final du = p.bayDirE(b) * f.u.e + p.bayDirN(b) * f.u.n;
      final ex = du.abs() > 0.5 ? kLoadingBayLengthM / 2 : kLoadingBayWidthM / 2;
      final ey = du.abs() > 0.5 ? kLoadingBayWidthM / 2 : kLoadingBayLengthM / 2;
      rects.add(('bay $b', SiteRect(ce.e - ex, ce.n - ey, ce.e + ex, ce.n + ey)));
    }
    for (var k = 0; k < p.segCount; k++) {
      // "Never runs along a throat" (§6.1): the drives; aisles are gaps.
      if (p.segKind(k) != SiteSegmentKind.driveway) continue;
      final a = f.toLocal(Vec2(p.nodeE(p.segFrom(k)), p.nodeN(p.segFrom(k))));
      final b = f.toLocal(Vec2(p.nodeE(p.segTo(k)), p.nodeN(p.segTo(k))));
      if ((a.e - b.e).abs() > 1e-6) continue;
      final hw = p.segWidthM(k) / 2;
      rects.add((
        'drive $k along v',
        SiteRect(a.e - hw, math.min(a.n, b.n), a.e + hw, math.max(a.n, b.n))
      ));
    }
    const t = 1e-6;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i], b = pts[i + 1];
      final vertical = (a.e - b.e).abs() <= 1e-6;
      expect(vertical || (a.n - b.n).abs() <= 1e-6, isTrue,
          reason: '${ctx.siteId}: path leg $i is not frame-aligned');
      for (final (what, r) in rects) {
        // A drive along v is only met by running along it.
        if (!vertical && what.startsWith('drive')) continue;
        final hitX = vertical
            ? a.e > r.x0 + t && a.e < r.x1 - t
            : math.max(math.min(a.e, b.e), r.x0) < math.min(math.max(a.e, b.e), r.x1) - t;
        final hitY = vertical
            ? math.max(math.min(a.n, b.n), r.y0) < math.min(math.max(a.n, b.n), r.y1) - t
            : a.n > r.y0 + t && a.n < r.y1 - t;
        if (hitX && hitY) out.add('${ctx.siteId}: path leg $i crosses $what');
      }
    }
    return out;
  }

  /// The throat of [p] runs along slot 0's road normal, and every pave
  /// corner off the parcel (frame y < 0) lies inside the slot's §3.7a
  /// corridor, the 4.5 m band along that normal from the kerb point.
  void throatInCorridor(SiteContext ctx, SiteAccessPlan p) {
    final f = ctx.frame!;
    final s = ctx.slot0;
    final k0 = p.segFrom(0), k1 = p.segTo(0);
    final de = p.nodeE(k1) - p.nodeE(k0), dn = p.nodeN(k1) - p.nodeN(k0);
    final len = math.sqrt(de * de + dn * dn);
    final cosToNormal = (de * s.normE + dn * s.normN) / len;
    for (var q = 0; q < p.paveCount; q++) {
      for (var i = p.paveStart(q); i < p.paveStart(q + 1); i++) {
        final pt = p.pavePt(i);
        final e = p.ptE(pt), n = p.ptN(pt);
        if (f.toLocal(Vec2(e, n)).n >= -1e-6) continue;
        final off = ((e - s.kerbE) * -s.normN + (n - s.kerbN) * s.normE).abs();
        expect(off, lessThanOrEqualTo(kAccessCorridorHalfM + 1e-6),
            reason: '${ctx.siteId}: pave $q corner ${off.toStringAsFixed(3)} m '
                'off the road normal (throat cos ${cosToNormal.toStringAsFixed(6)})');
      }
    }
  }

  /// The repair round's checks on a written car park or yard: circles in
  /// the lot and paved, the footpath clear of stalls, bays and lanes along
  /// v, and the throat inside the slot's corridor.
  void checkPark(SiteContext ctx, SiteAccessPlan p) {
    if (!p.hasNetwork) return;
    stallsInside(ctx, p);
    circlesInsideAndPaved(ctx, p);
    expect(footpathCrossings(ctx, p), isEmpty);
    throatInCorridor(ctx, p);
  }

  group('§3.5 worked example (c-med on a 24 × 32 auto lot, x_J 4.5)', () {
    final starter = starterKit();
    final sg = starter.roadGraph;
    late final SiteContext ctx = () {
      for (final p in starter.layout.autoParcels) {
        final c = SiteContext.ofLot(sg, p, cMed);
        if (c.slotCount == 0 || c.frame == null) continue;
        final kl = c.kerbLocal(c.slot0);
        if ((kl.e - 4.5).abs() < 1e-9 &&
            (kl.n + 3).abs() < 1e-9 &&
            (c.widthM - 24).abs() < 1e-9 &&
            (c.depthM - 32).abs() < 1e-9 &&
            c.slot0.roomM >= 4.0) {
          return c;
        }
      }
      throw StateError('no 24 × 32 starter lot with x_J 4.5');
    }();

    test('the fixture: A_min 264 m², C* 20, cap 30, throat 6 m', () {
      expect(minEnvelopeArea(cMed), closeTo(264, 1e-9));
      expect(capacityScoreCap(cMed), closeTo(30, 1e-9));
      expect(math.min(kCarParkThroatWidthM, 2 * (ctx.slot0.roomM - 1)), 6.0);
    });

    test('candidates: F1 double 90.11, F1 single 54.25, F2 and F3 rejected',
        () {
      final all = carParkCandidatesOf(ctx);
      CarParkCandidate find(CarParkFamily f, int m, bool single) => all
          .firstWhere((c) =>
              c.family == f && c.modules == m && c.singleLast == single);
      void env(SiteRect? r, double x0, double y0, double x1, double y1) {
        expect(r, isNotNull);
        expect(r!.x0, closeTo(x0, 1e-6));
        expect(r.y0, closeTo(y0, 1e-6));
        expect(r.x1, closeTo(x1, 1e-6));
        expect(r.y1, closeTo(y1, 1e-6));
      }

      final f1d = find(CarParkFamily.front, 1, false);
      expect(f1d.valid, isTrue, reason: '$f1d');
      expect(f1d.stallCount, 10);
      env(f1d.envelope, 1.5, 18.7, 22.5, 31.7);
      expect(f1d.driveLengthM, closeTo(11.5 + 19.2, 1e-6));
      expect(f1d.score, closeTo(90.11, 1e-6));

      final f1s = find(CarParkFamily.front, 1, true);
      expect(f1s.valid, isTrue);
      expect(f1s.stallCount, 6);
      env(f1s.envelope, 1.5, 14.2, 22.5, 31.7);
      expect(f1s.score, closeTo(54.25, 1e-6));

      final f2s = find(CarParkFamily.rear, 1, true);
      expect(f2s.valid, isFalse);
      expect(f2s.stallCount, 4);
      expect(f2s.driveLengthM - 19.2, closeTo(31.7, 1e-6));
      expect(f2s.envelope!.width * f2s.envelope!.depth, closeTo(254.8, 1e-6));
      expect(f2s.rejection, contains('A_min'));
      final f2d = find(CarParkFamily.rear, 1, false);
      expect(f2d.valid, isFalse);
      expect(f2d.envelope!.width * f2d.envelope!.depth, closeTo(182, 1e-6));

      final f3 = find(CarParkFamily.side, 1, true);
      expect(f3.valid, isFalse);
      // §3.5 says 7.8 m; the free rectangle's 0.5 m columns start at the
      // 1.5 m side setback, so the measured width is 7.5 m (both < 8).
      expect(f3.envelope!.width, lessThanOrEqualTo(7.8 + 1e-9));
      expect(f3.rejection, contains('8 x 8'));

      expect(all.where((c) => c.valid && c.score! > f1d.score!), isEmpty);
    });

    test('the winner is F1 double, drawn and valid exactly as §3.5 lists', () {
      final cp = carParkPlanOf(ctx)!;
      expect(cp.family, CarParkFamily.front);
      expect(cp.winner.modules, 1);
      expect(cp.winner.singleLast, isFalse);
      final (p, stats) = plan(ctx, graph: sg, laneSpans: SyntheticSites.laneSpansOf(sg));
      expect(p.program, SiteProgram.carPark);
      expect(p.flags & kPlanFallback, 0);
      expect(stats.programCount(SiteProgram.carPark), 1);
      final f = ctx.frame!;
      Vec2 local(double e, double n) => f.toLocal(Vec2(e, n));
      // Throat K(4.5, −3) → J(4.5, 8.5), aisle J → E(23.7, 8.5).
      expect(p.segCount, 2);
      expect(p.segLenM(0), closeTo(11.5, 1e-6));
      expect(p.segLenM(1), closeTo(19.2, 1e-6));
      expect(p.segWidthM(0), 6.0);
      expect(p.segLaneMode(0), SiteLaneMode.twoWay);
      expect(p.joinCutHalfM(0), 4.0);
      final e = local(p.nodeE(p.segTo(1)), p.nodeN(p.segTo(1)));
      expect(e.e, closeTo(23.7, 1e-6));
      expect(e.n, closeTo(8.5, 1e-6));
      expect(p.nodeTurnKind(p.segTo(1)), TurnaroundKind.hammerhead);
      // Row 1 (y [0.3, 5.5]) under the throat exclusion: x [8.5, 18.9];
      // row 2 (y [11.5, 16.7]): x [3.2, 18.8].
      final rows = <bool, List<double>>{true: [], false: []};
      for (var i = 0; i < p.stallCount; i++) {
        final c = local(p.stallE(i), p.stallN(i));
        rows[c.n < 8.5]!.add(c.e);
        expect(c.e + kStallWidthM / 2, lessThanOrEqualTo(20.7 + 1e-6));
      }
      final front = rows[true]!..sort();
      final back = rows[false]!..sort();
      expect(front, hasLength(4));
      expect(back, hasLength(6));
      expect(front.first - 1.3, closeTo(8.5, 1e-6));
      expect(front.last + 1.3, closeTo(18.9, 1e-6));
      expect(back.first - 1.3, closeTo(3.2, 1e-6));
      expect(back.last + 1.3, closeTo(18.8, 1e-6));
      expect(p.envX0, closeTo(1.5, 1e-5));
      expect(p.envY0, closeTo(18.7, 1e-5));
      expect(p.envX1, closeTo(22.5, 1e-5));
      expect(p.envY1, closeTo(31.7, 1e-5));
      stallsInside(ctx, p);
    });

    test('§6.1 step 6: the footpath jogs along the envelope front to the '
        'right T end, the nearest stall-free gap, then runs to the frontage',
        () {
      final (p, _) =
          plan(ctx, graph: sg, laneSpans: SyntheticSites.laneSpansOf(sg));
      final f = ctx.frame!;
      final pts = [
        for (var i = p.pathStart(0); i < p.pathStart(1); i++)
          f.toLocal(Vec2(p.ptE(p.pathPt(i)), p.ptN(p.pathPt(i)))),
      ];
      // The door (12, 18.7) stands over both rows ([8.5, 18.9] and
      // [3.2, 18.8]) and the throat band [1.5, 7.5]: blocked x [0.75, 19.65]
      // with the 0.75 m half path. Its left end lies outside the envelope's
      // front edge [2.25, 21.75], so the path takes x = 19.65.
      expect(pts, hasLength(3));
      expect(pts[0].e, closeTo(19.65, 1e-6));
      expect(pts[0].n, closeTo(0, 1e-6));
      expect(pts[1].e, closeTo(19.65, 1e-6));
      expect(pts[1].n, closeTo(18.7, 1e-6));
      expect(pts[2].e, closeTo(12, 1e-6));
      expect(pts[2].n, closeTo(18.7, 1e-6));
      final pave = f.toLocal(Vec2(p.ptE(p.pavementPt), p.ptN(p.pavementPt)));
      expect(pave.e, closeTo(19.65, 1e-6));
      checkPark(ctx, p);
    });
  });

  group('§3.3 throat sized to the slot', () {
    JoinSlot roomed(double room) => JoinSlot(
          piece: slot.piece,
          s: slot.s,
          dirs: slot.dirs,
          right: slot.right,
          flags: slot.flags,
          roomM: room,
          kerbE: slot.kerbE,
          kerbN: slot.kerbN,
          normE: slot.normE,
          normN: slot.normN,
        );

    test('a kJoinMinRoomM slot (room 2.5): a 3.0 m sharedSingle throat and at '
        'most 8 stalls', () {
      final ctx = on(rect(60, 60), cMed, withSlot: roomed(kJoinMinRoomM));
      final cp = carParkPlanOf(ctx);
      expect(cp, isNotNull);
      expect(cp!.stallCount, inInclusiveRange(1, kCarParkSharedSingleMaxStalls));
      final (p, _) = plan(ctx);
      expect(p.program, SiteProgram.carPark);
      expect(p.segWidthM(0), closeTo(3.0, 1e-6));
      expect(p.segLaneMode(0), SiteLaneMode.sharedSingle);
      expect(p.joinCutHalfM(0), closeTo(2.5, 1e-6));
      expect(p.stallCount, lessThanOrEqualTo(8));
    });

    test('room 2.4 gives a 2.8 m throat: no car park, kerb only', () {
      final ctx = on(rect(60, 60), cMed, withSlot: roomed(2.4));
      expect(carParkPlanOf(ctx), isNull);
      final (p, stats) = plan(ctx);
      expect(p.program, SiteProgram.kerbOnly);
      expect(p.flags & kPlanFallback, kPlanFallback);
      expect(stats.demotionCount(SiteDemotion.carParkNoFit), 1);
    });

    test('a narrow slot (room 4.0): a yard falls through to a car park', () {
      final ctx = on(rect(60, 100), iMed, withSlot: roomed(4.0));
      expect(yardCandidatesOf(ctx), isEmpty);
      final y = yardPlanOf(ctx);
      expect(y, isNotNull);
      expect(y!.program, SiteProgram.carPark);
      final (p, stats) = plan(ctx);
      expect(p.program, SiteProgram.carPark);
      expect(p.flags & kPlanFallback, kPlanFallback);
      expect(p.admitsTrucks, isFalse);
      expect(p.bayCount, 0);
      expect(stats.demotionCount(SiteDemotion.yardNoFit), 1);
    });
  });

  group('§3.6 yard', () {
    test('an industrial 70 × 100 lot gets a yard: 7 m truck throat, apron, '
        '12.5 m circle inside the lot and paved, two bays facing the '
        'envelope, trucks admitted (V13)', () {
      // x_J 20: 50 m of lot on the apron's side holds the 18 m apron and
      // the circle's square (18 + 12.5 + 0.3 m).
      final ctx = on(rect(70, 100, xJ: 20), iMed);
      final y = yardPlanOf(ctx);
      expect(y, isNotNull);
      expect(y!.program, SiteProgram.yard);
      expect(y.bayCount, kYardBays);
      final (p, stats) = plan(ctx);
      expect(p.program, SiteProgram.yard);
      expect(p.flags & kPlanFallback, 0);
      expect(stats.programCount(SiteProgram.yard), 1);
      expect(p.admitsTrucks, isTrue);
      expect(p.truckTurnRadiusM, kYardCircleRadiusM);
      expect(p.segWidthM(0), 7.0);
      expect(p.joinCutHalfM(0), closeTo(4.5, 1e-6));
      expect(p.bayCount, 2);
      expect(p.stallCount, greaterThan(0));
      var circles = 0;
      for (var n = 0; n < p.nodeCount; n++) {
        if (p.nodeTurnKind(n) == TurnaroundKind.circle) {
          circles++;
          expect(p.nodeTurnR(n), kYardCircleRadiusM);
        }
      }
      expect(circles, 1);
      final f = ctx.frame!;
      final envX = (p.envX0 + p.envX1) / 2, envY = (p.envY0 + p.envY1) / 2;
      for (var b = 0; b < p.bayCount; b++) {
        expect(p.segKind(p.baySeg(b)), SiteSegmentKind.apron);
        final c = f.toLocal(Vec2(p.bayE(b), p.bayN(b)));
        // The nose points at the envelope, and the bay's front end stands
        // within the 1 m clearance (and a profile column) of its face.
        final nu = p.bayDirE(b) * f.u.e + p.bayDirN(b) * f.u.n;
        final nv = p.bayDirE(b) * f.v.e + p.bayDirN(b) * f.v.n;
        expect(nu * (envX - c.e) + nv * (envY - c.n), greaterThan(0));
        expect(c.e, inInclusiveRange(p.envX0, p.envX1));
        final front = c.n - kLoadingBayLengthM / 2;
        expect(front - p.envY1, inInclusiveRange(1.0 - 1e-5, 1.5 + 1e-5));
      }
      // The apron runs the full 18 m to the circle node.
      for (var k = 0; k < p.segCount; k++) {
        if (p.segKind(k) == SiteSegmentKind.apron) {
          expect(p.segLenM(k), closeTo(kYardApronWidthM, 1e-6));
        }
      }
      expect(circlesInsideAndPaved(ctx, p), 1);
      checkPark(ctx, p);
    });

    test('a narrower lot shortens the apron (not under 11.5 m) so the '
        "circle's square stays inside it; every yard candidate's circle is "
        'inside the lot', () {
      var shortened = 0;
      for (var w = 30.0; w <= 44; w += 2) {
        for (final d in const [60.0, 80.0]) {
          final ctx = on(rect(w, d, xJ: 4.5), iMed);
          for (final c in yardCandidatesOf(ctx)) {
            expect(c.rejection, isNot(contains('circle leaves')),
                reason: 'the apron length keeps the square inside a '
                    'rectangle: $c');
          }
          final y = yardPlanOf(ctx);
          if (y == null || y.program != SiteProgram.yard) continue;
          final (p, _) = plan(ctx);
          expect(p.program, SiteProgram.yard);
          for (var k = 0; k < p.segCount; k++) {
            if (p.segKind(k) != SiteSegmentKind.apron) continue;
            final len = p.segLenM(k);
            expect(len, inInclusiveRange(11.5 - 1e-6, kYardApronWidthM + 1e-6));
            // room − margin − radius, capped at 18.
            expect(len, closeTo(math.min(18, w - 4.5 - 0.3 - 12.5), 1e-6));
            if (len < kYardApronWidthM - 1e-6) shortened++;
          }
          expect(circlesInsideAndPaved(ctx, p), 1);
          checkPark(ctx, p);
        }
      }
      expect(shortened, greaterThan(0));
    });

    test('no yard where the circle cannot fit: a 30 m lot joined at its '
        'middle', () {
      final ctx = on(rect(30, 80, xJ: 15), iMed);
      expect(yardCandidatesOf(ctx).where((c) => c.valid), isEmpty);
      expect(yardPlanOf(ctx)?.program, isNot(SiteProgram.yard));
    });

    test('the apron y range does not throw where its bounds meet (no '
        'num.clamp, §3.7): depth 40.6 m ± 3e-7', () {
      // lo = 0.3 + 8 + 1 + 3.5 + 15 = 27.8; hi = yRear − 12.5 with
      // yRear = D − 0.3, so hi = lo at D = 40.6.
      const dStar = 0.3 + 8 + 1 + 3.5 + 15 + 12.5 + 0.3;
      final depths = [
        for (var i = -150; i <= 150; i++) dStar + i * 2e-9,
        dStar - 1e-7,
        dStar + 1e-7,
        dStar - 3e-7,
        dStar + 3e-7,
      ];
      for (final d in depths) {
        for (final w in const [40.0, 60.0]) {
          final ctx = on(rect(w, d, xJ: 10), iMed);
          expect(() => yardCandidatesOf(ctx), returnsNormally, reason: '$d');
          expect(() => yardPlanOf(ctx), returnsNormally, reason: '$d');
        }
      }
    });

    test('a lot too small for a yard or a car park: null, then kerb only with '
        'kPlanFallback (the car park generator is not asked again)', () {
      final ctx = on(rect(14, 14), iMed);
      expect(yardPlanOf(ctx), isNull);
      final (p, stats) = plan(ctx);
      expect(p.program, SiteProgram.kerbOnly);
      expect(p.flags & kPlanFallback, kPlanFallback);
      expect(stats.demotionCount(SiteDemotion.yardNoFit), 1);
      expect(stats.demotionCount(SiteDemotion.carParkNoFit), 0);
    });
  });

  test('20–120 m rectangles × specs: every plan valid, stalls inside', () {
    final programs = <SiteProgram>[];
    for (final w in const [20.0, 30.0, 40.0, 60.0, 80.0, 120.0]) {
      for (final d in const [20.0, 40.0, 60.0, 120.0]) {
        for (final spec in [cLow, cMed, cHigh, iMed]) {
          final ctx = on(rect(w, d, xJ: w < 30 ? 4.5 : w / 2), spec);
          final (p, _) = plan(ctx);
          programs.add(p.program);
          if (p.hasNetwork) {
            expect(p.stallCount, greaterThan(0));
            checkPark(ctx, p);
          }
        }
      }
    }
    expect(programs, contains(SiteProgram.carPark));
    expect(programs, contains(SiteProgram.yard));
    // Big lots always park.
    final (big, _) = plan(on(rect(120, 120), cHigh));
    expect(big.program, SiteProgram.carPark);
  });

  test('§3.8 odd lots (L, trapezoid, narrow deep, wide shallow, triangle): '
      'valid V1–V13, stalls never outside', () {
    final shapes = <String, (List<(double, double)>, double)>{
      'L': ([(0, 0), (40, 0), (40, 20), (20, 20), (20, 60), (0, 60)], 10),
      'L notch at the back': (
        [(0, 0), (50, 0), (50, 60), (30, 60), (30, 30), (0, 30)],
        25
      ),
      'trapezoid': ([(0, 0), (50, 0), (38, 45), (12, 45)], 25),
      'narrow deep': ([(0, 0), (14, 0), (14, 120), (0, 120)], 4.5),
      'wide shallow': ([(0, 0), (120, 0), (120, 14), (0, 14)], 60),
      'triangle': ([(0, 0), (60, 0), (30, 50)], 30),
      'big triangle': ([(0, 0), (120, 0), (60, 110)], 60),
    };
    final networks = <String>[];
    for (final name in shapes.keys.toList()..sort()) {
      final (pts, xJ) = shapes[name]!;
      for (final spec in [cLow, cMed, iMed]) {
        final ctx = on(drawn(pts, xJ), spec);
        final (p, _) = plan(ctx);
        if (p.hasNetwork) {
          networks.add('$name ${spec.type}');
          checkPark(ctx, p);
        }
      }
    }
    // The generators park where the shape allows, not only on rectangles.
    expect(networks, containsAll(['L c-low', 'trapezoid c-low',
        'big triangle c-low']), reason: '$networks');
  });

  group('generated towns', () {
    for (final (name, make) in <(String, CitySim Function())>[
      ('starter kit', starterKit),
      ('built town', town),
      ('small generated town', () => const CityGenerator().generate(
          const CityGenSpec(blocksAcross: 4, seed: 5), bodies: fixtureBodies)),
    ]) {
      test('$name: every car park and yard passes V1–V13, stalls inside', () {
        final city = make();
        final cg = city.roadGraph;
        final sp = SyntheticSites.laneSpansOf(cg);
        final stats = SiteProgramStats();
        final sites = siteContextsOf(city);
        var parks = 0;
        for (final ctx in sites) {
          final b = PlanBuilder(graph: cg);
          final got = planSite(b, ctx, stats: stats);
          if (got != SiteProgram.carPark && got != SiteProgram.yard) continue;
          parks++;
          final p = b.build(validate: false).plan(0);
          final bad = SitePlanValidator.validate(p, graph: cg, laneSpans: sp);
          expect(bad, isEmpty, reason: bad.join('\n'));
          checkPark(ctx, p);
          if (got == SiteProgram.yard) expect(p.admitsTrucks, isTrue);
        }
        // ignore: avoid_print
        print('$name: $stats');
        expect(parks, greaterThan(0), reason: '$stats');
      });
    }

    // The towns' industrial lots (30 × 46 m) hold no 12.5 m circle beside a
    // spine and bays in front of an 8 m envelope: their yards fall back to
    // car parks. The sprawl's larger industrial lots do get yards.
    test('sprawl: every yard passes V1–V13, circle inside the lot and paved',
        () {
      final city = const CityGenerator().generate(
          const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 12),
          bodies: fixtureBodies);
      final cg = city.roadGraph;
      final sp = SyntheticSites.laneSpansOf(cg);
      var yards = 0, offered = 0;
      final gens = SiteGenerators(yard: (ctx) {
        offered++;
        return yardPlanOf(ctx);
      });
      for (final ctx in siteContextsOf(city, graph: cg)) {
        if (ctx.spec == null || !isIndustrialSpec(ctx.spec!)) continue;
        final b = PlanBuilder(graph: cg);
        if (planSite(b, ctx, generators: gens) != SiteProgram.yard) continue;
        yards++;
        final p = b.build(validate: false).plan(0);
        final bad = SitePlanValidator.validate(p, graph: cg, laneSpans: sp);
        expect(bad, isEmpty, reason: bad.join('\n'));
        expect(p.admitsTrucks, isTrue);
        expect(p.bayCount, kYardBays);
        expect(circlesInsideAndPaved(ctx, p), 1);
        checkPark(ctx, p);
      }
      // ignore: avoid_print
      print('sprawl: $yards yards of $offered offered');
      expect(yards, greaterThan(0));
    });
  });

  test('§3.8 a set-back skewed lot: the throat runs along the road normal '
      'to a bend node on the frontage, inside the slot corridor', () {
    // The frontage 40 m behind the kerb, turned 5.7° (sin 0.1): a throat
    // along v would drift about 4 m off the normal by the frontage.
    const sin = 0.1;
    final cos = math.sqrt(1 - sin * sin);
    final sn = slot.normN.sign;
    Parcel setBack(double w, double d, double xJ, double back) {
      Vec2 at(double x, double y) {
        final dx = x - xJ;
        return Vec2(slot.s + dx * cos - y * sin * sn,
            slot.kerbN + (back + dx * sin * sn + y * cos) * sn);
      }

      return Parcel(
        id: lotParcel.id,
        polygon: [at(0, 0), at(w, 0), at(w, d), at(0, d)],
        roadId: 'r0',
        frontage: (at(0, 0), at(w, 0)),
      );
    }

    for (final (w, d, spec) in [
      (60.0, 60.0, cMed),
      (40.0, 50.0, cLow),
      (80.0, 40.0, cHigh),
    ]) {
      final ctx = on(setBack(w, d, w / 2, 40), spec);
      final f = ctx.frame!;
      final nv = slot.normE * f.v.e + slot.normN * f.v.n;
      expect(nv, closeTo(cos, 1e-6), reason: 'the lot is turned as drawn');
      final cp = carParkPlanOf(ctx);
      expect(cp, isNotNull, reason: '$w x $d');
      expect(cp!.bends, isTrue);
      final (p, _) = plan(ctx);
      expect(p.program, SiteProgram.carPark);
      // Segment 0 is the throat along the normal, its far node on y = 0.
      final k0 = p.segFrom(0), b0 = p.segTo(0);
      final de = p.nodeE(b0) - p.nodeE(k0), dn = p.nodeN(b0) - p.nodeN(k0);
      final len = math.sqrt(de * de + dn * dn);
      expect((de * slot.normE + dn * slot.normN) / len, closeTo(1, 1e-9));
      expect(f.toLocal(Vec2(p.nodeE(b0), p.nodeN(b0))).n, closeTo(0, 1e-6));
      expect(len, greaterThanOrEqualTo(kThroatMinM));
      checkPark(ctx, p);
    }
  });

  test('500 random sites (skewed footprints, curved roads): every car park '
      'and yard valid, its throat inside the corridor, its circle inside the '
      'lot, its footpath clear', () {
    final spansOf = <RoadGraph, List<SiteLaneSpans>>{};
    var parks = 0, bends = 0;
    for (final r in RandomSites.build()) {
      final ctx = r.context();
      final b = PlanBuilder(graph: r.graph);
      final got = planSite(b, ctx);
      if (got != SiteProgram.carPark && got != SiteProgram.yard) continue;
      parks++;
      final p = b.build(validate: false).plan(0);
      final bad = SitePlanValidator.validate(p,
          graph: r.graph,
          laneSpans: spansOf[r.graph] ??= SyntheticSites.laneSpansOf(r.graph));
      expect(bad, isEmpty, reason: '${ctx.siteId}: ${bad.join('\n')}');
      checkPark(ctx, p);
      final cp = got == SiteProgram.yard ? yardPlanOf(ctx) : carParkPlanOf(ctx);
      if (cp!.bends) bends++;
    }
    // ignore: avoid_print
    print('random sites: $parks car parks and yards, $bends bent throats');
    expect(parks, greaterThan(20));
  });

  test('branch and bound: no valid candidate scores above the bound it was '
      'held to (the block counts only inside the side setbacks)', () {
    final sites = <SiteContext>[
      for (final w in const [12.0, 14.0, 16.0, 20.0, 24.0, 40.0, 80.0])
        for (final d in const [30.0, 45.0, 60.0, 120.0])
          for (final spec in [cLow, cMed, cHigh, iMed])
            for (final xJ in const [4.5, 0.5])
              on(rect(w, d, xJ: xJ < 1 ? w / 2 : xJ), spec),
      for (final r in RandomSites.build()) r.context(),
    ];
    var checked = 0;
    for (final ctx in sites) {
      for (final c in [...carParkCandidatesOf(ctx), ...yardCandidatesOf(ctx)]) {
        if (!c.valid) continue;
        checked++;
        expect(c.score!, lessThanOrEqualTo(c.scoreBound + 1e-9),
            reason: '${ctx.siteId} $c bound ${c.scoreBound}');
      }
    }
    expect(checked, greaterThan(100));
  });

  test('stall keys are stable when an unrelated aisle changes (V10, ask 8)',
      () {
    // Two F1 lots, one front module, both arms: the second lot is 20 m wider
    // on the right only, so only the right arm's aisle changes.
    final a = on(rect(60, 32, xJ: 30), cHigh);
    final b = on(rect(80, 32, xJ: 30), cHigh);
    for (final c in [a, b]) {
      final cp = carParkPlanOf(c)!;
      expect(cp.family, CarParkFamily.front);
      expect(cp.winner.modules, 1);
    }
    final (pa, _) = plan(a);
    final (pb, _) = plan(b);
    // The unchanged side: world e below the join (the lots differ at e > s).
    Map<String, int> leftKeys(SiteContext ctx, SiteAccessPlan p) {
      final out = <String, int>{};
      for (var i = 0; i < p.stallCount; i++) {
        if (p.stallE(i) >= slot.s) continue;
        out['${(p.stallE(i) * 10).round()},${(p.stallN(i) * 10).round()}'] =
            p.stallKey(i);
      }
      return out;
    }

    int rightCount(SiteContext ctx, SiteAccessPlan p) {
      var n = 0;
      for (var i = 0; i < p.stallCount; i++) {
        if (p.stallE(i) >= slot.s) n++;
      }
      return n;
    }

    final ka = leftKeys(a, pa), kb = leftKeys(b, pb);
    expect(ka, isNotEmpty);
    expect(kb, ka);
    expect(rightCount(b, pb), greaterThan(rightCount(a, pa)));
    // And the key index finds each stall.
    for (var i = 0; i < pb.stallCount; i++) {
      expect(pb.stallIndexOfKey(pb.stallKey(i)), i);
    }
  });

  test('§3.5 family biases: F2 +5 below 40 m of frontage, F3 −2', () {
    double formula(CarParkCandidate c, CityBuildingSpec spec) {
      final cap = math.max(capacityScoreCap(spec),
          capacityTarget(SiteProgram.carPark, spec).toDouble());
      final n = c.stallCount.toDouble();
      return kScoreStall * math.min(n, cap) -
          kScoreOverflow * math.max(0.0, n - cap) +
          kScoreEnvelopeArea * c.envelope!.width * c.envelope!.depth -
          kScoreDriveLength * c.driveLengthM;
    }

    for (final (w, rearBias) in const [(24.0, 5.0), (40.0, 0.0)]) {
      final all = carParkCandidatesOf(on(rect(w, 60, xJ: 4.5), cLow));
      final rear = all.where((c) => c.family == CarParkFamily.rear && c.valid);
      expect(rear, isNotEmpty, reason: '$all');
      for (final c in rear) {
        expect(c.score! - formula(c, cLow), closeTo(rearBias, 1e-9));
      }
      for (final c in all.where((c) => c.valid)) {
        final bias = switch (c.family) {
          CarParkFamily.rear => rearBias,
          CarParkFamily.side => kScoreSideBias,
          _ => 0.0,
        };
        expect(c.score! - formula(c, cLow), closeTo(bias, 1e-9));
      }
    }
  });

  test('generation prunes candidates yet picks exactly the exhaustive winner',
      () {
    final city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5),
        bodies: fixtureBodies);
    final sites = [
      ...siteContextsOf(city),
      for (final r in RandomSites.build()) r.context(),
    ];
    var compared = 0;
    for (final ctx in sites) {
      if (ctx.spec == null || ctx.slotCount == 0 || ctx.frame == null) continue;
      for (final (all, got) in [
        (carParkCandidatesOf(ctx), carParkPlanOf(ctx)),
        (yardCandidatesOf(ctx), () {
          final y = yardPlanOf(ctx);
          return y?.program == SiteProgram.yard ? y : null;
        }()),
      ]) {
        // §3.5's rule over every candidate: the top score's 1 % band, the
        // largest family tie-break key, then the higher score, then the
        // earlier candidate.
        var top = double.negativeInfinity;
        for (final c in all) {
          if (c.valid && c.score! > top) top = c.score!;
        }
        CarParkCandidate? pick;
        var pickKey = 0;
        for (final c in all) {
          if (!c.valid || c.score! < top - kScoreTieFraction * top.abs()) {
            continue;
          }
          final key = ctx.tieBreak(c.family.name);
          if (pick == null ||
              key > pickKey ||
              (key == pickKey && c.score! > pick.score!)) {
            pick = c;
            pickKey = key;
          }
        }
        if (pick == null) {
          expect(got, isNull, reason: ctx.siteId);
          continue;
        }
        expect(got, isNotNull, reason: ctx.siteId);
        final w = got!.winner;
        expect(
            (w.family, w.modules, w.singleLast, w.stallCount, w.score),
            (pick.family, pick.modules, pick.singleLast, pick.stallCount,
                pick.score),
            reason: ctx.siteId);
        compared++;
      }
    }
    expect(compared, greaterThan(50));
  });

  test('determinism: a fresh context in any order plans the same rows', () {
    final city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5),
        bodies: fixtureBodies);
    final cg = city.roadGraph;
    List<List<Object>> run(List<SiteContext> sites) {
      final out = <List<Object>>[];
      for (final ctx in sites) {
        final b = PlanBuilder(graph: cg);
        final got = planSite(b, ctx);
        if (got != SiteProgram.carPark && got != SiteProgram.yard) continue;
        out.add(RandomSites.signatureOf(b.build(validate: false).plan(0)));
      }
      return out;
    }

    final forward = run(siteContextsOf(city));
    expect(forward, isNotEmpty);
    final reversed = run(siteContextsOf(city).reversed.toList()).reversed.toList();
    expect(reversed, forward);
  });
}
