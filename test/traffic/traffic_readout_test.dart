// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/traffic_readout.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_traffic_readout.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The traffic readout's contract, slice 1's half (docs/plans/
/// agent-traffic.md §12.3, D46, D47; §17.1 traffic_readout_test): before a
/// picture it punishes nothing; pictures come every congestion epoch and
/// never go back, not even across the colony's switch to the agents and
/// back; the routes through a road are the locked routes of the vehicles
/// driving it; and reach, noise, land value and the tax factor are the
/// routed model's, answer for answer.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0.004);
  tearDown(AgentTuning.reset);

  test('before the first picture the readout punishes nothing', () {
    final city = town();
    final a = agentsOn(city)..advance(0.02);
    final r = a.readout;
    expect(r.hasRun, isFalse);
    expect(r.passes, city.roadTraffic.passes,
        reason: 'no picture of ours yet: the routed count the colony '
            'answered with, never less');
    expect(r.peakCongestion, 0);
    expect(r.averageCongestion, 0);
    for (final road in city.layout.roads) {
      expect(r.congestionOf(road.id), 0);
      expect(r.volumeOf(road.id), 0);
      expect(r.routesThrough(road.id), isEmpty);
    }
    for (final lot in city.layout.autoParcels) {
      expect(r.serviceReach(lot.id), isTrue);
      expect(r.fireReach(lot.id), isTrue);
      expect(r.deliveryReach(lot.id), isTrue);
      expect(r.noiseOf(lot.id), 0);
    }
    expect(r.taxLandValueFactor, 1.0);
  });

  test('a picture every congestion epoch from the first, and the count never '
      'goes back', () {
    final a = agentsOn(town());
    final r = a.readout;
    var prevT = a.timeUs, prevP = 0;
    for (var i = 0; i < 600; i++) {
      a.advance(0.5);
      final t = a.timeUs, p = r.passes;
      expect(p, greaterThanOrEqualTo(prevP));
      if (prevP > 0) {
        expect(p - prevP, t ~/ 2000000 - prevT ~/ 2000000,
            reason: 'one picture per 2 s of agent time');
      }
      expect(r.hasRun, p > 0);
      prevT = t;
      prevP = p;
    }
    expect(r.hasRun, isTrue);
    expect(r.peakCongestion, inInclusiveRange(0.0, 1.0));
    expect(r.averageCongestion, a.stats.congestionIndex,
        reason: 'the network index, as the last picture took it');
    var busy = 0;
    for (final road in a.city.layout.roads) {
      expect(r.congestionOf(road.id), inInclusiveRange(0.0, r.peakCongestion));
      if (r.volumeOf(road.id) > 0) busy++;
    }
    expect(busy, greaterThan(0), reason: 'vehicles went through some road');
  });

  test('the routes through a road are the locked routes of the vehicles '
      'driving it now', () {
    final a = agentsOn(town());
    runAgents(a, 150);
    final t = a.vehicles!, lg = a.laneGraph!;
    var sl = 0;
    while (!t.isSlotLive(sl) || t.elem[sl] >= lg.laneCount) {
      sl++;
    }
    final road = lg.graph.roads[lg.edgeRoad[lg.laneEdge[t.elem[sl]]]].id;
    var users = 0;
    for (var s = 0; s < t.highWater; s++) {
      if (!t.isSlotLive(s)) continue;
      for (var i = 0; i < t.routeLen[s]; i++) {
        final e = lg.laneEdge[t.laneOfRouteEdge(s, i)];
        if (lg.graph.roads[lg.edgeRoad[e]].id == road) {
          users++;
          break;
        }
      }
    }
    final routes = a.readout.routesThrough(road);
    expect(routes.length, math.min(users, 64));
    for (final tr in routes) {
      expect(tr.kind, TripKind.commuter, reason: 'commutes, both ways');
      expect(tr.weight, 1);
      expect(tr.roadIds, contains(road));
      for (var i = 1; i < tr.roadIds.length; i++) {
        expect(tr.roadIds[i], isNot(tr.roadIds[i - 1]),
            reason: 'each road once per visit');
      }
      expect(tr.polyline.length, greaterThanOrEqualTo(2));
    }
    expect(a.readout.routesThrough(road, kinds: {TripKind.goods}), isEmpty);
    expect(a.readout.routesThrough(road, kinds: {TripKind.commuter}).length,
        routes.length);
    expect(a.readout.routesThrough(road, limit: 1), hasLength(1));
    expect(a.readout.routesThrough('no-such-road'), isEmpty);
  });

  test('reach, noise, land value and the tax factor are the routed model\'s, '
      'answer for answer', () {
    final city = town();
    final a = agentsOn(city);
    for (var i = 0; i < 400; i++) {
      city.roadTraffic.advance(0.5);
      a.advance(0.5);
    }
    final r = a.readout, m = city.roadTraffic;
    expect(m.hasRun, isTrue, reason: 'the routed model has a picture too');
    for (final lot in city.layout.autoParcels) {
      expect(r.serviceReach(lot.id), m.serviceReach(lot.id));
      expect(r.fireReach(lot.id), m.fireReach(lot.id));
      expect(r.deliveryReach(lot.id), m.deliveryReach(lot.id));
      expect(r.noiseOf(lot.id), m.noiseOf(lot.id));
      expect(r.landValueOf(lot.id), m.landValueOf(lot.id));
    }
    expect(r.averageLandValue, m.averageLandValue);
    expect(r.taxLandValueFactor, m.taxLandValueFactor);
  });

  test('fire reach is the routed model\'s fire reach, not its service reach; '
      'passes count its pictures with ours, and never go back', () {
    final a = agentsOn(town());
    final routed = _Routed()..passes = 5;
    final r = AgentTrafficReadout(a, routed);
    final lot = a.city.layout.autoParcels.first.id;
    expect(r.serviceReach(lot), isTrue);
    expect(r.fireReach(lot), isFalse,
        reason: 'an ambulance reaching a lot is no fire cover there');

    expect(r.passes, 5,
        reason: 'no picture of ours yet: the routed count, so the switch to '
            'the agents takes no view\'s key back');
    runAgents(a, 60);
    final own = a.pictures;
    expect(own, greaterThan(0));
    expect(r.passes, own + 5);
    routed.passes = 6;
    expect(r.passes, own + 6,
        reason: 'the forwarded answers moved, so a view must redraw');

    // Off and on again: the tables start afresh, and the count stands.
    a.enabled = false;
    a.enabled = true;
    expect(r.hasRun, isFalse);
    expect(r.passes, own + 6);
  });

  test('a town no car has driven still publishes pictures, so the Routes view '
      'is never left waiting for the first car', () {
    // The starter kit as founded, nothing zoned: ticked through the colony's
    // own advance, as the running game ticks it.
    final city = starterKit(agentTraffic: true);
    final r = city.trafficReadout;
    expect(identical(r, city.agents.readout), isTrue);
    for (var i = 0; i < 20 && !r.hasRun; i++) {
      city.advance(0.5);
    }
    expect(r.hasRun, isTrue,
        reason: 'a picture at the first congestion epoch, cars or no cars');
    expect(r.passes, greaterThan(city.roadTraffic.passes));
    if (city.agents.stats.spawned == 0) {
      expect(r.peakCongestion, 0, reason: 'an empty picture punishes nothing');
      expect(r.averageCongestion, 0);
      for (final road in city.layout.roads) {
        expect(r.congestionOf(road.id), 0);
        expect(r.routesThrough(road.id), isEmpty);
      }
    }
  });

  test('the colony\'s count never goes back across the switch to the agents '
      'and back again (D47, E37)', () {
    final city = town();
    for (var i = 0; i < 40; i++) {
      city.roadTraffic.advance(0.5);
    }
    expect(identical(city.trafficReadout, city.roadTraffic), isTrue,
        reason: 'no agents yet: the routed model answers');
    final before = city.trafficReadout.passes;

    city.agents.enabled = true;
    expect(identical(city.trafficReadout, city.agents.readout), isTrue);
    expect(city.trafficReadout.passes, greaterThanOrEqualTo(before),
        reason: 'the switch to the agents takes no view\'s key back');
    runAgents(city.agents, 60);
    final on = city.trafficReadout.passes;
    expect(on, greaterThan(before));

    city.agents.enabled = false;
    expect(identical(city.trafficReadout, city.agents.readout), isTrue,
        reason: 'once they have published, the colony answers through them');
    expect(city.trafficReadout.passes, greaterThanOrEqualTo(on),
        reason: 'nor does the switch back');
    final r = city.trafficReadout, m = city.roadTraffic;
    expect(r.hasRun, m.hasRun,
        reason: 'switched off, every answer is the routed model\'s');
    expect(r.peakCongestion, m.peakCongestion);
    expect(r.averageCongestion, m.averageCongestion);
    for (final road in city.layout.roads) {
      expect(r.congestionOf(road.id), m.congestionOf(road.id));
      expect(r.volumeOf(road.id), m.volumeOf(road.id));
    }
  });
}

/// A routed model that tells fire reach from service reach, with a pass
/// count the test moves by hand.
class _Routed implements CityTrafficReadout {
  @override
  int passes = 0;

  @override
  bool get hasRun => true;

  @override
  double get peakCongestion => 0;

  @override
  double get averageCongestion => 0;

  @override
  double congestionOf(String roadId) => 0;

  @override
  double volumeOf(String roadId) => 0;

  @override
  List<TripRoute> routesThrough(String roadId,
          {Set<TripKind>? kinds, int limit = 64}) =>
      const [];

  @override
  bool serviceReach(String lotId) => true;

  @override
  bool fireReach(String lotId) => false;

  @override
  bool deliveryReach(String lotId) => true;

  @override
  double noiseOf(String lotId) => 0;

  @override
  double landValueOf(String lotId) => 0.5;

  @override
  double get averageLandValue => 0.5;

  @override
  double get taxLandValueFactor => 1;
}
