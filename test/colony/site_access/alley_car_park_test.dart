// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The alley car park, F2a (docs/plans/site-access.md §3.5, §3.2 slot 3, §2.4
/// V4; slice R8): a downtown lot's back-of-house parking comes off the ALLEY
/// behind it, so its street frontage stays an unbroken run of shopfronts.
///
/// What is pinned: the plan's two joins (slot 0 the KERBSIDE frontage, slot 3
/// the cut), that the street carries no kerb cut, the throat over the 0.6 m the
/// plat leaves behind the lot, V1–V13 and V7's reachability through the alley
/// join, the paving check against the rear corridor, the winner on a fixture
/// lot, and — the other half of the slice — that a lot with no alley behind it
/// plans byte for byte as it does today.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/car_park_packer.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/kerb_cuts.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_paving_check.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
// The traffic tables are READ here and never changed: §5.5's access rows are
// what say the plan's kerbside frontage is no driveway.
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_plan_source.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_plan_fixtures.dart';

/// A downtown block as the generator cuts one (`CityGenSpec.blockDepthM` 104,
/// `alleys` true): two streets 104 m apart with a service alley down the
/// midline. With [depthM] 46 the alley caps the lots' depth, so a north-row lot
/// comes out 24 × 41.4 m with its back edge 0.6 m off the alley's carriageway
/// edge (`CityLayout._depthAt`: an alley IS the midline, so a lot runs all the
/// way to it, less the alley's own 0.6 m setback). With [depthM] 32 nothing is
/// capped and the plat is the same with or without the alley.
/// [frontageM], [depthM] and [blockM] widen the block for the cases that need
/// a bigger lot than the plat's own downtown one.
CityLayout _block(
    {bool alley = true,
    double frontageM = 24,
    double depthM = 46,
    double blockM = 104}) {
  final layout = CityLayout(
      settings: ParcelSettings(frontageM: frontageM, depthM: depthM))
    ..commitRoad(controls: const [Vec2(0, 0), Vec2(400, 0)])
    ..commitRoad(controls: [Vec2(0, blockM), Vec2(400, blockM)]);
  if (alley) {
    layout.commitRoad(
        controls: [Vec2(0, blockM / 2), Vec2(400, blockM / 2)],
        roadClass: RoadClass.alley);
  }
  return layout;
}

/// The lots of [layout] that back onto the alley at n = 52 — the ones INSIDE
/// the block: the north row of the n = 0 street and the south row of the n = 104
/// one. Read off the geometry, never off `hasRearAlley`, so the rear-edge rule
/// is tested rather than assumed.
List<Parcel> _backingTheAlley(CityLayout layout, {double blockM = 104}) => [
      for (final p in layout.autoParcels)
        if (p.centroid.n > 0 && p.centroid.n < blockM) p,
    ];

/// A plan's content, without the graph it was resolved against: the digest two
/// road graphs' plans are compared by.
String _digest(SiteAccessPlan p) {
  final j = sitePlanJson(p)
    ..remove('graphStamp')
    ..remove('rev');
  return jsonEncode(j);
}

void main() {
  final cMed = kZoneSpecs['commercial']![Density.medium]!;

  /// Plans [ctx] through the dispatcher.
  (SiteAccessChunk, SiteAccessPlan) planOf(SiteContext ctx) {
    final b = PlanBuilder(graph: ctx.graph);
    expect(planSite(b, ctx), isNotNull, reason: ctx.siteId);
    final chunk = b.build(validate: false);
    return (chunk, chunk.plan(0));
  }

  group('a downtown lot backing onto an alley (24 x 41.4 m, c-med)', () {
    final layout = _block();
    final g = RoadGraph.of(layout);
    final parcel = _backingTheAlley(layout).first;
    final lot = g.lotNoOf(parcel.id)!;
    final ctx = SiteContext.ofLot(g, parcel, cMed);
    final spans = SyntheticSites.laneSpansOf(g);
    final alleyNo = g.roads.indexWhere((r) => r.roadClass == RoadClass.alley);

    test('the fixture: the back edge lies 0.6 m off the alley carriageway', () {
      final f = ctx.frame!;
      expect([
        for (final v in parcel.polygon)
          '${f.toLocal(v).e.toStringAsFixed(2)},'
              '${f.toLocal(v).n.toStringAsFixed(2)}'
      ], ['0.00,0.00', '24.00,0.00', '24.00,41.40', '0.00,41.40']);
      expect(f.widthM, 24.0);
      expect(ctx.depthM, closeTo(41.4, 1e-9));
      final s3 = ctx.alleySlot!;
      final kerb = f.toLocal(Vec2(s3.kerbE, s3.kerbN));
      expect(kerb.n, closeTo(42.0, 1e-9), reason: 'the alley carriageway edge');
      expect(kerb.n - 41.4, closeTo(0.6, 1e-9), reason: 'k, kerb to back edge');
      expect(s3.flags, kJoinCut | kJoinAlley);
      // The alley has no pavement, so its kerb IS its carriageway edge (§3.8).
      expect(g.roads[alleyNo].roadClass.hasPavement, isFalse);
    });

    test('plans F2a with two joins: slot 0 the kerbside frontage, slot 3 the '
        'cut that carries in and out', () {
      final (_, p) = planOf(ctx);
      expect(p.program, SiteProgram.carPark);
      expect(p.hasNetwork, isTrue);
      expect(p.joinCount, 2);
      // Join 0 is slot 0 (V3), and it is NOT a cut: the street wall is whole.
      expect(p.joinSlot(0), 0);
      expect(p.joinKind(0), SiteJoinKind.kerbside);
      expect(p.joinCutHalfM(0), 0);
      expect(p.joinKerbNode(0), -1);
      expect(p.joinThroatSeg(0), -1);
      // And NO car uses it: the frontage is the sign, the pavement point and
      // the stale-plan fallback, never a way in. With a role it would go to the
      // access table as a driveway (§5.5), beat the 20 km/h alley on cost, and
      // strand the car that took it at a join with no lane behind it.
      expect(p.joinRole(0), SiteJoinRole.none);
      expect(p.joinCanIn(0), isFalse);
      expect(p.joinCanOut(0), isFalse);
      expect(p.joinRef(0), g.joinRefOf(lot, 0));
      expect(p.joinRoadNo(0), g.pieceRoad[ctx.slot0.piece]);
      // Join 1 is the alley cut, and it is the only one.
      expect(p.joinSlot(1), kJoinSlotAlley);
      expect(p.joinKind(1), SiteJoinKind.cut);
      expect(p.joinRole(1), SiteJoinRole.both);
      expect(p.joinCanIn(1) && p.joinCanOut(1), isTrue);
      expect(p.joinRef(1), kJoinRefAlleyBase - lot);
      expect(p.joinRoadNo(1), alleyNo);
      expect(p.joinRoadS(1), ctx.alleySlot!.s);
      expect(p.joinCutHalfM(1), closeTo(kCarParkThroatWidthM / 2 + kCutFlareM, 1e-9));
      expect(p.joinKerbNode(1), 0);
      expect(p.joinThroatSeg(1), 0);
      expect([for (var j = 0; j < p.joinCount; j++) if (p.joinIsCut(j)) j], [1],
          reason: 'exactly one cut join');
    });

    test('the throat leaves the ALLEY, runs 9.1 m into the lot and crosses no '
        'pavement', () {
      final f = ctx.frame!;
      final (_, p) = planOf(ctx);
      final k = p.segFrom(0), far = p.segTo(0);
      expect(p.nodeFlags(k) & kNodeKerb, kNodeKerb);
      final s3 = ctx.alleySlot!;
      expect(p.nodeE(k), s3.kerbE);
      expect(p.nodeN(k), s3.kerbN);
      final a = f.toLocal(Vec2(p.nodeE(k), p.nodeN(k)));
      final b = f.toLocal(Vec2(p.nodeE(far), p.nodeN(far)));
      // Along −v, from the alley toward the frontage: 0.6 m of unowned ground,
      // 0.3 m of profile margin and the 8.2 m to module 0's aisle.
      expect(b.e, closeTo(a.e, 1e-9));
      expect(a.n - b.n, closeTo(9.1, 1e-9));
      expect(p.segLenM(0), closeTo(9.1, 1e-9));
      expect(p.segLenM(0), greaterThanOrEqualTo(kThroatMinM));
      expect(p.segFlags(0) & kSegThroat, kSegThroat);
      expect(p.segFlags(0) & kSegCrossesPavement, 0,
          reason: 'an alley has no pavement to cross');
    });

    test('the street frontage carries NO kerb cut; the alley carries one', () {
      final (chunk, _) = planOf(ctx);
      final canon = KerbCuts.canonicalOf([chunk], g);
      for (var r = 0; r < canon.length; r++) {
        if (r == alleyNo) continue;
        expect(canon[r], isNull,
            reason: '${g.roads[r].id} should carry no cut of this site');
      }
      final cuts = canon[alleyNo]!;
      expect(cuts, hasLength(KerbCuts.stride));
      expect(cuts[1], ctx.alleySlot!.s);
      expect(cuts[2], closeTo(kCarParkThroatWidthM / 2 + kCutFlareM, 1e-9));
      expect(cuts[4], KerbCuts.kindDropped.toDouble());
    });

    test('V1-V13 pass, and V7 reachability holds through the alley join', () {
      final (_, p) = planOf(ctx);
      final bad = SitePlanValidator.validate(p, graph: g, laneSpans: spans);
      expect(bad, isEmpty, reason: bad.join('\n'));
      final lg = SiteLaneGraph.of(p);
      expect(lg.isStronglyConnected, isTrue);
      expect(lg.inLane(1), greaterThanOrEqualTo(0));
      expect(lg.outLane(1), greaterThanOrEqualTo(0));
      expect(lg.inLane(0), -1, reason: 'a kerbside join is no lane');
      expect(lg.outLane(0), -1);
      expect(p.stallCount, greaterThan(0));
    });

    test('the paving check passes: the rear corridor covers the 0.6 m of the '
        'throat outside the lot', () {
      final f = ctx.frame!;
      final (_, p) = planOf(ctx);
      expect(sitePavingViolations(ctx, p), isEmpty);
      // The corridor runs from the alley kerb along the slot normal to where
      // the lot is certainly under it (the profile's far edge, its 0.3 m margin
      // left in as slack), not to the frontage line 41 m away.
      final line = corridorLineOf(f, ctx.alleySlot!).map(f.toLocal).toList();
      expect(line, hasLength(2));
      expect(line[0].n, closeTo(42.0, 1e-9));
      expect(line[1].n, closeTo(f.profile.maxDepthM, 1e-9));
      expect(line[0].n - line[1].n, closeTo(0.9, 1e-9));
      // The throat's pave spans the kerb to the aisle; its stretch past the
      // back edge is the corridor's.
      final ring = [
        for (var i = p.paveStart(0); i < p.paveStart(1); i++)
          f.toLocal(Vec2(p.ptE(p.pavePt(i)), p.ptN(p.pavePt(i)))),
      ];
      expect(ring.map((v) => v.n).reduce((a, b) => a > b ? a : b),
          closeTo(42.0, 1e-9), reason: 'the pave reaches the alley kerb');
    });

    test('no stall stands in the throat exclusion behind module 0\'s aisle', () {
      final f = ctx.frame!;
      final (_, p) = planOf(ctx);
      final xJ = f.toLocal(Vec2(ctx.alleySlot!.kerbE, ctx.alleySlot!.kerbN)).e;
      const half = kCarParkThroatWidthM / 2 + kThroatCorridorClearM;
      final aisleFar = f.toLocal(Vec2(p.nodeE(p.segTo(0)), p.nodeN(p.segTo(0)))).n +
          kAisleTwoWayWidthM / 2;
      for (var i = 0; i < p.stallCount; i++) {
        final c = f.toLocal(Vec2(p.stallE(i), p.stallN(i)));
        final du = p.stallDirE(i) * f.u.e + p.stallDirN(i) * f.u.n;
        final ex = du.abs() > 0.5 ? kStallLengthM / 2 : kStallWidthM / 2;
        final ey = du.abs() > 0.5 ? kStallWidthM / 2 : kStallLengthM / 2;
        final overX = c.e + ex > xJ - half + 1e-9 && c.e - ex < xJ + half - 1e-9;
        final behind = c.n + ey > aisleFar + 1e-9;
        expect(overX && behind, isFalse,
            reason: 'stall $i at $c stands in the drive\'s way');
      }
    });

    test('the winner, pinned: F2a is F1 mirrored — the same 10 stalls and the '
        'same 470.4 m2 envelope, 2.4 m less drive, plus F2\'s street-wall bias',
        () {
      final cp = carParkPlanOf(ctx)!;
      expect(cp.family, CarParkFamily.rearAlley);
      expect(cp.winner.modules, 1);
      expect(cp.winner.singleLast, isFalse);
      expect(cp.stallCount, 10);
      expect(cp.envelope.rect.x0, closeTo(1.5, 1e-9));
      expect(cp.envelope.rect.x1, closeTo(22.5, 1e-9));
      expect(cp.envelope.rect.y0, closeTo(0.3, 1e-9));
      expect(cp.envelope.rect.y1, closeTo(22.7, 1e-9));
      expect(cp.winner.driveLengthM, closeTo(28.3, 1e-9));
      expect(cp.winner.score, closeTo(100.258, 1e-9));
      expect(cp.bends, isFalse);
      // F1, the best from the street, on the same block mirrored: the throat is
      // 3 m of pavement + 8.5 m instead of 0.6 + 0.3 + 8.2, and no bias.
      final all = carParkCandidatesOf(ctx);
      final f1 = all.firstWhere((c) =>
          c.family == CarParkFamily.front && c.modules == 1 && !c.singleLast);
      expect(f1.stallCount, 10);
      expect(f1.envelope!.width * f1.envelope!.depth,
          closeTo(cp.envelope.rect.width * cp.envelope.rect.depth, 1e-9));
      expect(f1.driveLengthM, closeTo(30.7, 1e-9));
      expect(f1.score, closeTo(94.058, 1e-9));
      expect(cp.winner.score! - f1.score!,
          closeTo(kScoreRearBias + kScoreDriveLength * 2.4, 1e-9));
      // Every F2a candidate carries F2's bias and nothing else.
      for (final c in all) {
        if (c.family != CarParkFamily.rearAlley || !c.valid) continue;
        final raw = kScoreStall * c.stallCount +
            kScoreEnvelopeArea * c.envelope!.width * c.envelope!.depth -
            kScoreDriveLength * c.driveLengthM;
        expect(c.score! - raw, closeTo(kScoreRearBias, 1e-9),
            reason: '$c');
      }
    });

    test('no valid F2a candidate scores above the bound it was held to', () {
      // Every candidate a downtown lot this size offers is a single module, so
      // this exercises the `m == 1` arm of the bound alone; the `m >= 2` arm is
      // reached on the deeper lot below.
      var checked = 0;
      for (final p in _backingTheAlley(layout)) {
        final c = SiteContext.ofLot(g, p, cMed);
        for (final cand in carParkCandidatesOf(c)) {
          if (!cand.valid) continue;
          checked++;
          expect(cand.score!, lessThanOrEqualTo(cand.scoreBound + 1e-9),
              reason: '${c.siteId} $cand bound ${cand.scoreBound}');
        }
      }
      expect(checked, greaterThan(20));
    });

    test('pruned generation picks exactly the exhaustive winner', () {
      for (final p in _backingTheAlley(layout)) {
        final c = SiteContext.ofLot(g, p, cMed);
        final all = carParkCandidatesOf(c);
        var top = double.negativeInfinity;
        for (final x in all) {
          if (x.valid && x.score! > top) top = x.score!;
        }
        CarParkCandidate? pick;
        var pickKey = 0;
        for (final x in all) {
          if (!x.valid || x.score! < top - kScoreTieFraction * top.abs()) {
            continue;
          }
          final key = c.tieBreak(x.family.name);
          if (pick == null ||
              key > pickKey ||
              (key == pickKey && x.score! > pick.score!)) {
            pick = x;
            pickKey = key;
          }
        }
        final got = carParkPlanOf(c);
        expect(got == null, pick == null, reason: c.siteId);
        if (pick == null) continue;
        final w = got!.winner;
        expect((w.family, w.modules, w.singleLast, w.stallCount, w.score),
            (pick.family, pick.modules, pick.singleLast, pick.stallCount,
                pick.score),
            reason: c.siteId);
      }
    });

    test('every lot backing the alley that parks at all parks off it, passes '
        'V1-V13 and paves inside its parcel and corridor', () {
      var planned = 0;
      for (final p in _backingTheAlley(layout)) {
        final c = SiteContext.ofLot(g, p, cMed);
        final (_, plan) = planOf(c);
        final bad = SitePlanValidator.validate(plan, graph: g, laneSpans: spans);
        expect(bad, isEmpty, reason: '${p.id}: ${bad.join('\n')}');
        expect(sitePavingViolations(c, plan), isEmpty, reason: p.id);
        // A sliver at the end of a run is kerbOnly whatever lies behind it.
        if (plan.program != SiteProgram.carPark) continue;
        expect(plan.joinCount, 2, reason: p.id);
        expect(plan.joinSlot(1), kJoinSlotAlley, reason: p.id);
        expect(carParkPlanOf(c)!.family, CarParkFamily.rearAlley, reason: p.id);
        planned++;
      }
      expect(planned, greaterThan(8));
    });
  });

  group('the bound on a block of two modules or more (40 x 54.4 m)', () {
    // The plat's downtown lot is 24 x 41.4 m, and on it EVERY m ≥ 2 candidate is
    // refused for envelope room BEFORE a bound is recorded, so the cross-aisle
    // term of the m ≥ 2 bound is never charged there. This lot reaches it: a
    // 130 m block with 60 m of configured depth cuts 40 × 54.4 m lots, and the
    // alley still runs down the midline behind them.
    final layout = _block(frontageM: 40, depthM: 60, blockM: 130);
    final g = RoadGraph.of(layout);
    final parcel = _backingTheAlley(layout, blockM: 130).first;
    final ctx = SiteContext.ofLot(g, parcel, cMed);

    /// The candidates by (family, modules, whether the last module is single).
    Map<(CarParkFamily, int, bool), CarParkCandidate> byShape() => {
          for (final c in carParkCandidatesOf(ctx))
            (c.family, c.modules, c.singleLast): c,
        };

    test('the fixture: 40 x 54.4 m off an alley, with m >= 2 candidates that '
        'reach the bound', () {
      expect(ctx.frame!.widthM, closeTo(40, 1e-9));
      expect(ctx.depthM, closeTo(54.4, 1e-9));
      expect(ctx.alleySlot, isNotNull);
      var reached = 0;
      for (final e in byShape().entries) {
        if (e.key.$1 != CarParkFamily.rearAlley || e.key.$2 < 2) continue;
        if (!e.value.valid) continue;
        expect(e.value.scoreBound.isFinite, isTrue, reason: '${e.key}');
        reached++;
      }
      expect(reached, greaterThan(1), reason: 'the m >= 2 bound is charged');
    });

    test('a multi-module alley entry is bounded exactly as tightly as the same '
        'block entered from the street', () {
      // The slack the bound leaves (bound − score) comes out the SAME number
      // for F1 and for F2a on a lot that is its own mirror: an alley entry is
      // held to no looser a bound than a street entry.
      //
      // What this does NOT pin is the m ≥ 2 PRE-ALLOCATION bound, whose
      // cross-aisle term is charged over the full aisle span whichever end the
      // drive meets. That bound is not observable: `_Draft.preCheck` and
      // `_Draft.finish` record tighter bounds over the same candidate (the
      // realised drive rather than a lower bound on it), and `candBound` keeps
      // the smallest, so the pre-allocation number never reaches `scoreBound`.
      // Nor is its pruning observable — the pruned verdicts and the winner come
      // out identical with the term charged from the drive's own aisle instead,
      // on this lot and on five other geometries, three of them won by an F2a
      // candidate of two modules or more. It is admissible either way (the
      // ladder the packer builds is exactly 2 × the span), so the term is a
      // tightening with no behaviour behind it to pin.
      final all = byShape();
      var compared = 0;
      for (final m in [2, 3, 4]) {
        for (final single in [false, true]) {
          final f1 = all[(CarParkFamily.front, m, single)];
          final f2a = all[(CarParkFamily.rearAlley, m, single)];
          if (f1 == null || f2a == null || !f1.valid || !f2a.valid) continue;
          expect(f2a.scoreBound - f2a.score!,
              closeTo(f1.scoreBound - f1.score!, 1e-9),
              reason: 'm$m ${single ? 'single' : 'double'}: '
                  'F1 ${f1.scoreBound}/${f1.score}, '
                  'F2a ${f2a.scoreBound}/${f2a.score}');
          compared++;
        }
      }
      expect(compared, greaterThan(1));
    });

    test('and no valid candidate of any family beats its own bound', () {
      var checked = 0;
      for (final c in carParkCandidatesOf(ctx)) {
        if (!c.valid) continue;
        expect(c.score!, lessThanOrEqualTo(c.scoreBound + 1e-9), reason: '$c');
        checked++;
      }
      expect(checked, greaterThan(4));
    });
  });

  group('a lot with no alley behind it plans as it does today', () {
    // 32 m lots: the alley at n = 52 caps nothing, so the plat is the same with
    // or without it and the only input that moves is the alley itself.
    final withAlley = _block(depthM: 32);
    final without = _block(alley: false, depthM: 32);
    final gA = RoadGraph.of(withAlley), gN = RoadGraph.of(without);

    test('the plat is identical, with the alley drawn or not', () {
      String shape(Parcel p) =>
          [for (final v in p.polygon) '${v.e},${v.n}'].join(' ');
      final a = {for (final p in withAlley.autoParcels) p.id: shape(p)};
      final n = {for (final p in without.autoParcels) p.id: shape(p)};
      expect(a, n);
      expect(a, isNotEmpty);
    });

    test('every lot that does not take the alley plans byte for byte the same; '
        'only the ones that do move', () {
      final backing = {for (final p in _backingTheAlley(withAlley)) p.id};
      expect(backing, isNotEmpty);
      var same = 0, moved = 0;
      for (final p in without.autoParcels) {
        final lotA = gA.lotNoOf(p.id);
        if (lotA == null) continue;
        expect(gA.hasRearAlley(lotA), backing.contains(p.id), reason: p.id);
        final (_, a) = planOf(SiteContext.ofLot(gA, p, cMed));
        final (_, n) = planOf(SiteContext.ofLot(gN, p, cMed));
        if (a.joinCount == 2) {
          // Only a plan that TAKES slot 3 moves; a candidate lot the dispatcher
          // sends to kerbOnly is untouched by the alley behind it.
          expect(a.joinSlot(1), kJoinSlotAlley, reason: p.id);
          expect(backing, contains(p.id), reason: p.id);
          expect(_digest(a), isNot(_digest(n)), reason: p.id);
          expect(n.joinCount, 1, reason: p.id);
          moved++;
        } else {
          expect(_digest(a), _digest(n), reason: p.id);
          same++;
        }
      }
      expect(same, greaterThan(20));
      expect(moved, greaterThan(8));
    });

    test('and it is the §3.5 worked example, unchanged: F1 double, 10 stalls, '
        'envelope 21 x 13 m, score 90.11, no F2a candidate offered', () {
      final p = without.autoParcels
          .firstWhere((q) => _backingTheAlley(withAlley).any((r) => r.id == q.id));
      final ctx = SiteContext.ofLot(gN, p, cMed);
      expect(ctx.alleySlot, isNull);
      expect(ctx.hasAlleyCandidate, isFalse);
      final all = carParkCandidatesOf(ctx);
      expect(all.where((c) => c.family == CarParkFamily.rearAlley), isEmpty);
      final cp = carParkPlanOf(ctx)!;
      expect(cp.family, CarParkFamily.front);
      expect(cp.winner.modules, 1);
      expect(cp.winner.singleLast, isFalse);
      expect(cp.stallCount, 10);
      expect(cp.envelope.rect.width, closeTo(21, 1e-9));
      expect(cp.envelope.rect.depth, closeTo(13, 1e-9));
      expect(cp.winner.score, closeTo(90.11, 1e-9));
      final (_, plan) = planOf(ctx);
      expect(plan.joinCount, 1);
      expect(plan.joinKind(0), SiteJoinKind.cut);
    });
  });

  group('the book (§4.2)', () {
    test('an alley drawn behind built shops re-plans them onto slot 3', () {
      final city = town();
      final road = commit(city, const FixtureRoad([Vec2(2000, -150), Vec2(2000, 150)]));
      final shops = [
        for (final p in city.layout.autoParcels)
          if (p.roadId == road) p,
      ];
      expect(shops, isNotEmpty);
      for (final p in shops) {
        city.placeOnParcel(p.id, cMed);
      }
      final book = city.siteAccess;
      void drain() {
        expect(
            book.sync(city, city.roadGraph,
                maxUnits: SiteAccessBook.unlimited,
                maxChecks: SiteAccessBook.unlimited),
            isTrue);
      }

      drain();
      int joinsOf(String id) {
        for (final c in book.chunks) {
          for (var k = 0; k < c.siteCount; k++) {
            if (c.siteId(k) == id) return c.joinCountOf(k);
          }
        }
        return -1;
      }

      final east = [for (final p in shops) if (p.centroid.e > 2000) p];
      expect(east, isNotEmpty);
      for (final p in east) {
        expect(joinsOf(p.id), 1, reason: '${p.id} before the alley');
      }
      // The alley 42 m behind the east row: the lots are 32 m deep, so their
      // polygons do not move — only the alley appears.
      commit(city,
          const FixtureRoad([Vec2(2045, -150), Vec2(2045, 150)],
              roadClass: RoadClass.alley));
      drain();
      final g = city.roadGraph;
      var onAlley = 0;
      for (final p in east) {
        if (!g.hasRearAlley(g.lotNoOf(p.id)!)) continue;
        expect(joinsOf(p.id), 2, reason: '${p.id} after the alley');
        onAlley++;
        expect(book.isCurrentFor(p.id, g), isTrue, reason: p.id);
      }
      expect(onAlley, greaterThan(0));
      // And a second drain with nothing changed does nothing at all.
      drain();
      expect(book.lastSync.generated, 0);
      expect(book.lastSync.chunks, 0);
    });

    test('the access table offers the ALLEY and not the frontage: an F2a site '
        'is reached and left through its cut alone (§5.5)', () {
      // The traffic tables are READ here, never changed (this file is the road
      // side's), and the case lives with the plan because it is the plan's
      // statement that it checks: a network plan's kerbside join carries role
      // `none`, so `AccessPoints.ofPlanJoin` reports it neither in- nor
      // out-capable and `BuildingTable` writes its rows with neither bit. Were
      // it `both`, the street frontage would be offered as a route goal
      // (`addGoals` gates on `kAccIn` alone — `kAccCut` has no reader in lib/),
      // a street would beat a 20 km/h alley on cost, and the car that took it
      // would arrive at a join with no lane behind it, give up at the gate and
      // leave the car park empty.
      final city = town();
      final road =
          commit(city, const FixtureRoad([Vec2(2000, -150), Vec2(2000, 150)]));
      final shops = [
        for (final p in city.layout.autoParcels)
          if (p.roadId == road) p,
      ];
      for (final p in shops) {
        city.placeOnParcel(p.id, cMed);
      }
      commit(
          city,
          const FixtureRoad([Vec2(2045, -150), Vec2(2045, 150)],
              roadClass: RoadClass.alley));
      final book = city.siteAccess;
      expect(
          book.sync(city, city.roadGraph,
              maxUnits: SiteAccessBook.unlimited,
              maxChecks: SiteAccessBook.unlimited),
          isTrue);
      final g = city.roadGraph;
      final lg = LaneGraphBuilder.build(g);
      final plans = BookPlanSource(book);
      final buildings = BuildingTable()..sync(city, lg, plans);
      var checked = 0;
      for (final p in shops) {
        final plan = plans.planOf(p.id);
        if (plan == null || plan.joinCount < 2) continue;
        expect(plan.joinSlot(1), kJoinSlotAlley, reason: p.id);
        final sl = SlotPool.slotOf(buildings.handleOfSite(p.id)!);
        final base = BuildingTable.accRow0(sl);
        expect(buildings.accCount[sl], 4,
            reason: '${p.id}: two joins, each served both ways');
        var routable = 0, kerbside = 0;
        for (var i = 0; i < buildings.accCount[sl]; i++) {
          final r = base + i;
          final bits = buildings.accBits[r];
          final onAlleyRoad =
              g.roads[lg.edgeRoad[buildings.accEdge[r]]].roadClass ==
                  RoadClass.alley;
          if (buildings.accJoin[r] == plan.joinRef(1)) {
            expect(onAlleyRoad, isTrue, reason: p.id);
            expect(bits & kAccIn, kAccIn, reason: p.id);
            expect(bits & kAccOut, kAccOut, reason: p.id);
            expect(bits & kAccCut, kAccCut, reason: p.id);
            routable++;
          } else {
            expect(buildings.accJoin[r], plan.joinRef(0), reason: p.id);
            expect(onAlleyRoad, isFalse, reason: '${p.id}: the street');
            expect(bits & (kAccIn | kAccOut), 0,
                reason: '${p.id}: the frontage is no driveway');
            expect(bits & kAccCut, 0, reason: p.id);
            kerbside++;
          }
        }
        expect((routable, kerbside), (2, 2), reason: p.id);
        checked++;
      }
      expect(checked, greaterThan(0));
    });
  });
}
