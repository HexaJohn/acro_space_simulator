// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_connectors.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/network_key.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The lane graph is DERIVED from the road agent's graph, never built
/// beside it (docs/plans/agent-traffic.md §3.1, §3.8): one numbering of one
/// network, re-derived when that graph object changes, and only its
/// controls refreshed when the change was a junction plan.
void main() {
  test('lane-graph edges are the road graph\'s edges, id for id', () {
    final g = grid(3).roadGraph;
    final lg = LaneGraphBuilder.build(g);
    expect(lg.roadEdgeCount, g.edgeCount);
    expect(lg.edgeCount, g.edgeCount);
    for (var e = 0; e < g.edgeCount; e++) {
      final p = g.edgePiece[e];
      expect(lg.edgeFrom[e], g.edgeFrom[e]);
      expect(lg.edgeTo[e], g.edgeTo[e]);
      expect(lg.edgeForward[e], g.edgeForward[e]);
      expect(lg.edgeRoad[e], g.pieceRoad[p]);
      expect(lg.edgeS0[e], g.pieceS0[p]);
      expect(lg.edgeS1[e], g.pieceS1[p]);
      expect(lg.edgeLen[e], g.edgeLength[e]);
      expect(lg.edgeLimit[e], closeTo(g.roadSpeedMps[g.pieceRoad[p]], 1e-4));
      expect(lg.edgeLaneCount[e], greaterThan(0));
      final rev = lg.edgeReverse[e];
      if (rev >= 0) {
        expect(g.edgePiece[rev], p);
        expect(lg.edgeReverse[rev], e);
      }
      // The leg it leaves by is a leg of its own road at its own node.
      final node = g.nodes[g.edgeFrom[e]];
      expect(node.legRoadIds[lg.edgeOutLeg[e]], g.roads[g.pieceRoad[p]].id);
    }
  });

  test('node kinds follow the network\'s own plans', () {
    final layout = CityLayout();
    // A street crossing (an all-way stop) with a street end-on to one arm
    // (a continuation) and a dead end beyond it.
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)], regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(-200, 0), Vec2(200, 0)], regenerateLots: false);
    layout.addRoad(const RoadSpline(
        id: 'on', controls: [Vec2(200, 0), Vec2(400, 30)]));
    // An avenue crossing a street at x = 1000: signals.
    layout.commitRoad(
        controls: const [Vec2(800, 0), Vec2(1200, 0)],
        roadClass: RoadClass.avenue,
        regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(1000, -200), Vec2(1000, 200)],
        regenerateLots: false);
    // Three collectors meeting: a roundabout.
    for (final (i, p) in const [Vec2(0, 1200), Vec2(200, 1000), Vec2(-200, 1000)]
        .indexed) {
      layout.addRoad(RoadSpline(
          id: 'c$i',
          controls: [const Vec2(0, 1000), p],
          collector: true));
    }
    // A ramp beside an expressway: a ramp merge.
    layout.addRoad(const RoadSpline(
        id: 'x',
        controls: [Vec2(-500, -1000), Vec2(500, -1000)],
        roadClass: RoadClass.expressway6));
    layout.addRoad(const RoadSpline(
        id: 'r',
        controls: [Vec2(-150, -1045), Vec2(0, -1012.8)],
        roadClass: RoadClass.ramp));
    // A deck that stops in mid air.
    layout.addRoad(const RoadSpline(
        id: 'deck',
        controls: [Vec2(2000, 0), Vec2(2300, 0)],
        deck: RoadDeck(startM: 12, endM: 12, startOffsetM: 12, endOffsetM: 12)));
    // A partial stop: the player told one leg of a crossing to stop.
    layout.commitRoad(
        controls: const [Vec2(3000, -200), Vec2(3000, 200)],
        regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(2800, 0), Vec2(3200, 0)], regenerateLots: false);
    final pre = RoadGraph.of(layout);
    final partial = pre.nodeNear(const Vec2(3000, 0))!;
    final g = RoadGraph.of(layout, overrides: [
      JunctionOverride(
          at: partial.at, stopHeadings: [partial.legs.first.heading]),
    ]);
    final lg = LaneGraphBuilder.build(g);

    final seen = <NodeControlKind>{};
    for (var n = 0; n < g.nodeCount; n++) {
      final want = _kindByTable(g.nodes[n]);
      expect(lg.kindOf(n), want, reason: 'node $n at ${g.nodes[n].at}');
      seen.add(want);
    }
    expect(seen, containsAll(<NodeControlKind>[
      NodeControlKind.deadEnd,
      NodeControlKind.danglingDeck,
      NodeControlKind.continuation,
      NodeControlKind.rampMerge,
      NodeControlKind.allWayStop,
      NodeControlKind.stop,
      NodeControlKind.signals,
      NodeControlKind.roundabout,
    ]));
  });

  test('a junction override patches the graph: the controls refresh and '
      'every lane and connector stands', () {
    final city = signalised();
    final g0 = city.roadGraph;
    final lg0 = LaneGraphBuilder.build(g0);
    final centre = g0.nodeNear(const Vec2(0, 0))!.id;
    expect(lg0.kindOf(centre), NodeControlKind.signals);
    final key0 = TrafficNetKey(g0);

    city.setJunctionOverride(
        const JunctionOverride(at: Vec2(0, 0), lights: false));
    final g1 = city.roadGraph;
    expect(g1.sharesStructureWith(g0), isTrue);
    expect(TrafficNetKey(g1).since(key0), NetChange.controls);
    final lg1 = LaneGraphBuilder.refresh(lg0, g1)!;
    expect(lg1.sharesStructureWith(lg0), isTrue);
    expect(identical(lg1.conPts, lg0.conPts), isTrue);
    expect(identical(lg1.conToLane, lg0.conToLane), isTrue);
    expect(lg1.kindOf(centre), NodeControlKind.allWayStop);
    // Exactly what a fresh build of the patched graph gives.
    final fresh = LaneGraphBuilder.build(g1);
    expect(lg1.conRole, fresh.conRole);
    expect(lg1.controls.kind, fresh.controls.kind);
    expect(lg1.controls.edgeStops, fresh.controls.edgeStops);
    expect(lg1.connectorCount, fresh.connectorCount);
    // The connectors across the centre gave way; now they stop and yield.
    for (var i = lg1.nodeConStart[centre]; i < lg1.nodeConStart[centre + 1]; i++) {
      final c = lg1.nodeCons[i];
      if (lg1.connectorKindOf(c) != ConnectorKind.turn &&
          lg1.connectorKindOf(c) != ConnectorKind.aligned) {
        continue;
      }
      expect(lg0.roleOf(c), ConnectorRole.priority);
      expect(lg1.roleOf(c), ConnectorRole.yield);
    }
    // The same graph again is no change at all.
    expect(LaneGraphBuilder.refresh(lg1, g1), same(lg1));
    expect(TrafficNetKey(g1).since(TrafficNetKey(g1)), NetChange.none);
  });

  test('a road edit is a new network: rebuild, never refresh', () {
    final city = signalised();
    final g0 = city.roadGraph;
    final lg0 = LaneGraphBuilder.build(g0);
    commit(city,
        const FixtureRoad([Vec2(150, -200), Vec2(150, 200)]));
    final g1 = city.roadGraph;
    expect(g1.sharesStructureWith(g0), isFalse);
    expect(TrafficNetKey(g1).since(TrafficNetKey(g0)), NetChange.rebuild);
    expect(LaneGraphBuilder.refresh(lg0, g1), isNull);
    // Our own counters are changes too, of their own sizes.
    expect(TrafficNetKey(g1, stubsRev: 1).since(TrafficNetKey(g1)),
        NetChange.stubs);
    expect(TrafficNetKey(g1, stopsRev: 1).since(TrafficNetKey(g1)),
        NetChange.stops);
    expect(TrafficNetKey(g1).since(null), NetChange.rebuild);
  });

  test('the watch reads the graph only when a road or the plat moved', () {
    final source = _CountingSource(grid(2).roadGraph);
    final watch = TrafficNetWatch();
    for (var i = 0; i < 10; i++) {
      watch.poll(source);
    }
    expect(source.reads, 1);
    expect(watch.fetches, 1);
    source.roadsRevision++;
    watch.poll(source);
    watch.poll(source);
    expect(source.reads, 2);
    source.layoutVersion++;
    watch.poll(source);
    expect(source.reads, 3);
    watch.reset();
    watch.poll(source);
    expect(source.reads, 4);
  });

  test('a colony\'s override reaches the watch through its revision', () {
    final city = signalised();
    final watch = TrafficNetWatch();
    final source = CityNetSource(city);
    final g0 = watch.poll(source);
    expect(watch.poll(source), same(g0));
    expect(watch.fetches, 1);
    city.setJunctionOverride(
        const JunctionOverride(at: Vec2(0, 0), lights: false));
    final g1 = watch.poll(source);
    expect(watch.fetches, 2);
    expect(g1, isNot(same(g0)));
    expect(g1.sharesStructureWith(g0), isTrue);
    expect(g1.nodeNear(const Vec2(0, 0))!.control, JunctionControl.stop);
  });
}

/// §3.2's table, written out again so the builder is checked against the
/// design rather than against itself.
NodeControlKind _kindByTable(RoadNode node) {
  final legs = node.legs;
  if (legs.length == 1) {
    return node.atGrade ? NodeControlKind.deadEnd : NodeControlKind.danglingDeck;
  }
  final plan = node.plan;
  switch (plan.control) {
    case JunctionControl.none:
      return legs.length == 2
          ? NodeControlKind.continuation
          : NodeControlKind.uncontrolled;
    case JunctionControl.merge:
      return legs.any((l) => l.roadClass == RoadClass.ramp)
          ? NodeControlKind.rampMerge
          : NodeControlKind.continuation;
    case JunctionControl.stop:
      final all = [
        for (var i = 0; i < legs.length; i++)
          if (legs[i].inbound) i,
      ].every(plan.stopLegs.contains);
      return all ? NodeControlKind.allWayStop : NodeControlKind.stop;
    case JunctionControl.signals:
      return NodeControlKind.signals;
    case JunctionControl.roundabout:
      return NodeControlKind.roundabout;
  }
}

/// A network source that counts how often its graph is read.
class _CountingSource implements TrafficNetSource {
  _CountingSource(this._graph);

  final RoadGraph _graph;
  int reads = 0;

  @override
  int roadsRevision = 0;

  @override
  int layoutVersion = 0;

  @override
  RoadGraph get roadGraph {
    reads++;
    return _graph;
  }
}
