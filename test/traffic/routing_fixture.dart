// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the routing tests share (docs/plans/agent-traffic.md §17.1): lane
/// graphs straight from a layout, edges found by road id or by place, random
/// towns, a new trip planned the way the queue plans one, and the checks
/// that a route can be driven and means the same thing across two builds.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/graph_lineage.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_planner.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/path_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lane graph of [layout]'s roads, under the player's [overrides].
LaneGraph lanesOf(CityLayout layout,
        {List<JunctionOverride> overrides = const []}) =>
    LaneGraphBuilder.build(RoadGraph.of(layout, overrides: overrides));

/// The first edge of road [roadId] running first point to last, or
/// ([forward] false) the other way.
int edgeOf(LaneGraph lg, String roadId, {bool forward = true}) {
  for (var e = 0; e < lg.edgeCount; e++) {
    if (lg.graph.roads[lg.edgeRoad[e]].id != roadId) continue;
    if ((lg.edgeForward[e] == 1) != forward) continue;
    return e;
  }
  throw StateError('no ${forward ? 'forward' : 'backward'} edge of $roadId');
}

/// The edge whose line passes nearest [p] while travelling within 45° of
/// [dir].
int edgeNear(LaneGraph lg, Vec2 p, Vec2 dir) {
  var best = -1;
  var bestD = double.infinity;
  for (var e = 0; e < lg.edgeCount; e++) {
    final rec = lg.graph.roadRecs[lg.edgeRoad[e]];
    final hit = EdgeLineage.project(rec, p.e, p.n);
    if (hit.s < lg.edgeS0[e] - 1e-6 || hit.s > lg.edgeS1[e] + 1e-6) continue;
    final sign = lg.edgeForward[e] == 1 ? 1.0 : -1.0;
    final j = hit.seg;
    final te = (rec.e[j] - rec.e[j - 1]) * sign;
    final tn = (rec.n[j] - rec.n[j - 1]) * sign;
    final tl = math.sqrt(te * te + tn * tn);
    if (tl == 0) continue;
    if ((te * dir.e + tn * dir.n) / (tl * dir.length) < math.cos(math.pi / 4)) {
      continue;
    }
    if (hit.d < bestD) {
      bestD = hit.d;
      best = e;
    }
  }
  if (best < 0) throw StateError('no edge near $p heading $dir');
  return best;
}

/// The travel arc along [edge] of its line's nearest point to [p].
double arcNear(LaneGraph lg, int edge, Vec2 p) {
  final rec = lg.graph.roadRecs[lg.edgeRoad[edge]];
  final s = EdgeLineage.project(rec, p.e, p.n).s;
  final c = s < lg.edgeS0[edge]
      ? lg.edgeS0[edge]
      : (s > lg.edgeS1[edge] ? lg.edgeS1[edge] : s);
  return lg.travelArc(edge, c);
}

/// Where travel arc [t] along [edge] is.
Vec2 pointOnEdge(LaneGraph lg, int edge, double t) =>
    lg.graph.pointAt(lg.edgeRoad[edge], lg.roadArc(edge, t));

/// A random grid town, seeded by [rng]: two to four roads each way, every
/// road a random class — streets, avenues, boulevards, one-way streets
/// both ways, motorways, alleys — dressed at random where the class
/// allows.
CityLayout randomTownLayout(TrafficRng rng) {
  const classes = [
    RoadClass.street,
    RoadClass.street,
    RoadClass.avenue,
    RoadClass.boulevard,
    RoadClass.streetOneWay,
    RoadClass.motorway,
    RoadClass.alley,
  ];
  final layout = CityLayout();
  final n = 2 + rng.nextInt(3);
  final spacing = 150.0 + rng.nextInt(120);
  final half = (n - 1) * spacing / 2;
  final lo = -half - spacing / 2, hi = half + spacing / 2;
  for (var i = 0; i < n; i++) {
    final at = -half + i * spacing;
    for (final vertical in [true, false]) {
      final cls = classes[rng.nextInt(classes.length)];
      final deco = cls.supportsDecoration
          ? RoadDecoration.values[rng.nextInt(RoadDecoration.values.length)]
          : RoadDecoration.none;
      layout.commitRoad(
        controls: vertical
            ? [Vec2(at, lo), Vec2(at, hi)]
            : [Vec2(lo, at), Vec2(hi, at)],
        roadClass: cls,
        decoration: deco,
        reversed: cls.oneWay && rng.nextInt(2) == 0,
        regenerateLots: false,
      );
    }
  }
  return layout;
}

/// A trip planned the way the queue plans a new one: the edge A*, then the
/// lane pass.
typedef Trip = ({List<int> route, List<int> edges, double cost});

/// A new trip from travel arc [fromT] of [fromEdge] to [toT] of [toEdge],
/// arriving in a lane of [destMask]; null when nothing joins them, or no
/// lanes drive the cheapest way.
Trip? planTrip(LaneGraph lg, int fromEdge, double fromT, int toEdge,
    double toT,
    {int destMask = kAllLanes, RouteCost? cost, LaneLoad? load}) {
  final prices = cost ?? RouteCost(lg);
  final ends = PathEnds()
    ..addOrigin(fromEdge, fromT)
    ..addGoal(toEdge, toT, laneMask: destMask);
  final search = SearchContext()..begin(prices, ends);
  if (search.step(1 << 30) != SearchStatus.found) return null;
  final planner = LanePlanner();
  if (!planner.plan(lg, search.path, search.pathLength,
      destMask: destMask, load: load)) {
    return null;
  }
  return (
    route: planner.route.sublist(0, planner.routeLength),
    edges: search.path.sublist(0, search.pathLength),
    cost: search.cost,
  );
}

/// Checks that [route] (`[firstLane, c₁, …]`) can be driven on [lg]: each
/// connector leaves the very lane the one before landed in.
void expectDrivable(LaneGraph lg, List<int> route, {String reason = ''}) {
  expect(route, isNotEmpty, reason: reason);
  expect(route[0], inInclusiveRange(0, lg.laneCount - 1), reason: reason);
  var lane = route[0];
  for (var i = 1; i < route.length; i++) {
    final c = route[i];
    expect(c, inInclusiveRange(0, lg.connectorCount - 1), reason: reason);
    expect(lg.conFromLane[c], lane,
        reason: '$reason: connector $i leaves lane ${lg.conFromLane[c]}, '
            'but the vehicle is in lane $lane');
    lane = lg.conToLane[c];
  }
}

/// The lane of each edge of [route], in order.
List<int> lanesAlong(LaneGraph lg, List<int> route) => [
      route[0],
      for (var i = 1; i < route.length; i++) lg.conToLane[route[i]],
    ];

/// The edges of [route], in order.
List<int> edgesAlong(LaneGraph lg, List<int> route) =>
    [for (final l in lanesAlong(lg, route)) lg.laneEdge[l]];

/// [route] as build-free words: each edge as its road id, `+` or `-` for
/// its direction, and the lane index — what a route MEANS, which two builds
/// of one network agree on although they number everything differently.
List<String> describe(LaneGraph lg, List<int> route) => [
      for (final l in lanesAlong(lg, route))
        '${lg.graph.roads[lg.edgeRoad[lg.laneEdge[l]]].id}'
            '${lg.edgeForward[lg.laneEdge[l]] == 1 ? '+' : '-'}'
            '${lg.laneIdx[l]}',
    ];

/// A route held in a typed list, as the arena holds it.
Int32List asRoute(List<int> route) => Int32List.fromList(route);

/// Streets north–south at x = 0, 200, 400 and 600 (r0–r3, each split at
/// y = 0 into `x0` south and `x1` north), then a [cls] east–west across them
/// all along y = 0 (r4, cut into r4x0 … r4x4: r4x1 runs x = 0 to 200). The
/// crossings of an arterial with a street have lights. Committed streets
/// first, so every id is one split deep.
CityLayout avenueTown(RoadClass cls) {
  final layout = CityLayout();
  for (var i = 0; i < 4; i++) {
    final x = i * 200.0;
    layout.commitRoad(
        controls: [Vec2(x, -200), Vec2(x, 200)], regenerateLots: false);
  }
  layout.commitRoad(
      controls: const [Vec2(-200, 0), Vec2(800, 0)],
      roadClass: cls,
      regenerateLots: false);
  return layout;
}
