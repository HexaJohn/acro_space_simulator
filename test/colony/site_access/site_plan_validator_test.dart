// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
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

    test('no out-capable join (the site then also falls apart, V7)', () {
      final d = draft(SyntheticTemplate.strip);
      d.joins[0].role = SiteJoinRole.inOnly;
      final got = {for (final v in violations(d)) v.invariant};
      expect(got, containsAll([SiteInvariant.v4Roles]));
      expect(got.difference({SiteInvariant.v4Roles, SiteInvariant.v7Connected}),
          isEmpty);
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
  });

  test('V6: two nodes within 0.5 m', () {
    final d = draft(SyntheticTemplate.strip);
    final e = d.nodes[2];
    d.nodes.add(DraftNode(e.e + 0.3, e.n));
    rejects(d, SiteInvariant.v6Nodes);
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
  });

  test('V10: an aisle ahead of the throat', () {
    final d = draft(SyntheticTemplate.strip)..swapSegments(0, 1);
    rejects(d, SiteInvariant.v10OrderAndKeys);
  });

  test('V11: a network plan without an entrance node', () {
    final d = draft(SyntheticTemplate.strip)..entranceNode = -1;
    rejects(d, SiteInvariant.v11Entrance);
  });

  test('V12: a rev that is not the content hash', () {
    final d = draft(SyntheticTemplate.strip);
    d.revOverride = planOf(d).rev + 1;
    rejects(d, SiteInvariant.v12Revision);
  });

  test('V13: trucks admitted with a 10 m turning circle', () {
    final d = draft(SyntheticTemplate.yard);
    d.nodes[3].turnR = 10;
    rejects(d, SiteInvariant.v13Reserved);
  });

  test('geometry: a coordinate that is not finite stops the check', () {
    final d = draft(SyntheticTemplate.strip);
    d.stalls[0].e = double.nan;
    rejects(d, SiteInvariant.geometry);
  });
}
