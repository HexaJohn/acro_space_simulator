// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A5: forward-out departures (docs/plans/site-access.md §7.4 Departure,
/// §7.9 A5).
///
/// Car parks, yards and installations leave FORWARD through their throats —
/// homes are A9's back-out and are not here. The rules this pins are the
/// ones a car park can get wrong:
///
/// - the route is planned first, and the car reverses out of its stall along
///   the very curve it came in by, which starts and ends on the stall pose
///   to well inside §7.4's 0.05 m and 2°;
/// - the stall is released when the car is out of it, not when it reaches
///   the road, so the space is another car's while this one is still inside
///   the site;
/// - the front NEVER passes the kerb line less `throatStopM` before the EXIT
///   is logged: a car waiting for its gap does not stick its nose out;
/// - the EXIT comes on a `canJoin` gap and on nothing else, under a stream
///   down the kerb lane;
/// - and the wait for that gap is BOUNDED (agent-traffic.md §5.6). `canJoin`
///   has no impatient term to waive a body with, and the road mover's
///   despawn cannot reach a car whose element is −1, so a street that never
///   opens would otherwise hold the car for ever: after `throatStuckAfterS`
///   of grace and `stuckDespawnS` of stuck time the departure is given up,
///   counted, and the car goes back on a stall with its owner's leg asked
///   for again — without ever crossing the kerb.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_manoeuvre.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'movement_fixture.dart';
import 'site_drive_fixture.dart';

void main() {
  tearDown(AgentTuning.reset);

  group('A5: a forward-out departure', () {
    test('reverses out, holds its nose inside the kerb, and leaves on a gap',
        () {
      final lot = starterLotOf(SyntheticTemplate.strip);
      final d = SiteDrive({lot: SyntheticTemplate.strip});
      final e = servingEdges(d, lot);
      const stall = 5;
      d.park(lot, stall);
      expect(d.taken(lot, stall), isTrue);

      final h = d.departure(lot, stall: stall, edge: e.near);
      expect(h, isNot(SlotPool.none));
      final sl = SlotPool.slotOf(h);
      final row = d.rowOf(lot);
      final g = d.world.lanesOf(lot);
      final outLane = g.outLane(0);
      final throatLen =
          d.world.sites.elemLen[d.world.sites.elemBase[row] + outLane];
      expect(d.cols.phase[sl], SitePhase.stallOut.index);
      expect(d.cols.manU[sl], 1.0, reason: 'it starts ON its stall');

      // Where the stall was let go, and what the car was doing then.
      var releasedInPhase = -1;
      var sawThroatWait = false;
      var waitedRefused = 0;
      var exitStep = -1;
      var canJoinAtExit = false;
      // Asked where the mover asks it: after the road has moved, before the
      // site mover decides.
      var joinable = false;
      d.probe = () {
        joinable = d.table.isLive(h) &&
            d.cols.phase[sl] == SitePhase.throatWait.index &&
            _canJoin(d, h, lot, e.near);
        if (d.cols.phase[sl] == SitePhase.throatWait.index) {
          sawThroatWait = true;
          if (!joinable) waitedRefused++;
        }
        // Nothing of the car is on the road, and its nose is inside the kerb
        // line, until the EXIT is logged.
        if (d.cols.phase[sl] > 0) {
          expect(d.table.elem[sl], -1, reason: 'still off the road');
          if (d.cols.lane[sl] == outLane) {
            expect(d.table.s[sl],
                lessThanOrEqualTo(throatLen - AgentTuning.throatStopM + 1e-3),
                reason: 'the front stayed inside kerb − throatStopM');
          }
        }
        if (releasedInPhase < 0 && !d.taken(lot, stall)) {
          releasedInPhase = d.cols.phase[sl];
        }
      };

      for (var i = 0; i < 600 && exitStep < 0; i++) {
        // A stream down the kerb lane for the first minute (A5).
        if (d.nowUs < 60000000) d.stream(e.near, everyS: 2);
        d.step();
        expect(occupancyErrors(d.table), isEmpty);
        expect(siteOccupancyErrors(d), isEmpty);
        if (d.of(AccessEventKind.exit).isNotEmpty) {
          exitStep = i;
          canJoinAtExit = joinable;
        }
      }
      d.probe = null;

      expect(exitStep, greaterThan(0), reason: 'it does get out');
      expect(sawThroatWait, isTrue, reason: 'it waited at the throat');
      expect(canJoinAtExit, isTrue, reason: 'the EXIT came on a canJoin gap');
      expect(waitedRefused, greaterThan(0),
          reason: 'the stream refused it at least once');
      expect(releasedInPhase, SitePhase.stallOut.index,
          reason: 'the stall went as the car cleared its mouth, not later');
      expect(d.taken(lot, stall), isFalse);

      final exits = d.of(AccessEventKind.exit);
      expect(exits, hasLength(1));
      expect(exits.first.t, closeTo(d.access(lot).sOn(d.lg, e.near), 1.5));
      expect(exits.first.row, row);
      expect(exits.first.join, 0);
      expect(d.leftSite, [h]);
      expect(d.table.elem[sl], exits.first.lane);
      expect(d.table.state[sl], VehicleState.driving.index);
      expect(d.stats.exits, 1);
      expect(claimErrors(d), isEmpty);
    });

    test('a yard lets its truck out the same way', () {
      final lot = starterLotOf(SyntheticTemplate.yard);
      final d = SiteDrive({lot: SyntheticTemplate.yard});
      final e = servingEdges(d, lot);
      const stall = 0;
      d.park(lot, stall);
      final h = d.departure(lot,
          stall: stall, edge: e.near, kind: AgentKind.truck);
      expect(h, isNot(SlotPool.none));
      d.run(180, () {
        expect(occupancyErrors(d.table), isEmpty);
        expect(siteOccupancyErrors(d), isEmpty);
      });
      expect(d.of(AccessEventKind.exit), hasLength(1));
      expect(d.taken(lot, stall), isFalse);
    });
  });

  group('A5: a gap that never comes (§5.6)', () {
    test('the departure is given up, counted, and nothing crosses the kerb',
        () {
      final lot = starterLotOf(SyntheticTemplate.strip);
      final d = SiteDrive({lot: SyntheticTemplate.strip});
      final e = servingEdges(d, lot);
      final row = d.rowOf(lot);
      const stall = 5;
      d.park(lot, stall);
      // A body standing squarely across the join, and never moving again:
      // `canJoin` has no impatient term to waive a body with, so the gap
      // this car is waiting for never comes.
      final blocker = d.obstruct(e.near, d.access(lot).sOn(d.lg, e.near));
      expect(blocker, isNot(SlotPool.none));
      final out = d.departure(lot, stall: stall, edge: e.near);
      expect(out, isNot(SlotPool.none));
      final sl = SlotPool.slotOf(out);

      // Twice the bound, so a rule that never fired would be plain.
      final (waitedFromS, endedAtS) = _runToResolution(d, out, sl, 3000);
      expect(waitedFromS, greaterThan(0), reason: 'it reached the throat');
      expect(endedAtS - waitedFromS, closeTo(_boundS, 1),
          reason: 'bounded from the moment it started waiting');
      expect(d.table.isLive(out), isFalse, reason: 'it gave the departure up');
      expect(d.stats.throatGiveUps, 1, reason: 'and it is counted');
      expect(d.of(AccessEventKind.exit), isEmpty,
          reason: 'no EXIT with a body across the join — not once');
      expect(d.leftSite, isEmpty, reason: 'the road never saw it');

      // Back on a stall of its own site, its leg handed to its owner to plan
      // again, and nothing of the car left inside the site.
      final back = d.parked[out];
      expect(back, isNotNull);
      expect(back, isNot(-1),
          reason: 'a stall, not a garage: this lot has 23 free');
      expect(d.taken(lot, back!), isTrue);
      expect(d.replanned, hasLength(1));
      expect(d.world.sites.inside[row], 0);
      expect(occupancyErrors(d.table), isEmpty);
      expect(siteOccupancyErrors(d), isEmpty);
      expect(claimErrors(d), isEmpty);
    });

    test('every forward-out program is bounded, not just the car park', () {
      for (final tpl in const [
        SyntheticTemplate.strip,
        SyntheticTemplate.loop,
        SyntheticTemplate.yard,
        SyntheticTemplate.utility,
      ]) {
        final lot = starterLotOf(tpl);
        final d = SiteDrive({lot: tpl});
        final j = _outJoin(d, lot);
        expect(j, isNot(-1), reason: '$tpl has a join to leave by');
        final e = servingEdges(d, lot, j);
        expect(e.near, isNot(-1), reason: '$tpl join $j is served');
        d.park(lot, 0);
        expect(d.obstruct(e.near, d.access(lot, j).sOn(d.lg, e.near)),
            isNot(SlotPool.none),
            reason: '$tpl: the street can be blocked');
        final out = d.departure(lot, j: j, stall: 0, edge: e.near);
        expect(out, isNot(SlotPool.none), reason: '$tpl departs');

        final (waitedFromS, endedAtS) =
            _runToResolution(d, out, SlotPool.slotOf(out), 3000);
        expect(waitedFromS, greaterThan(0), reason: '$tpl reached its throat');
        expect(endedAtS - waitedFromS, closeTo(_boundS, 1), reason: '$tpl');
        expect(d.stats.throatGiveUps, 1, reason: '$tpl counts it');
        expect(d.of(AccessEventKind.exit), isEmpty,
            reason: '$tpl crossed no kerb');
        expect(d.parked[out], isNotNull, reason: '$tpl is back on a stall');
        expect(siteOccupancyErrors(d), isEmpty, reason: '$tpl');
        expect(claimErrors(d), isEmpty, reason: '$tpl');
      }
    });

    test('a stream jammed across the join is bounded the same way', () {
      final lot = starterLotOf(SyntheticTemplate.strip);
      final d = SiteDrive({lot: SyntheticTemplate.strip});
      final e = servingEdges(d, lot);
      final t = d.access(lot).sOn(d.lg, e.near);
      final lane = d.lg.laneOf(e.near, 0);
      // The wedge a city actually makes: something stopped 30 m past the
      // join, and a car a second down the kerb lane behind it. A moving
      // stream always dilates into gaps a car can leave on; a stream that
      // has stopped is a wall of bodies, and `canJoin` refuses a body for
      // as long as it stands there.
      d.obstruct(e.near, t + 30);
      d.run(40, () => d.stream(e.near, everyS: 1, speed: 8));
      final at = t - d.lg.edgeLaneS0[e.near];
      expect(bodiesIn(d, lane, at - 2, at + 2), isNotEmpty,
          reason: 'the queue is standing across the join');

      const stall = 4;
      d.park(lot, stall);
      final out = d.departure(lot, stall: stall, edge: e.near);
      expect(out, isNot(SlotPool.none));
      final sl = SlotPool.slotOf(out);
      final (waitedFromS, endedAtS) = _runToResolution(d, out, sl, 3000,
          each: () => d.stream(e.near, everyS: 1, speed: 8));

      expect(waitedFromS, greaterThan(0), reason: 'it reached the throat');
      expect(endedAtS - waitedFromS, closeTo(_boundS, 1),
          reason: 'bounded from the moment it started waiting');
      expect(d.table.isLive(out), isFalse);
      expect(d.stats.throatGiveUps, 1);
      expect(d.of(AccessEventKind.exit), isEmpty,
          reason: 'it never pulled out into the queue');
      expect(d.parked[out], isNotNull, reason: 'back on a stall');
      expect(occupancyErrors(d.table), isEmpty);
      expect(siteOccupancyErrors(d), isEmpty);
      expect(claimErrors(d), isEmpty);
    });
  });

  group('the stall pose, in and out', () {
    test('a car lands on its stall within 0.05 m and 2°, and leaves from it',
        () {
      final lot = starterLotOf(SyntheticTemplate.strip);
      final d = SiteDrive({lot: SyntheticTemplate.strip});
      final e = servingEdges(d, lot);
      final p = d.planOf(lot);
      final pose = Float64List(4);

      // In: the manoeuvre runs to u = 1 and is gone in the same sub-step, so
      // what is watched is the last u it was seen at.
      final h = d.arrival(lot, edge: e.near, backM: 120);
      final sl = SlotPool.slotOf(h);
      var lastU = -1.0;
      var lastStall = -1, lastLane = -1;
      d.probe = () {
        if (!d.table.isLive(h)) return;
        if (d.cols.phase[sl] != SitePhase.stallIn.index) return;
        lastU = d.cols.manU[sl].toDouble();
        lastStall = d.cols.claim[sl];
        lastLane = d.cols.lane[sl];
      };
      d.run(100);
      d.probe = null;
      expect(lastStall, isNot(-1), reason: 'it ran a stall manoeuvre');
      final parkedStall = d.parked[h]!;
      expect(lastStall, parkedStall);
      // One sub-step's worth of curve from the end, and the end itself is
      // the stall to well inside 0.05 m and 2°.
      final dirIn = _dirOf(d, lot, parkedStall);
      final du = kStallManoeuvreMps *
          0.2 /
          SiteManoeuvre.stallCurveM(p, parkedStall, dirIn);
      expect(1 - lastU, lessThanOrEqualTo(du + 1e-6));
      _expectOnStall(p, lastStall, lastLane, 1, pose, 0.05, 2);
      // Out: the first pose of the departure's is the stall pose again.
      final out = d.departure(lot, stall: parkedStall, edge: e.near);
      final os = SlotPool.slotOf(out);
      expect(d.cols.manU[os], 1.0);
      _expectOnStall(p, d.cols.claim[os], d.cols.lane[os],
          d.cols.manU[os].toDouble(), pose, 0.05, 2);
    });
  });
}

/// What a throat wait may run to, in agent seconds: the minute of grace
/// §7.4 step 6 gives a car queueing for its gap, and then the stuck time
/// §5.6 gives any vehicle that is going nowhere.
double get _boundS =>
    AgentTuning.throatStuckAfterS + AgentTuning.stuckDespawnS;

/// The first join of [lot] a car may leave by: the loop leaves by its second
/// one, on the side street.
int _outJoin(SiteDrive d, String lot) {
  final row = d.rowOf(lot);
  final p = d.planOf(lot);
  for (var j = 0; j < p.joinCount; j++) {
    if (d.world.sites.joinTarget(row, j) >= 0) return j;
  }
  return -1;
}

/// Runs [d] until departing vehicle [out] is resolved — out on the road, or
/// given up and off the table — or [steps] sub-steps have passed, calling
/// [each] before every one. Returns the agent seconds at which it started
/// waiting at its throat and at which it was resolved, each −1 if it never
/// was.
(double, double) _runToResolution(SiteDrive d, int out, int sl, int steps,
    {void Function()? each}) {
  var waitedFromS = -1.0, endedAtS = -1.0;
  for (var i = 0; i < steps && endedAtS < 0; i++) {
    each?.call();
    d.step();
    if (!d.table.isLive(out)) {
      endedAtS = secondsOf(d.nowUs);
      break;
    }
    if (d.table.elem[sl] >= 0) {
      endedAtS = secondsOf(d.nowUs);
      break;
    }
    if (waitedFromS < 0 && d.cols.phase[sl] == SitePhase.throatWait.index) {
      waitedFromS = secondsOf(d.nowUs);
    }
  }
  return (waitedFromS, endedAtS);
}

/// The pose of [stall]'s manoeuvre at [u] is the stall's, within [m] metres
/// and [deg] degrees (§7.4 step 5).
void _expectOnStall(SiteAccessPlan p, int stall, int lane, double u,
    Float64List pose, double m, double deg) {
  final dir = SiteLaneGraph.isForward(lane) ? kSiteDirFwd : kSiteDirBwd;
  SiteManoeuvre.stallPose(p, stall, dir, u, pose, 0);
  expect(pose[0], closeTo(p.stallE(stall), m));
  expect(pose[1], closeTo(p.stallN(stall), m));
  final dot = pose[2] * p.stallDirE(stall) + pose[3] * p.stallDirN(stall);
  // cos 2° = 0.99939; a dot at least that is an angle at most 2°.
  expect(dot, greaterThan(0.9993), reason: 'within $deg° of the stall');
}

/// The direction bit a car enters [stall] of [lot] by.
int _dirOf(SiteDrive d, String lot, int stall) {
  final row = d.rowOf(lot);
  final lane =
      d.world.sites.laneOfTarget(row, d.world.sites.stallTarget(row, stall));
  return SiteLaneGraph.isForward(lane) ? kSiteDirFwd : kSiteDirBwd;
}

/// Whether the arbiter would let [handle] out of [lot]'s throat onto [edge]
/// now: the same question the mover asks, asked from outside it.
bool _canJoin(SiteDrive d, int handle, String lot, int edge) {
  final sl = SlotPool.slotOf(handle);
  final t = d.table;
  if (!t.isLive(handle) || t.routeLen[sl] <= 0) return false;
  final lane = t.arena.data[t.routeOff[sl]];
  final a = d.access(lot);
  final at = a.sOn(d.lg, edge) - d.lg.edgeLaneS0[edge];
  return d.arbiter.canJoin(lane, at, t.len[sl].toDouble(),
      AgentKind.values[t.kind[sl]],
      fromLeft: !a.rightOfTravel(d.lg, edge));
}
