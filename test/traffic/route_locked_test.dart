// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// §17.3 #1, the half slice 1 can pin (docs/plans/agent-traffic.md §4.6):
/// a route never changes for traffic. Its connectors and its lane on every
/// edge are the ones it was planned with at every sub-step until it arrives
/// — past a jam, or stuck behind one until the stuck timer takes it. (Who
/// takes the other road next time needs slice 2's delay table.)
void main() {
  // No background demand: only the trips each test sends.
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('X drives past a jam on its own road on the route, and in the lanes, '
      'it was planned with', () {
    final city = _street();
    final a = agentsOn(city);
    // Thirty cars westbound from six homes to one, then frozen where they
    // are: a jam the length of the street's far side.
    final far = lotNearest(city, const Vec2(-650, 20)).id;
    for (var i = 0; i < 6; i++) {
      final from = lotNearest(city, Vec2(550.0 - 100 * i, 20)).id;
      for (var k = 0; k < 5; k++) {
        forceTrip(a, from, far);
      }
    }
    for (var i = 0; i < 180 && !_allOnRoad(a); i++) {
      a.advance(0.5);
    }
    expect(_allOnRoad(a), isTrue, reason: 'every car pulled out');
    final t = a.vehicles!;
    var stalled = 0;
    for (var sl = 0; sl < t.highWater; sl++) {
      if (!t.isSlotLive(sl)) continue;
      stall(a, t.handleOf(sl));
      stalled++;
    }
    expect(stalled, 30);

    final x = forceTrip(a, lotNearest(city, const Vec2(-600, -20)).id,
        lotNearest(city, const Vec2(600, -20)).id);
    final xh = _pullOut(a, x);
    final hash = routeHash(a, xh);
    final planned = routeOf(a, xh);
    final arrived = a.stats.arrived;
    var ticks = 0;
    while (a.vehicles!.isLive(xh)) {
      expect(routeHash(a, xh), hash, reason: 'its connectors, at ${a.timeUs}');
      final now = routeOf(a, xh);
      expect(now, planned.sublist(planned.length - now.length),
          reason: 'its lanes, at ${a.timeUs}');
      a.advance(0.5);
      expect(++ticks, lessThan(600), reason: 'X should have arrived');
    }
    expect(a.stats.arrived, arrived + 1, reason: 'X arrived');
    expect(a.stats.despawnStuck, 0);
    expect(a.stats.replans, 0);
    expect(a.stats.appendedLegs, 0);
  });

  test('Z, stuck behind a car that will never move, keeps its route until '
      'the stuck timer takes it — no re-plan', () {
    final city = _street();
    final a = agentsOn(city);
    final b = forceTrip(a, lotNearest(city, const Vec2(-300, -20)).id,
        lotNearest(city, const Vec2(700, -20)).id);
    final bh = _pullOut(a, b);
    for (var i = 0; i < 20; i++) {
      a.advance(0.5);
    }
    stall(a, bh);

    final z = forceTrip(a, lotNearest(city, const Vec2(-650, -20)).id,
        lotNearest(city, const Vec2(650, -20)).id);
    final zh = _pullOut(a, z);
    final hash = routeHash(a, zh);
    var ticks = 0;
    while (a.vehicles!.isLive(zh)) {
      expect(routeHash(a, zh), hash, reason: 'at ${a.timeUs}');
      a.advance(0.5);
      expect(++ticks, lessThan(1200), reason: 'Z should have been taken off');
    }
    expect(a.stats.despawnStuck, 1, reason: 'Z, and only Z');
    expect(a.stats.replans, 0);
    expect(a.vehicles!.isLive(bh), isTrue, reason: 'a stalled car dwells');
  });
}

/// A 1.6 km street east–west through the origin, every lot along it a
/// home.
CitySim _street() {
  final city = foundFlat(
      roads: const [FixtureRoad([Vec2(-800, 0), Vec2(800, 0)])]);
  zoneAll(city, const [ParcelUse.residential]);
  buildAll(city);
  return city;
}

/// Whether every trip asked for is on the road.
bool _allOnRoad(CityAgents a) =>
    a.commutes!.liveCount == a.liveVehicles &&
    a.pathQueue!.idle &&
    a.planner!.waiting == 0;

/// Advances [a] until [trip] has pulled out; its vehicle.
int _pullOut(CityAgents a, int trip) {
  expect(trip, greaterThanOrEqualTo(0), reason: 'the trip was taken');
  for (var i = 0; i < 120; i++) {
    final h = vehicleOfTrip(a, trip);
    if (h >= 0) return h;
    a.advance(0.5);
  }
  fail('the trip never pulled out');
}
