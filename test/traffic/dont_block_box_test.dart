// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/node_control.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// §17.3 #12, `dont_block_the_box` (docs/plans/agent-traffic.md §5.4, §5.8):
/// with the exit lane beyond a junction full, no vehicle ever stands in the
/// junction. It waits at its line — through green — and the cross street
/// keeps moving through the box it left clear.
///
/// On the `signalised()` fixture: a car stalled 40 m up the north arm
/// blocks it for good, and cars from the south arm queue behind it back to
/// the junction and beyond, while cars cross east and west along the
/// avenue. "In the junction" is the body, not the element: a car whose front
/// has reached the exit lane but whose tail is still on its connector is in
/// the box as surely as one wholly on it, and holds every crossing movement
/// short of its tail. Only real junctions have a box; a dead end's turning
/// place does not.
void main() {
  setUp(() {
    AgentTuning.commuteRatePerResident = 0;
    // The queue behind the stalled car is the saturated exit, standing for
    // the whole test: not a jam for the stuck timer to clear.
    AgentTuning.stuckDespawnS = 3600;
  });
  tearDown(AgentTuning.reset);

  test('with the exit full, cars wait at their line and never in the box, '
      'and the cross street keeps flowing', () {
    final r = _saturate();
    expect(r.boxWaits, isEmpty, reason: r.boxWaits.take(5).join('\n'));
    expect(r.heldOnGreen, isTrue,
        reason: 'a car stood at its line through green: the exit was full');
    expect(r.crossArrived, greaterThanOrEqualTo(10));
    expect(r.crossArrived, r.crossSent, reason: 'every car across arrived');
  });

  test('without the box check the same traffic stops in the box', () {
    AgentTuning.dontBlockBox = false;
    final r = _saturate();
    expect(r.boxWaits, isNotEmpty);
  });
}

/// The scenario; what it saw: every car found at rest in a junction's box,
/// whether a car at the south line was held there through green, and the
/// cars sent across the avenue and those that arrived.
({List<String> boxWaits, bool heldOnGreen, int crossSent, int crossArrived})
    _saturate() {
  final city = signalised();
  zoneAll(city, const [ParcelUse.residential]);
  buildAll(city);
  final a = agentsOn(city);
  final southLots = [
    for (final y in const [100.0, 140.0, 180.0, 220.0, 260.0])
      lotNearest(city, Vec2(20, -y)).id,
  ];
  final far = lotNearest(city, const Vec2(20, 270)).id;

  // The plug: a car stalled 40 m up the north arm's northbound lane.
  final plugTrip = forceTrip(a, southLots.first, far);
  final lg = a.laneGraph!;
  final t = a.vehicles!;
  final southUp = edgeNear(lg, const Vec2(0, -150), const Vec2(0, 1));
  final northUp = edgeNear(lg, const Vec2(0, 150), const Vec2(0, 1));
  final approach = lg.laneOf(southUp, 0), exit = lg.laneOf(northUp, 0);
  var plug = -1;
  for (var i = 0; i < 1500 && plug < 0; i++) {
    a.advance(kStepS);
    final h = vehicleOfTrip(a, plugTrip);
    if (h < 0) continue;
    final sl = h & 0xFFFFF;
    if (t.elem[sl] == exit && t.s[sl] >= 40) {
      stall(a, h);
      plug = h;
    }
  }
  expect(plug, greaterThanOrEqualTo(0), reason: 'the plug reached the arm');

  // The queue: more than the 40 m holds, so it backs up through the
  // junction's mouth onto the south arm.
  for (var i = 0; i < 12; i++) {
    forceTrip(a, southLots[i % southLots.length], far);
  }

  // The cross street: east along the avenue's south side, west along its
  // north, a pair every 12 s for three minutes.
  const west = [-120.0, -180.0, -240.0], east = [120.0, 180.0, 240.0];
  final eastFrom = [for (final x in west) _lot(city, x, -25)];
  final eastTo = [for (final x in east) _lot(city, x, -25)];
  final westFrom = [for (final x in east) _lot(city, x, 25)];
  final westTo = [for (final x in west) _lot(city, x, 25)];

  final node = lg.edgeTo[southUp];
  final plan = lg.controls.planOf(node)!;
  final phase = lg.controls.edgePhase[southUp];
  final boxWaits = <String>[];
  var heldOnGreen = false;
  var sent = 0;
  final arrived0 = a.stats.arrived;
  const steps = 300 * 5; // five minutes of sub-steps
  for (var i = 0; i < steps; i++) {
    if (i % 60 == 0 && i < 180 * 5) {
      final k = sent ~/ 2;
      forceTrip(a, eastFrom[k % 3], eastTo[(k + 1) % 3]);
      forceTrip(a, westFrom[k % 3], westTo[(k + 2) % 3]);
      sent += 2;
    }
    a.advance(kStepS);
    for (var sl = 0; sl < t.highWater; sl++) {
      if (!t.isSlotLive(sl) || t.v[sl] >= kStuckMps) continue;
      final c = _boxConnector(t, lg, sl);
      if (c >= 0) {
        boxWaits.add('t=${secondsOf(a.timeUs)} s: handle ${t.handleOf(sl)} at '
            'rest with its body on connector $c');
      }
    }
    final head = t.elemHead[approach];
    if (head >= 0 &&
        t.flags[head] & kRefused != 0 &&
        t.v[head] < kWaitingMps &&
        t.s[head] >= lg.laneLength(approach) - 3 &&
        plan.stateAt(phase, a.timeUs) == SignalState.green) {
      heldOnGreen = true;
    }
  }
  expect(t.isLive(plug), isTrue, reason: 'the plug never moved');
  return (
    boxWaits: boxWaits,
    heldOnGreen: heldOnGreen,
    crossSent: sent,
    crossArrived: a.stats.arrived - arrived0,
  );
}

String _lot(CitySim city, double e, double n) => lotNearest(city, Vec2(e, n)).id;

/// The connector of a real junction that some part of the vehicle in [sl]
/// lies on, or −1: the one it is on, or — its front just onto the lane
/// beyond, its tail not yet clear — the one it came through.
int _boxConnector(VehicleTable t, LaneGraph lg, int sl) {
  final nL = lg.laneCount;
  final el = t.elem[sl];
  int c;
  if (el >= nL) {
    c = el - nL;
  } else {
    final cur = t.routeCur[sl];
    if (cur == 0 || t.s[sl] >= t.len[sl]) return -1;
    c = t.connectorOfRouteEdge(sl, cur);
  }
  return isRealJunction(lg.kindOf(lg.conNode[c])) ? c : -1;
}
