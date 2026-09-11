// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/graph_lineage.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_connectors.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_state_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_fixture.dart';

/// Routes carried across network edits (docs/plans/agent-traffic.md §3.9;
/// §17.1 route_remap_test; the core of §17.3 #3 and #4): a route passes
/// straight through a junction a new road makes, keeps its lanes, and is
/// planned afresh only when the edit made it impossible. Lineage runs
/// through road ids and arcs, never through graph numbers, which every
/// build deals out afresh.
void main() {
  test('a single split: the route runs straight through the new junction, '
      'in the lane it was in, and nobody moves', () {
    final layout = _streetTown();
    final old = lanesOf(layout);
    final trip = _through(old);
    expect(describe(old, trip.route), ['r2x0+0', 'r2x1+0', 'r2x2+0']);
    layout.commitRoad(
        controls: const [Vec2(0, -300), Vec2(0, 300)], regenerateLots: false);
    final now = lanesOf(layout);

    final first = _carry(old, now, trip.route, t: 50, destS: 100);
    expect(first.status, RemapStatus.kept);
    final route = _routeOf(first.rm);
    expectDrivable(now, route);
    expect(describe(now, route),
        ['r2x0+0', 'r2x1x0+0', 'r2x1x1+0', 'r2x2+0']);
    expect(first.rm.lanesRepaired, isFalse);
    // Straight across the new road, never onto it.
    expect(now.turnOf(route[2]), TurnClass.straight);
    // The vehicle and its stop are where they were.
    expect(
        _placeOf(now, first.rm)
            .distanceTo(pointOnEdge(old, edgeOf(old, 'r2x0'), 50)),
        lessThan(0.5));
    expect(
        pointOnEdge(now, edgeOf(now, 'r2x2'), first.rm.stopS)
            .distanceTo(pointOnEdge(old, edgeOf(old, 'r2x2'), 100)),
        lessThan(0.5));

    // A vehicle on the split road, past the new crossing, is on its east
    // piece, where it was.
    final mid = _carry(old, now, trip.route, at: 1, t: 305, destS: 100);
    expect(mid.status, RemapStatus.kept);
    expect(describe(now, _routeOf(mid.rm)), ['r2x1x1+0', 'r2x2+0']);
    expect(
        _placeOf(now, mid.rm)
            .distanceTo(pointOnEdge(old, edgeOf(old, 'r2x1'), 305)),
        lessThan(0.5));

    // One still on the connector into the split road lands on its west
    // piece.
    final turning =
        _carry(old, now, trip.route, at: 1, onConnector: true, destS: 100);
    expect(turning.status, RemapStatus.kept);
    expect(describe(now, _routeOf(turning.rm)),
        ['r2x1x0+0', 'r2x1x1+0', 'r2x2+0']);
    expect(turning.rm.laneS, 0);
  });

  test('nested x chains: a road split twice between two builds is one '
      'lineage', () {
    final layout = _streetTown();
    final old = lanesOf(layout);
    final trip = _through(old);
    layout.commitRoad(
        controls: const [Vec2(-100, -300), Vec2(-100, 300)],
        regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(100, -300), Vec2(100, 300)],
        regenerateLots: false);
    final now = lanesOf(layout);
    expect(layout.roadById('r2x1x1x0'), isNotNull,
        reason: 'the second road cut a piece the first had cut');
    final r = _carry(old, now, trip.route, t: 50, destS: 100);
    expect(r.status, RemapStatus.kept);
    expect(describe(now, _routeOf(r.rm)),
        ['r2x0+0', 'r2x1x0+0', 'r2x1x1x0+0', 'r2x1x1x1+0', 'r2x2+0']);
  });

  test('a split within 8 m of another drops the sliver between, and the '
      'pieces either side meet at one node', () {
    final layout = _streetTown();
    final old = lanesOf(layout);
    final trip = _through(old);
    layout.commitRoad(
        controls: const [Vec2(0, -300), Vec2(0, 300)], regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(7, -300), Vec2(7, 300)],
        snapStart: false,
        snapEnd: false,
        regenerateLots: false);
    final now = lanesOf(layout);
    // The 7 m between the two crossings was too short to keep ...
    expect(layout.roadById('r2x1x1'), isNull);
    expect(layout.roadById('r2x1x1x0'), isNotNull);
    expect(layout.roadById('r2x1x1x1'), isNull);
    // ... and the pieces either side share the node the crossings made.
    final west = edgeOf(now, 'r2x1x0'), east = edgeOf(now, 'r2x1x1x0');
    expect(now.edgeTo[west], now.edgeFrom[east]);
    final r = _carry(old, now, trip.route, t: 50, destS: 100);
    expect(r.status, RemapStatus.kept);
    expect(describe(now, _routeOf(r.rm)),
        ['r2x0+0', 'r2x1x0+0', 'r2x1x1x0+0', 'r2x2+0']);
  });

  test('a lane-count change: the sticky repair touches only the span it '
      'must, and every connector after it is the one planned', () {
    final layout = _streetTown();
    layout.commitRoad(
        controls: const [Vec2(-400, 150), Vec2(400, 150)],
        regenerateLots: false);
    final old = lanesOf(layout);
    // East, left at x = 200, then straight on across y = 150.
    final trip = planTrip(
        old, edgeOf(old, 'r2x0'), 50, edgeOf(old, 'r1x1x1'), 50,
        destMask: 1)!;
    expect(describe(old, trip.route),
        ['r2x0+0', 'r2x1+0', 'r1x1x0+0', 'r1x1x1+0']);
    layout.upgradeRoad('r2x1', roadClass: RoadClass.avenue);
    final now = lanesOf(layout);
    final r = _carry(old, now, trip.route, t: 50, destS: 50);
    expect(r.status, RemapStatus.kept);
    expect(r.rm.lanesRepaired, isTrue);
    final route = _routeOf(r.rm);
    expectDrivable(now, route);
    // The avenue's kerb lane turns only right or straight on: the left now
    // leaves its inner lane. The vehicle's own lane, and everything after
    // the left, are as planned.
    expect(describe(now, route),
        ['r2x0+0', 'r2x1+1', 'r1x1x0+0', 'r1x1x1+0']);
    expect(now.turnOf(route[2]), TurnClass.left);
    expect(now.turnOf(route[3]), old.turnOf(trip.route[3]));
    expect(now.connectorKindOf(route[3]), old.connectorKindOf(trip.route[3]));
  });

  test('a repair the lane the vehicle is in cannot make fails the remap, and '
      'one fixed-start re-plan finds a way that drives', () {
    final layout = avenueTown(RoadClass.avenue);
    final old = lanesOf(layout);
    final start = edgeOf(old, 'r4x1');
    // Held in lane 0, a left at x = 400: it shifts into lane 1 at x = 200.
    final plan = LaneStateSearch()
      ..begin(
          RouteCost(old),
          PathEnds()
            ..addOrigin(start, 50, lane: old.laneOf(start, 0))
            ..addGoal(edgeOf(old, 'r2x1'), 100, laneMask: 1))
      ..step(1 << 30);
    expect(plan.status, SearchStatus.found);
    final route = plan.route.sublist(0, plan.routeLength);
    expect(describe(old, route), ['r4x1+0', 'r4x2+1', 'r2x1+0']);
    expect(old.connectorKindOf(route[1]), ConnectorKind.shift);

    // The street at x = 200 is taken away: the crossing becomes a seam,
    // and nobody changes lanes at a seam.
    layout.removeRoad('r1x0', regenerateLots: false);
    layout.removeRoad('r1x1', regenerateLots: false);
    final now = lanesOf(layout);
    expect(now.kindOf(now.edgeTo[edgeOf(now, 'r4x1')]),
        NodeControlKind.continuation);
    final r = _carry(old, now, route, t: 50, destS: 100);
    expect(r.status, RemapStatus.replan);
    expect(describe(now, [r.rm.lane]), ['r4x1+0']);

    // One re-plan, from the lane it is in.
    final e = now.laneEdge[r.rm.lane];
    final goal = edgeOf(now, 'r2x1');
    final again = LaneStateSearch()
      ..begin(
          RouteCost(now),
          PathEnds()
            ..addOrigin(e, now.edgeLaneS0[e] + r.rm.laneS, lane: r.rm.lane)
            ..addGoal(goal, 100, laneMask: 1))
      ..step(1 << 30);
    expect(again.status, SearchStatus.found);
    final fresh = again.route.sublist(0, again.routeLength);
    expectDrivable(now, fresh);
    expect(fresh.first, r.rm.lane);
    expect(lanesAlong(now, fresh).last, now.laneOf(goal, 0));
  });

  test('a one-way reversed ahead makes the route impossible — a re-plan; '
      'reversed under the vehicle, a despawn; behind it, nothing', () {
    final layout = _streetTown(cls: RoadClass.streetOneWay);
    final old = lanesOf(layout);
    final trip = _through(old);
    layout.reverseRoad('r2x1');
    final now = lanesOf(layout);
    expect(
        _carry(old, now, trip.route, t: 50, destS: 100).status,
        RemapStatus.replan);
    expect(
        _carry(old, now, trip.route, at: 1, t: 100, destS: 100).status,
        RemapStatus.despawn);
    final behind = _carry(old, now, trip.route, at: 2, t: 20, destS: 100);
    expect(behind.status, RemapStatus.kept);
    expect(describe(now, _routeOf(behind.rm)), ['r2x2+0']);
  });

  test('a road removed ahead: a re-plan. The road under the vehicle '
      'removed, or the one its connector leads onto: a despawn', () {
    final layout = _streetTown();
    final old = lanesOf(layout);
    final trip = _through(old);
    layout.removeRoad('r2x1', regenerateLots: false);
    final now = lanesOf(layout);
    final ahead = _carry(old, now, trip.route, t: 50, destS: 100);
    expect(ahead.status, RemapStatus.replan);
    expect(describe(now, [ahead.rm.lane]), ['r2x0+0']);
    expect(
        _placeOf(now, ahead.rm)
            .distanceTo(pointOnEdge(old, edgeOf(old, 'r2x0'), 50)),
        lessThan(0.5));
    expect(
        _carry(old, now, trip.route, at: 1, t: 100, destS: 100).status,
        RemapStatus.despawn);
    expect(
        _carry(old, now, trip.route, at: 1, onConnector: true, destS: 100)
            .status,
        RemapStatus.despawn);
  });

  test('an end dragged re-lays the road: a vehicle on its unchanged stretch '
      'stays, one on the moved stretch goes, and routes through it '
      're-plan', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(-400, 0), Vec2(400, 0)], regenerateLots: false);
    // A spur north from the middle: straight for 200 m, then bending east.
    layout.commitRoad(
        controls: const [Vec2(0, 0), Vec2(0, 100), Vec2(0, 200), Vec2(100, 300)],
        regenerateLots: false);
    final old = lanesOf(layout);
    final spur = edgeOf(old, 'r1');
    final west = edgeOf(old, 'r0x0');
    final onSpur = [old.laneOf(spur, 0)];
    final turning = planTrip(old, west, 100, spur, 250, destMask: 1)!;
    expect(edgesAlong(old, turning.route), [west, spur]);
    final through =
        planTrip(old, west, 100, edgeOf(old, 'r0x1'), 100, destMask: 1)!;

    // Adjust Roads drags the far end west: the road is laid again, under a
    // descendant id, on new geometry.
    final newId = layout.childIdFor('r1');
    expect(newId, 'r1x0');
    layout.removeRoad('r1', regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(0, 0), Vec2(0, 100), Vec2(0, 200), Vec2(-100, 300)],
        id: newId,
        snapStart: false,
        snapEnd: false,
        regenerateLots: false);
    final now = lanesOf(layout);

    final stays = _carry(old, now, onSpur, t: 50, destS: 250);
    expect(stays.status, RemapStatus.replan);
    expect(describe(now, [stays.rm.lane]), ['r1x0+0']);
    expect(_placeOf(now, stays.rm).distanceTo(pointOnEdge(old, spur, 50)),
        lessThan(0.5));
    expect(_carry(old, now, onSpur, t: 250, destS: 280).status,
        RemapStatus.despawn);
    expect(_carry(old, now, turning.route, t: 100, destS: 250).status,
        RemapStatus.replan);
    final past = _carry(old, now, through.route, t: 100, destS: 100);
    expect(past.status, RemapStatus.kept);
    expect(describe(now, _routeOf(past.rm)), describe(old, through.route));
  });

  test('an unrelated road added changes nothing: the same roads, the same '
      'lanes, the same places', () {
    final layout = _streetTown();
    final old = lanesOf(layout);
    final trip = _through(old);
    layout.commitRoad(
        controls: const [Vec2(1000, 1000), Vec2(1300, 1000)],
        regenerateLots: false);
    final now = lanesOf(layout);
    expect(now.edgeCount, greaterThan(old.edgeCount));
    final r = _carry(old, now, trip.route, t: 50, destS: 100);
    expect(r.status, RemapStatus.kept);
    expect(r.rm.lanesRepaired, isFalse);
    expect(describe(now, _routeOf(r.rm)), describe(old, trip.route));
    expect(r.rm.laneS, closeTo(50 - old.edgeLaneS0[edgeOf(old, 'r2x0')], 1e-6));
    expect(r.rm.stopS, closeTo(100, 1e-6));
  });
}

/// Streets north–south at x = −200 (r0) and x = 200 (r1), then a [cls]
/// east–west across both along y = 0 (r2): r2x0 runs x = −400 to −200,
/// r2x1 to 200, r2x2 to 400.
CityLayout _streetTown({RoadClass cls = RoadClass.street}) {
  final layout = CityLayout();
  layout.commitRoad(
      controls: const [Vec2(-200, -300), Vec2(-200, 300)],
      regenerateLots: false);
  layout.commitRoad(
      controls: const [Vec2(200, -300), Vec2(200, 300)],
      regenerateLots: false);
  layout.commitRoad(
      controls: const [Vec2(-400, 0), Vec2(400, 0)],
      roadClass: cls,
      regenerateLots: false);
  return layout;
}

/// The trip east along [_streetTown]'s street: from 50 m along r2x0 to
/// 100 m along r2x2, at the kerb.
Trip _through(LaneGraph lg) => planTrip(
    lg, edgeOf(lg, 'r2x0'), 50, edgeOf(lg, 'r2x2'), 100,
    destMask: 1)!;

/// Carries [route] from [from] onto [to] for a vehicle on its route edge
/// [at] — [t] travel metres along it, or on the connector into it — whose
/// stop is [destS] along the last edge.
({RemapStatus status, RouteRemapper rm}) _carry(
    LaneGraph from, LaneGraph to, List<int> route,
    {int at = 0, double t = 0, bool onConnector = false, required double destS}) {
  final rm = RouteRemapper(EdgeLineage(from, to));
  final lane = at == 0 ? route[0] : from.conToLane[route[at]];
  final e = from.laneEdge[lane];
  final status = rm.remap(asRoute(route), 0, route.length,
      at: at, onConnector: onConnector, s: t - from.edgeLaneS0[e], destS: destS);
  return (status: status, rm: rm);
}

List<int> _routeOf(RouteRemapper rm) => rm.route.sublist(0, rm.routeLength);

/// Where the remapped vehicle stands.
Vec2 _placeOf(LaneGraph lg, RouteRemapper rm) {
  final e = lg.laneEdge[rm.lane];
  return pointOnEdge(lg, e, lg.edgeLaneS0[e] + rm.laneS);
}
