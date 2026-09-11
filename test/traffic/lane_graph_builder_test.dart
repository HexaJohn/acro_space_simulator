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
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The lane graph on the networks the design names (docs/plans/
/// agent-traffic.md §17.1): each case is a shape of road a player or the
/// generator really builds.
void main() {
  LaneGraph lanesOf(CityLayout layout) =>
      LaneGraphBuilder.build(RoadGraph.of(layout));

  /// The id of the edge of road [roadId] running first point to last (or,
  /// [forward] false, the other way) that leaves node [from] (−1: any).
  int edgeOf(LaneGraph lg, String roadId, {bool forward = true, int from = -1}) {
    final g = lg.graph;
    for (var e = 0; e < lg.edgeCount; e++) {
      if (g.roads[lg.edgeRoad[e]].id != roadId) continue;
      if ((lg.edgeForward[e] == 1) != forward) continue;
      if (from >= 0 && lg.edgeFrom[e] != from) continue;
      return e;
    }
    return -1;
  }

  /// The connectors leaving any lane of [edge].
  List<int> consFrom(LaneGraph lg, int edge) => [
        for (var c = lg.laneConStart[lg.edgeLaneBase[edge]];
            c < lg.laneConStart[lg.edgeLaneBase[edge] + lg.edgeLaneCount[edge]];
            c++)
          c
      ];

  test('the starter crossroads: an all-way stop, twelve movements across '
      'it and a turning circle at every end', () {
    final lg = LaneGraphBuilder.build(starterKit().roadGraph);
    expect(lg.nodeCount, 5);
    expect(lg.edgeCount, 8);
    expect(lg.laneCount, 8, reason: 'one lane each way on every arm');
    final centre = lg.graph.nodeNear(const Vec2(0, 0))!.id;
    expect(lg.kindOf(centre), NodeControlKind.allWayStop);
    var across = 0, uTurns = 0;
    for (var c = 0; c < lg.connectorCount; c++) {
      if (lg.connectorKindOf(c) == ConnectorKind.shift) {
        fail('one lane: nowhere to shift to');
      }
      if (lg.conNode[c] == centre) {
        expect(lg.turnOf(c), isNot(TurnClass.uTurn));
        across++;
      } else {
        expect(lg.turnOf(c), TurnClass.uTurn);
        uTurns++;
      }
    }
    expect(across, 12, reason: 'lane 0 makes right, straight and left');
    expect(uTurns, 4);
    // Every approach to the centre makes all three turns.
    for (var i = lg.inStart[centre]; i < lg.inStart[centre + 1]; i++) {
      final turns = {for (final c in consFrom(lg, lg.inEdges[i])) lg.turnOf(c)};
      expect(turns, {TurnClass.right, TurnClass.straight, TurnClass.left});
    }
  });

  test('a street stopping against another mid-block joins it at the '
      'graph\'s attach node', () {
    final layout = CityLayout();
    layout.addRoad(
        const RoadSpline(id: 'main', controls: [Vec2(-200, 0), Vec2(200, 0)]));
    layout.addRoad(
        const RoadSpline(id: 'stub', controls: [Vec2(0, 150), Vec2(0, 5)]));
    final lg = lanesOf(layout);
    final t = lg.graph.nodeNear(const Vec2(0, 2))!;
    expect(t.legs, hasLength(3));
    expect(lg.kindOf(t.id), NodeControlKind.allWayStop);
    // From the stub, both ways along main: a right and a left.
    final down = edgeOf(lg, 'stub');
    expect(lg.edgeTo[down], t.id);
    final outs = {for (final c in consFrom(lg, down)) lg.conToEdge(c)};
    expect(outs, hasLength(2));
    expect({for (final c in consFrom(lg, down)) lg.turnOf(c)},
        {TurnClass.right, TurnClass.left});
  });

  test('a ramp ending 12.8 m beside an expressway joins it, and its one '
      'connector lands in the kerb lane of its own carriageway', () {
    final layout = CityLayout();
    layout.addRoad(const RoadSpline(
        id: 'x',
        controls: [Vec2(-500, 0), Vec2(500, 0)],
        roadClass: RoadClass.expressway6));
    layout.addRoad(const RoadSpline(
        id: 'r',
        controls: [Vec2(-150, -45), Vec2(0, -12.8)],
        roadClass: RoadClass.ramp));
    final lg = lanesOf(layout);
    final node = lg.graph.nodeNear(const Vec2(0, -6.4))!;
    expect(node.legs, hasLength(3));
    expect(lg.kindOf(node.id), NodeControlKind.rampMerge);
    final ramp = edgeOf(lg, 'r');
    expect(lg.edgeTo[ramp], node.id);
    final cons = consFrom(lg, ramp);
    expect(cons, hasLength(1));
    final to = lg.conToEdge(cons.single);
    expect(lg.graph.roads[lg.edgeRoad[to]].id, 'x');
    expect(lg.edgeForward[to], 1, reason: 'eastbound: the ramp is south of it');
    expect(lg.laneIdx[lg.conToLane[cons.single]], 0);
    expect(lg.roleOf(cons.single), ConnectorRole.mergeYield);
    // The eastbound mainline runs on, all three lanes aligned.
    final east = edgeOf(lg, 'x', from: -1);
    final into = [
      for (var e = 0; e < lg.edgeCount; e++)
        if (lg.edgeTo[e] == node.id && lg.edgeForward[e] == 1 && e != ramp) e
    ].single;
    expect(east, isNot(-1));
    expect(
        {for (final c in consFrom(lg, into)) (lg.laneIdx[lg.conFromLane[c]], lg.laneIdx[lg.conToLane[c]])},
        {(0, 0), (1, 1), (2, 2)});
  });

  test('a cloverleaf loop ramp meets the bridged over-road\'s split end, '
      'bridges or no', () {
    final layout = CityLayout();
    layout.addRoad(const RoadSpline(
        id: 'a',
        controls: [Vec2(-400, 0), Vec2(0, 0)],
        roadClass: RoadClass.expressway4,
        bridges: [(250.0, 400.0)]));
    layout.addRoad(const RoadSpline(
        id: 'b',
        controls: [Vec2(0, 0), Vec2(400, 0)],
        roadClass: RoadClass.expressway4,
        bridges: [(0.0, 150.0)]));
    layout.addRoad(const RoadSpline(
        id: 'loop',
        controls: [Vec2(-60, -80), Vec2(-20, -60), Vec2(-5, -15), Vec2(0, -5)],
        roadClass: RoadClass.ramp));
    final lg = lanesOf(layout);
    final node = lg.graph.nodeNear(const Vec2(0, -2))!;
    expect(node.legRoadIds.toSet(), {'a', 'b', 'loop'});
    expect(lg.kindOf(node.id), NodeControlKind.rampMerge);
    final cons = consFrom(lg, edgeOf(lg, 'loop'));
    expect(cons, hasLength(1));
    expect(lg.graph.roads[lg.edgeRoad[lg.conToEdge(cons.single)]].id, 'b');
    expect(lg.laneIdx[lg.conToLane[cons.single]], 0);
  });

  test('an elevated road crossing a street in plan shares no node with it',
      () {
    // A viaduct on its deck, twelve metres up; a street passing beneath
    // it and another ending right under it — which the network must not
    // join to the deck above.
    const deck =
        RoadDeck(startM: 12, endM: 12, startOffsetM: 12, endOffsetM: 12);
    final layout = CityLayout();
    layout.addRoad(const RoadSpline(
        id: 'deck',
        controls: [Vec2(-300, 0), Vec2(300, 0)],
        roadClass: RoadClass.elevated,
        deck: deck));
    layout.addRoad(const RoadSpline(
        id: 'under', controls: [Vec2(0, -300), Vec2(0, 300)]));
    layout.addRoad(const RoadSpline(
        id: 'stops', controls: [Vec2(100, -300), Vec2(100, 0)]));
    final lg = lanesOf(layout);
    final end = lg.graph.nodeNear(const Vec2(100, 0))!;
    expect(end.legs, hasLength(1), reason: 'a dead end under the deck');
    expect(lg.kindOf(end.id), NodeControlKind.deadEnd);
    for (final node in lg.graph.nodes) {
      final classes = {for (final l in node.legs) l.roadClass};
      expect(classes.contains(RoadClass.elevated) && classes.contains(RoadClass.street),
          isFalse,
          reason: 'at ${node.at}');
    }
    for (var c = 0; c < lg.connectorCount; c++) {
      final a = lg.graph.roads[lg.edgeRoad[lg.conFromEdge(c)]].roadClass;
      final b = lg.graph.roads[lg.edgeRoad[lg.conToEdge(c)]].roadClass;
      expect(a == b, isTrue, reason: 'no way between the deck and the street');
    }
  });

  test('a reversed one-way road runs backward only', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, 0), Vec2(300, 0)],
        roadClass: RoadClass.streetOneWay,
        reversed: true,
        regenerateLots: false);
    final lg = lanesOf(layout);
    expect(lg.edgeCount, 1);
    expect(lg.edgeForward[0], 0);
    expect(lg.edgeReverse[0], -1);
    expect(lg.edgeLaneCount[0], 2);
    // Right of travel, which runs west: the kerb lane is the north one.
    expect(lg.laneOff[lg.laneOf(0, 0)], closeTo(2.0, 1e-6));
    expect(lg.laneOff[lg.laneOf(0, 1)], closeTo(-2.0, 1e-6));
    // A one-way road's two ends are no place to turn: nothing leaves.
    expect(lg.connectorCount, 0);
  });

  group('tapers keep their lanes to the seam', () {
    test('six lanes into four: the seam is a continuation that drops the '
        'kerb lane into the new kerb lane', () {
      final layout = CityLayout();
      layout.addRoad(RoadSpline(
          id: 'x6',
          controls: const [Vec2(-500, 0), Vec2(0, 0)],
          roadClass: RoadClass.expressway6,
          endHalfWidthM: RoadClass.expressway4.halfWidth));
      layout.addRoad(const RoadSpline(
          id: 'x4',
          controls: [Vec2(0, 0), Vec2(500, 0)],
          roadClass: RoadClass.expressway4));
      final lg = lanesOf(layout);
      final seam = lg.graph.nodeNear(const Vec2(0, 0))!;
      expect(seam.control, JunctionControl.merge);
      expect(lg.kindOf(seam.id), NodeControlKind.continuation,
          reason: 'a merge with no ramp is a seam, not a merge');
      final east = edgeOf(lg, 'x6');
      expect(lg.edgeLaneCount[east], 3);
      expect(lg.edgeLaneCount[edgeOf(lg, 'x4')], 2);
      expect(
          {
            for (final c in consFrom(lg, east))
              (lg.laneIdx[lg.conFromLane[c]], lg.laneIdx[lg.conToLane[c]],
                  lg.connectorKindOf(c))
          },
          {
            (2, 1, ConnectorKind.aligned),
            (1, 0, ConnectorKind.aligned),
            (0, 0, ConnectorKind.dropped),
          });
    });

    test('a radial expressway tapered to an avenue\'s width drops three '
        'lanes to two where it meets it', () {
      final layout = CityLayout();
      layout.addRoad(const RoadSpline(
          id: 'ave',
          controls: [Vec2(-400, 0), Vec2(0, 0)],
          roadClass: RoadClass.avenue));
      layout.addRoad(RoadSpline(
          id: 'rad',
          controls: const [Vec2(0, 0), Vec2(800, 0)],
          roadClass: RoadClass.expressway6,
          startHalfWidthM: RoadClass.avenue.halfWidth));
      final lg = lanesOf(layout);
      expect(lg.kindOf(lg.graph.nodeNear(const Vec2(0, 0))!.id),
          NodeControlKind.continuation);
      for (var e = 0; e < lg.edgeCount; e++) {
        expect(lg.edgeLaneCount[e], greaterThan(0));
      }
      final inbound = edgeOf(lg, 'rad', forward: false);
      expect(lg.edgeLaneCount[inbound], 3);
      final cons = consFrom(lg, inbound);
      expect(cons.map((c) => lg.conToEdge(c)).toSet(),
          {edgeOf(lg, 'ave', forward: false)});
      expect(cons.where((c) => lg.connectorKindOf(c) == ConnectorKind.dropped),
          hasLength(1));
    });
  });

  group('the beltway seam', () {
    test('a ring with no interchange is one piece that joins itself', () {
      final layout = CityLayout();
      layout.addRoad(const RoadSpline(
          id: 'belt',
          controls: [
            Vec2(1000, 0),
            Vec2(0, 1000),
            Vec2(-1000, 0),
            Vec2(0, -1000),
            Vec2(1000, 0),
          ],
          roadClass: RoadClass.expressway8));
      final lg = lanesOf(layout);
      final g = lg.graph;
      expect(g.pieceCount, 1);
      expect(g.pieceFrom[0], g.pieceTo[0]);
      final seam = g.pieceFrom[0];
      expect(lg.kindOf(seam), NodeControlKind.continuation);
      for (final e in [edgeOf(lg, 'belt'), edgeOf(lg, 'belt', forward: false)]) {
        final cons = consFrom(lg, e);
        expect(cons, hasLength(4));
        for (final c in cons) {
          expect(lg.conToEdge(c), e, reason: 'round again, never back');
          expect(lg.connectorKindOf(c), ConnectorKind.aligned);
        }
      }
    });

    test('a ring cut by interchanges is ordinary continuations', () {
      final layout = CityLayout();
      layout.addRoad(const RoadSpline(
          id: 'north',
          controls: [Vec2(1000, 0), Vec2(0, 1000), Vec2(-1000, 0)],
          roadClass: RoadClass.expressway8));
      layout.addRoad(const RoadSpline(
          id: 'south',
          controls: [Vec2(-1000, 0), Vec2(0, -1000), Vec2(1000, 0)],
          roadClass: RoadClass.expressway8));
      final lg = lanesOf(layout);
      final g = lg.graph;
      expect(g.nodeCount, 2);
      for (var n = 0; n < g.nodeCount; n++) {
        expect(lg.kindOf(n), NodeControlKind.continuation);
      }
      for (var p = 0; p < g.pieceCount; p++) {
        expect(g.pieceFrom[p], isNot(g.pieceTo[p]));
      }
      final cons = consFrom(lg, edgeOf(lg, 'north'));
      expect({for (final c in cons) lg.conToEdge(c)}, {edgeOf(lg, 'south')});
    });
  });

  test('a dead end turns every lane round into every lane', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, 0), Vec2(300, 0)],
        roadClass: RoadClass.avenue,
        regenerateLots: false);
    final lg = lanesOf(layout);
    final end = lg.graph.nodeNear(const Vec2(300, 0))!.id;
    final cons = [
      for (var i = lg.nodeConStart[end]; i < lg.nodeConStart[end + 1]; i++)
        lg.nodeCons[i]
    ];
    expect(cons, hasLength(4));
    for (final c in cons) {
      expect(lg.connectorKindOf(c), ConnectorKind.uTurn);
      expect(lg.conToEdge(c), lg.edgeReverse[lg.conFromEdge(c)]);
      expect(lg.conLen[c], greaterThan(3.14159 * 4 - 1e-3));
    }
  });

  test('rail is not in the lane graph', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -300), Vec2(0, 300)],
        roadClass: RoadClass.rail,
        regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(-300, 0), Vec2(300, 0)], regenerateLots: false);
    final lg = lanesOf(layout);
    for (var e = 0; e < lg.edgeCount; e++) {
      expect(lg.graph.roads[lg.edgeRoad[e]].roadClass.isRail, isFalse);
    }
    // The street carries on across the level crossing.
    final x = lg.graph.nodeNear(const Vec2(0, 0))!;
    expect(lg.kindOf(x.id), NodeControlKind.continuation);
  });

  test('lane offsets are the road\'s own paint, for every class and dressing',
      () {
    for (final cls in RoadClass.values) {
      if (cls.isRail) continue;
      for (final deco in RoadDecoration.values) {
        final road = RoadSpline(
            id: 'r', controls: const [Vec2(0, 0), Vec2(1, 0)], roadClass: cls,
            decoration: deco);
        final lay = road.lanes;
        final n = lanesPerDirection(road);
        if (lay == null) {
          expect(n, 1);
          expect(laneOffsetRight(road, 0), cls.halfWidth / 2);
          continue;
        }
        expect(n, lay.lanesEachWay);
        for (var k = 0; k < n; k++) {
          expect(laneOffsetRight(road, k), lay.laneOffsets[n - 1 - k],
              reason: '$cls $deco lane $k');
        }
      }
    }
    final lg = LaneGraphBuilder.build(starterKit().roadGraph);
    for (var l = 0; l < lg.laneCount; l++) {
      expect(lg.laneOff[l], 2.0, reason: 'a street\'s lane is 2 m out');
    }
  });

  test('lanes end at the stop bar and connectors bridge the plate', () {
    final lg = LaneGraphBuilder.build(starterKit().roadGraph);
    final centre = lg.graph.nodeNear(const Vec2(0, 0))!.id;
    final back = lg.controls.stopBack[centre];
    expect(back, greaterThan(0));
    for (var e = 0; e < lg.edgeCount; e++) {
      if (lg.edgeTo[e] == centre) {
        expect(lg.edgeLaneS1[e], closeTo(lg.edgeLen[e] - back, 1e-3));
        expect(lg.edgeLaneS0[e], 0, reason: 'from a dead end');
      } else {
        expect(lg.edgeLaneS0[e], closeTo(back, 1e-3));
        expect(lg.edgeLaneS1[e], closeTo(lg.edgeLen[e], 1e-3));
      }
    }
    // A straight across the centre is about the plate's width long.
    for (var c = 0; c < lg.connectorCount; c++) {
      if (lg.conNode[c] == centre && lg.turnOf(c) == TurnClass.straight) {
        expect(lg.conLen[c], closeTo(2 * back, 0.5));
        expect(lg.conVmax[c], kConVmaxCap);
      }
    }
  });

  test('a lane graph built a few items at a time is the one built at once',
      () {
    final g = grid(3).roadGraph;
    final whole = LaneGraphBuilder.build(g);
    // Items: the controls, every edge twice (edges, lanes), every node twice
    // (connectors, conflicts), the packing and the finish.
    final items = 1 + 2 * g.edgeCount + 2 * g.nodeCount + 2;
    for (final budget in [1, 17]) {
      final b = LaneGraphBuilder(g);
      var calls = 1;
      while (!b.step(budget)) {
        calls++;
      }
      expect(calls, (items + budget - 1) ~/ budget);
      final part = b.result;
      expect(part.laneEdge, whole.laneEdge);
      expect(part.laneOff, whole.laneOff);
      expect(part.edgeLaneS0, whole.edgeLaneS0);
      expect(part.edgeLaneS1, whole.edgeLaneS1);
      expect(part.conFromLane, whole.conFromLane);
      expect(part.conToLane, whole.conToLane);
      expect(part.conLen, whole.conLen);
      expect(part.conPts, whole.conPts);
      expect(part.conRole, whole.conRole);
      expect(part.conConflictStart, whole.conConflictStart);
      expect(part.conflictWith, whole.conflictWith);
      expect(part.conflictAtSelf, whole.conflictAtSelf);
      expect(part.moveOut, whole.moveOut);
      expect(part.edgeInMainScc, whole.edgeInMainScc);
    }
  });

  test('connectors that cross know where; a lane splitting two ways does '
      'not conflict with itself', () {
    final lg = LaneGraphBuilder.build(signalised().roadGraph);
    final centre = lg.graph.nodeNear(const Vec2(0, 0))!.id;
    var crossings = 0;
    for (var i = lg.nodeConStart[centre]; i < lg.nodeConStart[centre + 1]; i++) {
      final c = lg.nodeCons[i];
      for (var k = lg.conConflictStart[c]; k < lg.conConflictStart[c + 1]; k++) {
        final o = lg.conflictWith[k];
        expect(lg.conFromLane[o], isNot(lg.conFromLane[c]));
        expect(lg.conNode[o], centre);
        expect(lg.conflictAtSelf[k], inInclusiveRange(0, lg.conLen[c] + 1e-3));
        expect(lg.conflictAtOther[k], inInclusiveRange(0, lg.conLen[o] + 1e-3));
        // Stored both ways round.
        var mirrored = false;
        for (var m = lg.conConflictStart[o]; m < lg.conConflictStart[o + 1]; m++) {
          if (lg.conflictWith[m] == c &&
              lg.conflictAtSelf[m] == lg.conflictAtOther[k] &&
              lg.conflictAtOther[m] == lg.conflictAtSelf[k]) {
            mirrored = true;
          }
        }
        expect(mirrored, isTrue);
        crossings++;
      }
    }
    expect(crossings, greaterThan(0));
    // Every edge of a connected town is in the main strongly connected part.
    for (var e = 0; e < lg.edgeCount; e++) {
      expect(lg.edgeInMainScc[e], 1);
    }
  });
}
