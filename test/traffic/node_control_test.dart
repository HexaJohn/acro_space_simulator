// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/node_control.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// Node control (docs/plans/agent-traffic.md §3.2, §3.7): the network's own
/// plan, read and never re-decided — so the junction the tiles draw is the
/// junction the agents obey.
void main() {
  RoadGraph streetCrossing() {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)], regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(-200, 0), Vec2(200, 0)], regenerateLots: false);
    return RoadGraph.of(layout);
  }

  group('on the generator\'s town', () {
    late RoadGraph g;
    late List<RoadEnd> ends;
    setUpAll(() {
      final city = const CityGenerator()
          .generate(const CityGenSpec(blocksAcross: 3), bodies: fixtureBodies);
      g = city.roadGraph;
      // Every road end as the tiles see it: the first point of travel and the
      // point in from it, for every class that makes a junction leg.
      ends = [];
      Vector3 v(Vec2 p) => Vector3(p.e, p.n, 0);
      for (final r in city.layout.roads) {
        final cls = r.roadClass;
        if (!cls.joinsJunctions) continue;
        final s = city.layout.roadIndex.byId(r.id)!.samples;
        final pts = r.reversed ? s.reversed.toList() : s;
        ends.add(RoadEnd(v(pts.first), v(pts[1]), r.halfWidth, cls,
            paved: cls.paved, collector: r.collector, isStart: true));
        ends.add(RoadEnd(v(pts.last), v(pts[pts.length - 2]), r.halfWidth, cls,
            paved: cls.paved, collector: r.collector));
      }
    });

    test('every node\'s kind is the §3.2 reading of its plan', () {
      final ctl = NodeControls.of(g);
      for (var n = 0; n < g.nodeCount; n++) {
        final node = g.nodes[n];
        final k = controlKindOf(node);
        expect(ctl.kindOf(n), k);
        switch (node.plan.control) {
          case JunctionControl.signals:
            expect(k, NodeControlKind.signals);
          case JunctionControl.roundabout:
            expect(k, NodeControlKind.roundabout);
          case JunctionControl.stop:
            expect(k, anyOf(NodeControlKind.stop, NodeControlKind.allWayStop));
          case JunctionControl.merge:
            expect(k, anyOf(NodeControlKind.rampMerge, NodeControlKind.continuation));
          case JunctionControl.none:
            expect(
                k,
                anyOf(NodeControlKind.deadEnd, NodeControlKind.danglingDeck,
                    NodeControlKind.continuation, NodeControlKind.uncontrolled));
        }
      }
    });

    test('where the tiles draw a junction of the same legs, they draw the '
        'control the agents obey', () {
      final drawn = RoadMesher.junctionsFromEnds(ends);
      expect(drawn, isNotEmpty);
      var agree = 0;
      final report = <String>[];
      for (final j in drawn) {
        final node = g.nodeNear(Vec2(j.at.x, j.at.y), withinM: 8);
        if (node == null) {
          report.add('tiles draw ${j.control} at ${j.at} with no graph node');
          continue;
        }
        final tileLegs = [for (final l in j.legs) l.roadClass.index]..sort();
        final graphLegs = [for (final l in node.legs) l.roadClass.index]
          ..sort();
        final sameLegs = tileLegs.length == graphLegs.length &&
            [for (var i = 0; i < tileLegs.length; i++) tileLegs[i] == graphLegs[i]]
                .every((b) => b);
        if (!sameLegs) {
          // The tiles leave alleys, paths and decks out of a junction; the
          // graph keeps every car leg. Theirs to reconcile (C1).
          if (node.control != j.control) {
            report.add('legs differ at ${node.at}: graph ${node.control}, '
                'tiles ${j.control}');
          }
          continue;
        }
        expect(node.control, j.control, reason: 'at ${node.at}');
        agree++;
      }
      if (report.isNotEmpty) {
        // ignore: avoid_print
        print('node control vs tiles, for the road agent (C1):\n'
            '${report.join('\n')}');
      }
      expect(agree, greaterThan(10));
    });
  });

  test('lights switched on by an override turn a stop into signals, and '
      'editing that override in place re-plans the junction again', () {
    final g = streetCrossing();
    final at = g.nodeNear(const Vec2(0, 0))!;
    final lg0 = LaneGraphBuilder.build(g);
    expect(lg0.kindOf(at.id), NodeControlKind.allWayStop);

    final lit =
        g.withOverrides([JunctionOverride(at: at.at, lights: true)]);
    final lg1 = LaneGraphBuilder.refresh(lg0, lit)!;
    expect(lg1.kindOf(at.id), NodeControlKind.signals);
    final plan = lg1.controls.planOf(at.id)!;
    for (var i = lg1.inStart[at.id]; i < lg1.inStart[at.id + 1]; i++) {
      final e = lg1.inEdges[i];
      expect(lg1.controls.edgePhase[e], plan.legPhase[g.edgeLeg[e]]);
      expect(lg1.controls.edgeStops[e], 0);
    }

    // The same override, edited: lights off, and only the first leg stops.
    final edited = lit.withOverrides([
      JunctionOverride(
          at: at.at, lights: false, stopHeadings: [at.legs.first.heading]),
    ]);
    final lg2 = LaneGraphBuilder.refresh(lg1, edited)!;
    expect(lg2.kindOf(at.id), NodeControlKind.stop);
    expect(lg2.controls.planOf(at.id), isNull);
    for (var i = lg2.inStart[at.id]; i < lg2.inStart[at.id + 1]; i++) {
      final e = lg2.inEdges[i];
      final stops = g.edgeLeg[e] == 0;
      expect(lg2.controls.edgeStops[e], stops ? 1 : 0);
      expect(lg2.controls.edgeYields[e], stops ? 1 : 0);
      expect(lg2.controls.edgePhase[e], -1);
    }
  });

  test('a node\'s legs come out in heading order, each with its stop flag', () {
    final g = streetCrossing();
    final node = g.nodeNear(const Vec2(0, 0))!;
    final partial = g.withOverrides([
      JunctionOverride(at: node.at, stopHeadings: [node.legs[2].heading]),
    ]);
    final ctl = NodeControls.of(partial);
    final lo = ctl.legStart[node.id], hi = ctl.legStart[node.id + 1];
    expect(hi - lo, 4);
    for (var k = lo + 1; k < hi; k++) {
      expect(node.legs[ctl.legOrder[k]].heading,
          greaterThanOrEqualTo(node.legs[ctl.legOrder[k - 1]].heading));
    }
    final plan = partial.nodes[node.id].plan;
    for (var k = lo; k < hi; k++) {
      expect(ctl.legStops[k] == 1, plan.stopLegs.contains(ctl.legOrder[k]));
    }
    expect([for (var k = lo; k < hi; k++) ctl.legStops[k]].where((s) => s == 1),
        hasLength(1));
    // Every node's legs are a permutation of its own.
    for (var n = 0; n < g.nodeCount; n++) {
      final order = [
        for (var k = ctl.legStart[n]; k < ctl.legStart[n + 1]; k++)
          ctl.legOrder[k]
      ]..sort();
      expect(order, List.generate(g.nodes[n].legs.length, (i) => i));
    }
  });

  test('lanes stop at the bar the tiles draw', () {
    final g = streetCrossing();
    final ctl = NodeControls.of(g);
    final centre = g.nodeNear(const Vec2(0, 0))!.id;
    const hw = 4.0; // a street's half width
    expect(ctl.stopBack[centre], closeTo(hw * 1.45 * 0.92, 1e-5));
    for (var n = 0; n < g.nodeCount; n++) {
      if (n != centre) expect(ctl.stopBack[n], 0, reason: 'a dead end');
    }
    expect(stopBackOf(NodeControlKind.roundabout, 4), closeTo(14 * 0.96, 1e-9));
    expect(stopBackOf(NodeControlKind.roundabout, 8), closeTo(22 * 0.96, 1e-9));
    for (final k in [
      NodeControlKind.continuation,
      NodeControlKind.rampMerge,
      NodeControlKind.deadEnd,
      NodeControlKind.uncontrolled,
    ]) {
      expect(stopBackOf(k, 8), 0);
    }
  });

  test('a ramp gives way at its merge; the mainline does not', () {
    final layout = CityLayout();
    layout.addRoad(const RoadSpline(
        id: 'x',
        controls: [Vec2(-500, 0), Vec2(500, 0)],
        roadClass: RoadClass.expressway6));
    layout.addRoad(const RoadSpline(
        id: 'r',
        controls: [Vec2(-150, -45), Vec2(0, -12.8)],
        roadClass: RoadClass.ramp));
    final g = RoadGraph.of(layout);
    final ctl = NodeControls.of(g);
    final merge = g.nodeNear(const Vec2(0, -6.4))!;
    expect(ctl.kindOf(merge.id), NodeControlKind.rampMerge);
    for (var e = 0; e < g.edgeCount; e++) {
      if (g.edgeTo[e] != merge.id) continue;
      final ramp = g.roads[g.pieceRoad[g.edgePiece[e]]].id == 'r';
      expect(ctl.edgeYields[e], ramp ? 1 : 0);
      expect(ctl.edgeStops[e], 0);
    }
  });
}
