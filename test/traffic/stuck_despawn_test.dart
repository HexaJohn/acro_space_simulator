// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';

/// Stuck vehicles, and what is not stuck (docs/plans/agent-traffic.md §5.6,
/// §5.8; §17.3 #7 in its car form, and #29): a car that cannot get anywhere
/// despawns 120 s after it came to rest, never earlier; a vehicle standing
/// on purpose, or held for a re-plan, never does; and where three approaches
/// to one junction have each waited a minute, the longest waiter goes.
void main() {
  tearDown(AgentTuning.reset);

  /// Runs [d] until [h] is gone or [limitS] have passed, and returns when
  /// it first came below the stuck speed.
  int? restOf(Drive d, int h, {double limitS = 400}) {
    int? rest;
    while (d.table.isLive(h) && d.nowUs < usOf(limitS)) {
      d.step();
      if (rest == null &&
          d.table.isLive(h) &&
          d.table.v[d.slot(h)] < kStuckMps) {
        rest = d.nowUs;
      }
    }
    return rest;
  }

  test('a car queued behind a stalled one despawns 120 s after it came to '
      'rest, never earlier; the stalled one, standing on purpose, stays', () {
    final lg = straightRoad(lengthM: 1200);
    final e = edgeOf(lg, 'r0');
    final d = Drive(lg);
    final stalled = d.trip(e, 700, e, 1100);
    d.table.stall(stalled);
    final car = d.trip(e, 100, e, 1100, speed: 10);
    final rest = restOf(d, car);
    expect(rest, isNotNull);
    expect(d.despawns[car], DespawnReason.stuck);
    final lived = secondsOf(d.despawnUs[car]! - rest!);
    expect(lived, inInclusiveRange(119.8 - 1e-9, 120.2 + 1e-9));
    expect(d.mover.despawnStuck, 1);
    expect(d.mover.edgeStuck[e], 1);
    d.run(200);
    expect(d.table.isLive(stalled), isTrue,
        reason: 'a dwelling vehicle\'s stuck timer is frozen');
    expect(d.table.stuckUs[d.slot(stalled)], 0);
  });

  test('a blocked dead end: the car waiting for the turning circle despawns '
      'at 120 s', () {
    final lg = straightRoad(lengthM: 400);
    final east = edgeOf(lg, 'r0'), west = edgeOf(lg, 'r0', forward: false);
    final d = Drive(lg);
    // One car round the dead end, stalled on the turn itself.
    final blocker = d.trip(east, 330, west, 300, speed: 6);
    while (d.table.elem[d.slot(blocker)] < lg.laneCount) {
      d.step();
    }
    d.table.stall(blocker);
    final car = d.trip(east, 60, west, 300, speed: 8);
    final rest = restOf(d, car);
    expect(d.despawns[car], DespawnReason.stuck);
    expect(secondsOf(d.despawnUs[car]! - rest!),
        inInclusiveRange(119.8 - 1e-9, 120.2 + 1e-9));
    expect(d.table.isLive(blocker), isTrue);
  });

  test('held at the end of its edge for a re-plan, a vehicle is never '
      'despawned, and never enters the junction', () {
    final lg = crossroads();
    final d = Drive(lg);
    final west = edgeNear(lg, const Vec2(-150, 0), const Vec2(1, 0));
    final north = edgeNear(lg, const Vec2(0, 150), const Vec2(0, 1));
    final h = d.trip(west, 50, north, 200, speed: 8);
    final sl = d.slot(h);
    d.table.state[sl] = VehicleState.holdAtEdgeEnd.index;
    d.run(300);
    expect(d.table.isLive(h), isTrue);
    expect(d.table.stuckUs[sl], 0);
    expect(d.table.elem[sl], lessThan(lg.laneCount), reason: 'still on its lane');
    final laneLen = lg.laneLength(d.table.elem[sl]);
    expect(d.table.s[sl], inInclusiveRange(laneLen - 3, laneLen));
    expect(d.table.v[sl], lessThan(0.05));
    // The re-plan arrives: it drives on, and its route takes it through.
    d.table.state[sl] = VehicleState.driving.index;
    d.run(60);
    expect(d.arrivedHandles, contains(h));
  });

  test('the wedge breaker: once three approaches have each waited past '
      '60 s, the longest waiter goes, then the next', () {
    AgentTuning.stuckDespawnS = 600;
    final lg = crossroads();
    final d = Drive(lg);
    final centre = lg.edgeTo[edgeNear(lg, const Vec2(-150, 0), const Vec2(1, 0))];
    // A car parked just past the mouth of every road out: no exit has room.
    final ins = <int>[], outs = <int>[];
    for (var e = 0; e < lg.edgeCount; e++) {
      if (lg.edgeTo[e] == centre) ins.add(e);
      if (lg.edgeFrom[e] == centre) outs.add(e);
    }
    expect(ins, hasLength(4));
    for (final e in outs) {
      final at = lg.edgeLaneS0[e] + 6;
      final h = d.trip(e, at, e, at + 100, checkRoom: false);
      expect(h, isNot(SlotPool.none));
      d.table.stall(h);
    }
    // Four cars that want to cross, arriving one after another.
    final cars = <int>[];
    for (var i = 0; i < 4; i++) {
      final e = ins[i];
      final out = outs.firstWhere((o) => lg.edgeReverse[o] != e &&
          lg.canFollow(e, o));
      cars.add(d.trip(e, lg.edgeLaneS1[e] - 60.0 - 25 * i, out,
          lg.edgeLaneS0[out] + 150));
    }
    expect(cars, everyElement(isNot(SlotPool.none)));
    d.run(150);
    expect(d.mover.despawnWedge, 2);
    final wedged = [
      for (final h in cars)
        if (d.despawns[h] == DespawnReason.wedge) h,
    ];
    expect(wedged, [cars[0], cars[1]],
        reason: 'the first two to arrive had waited longest');
    expect(d.despawnUs[cars[0]]!, lessThan(d.despawnUs[cars[1]]!));
    expect(d.table.isLive(cars[2]), isTrue);
    expect(d.table.isLive(cars[3]), isTrue);
    for (final h in [cars[2], cars[3]]) {
      expect(d.table.kind[d.slot(h)], AgentKind.car.index);
    }
  });
}
