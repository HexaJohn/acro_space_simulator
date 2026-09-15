// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'site_plan_fixtures.dart';

/// Fixture validity (docs/plans/site-access.md §7.9, §8.3 R2a): every
/// `SyntheticSites` template is a valid plan under V1–V13 against the
/// starter kit's real road graph and its lane graphs under every override
/// kind, and its site lanes are what §2.5 says.
void main() {
  late RoadGraph g;
  late SiteAccessChunk chunk;

  setUpAll(() {
    g = SyntheticSites.starterCity().roadGraph;
    chunk = SyntheticSites.starterChunk(g);
  });

  SiteAccessPlan plan(String id) => chunk.plan(chunk.siteOf(id));

  test('every fixture passes V1–V13 on the real graph under every override',
      () {
    final spans = SyntheticSites.laneSpansOf(g);
    expect(spans, hasLength(5));
    expect(chunk.siteCount, SyntheticTemplate.values.length + 1);
    final vs = SitePlanValidator.validateChunk(chunk, graph: g, laneSpans: spans);
    expect(vs, isEmpty, reason: vs.join('\n'));
  });

  test('the fixtures are what their names say', () {
    final kerb = plan('KERBSIDE');
    expect(kerb.program, SiteProgram.kerbOnly);
    expect(kerb.hasNetwork, isFalse);
    expect(kerb.joinCount, 1);
    expect(kerb.joinKind(0), SiteJoinKind.kerbside);
    expect([kerb.nodeCount, kerb.segCount, kerb.stallCount], [0, 0, 0]);
    expect(kerb.entranceNode, -1);

    for (final (id, tandem) in [('HOME', false), ('HOME_TANDEM', true)]) {
      final h = plan(id);
      expect(h.program, SiteProgram.homeDriveway);
      expect(h.joinCutHalfM(0), kHomeCutHalfM);
      expect(h.segLaneMode(0), SiteLaneMode.sharedSingle);
      expect(h.segWidthM(0), tandem ? closeTo(3.2, 1e-6) : closeTo(5.2, 1e-6));
      expect(h.segLenM(0), closeTo(7, 1e-9));
      expect(h.segKind(1), SiteSegmentKind.apron);
      expect(h.segLenM(1), closeTo(tandem ? 10.4 : 5.2, 1e-9));
      expect(h.nodeTurnKind(2), TurnaroundKind.none);
      expect(h.nodeFlags(2) & kNodeDeadEnd, isNot(0));
      expect(h.stallCount, 2);
      for (var i = 0; i < 2; i++) {
        expect(h.stallAngle(i), StallAngle.inline);
        expect(h.stallInDirs(i), kSiteDirFwd);
        expect(h.stallOutDirs(i), kSiteDirBwd);
      }
      // Ordered from the street outward: tandem S0 outer, S1 deep.
      expect(h.stallS(0), 0);
      expect(h.stallS(1), tandem ? closeTo(5.2, 1e-6) : 0);
      expect(h.stallSide(1), tandem ? 0 : 1);
    }

    final strip = plan('STRIP');
    expect(strip.program, SiteProgram.carPark);
    expect(strip.stallCount, 24);
    expect(strip.nodeTurnKind(2), TurnaroundKind.circle);

    final loop = plan('LOOP');
    expect(loop.joinCount, 2);
    expect(loop.joinSlot(0), 0);
    expect(loop.joinSlot(1), kJoinSlotSideStreet);
    expect(loop.joinRef(1), kJoinRefSideStreetBase - loop.graphLot);
    expect(loop.joinRole(0), SiteJoinRole.inOnly);
    expect(loop.joinRole(1), SiteJoinRole.outOnly);
    expect(loop.stallAngle(0), StallAngle.angled60);

    final yard = plan('YARD');
    expect(yard.admitsTrucks, isTrue);
    expect(yard.bayCount, 2);
    expect(yard.truckTurnRadiusM, kTruckTurnMinM);

    final u = plan('UTILITY');
    expect(u.program, SiteProgram.installation);
    expect(u.segLenM(0), closeTo(56, 1e-9));
    expect(u.segViaCount(0), 2);
    expect(u.stallCount, 20);
    expect(u.bayCount, 2);
    expect(u.nodeFlags(u.entranceNode) & kNodeGate, isNot(0));
    expect(u.nodeTurnKind(u.entranceNode), TurnaroundKind.hammerhead);

    final f = plan(SyntheticSites.footprintId);
    expect(f.graphLot, -1);
    expect(f.joinRef(0), kJoinRefNone);
  });

  test('site lanes (§2.5): one strongly connected network, in and out lanes by '
      'role', () {
    for (var k = 0; k < chunk.siteCount; k++) {
      final p = chunk.plan(k);
      final lg = SiteLaneGraph.of(p);
      if (!p.hasNetwork) {
        expect(lg.laneCount, 0);
        continue;
      }
      expect(lg.isStronglyConnected, isTrue, reason: p.siteId);
      for (var j = 0; j < p.joinCount; j++) {
        expect(lg.inLane(j) >= 0, p.joinCanIn(j), reason: '${p.siteId} $j');
        if (p.joinCanOut(j)) expect(lg.outLane(j), isNonNegative);
      }
      for (var i = 0; i < p.stallCount; i++) {
        for (final dir in [kSiteDirFwd, kSiteDirBwd]) {
          if (p.stallInDirs(i) & dir == 0) continue;
          expect(lg.isPresent(lg.stallLane(i, dir)), isTrue);
        }
      }
    }
  });

  test('the home pad: reverse-only stall links, no movement at P, scoped to '
      'homeDriveway', () {
    final h = plan('HOME');
    final lg = SiteLaneGraph.of(h);
    final pad = SiteLaneGraph.laneOf(1, forward: true);
    final links = <(int, int, int)>[
      for (var l = 0; l < lg.laneCount; l++)
        for (var i = lg.linkStart[l]; i < lg.linkStart[l + 1]; i++)
          (l, lg.linkTo[i], lg.linkKind[i]),
    ];
    final inline = links.where((x) => x.$3 == kSiteLinkInlineStall).toList();
    expect(inline, [
      (pad, SiteLaneGraph.reverseOf(pad), kSiteLinkInlineStall),
      (pad, SiteLaneGraph.reverseOf(pad), kSiteLinkInlineStall),
    ]);
    // Nothing leaves the pad's forward lane but the stalls: no U-turn at P.
    expect(links.where((x) => x.$1 == pad && x.$3 != kSiteLinkInlineStall),
        isEmpty);
    expect(links.where((x) => x.$3 == kSiteLinkUTurn), isEmpty);
    expect(lg.inLane(0), SiteLaneGraph.laneOf(0, forward: true));
    expect(lg.outLane(0), SiteLaneGraph.laneOf(0, forward: false));
    expect(lg.laneOffsetM(0), 0);

    // The same rows under another program: no stall link, not connected.
    final d = SyntheticSites.draftAt(
        g, SyntheticSites.starterLots[SyntheticTemplate.home]!.$1,
        SyntheticTemplate.home)
      ..program = SiteProgram.carPark;
    final other = SiteLaneGraph.of(
        SyntheticSites.chunkOf(g, [d], validate: false).plan(0));
    expect(
        [
          for (var i = 0; i < other.linkCount; i++)
            if (other.linkKind[i] == kSiteLinkInlineStall) i
        ],
        isEmpty);
    expect(other.isStronglyConnected, isFalse);
  });

  test('the loop: one lane per segment, the road link from out-join to '
      'in-join, lane offsets', () {
    final p = plan('LOOP');
    final lg = SiteLaneGraph.of(p);
    expect([for (var l = 0; l < lg.laneCount; l++) lg.present[l]],
        [1, 0, 0, 1, 1, 0, 1, 0]);
    final road = [
      for (var l = 0; l < lg.laneCount; l++)
        for (var i = lg.linkStart[l]; i < lg.linkStart[l + 1]; i++)
          if (lg.linkKind[i] == kSiteLinkRoad) (l, lg.linkTo[i], lg.linkVia[i])
    ];
    expect(road, [(lg.outLane(1), lg.inLane(0), 0)]);
    final strip = SiteLaneGraph.of(plan('STRIP'));
    expect(strip.laneOffsetM(2), closeTo(1.5, 1e-6));
  });

  test('stall keys: every stall found by its key, in either sign; unknown '
      'keys are gone', () {
    for (var k = 0; k < chunk.siteCount; k++) {
      final p = chunk.plan(k);
      for (var i = 0; i < p.stallCount; i++) {
        expect(p.stallIndexOfKey(p.stallKey(i)), i);
        expect(p.stallIndexOfKey(p.stallKey(i).toUnsigned(32)), i);
      }
    }
    final strip = plan('STRIP');
    var missing = 12345;
    while (strip.stallIndexOfKey(missing) >= 0) {
      missing++;
    }
    expect(strip.stallIndexOfKey(missing), -1);
  });

  test('stall keys hash the lattice, not the world: the same plan on another '
      'lot keeps its keys; indices follow (seg, s, side)', () {
    final a = plan('STRIP');
    final other = SyntheticSites.placeAt(g, 'lot-r1x0-l3', SyntheticTemplate.strip)
        .plan(0);
    expect(other.stallCount, a.stallCount);
    for (var i = 0; i < a.stallCount; i++) {
      expect(other.stallKey(i), a.stallKey(i));
    }
    // A collision takes key + 1 in lattice order.
    final k = PlanBuilder.latticeKey(2, 0, 0, 0, 6);
    expect(k, PlanBuilder.latticeKey(2, 0, 0, 0, 6));
    expect(PlanBuilder.headingOctant(0, 1, 1, 0), 2);
    expect(PlanBuilder.headingOctant(-0.7, -0.7, 1, 0), 5);
    expect(PlanBuilder.headingOctant(0.1, -1, 1, 0), 6);
  });

  test('determinism: the same calls give the same bytes; rev ignores the site '
      'id and graph resolution', () {
    final again = SyntheticSites.starterChunk(g);
    final a = chunk.debugRetained, b = again.debugRetained;
    for (var i = 0; i < 5; i++) {
      final x = a[i] as TypedData, y = b[i] as TypedData;
      expect(y.buffer.asUint8List(y.offsetInBytes, y.lengthInBytes),
          x.buffer.asUint8List(x.offsetInBytes, x.lengthInBytes),
          reason: 'backing $i');
    }
    final renamed = SyntheticSites.draftAt(
        g, SyntheticSites.starterLots[SyntheticTemplate.home]!.$1,
        SyntheticTemplate.home,
        siteId: 'a-renamed-lot');
    final r = SyntheticSites.chunkOf(g, [renamed]).plan(0);
    expect(r.rev, plan('HOME').rev);
    expect(r.rev, isNot(0));
  });
}
