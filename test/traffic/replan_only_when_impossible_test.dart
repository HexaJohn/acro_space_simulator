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

/// §17.3 #4 (docs/plans/agent-traffic.md §3.9, §4.7): a route is planned
/// again only when a network edit made it impossible, and then exactly
/// once, from where the vehicle is. A road added elsewhere re-plans
/// nothing; a road removed ahead re-plans the vehicles that needed it, and
/// they still arrive; the road under a vehicle removed takes the vehicle
/// off; a one-way turned round ahead re-plans; and an end dragged in Adjust
/// Roads (`CitySim.moveRoadEnd`) re-lays a road, so the routes over it
/// re-plan — those still waiting to pull out among them — and nothing else
/// does.
///
/// The drag's cases run on the colony's own agents, so the lot hooks its
/// re-cut fires (E12–E14) reach them in the same poll as the rebuild, as
/// they reach the play surface's.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('an unrelated road: nothing re-plans, nothing is taken off, every '
      'trip arrives', () {
    final town = _ring();
    final a = agentsOn(town.city);
    final cars = _launch(a, town, 8);
    commit(town.city,
        const FixtureRoad([Vec2(3000, 3000), Vec2(3300, 3000)]));
    a.advance(0.5);
    expect(a.graphRev, 2);
    expect(a.stats.replans, 0);
    expect(a.stats.despawnEdit, 0);
    runAgents(a, 400);
    for (final h in cars) {
      expect(a.vehicles!.isLive(h), isFalse);
    }
    expect(a.stats.arrived, cars.length);
    expect(a.stats.replans, 0);
  });

  test('the road ahead removed: one re-plan for each car that needed it, and '
      'each arrives; the road under a car removed: it is taken off', () {
    final town = _ring();
    final a = agentsOn(town.city);
    final cars = _launch(a, town, 10);
    final split = _splitAtN(a, town, cars);
    town.city.layout.removeRoad(town.n, regenerateLots: false);
    final arrived = a.stats.arrived;
    a.advance(0.5);
    expect(a.stats.replans, split.before.length,
        reason: 'exactly one re-plan per car whose road ahead went');
    expect(a.stats.despawnEdit, split.on.length,
        reason: 'the cars on the road that went');
    for (final h in split.on) {
      expect(a.vehicles!.isLive(h), isFalse);
    }
    for (final h in split.before) {
      expect(a.vehicles!.isLive(h), isTrue);
      expect(routeOf(a, h).any((w) => w.startsWith(town.n)), isFalse);
    }
    runAgents(a, 500);
    for (final h in [...split.before, ...split.past]) {
      expect(a.vehicles!.isLive(h), isFalse, reason: 'arrived');
    }
    expect(a.stats.arrived - arrived, split.before.length + split.past.length);
    expect(a.stats.replans, split.before.length, reason: 're-planned once');
    expect(a.stats.despawnStuck + a.stats.despawnWedge, 0);
  });

  test('a one-way turned round ahead: the cars that needed it re-plan', () {
    final town = _ring(north: RoadClass.streetOneWay);
    final a = agentsOn(town.city);
    final cars = _launch(a, town, 10);
    final split = _splitAtN(a, town, cars);
    final onSpur = [
      for (final h in split.before)
        if (roadOf(a, h) == town.o) h,
    ];
    town.city.layout.reverseRoad(town.n);
    final arrived = a.stats.arrived;
    a.advance(0.5);
    expect(a.stats.replans, split.before.length);
    for (final h in split.on) {
      expect(a.vehicles!.isLive(h), isFalse,
          reason: 'turned round under it: taken off');
    }
    runAgents(a, 500);
    for (final h in [...onSpur, ...split.past]) {
      expect(a.vehicles!.isLive(h), isFalse, reason: 'arrived');
    }
    expect(a.stats.arrived - arrived,
        greaterThanOrEqualTo(onSpur.length + split.past.length));
  });

  test('(e) an end dragged re-lays a road on the route: the cars that needed '
      'it re-plan once and arrive, those on the stretch left in place '
      'staying on the road; the cars past it keep their routes', () {
    final town = _dragRing();
    final a = town.city.agents..enabled = true;
    // Three waves from O to D, 45 s apart: when the last is short of N the
    // one before it is on N and the first is past it.
    final cars = [
      ..._launch(a, town, 4),
      ...() {
        runAgents(a, 45);
        return _launch(a, town, 4);
      }(),
      ...() {
        runAgents(a, 45);
        return _launch(a, town, 4);
      }(),
    ];
    final split = _splitAtN(a, town, cars, withPast: true);
    final routes = {for (final h in split.past) h: routeOf(a, h)};

    // N's east end, dragged from its corner down E to y = 250: N is laid
    // again under a new id, the 600 m from W on the line it had, the rest
    // on a new line; the moved end cuts E and joins it there.
    final moved = town.city
        .moveRoadEnd(town.n, atStart: false, to: const Vec2(400, 250));
    expect(moved.roadId, isNotNull, reason: 'the drag was laid');
    final relaid = moved.roadId!;
    final arrived = a.stats.arrived;
    a.advance(0.2);
    expect(a.graphRev, greaterThanOrEqualTo(2));
    final t = a.vehicles!;
    final stayed = [
      for (final h in split.on)
        if (t.isLive(h)) h,
    ];
    final past = [
      for (final h in split.past)
        if (t.isLive(h)) h,
    ];
    expect(stayed, isNotEmpty,
        reason: 'a car on the stretch left in place stays on the road');
    expect(past, isNotEmpty);
    expect(a.stats.despawnEdit, split.on.length - stayed.length,
        reason: 'only a car on the moved stretch is taken off');
    expect(a.stats.replans, split.before.length + stayed.length,
        reason: 'exactly one re-plan for each car that needed N, and none '
            'for any other');
    for (final h in stayed) {
      expect(roadOf(a, h), startsWith(relaid),
          reason: 'on the road re-laid under it');
    }
    for (final h in past) {
      expect(routeDescends(routes[h]!, routeOf(a, h)), isTrue,
          reason: 'past N: the route it was planned, through E cut '
              '(${routes[h]} → ${routeOf(a, h)})');
    }

    runAgents(a, 500);
    for (final h in [...split.before, ...stayed, ...past]) {
      expect(t.isLive(h), isFalse, reason: 'arrived');
    }
    expect(a.stats.arrived - arrived,
        split.before.length + stayed.length + past.length);
    expect(a.stats.replans, split.before.length + stayed.length,
        reason: 're-planned once');
    expect(a.stats.despawnStuck + a.stats.despawnWedge, 0);
    expect(a.stats.arrivedGone, 0);
  });

  test('(e) a route still waiting to pull out when a drag re-lays a road on '
      'it is planned again from its origin, once, and driven by the road '
      're-laid', () {
    final town = _dragRing();
    final a = town.city.agents..enabled = true;
    final (origins, dests) = _ends(town.city);
    final trips = [
      for (var i = 0; i < 6; i++) forceTrip(a, origins[i % 4], dests[i % 2]),
    ];
    // Inside the spawn ramp's first half second no car pulls out: every
    // trip is planned by N, and waits at its origin.
    a.advance(0.5);
    expect(a.liveVehicles, 0);
    expect(a.planner!.waiting, 6);

    final relaid = town.city
        .moveRoadEnd(town.n, atStart: false, to: const Vec2(400, 250))
        .roadId!;
    a.advance(0.5);
    expect(a.stats.replans, 6, reason: 'each waiting route, once');

    for (var i = 0; i < 240; i++) {
      if (trips.every((tr) => vehicleOfTrip(a, tr) >= 0)) break;
      a.advance(0.5);
    }
    for (final tr in trips) {
      final h = vehicleOfTrip(a, tr);
      expect(h, greaterThanOrEqualTo(0), reason: 'it pulled out');
      expect(routeOf(a, h).any((w) => w.startsWith(relaid)), isTrue,
          reason: 'planned again on the network the drag made');
    }
    runAgents(a, 400);
    expect(a.liveVehicles, 0);
    expect(a.stats.arrived, 6);
    expect(a.stats.replans, 6);
    expect(a.stats.despawnEdit + a.stats.despawnStuck, 0);
  });
}

/// [_ring] for Adjust Roads: N laid with a jog — straight from W for
/// 300 m, then up 40 m and on to meet E at (400, 340) — so the layout keeps
/// its interior controls, and a drag of its east end re-lays the line past
/// the jog and leaves the 600 m from W where it was. Funded, so a drag is
/// never refused for its price.
({CitySim city, String n, String o}) _dragRing() {
  final city = foundFlat();
  commit(city, const FixtureRoad([Vec2(-400, -300), Vec2(-400, 300)]));
  commit(city, const FixtureRoad([Vec2(-400, -300), Vec2(400, -300)]));
  commit(city, const FixtureRoad([Vec2(400, -300), Vec2(400, 340)]));
  final n = commit(
      city,
      const FixtureRoad([
        Vec2(-400, 300),
        Vec2(-100, 300),
        Vec2(100, 340),
        Vec2(400, 340),
      ]));
  final o = commit(city, const FixtureRoad([Vec2(-400, 200), Vec2(-700, 200)]));
  commit(city, const FixtureRoad([Vec2(400, 200), Vec2(700, 200)]));
  zoneAll(city, const [ParcelUse.residential]);
  buildAll(city);
  city.funds = 1e9;
  return (city: city, n: n, o: o);
}

/// A ring town: streets W (x = −400), S (y = −300), E (x = 400) and N
/// (y = 300, of class [north]) round a block, and spurs O west off W and D
/// east off E at y = 200. From O to D the way is up W, along N and down E;
/// the way round by S is 800 m longer. Every lot is a home.
({CitySim city, String n, String o}) _ring(
    {RoadClass north = RoadClass.street}) {
  final city = foundFlat();
  commit(city, const FixtureRoad([Vec2(-400, -300), Vec2(-400, 300)]));
  commit(city, const FixtureRoad([Vec2(-400, -300), Vec2(400, -300)]));
  commit(city, const FixtureRoad([Vec2(400, -300), Vec2(400, 300)]));
  final n = commit(city,
      FixtureRoad(const [Vec2(-400, 300), Vec2(400, 300)], roadClass: north));
  final o = commit(city, const FixtureRoad([Vec2(-400, 200), Vec2(-700, 200)]));
  commit(city, const FixtureRoad([Vec2(400, 200), Vec2(700, 200)]));
  zoneAll(city, const [ParcelUse.residential]);
  buildAll(city);
  return (city: city, n: n, o: o);
}

/// The home lots on O the trips leave from, and the two on D they drive
/// to.
(List<String>, List<String>) _ends(CitySim city) => (
      [
        for (final x in const [-500.0, -560.0, -620.0, -680.0, -540.0])
          lotNearest(city, Vec2(x, x == -540.0 ? 215 : 185)).id,
      ],
      [
        lotNearest(city, const Vec2(600, 185)).id,
        lotNearest(city, const Vec2(650, 215)).id,
      ],
    );

/// [count] trips from homes on O to homes on D, pulled out; their vehicles.
List<int> _launch(
    CityAgents a, ({CitySim city, String n, String o}) town, int count) {
  final (origins, dests) = _ends(town.city);
  final trips = [
    for (var i = 0; i < count; i++)
      forceTrip(a, origins[i % origins.length], dests[i % 2]),
  ];
  for (var i = 0; i < 240; i++) {
    if (trips.every((tr) => vehicleOfTrip(a, tr) >= 0)) break;
    a.advance(0.5);
  }
  final cars = [for (final tr in trips) vehicleOfTrip(a, tr)];
  expect(cars.every((h) => h >= 0), isTrue, reason: 'every car pulled out');
  for (final h in cars) {
    expect(routeOf(a, h).any((w) => w.startsWith(town.n)), isTrue,
        reason: 'planned by N, the short way');
  }
  return cars;
}

/// Runs until some of [cars] are on N and some still have it ahead — and,
/// [withPast], some are past it and still driving; then which are on it,
/// which have it ahead, and which are past it.
({List<int> on, List<int> before, List<int> past}) _splitAtN(
    CityAgents a, ({CitySim city, String n, String o}) town, List<int> cars,
    {bool withPast = false}) {
  for (var i = 0; i < 400; i++) {
    final s = _split(a, town.n, cars);
    if (s.on.isNotEmpty &&
        s.before.isNotEmpty &&
        (!withPast || s.past.isNotEmpty)) {
      return s;
    }
    a.advance(0.2);
  }
  fail('never had cars both on N and short of it'
      '${withPast ? ', and past it' : ''}');
}

({List<int> on, List<int> before, List<int> past}) _split(
    CityAgents a, String n, List<int> cars) {
  final on = <int>[], before = <int>[], past = <int>[];
  for (final h in cars) {
    if (!a.vehicles!.isLive(h)) continue;
    final d = a.describe(h)!;
    final el = d['element']! as int;
    if (el >= a.laneGraph!.laneCount) return (on: [], before: [], past: []);
    final road = roadOf(a, h);
    if (road == n) {
      on.add(h);
    } else if (routeOf(a, h).any((w) => w.startsWith(n))) {
      before.add(h);
    } else {
      past.add(h);
    }
  }
  return (on: on, before: before, past: past);
}
