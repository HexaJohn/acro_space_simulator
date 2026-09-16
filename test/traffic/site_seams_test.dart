// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The P0 seams the four T4a packages are written against
/// (docs/plans/t4a-implementation.md §1.4, §1.5, §1.8): the site columns,
/// the access event log and the site counters.
///
/// What is pinned here is what everyone else builds on: the columns grow
/// with the vehicle table and keep what they held, a cleared row says
/// nothing, a digest folds every column (so a twin run that differs
/// anywhere diverges), and the event log empties every sub-step while its
/// totals never go back.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_stats.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';

void main() {
  group('SiteVehicles', () {
    test('a fresh table, and a cleared row, say nothing', () {
      final c = SiteVehicles(4);
      for (var sl = 0; sl < 4; sl++) {
        expect(c.phase[sl], SitePhase.none.index);
        expect(c.row[sl], -1);
        expect(c.lane[sl], -1);
        expect(c.target[sl], -1);
        expect(c.join[sl], -1);
        expect(c.sPrev[sl], -1);
        expect(c.sNext[sl], -1);
        expect(c.owner[sl], -1);
        expect(c.claim[sl], -1);
        expect(c.waitMs[sl], 0);
        expect(c.manU[sl], 0);
      }
      c
        ..row[2] = 3
        ..lane[2] = 5
        ..phase[2] = SitePhase.inbound.index
        ..manU[2] = 0.5
        ..waitMs[2] = 17;
      c.clear(2);
      expect(c.row[2], -1);
      expect(c.lane[2], -1);
      expect(c.phase[2], SitePhase.none.index);
      expect(c.manU[2], 0);
      expect(c.waitMs[2], 0);
    });

    test('ensure grows without losing a row, and asks for nothing twice', () {
      final c = SiteVehicles(2);
      final was = c.row;
      c
        ..row[1] = 4
        ..phase[1] = SitePhase.stallIn.index
        ..manU[1] = 0.25;
      c.ensure(2);
      expect(identical(c.row, was), isTrue, reason: 'no room needed, no work');
      c.ensure(5);
      expect(c.capacity, 5);
      expect(c.row[1], 4);
      expect(c.phase[1], SitePhase.stallIn.index);
      expect(c.manU[1], 0.25);
      expect(c.row[4], -1, reason: 'the new rows are clear');
      expect(c.phase[4], SitePhase.none.index);
    });

    test('the digest folds every column of a vehicle with site business',
        () {
      final d = Drive(straightRoad());
      final t = d.table;
      final lane = d.lg.laneOf(0, 0);
      final h = t.spawn(
        kind: AgentKind.car,
        route: Int32List.fromList([lane]),
        routeLength: 1,
        originT: d.lg.edgeLaneS0[0] + 50,
        destT: d.lg.edgeLaneS1[0],
        nowUs: 0,
      );
      final sl = SlotPool.slotOf(h);
      final c = SiteVehicles(t.capacity);
      final quiet = c.digest(kFnvOffset32, t);
      expect(quiet, kFnvOffset32,
          reason: 'no site business folds nothing: the old digests stand');

      c
        ..phase[sl] = SitePhase.inbound.index
        ..row[sl] = 2
        ..lane[sl] = 3;
      final busy = c.digest(kFnvOffset32, t);
      expect(busy, isNot(quiet));

      for (final turn in <void Function()>[
        () => c.lane[sl] = 4,
        () => c.target[sl] = 1,
        () => c.join[sl] = 1,
        () => c.sPrev[sl] = 0,
        () => c.sNext[sl] = 0,
        () => c.owner[sl] = 9,
        () => c.ownerKind[sl] = 2,
        () => c.waitMs[sl] = 200000,
        () => c.claim[sl] = 3,
        () => c.manU[sl] = 0.125,
        () => c.phase[sl] = SitePhase.stallIn.index,
      ]) {
        final before = c.digest(kFnvOffset32, t);
        turn();
        expect(c.digest(kFnvOffset32, t), isNot(before),
            reason: 'every column must be folded');
      }

      // Cleared, it folds nothing again: a slot handed back to the road.
      c.clear(sl);
      expect(c.digest(kFnvOffset32, t), quiet);
    });
  });

  group('AccessEventLog', () {
    test('a sub-step empties the log; the totals never go back', () {
      final log = AccessEventLog(capacity: 4);
      log.beginStep();
      log.log(AccessEventKind.enter, 11, 2, 40.5, 3, 1, 0);
      log.log(AccessEventKind.exit, 12, 2, 41.0, 3, 1, 0);
      expect(log.count, 2);
      expect(log.enters, 1);
      expect(log.exits, 1);
      expect(log.handle[0], 11);
      expect(log.kind[0], AccessEventKind.enter.index);
      expect(log.edge[1], 2);
      expect(log.t[1], 41.0);
      expect(log.lane[1], 3);
      expect(log.row[1], 1);
      expect(log.join[1], 0);

      log.beginStep();
      expect(log.count, 0);
      expect(log.enters, 1, reason: 'a total is the colony\'s, not a step\'s');
      log.log(AccessEventKind.backOutExit, 13, 5, 9.25, 1, 2, 1);
      expect(log.count, 1);
      expect(log.exits, 2, reason: 'a back-out EXIT is an EXIT');
      expect(log.dropped, 0);
    });

    test('a full log drops rather than throws, and says how many', () {
      final log = AccessEventLog(capacity: 2);
      log.beginStep();
      for (var i = 0; i < 4; i++) {
        log.log(AccessEventKind.enter, i, 0, 0, 0, 0, 0);
      }
      expect(log.count, 2);
      expect(log.dropped, 2);
      expect(log.enters, 4);
    });

    test('ensure keeps this step\'s events and grows with the table', () {
      final log = AccessEventLog(capacity: 2);
      log.beginStep();
      log.log(AccessEventKind.enter, 11, 2, 40.5, 3, 1, 0);
      log.ensure(2);
      expect(log.capacity, 2, reason: 'no room needed, no work');
      log.ensure(8);
      expect(log.capacity, 8);
      expect(log.count, 1);
      expect(log.handle[0], 11);
      expect(log.t[0], 40.5);
    });

    test('the digest follows the events, and the totals', () {
      int digestOf(void Function(AccessEventLog) write) {
        final log = AccessEventLog(capacity: 8);
        log.beginStep();
        write(log);
        return log.digest(kFnvOffset32);
      }

      final base = digestOf((l) => l.log(AccessEventKind.enter, 11, 2, 40.5, 3, 1, 0));
      expect(digestOf((l) => l.log(AccessEventKind.enter, 11, 2, 40.5, 3, 1, 0)),
          base,
          reason: 'one history, one digest');
      expect(digestOf((l) => l.log(AccessEventKind.exit, 11, 2, 40.5, 3, 1, 0)),
          isNot(base));
      expect(
          digestOf((l) => l.log(AccessEventKind.enter, 11, 2, 40.6, 3, 1, 0)),
          isNot(base),
          reason: 'the arc is folded to the millimetre');
      expect(
          digestOf((l) => l.log(AccessEventKind.enter, 11, 2, 40.5, 4, 1, 0)),
          isNot(base));
      expect(digestOf((l) {}), isNot(base));
    });
  });

  test('SiteStats folds every counter', () {
    final s = SiteStats();
    final zero = s.digest(kFnvOffset32);
    for (final turn in <void Function()>[
      () => s.enters++,
      () => s.exits++,
      () => s.gateForced++,
      () => s.gateGiveUps++,
      () => s.gateCrossGiveUps++,
      () => s.parkedLot++,
      () => s.parkedKerb++,
      () => s.garaged++,
      () => s.snaps++,
      () => s.relocates++,
      () => s.siteGarages++,
      () => s.limboRows++,
      () => s.siteRetargets++,
      () => s.backOutForced++,
      () => s.shuffles++,
      () => s.backOutGiveUps++,
      () => s.throatGiveUps++,
    ]) {
      final before = s.digest(kFnvOffset32);
      turn();
      expect(s.digest(kFnvOffset32), isNot(before));
    }
    expect(s.digest(kFnvOffset32), isNot(zero));
  });
}
