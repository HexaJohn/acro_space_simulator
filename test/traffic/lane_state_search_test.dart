// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_connectors.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_state_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/path_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_fixture.dart';

/// Plans from the lane a vehicle is already in (docs/plans/agent-traffic.md
/// §4.5, D34; §17.1 lane_state_search_test; §17.2 fixed-start
/// feasibility): the search moves only along real connectors, so whatever
/// it returns can be driven, and it never returns a turn the lane cannot
/// make.
void main() {
  test('the avenue example: held in lane 0 with a left three nodes on, it '
      'shifts into lane 1 at a junction and makes the left from there', () {
    final lg = lanesOf(avenueTown(RoadClass.avenue));
    final cost = RouteCost(lg);
    final start = edgeOf(lg, 'r4x1'), goal = edgeOf(lg, 'r3x1');
    final ends = PathEnds()
      ..addOrigin(start, 50, lane: lg.laneOf(start, 0))
      ..addGoal(goal, 100, laneMask: 1);
    final search = LaneStateSearch()..begin(cost, ends);
    expect(search.step(1 << 30), SearchStatus.found);
    final route = search.route.sublist(0, search.routeLength);
    expectDrivable(lg, route);
    expect(route.first, lg.laneOf(start, 0));
    expect(lanesAlong(lg, route).last, lg.laneOf(goal, 0));
    // East along the avenue, two junctions straight on, then the left.
    expect(edgesAlong(lg, route),
        [start, edgeOf(lg, 'r4x2'), edgeOf(lg, 'r4x3'), goal]);
    var shifts = 0;
    for (var i = 1; i < route.length; i++) {
      if (lg.connectorKindOf(route[i]) == ConnectorKind.shift) shifts++;
    }
    expect(shifts, 1, reason: 'one lane change, at a junction');
    expect(lg.turnOf(route.last), TurnClass.left);
    expect(lg.laneIdx[lg.conFromLane[route.last]], 1);
  });

  test('a fixed-lane re-plan never returns the left its lane cannot make at '
      'the very first node', () {
    final lg = lanesOf(avenueTown(RoadClass.avenue));
    final cost = RouteCost(lg);
    final start = edgeOf(lg, 'r4x1'), goal = edgeOf(lg, 'r1x1');
    // A new trip, free to pick its lane, would turn left at once — from
    // lane 1.
    final free = planTrip(lg, start, 150, goal, 100, destMask: 1)!;
    expect(describe(lg, free.route), ['r4x1+1', 'r1x1+0']);
    // Held in lane 0 it cannot, and does not.
    final ends = PathEnds()
      ..addOrigin(start, 150, lane: lg.laneOf(start, 0))
      ..addGoal(goal, 100, laneMask: 1);
    final search = LaneStateSearch()..begin(cost, ends);
    expect(search.step(1 << 30), SearchStatus.found);
    final route = search.route.sublist(0, search.routeLength);
    expectDrivable(lg, route);
    expect(route.first, lg.laneOf(start, 0));
    expect(lg.conToEdge(route[1]), isNot(goal));
    expect(lanesAlong(lg, route).last, lg.laneOf(goal, 0));
  });

  test('every route a fixed-start search returns can be driven, on 25 '
      'random towns (§17.2), and costs what Dijkstra finds', () {
    var found = 0, none = 0;
    for (var town = 1; town <= 25; town++) {
      final lg = lanesOf(randomTownLayout(TrafficRng(town)));
      final cost = RouteCost(lg);
      final rng = TrafficRng(1100 + town);
      final aStar = LaneStateSearch(), dijkstra = LaneStateSearch();
      final edges = SearchContext();
      final ends = PathEnds();
      for (var i = 0; i < 20; i++) {
        final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
        final lane = lg.laneOf(o, rng.nextInt(lg.edgeLaneCount[o]));
        final nG = lg.edgeLaneCount[g];
        final mask = switch (rng.nextInt(3)) {
          0 => 1,
          1 => 1 << (nG - 1),
          _ => kAllLanes,
        };
        ends
          ..clear()
          ..addOrigin(o, rng.nextUnit() * lg.edgeLen[o], lane: lane)
          ..addGoal(g, rng.nextUnit() * lg.edgeLen[g], laneMask: mask);
        aStar
          ..begin(cost, ends)
          ..step(1 << 30);
        dijkstra
          ..begin(cost, ends, heuristic: false)
          ..step(1 << 30);
        final why = 'town $town trip $i';
        expect(aStar.status, dijkstra.status, reason: why);
        edges
          ..begin(cost, ends)
          ..step(1 << 30);
        if (aStar.status == SearchStatus.noPath) {
          none++;
          continue;
        }
        // Held to a lane, it can never reach what a free start cannot.
        expect(edges.status, SearchStatus.found, reason: why);
        expect(aStar.cost, closeTo(dijkstra.cost, 1e-9 * math.max(1.0, aStar.cost)),
            reason: why);
        expect(aStar.cost, greaterThanOrEqualTo(edges.cost - 1e-9), reason: why);
        final route = aStar.route.sublist(0, aStar.routeLength);
        expectDrivable(lg, route, reason: why);
        expect(route.first, lane, reason: why);
        final last = lanesAlong(lg, route).last;
        expect(lg.laneEdge[last], g, reason: why);
        expect((mask >> lg.laneIdx[last]) & 1, 1, reason: why);
        found++;
      }
    }
    expect(found, greaterThan(300));
    expect(found + none, 500);
  });

  test('a state search resumes where it stopped: the same route at budgets '
      'of 1, 17 and 4,000', () {
    for (var town = 1; town <= 4; town++) {
      final lg = lanesOf(randomTownLayout(TrafficRng(80 + town)));
      final cost = RouteCost(lg);
      final rng = TrafficRng(1300 + town);
      final ends = PathEnds();
      for (var i = 0; i < 10; i++) {
        final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
        ends
          ..clear()
          ..addOrigin(o, 1, lane: lg.laneOf(o, 0))
          ..addGoal(g, lg.edgeLen[g] / 2);
        final whole = LaneStateSearch()
          ..begin(cost, ends)
          ..step(4000);
        expect(whole.status, isNot(SearchStatus.running));
        for (final budget in [1, 17]) {
          final part = LaneStateSearch()..begin(cost, ends);
          var steps = 0;
          while (part.step(budget) == SearchStatus.running) {
            expect(part.lastStepExpansions, budget);
            steps++;
          }
          expect(steps, lessThan(100000));
          expect(part.status, whole.status);
          expect(part.expansions, whole.expansions);
          expect(part.route.sublist(0, part.routeLength),
              whole.route.sublist(0, whole.routeLength));
        }
      }
    }
  });

  test('free to start in any lane of its edge, it takes the cheapest', () {
    final lg = lanesOf(avenueTown(RoadClass.avenue));
    final cost = RouteCost(lg);
    final start = edgeOf(lg, 'r4x1'), goal = edgeOf(lg, 'r1x1');
    final any = LaneStateSearch()
      ..begin(
          cost,
          PathEnds()
            ..addOrigin(start, 150)
            ..addGoal(goal, 100, laneMask: 1))
      ..step(1 << 30);
    var best = double.infinity;
    for (var k = 0; k < lg.edgeLaneCount[start]; k++) {
      final one = LaneStateSearch()
        ..begin(
            cost,
            PathEnds()
              ..addOrigin(start, 150, lane: lg.laneOf(start, k))
              ..addGoal(goal, 100, laneMask: 1))
        ..step(1 << 30);
      best = math.min(best, one.cost);
    }
    expect(any.cost, best);
    expect(describe(lg, any.route.sublist(0, any.routeLength)),
        ['r4x1+1', 'r1x1+0']);
  });
}
