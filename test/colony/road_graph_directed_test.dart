// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The directed road graph: junctions where road ends meet (in plan AND
/// in height), edges the ways traffic may run, lots hung on the stretch
/// they are entered from.
library;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:flutter_test/flutter_test.dart';

/// The auto lot on [roadId] nearest [p] (by centroid), on the side of the
/// road [north] says.
Parcel lotOn(CityLayout layout, String roadId, Vec2 p, {required bool north}) {
  final lots = layout.autoParcels
      .where((l) => l.roadId == roadId && (l.centroid.n > 0) == north)
      .toList()
    ..sort((a, b) =>
        a.centroid.distanceTo(p).compareTo(b.centroid.distanceTo(p)));
  return lots.first;
}

/// Edges out of the node nearest [p].
List<int> edgesOut(RoadGraph g, Vec2 p) {
  final n = g.nodeNear(p)!;
  return [
    for (var k = g.outStart[n.id]; k < g.outStart[n.id + 1]; k++)
      g.outEdges[k]
  ];
}

void main() {
  test('a crossing is one node of four legs, an all-way stop', () {
    final layout = CityLayout();
    layout.commitRoad(controls: const [Vec2(0, -200), Vec2(0, 200)]);
    layout.commitRoad(controls: const [Vec2(-200, 0), Vec2(200, 0)]);
    final g = RoadGraph.of(layout);
    expect(g.roadCount, 4);
    final j = g.nodeNear(const Vec2(0, 0))!;
    expect(j.legs, hasLength(4));
    expect(j.control, JunctionControl.stop);
    expect(j.plan.stopLegs, {0, 1, 2, 3},
        reason: 'four streets: every leg stops');
    // Four dead ends and the junction; each arm both ways.
    expect(g.nodeCount, 5);
    expect(g.edgeCount, 8);
    // Stop delay on arrival at the junction, none at a dead end.
    for (var e = 0; e < g.edgeCount; e++) {
      final drive = g.edgeLength[e] / g.roadSpeedMps[g.pieceRoad[g.edgePiece[e]]];
      final delay = g.edgeTime[e] - drive;
      final intoJunction = g.edgeTo[e] == j.id;
      expect(delay, closeTo(intoJunction ? RoadGraph.stopDelaySec : 0, 1e-9));
    }
  });

  test('two avenues crossing get signals; an override can take them off',
      () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)],
        roadClass: RoadClass.avenue);
    layout.commitRoad(
        controls: const [Vec2(-200, 0), Vec2(200, 0)],
        roadClass: RoadClass.avenue);
    expect(RoadGraph.of(layout).nodeNear(const Vec2(0, 0))!.control,
        JunctionControl.signals);
    final off = RoadGraph.of(layout, overrides: const [
      JunctionOverride(at: Vec2(2, -1), lights: false),
    ]);
    expect(off.nodeNear(const Vec2(0, 0))!.control, JunctionControl.stop);
    // Too far away to be this junction.
    final far = RoadGraph.of(layout, overrides: const [
      JunctionOverride(at: Vec2(40, 0), lights: false),
    ]);
    expect(far.nodeNear(const Vec2(0, 0))!.control, JunctionControl.signals);
  });

  test('a one-way road runs one way; reversed, the other', () {
    final layout = CityLayout();
    final id = layout
        .commitRoad(
            controls: const [Vec2(0, 0), Vec2(300, 0)],
            roadClass: RoadClass.streetOneWay)
        .roadId;
    var g = RoadGraph.of(layout);
    expect(g.edgeCount, 1);
    expect(g.edgeForward[0], 1);
    expect(g.nodes[g.edgeFrom[0]].at.e, closeTo(0, 1e-6));
    // The start end is the first point of travel.
    final start = g.nodeNear(const Vec2(0, 0))!;
    expect(start.legs.single.startsHere, isTrue);
    expect(start.legs.single.outgoing, isTrue);

    layout.updateRoad(layout.roadById(id)!.copyWith(reversed: true));
    g = RoadGraph.of(layout);
    expect(g.edgeCount, 1);
    expect(g.edgeForward[0], 0);
    expect(g.nodes[g.edgeFrom[0]].at.e, closeTo(300, 1e-6),
        reason: 'traffic now enters at the last point');
    expect(g.nodeNear(const Vec2(0, 0))!.legs.single.outgoing, isFalse);
    expect(g.nodeNear(const Vec2(300, 0))!.legs.single.outgoing, isTrue);
  });

  test('rail is not in the graph', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)],
        roadClass: RoadClass.rail);
    layout.commitRoad(controls: const [Vec2(-200, 0), Vec2(200, 0)]);
    final g = RoadGraph.of(layout);
    for (final r in g.roads) {
      expect(r.roadClass.isRail, isFalse);
    }
    // The street, split at the level crossing, carries on through it: two
    // ends meeting, no junction.
    final x = g.nodeNear(const Vec2(0, 0))!;
    expect(x.legs, hasLength(2));
    expect(x.control, JunctionControl.none);
  });

  test('a lot on a four-lane road is reached from its own side only', () {
    final layout = CityLayout();
    final id = layout
        .commitRoad(
            controls: const [Vec2(0, 0), Vec2(400, 0)],
            roadClass: RoadClass.avenue)
        .roadId;
    final g = RoadGraph.of(layout);
    // Drawn east: the south kerb is on the right of eastbound traffic.
    final south = g.accessOf(lotOn(layout, id, const Vec2(200, -20), north: false).id)!;
    expect(south.forward, isTrue);
    expect(south.backward, isFalse);
    final north = g.accessOf(lotOn(layout, id, const Vec2(200, 20), north: true).id)!;
    expect(north.forward, isFalse);
    expect(north.backward, isTrue);

    // A two-lane street has no median: either way.
    final street = CityLayout();
    final sid = street
        .commitRoad(controls: const [Vec2(0, 0), Vec2(400, 0)])
        .roadId;
    final sg = RoadGraph.of(street);
    final any = sg.accessOf(lotOn(street, sid, const Vec2(200, 20), north: true).id)!;
    expect(any.forward && any.backward, isTrue);
  });

  test('a lot on a one-way road is entered in its travel direction', () {
    final layout = CityLayout();
    final id = layout
        .commitRoad(
            controls: const [Vec2(0, 0), Vec2(400, 0)],
            roadClass: RoadClass.streetOneWay)
        .roadId;
    final g = RoadGraph.of(layout);
    for (final north in [true, false]) {
      final a = g.accessOf(
          lotOn(layout, id, Vec2(200, north ? 20 : -20), north: north).id)!;
      expect(a.forward, isTrue);
      expect(a.backward, isFalse);
    }
  });

  test('an end on a deck meets only ends at its level', () {
    RoadGraph graphOf(RoadDeck? deck, {RoadDeck? other}) {
      final layout = CityLayout();
      layout.addRoad(RoadSpline(
          id: 'a', controls: const [Vec2(-200, 0), Vec2(0, 0)], deck: other));
      layout.addRoad(RoadSpline(
          id: 'b', controls: const [Vec2(0, 0), Vec2(200, 0)], deck: deck));
      return RoadGraph.of(layout);
    }

    // A draped street's end and a raised deck's end in the same place: the
    // deck is twelve metres up — no junction.
    const raised = RoadDeck(
        startM: 12, endM: 12, startOffsetM: 12, endOffsetM: 12);
    expect(graphOf(raised).nodeCount, 4);
    // Laid at grade at that end: it meets the street.
    const ramped =
        RoadDeck(startM: 0, endM: 12, startOffsetM: 0, endOffsetM: 12);
    expect(graphOf(ramped).nodeCount, 3);
    // Two decks at one height meet; four metres apart they do not.
    const high = RoadDeck(
        startM: 20, endM: 20, startOffsetM: 20, endOffsetM: 20);
    const higher = RoadDeck(
        startM: 24, endM: 24, startOffsetM: 24, endOffsetM: 24);
    expect(graphOf(high, other: high).nodeCount, 3);
    expect(graphOf(higher, other: high).nodeCount, 4);
  });

  test('a dead end lying against a road joins it part way along', () {
    final layout = CityLayout();
    // Raw inserts: nothing is split, so the stub's end touches the street
    // mid-block with no road end there to meet.
    layout.addRoad(const RoadSpline(
        id: 'main', controls: [Vec2(-200, 0), Vec2(200, 0)]));
    layout.addRoad(const RoadSpline(
        id: 'stub', controls: [Vec2(0, 5), Vec2(0, 150)]));
    final g = RoadGraph.of(layout);
    final t = g.nodeNear(const Vec2(0, 2))!;
    expect(t.legs, hasLength(3), reason: 'both ways along main, and the stub');
    expect(t.legRoadIds.where((id) => id == 'main'), hasLength(2));
    // Main is two pieces now, and a car from the stub can go either way.
    final main = g.roadNoOf('main')!;
    expect(g.roadFirstPiece[main + 1] - g.roadFirstPiece[main], 2);
    expect(edgesOut(g, const Vec2(0, 2)), hasLength(3));
  });

  test('a hand-drawn lot is served by the nearest road within reach', () {
    final layout = CityLayout();
    final id =
        layout.commitRoad(controls: const [Vec2(0, 0), Vec2(600, 0)]).roadId;
    // A big site well back from the road; its near edge is 60 m off.
    final near = layout.addManualParcel(const [
      Vec2(200, -60),
      Vec2(200, -400),
      Vec2(500, -400),
      Vec2(500, -60),
    ].reversed.toList())!;
    final far = layout.addManualParcel(const [
      Vec2(200, 200),
      Vec2(500, 200),
      Vec2(500, 500),
      Vec2(200, 500),
    ])!;
    final g = RoadGraph.of(layout);
    final a = g.accessOf(near.id)!;
    expect(a.roadId, id);
    expect(a.sM, inInclusiveRange(200, 500));
    expect(g.accessOf(far.id), isNull, reason: '200 m off is out of reach');
  });

  test('the landing site is the nearest point of the network', () {
    final layout = CityLayout();
    layout.commitRoad(controls: const [Vec2(-300, 50), Vec2(300, 50)]);
    final g = RoadGraph.of(layout);
    expect(g.rootPiece, 0);
    expect(g.rootS, closeTo(300, 1));
    expect(g.rootDirs, RoadGraph.forwardBit | RoadGraph.backwardBit);
  });

  test('two builds of one layout number everything alike', () {
    final layout = CityLayout();
    for (var i = 0; i < 4; i++) {
      final x = -150.0 + i * 100;
      layout.commitRoad(
          controls: [Vec2(x, -180), Vec2(x, 180)], regenerateLots: false);
      layout.commitRoad(
          controls: [Vec2(-180, x), Vec2(180, x)], regenerateLots: false);
    }
    layout.regenerate();
    final a = RoadGraph.of(layout), b = RoadGraph.of(layout);
    expect(a.nodeCount, b.nodeCount);
    expect(a.edgeFrom, b.edgeFrom);
    expect(a.edgeTo, b.edgeTo);
    expect(a.edgeTime, b.edgeTime);
    expect(a.lotPiece, b.lotPiece);
    // Sixteen crossings of four legs, and every inner arm both ways.
    expect(a.nodes.where((n) => n.legs.length == 4), hasLength(16));
  });
}
