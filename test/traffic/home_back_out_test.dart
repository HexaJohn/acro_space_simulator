// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A9: home driveways (docs/plans/site-access.md §7.4 Home back-out, §7.5,
/// §7.9 A9; agent-traffic.md §7.5, D49).
///
/// A home is the one site a car does not drive out of. It parks nose-in and
/// leaves by reversing down the pad and the throat and swinging its tail
/// upstream into the street, which is the only manoeuvre in the design that
/// puts a car into a lane it was never routed onto. Everything that keeps
/// that safe is here:
///
/// - the footprint `[T − 10, T + 2]` on the target lane holds no body when
///   the reverse is granted, and none when the EXIT is logged;
/// - the EXIT lands at `T ± 11 m` in the target lane `L`, and the car is a
///   REVERSING vehicle there until it has shifted;
/// - both directions work — near into the kerb lane, far across it — under a
///   minute of traffic down the street;
/// - the drive is one `sharedSingle` claim unit, never held both ways, and an
///   uncommitted outbound car yields it to an inbound one held at the gate;
/// - a deep tandem car blocked by its neighbour has that neighbour shuffled
///   away after `tandemShuffleS`;
/// - ten minutes of both homes cycling deadlocks nothing.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'movement_fixture.dart';
import 'site_drive_fixture.dart';

/// The two homes, on their own starter lots.
Map<String, SyntheticTemplate> _homes() => {
      starterLotOf(SyntheticTemplate.home): SyntheticTemplate.home,
      starterLotOf(SyntheticTemplate.homeTandem): SyntheticTemplate.homeTandem,
    };

void main() {
  tearDown(AgentTuning.reset);

  group('A9: parking and leaving a home', () {
    test('the stalls are nose-in, forward off the pad', () {
      final d = SiteDrive(_homes());
      for (final t in [SyntheticTemplate.home, SyntheticTemplate.homeTandem]) {
        final lot = starterLotOf(t);
        final p = d.planOf(lot);
        final kn = p.joinKerbNode(0);
        expect(p.stallCount, 2);
        for (var i = 0; i < p.stallCount; i++) {
          // The nose points AWAY from the kerb node: a car drives in forward
          // and leaves in reverse (§7.4 Home back-out).
          final along = (p.stallE(i) - p.nodeE(kn)) * p.stallDirE(i) +
              (p.stallN(i) - p.nodeN(kn)) * p.stallDirN(i);
          expect(along, greaterThan(0), reason: '$lot stall $i faces the lot');
          expect(p.stallInDirs(i) & p.stallOutDirs(i), 0,
              reason: 'in forward, out backward');
        }
      }
    });

    test('a car drives in, parks nose-in, and backs out into the kerb lane',
        () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      final h = d.arrival(lot, edge: e.near, backM: 100);
      expect(h, isNot(SlotPool.none));
      d.run(60);
      expect(d.parked, hasLength(1));
      final stall = d.parked[h]!;

      final out = d.departure(lot, stall: stall, edge: e.near);
      expect(out, isNot(SlotPool.none));
      final sl = SlotPool.slotOf(out);
      expect(d.cols.phase[sl], SitePhase.backOutWait.index,
          reason: 'a home car waits in its stall, never on an aisle');
      d.run(40, () {
        expect(occupancyErrors(d.table), isEmpty);
        expect(claimErrors(d), isEmpty);
      });

      final exits = d.of(AccessEventKind.backOutExit);
      expect(exits, hasLength(1));
      final lane = d.lg.laneOf(e.near, 0);
      expect(exits.first.lane, lane, reason: 'it lands in L');
      expect(exits.first.t, closeTo(d.access(lot).sOn(d.lg, e.near), 11),
          reason: 'the property test allows T ± 11 m for a back-out');
      expect(d.leftSite, [out]);
      expect(d.taken(lot, stall), isFalse);
      expect(d.of(AccessEventKind.exit), isEmpty,
          reason: 'a home never leaves forward through its throat');
    });

    test('it is a REVERSING vehicle in L until it has shifted', () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      d.park(lot, 0);
      final out = d.departure(lot, stall: 0, edge: e.near);
      final sl = SlotPool.slotOf(out);
      final lane = d.lg.laneOf(e.near, 0);
      var reversingS = 0.0;
      var sawShift = false;
      for (var i = 0; i < 300; i++) {
        d.step();
        if (!d.table.isLive(out)) break;
        final flags = d.table.flags[sl];
        if (flags & kReversing != 0) {
          reversingS += 0.2;
          expect(d.table.elem[sl], lane);
          expect(d.table.state[sl], VehicleState.manoeuvre.index);
          expect(d.cols.phase[sl],
              anyOf(SitePhase.backOut.index, SitePhase.shift.index));
        }
        if (d.cols.phase[sl] == SitePhase.shift.index) sawShift = true;
        if (d.cols.phase[sl] == SitePhase.none.index && sawShift) {
          expect(d.table.flags[sl] & kReversing, 0);
          expect(d.table.state[sl], VehicleState.driving.index);
          break;
        }
      }
      expect(sawShift, isTrue, reason: 'the 0.5 s stop to shift happened');
      expect(reversingS, greaterThan(AgentTuning.shiftStopS));
    });

    test('the far direction crosses the near lane and lands in the far one',
        () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      expect(e.far, isNot(-1));
      d.park(lot, 1);
      final out = d.departure(lot, stall: 1, edge: e.far);
      expect(out, isNot(SlotPool.none));
      // The near lane is claimed for the manoeuvre even though the car never
      // occupies it (§7.4 EXIT logging).
      var claimedNear = false;
      final near = d.lg.laneOf(e.near, 0);
      final probe = Float64List(2);
      d.run(40, () {
        if (d.siteMover.count > 0 &&
            d.siteMover.obstacleAhead(near, -1000, probe)) {
          claimedNear = true;
        }
      });
      expect(claimedNear, isTrue, reason: 'the crossing was claimed');
      final exits = d.of(AccessEventKind.backOutExit);
      expect(exits, hasLength(1));
      expect(exits.first.lane, d.lg.laneOf(e.far, 0));
      expect(exits.first.t, closeTo(d.access(lot).sOn(d.lg, e.far), 11));
    });
  });

  group('A9: the gap the reverse needs', () {
    test('a minute of traffic holds the back-out, and no EXIT ever has a body '
        'in its footprint', () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      final lane = d.lg.laneOf(e.near, 0);
      final t = d.access(lot).sOn(d.lg, e.near) - d.lg.edgeLaneS0[e.near];
      final lo = t - AgentTuning.backOutUpM, hi = t + AgentTuning.backOutDownM;
      d.park(lot, 0);
      // The street is already busy when the car wants to leave: a stream
      // built up first, so the very first gap check meets real traffic.
      for (var i = 0; i < 100; i++) {
        d.stream(e.near, everyS: 2);
        d.step();
      }
      final out = d.departure(lot, stall: 0, edge: e.near);
      final sl = SlotPool.slotOf(out);

      var wasWaiting = false;
      var bodiesBefore = <int>[];
      var refusedSteps = 0;
      var grantedWithBody = false;
      var exitWithBody = false;
      d.probe = () {
        wasWaiting = d.table.isLive(out) &&
            d.cols.phase[sl] == SitePhase.backOutWait.index;
        bodiesBefore = bodiesIn(d, lane, lo, hi);
        if (wasWaiting) refusedSteps++;
      };
      var exited = false;
      final streamUntilUs = d.nowUs + usOf(60);
      for (var i = 0; i < 900 && !exited; i++) {
        if (d.nowUs < streamUntilUs) d.stream(e.near, everyS: 2);
        d.step();
        expect(occupancyErrors(d.table), isEmpty);
        if (wasWaiting &&
            d.table.isLive(out) &&
            d.cols.phase[sl] == SitePhase.backOut.index &&
            bodiesBefore.isNotEmpty) {
          grantedWithBody = true;
        }
        if (d.of(AccessEventKind.backOutExit).isNotEmpty && !exited) {
          exited = true;
          if (bodiesBefore.where((h) => h != out).isNotEmpty) {
            exitWithBody = true;
          }
        }
      }
      d.probe = null;
      expect(exited, isTrue, reason: 'it gets out once the stream thins');
      expect(grantedWithBody, isFalse);
      expect(exitWithBody, isFalse);
      expect(refusedSteps, greaterThan(50),
          reason: 'the stream really did hold it up');
      expect(d.stats.backOutForced, 0,
          reason: 'a minute of traffic is well inside backOutForcedS');
    });

    test('an inbound car at the gate keeps the drive; the outbound one waits '
        'in its stall until it has parked', () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      d.park(lot, 0);
      final inb = d.arrival(lot, edge: e.near, backM: 120);
      expect(inb, isNot(SlotPool.none));
      final inSl = SlotPool.slotOf(inb);

      // The departure is asked for on the very sub-step the inbound car is
      // held at the gate — the moment §7.4's deadlock rule is about — so an
      // outbound car that did not yield would commit on the spot.
      var out = SlotPool.none;
      var heldNow = false;
      var yields = 0;
      d.probe = () {
        heldNow = d.table.isLive(inb) &&
            d.cols.phase[inSl] == SitePhase.gateHeld.index;
        if (heldNow && out == SlotPool.none) {
          out = d.departure(lot, stall: 0, edge: e.near);
        }
      };
      var parkedUs = -1, committedUs = -1;
      for (var i = 0; i < 900; i++) {
        d.step();
        expect(claimErrors(d), isEmpty);
        if (out == SlotPool.none) continue;
        final outSl = SlotPool.slotOf(out);
        final live = d.table.isLive(out);
        final phase = live ? d.cols.phase[outSl] : SitePhase.none.index;
        if (heldNow) {
          expect(phase, SitePhase.backOutWait.index,
              reason: 'the uncommitted outbound car yielded (§7.4 deadlock)');
          yields++;
        }
        if (parkedUs < 0 && d.parked.isNotEmpty) parkedUs = d.nowUs;
        if (committedUs < 0 &&
            live &&
            phase != SitePhase.backOutWait.index &&
            phase != SitePhase.none.index) {
          committedUs = d.nowUs;
        }
        if (d.of(AccessEventKind.backOutExit).isNotEmpty) break;
      }
      d.probe = null;
      expect(out, isNot(SlotPool.none));
      expect(yields, greaterThan(0), reason: 'the conflict really happened');
      expect(d.of(AccessEventKind.enter), hasLength(1),
          reason: 'the inbound car got in');
      expect(parkedUs, greaterThan(0), reason: 'and parked');
      expect(committedUs, greaterThan(parkedUs),
          reason: 'the outbound car waited until the drive was its own');
      expect(d.of(AccessEventKind.backOutExit), hasLength(1),
          reason: 'and then it left');
    });
  });

  group('A9: tandem stalls', () {
    test('a deep car blocked by its neighbour has it shuffled away', () {
      AgentTuning.tandemShuffleS = 5;
      final lot = starterLotOf(SyntheticTemplate.homeTandem);
      final d = SiteDrive({lot: SyntheticTemplate.homeTandem});
      final e = servingEdges(d, lot);
      final p = d.planOf(lot);
      // Stall 0 is the outer one, at the street end of the pad; stall 1 is
      // the deep one behind it.
      expect(p.stallS(0), lessThan(p.stallS(1)));
      d.park(lot, 0);
      d.park(lot, 1);
      final out = d.departure(lot, stall: 1, edge: e.near);
      final sl = SlotPool.slotOf(out);
      // Nothing happens while the blocker stands there.
      d.run(4);
      expect(d.cols.phase[sl], SitePhase.backOutWait.index);
      expect(d.shuffled, isEmpty);
      d.run(120);
      expect(d.shuffled, [(d.rowOf(lot), 0)]);
      expect(d.stats.shuffles, 1);
      expect(d.of(AccessEventKind.backOutExit), hasLength(1));
      expect(d.taken(lot, 1), isFalse);
    });

    test('an arriving car takes the deepest free stall', () {
      final lot = starterLotOf(SyntheticTemplate.homeTandem);
      final d = SiteDrive({lot: SyntheticTemplate.homeTandem});
      final e = servingEdges(d, lot);
      final h = d.arrival(lot, edge: e.near, backM: 100);
      d.run(80);
      expect(d.parked[h], 1, reason: 'deepest first (§7.5 tandem)');
    });
  });

  test('A9: ten minutes of both homes cycling, and nothing wedges', () {
    final d = SiteDrive(_homes(), capacity: 256);
    final lots = [
      starterLotOf(SyntheticTemplate.home),
      starterLotOf(SyntheticTemplate.homeTandem),
    ];
    final edges = {for (final l in lots) l: servingEdges(d, l)};
    // Both homes full to start with, so every stall sees both a departure
    // and an arrival.
    for (final l in lots) {
      d.park(l, 0);
      d.park(l, 1);
    }
    var departed = 0, arrivals = 0;
    for (var i = 0; i < 3000; i++) {
      final e = edges[lots[i % 2]]!;
      final lot = lots[i % 2];
      // Traffic down the street, and a car in or out of a home every few
      // seconds — near for one stall, far across the road for the other —
      // which is many times what two houses would really generate.
      d.stream(e.near, everyS: 20);
      if (i % 40 == 0) {
        final row = d.rowOf(lot);
        for (var s = 0; s < 2; s++) {
          if (d.world.sites.stallCar[d.world.sites.stallBase[row] + s] < 0) {
            continue;
          }
          if (d.departure(lot, stall: s, edge: s.isEven ? e.near : e.far) !=
              SlotPool.none) {
            departed++;
          }
          break;
        }
      }
      if (i % 50 == 0 &&
          d.world.sites.firstFreeStall(d.rowOf(lot), 0) >= 0 &&
          d.arrival(lot, edge: e.near, backM: 110) != SlotPool.none) {
        arrivals++;
      }
      d.step();
      expect(occupancyErrors(d.table), isEmpty, reason: 'sub-step $i');
      expect(siteOccupancyErrors(d), isEmpty, reason: 'sub-step $i');
      expect(claimErrors(d), isEmpty, reason: 'sub-step $i');
    }
    expect(secondsOf(d.nowUs), closeTo(600, 1));
    expect(departed, greaterThan(10));
    expect(arrivals, greaterThan(5));
    expect(d.stats.exits, greaterThan(5), reason: 'cars really did get out');
    expect(d.stats.enters, greaterThan(3), reason: 'and really did get in');
    // Nothing is left stuck inside a site at the end of ten minutes but
    // whatever is mid-manoeuvre.
    for (var sl = 0; sl < d.table.highWater; sl++) {
      if (!d.table.isSlotLive(sl)) continue;
      expect(d.table.stuckUs[sl], lessThan(usOf(AgentTuning.stuckDespawnS)),
          reason: 'slot $sl wedged');
    }
  });
}

