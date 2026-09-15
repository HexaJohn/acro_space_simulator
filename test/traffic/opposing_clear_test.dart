// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// `JunctionArbiter.opposingClear`, pulled out of `canJoin`'s `fromLeft`
/// loop (docs/plans/t4a-implementation.md §2), against the loop it came
/// from.
///
/// The site arrival gate asks the same question as a car pulling out of a
/// building on the left of travel (G2, site-access.md §7.4, ask 14), so the
/// predicate had to become public. It must not have become a DIFFERENT
/// predicate on the way: [_oldFromLeft] below is the loop as it stood at
/// 758b018, and every case here is checked against it.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/junction_arbiter.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';

/// The `fromLeft` half of `canJoin` as it stood before the extraction: the
/// opposing carriageway crossed at the mirror of [at], every lane of it
/// clear across the crossing with nothing arriving inside [kOpposingGapS].
bool _oldFromLeft(VehicleTable t, LaneGraph lg, int lane, double at, double len) {
  final e = lg.laneEdge[lane];
  final r = lg.edgeReverse[e];
  if (r < 0) return true;
  final tArc = lg.edgeLen[e] - (lg.edgeLaneS0[e] + at);
  final atR = tArc - lg.edgeLaneS0[r];
  for (var j = 0; j < lg.edgeLaneCount[r]; j++) {
    if (!_oldCrossingClear(t, lg.laneOf(r, j), atR, len)) return false;
  }
  return true;
}

bool _oldCrossingClear(VehicleTable t, int lane, double at, double len) {
  for (var w = t.elemHead[lane]; w >= 0; w = t.next[w]) {
    final sw = t.s[w];
    if (sw - t.len[w] <= at + len && sw >= at - len) return false;
    if (sw < at) {
      final vw = t.v[w];
      return (at - sw) / (vw > kEtaFloorMps ? vw : kEtaFloorMps) >=
          kOpposingGapS;
    }
  }
  return true;
}

void main() {
  late Drive d;
  late int lane, opposing;
  late double s0, s1;

  setUp(() {
    final lg = straightRoad();
    d = Drive(lg);
    lane = lg.laneOf(0, 0);
    final r = lg.edgeReverse[0];
    opposing = lg.laneOf(r, 0);
    s0 = lg.edgeLaneS0[0].toDouble();
    s1 = lg.edgeLaneS1[0].toDouble();
  });

  /// A car on [onLane] with its front [at] lane metres along, at [speed].
  int car(int onLane, double at, {double speed = 0}) {
    final e = d.lg.laneEdge[onLane];
    final h = d.table.spawn(
      kind: AgentKind.car,
      route: Int32List.fromList([onLane]),
      routeLength: 1,
      originT: d.lg.edgeLaneS0[e] + at,
      destT: d.lg.edgeLaneS1[e],
      nowUs: 0,
      speed: speed,
    );
    expect(h, isNot(SlotPool.none));
    return h;
  }

  /// The crossing point on the opposing lane for a pull-out at [at].
  double mirrorOf(double at) {
    final r = d.lg.edgeReverse[0];
    return d.lg.edgeLen[0] - (s0 + at) - d.lg.edgeLaneS0[r];
  }

  void check(double at, {required bool expected}) {
    const len = 4.9;
    expect(d.arbiter.opposingClear(lane, at, len), expected);
    expect(d.arbiter.opposingClear(lane, at, len),
        _oldFromLeft(d.table, d.lg, lane, at, len),
        reason: 'the extracted predicate must be the loop it came from');
    // The whole of canJoin from the left is that loop and the room on the
    // near lanes, which nothing stands in here.
    expect(d.arbiter.canJoin(lane, at, len, AgentKind.car, fromLeft: true),
        expected);
  }

  test('an empty opposing carriageway is clear', () {
    check(400, expected: true);
    expect(s1, greaterThan(400));
  });

  test('a body across the crossing point is not', () {
    final at = 400.0;
    car(opposing, mirrorOf(at));
    check(at, expected: false);
  });

  test('a car approaching the crossing inside four seconds is not', () {
    final at = 400.0;
    // 30 m short of the crossing at 10 m/s: three seconds away.
    car(opposing, mirrorOf(at) - 30, speed: 10);
    check(at, expected: false);
  });

  test('a car far enough back, or already past, is clear', () {
    final at = 400.0;
    // 120 m short at 10 m/s: twelve seconds away.
    final back = car(opposing, mirrorOf(at) - 120, speed: 10);
    check(at, expected: true);
    // Past the crossing, whatever its speed: it is behind the turn.
    d.table.detach(SlotPool.slotOf(back));
    car(opposing, mirrorOf(at) + 60, speed: 2);
    check(at, expected: true);
  });

  test('a stopped car short of the crossing never clears (the ETA floor)',
      () {
    final at = 400.0;
    car(opposing, mirrorOf(at) - 1.5);
    check(at, expected: false);
  });

  test('a one-way street has no opposing carriageway', () {
    final lg = straightRoad(cls: RoadClass.streetOneWay);
    final one = Drive(lg);
    final only = lg.laneOf(0, 0);
    expect(lg.edgeReverse[0], -1);
    expect(one.arbiter.opposingClear(only, 100, 4.9), isTrue);
    expect(_oldFromLeft(one.table, lg, only, 100, 4.9), isTrue);
  });
}
