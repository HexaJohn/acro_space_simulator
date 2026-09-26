// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'site_plan_fixtures.dart';

/// The validator rejects what it claims (docs/plans/site-access.md §2.4, §8.3
/// R2a): every hand-broken fixture fails EXACTLY the invariant it breaks, and
/// the V5, V7, V9, V1 and V8 cases §8.3 lists are pinned one by one.
void main() {
  late RoadGraph g;
  late List<SiteLaneSpans> spans;

  setUpAll(() {
    g = SyntheticSites.starterCity().roadGraph;
    spans = SyntheticSites.laneSpansOf(g);
  });

  DraftSite draft(SyntheticTemplate t) =>
      SyntheticSites.draftAt(g, SyntheticSites.starterLots[t]!.$1, t);

  SiteAccessPlan planOf(DraftSite d) =>
      SyntheticSites.chunkOf(g, [d], validate: false).plan(0);

  List<SiteViolation> violations(DraftSite d, {List<SiteLaneSpans>? with_}) =>
      SitePlanValidator.validate(planOf(d), graph: g, laneSpans: with_ ?? spans);

  void rejects(DraftSite d, SiteInvariant v, {List<SiteLaneSpans>? with_}) {
    final vs = violations(d, with_: with_);
    expect({for (final x in vs) x.invariant}, {v},
        reason: 'expected exactly ${v.label}, got:\n${vs.join('\n')}');
  }

  void accepts(DraftSite d, {List<SiteLaneSpans>? with_}) {
    final vs = violations(d, with_: with_);
    expect(vs, isEmpty, reason: vs.join('\n'));
  }

  /// Moves node [n] of [d] by frame (dx, dy).
  void moveNode(DraftSite d, int n, double dx, double dy) {
    final (e, nn) = d.dir(dx, dy);
    d.nodes[n]
      ..e += e
      ..n += nn;
  }

  test('every unbroken template passes (the baseline each case breaks)', () {
    for (final t in SyntheticTemplate.values) {
      accepts(draft(t));
    }
    accepts(SyntheticSites.footprintDraft(g));
  });

  group('V1 window', () {
    test('a cut wider than its kerb window', () {
      final d = draft(SyntheticTemplate.home);
      final j = d.joins[0];
      // Just past the slot's own room: the cut reaches out of the window.
      j.cutHalfM = g.kerbWindows.roomAt(j.piece, j.roadS) + 0.25;
      rejects(d, SiteInvariant.v1Window);
    });

    test('a home join with 11.9 m of lane upstream of T is rejected; 12 m '
        'passes', () {
      final d = draft(SyntheticTemplate.home);
      final j = d.joins[0];
      final e = g.pieceFwdEdge[j.piece];
      expect(j.dirs & RoadGraph.forwardBit, isNot(0));
      List<SiteLaneSpans> upstream(double metres) {
        final base = spans.first;
        final s0 = Float32List.fromList(base.laneS0);
        s0[e] = base.travelArc(e, j.roadS) - metres;
        return [(laneS0: s0, laneS1: base.laneS1, travelArc: base.travelArc)];
      }

      rejects(d, SiteInvariant.v1Window, with_: upstream(11.9));
      accepts(d, with_: upstream(12.0));
      // The same plan as a car park keeps no swing margin.
      final strip = draft(SyntheticTemplate.strip);
      final e2 = g.pieceFwdEdge[strip.joins[0].piece];
      final base = spans.first;
      final s0 = Float32List.fromList(base.laneS0);
      s0[e2] = base.travelArc(e2, strip.joins[0].roadS) - 11.9;
      accepts(strip,
          with_: [(laneS0: s0, laneS1: base.laneS1, travelArc: base.travelArc)]);
    });
  });

  test('V2: dirs that are not joinDirsFor(road, side)', () {
    final d = SyntheticSites.footprintDraft(g);
    expect(d.joins[0].ref, kJoinRefNone); // V3 has nothing to compare
    d.joins[0].dirs = RoadGraph.forwardBit;
    rejects(d, SiteInvariant.v2SideAndDirections);
  });

  group('V3 one source', () {
    test('a copied arc a quantum off its slot', () {
      final d = draft(SyntheticTemplate.home);
      d.joins[0].roadS += 0.25;
      rejects(d, SiteInvariant.v3OneSource);
    });

    test('a side-street join whose handle is not joinRefOf(lot, 2)', () {
      final d = draft(SyntheticTemplate.loop);
      expect(d.joins[1].ref, lessThanOrEqualTo(kJoinRefSideStreetBase));
      d.joins[1].ref = kJoinRefSideStreetBase - (d.graphLot + 1);
      rejects(d, SiteInvariant.v3OneSource);
    });
  });

  group('V4 roles', () {
    test('a network under a kerb-only program', () {
      final d = draft(SyntheticTemplate.strip)..program = SiteProgram.kerbOnly;
      rejects(d, SiteInvariant.v4Roles);
    });

    test('two cuts on one piece need a 6 m gap between their EDGES', () {
      List<String> spacing(double gapM) {
        final d = draft(SyntheticTemplate.strip);
        final j0 = d.joins[0];
        d.joins.add(DraftJoin(
          slot: 1,
          ref: j0.ref,
          piece: j0.piece,
          roadS: j0.roadS + 2 * j0.cutHalfM + gapM,
          right: j0.right,
          dirs: j0.dirs,
          roadNo: j0.roadNo,
          cutHalfM: j0.cutHalfM,
        ));
        return [
          for (final v in violations(d))
            if (v.invariant == SiteInvariant.v4Roles &&
                v.detail.contains('edge to edge'))
              v.detail
        ];
      }

      // Centres 13.9 m apart with 4 m halves: the old centre reading passed.
      expect(spacing(5.9), hasLength(1));
      expect(spacing(6.0), isEmpty);
    });

    test('no out-capable join (the site then also falls apart, V7)', () {
      final d = draft(SyntheticTemplate.strip);
      d.joins[0].role = SiteJoinRole.inOnly;
      final got = {for (final v in violations(d)) v.invariant};
      expect(got, containsAll([SiteInvariant.v4Roles]));
      expect(got.difference({SiteInvariant.v4Roles, SiteInvariant.v7Connected}),
          isEmpty);
    });

    // The strip car park on a lot with an alley behind it, plus a KERBSIDE join
    // on its real rear-alley slot 3 with role [role]: §2.4's widening, on the
    // generator's own join handle.
    //
    // The second join is `joinRefOf(lot, kJoinSlotAlley)`, its piece, arc, side
    // and dirs copied from the slot the graph placed, so V3 and V2 have
    // something real to check and the case would fail if slot 3 were refused
    // anywhere. The ORIENTATION the generator emits is the mirror of this one
    // (the kerbside join at slot 0, the cut at slot 3); that shape is pinned on
    // a real plan, with its geometry, by `alley_car_park_test`. What is isolated
    // here is V4's rule alone.
    List<SiteViolation> alleyPlusKerbside(SiteJoinRole role) {
      final (ga, lotId) = _alleyBlock();
      final lot = ga.lotNoOf(lotId)!;
      final s3 = ga.rearAlleyJoinOf(lot)!;
      final d = SyntheticSites.draftAt(ga, lotId, SyntheticTemplate.strip);
      d.joins.add(DraftJoin(
        slot: kJoinSlotAlley,
        ref: ga.joinRefOf(lot, kJoinSlotAlley),
        piece: s3.piece,
        roadS: s3.s,
        right: s3.right,
        dirs: s3.dirs,
        roadNo: ga.pieceRoad[s3.piece],
        role: role,
        kind: SiteJoinKind.kerbside,
      ));
      expect(d.joins[1].ref, kJoinRefAlleyBase - lot);
      return SitePlanValidator.validate(
          SyntheticSites.chunkOf(ga, [d], validate: false).plan(0),
          graph: ga,
          laneSpans: SyntheticSites.laneSpansOf(ga));
    }

    test('ACCEPTED: a kerbside join on the REAR ALLEY SLOT beside the cut '
        '(R8\'s widening)', () {
      // §2.4 asks a network plan for ≥ 1 in-capable and ≥ 1 out-capable CUT
      // join, not that every join be a cut. Its role is `none`: nothing but a
      // cut may say "drive here".
      final vs = alleyPlusKerbside(SiteJoinRole.none);
      expect(vs, isEmpty, reason: vs.join('\n'));
    });

    test('REJECTED: the same kerbside join claiming a vehicle role', () {
      // The other half of the widening. A kerbside join with a role is offered
      // to the access table as a driveway (§5.5): it wins the goal whenever its
      // road is the cheaper one, and the car that took it arrives at a join
      // with no lane behind it. Only a cut may carry a role.
      for (final role in [
        SiteJoinRole.both,
        SiteJoinRole.inOnly,
        SiteJoinRole.outOnly
      ]) {
        expect([
          for (final v in alleyPlusKerbside(role))
            if (v.invariant == SiteInvariant.v4Roles) v.detail
        ], [
          'kerbside join 1 of a network plan has role ${role.name}, not none'
        ]);
      }
    });

    test('REJECTED: a cut join with no role at all', () {
      // The converse: a cut exists to be driven. A roleless cut contributes to
      // neither direction, so it is a kerb cut nothing uses.
      final d = draft(SyntheticTemplate.strip);
      d.joins[0].role = SiteJoinRole.none;
      expect([
        for (final v in violations(d))
          if (v.invariant == SiteInvariant.v4Roles) v.detail
      ], ['cut join 0 has no role', 'no in-capable cut join',
        'no out-capable cut join']);
    });

    test('a network plan of kerbside joins alone is still rejected', () {
      // The widening above must not become "anything goes": a network with no
      // CUT join has no way in and no way out, and V4 still says so.
      final d = draft(SyntheticTemplate.strip);
      d.joins[0]
        ..kind = SiteJoinKind.kerbside
        ..role = SiteJoinRole.none
        ..cutHalfM = 0;
      final vs = violations(d);
      expect([
        for (final v in vs)
          if (v.invariant == SiteInvariant.v4Roles) v.detail
      ], ['no in-capable cut join', 'no out-capable cut join']);
      // The rest is the site coming apart once its join lanes are gone (its
      // throat is nobody's), not V4's business.
      expect(
          {for (final v in vs) v.invariant}.difference({
            SiteInvariant.v4Roles,
            SiteInvariant.v7Connected,
            SiteInvariant.v10OrderAndKeys,
          }),
          isEmpty,
          reason: vs.join('\n'));
    });
  });

  group('V5 throat', () {
    test('ACCEPTED: a 56 m throat with vias at 24 and 48 m to a frontage node',
        () {
      final d = draft(SyntheticTemplate.utility);
      final p = planOf(d);
      expect(p.segViaCount(0), 2);
      expect(p.segLenM(0), closeTo(56, 1e-9));
      accepts(d);
    });

    test('ACCEPTED: the home K→H→P straight run, P with no turnaround', () {
      for (final t in [SyntheticTemplate.home, SyntheticTemplate.homeTandem]) {
        final d = draft(t);
        expect(d.nodes[2].turn, TurnaroundKind.none);
        accepts(d);
      }
    });

    test('a via 0.2 m off the chord', () {
      final d = draft(SyntheticTemplate.utility);
      final (e, n) = d.segs[0].vias[0];
      final (ue, un) = d.dir(0.2, 0);
      d.segs[0].vias = [(e + ue, n + un), d.segs[0].vias[1]];
      rejects(d, SiteInvariant.v5Throat);
    });

    test('vias 25 m apart', () {
      final d = draft(SyntheticTemplate.utility);
      d.segs[0].vias = [d.w(0, 25 - 56), d.w(0, 50 - 56)];
      rejects(d, SiteInvariant.v5Throat);
    });

    test('a 6.9 m throat, its stall mouths 6.9 m from the kerb', () {
      final d = draft(SyntheticTemplate.home);
      moveNode(d, 1, 0, -0.1); // H
      moveNode(d, 2, 0, -0.1); // P
      final (e, n) = d.dir(0, -0.1);
      for (final s in d.stalls) {
        s
          ..e += e
          ..n += n;
      }
      final vs = violations(d);
      rejects(d, SiteInvariant.v5Throat);
      expect(vs.where((v) => v.detail.contains('stall')), isNotEmpty);
    });

    test('a branch node 6.9 m from the kerb node', () {
      final d = draft(SyntheticTemplate.yard);
      moveNode(d, 1, 0, -0.1); // J
      final vs = violations(d);
      rejects(d, SiteInvariant.v5Throat);
      expect(vs.where((v) => v.detail.contains('branch node')), isNotEmpty);
    });

    test('a home cut half of 3.9 m', () {
      final d = draft(SyntheticTemplate.home);
      d.joins[0].cutHalfM = 3.9;
      rejects(d, SiteInvariant.v5Throat);
    });

    test('a home pad whose end node lies 0.2 m off the throat axis', () {
      final d = draft(SyntheticTemplate.homeTandem);
      moveNode(d, 2, 0.2, 0); // P
      rejects(d, SiteInvariant.v5Throat);
    });

    test('a bent home pad: a via 0.2 m off the axis, its end back on it', () {
      final d = draft(SyntheticTemplate.homeTandem);
      d.segs[1].vias = [d.w(0.2, 4 + 5.2)];
      final vs = violations(d);
      rejects(d, SiteInvariant.v5Throat);
      expect(vs.single.detail, contains('via'));
    });
  });

  test('V6: two nodes within 0.5 m (the aisle stub between them < 1 m)', () {
    final d = draft(SyntheticTemplate.strip);
    // E(42, 8.5) goes on 0.3 m to a new dead end X with the circle.
    final x = d.node(42.3, 8.5,
        flags: kNodeDeadEnd, turn: TurnaroundKind.circle, turnR: 6.5);
    d.segs.add(DraftSeg(2, x,
        kind: SiteSegmentKind.aisle, mode: SiteLaneMode.twoWay, widthM: 6));
    final vs = violations(d);
    rejects(d, SiteInvariant.v6Nodes);
    expect(vs.where((v) => v.detail.contains('within')), isNotEmpty);
  });

  group('V7 connected', () {
    test('a dead end without a turnaround that is no home pad end', () {
      final d = draft(SyntheticTemplate.strip);
      d.nodes[2]
        ..turn = TurnaroundKind.none
        ..turnR = 0;
      rejects(d, SiteInvariant.v7Connected);
    });

    test('a circle under 6 m', () {
      final d = draft(SyntheticTemplate.strip);
      d.nodes[2].turnR = 5.9;
      rejects(d, SiteInvariant.v7Connected);
    });

    test('a hammerhead with no clear apron: the gate with a bay in it', () {
      final d = draft(SyntheticTemplate.utility);
      final gate = d.nodes[3];
      d.bays[0]
        ..e = gate.e
        ..n = gate.n;
      final got = {for (final v in violations(d)) v.invariant};
      expect(got, contains(SiteInvariant.v7Connected));
    });

    test('two halves joined only by the road: each strongly connected through '
        'road links, but join 1 is unreachable inside the site from join 0',
        () {
      final d = draft(SyntheticTemplate.loop);
      // Nodes K1, K2, A, B, C: drop C and the aisles A→C, C→B with their
      // stalls; two-way 6 m throats, both joins both ways, circles at A, B.
      d.nodes.removeLast();
      d.segs.removeRange(2, 4);
      d.stalls.clear();
      d.paves.removeRange(2, 4);
      for (final s in d.segs) {
        s
          ..mode = SiteLaneMode.twoWay
          ..widthM = 6;
      }
      for (final j in d.joins) {
        j
          ..role = SiteJoinRole.both
          ..cutHalfM = 3 + kCutFlareM;
      }
      for (final n in [d.nodes[2], d.nodes[3]]) {
        n
          ..flags = kNodeDeadEnd
          ..turn = TurnaroundKind.circle
          ..turnR = 6;
      }
      d.entranceNode = 2;
      final lg = SiteLaneGraph.of(planOf(d));
      expect(lg.isStronglyConnected, isTrue); // the old V7 passed it
      final vs = violations(d);
      rejects(d, SiteInvariant.v7Connected);
      expect(vs.where((v) => v.detail.contains('unreachable')), isNotEmpty);
    });

    test('a node of site degree 0', () {
      final d = draft(SyntheticTemplate.strip)..node(20, 40);
      final vs = violations(d);
      rejects(d, SiteInvariant.v7Connected);
      expect(vs.single.detail, contains('isolated node'));
    });

    test('the home exception is scoped to homeDriveway', () {
      final d = draft(SyntheticTemplate.home)..program = SiteProgram.carPark;
      final got = {for (final v in violations(d)) v.invariant};
      expect(got, contains(SiteInvariant.v7Connected));
    });
  });

  test('V8: a segLenM off by 2e-6', () {
    final d = draft(SyntheticTemplate.strip);
    final len = planOf(d).segLenM(1);
    d.segs[1].lenM = len + 2e-6;
    rejects(d, SiteInvariant.v8Segments);
    d.segs[1].lenM = len + 0.5e-6;
    accepts(d);
  });

  group('V9 stalls', () {
    test('an inline home stall with stallInDirs != {fwd}', () {
      final d = draft(SyntheticTemplate.home);
      d.stalls[0].inDirs = kSiteDirBwd;
      rejects(d, SiteInvariant.v9Stalls);
    });

    test('an inline home stall with stallOutDirs != {bwd}', () {
      final d = draft(SyntheticTemplate.homeTandem);
      d.stalls[1].outDirs = kSiteDirFwd | kSiteDirBwd;
      rejects(d, SiteInvariant.v9Stalls);
    });

    test('a stall with no in-dir bit', () {
      final d = draft(SyntheticTemplate.strip);
      d.stalls[5].inDirs = 0;
      rejects(d, SiteInvariant.v9Stalls);
    });

    test('a forward bit without run-up', () {
      final d = draft(SyntheticTemplate.strip);
      expect(d.stalls[0].s, lessThan(6.3));
      d.stalls[0].inDirs |= kSiteDirFwd;
      rejects(d, SiteInvariant.v9Stalls);
    });

    test('a perpendicular stall moved 4.6 m into its own aisle', () {
      final d = draft(SyntheticTemplate.strip);
      final s = d.stalls[0];
      final (e, n) = d.dir(0, 4.6); // toward the centreline (side 0 is −v)
      s
        ..e += e
        ..n += n;
      final vs = violations(d);
      rejects(d, SiteInvariant.v9Stalls);
      expect(vs.single.detail, contains('own carriageway'));
    });

    test('both in-dirs on a perpendicular stall need a two-way aisle of 6 m',
        () {
      // The strip's mid-aisle stalls take both bits on its 6 m two-way aisle.
      final strip = draft(SyntheticTemplate.strip);
      final k = strip.stalls[5].seg;
      expect(strip.segs[k].mode, SiteLaneMode.twoWay);
      expect(strip.stalls[5].inDirs, kSiteDirFwd | kSiteDirBwd);
      accepts(strip);
      // The same stalls on a 5.4 m shared single lane (legal for V8).
      final shared = draft(SyntheticTemplate.strip);
      shared.segs[k]
        ..mode = SiteLaneMode.sharedSingle
        ..widthM = 5.4;
      final both = [
        for (var i = 0; i < shared.stalls.length; i++)
          if (shared.stalls[i].seg == k &&
              shared.stalls[i].inDirs == kSiteDirFwd | kSiteDirBwd)
            i,
      ];
      final vs = violations(shared);
      rejects(shared, SiteInvariant.v9Stalls);
      expect(vs, hasLength(both.length));
      expect(vs.every((v) => v.detail.contains('both in-dirs')), isTrue);
      // Down to one direction each, they pass.
      for (final i in both) {
        shared.stalls[i].inDirs = kSiteDirBwd;
      }
      accepts(shared);
    });
  });

  test('V10: an aisle ahead of the throat', () {
    final d = draft(SyntheticTemplate.strip)..swapSegments(0, 1);
    rejects(d, SiteInvariant.v10OrderAndKeys);
  });

  group('V11 entrance', () {
    test('a network plan without an entrance node', () {
      final d = draft(SyntheticTemplate.strip)..entranceNode = -1;
      rejects(d, SiteInvariant.v11Entrance);
    });

    test('no door (entrancePt −1)', () {
      rejects(draft(SyntheticTemplate.strip)..omitEntrance = true,
          SiteInvariant.v11Entrance);
      rejects(draft(SyntheticTemplate.kerbside)..omitEntrance = true,
          SiteInvariant.v11Entrance);
    });

    test('no pavement point (pavementPt −1)', () {
      rejects(draft(SyntheticTemplate.kerbside)..omitPavement = true,
          SiteInvariant.v11Entrance);
      rejects(draft(SyntheticTemplate.strip)..omitPavement = true,
          SiteInvariant.v11Entrance);
    });

    test('an entrance node out of range', () {
      final d = draft(SyntheticTemplate.strip)..entranceNode = 99;
      rejects(d, SiteInvariant.v11Entrance);
    });
  });

  test('V12: a rev that is not the content hash', () {
    final d = draft(SyntheticTemplate.strip);
    d.revOverride = planOf(d).rev + 1;
    rejects(d, SiteInvariant.v12Revision);
  });

  group('V13 trucks', () {
    test('trucks admitted with a 10 m turning circle', () {
      final d = draft(SyntheticTemplate.yard);
      d.nodes[3].turnR = 10;
      rejects(d, SiteInvariant.v13Reserved);
    });

    test('the bays reached only past a 6 m circle while a 12.5 m circle '
        'stands on another truck spur', () {
      final d = draft(SyntheticTemplate.yard);
      d.segs[1].maxVehLenM = kTruckMinVehLenM; // the aisle J→E takes trucks
      d.nodes[2].turnR = kTruckTurnMinM; // E
      d.nodes[3].turnR = 6; // Y, the apron's end
      rejects(d, SiteInvariant.v13Reserved);
    });

    test('one-way lanes are respected: an apron trucks can only leave', () {
      final d = draft(SyntheticTemplate.utility);
      // The spine Y→G one-way toward Y: no truck lane reaches the bays from
      // Y, and from the gate end nothing enters.
      d.segs[8].mode = SiteLaneMode.oneWayBackward;
      final got = {for (final v in violations(d)) v.invariant};
      expect(got, contains(SiteInvariant.v13Reserved));
    });
  });

  test('geometry: a coordinate that is not finite stops the check', () {
    final d = draft(SyntheticTemplate.strip);
    d.stalls[0].e = double.nan;
    rejects(d, SiteInvariant.geometry);
  });

  test('geometry: a fence gap that is not finite', () {
    final d = draft(SyntheticTemplate.strip)..fenceGaps = [(0, 0.2, 0.4)];
    accepts(d);
    d.fenceGaps = [(0, double.nan, 0.4)];
    rejects(d, SiteInvariant.geometry);
  });
}

/// A downtown block as the generator cuts one (`blockDepthM` 104, `alleys`
/// true, `lotDepthM` 46: an alley IS the midline, so a lot runs all the way to
/// it), and the id of a lot that backs onto the alley — one whose slot 3 the
/// graph will place.
(RoadGraph, String) _alleyBlock() {
  final layout = CityLayout(settings: ParcelSettings(frontageM: 24, depthM: 46))
    ..commitRoad(controls: const [Vec2(0, 0), Vec2(400, 0)])
    ..commitRoad(controls: const [Vec2(0, 104), Vec2(400, 104)])
    ..commitRoad(
        controls: const [Vec2(0, 52), Vec2(400, 52)],
        roadClass: RoadClass.alley);
  final g = RoadGraph.of(layout);
  for (final p in layout.autoParcels) {
    final lot = g.lotNoOf(p.id);
    if (lot != null && g.rearAlleyJoinOf(lot) != null) return (g, p.id);
  }
  throw StateError('no lot of the block backs onto its alley');
}
