// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A6, and the arrival gate it belongs to (docs/plans/site-access.md §7.4
/// steps 2–5, §7.9 A6; agent-traffic.md §5.4).
///
/// The road side's ask 14 is that a far-side left-in — a car turning across
/// the opposing carriageway into a driveway — takes the same opposing gap a
/// left turn at a junction takes. Traffic's answer is that the gap is taken
/// at the ARRIVAL GATE rather than at a connector, because there is no
/// connector: the car is on its destination lane and the turn in is an
/// access event. So this file pins the whole gate:
///
/// - G1, the throat's room, and G1b, the `sharedSingle` claim;
/// - G2, the opposing gap, waived after `gateForcedS` and counted;
/// - G3, the speed;
/// - the give-up after `gateGiveUpS` refused — whatever refused it — which
///   is what sends a car on to D17 step 2. The forced grant waives the ETA
///   half of G2 and never a body across the crossing, so a far-side left-in
///   over a carriageway that never opens is refused for ever, and that is
///   the wait the last group here bounds (agent-traffic.md §7.3 step 1).
library;

import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_drive_fixture.dart';

void main() {
  tearDown(AgentTuning.reset);

  group('the arrival gate', () {
    test('a car turns in, drives the site and parks on stallOrder[j][0]', () {
      final lot = starterLotOf(SyntheticTemplate.strip);
      final d = SiteDrive({lot: SyntheticTemplate.strip});
      final e = servingEdges(d, lot);
      final h = d.arrival(lot, edge: e.near, backM: 120);
      expect(h, isNot(SlotPool.none));
      final row = d.rowOf(lot);
      final first = d.world.sites
          .stallOrder[d.world.sites.orderBase[row] + 0 * d.planOf(lot).stallCount];
      d.run(90, () => expect(siteOccupancyErrors(d), isEmpty));

      final enters = d.of(AccessEventKind.enter);
      expect(enters, hasLength(1), reason: 'exactly one ENTER');
      final a = d.access(lot);
      expect(enters.first.t, closeTo(a.sOn(d.lg, e.near), 1.5),
          reason: 'logged at the join, within the property test\'s 1.5 m');
      expect(enters.first.lane, d.lg.laneOf(e.near, a.destLane(d.lg, e.near)),
          reason: 'it left from its locked destination lane (§5.5 ENTER)');
      expect(enters.first.row, row);
      expect(enters.first.join, 0);
      expect(d.parked[h], first, reason: 'the first stall of the join order');
      expect(d.world.sites.lotUsed[row], 1);
      expect(claimErrors(d), isEmpty);
    });

    test('G3: a car is never granted above gateMaxMps', () {
      final lot = starterLotOf(SyntheticTemplate.strip);
      final d = SiteDrive({lot: SyntheticTemplate.strip});
      final e = servingEdges(d, lot);
      final handles = [
        for (var i = 0; i < 3; i++)
          d.arrival(lot, edge: e.near, backM: 150.0 - 30 * i),
      ];
      expect(handles, everyElement(isNot(SlotPool.none)));
      final speedAtGrant = <int, double>{};
      var enters = 0;
      for (var i = 0; i < 400; i++) {
        final before = <int, double>{
          for (final h in handles)
            if (d.table.isLive(h)) h: d.table.v[SlotPool.slotOf(h)].toDouble(),
        };
        d.step();
        for (var k = enters; k < d.of(AccessEventKind.enter).length; k++) {
          final ev = d.of(AccessEventKind.enter)[k];
          speedAtGrant[ev.handle] = before[ev.handle] ?? -1;
        }
        enters = d.of(AccessEventKind.enter).length;
      }
      expect(enters, 3);
      for (final v in speedAtGrant.values) {
        expect(v, lessThanOrEqualTo(AgentTuning.gateMaxMps));
      }
    });

    test('G1: cars queue for the throat instead of piling into it', () {
      final lot = starterLotOf(SyntheticTemplate.strip);
      final d = SiteDrive({lot: SyntheticTemplate.strip});
      final e = servingEdges(d, lot);
      for (var i = 0; i < 4; i++) {
        d.arrival(lot, edge: e.near, backM: 160.0 - 7 * i);
      }
      d.run(120, () {
        expect(siteOccupancyErrors(d), isEmpty);
        expect(claimErrors(d), isEmpty);
      });
      final enters = d.of(AccessEventKind.enter);
      expect(enters, hasLength(4));
      expect(d.parked, hasLength(4));
      // No two cars took the same stall, and none was granted on the very
      // sub-step the one before it was.
      expect(d.parked.values.toSet(), hasLength(4));
      for (var i = 1; i < enters.length; i++) {
        expect(enters[i].nowUs, greaterThan(enters[i - 1].nowUs));
      }
    });

    test('G1b and the give-up: an outbound car holding the drive sends an '
        'inbound one to the kerb after gateGiveUpS', () {
      // A back-out that crawls: the drive is claimed OUTBOUND for the whole
      // test, so an inbound car is refused on G1b and never on anything that
      // clears by itself.
      AgentTuning.backOutMaxMps = 0.01;
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      d.park(lot, 0);
      final out = d.departure(lot, stall: 0, edge: e.near);
      expect(out, isNot(SlotPool.none));
      d.run(4);
      expect(d.cols.phase[SlotPool.slotOf(out)], SitePhase.backOut.index,
          reason: 'the outbound car has committed');

      // The inbound car comes down the FAR carriageway, which the back-out's
      // footprint does not claim, so it reaches the gate and is refused
      // there and only there.
      final inb = d.arrival(lot, edge: e.far, backM: 90);
      expect(inb, isNot(SlotPool.none));
      d.run(120);
      expect(d.of(AccessEventKind.enter), isEmpty);
      expect(d.gaveUp, [inb]);
      expect(d.stats.gateGiveUps, 1);
      final gave = d.heldSince[inb]!;
      expect(d.world.sites.lotUsed[d.rowOf(lot)], 1,
          reason: 'the reservation went back when the stall did');
      expect(gave, greaterThan(0));
    });
  });

  group('A6: the far-side left-in takes the opposing gap', () {
    test('a stream on the near carriageway holds the turn in, and the grant '
        'at gateForcedS is a counted forced one', () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      expect(e.far, isNot(-1), reason: 'a 1+1 street has both directions');
      final h = d.arrival(lot, edge: e.far, backM: 90);
      expect(h, isNot(SlotPool.none));

      // Every two seconds at 8 m/s: 16 m apart, so the 4 s opposing gap
      // (32 m) never opens.
      final clearAtGrant = <bool>[];
      var seen = 0;
      for (var i = 0; i < 500; i++) {
        final sl = SlotPool.slotOf(h);
        final onRoad = d.table.isLive(h) && d.table.elem[sl] >= 0;
        final clear = onRoad &&
            d.arbiter.opposingClear(d.table.elem[sl],
                d.table.destLaneS(sl), d.table.len[sl].toDouble());
        d.stream(e.near, everyS: 2);
        d.step();
        final enters = d.of(AccessEventKind.enter);
        if (enters.length > seen) {
          seen = enters.length;
          clearAtGrant.add(clear);
        }
      }
      expect(seen, 1, reason: 'it does get in, eventually');
      expect(clearAtGrant, [false], reason: 'the road was never clear');
      expect(d.stats.gateForced, 1, reason: 'the ETA test was waived, counted');
      final ev = d.of(AccessEventKind.enter).first;
      final waited = secondsOf(ev.nowUs - d.heldSince[ev.handle]!);
      expect(waited, greaterThanOrEqualTo(AgentTuning.gateForcedS),
          reason: 'no forced grant inside 25 s');
    });

    test('with real gaps it turns in on one, and nothing is forced', () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      final h = d.arrival(lot, edge: e.far, backM: 90);
      expect(h, isNot(SlotPool.none));

      var clearAtGrant = false;
      var seen = 0;
      for (var i = 0; i < 400; i++) {
        // A car can be handed to the gate and granted inside one sub-step,
        // so what is sampled is "still on the road", not "already held".
        final sl = SlotPool.slotOf(h);
        final onRoad = d.table.isLive(h) && d.table.elem[sl] >= 0;
        final clear = onRoad &&
            d.arbiter.opposingClear(d.table.elem[sl],
                d.table.destLaneS(sl), d.table.len[sl].toDouble());
        // 12 s apart at 8 m/s: nearly 100 m of gap.
        d.stream(e.near, everyS: 12);
        d.step();
        if (d.of(AccessEventKind.enter).length > seen) {
          seen = d.of(AccessEventKind.enter).length;
          clearAtGrant = clear;
        }
      }
      expect(seen, 1);
      expect(clearAtGrant, isTrue,
          reason: 'granted only while the opposing lanes were clear');
      expect(d.stats.gateForced, 0);
      final ev = d.of(AccessEventKind.enter).first;
      final waited = secondsOf(ev.nowUs - d.heldSince[ev.handle]!);
      expect(waited, lessThan(AgentTuning.gateForcedS));
      expect(d.parked, hasLength(1));
    });
  });

  group('a turn in that can never be taken (§7.3 step 1)', () {
    test('the stall goes back at gateGiveUpS, counted on the crossing, and '
        'the car is still on its lane for D17 step 2', () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      expect(e.far, isNot(-1), reason: 'a 1+1 street has both directions');
      // A body standing squarely across the crossing, and never moving
      // again. The forced grant waives the ETA half of G2 and NEVER a body,
      // so the gap this car wants never comes, at 25 s or at any other time.
      expect(d.obstruct(e.near, d.access(lot).sOn(d.lg, e.near)),
          isNot(SlotPool.none));
      final h = d.arrival(lot, edge: e.far, backM: 90);
      expect(h, isNot(SlotPool.none));
      final row = d.rowOf(lot);

      // Twice the bound, so a rule that never fired would be plain.
      var gaveUpAtUs = -1;
      for (var i = 0; i < (120 / kStepS).round() && gaveUpAtUs < 0; i++) {
        d.step();
        expect(d.world.sites.lotUsed[row], lessThanOrEqualTo(1),
            reason: 'one reservation at a time, and only while it is held');
        if (d.gaveUp.isNotEmpty) gaveUpAtUs = d.nowUs;
      }

      expect(gaveUpAtUs, greaterThanOrEqualTo(0), reason: 'it gave up at all');
      final held = d.heldSince[h];
      expect(held, isNotNull, reason: 'it reached the gate');
      expect(secondsOf(gaveUpAtUs - held!), closeTo(AgentTuning.gateGiveUpS, 0.25),
          reason: 'bounded from the sub-step it was handed over');
      expect(d.gaveUp, [h], reason: 'on to D17 step 2, once');
      expect(d.stats.gateGiveUps, 1);
      expect(d.stats.gateCrossGiveUps, 1,
          reason: 'the crossing was what was still refusing it');

      // The safety half: nothing crossed the kerb, and no forced grant was
      // given, because a body is never waived however long the wait ran.
      expect(d.of(AccessEventKind.enter), isEmpty,
          reason: 'no ENTER across a body — not once');
      expect(d.stats.gateForced, 0);

      // The stall is free for the next car, exactly once, and the car went
      // to step 2 from the lane it was held in, not to §5.6's despawn.
      expect(d.world.sites.lotUsed[row], 0);
      for (var s = 0; s < d.planOf(lot).stallCount; s++) {
        expect(d.taken(lot, s), isFalse, reason: 'stall $s is free again');
      }
      expect(d.gaveUpOn[h], isNotNull);
      expect(d.gaveUpOn[h], greaterThanOrEqualTo(0),
          reason: 'still live, still on its arrival lane');
      expect(d.despawns.values, isNot(contains(DespawnReason.stuck)),
          reason: 'resolved by the gate, not lost to §5.6');
      expect(siteOccupancyErrors(d), isEmpty);
      expect(claimErrors(d), isEmpty);
    });

    test('a crossing that clears before the give-up is still a grant, and '
        'the give-up never pre-empts a real gap', () {
      final lot = starterLotOf(SyntheticTemplate.home);
      final d = SiteDrive({lot: SyntheticTemplate.home});
      final e = servingEdges(d, lot);
      final blocker = d.obstruct(e.near, d.access(lot).sOn(d.lg, e.near));
      expect(blocker, isNot(SlotPool.none));
      final h = d.arrival(lot, edge: e.far, backM: 90);
      expect(h, isNot(SlotPool.none));

      // To the gate first, then held there until the give-up is five seconds
      // away: past the forced grant, which a body does not answer.
      for (var i = 0; i < (60 / kStepS).round() && d.heldSince[h] == null; i++) {
        d.step();
      }
      expect(d.heldSince[h], isNotNull, reason: 'it reached the gate');
      d.run(AgentTuning.gateGiveUpS - 5);
      expect(d.of(AccessEventKind.enter), isEmpty,
          reason: 'the body held it the whole time');
      expect(d.stats.gateForced, 0, reason: 'and no body was ever waived');
      expect(d.gaveUp, isEmpty, reason: 'and the give-up had not come yet');
      d.clear(blocker);
      d.run(10);

      expect(d.gaveUp, isEmpty, reason: 'it got in instead of giving up');
      expect(d.of(AccessEventKind.enter), hasLength(1));
      expect(d.stats.gateGiveUps, 0);
      expect(d.stats.gateCrossGiveUps, 0);
      expect(d.world.sites.lotUsed[d.rowOf(lot)], 1);
    });
  });
}
