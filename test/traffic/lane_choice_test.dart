// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// §17.3 #5, live (docs/plans/agent-traffic.md §4.5): a car planned onto an
/// avenue drives it in the lane its next turn needs — the inner lane for a
/// left, the kerb lane for a right, a boulevard's third lane for a left —
/// and where two lanes serve a trip equally it takes the one with fewer
/// cars on it at that moment, so through traffic spreads across the lanes.
///
/// lane_planner_test pins the lane pass on bare lane graphs. Here the
/// colony's own trips drive it: the lots they leave from and go to, the
/// queue that plans them, the table whose lanes the tie-break counts.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('on an avenue a left at the next node is driven from lane 1, and a '
      'right from lane 0', () {
    final city = _arterialTown(RoadClass.avenue);
    final a = agentsOn(city);
    final from = lotNearest(city, const Vec2(100, -25)).id;
    final left = _pullOut(a, forceTrip(a, from, _lotAt(city, 220, 100)));
    final lg = a.laneGraph!;
    final east = edgeNear(lg, const Vec2(100, 0), const Vec2(1, 0));
    final north = edgeNear(lg, const Vec2(200, 100), const Vec2(0, 1));
    final south = edgeNear(lg, const Vec2(200, -100), const Vec2(0, -1));
    expect(routeOf(a, left).take(2), [_word(lg, east, 1), _word(lg, north, 0)],
        reason: 'left at x = 200 from the inner lane');
    final right = _pullOut(a, forceTrip(a, from, _lotAt(city, 180, -100)));
    expect(routeOf(a, right).take(2), [_word(lg, east, 0), _word(lg, south, 0)],
        reason: 'right at x = 200 from the kerb lane');
    _arriveAll(a, 2);
  });

  test('on a boulevard a left-turner is in lane 2', () {
    final city = _arterialTown(RoadClass.boulevard);
    final a = agentsOn(city);
    final from = lotNearest(city, const Vec2(100, -30)).id;
    final left = _pullOut(a, forceTrip(a, from, _lotAt(city, 220, 100)));
    final lg = a.laneGraph!;
    final east = edgeNear(lg, const Vec2(100, 0), const Vec2(1, 0));
    final north = edgeNear(lg, const Vec2(200, 100), const Vec2(0, 1));
    expect(lg.edgeLaneCount[east], 3);
    expect(routeOf(a, left).take(2), [_word(lg, east, 2), _word(lg, north, 0)]);
    _arriveAll(a, 1);
  });

  test('where two lanes serve a trip equally the emptier is taken: through '
      'traffic spreads across the lanes', () {
    // North up the street at x = 400, left onto the avenue westbound,
    // straight on at x = 200 and right at x = 0. Landing in the avenue's
    // inner lane, the natural landing of a left, needs a shift back to the
    // kerb at x = 200; landing in the kerb lane costs a lane at once. The
    // charge is the same either way (lane_planner_test pins it), so the
    // cars already on the westbound piece decide.
    final city = _arterialTown(RoadClass.avenue);
    final a = agentsOn(city);
    final from = _lotAt(city, 420, -100), to = _lotAt(city, 20, 100);
    runAgents(a, 2); // past the first of the spawn ramp
    final lg = a.laneGraph!;
    final west = edgeNear(lg, const Vec2(300, 0), const Vec2(-1, 0));
    final piece = lg.graph.roads[lg.edgeRoad[west]].id;
    final l0 = lg.laneOf(west, 0), l1 = lg.laneOf(west, 1);
    final t = a.vehicles!;
    final landed = <int>[];
    final cars = <int>[];
    for (var k = 0; k < 6; k++) {
      // What the queue's lane pass will count, since no sub-step runs
      // between here and its plan.
      final n0 = t.elemCount[l0], n1 = t.elemCount[l1];
      final h = _pullOut(a, forceTrip(a, from, to), stepS: kStepS);
      final lane = laneOn(a, h, piece);
      expect(lane, n1 < n0 ? 1 : 0,
          reason: 'car $k planned with $n0 on the kerb lane and $n1 on the '
              'inner: the emptier, the kerb lane of equals');
      landed.add(lane);
      cars.add(h);
      // The next car is planned while this one drives the piece — in the
      // lane it was given there, and no other.
      var on = false;
      for (var i = 0; i < 600 && !on; i++) {
        a.advance(kStepS);
        final el = t.elem[h & 0xFFFFF];
        on = t.isLive(h) && el < lg.laneCount && lg.laneEdge[el] == west;
        if (on) expect(el, lg.laneOf(west, lane), reason: 'car $k');
      }
      expect(on, isTrue, reason: 'car $k reached the westbound piece');
    }
    expect(landed.toSet(), {0, 1}, reason: 'both lanes: $landed');
    _arriveAll(a, cars.length);
  });
}

/// Streets north–south at x = 0, 200, 400 and 600 from y = −200 to 200,
/// then a [cls] east–west along y = 0 from x = −200 to 800 across them all:
/// the arterial is cut into five pieces and every crossing has lights.
/// Every lot is a home.
CitySim _arterialTown(RoadClass cls) {
  final city = foundFlat(roads: [
    for (var i = 0; i < 4; i++)
      FixtureRoad([Vec2(i * 200.0, -200), Vec2(i * 200.0, 200)]),
    FixtureRoad(const [Vec2(-200, 0), Vec2(800, 0)], roadClass: cls),
  ]);
  zoneAll(city, const [ParcelUse.residential]);
  buildAll(city);
  return city;
}

/// The lot whose centroid is nearest (e, n).
String _lotAt(CitySim city, double e, double n) =>
    lotNearest(city, Vec2(e, n)).id;

/// Edge [e] in lane [lane], in [routeOf]'s words.
String _word(LaneGraph lg, int e, int lane) =>
    '${lg.graph.roads[lg.edgeRoad[e]].id}'
    '${lg.edgeForward[e] == 1 ? '+' : '-'}$lane';

/// Advances [a] until [trip] has pulled out; its vehicle.
int _pullOut(CityAgents a, int trip, {double stepS = 0.5}) {
  expect(trip, greaterThanOrEqualTo(0), reason: 'the trip was taken');
  for (var i = 0; i < 240; i++) {
    a.advance(stepS);
    final h = vehicleOfTrip(a, trip);
    if (h >= 0) return h;
  }
  fail('the trip never pulled out');
}

/// Runs [a] until every vehicle is off the road, and checks the last
/// [count] trips all arrived — none taken off.
void _arriveAll(CityAgents a, int count) {
  for (var i = 0; i < 1200 && a.liveVehicles > 0; i++) {
    a.advance(0.5);
  }
  expect(a.liveVehicles, 0);
  expect(a.stats.arrived, count);
  expect(a.stats.despawnStuck + a.stats.despawnWedge + a.stats.despawnEdit, 0);
}
