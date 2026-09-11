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

/// §17.3 #3 (docs/plans/agent-traffic.md §3.9, §4.6): a road drawn across
/// planned routes splits the roads it crosses, and every route carried
/// across passes STRAIGHT THROUGH the junction it made, in the lane it was
/// in — nobody re-plans, nobody is taken off, everybody arrives — while a
/// trip planned after the road is drawn takes it.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('trips planned the long way drive straight through a shortcut drawn '
      'across their route; a trip planned after it takes it', () {
    final city = _uTown();
    final a = agentsOn(city);
    final dests = [
      lotNearest(city, const Vec2(600, 185)).id,
      lotNearest(city, const Vec2(650, 215)).id,
    ];
    final origins = [
      for (final x in const [-500.0, -560.0, -620.0, -680.0])
        lotNearest(city, Vec2(x, 185)).id,
    ];
    final trips = [
      for (var i = 0; i < 20; i++) forceTrip(a, origins[i % 4], dests[i % 2]),
    ];
    for (var i = 0; i < 240; i++) {
      if (trips.every((tr) => vehicleOfTrip(a, tr) >= 0)) break;
      a.advance(0.5);
    }
    final cars = [for (final tr in trips) vehicleOfTrip(a, tr)];
    expect(cars.every((h) => h >= 0), isTrue, reason: 'all 20 pulled out');
    final lanes = {for (final h in cars) h: routeOf(a, h)};

    final shortcut =
        commit(city, const FixtureRoad([Vec2(-400, 0), Vec2(400, 0)]));
    a.advance(0.5);
    expect(a.graphRev, 2, reason: 'the road rebuilt the lane graph');
    expect(a.stats.replans, 0, reason: 'no route was made impossible');
    expect(a.stats.despawnEdit, 0);

    final lg = a.laneGraph!;
    final tee = lg.graph.nodeNear(const Vec2(-400, 0))!.id;
    var through = 0;
    for (final h in cars) {
      if (!a.vehicles!.isLive(h)) continue;
      final words = routeOf(a, h);
      expect(words.any((w) => w.startsWith(shortcut)), isFalse,
          reason: 'planned before the road: never onto it ($words)');
      expect(_sameLanes(lanes[h]!, words), isTrue,
          reason: 'each piece in the lane its road was planned in: '
              '${lanes[h]} → $words');
      if (_crosses(a, h, tee)) through++;
    }
    expect(through, greaterThan(0),
        reason: 'routes run on through the new junction on W');

    final late = forceTrip(a, origins[0], dests[0]);
    int lateCar = -1;
    for (var i = 0; i < 120 && lateCar < 0; i++) {
      a.advance(0.5);
      lateCar = vehicleOfTrip(a, late);
    }
    expect(lateCar, greaterThanOrEqualTo(0));
    expect(routeOf(a, lateCar).any((w) => w.startsWith(shortcut)), isTrue,
        reason: 'a trip planned after the road takes it');

    final arrived = a.stats.arrived;
    runAgents(a, 400);
    for (final h in cars) {
      expect(a.vehicles!.isLive(h), isFalse, reason: 'arrived');
    }
    expect(a.stats.arrived - arrived, greaterThanOrEqualTo(1));
    expect(a.stats.arrived, 21);
    expect(a.stats.despawnStuck + a.stats.despawnWedge, 0);
    expect(a.stats.replans, 0);
  });
}

/// Streets W (x = −400), S (y = −300) and E (x = 400) in a U, and spurs O
/// west off W and D east off E at y = 200: from O the only way to D is down
/// W, along S and up E. Every lot is a home.
CitySim _uTown() {
  final city = foundFlat(roads: const [
    FixtureRoad([Vec2(-400, -300), Vec2(-400, 300)]),
    FixtureRoad([Vec2(-400, -300), Vec2(400, -300)]),
    FixtureRoad([Vec2(400, -300), Vec2(400, 300)]),
    FixtureRoad([Vec2(-400, 200), Vec2(-700, 200)]),
    FixtureRoad([Vec2(400, 200), Vec2(700, 200)]),
  ]);
  zoneAll(city, const [ParcelUse.residential]);
  buildAll(city);
  return city;
}

/// Whether every step of route [now] (in [routeOf]'s words) runs in the
/// lane, and the direction, that route [was] used on the road it descends
/// from — itself, or the road a split cut it from (`<id>x<i>`). A split adds
/// a step to a route, so the two are matched by road, not by position.
bool _sameLanes(List<String> was, List<String> now) {
  for (final w in now) {
    final road = w.substring(0, w.length - 2);
    var matched = false;
    for (final v in was) {
      final old = v.substring(0, v.length - 2);
      if (road != old && !road.startsWith('${old}x')) continue;
      if (v.substring(v.length - 2) != w.substring(w.length - 2)) return false;
      matched = true;
    }
    if (!matched) return false;
  }
  return true;
}

/// Whether the rest of [h]'s route runs through node [node].
bool _crosses(CityAgents a, int h, int node) {
  final t = a.vehicles!, lg = a.laneGraph!;
  final sl = h & 0xFFFFF;
  for (var i = t.routeCur[sl]; i < t.routeLen[sl] - 1; i++) {
    if (lg.edgeTo[lg.laneEdge[t.laneOfRouteEdge(sl, i)]] == node) return true;
  }
  return false;
}
