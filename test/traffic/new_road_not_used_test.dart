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
/// trip planned after the road is drawn takes it. The lots the split re-cuts
/// and renames are carried by E12, so no trip to one loses its destination.
///
/// The agents are the colony's own ([_colonyAgents]), so the road commits
/// reach them through E12 exactly as they reach the play surface's; the
/// test advances them itself, so the economy stands still.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('trips planned the long way drive straight through a shortcut drawn '
      'across their route, to lots its re-cut renamed among them; a trip '
      'planned after it takes it', () {
    final city = _uTown();
    final a = _colonyAgents(city);
    final dests = [
      lotNearest(city, const Vec2(600, 185)).id,
      lotNearest(city, const Vec2(650, 215)).id,
      // On E between S and D: the shortcut cuts E, and every lot along
      // the piece it cuts is re-cut and renamed.
      lotNearest(city, const Vec2(420, 100)).id,
      lotNearest(city, const Vec2(380, 60)).id,
    ];
    final origins = [
      for (final x in const [-500.0, -560.0, -620.0, -680.0])
        lotNearest(city, Vec2(x, 185)).id,
    ];
    final trips = [
      for (var i = 0; i < 20; i++)
        forceTrip(a, origins[i % 4], dests[(i ~/ 4) % 4]),
    ];
    for (var i = 0; i < 240; i++) {
      if (trips.every((tr) => vehicleOfTrip(a, tr) >= 0)) break;
      a.advance(0.5);
    }
    final cars = [for (final tr in trips) vehicleOfTrip(a, tr)];
    expect(cars.every((h) => h >= 0), isTrue, reason: 'all 20 pulled out');
    final lanes = {for (final h in cars) h: routeOf(a, h)};
    final b = a.buildings!;
    final building = {
      for (final site in dests.sublist(2)) site: b.handleOfSite(site)!,
    };
    final toRenamed = [
      for (final h in cars)
        if (building.containsKey(a.describe(h)!['to'])) h,
    ];
    expect(toRenamed, hasLength(8));

    final shortcut =
        commit(city, const FixtureRoad([Vec2(-400, 0), Vec2(400, 0)]));
    a.advance(0.5);
    expect(a.graphRev, 2, reason: 'the road rebuilt the lane graph');
    expect(a.stats.replans, 0, reason: 'no route was made impossible');
    expect(a.stats.despawnEdit, 0);

    // Their lots re-cut and renamed, and each carried (E12): the same
    // building, the same handle, under the new name — the one the trips
    // driving there now name.
    for (final e in building.entries) {
      expect(city.layout.autoParcels.any((p) => p.id == e.key), isFalse,
          reason: '${e.key} was re-cut');
      final now = b.siteOf(e.value);
      expect(now, allOf(isNotNull, isNot(e.key)),
          reason: 'its building carried to the lot that replaced it');
      expect(city.parcelBuildings.containsKey(now), isTrue);
      expect(b.handleOfSite(now!), e.value);
    }
    for (final h in toRenamed) {
      expect(building.values.map(b.siteOf), contains(a.describe(h)!['to']),
          reason: 'it drives to the renamed site');
    }

    final lg = a.laneGraph!;
    final tee = lg.graph.nodeNear(const Vec2(-400, 0))!.id;
    var through = 0;
    for (final h in cars) {
      if (!a.vehicles!.isLive(h)) continue;
      final words = routeOf(a, h);
      expect(words.any((w) => w.startsWith(shortcut)), isFalse,
          reason: 'planned before the road: never onto it ($words)');
      expect(routeDescends(lanes[h]!, words), isTrue,
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
    expect(a.stats.arrivedGone, 0,
        reason: 'every trip found its building where it arrived');
    expect(a.stats.despawnStuck + a.stats.despawnWedge, 0);
    expect(a.stats.replans, 0);
  });

  test('trips planned but still waiting to pull out when the shortcut is '
      'drawn keep the long way they were planned: waiting is no licence to '
      'plan again', () {
    final city = _uTown();
    final a = _colonyAgents(city);
    final (origins, dests) = _ends(city);
    final trips = [
      for (var i = 0; i < 20; i++) forceTrip(a, origins[i % 4], dests[i % 2]),
    ];
    // Inside the spawn ramp's first half second no car pulls out: every
    // trip is planned, and waits at its origin.
    a.advance(0.5);
    expect(a.liveVehicles, 0);
    expect(a.planner!.waiting, 20);

    final shortcut =
        commit(city, const FixtureRoad([Vec2(-400, 0), Vec2(400, 0)]));
    a.advance(0.5);
    expect(a.graphRev, 2);
    expect(a.stats.replans, 0, reason: 'no waiting route was made impossible');

    for (var i = 0; i < 240; i++) {
      if (trips.every((tr) => vehicleOfTrip(a, tr) >= 0)) break;
      a.advance(0.5);
    }
    final cars = [for (final tr in trips) vehicleOfTrip(a, tr)];
    expect(cars.every((h) => h >= 0), isTrue, reason: 'all 20 pulled out');
    final lg = a.laneGraph!;
    final tee = lg.graph.nodeNear(const Vec2(-400, 0))!.id;
    var through = 0;
    for (final h in cars) {
      final words = routeOf(a, h);
      expect(words.any((w) => w.startsWith(shortcut)), isFalse,
          reason: 'planned before the road: never onto it ($words)');
      if (_crosses(a, h, tee)) through++;
    }
    expect(through, greaterThan(0),
        reason: 'straight on through the new junction on W');
    expect(a.stats.replans, 0);
  });

  test('a waiting route the edit makes impossible is planned again from its '
      'origin, and counted', () {
    final city = _uTown();
    final a = _colonyAgents(city);
    final (origins, dests) = _ends(city);
    final trips = [
      for (var i = 0; i < 8; i++) forceTrip(a, origins[i % 4], dests[i % 2]),
    ];
    a.advance(0.5);
    expect(a.liveVehicles, 0);
    expect(a.planner!.waiting, 8);

    // One edit: the shortcut drawn, and S — which every waiting route
    // drives — taken up.
    final shortcut =
        commit(city, const FixtureRoad([Vec2(-400, 0), Vec2(400, 0)]));
    final south = city.layout.roads
        .firstWhere((r) => r.controls.every((p) => (p.n + 300).abs() < 1))
        .id;
    city.layout.removeRoad(south, regenerateLots: false);
    a.advance(0.5);
    expect(a.stats.replans, 8);

    for (var i = 0; i < 240; i++) {
      if (trips.every((tr) => vehicleOfTrip(a, tr) >= 0)) break;
      a.advance(0.5);
    }
    for (final tr in trips) {
      final h = vehicleOfTrip(a, tr);
      expect(h, greaterThanOrEqualTo(0));
      expect(routeOf(a, h).any((w) => w.startsWith(shortcut)), isTrue,
          reason: 'planned again on the new network: across the shortcut');
    }
  });
}

/// [city]'s own agents, switched on — so every lot-rename and clear hook
/// the colony fires (E12–E14) reaches them — but ticked by the test, not by
/// the colony.
CityAgents _colonyAgents(CitySim city) => city.agents..enabled = true;

/// The four home lots on O the scenario's trips leave from, and the two on
/// D they drive to.
(List<String>, List<String>) _ends(CitySim city) => (
      [
        for (final x in const [-500.0, -560.0, -620.0, -680.0])
          lotNearest(city, Vec2(x, 185)).id,
      ],
      [
        lotNearest(city, const Vec2(600, 185)).id,
        lotNearest(city, const Vec2(650, 215)).id,
      ],
    );

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

/// Whether the rest of [h]'s route runs through node [node].
bool _crosses(CityAgents a, int h, int node) {
  final t = a.vehicles!, lg = a.laneGraph!;
  final sl = h & 0xFFFFF;
  for (var i = t.routeCur[sl]; i < t.routeLen[sl] - 1; i++) {
    if (lg.edgeTo[lg.laneEdge[t.laneOfRouteEdge(sl, i)]] == node) return true;
  }
  return false;
}
