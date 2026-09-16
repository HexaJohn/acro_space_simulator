// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// §17.3 #1, `route_locked_despite_traffic` (docs/plans/agent-traffic.md
/// §4.6, §4.2): a route never changes for traffic — and the next trip,
/// planned once the jam has been measured, goes the other way. Congestion
/// is read at spawn (the user's decision 1), never by a trip already on the
/// road.
///
/// Two parallel routes join the spur O to the spur D ([_twoRoutes]): A,
/// short, by the avenue N; B, 800 m longer, by S. A car planned on A has
/// five edges and four connectors to keep, and a lane of two to keep on N,
/// so the test has something to catch. Its jam is in its OWN lane of N,
/// the other lane left empty, and it stands in the queue for a minute and
/// more — past where any rule that re-planned a waiting car, or moved it
/// into the free lane, would have acted. A re-plan from where it stands
/// would leave a shorter block than the planned one, so the hash would see
/// it; a move to the free lane would show in its lanes.
///
/// The whole scenario runs on [_nearRoutes], where B is dearer than A by
/// less than the jam: Y, planned at the first delay epoch after the jam
/// stands, is priced by it (§4.2's live queue) and takes B, while X, in the
/// jam, keeps A.
void main() {
  // No background demand: only the trips each test sends.
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('X, planned on A, stands a minute behind thirty cars stalled in its '
      'own lane of N with the other lane free, keeps its route and its lane '
      'on every edge, and arrives when they clear', () {
    final city = _twoRoutes();
    final a = agentsOn(city);
    // The spawn ramp done, so cars pull out as fast as there is room.
    runAgents(a, AgentTuning.warmupS + 1);
    final (origins, dests) = _ends(city);

    // X, planned on A while A is empty.
    final xh = _pullOut(a, [forceTrip(a, origins[3], dests[0])]).single;
    final t = a.vehicles!, lg = a.laneGraph!;
    final xs = SlotPool.slotOf(xh);
    final hash = routeHash(a, xh);
    final planned = routeOf(a, xh);
    expect(t.routeLen[xs], 5, reason: 'O, W, N, E and D: four connectors');
    final n = _avenueOf(city, planned);
    final nEdge = _edgeOfRoad(a, xh, n);
    expect(lg.edgeLaneCount[nEdge], 2, reason: 'a lane of two on N');
    final xLane = laneOn(a, xh, n);
    final free = lg.laneOf(nEdge, 1 - xLane);

    // Then thirty cars from the homes along N's south side to D, every one
    // turning right onto E from X's lane, each stalled once it is a car's
    // length on from where it pulled out, or has come to rest behind one
    // that was: thirty cars standing ahead of X in X's lane of N.
    final lots = _lotsOnN(city);
    final jam = [
      for (var i = 0; i < 30; i++)
        forceTrip(a, lots[i % lots.length], dests[i % 2]),
    ];
    for (final tr in jam) {
      expect(tr, greaterThanOrEqualTo(0), reason: 'the trip was taken');
    }

    final arrived = a.stats.arrived;
    final stalled = <int>{};
    var queuedUs = 0;
    var released = false;
    var ticks = 0;
    while (t.isLive(xh)) {
      expect(routeHash(a, xh), hash, reason: 'its connectors, at ${a.timeUs}');
      final now = routeOf(a, xh);
      expect(now, planned.sublist(planned.length - now.length),
          reason: 'its lanes, at ${a.timeUs}');
      if (!released) {
        for (final tr in jam) {
          final h = vehicleOfTrip(a, tr);
          if (h < 0 || stalled.contains(h)) continue;
          final s = _onEdgeAt(a, h, nEdge);
          expect(s, greaterThanOrEqualTo(0), reason: 'it pulled out onto N');
          final sl = SlotPool.slotOf(h);
          final odo = t.odo[sl];
          if (odo >= _stallAfterM || (odo > 0.5 && t.v[sl] < 0.1)) {
            expect(laneOn(a, h, n), xLane, reason: 'in X\'s own lane');
            expect(_onEdgeAt(a, xh, nEdge), lessThan(s),
                reason: 'ahead of X');
            stall(a, h);
            stalled.add(h);
          }
        }
        if (stalled.length == jam.length &&
            _onEdgeAt(a, xh, nEdge) >= 0 &&
            t.v[xs] < 0.1) {
          queuedUs += kStepUs;
          expect(t.elemCount[free], 0, reason: 'the other lane of N is free');
        }
        if (queuedUs >= _queuedUs) {
          for (final h in jam) {
            unstall(a, h);
          }
          released = true;
        }
      }
      a.advance(kStepS);
      expect(++ticks, lessThan(3000), reason: 'X should have arrived');
    }
    expect(released, isTrue, reason: 'X stood a minute behind the jam');
    expect(a.stats.despawnStuck + a.stats.despawnWedge, 0);
    expect(a.stats.replans, 0);
    // From T4a every arrival appends a parking leg (D17 step 2), so what
    // is pinned here is that the EDIT appended none: no re-plan, and no
    // re-target of a destination that moved under the car.
    expect(a.stats.arrivedGone, 0);
    expect(a.siteStats.siteRetargets, 0);

    // The thirty, set going again, arrive too — X among them.
    runAgents(a, 300);
    for (final h in stalled) {
      expect(t.isLive(h), isFalse);
    }
    expect(a.stats.arrived - arrived, 31);
    expect(a.stats.despawnStuck + a.stats.despawnWedge, 0);
    expect(a.stats.replans, 0);
  });

  test('§17.3 #1 in full: X, planned on A before the jam, keeps its route '
      'and lanes through it; Y, planned after the next delay epoch, takes B',
      () {
    // Y's own trip, on a free network: by A, like X. What sends it by B is
    // the jam, and nothing else.
    final free = _nearRoutes();
    final f = agentsOn(free);
    runAgents(f, AgentTuning.warmupS + 1);
    final (fo, fd) = _ends(free);
    final unjammed = routeOf(f, _pullOut(f, [forceTrip(f, fo[2], fd[1])]).single);
    expect(_southOf(free, unjammed), isNull, reason: 'free, Y goes by A');
    _avenueOf(free, unjammed);

    final city = _nearRoutes();
    final a = agentsOn(city);
    runAgents(a, AgentTuning.warmupS + 1);
    final (origins, dests) = _ends(city);
    final t = a.vehicles!;

    // X, planned on A while A is empty: nothing measured, D = 0 everywhere.
    final xTrip = forceTrip(a, origins[3], dests[0]);
    final xh = _pullOut(a, [xTrip]).single;
    final xs = SlotPool.slotOf(xh);
    final hash = routeHash(a, xh);
    final planned = routeOf(a, xh);
    final n = _avenueOf(city, planned);
    final nEdge = _edgeOfRoad(a, xh, n);
    final xLane = laneOn(a, xh, n);
    expect(_southOf(city, planned), isNull, reason: 'X is on A, not B');

    final lots = _lotsOnN(city);
    final jam = [
      for (var i = 0; i < 30; i++)
        forceTrip(a, lots[i % lots.length], dests[i % 2]),
    ];
    for (final tr in jam) {
      expect(tr, greaterThanOrEqualTo(0), reason: 'the trip was taken');
    }

    final epochUs = usOf(AgentTuning.congestionEpochS);
    final stalled = <int>{};
    var standing = false;
    var yTrip = -1;
    var yh = -1;
    var yRoute = const <String>[];
    var priced = 0.0;
    var queuedUs = 0;
    var released = false;
    var ticks = 0;
    while (t.isLive(xh)) {
      expect(routeHash(a, xh), hash, reason: 'its connectors, at ${a.timeUs}');
      final now = routeOf(a, xh);
      expect(now, planned.sublist(planned.length - now.length),
          reason: 'its lanes, at ${a.timeUs}');
      if (!released) {
        for (final tr in jam) {
          final h = vehicleOfTrip(a, tr);
          if (h < 0 || stalled.contains(h)) continue;
          final sl = SlotPool.slotOf(h);
          final odo = t.odo[sl];
          if (odo >= _stallAfterM || (odo > 0.5 && t.v[sl] < 0.1)) {
            expect(laneOn(a, h, n), xLane, reason: 'in X\'s own lane');
            stall(a, h);
            stalled.add(h);
          }
        }
        standing = standing ||
            (stalled.length == jam.length &&
                _onEdgeAt(a, xh, nEdge) >= 0 &&
                t.v[xs] < 0.1);
        // The first delay epoch with the jam standing has just published:
        // Y is asked for now, and priced by it.
        if (standing && yTrip < 0 && a.timeUs % epochUs == 0) {
          priced = a.pathQueue!.delays![nEdge];
          yTrip = forceTrip(a, origins[2], dests[1]);
          expect(yTrip, greaterThanOrEqualTo(0));
        }
        if (yTrip >= 0 && yh < 0) {
          yh = vehicleOfTrip(a, yTrip);
          if (yh >= 0) yRoute = routeOf(a, yh);
        }
        if (yh >= 0) queuedUs += kStepUs;
        if (queuedUs >= usOf(20)) {
          for (final h in jam) {
            unstall(a, h);
          }
          released = true;
        }
      }
      a.advance(kStepS);
      expect(++ticks, lessThan(4000), reason: 'X should have arrived');
    }
    expect(released, isTrue, reason: 'Y pulled out while X stood in the jam');
    expect(priced, greaterThan(20),
        reason: 'thirty cars standing on N: its live queue');

    expect(yRoute, isNotEmpty, reason: 'Y pulled out');
    for (final w in yRoute) {
      final road = city.layout.roadById(w.substring(0, w.length - 2));
      expect(road?.roadClass, isNot(RoadClass.avenue),
          reason: 'Y avoids the jammed avenue: $yRoute');
    }
    expect(_southOf(city, yRoute), isNotNull, reason: 'Y takes B: $yRoute');
    expect(a.stats.replans, 0);
    // From T4a every arrival appends a parking leg (D17 step 2), so what
    // is pinned here is that the EDIT appended none: no re-plan, and no
    // re-target of a destination that moved under the car.
    expect(a.stats.arrivedGone, 0);
    expect(a.siteStats.siteRetargets, 0);
    expect(a.stats.despawnStuck + a.stats.despawnWedge, 0);
  });

  test('Z, behind a car stalled for good in its own lane of N, keeps its '
      'route and lanes until the stuck timer takes it: no re-plan', () {
    final city = _twoRoutes();
    final a = agentsOn(city);
    runAgents(a, AgentTuning.warmupS + 1);
    final (origins, dests) = _ends(city);
    final t = a.vehicles!, lg = a.laneGraph!;

    // B stops for good 300 m along N.
    final bh = _pullOut(a, [forceTrip(a, origins[1], dests[1])]).single;
    final n = _avenueOf(city, routeOf(a, bh));
    final nEdge = _edgeOfRoad(a, bh, n);
    for (var i = 0; _onEdgeAt(a, bh, nEdge) < 300; i++) {
      expect(i, lessThan(1000), reason: 'B should have reached N');
      a.advance(kStepS);
    }
    stall(a, bh);

    final zh = _pullOut(a, [forceTrip(a, origins[0], dests[0])]).single;
    final zs = SlotPool.slotOf(zh);
    expect(t.routeLen[zs], 5);
    expect(laneOn(a, zh, n), laneOn(a, bh, n), reason: 'B is in its lane');
    final free = lg.laneOf(nEdge, 1 - laneOn(a, zh, n));
    final hash = routeHash(a, zh);
    final planned = routeOf(a, zh);
    var ticks = 0;
    while (t.isLive(zh)) {
      expect(routeHash(a, zh), hash, reason: 'at ${a.timeUs}');
      final now = routeOf(a, zh);
      expect(now, planned.sublist(planned.length - now.length),
          reason: 'its lanes, at ${a.timeUs}');
      expect(t.elemCount[free], 0, reason: 'the other lane of N is free');
      a.advance(kStepS);
      expect(++ticks, lessThan(3000), reason: 'Z should have been taken off');
    }
    expect(a.stats.despawnStuck, 1, reason: 'Z, and only Z');
    expect(a.stats.replans, 0);
    expect(t.isLive(bh), isTrue, reason: 'a stalled car dwells');
  });
}

/// How far a car of the jam drives from where it pulled out before it
/// stalls: past its own driveway, so the next car out of that lot has
/// room to pull out behind it.
const double _stallAfterM = 8;

/// How long X stands in the jam before it clears: a minute, past any rule
/// that acts on a car kept waiting, and short of the stuck timer.
final int _queuedUs = usOf(60);

/// Streets W (x = −400), S (y = −300) and E (x = 400) round a block, the
/// avenue N (y = 300) along its north side and on east past E, so E meets
/// it at a tee, and spurs O west off W and D east off E at y = 200. From O
/// to D, A runs up W, along N — two lanes each way — and down E, turning
/// right onto E from N's kerb lane; B runs down W, along S and up E, 800 m
/// longer. Every lot is a home.
CitySim _twoRoutes() {
  final city = foundFlat(roads: const [
    FixtureRoad([Vec2(-400, 300), Vec2(700, 300)], roadClass: RoadClass.avenue),
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

/// [_twoRoutes] with S drawn at y = 0 instead of −300, the spurs still at
/// y = 200 between it and N: B is then 200 m longer than A, and on streets
/// where A has the avenue — 16 s dearer by §4.1's prices, where it was 34 s
/// on [_twoRoutes]. Thirty cars standing in one lane of N, a 29 s live
/// queue, outweigh that.
CitySim _nearRoutes() {
  final city = foundFlat(roads: const [
    FixtureRoad([Vec2(-400, 300), Vec2(700, 300)], roadClass: RoadClass.avenue),
    FixtureRoad([Vec2(-400, 0), Vec2(-400, 300)]),
    FixtureRoad([Vec2(-400, 0), Vec2(400, 0)]),
    FixtureRoad([Vec2(400, 0), Vec2(400, 300)]),
    FixtureRoad([Vec2(-400, 200), Vec2(-700, 200)]),
    FixtureRoad([Vec2(400, 200), Vec2(700, 200)]),
  ]);
  zoneAll(city, const [ParcelUse.residential]);
  buildAll(city);
  return city;
}

/// The road of route [words] (in [routeOf]'s words) that runs along S at
/// y = 0 — B's own street — or null when the route does not use it.
String? _southOf(CitySim city, List<String> words) {
  for (final w in words) {
    final id = w.substring(0, w.length - 2);
    final road = city.layout.roadById(id);
    if (road == null) continue;
    if (road.controls.every((c) => c.n.abs() < 1)) return id;
  }
  return null;
}

/// The four home lots on O the trips leave from, and the two on D they
/// drive to.
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

/// The home lots along N's south side between W and E — on the right of
/// travel east, so a car from one pulls out into N's kerb lane — west to
/// east.
List<String> _lotsOnN(CitySim city) {
  final lots = [
    for (final p in city.layout.autoParcels)
      if (p.centroid.n > 230 &&
          p.centroid.n < 300 &&
          p.centroid.e > -370 &&
          p.centroid.e < 370)
        p,
  ]..sort((p, q) => p.centroid.e.compareTo(q.centroid.e));
  expect(lots.length, greaterThanOrEqualTo(15),
      reason: 'N is lined with lots, two cars to each');
  return [for (final p in lots) p.id];
}

/// The avenue among the roads of route [words] (in [routeOf]'s words).
String _avenueOf(CitySim city, List<String> words) {
  for (final w in words) {
    final id = w.substring(0, w.length - 2);
    if (city.layout.roadById(id)?.roadClass == RoadClass.avenue) return id;
  }
  fail('the route $words runs on no avenue');
}

/// The lane-graph edge [h]'s route drives on road [roadId].
int _edgeOfRoad(CityAgents a, int h, String roadId) {
  final t = a.vehicles!, lg = a.laneGraph!;
  final sl = SlotPool.slotOf(h);
  for (var i = t.routeCur[sl]; i < t.routeLen[sl]; i++) {
    final e = lg.laneEdge[t.laneOfRouteEdge(sl, i)];
    if (lg.graph.roads[lg.edgeRoad[e]].id == roadId) return e;
  }
  fail('its route does not drive $roadId');
}

/// How far [h] is along its lane of [edge], or −1 when it is not on one.
double _onEdgeAt(CityAgents a, int h, int edge) {
  final t = a.vehicles!, lg = a.laneGraph!;
  if (!t.isLive(h)) return -1;
  final sl = SlotPool.slotOf(h);
  final el = t.elem[sl];
  if (el < 0 || el >= lg.laneCount || lg.laneEdge[el] != edge) return -1;
  return t.s[sl].toDouble();
}

/// Advances [a] a sub-step at a time until every one of [trips] has pulled
/// out; their vehicles, in order.
List<int> _pullOut(CityAgents a, List<int> trips) {
  for (final tr in trips) {
    expect(tr, greaterThanOrEqualTo(0), reason: 'the trip was taken');
  }
  for (var i = 0; i < 1500; i++) {
    final cars = [for (final tr in trips) vehicleOfTrip(a, tr)];
    if (cars.every((h) => h >= 0)) return cars;
    a.advance(kStepS);
  }
  fail('the trips never all pulled out');
}
