// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// §17.3 #2, `faster_slightly_longer_preferred` (docs/plans/agent-traffic.md
/// §4.1, §4.2, §4.6), in a colony, with the delay table frozen at 0
/// (`freezeDelays`) so the arithmetic holds:
///
/// - a 1,000 m street at 40 km/h costs 90 s × 1.00 = 90.0 s;
/// - an avenue some 15% longer at 50 km/h costs about 82.8 s × 0.97, 80 s;
/// - the junction penalties are equal — lights at both ends, both ways
///   straight on — so a new trip takes the avenue.
///
/// Then `setDelay` puts 20 s on the avenue, which makes it dearer than the
/// street: NEW trips take the street, and a trip planned before stays on the
/// avenue, its route and lanes untouched, to its stop.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('the faster, slightly longer avenue is taken; 20 s set on it sends '
      'new trips by the street, and the trip already on it stays', () {
    final city = _twoWays();
    final a = agentsOn(city);
    runAgents(a, AgentTuning.warmupS + 1);
    a.freezeDelays();
    final lg = a.laneGraph!;
    final pub = a.delays!.published!;
    expect(a.pathQueue!.delays, same(pub));
    for (var e = 0; e < pub.length; e++) {
      expect(pub[e], 0, reason: 'frozen at 0');
    }

    final st = _edgeAlong(a, _streetId), av = _edgeAlong(a, _avenueId);
    expect(lg.kindOf(lg.edgeFrom[st]), NodeControlKind.signals);
    expect(lg.kindOf(lg.edgeTo[st]), NodeControlKind.signals);
    expect(lg.edgeFrom[av], lg.edgeFrom[st]);
    expect(lg.edgeTo[av], lg.edgeTo[st]);
    final cost = RouteCost(lg);
    expect(lg.edgeLen[st], closeTo(1000, 0.5));
    expect(cost.edgeTime[st], closeTo(90.0, 0.1));
    expect(lg.edgeLen[av] / lg.edgeLen[st], inInclusiveRange(1.10, 1.20));
    expect(cost.edgeTime[av], lessThan(cost.edgeTime[st] - 5));
    expect(cost.edgeTime[av] + 20, greaterThan(cost.edgeTime[st]),
        reason: '20 s makes the avenue the dearer way');

    final from = lotNearest(city, const Vec2(-100, -20)).id;
    final to = lotNearest(city, const Vec2(1100, -20)).id;

    // X, planned while nothing is measured: by the avenue.
    final xh = _pullOut(a, forceTrip(a, from, to));
    final planned = routeOf(a, xh);
    expect(_uses(planned, _avenueId), isTrue, reason: '$planned');
    expect(_uses(planned, _streetId), isFalse, reason: '$planned');
    final hash = routeHash(a, xh);

    // 20 s on the avenue, published at once.
    a.setDelay(av, 20);
    expect(a.delays!.published![av], 20);
    expect(a.pathQueue!.delays![av], 20);

    // Y, planned now: by the street.
    final to2 = lotNearest(city, const Vec2(1150, -20)).id;
    final yh = _pullOut(a, forceTrip(a, from, to2), each: () {
      expect(routeHash(a, xh), hash, reason: 'X, at ${a.timeUs}');
    });
    final yRoute = routeOf(a, yh);
    expect(_uses(yRoute, _streetId), isTrue, reason: '$yRoute');
    expect(_uses(yRoute, _avenueId), isFalse, reason: '$yRoute');

    // X keeps the avenue, its connectors and its lanes, to its stop; the
    // pinned delay stands through every epoch meanwhile.
    // From T4a a car keeps its vehicle row past its arrival while it parks
    // (§7.3 D17): the locked route is pinned to the arrival, which is where
    // the trip it was planned for ends.
    final arrived = a.stats.arrived;
    var ticks = 0;
    while (a.vehicles!.isLive(xh) && a.stats.arrived == arrived) {
      expect(routeHash(a, xh), hash, reason: 'X, at ${a.timeUs}');
      final now = routeOf(a, xh);
      expect(now, planned.sublist(planned.length - now.length),
          reason: 'its lanes, at ${a.timeUs}');
      a.advance(kStepS);
      expect(a.pathQueue!.delays![av], 20);
      expect(++ticks, lessThan(2000), reason: 'X should have arrived');
    }
    expect(a.stats.arrived, greaterThan(arrived));
    expect(a.stats.replans, 0);
    expect(a.stats.arrivedGone, 0);
    // What legs are appended here are the parking legs D17 step 2 adds on
    // arrival (T4a): never a re-plan, never a re-target.
    expect(a.siteStats.siteRetargets, 0);
    expect(a.stats.despawnStuck + a.stats.despawnWedge, 0);
  });
}

const String _inId = 'in', _streetId = 'st', _avenueId = 'av', _outId = 'out';

/// From the spur `in` (x = −200 to 0) to the spur `out` (1,000 to 1,200)
/// along y = 0, two ways: the street `st` straight across, and the avenue
/// `av` bowed some 270 m to the north, leaving and arriving within 30° of
/// straight on — both junctions lit, so the junction penalties are equal
/// and the roads alone decide. Every lot a home.
CitySim _twoWays() {
  final city = foundFlat();
  final ids = <String, String>{};
  void road(String name, List<Vec2> pts, [RoadClass cls = RoadClass.street]) =>
      ids[name] = commit(city, FixtureRoad(pts, roadClass: cls));
  road(_streetId, const [Vec2(0, 0), Vec2(1000, 0)]);
  road(_inId, const [Vec2(-200, 0), Vec2(0, 0)]);
  road(_outId, const [Vec2(1000, 0), Vec2(1200, 0)]);
  road(
      _avenueId,
      const [
        Vec2(0, 0),
        Vec2(100, 25),
        Vec2(500, 272),
        Vec2(900, 25),
        Vec2(1000, 0),
      ],
      RoadClass.avenue);
  city.setJunctionOverride(const JunctionOverride(at: Vec2(0, 0), lights: true));
  city.setJunctionOverride(
      const JunctionOverride(at: Vec2(1000, 0), lights: true));
  zoneAll(city, const [ParcelUse.residential]);
  buildAll(city);
  _roadIds = ids;
  return city;
}

/// The colony road ids [_twoWays] committed, by name.
Map<String, String> _roadIds = const {};

/// The edge of the road named [name] running from x = 0 to x = 1,000.
int _edgeAlong(CityAgents a, String name) {
  final lg = a.laneGraph!;
  final id = _roadIds[name]!;
  for (var e = 0; e < lg.roadEdgeCount; e++) {
    if (lg.graph.roads[lg.edgeRoad[e]].id != id) continue;
    final from = lg.graph.nodes[lg.edgeFrom[e]].at;
    if (from.e.abs() < 1) return e;
  }
  fail('no edge of $name leaves x = 0');
}

/// Whether route [words] (in `routeOf`'s words) drives the road named
/// [name].
bool _uses(List<String> words, String name) {
  final id = _roadIds[name]!;
  for (final w in words) {
    if (w.substring(0, w.length - 2) == id) return true;
  }
  return false;
}

/// Advances [a] a sub-step at a time — calling [each] after every one —
/// until [trip] has pulled out; its vehicle.
int _pullOut(CityAgents a, int trip, {void Function()? each}) {
  expect(trip, greaterThanOrEqualTo(0), reason: 'the trip was taken');
  for (var i = 0; i < 1500; i++) {
    final h = vehicleOfTrip(a, trip);
    if (h >= 0) return h;
    a.advance(kStepS);
    each?.call();
  }
  fail('the trip never pulled out');
}
