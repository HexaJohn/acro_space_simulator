// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';

/// The frame the renderer is handed every sub-step (docs/plans/
/// agent-traffic.md §13.1, §13.2): three column sets written in turn, so a
/// frame handed out is never written under the renderer; a row per slot,
/// so a vehicle keeps its row; and the flags that stop the renderer rolling
/// a car past a line it may not cross.
void main() {
  test('three column sets in turn: a frame handed out is never written '
      'again', () {
    final d = Drive(straightRoad());
    final e = edgeOf(d.lg, 'r0');
    d.trip(e, 20, e, 1500, speed: 5);
    d.trip(e, 200, e, 1800, speed: 5);
    final b = AgentFrameBuilder();
    final f0 = b.publish(d.table, timeUs: d.nowUs);
    final s0 = List<double>.of(f0.s), el0 = List<int>.of(f0.elem);
    d.step();
    final f1 = b.publish(d.table, timeUs: d.nowUs);
    d.step();
    final f2 = b.publish(d.table, timeUs: d.nowUs);
    expect(identical(f0.s, f1.s), isFalse);
    expect(identical(f1.s, f2.s), isFalse);
    expect(identical(f0.s, f2.s), isFalse);
    expect(f0.s, s0, reason: 'two publishes later, frame 0 is untouched');
    expect(f0.elem, el0);
    expect(f1.s[0], greaterThan(f0.s[0]), reason: 'the car moved');
    d.step();
    final f3 = b.publish(d.table, timeUs: d.nowUs);
    expect(identical(f3.s, f0.s), isTrue, reason: 'the fourth reuses the first');
    expect(f3.timeUs, d.nowUs.toDouble());
    expect(b.published, 4);
    expect(identical(b.latest, f3), isTrue);
  });

  test('rows are slots: a vehicle keeps its row, an empty slot is not '
      'drawn', () {
    final d = Drive(straightRoad());
    final e = edgeOf(d.lg, 'r0');
    final h0 = d.trip(e, 20, e, 1500);
    final h1 = d.trip(e, 300, e, 1600);
    final h2 = d.trip(e, 600, e, 1700);
    d.mover.despawn(h1, DespawnReason.edit);
    final f = AgentFrameBuilder().publish(d.table, timeUs: 0, graphRev: 7);
    expect(f.count, 3);
    expect(f.graphRev, 7);
    expect(f.handle[SlotPool.slotOf(h0)], h0);
    expect(f.handle[SlotPool.slotOf(h2)], h2);
    expect(f.handle[SlotPool.slotOf(h1)], -1);
    expect(f.elem[SlotPool.slotOf(h1)], -1);
    final s0 = SlotPool.slotOf(h0);
    expect(f.elem[s0], d.table.elem[s0]);
    expect(f.next[s0], d.table.nextElemOf(s0));
    expect(f.kind[s0], d.table.kind[s0]);
    expect(f.lat[s0], 0);
  });

  test('flags: brake lights on a hard stop; "stopping" on a car that may not '
      'go on', () {
    final d = Drive(straightRoad());
    final e = edgeOf(d.lg, 'r0');
    final h0 = d.trip(e, 20, e, 1500, speed: 10);
    final h1 = d.trip(e, 400, e, 1600, speed: 10);
    final s0 = SlotPool.slotOf(h0), s1 = SlotPool.slotOf(h1);
    d.table.a[s0] = -2;
    d.table.stall(h1);
    final f = AgentFrameBuilder().publish(d.table, timeUs: 0);
    expect(f.flags[s0] & kFrameBraking, kFrameBraking);
    expect(f.flags[s0] & kFrameStopping, 0);
    expect(f.flags[s1] & kFrameStopping, kFrameStopping);
    expect(f.flags[s1] & kFrameBraking, 0);
    expect(AgentFrame.empty.count, 0);
  });

  test('the site columns: a book slot and a plan lane, −1 on the road', () {
    final d = Drive(straightRoad());
    final e = edgeOf(d.lg, 'r0');
    final onRoad = d.trip(e, 20, e, 1500, speed: 5);
    final inLot = d.trip(e, 400, e, 1600, speed: 5);
    final s0 = SlotPool.slotOf(onRoad), s1 = SlotPool.slotOf(inLot);

    // Site rows of the test's own: the publish reads the book slot out of
    // them, which is the wire ordinal settled with the road side (§0 Q4).
    final sites = SiteTable(capacity: 8);
    sites.bookSlot[3] = 41;
    final cols = SiteVehicles(d.table.capacity)
      ..row[s1] = 3
      ..lane[s1] = 6
      ..phase[s1] = SitePhase.inbound.index;

    final f = AgentFrameBuilder()
        .publish(d.table, timeUs: 0, site: cols, siteRows: sites, sitesRev: 9);
    expect(f.sitesRev, 9);
    expect(f.siteOrd[s1], 41);
    expect(f.siteLane[s1], 6);
    expect(f.siteOrd[s0], -1, reason: 'a car on the road is on no site');
    expect(f.siteLane[s0], -1);

    // A car held at the gate, or bound for a kerb slot, is still on the
    // street: the road geometry places it, as it always did.
    cols.phase[s1] = SitePhase.gateHeld.index;
    final held = AgentFrameBuilder()
        .publish(d.table, timeUs: 0, site: cols, siteRows: sites, sitesRev: 9);
    expect(held.siteOrd[s1], -1);
    expect(held.siteLane[s1], -1);

    // Columns a caller built for itself carry no site business at all.
    expect(AgentFrame.empty.sitesRev, 0);
    final own = AgentFrame.fromColumns(
      count: 2,
      timeUs: 0,
      graphRev: 0,
      handle: Int32List(2),
      elem: Int32List(2),
      next: Int32List(2),
      s: Float32List(2),
      v: Float32List(2),
      a: Float32List(2),
      lat: Float32List(2),
      kind: Uint8List(2),
      variant: Uint8List(2),
      flags: Uint8List(2),
    );
    expect(own.siteOrd, [-1, -1]);
    expect(own.siteLane, [-1, -1]);
  });

  test('reversing: the vehicle flag, and a stall pull-out on the plan', () {
    final d = Drive(straightRoad());
    final e = edgeOf(d.lg, 'r0');
    final backingOut = d.trip(e, 20, e, 1500, speed: 0);
    final pullingOut = d.trip(e, 400, e, 1600, speed: 0);
    final s0 = SlotPool.slotOf(backingOut), s1 = SlotPool.slotOf(pullingOut);
    // A home back-out is in its lane, flagged by the vehicle table; a stall
    // pull-out is still on the plan, and the phase is what says so (§7.5).
    d.table.flags[s0] |= kReversing;
    final sites = SiteTable(capacity: 8);
    sites.bookSlot[2] = 7;
    final cols = SiteVehicles(d.table.capacity)
      ..row[s1] = 2
      ..lane[s1] = 0
      ..phase[s1] = SitePhase.stallOut.index;
    final f = AgentFrameBuilder()
        .publish(d.table, timeUs: 0, site: cols, siteRows: sites);
    expect(f.flags[s0] & kFrameReversing, kFrameReversing);
    expect(f.flags[s1] & kFrameReversing, kFrameReversing);
    cols.phase[s1] = SitePhase.inbound.index;
    final fwd = AgentFrameBuilder()
        .publish(d.table, timeUs: 0, site: cols, siteRows: sites);
    expect(fwd.flags[s1] & kFrameReversing, 0, reason: 'driving in, not out');
  });
}
