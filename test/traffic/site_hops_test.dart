// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a synced site row knows about getting about inside it
/// (docs/plans/t4a-implementation.md §1.3; site-access.md §7.4 step 2, §7.5,
/// §7.8 item 2, D49): the rows themselves, the next-hop tables, the stall
/// order each join fills by, and the `sharedSingle` claim units.
///
/// The hops are checked against a plain relaxation over the plan's own links
/// written here — a different algorithm from the table's breadth-first walk,
/// so the two agreeing means the ANSWER is right and not just the code
/// repeated twice. Road links are left out of both: a road link is the
/// public road, which a car reaches by an EXIT event and not by a hop
/// (§2.5).
library;

import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_table.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';

void main() {
  late SiteWorld w;

  setUpAll(() {
    w = SiteWorld(everyTemplate())..sync();
  });

  /// The templates with a network, which is every one but the kerbside.
  const networks = [
    SyntheticTemplate.home,
    SyntheticTemplate.homeTandem,
    SyntheticTemplate.strip,
    SyntheticTemplate.loop,
    SyntheticTemplate.yard,
    SyntheticTemplate.utility,
  ];

  test('a row per built site with a network plan, and none for a kerbside one',
      () {
    final s = w.sites;
    for (final t in networks) {
      final lot = lotOf(t);
      final row = w.rowOf(lot);
      expect(row, greaterThanOrEqualTo(0), reason: '$t has a network plan');
      final p = w.planOf(lot);
      expect(s.rowFlags[row] & kRowLive, kRowLive, reason: '$t');
      expect(s.rowFlags[row] & (kRowLimbo | kRowNotCurrent), 0, reason: '$t');
      expect(s.lotCap[row], p.stallCount, reason: '$t: capacity IS the stalls');
      expect(s.stallCount[row], p.stallCount, reason: '$t');
      expect(s.lotUsed[row], 0, reason: '$t starts empty');
      expect(s.rev[row], p.rev, reason: '$t');
      expect(s.bookSlot[row], w.plans.slotOf(lot),
          reason: '$t: the book slot is the wire ordinal');
      expect(s.building[row], w.buildingOf(lot), reason: '$t');
      expect(s.laneCount[row], 2 * p.segCount, reason: '$t');
      expect(s.inside[row], 0, reason: '$t');
    }

    final kerbside = lotOf(SyntheticTemplate.kerbside);
    expect(w.plans.planOf(kerbside), isNotNull, reason: 'it has a plan');
    expect(w.rowOf(kerbside), -1,
        reason: 'a kerbside plan has no network row (§7.6 row 2), so the '
            'gate reads it as no stalls at all');
    expect(w.changes.count, 0, reason: 'a first sync tells the sink nothing');
  });

  test('every site element is its row\'s lane, with the plan\'s length and cap',
      () {
    final s = w.sites;
    for (final t in networks) {
      final row = w.rowOf(lotOf(t));
      final p = w.planOf(lotOf(t));
      final g = w.lanesOf(lotOf(t));
      for (var l = 0; l < s.laneCount[row]; l++) {
        final e = s.elemBase[row] + l;
        expect(s.elemRow[e], row, reason: '$t lane $l');
        expect(s.elemHead[e], -1, reason: '$t lane $l');
        expect(s.elemTail[e], -1, reason: '$t lane $l');
        expect(s.elemCount[e], 0, reason: '$t lane $l');
        if (g.present[l] == 0) {
          expect(s.elemLen[e], 0, reason: '$t lane $l is not there');
          continue;
        }
        expect(s.elemLen[e], closeTo(p.segLenM(SiteLaneGraph.segOf(l)), 1e-3),
            reason: '$t lane $l');
        expect(s.elemVmax[e], closeTo(p.segSpeedMps(SiteLaneGraph.segOf(l)), 1e-3),
            reason: '$t lane $l');
      }
    }
  });

  test('the hops agree with a plain walk of the plan\'s links', () {
    final s = w.sites;
    for (final t in networks) {
      final row = w.rowOf(lotOf(t));
      final p = w.planOf(lotOf(t));
      final g = w.lanesOf(lotOf(t));
      final outs = _outJoins(p, g);
      expect(s.targetCount[row], p.stallCount + outs.length, reason: '$t');
      for (var k = 0; k < s.targetCount[row]; k++) {
        final ends = _terminals(p, g, outs, k);
        expect(ends, isNotEmpty, reason: '$t target $k');
        expect(ends, contains(s.laneOfTarget(row, k)),
            reason: '$t target $k: the lane it names is one it ends on');
        final d = _stepsTo(g, ends);
        for (var l = 0; l < g.laneCount; l++) {
          if (g.present[l] == 0) continue;
          final next = s.nextLane(row, l, k);
          final why = '$t target $k from lane $l';
          if (d[l] < 0) {
            expect(next, -1, reason: '$why is unreachable');
            continue;
          }
          if (d[l] == 0) {
            expect(next, l, reason: '$why is already there');
            continue;
          }
          expect(next, greaterThanOrEqualTo(0), reason: why);
          expect(d[next], d[l] - 1, reason: '$why must be a step nearer');
          expect(_linked(g, l, next), isTrue,
              reason: '$why must be a link a car may take');
        }
      }
    }
  });

  test('every in-join reaches every stall and every way out (V7)', () {
    final s = w.sites;
    var checked = 0;
    for (final t in networks) {
      final row = w.rowOf(lotOf(t));
      final p = w.planOf(lotOf(t));
      final g = w.lanesOf(lotOf(t));
      for (var j = 0; j < p.joinCount; j++) {
        final from = g.inLane(j);
        if (!p.joinCanIn(j) || from < 0) continue;
        checked++;
        for (var k = 0; k < s.targetCount[row]; k++) {
          expect(s.nextLane(row, from, k), greaterThanOrEqualTo(0),
              reason: '$t: join $j must reach target $k');
        }
      }
    }
    expect(checked, networks.length, reason: 'every template has one in-join');
  });

  test('a road link is never a hop: leaving is an EXIT, not a turn', () {
    final s = w.sites;
    // The strip's throat out-lane ends at its kerb node, and the only link
    // on from there is the road. Its own stalls are then unreachable
    // WITHOUT leaving, which is exactly what the exclusion has to mean.
    final row = w.rowOf(lotOf(SyntheticTemplate.strip));
    final g = w.lanesOf(lotOf(SyntheticTemplate.strip));
    final out = g.outLane(0);
    expect(out, greaterThanOrEqualTo(0));
    var roadLinks = 0;
    for (var i = g.linkStart[out]; i < g.linkStart[out + 1]; i++) {
      if (g.linkKind[i] == kSiteLinkRoad) roadLinks++;
    }
    expect(roadLinks, greaterThan(0), reason: 'the plan does model the road');
    for (var k = 0; k < s.stallCount[row]; k++) {
      expect(s.nextLane(row, out, k), -1,
          reason: 'a car at the kerb line is on its way OUT');
    }
  });

  test('the stall order is by how far in the stall is', () {
    final s = w.sites;
    final lot = lotOf(SyntheticTemplate.strip);
    final row = w.rowOf(lot);
    final p = w.planOf(lot), g = w.lanesOf(lot);
    final n = p.stallCount;
    expect(n, 24);
    final into = _reach(p, g, g.inLane(0));
    final order = _orderOf(s, row, 0, n);
    expect(order.toSet(), hasLength(n), reason: 'every stall, once');
    for (var i = 1; i < n; i++) {
      final a = order[i - 1], b = order[i];
      expect(into[a] <= into[b], isTrue,
          reason: 'stall $a (${into[a]} m) must not come after $b '
              '(${into[b]} m)');
      if (into[a] == into[b]) {
        expect(a, lessThan(b), reason: 'a tie goes to the lower index');
      }
    }
    // The two stalls at the aisle mouth can only be entered by REVERSING up
    // the aisle, so they are the longest drive of all and go last, which is
    // the whole point of ordering by path length rather than by index.
    expect(order.sublist(n - 2)..sort(), [0, 1]);
    expect(p.stallInDirs(0) & kSiteDirFwd, 0, reason: 'no run-up at s = 4.5');
  });

  test('a home pad fills from the back', () {
    final s = w.sites;
    final tandem = lotOf(SyntheticTemplate.homeTandem);
    final row = w.rowOf(tandem);
    final p = w.planOf(tandem);
    expect(p.program, SiteProgram.homeDriveway);
    expect(p.stallCount, 2);
    expect(p.stallS(1), greaterThan(p.stallS(0)), reason: 'stall 1 is deeper');
    expect(_orderOf(s, row, 0, 2), [1, 0],
        reason: 'a tandem pad takes the DEEPEST free stall first (§7.5), or '
            'the outer car boxes the inner one in');
    expect(s.firstFreeStall(row, 0), 1);

    // Side by side, the two stalls are the same drive in, so the tie by
    // index leaves them in the plan's own order.
    final side = lotOf(SyntheticTemplate.home);
    final sideRow = w.rowOf(side);
    expect(w.planOf(side).stallCount, 2);
    expect(_orderOf(s, sideRow, 0, 2), [0, 1]);
  });

  test('a home drive is one sharedSingle claim unit, K to H to P', () {
    final s = w.sites;
    for (final t in const [
      SyntheticTemplate.home,
      SyntheticTemplate.homeTandem,
    ]) {
      final row = w.rowOf(lotOf(t));
      final p = w.planOf(lotOf(t));
      expect(p.segCount, 2, reason: '$t is the throat and the pad');
      expect(p.segLaneMode(0), SiteLaneMode.sharedSingle, reason: '$t');
      expect(p.segLaneMode(1), SiteLaneMode.sharedSingle, reason: '$t');
      expect(s.unitCount[row], 1,
          reason: '$t: the chain from the kerb node to the first two-way or '
              'turnaround node is ONE unit (§7.4)');
      final unit = s.unitBase[row];
      for (var l = 0; l < s.laneCount[row]; l++) {
        expect(s.elemUnit[s.elemBase[row] + l], unit,
            reason: '$t lane $l is in the drive\'s claim unit');
      }
      expect(s.unitClaimH[unit], -1);
      expect(s.unitClaimers[unit], 0);
    }

    // Nothing else the templates build is a single-lane chain.
    for (final t in const [
      SyntheticTemplate.strip,
      SyntheticTemplate.loop,
      SyntheticTemplate.yard,
      SyntheticTemplate.utility,
    ]) {
      final row = w.rowOf(lotOf(t));
      expect(s.unitCount[row], 0, reason: '$t has no shared single lane');
      for (var l = 0; l < s.laneCount[row]; l++) {
        expect(s.elemUnit[s.elemBase[row] + l], -1, reason: '$t lane $l');
      }
    }
  });

  test('nextLane refuses what it does not know, and never allocates a thing',
      () {
    final s = w.sites;
    final row = w.rowOf(lotOf(SyntheticTemplate.strip));
    expect(s.nextLane(-1, 0, 0), -1);
    expect(s.nextLane(row, -1, 0), -1);
    expect(s.nextLane(row, 0, -1), -1);
    expect(s.nextLane(row, s.laneCount[row], 0), -1);
    expect(s.nextLane(row, 0, s.targetCount[row]), -1);
    expect(s.stallTarget(row, s.stallCount[row]), -1);
    expect(s.stallTarget(row, 0), 0);
    expect(s.joinTarget(row, 0), s.stallCount[row],
        reason: 'the out-joins follow the stalls');
    expect(s.joinTarget(row, 1), -1, reason: 'the strip has one join');
    expect(s.laneOfTarget(row, s.joinTarget(row, 0)),
        w.lanesOf(lotOf(SyntheticTemplate.strip)).outLane(0));
  });
}

/// The joins of [p] a car may leave by, in join order: the hop targets that
/// follow the stalls.
List<int> _outJoins(SiteAccessPlan p, SiteLaneGraph g) => [
      for (var j = 0; j < p.joinCount; j++)
        if (p.joinCanOut(j) && g.outLane(j) >= 0) j,
    ];

/// Every lane a car may be on when it has reached target [t]: a stall's
/// in-direction lanes, or an out-join's out-lane.
List<int> _terminals(
    SiteAccessPlan p, SiteLaneGraph g, List<int> outs, int t) {
  if (t >= p.stallCount) return [g.outLane(outs[t - p.stallCount])];
  final k = p.stallSeg(t);
  final dirs = p.stallInDirs(t);
  final ends = <int>[];
  if (dirs & kSiteDirFwd != 0 && g.present[2 * k] == 1) ends.add(2 * k);
  if (dirs & kSiteDirBwd != 0 && g.present[2 * k + 1] == 1) ends.add(2 * k + 1);
  if (ends.isEmpty) {
    if (g.present[2 * k] == 1) ends.add(2 * k);
    if (g.present[2 * k + 1] == 1) ends.add(2 * k + 1);
  }
  return ends;
}

/// Whether a car on [a] may take a link to [b] that is not the public road.
bool _linked(SiteLaneGraph g, int a, int b) {
  for (var i = g.linkStart[a]; i < g.linkStart[a + 1]; i++) {
    if (g.linkKind[i] != kSiteLinkRoad && g.linkTo[i] == b) return true;
  }
  return false;
}

/// How many links each lane is from [ends], −1 for a lane that cannot get
/// there: relaxed to a fixed point over the plan's links, road links left
/// out. Deliberately not the table's algorithm.
List<int> _stepsTo(SiteLaneGraph g, List<int> ends) {
  final d = List<int>.filled(g.laneCount, -1);
  for (final l in ends) {
    if (g.present[l] == 1) d[l] = 0;
  }
  for (var pass = 0; pass <= g.laneCount; pass++) {
    var moved = false;
    for (var a = 0; a < g.laneCount; a++) {
      if (g.present[a] == 0) continue;
      for (var i = g.linkStart[a]; i < g.linkStart[a + 1]; i++) {
        if (g.linkKind[i] == kSiteLinkRoad) continue;
        final b = g.linkTo[i];
        if (g.present[b] == 0 || d[b] < 0) continue;
        if (d[a] < 0 || d[a] > d[b] + 1) {
          d[a] = d[b] + 1;
          moved = true;
        }
      }
    }
    if (!moved) break;
  }
  return d;
}

/// How far a car coming in on [from] drives to reach each stall of [p],
/// `infinity` where it cannot: the same relaxation, over lane lengths.
List<double> _reach(SiteAccessPlan p, SiteLaneGraph g, int from) {
  final c = List<double>.filled(g.laneCount, double.infinity);
  c[from] = 0;
  for (var pass = 0; pass <= g.laneCount; pass++) {
    var moved = false;
    for (var a = 0; a < g.laneCount; a++) {
      if (!c[a].isFinite) continue;
      final len = p.segLenM(SiteLaneGraph.segOf(a));
      for (var i = g.linkStart[a]; i < g.linkStart[a + 1]; i++) {
        if (g.linkKind[i] == kSiteLinkRoad) continue;
        final b = g.linkTo[i];
        if (g.present[b] == 0) continue;
        if (c[a] + len < c[b]) {
          c[b] = c[a] + len;
          moved = true;
        }
      }
    }
    if (!moved) break;
  }
  return [
    for (var i = 0; i < p.stallCount; i++) _stallReach(p, g, c, i),
  ];
}

double _stallReach(
    SiteAccessPlan p, SiteLaneGraph g, List<double> c, int i) {
  final k = p.stallSeg(i);
  final dirs = p.stallInDirs(i);
  var best = double.infinity;
  if (dirs & kSiteDirFwd != 0 && g.present[2 * k] == 1) {
    final v = c[2 * k] + p.stallS(i);
    if (v < best) best = v;
  }
  if (dirs & kSiteDirBwd != 0 && g.present[2 * k + 1] == 1) {
    final v = c[2 * k + 1] + (p.segLenM(k) - p.stallS(i));
    if (v < best) best = v;
  }
  return best;
}

/// [row]'s stall order for [join], as a plain list.
List<int> _orderOf(SiteTable s, int row, int join, int n) {
  final at = s.orderBase[row] + join * s.stallCount[row];
  return [for (var i = 0; i < n; i++) s.stallOrder[at + i]];
}
