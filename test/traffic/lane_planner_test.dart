// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_planner.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/path_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_fixture.dart';

/// The lane pass: one locked lane on every edge of a new trip (docs/plans/
/// agent-traffic.md §4.5; §17.1 lane_planner_test; §17.2 lane-planner
/// feasibility; §17.3 #5), and the sticky repair a remap mends a route
/// with (§3.9 step 3).
void main() {
  test('backward sets are never empty for a new trip: every route the edge '
      'A* returns on 25 random towns can be given lanes', () {
    var trips = 0;
    for (var town = 1; town <= 25; town++) {
      final lg = lanesOf(randomTownLayout(TrafficRng(town)));
      final cost = RouteCost(lg);
      final rng = TrafficRng(300 + town);
      final search = SearchContext();
      final planner = LanePlanner();
      final ends = PathEnds();
      for (var i = 0; i < 20; i++) {
        final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
        final nG = lg.edgeLaneCount[g];
        // The kerb, a driveway across the road, or passing through.
        final mask = switch (rng.nextInt(3)) {
          0 => 1,
          1 => 1 << (nG - 1),
          _ => kAllLanes,
        };
        ends
          ..clear()
          ..addOrigin(o, rng.nextUnit() * lg.edgeLen[o])
          ..addGoal(g, rng.nextUnit() * lg.edgeLen[g], laneMask: mask);
        search.begin(cost, ends);
        if (search.step(1 << 30) != SearchStatus.found) continue;
        final edges = search.path.sublist(0, search.pathLength);
        final why = 'town $town trip $i: $edges';
        expect(planner.plan(lg, search.path, search.pathLength, destMask: mask),
            isTrue,
            reason: why);
        final route = planner.route.sublist(0, planner.routeLength);
        expectDrivable(lg, route, reason: why);
        expect(edgesAlong(lg, route), edges, reason: why);
        expect((mask >> lg.laneIdx[lanesAlong(lg, route).last]) & 1, 1,
            reason: why);
        trips++;
      }
    }
    expect(trips, greaterThan(250));
  });

  test('a trip to a building on the right arrives in the kerb lane, and to '
      'one across the road in the innermost', () {
    final lg = lanesOf(avenueTown(RoadClass.avenue));
    final from = edgeOf(lg, 'r4x1'), to = edgeOf(lg, 'r4x3');
    final kerb = planTrip(lg, from, 50, to, 100, destMask: 1)!;
    expect(describe(lg, kerb.route), ['r4x1+0', 'r4x2+0', 'r4x3+0']);
    final across = planTrip(lg, from, 50, to, 100, destMask: 1 << 1)!;
    expect(describe(lg, across.route), ['r4x1+1', 'r4x2+1', 'r4x3+1']);
  });

  test('no lane assignment charges less than the lane pass\'s (§4.5): '
      'unnatural landings are as few as the route allows', () {
    var checked = 0;
    for (var town = 1; town <= 10; town++) {
      final lg = lanesOf(randomTownLayout(TrafficRng(60 + town)));
      final cost = RouteCost(lg);
      final rng = TrafficRng(600 + town);
      final search = SearchContext();
      final planner = LanePlanner();
      final ends = PathEnds();
      for (var i = 0; i < 30; i++) {
        final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
        final mask = rng.nextInt(2) == 0 ? 1 : kAllLanes;
        ends
          ..clear()
          ..addOrigin(o, 1)
          ..addGoal(g, lg.edgeLen[g] - 1, laneMask: mask);
        search.begin(cost, ends);
        if (search.step(1 << 30) != SearchStatus.found) continue;
        if (search.pathLength > 6) continue;
        final edges = search.path.sublist(0, search.pathLength);
        expect(planner.plan(lg, search.path, search.pathLength, destMask: mask),
            isTrue);
        expect(planner.penalty, closeTo(_cheapest(lg, edges, mask), 1e-9),
            reason: 'town $town: $edges');
        checked++;
      }
    }
    expect(checked, greaterThan(100));
  });

  group('§17.3 #5: the lane matches the next turn', () {
    test('on an avenue a left at the next node takes lane 1, and a right '
        'lane 0', () {
      final lg = lanesOf(avenueTown(RoadClass.avenue));
      final av = edgeOf(lg, 'r4x1');
      final left = planTrip(lg, av, 50, edgeOf(lg, 'r1x1'), 100, destMask: 1)!;
      expect(describe(lg, left.route), ['r4x1+1', 'r1x1+0']);
      final right = planTrip(
          lg, av, 50, edgeOf(lg, 'r1x0', forward: false), 100,
          destMask: 1)!;
      expect(describe(lg, right.route), ['r4x1+0', 'r1x0-0']);
    });

    test('on a boulevard a left-turner is in lane 2', () {
      final lg = lanesOf(avenueTown(RoadClass.boulevard));
      final bv = edgeOf(lg, 'r4x1');
      expect(lg.edgeLaneCount[bv], 3);
      final left = planTrip(lg, bv, 50, edgeOf(lg, 'r1x1'), 100, destMask: 1)!;
      expect(describe(lg, left.route), ['r4x1+2', 'r1x1+0']);
    });

    test('where two lanes serve a trip equally, the emptier is taken: '
        'through traffic spreads across the lanes', () {
      final lg = lanesOf(avenueTown(RoadClass.avenue));
      // North up the street at x = 400, left onto the avenue westbound,
      // straight on at x = 200, right at x = 0. Landing in the avenue's
      // inner lane (the natural landing of a left) needs a shift back at
      // x = 200; landing in its kerb lane costs a lane at once. The same
      // charge either way.
      final west = edgeOf(lg, 'r4x2', forward: false);
      final edges = Int32List.fromList([
        edgeOf(lg, 'r2x0'),
        west,
        edgeOf(lg, 'r4x1', forward: false),
        edgeOf(lg, 'r0x1'),
      ]);
      final planner = LanePlanner();
      int landing(Map<int, int> load) {
        expect(planner.plan(lg, edges, 4, destMask: 1, load: _Load(load)),
            isTrue);
        expect(planner.penalty, 1.0);
        final route = planner.route.sublist(0, planner.routeLength);
        expectDrivable(lg, route);
        return lg.laneIdx[lanesAlong(lg, route)[1]];
      }

      expect(landing({}), 0, reason: 'empty: the lower lane');
      expect(landing({lg.laneOf(west, 0): 3}), 1);
      expect(landing({lg.laneOf(west, 1): 3}), 0);
    });
  });

  group('the sticky repair (§3.9 step 3)', () {
    test('keeps every planned connector that still exists, and changes '
        'nothing', () {
      final lg = lanesOf(avenueTown(RoadClass.avenue));
      final trip = planTrip(
          lg, edgeOf(lg, 'r4x0'), 50, edgeOf(lg, 'r3x1'), 100,
          destMask: 1)!;
      final edges = Int32List.fromList(trip.edges);
      final want = Int32List.fromList(
          [for (final l in lanesAlong(lg, trip.route)) lg.laneIdx[l]]);
      final planner = LanePlanner();
      expect(planner.repair(lg, edges, want, edges.length, destMask: 1),
          isTrue);
      expect(planner.repaired, isFalse);
      expect(planner.route.sublist(0, planner.routeLength), trip.route);
    });

    test('mends a broken connector over the shortest span, reaching back '
        'only as far as it must', () {
      final lg = lanesOf(avenueTown(RoadClass.avenue));
      // East along the avenue in the kerb lane throughout, then a left at
      // x = 400 — which the kerb lane cannot make.
      final edges = Int32List.fromList([
        edgeOf(lg, 'r4x0'),
        edgeOf(lg, 'r4x1'),
        edgeOf(lg, 'r4x2'),
        edgeOf(lg, 'r2x1'),
      ]);
      final want = Int32List.fromList([0, 0, 0, 0]);
      final planner = LanePlanner();
      expect(planner.repair(lg, edges, want, 4, destMask: 1), isTrue);
      expect(planner.repaired, isTrue);
      final route = planner.route.sublist(0, planner.routeLength);
      expectDrivable(lg, route);
      // Lane 0 is kept up to the last junction before the left; the shift
      // into lane 1 is made there, not a node earlier.
      expect(describe(lg, route), ['r4x0+0', 'r4x1+0', 'r4x2+1', 'r2x1+0']);
      expect(route[1], lg.connector(lg.laneOf(edges[0], 0), lg.laneOf(edges[1], 0)));
    });

    test('says no when the lane the vehicle is in cannot be mended from', () {
      final lg = lanesOf(avenueTown(RoadClass.avenue));
      final edges = Int32List.fromList([edgeOf(lg, 'r4x2'), edgeOf(lg, 'r2x1')]);
      final planner = LanePlanner();
      expect(
          planner.repair(lg, edges, Int32List.fromList([0, 0]), 2, destMask: 1),
          isFalse);
      expect(
          planner.repair(lg, edges, Int32List.fromList([1, 0]), 2, destMask: 1),
          isTrue);
    });
  });
}

/// The least §4.5 charge of any lane assignment that drives [edges], from
/// any lane of the first to a lane of [mask] on the last, by trying them
/// all.
double _cheapest(LaneGraph lg, List<int> edges, int mask) {
  var best = double.infinity;
  void walk(int i, int lane, double charge) {
    if (charge >= best) return;
    if (i == edges.length - 1) {
      if ((mask >> lg.laneIdx[lane]) & 1 == 1) best = charge;
      return;
    }
    for (var c = lg.laneConStart[lane]; c < lg.laneConStart[lane + 1]; c++) {
      final to = lg.conToLane[c];
      if (lg.laneEdge[to] != edges[i + 1]) continue;
      walk(i + 1, to, charge + lg.conPen[c]);
    }
  }

  for (var k = 0; k < lg.edgeLaneCount[edges[0]]; k++) {
    walk(0, lg.laneOf(edges[0], k), 0);
  }
  return best;
}

class _Load implements LaneLoad {
  _Load(this.counts);

  final Map<int, int> counts;

  @override
  int vehiclesOn(int lane) => counts[lane] ?? 0;
}
