// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The access-event seam on the vehicle table (T4a P0,
/// docs/plans/t4a-implementation.md §1.4, §2; site-access.md §7.4).
///
/// A car inside a site is off the road: element −1, on no element's list.
/// Everything that walks the lists must therefore leave it out, and
/// everything that indexes an element by slot must see the −1 first — a
/// rebuild's `relinkAll` above all, which would otherwise index
/// `elemTail[−1]` and crash the colony on a road edit.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';

void main() {
  late Drive d;
  late int lane;
  late double s0, s1;

  setUp(() {
    final lg = straightRoad();
    d = Drive(lg);
    lane = lg.laneOf(0, 0);
    s0 = lg.edgeLaneS0[0].toDouble();
    s1 = lg.edgeLaneS1[0].toDouble();
  });

  /// A car whose front is [at] lane metres along [lane], driving to the end.
  int car(double at) => d.table.spawn(
        kind: AgentKind.car,
        route: Int32List.fromList([lane]),
        routeLength: 1,
        originT: s0 + at,
        destT: s1,
        nowUs: d.nowUs,
      );

  List<int> listOf(int el) {
    final t = d.table;
    final out = <int>[];
    for (var sl = t.elemHead[el]; sl >= 0; sl = t.next[sl]) {
      out.add(t.handleOf(sl));
    }
    return out;
  }

  test('detach and attach keep the lane in order, and link no element −1',
      () {
    final t = d.table;
    final a = car(100), b = car(70), c = car(40);
    expect(listOf(lane), [a, b, c]);

    t.detach(SlotPool.slotOf(b));
    expect(t.elem[SlotPool.slotOf(b)], -1);
    expect(t.isLive(b), isTrue, reason: 'it is inside a site, not despawned');
    expect(listOf(lane), [a, c]);
    expect(t.elemCount[lane], 2);
    expect(t.nextElemOf(SlotPool.slotOf(b)), -1);
    expect(occupancyErrors(t), isEmpty);

    // A rebuild relinks every vehicle on the road; the one off it stays off
    // and indexes no element.
    t.relinkAll();
    expect(listOf(lane), [a, c]);
    expect(t.elem[SlotPool.slotOf(b)], -1);
    expect(t.prev[SlotPool.slotOf(b)], -1);
    expect(t.next[SlotPool.slotOf(b)], -1);
    expect(occupancyErrors(t), isEmpty);

    t.attach(SlotPool.slotOf(b), lane, 70, nowUs: d.nowUs);
    expect(listOf(lane), [a, b, c], reason: 'back in its place in the order');
    expect(t.elemCount[lane], 3);
    expect(t.s[SlotPool.slotOf(b)], 70);
    expect(t.v0[SlotPool.slotOf(b)],
        closeTo(d.lg.edgeLimit[0] * t.f[SlotPool.slotOf(b)], 1e-3));
    expect(t.edgeEnterUs[SlotPool.slotOf(b)], -1,
        reason: 'it pulled out part way along: it observes no delay here');
    expect(occupancyErrors(t), isEmpty);
  });

  test('detaching twice, and attaching past the lane end, are both safe', () {
    final t = d.table;
    final h = car(50);
    final sl = SlotPool.slotOf(h);
    t.detach(sl);
    t.detach(sl);
    expect(t.elem[sl], -1);
    expect(t.elemCount[lane], 0);
    t.attach(sl, lane, 1e9, nowUs: d.nowUs);
    expect(t.s[sl], d.lg.laneLength(lane));
    expect(occupancyErrors(t), isEmpty);
  });

  test('spawnDetached puts a car on no element, with its route', () {
    final t = d.table;
    final onRoad = car(100);
    final h = t.spawnDetached(
      kind: AgentKind.car,
      route: Int32List.fromList([lane]),
      routeLength: 1,
      originT: s0 + 200,
      destT: s1,
      nowUs: d.nowUs,
      owner: 7,
    );
    final sl = SlotPool.slotOf(h);
    expect(t.isLive(h), isTrue);
    expect(t.elem[sl], -1);
    expect(t.s[sl], 0);
    expect(t.v[sl], 0);
    expect(t.routeLen[sl], 1);
    expect(t.owner[sl], 7);
    expect(t.state[sl], VehicleState.driving.index);
    expect(t.elemCount[lane], 1, reason: 'only the car on the road is listed');
    expect(listOf(lane), [onRoad]);
    expect(occupancyErrors(t), isEmpty);

    t.attach(sl, lane, 40, nowUs: d.nowUs);
    expect(listOf(lane), [onRoad, h]);
    expect(occupancyErrors(t), isEmpty);
  });

  test('a car inside a site is never moved, and never despawns stuck', () {
    final t = d.table;
    final h = car(100);
    final sl = SlotPool.slotOf(h);
    t.detach(sl);
    t.state[sl] = VehicleState.onSite.index;
    t.s[sl] = 3.5; // its place on a site lane, which the road never touches
    d.run(200);
    expect(t.isLive(h), isTrue);
    expect(d.despawns, isEmpty);
    expect(t.s[sl], 3.5);
    expect(t.stuckUs[sl], 0);
  });

  test('a manoeuvring car stands like a dwelling one, and its followers '
      'stop behind it', () {
    final t = d.table;
    final front = car(300), back = car(240);
    final fs = SlotPool.slotOf(front), bs = SlotPool.slotOf(back);
    t.state[fs] = VehicleState.manoeuvre.index;
    t.flags[fs] |= kReversing;
    t.v[fs] = 0;
    d.run(30);
    expect(t.s[fs], 300, reason: 'the site mover owns its pose');
    expect(t.v[fs], 0);
    expect(t.a[fs], 0);
    expect(t.s[bs], lessThan(300 - t.len[fs]),
        reason: 'the follower stopped behind its body');
    expect(t.v[bs], lessThan(0.5));
    expect(t.stuckUs[fs], 0, reason: 'a manoeuvre freezes the stuck clock');
    expect(occupancyErrors(t), isEmpty);
  });

  test('a manoeuvring car still samples its lane as blocked', () {
    final t = d.table;
    final h = car(300);
    t.state[SlotPool.slotOf(h)] = VehicleState.manoeuvre.index;
    d.mover.clearLaneBooks();
    d.step();
    expect(d.mover.laneSamples[lane], 1);
    expect(d.nowUs, kStepUs);
  });
}
