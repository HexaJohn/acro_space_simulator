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
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
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

/// Seconds edge [e] loses at the node it arrives at: its time less its
/// driving time.
double delayOf(RoadGraph g, int e) =>
    g.edgeTime[e] - g.edgeLength[e] / g.roadSpeedMps[g.pieceRoad[g.edgePiece[e]]];

/// The delay of every edge arriving at [node].
List<double> arrivalDelays(RoadGraph g, RoadNode node) => [
      for (var e = 0; e < g.edgeCount; e++)
        if (g.edgeTo[e] == node.id) delayOf(g, e)
    ];

/// The junction the tiles draw nearest [p], or null for none: [layout]'s
/// road ends as the tile bucketing hands them to the mesher — only the
/// classes that join junctions, each end with the point in along its road
/// — through [RoadMesher.junctionsFromEnds], in a flat local frame.
RoadJunction? tilesPlanNear(CityLayout layout, Vec2 p) {
  final ends = <RoadEnd>[];
  for (final (_, rec) in layout.roadIndex.indexed) {
    final road = rec.road;
    if (!road.roadClass.joinsJunctions || rec.sampleCount < 2) continue;
    Vector3 at(int i) => Vector3(rec.e[i], rec.n[i], 0);
    final last = rec.sampleCount - 1;
    ends
      ..add(RoadEnd(at(0), at(1), road.halfWidth, road.roadClass,
          collector: road.collector, isStart: true))
      ..add(RoadEnd(at(last), at(last - 1), road.halfWidth, road.roadClass,
          collector: road.collector));
  }
  RoadJunction? best;
  for (final j in RoadMesher.junctionsFromEnds(ends)) {
    if (Vec2(j.at.x, j.at.y).distanceTo(p) <= 12) best = j;
  }
  return best;
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
    // deck is twelve metres up on its piers — no junction.
    const raised = RoadDeck(
        startM: 12,
        endM: 12,
        startOffsetM: 12,
        endOffsetM: 12,
        structures: [(0.0, 200.0)]);
    expect(graphOf(raised).nodeCount, 4);
    // Graded into the ground at that end: it meets the street.
    const ramped = RoadDeck(
        startM: 0,
        endM: 12,
        startOffsetM: 0,
        endOffsetM: 12,
        structures: [(40.0, 200.0)]);
    expect(graphOf(ramped).nodeCount, 3);
    // Two decks meet short of the grade separation — four metres apart is
    // one junction in the air, as the layout cuts it; five is not.
    RoadDeck onPiers(double h) => RoadDeck(
        startM: h,
        endM: h,
        startOffsetM: h,
        endOffsetM: h,
        structures: const [(0.0, 200.0)]);
    expect(graphOf(onPiers(20), other: onPiers(20)).nodeCount, 3);
    expect(graphOf(onPiers(24), other: onPiers(20)).nodeCount, 3);
    expect(graphOf(onPiers(25), other: onPiers(20)).nodeCount, 4);
  });

  test("the layout's junctions are the graph's: one grade-separation rule",
      () {
    // Two raised streets crossing on their piers, four metres apart: under
    // the grade separation, so the layout cuts both into a junction — and
    // traffic can turn there.
    RoadDeck onPiers(double h) => RoadDeck(
        startM: h,
        endM: h,
        startOffsetM: h,
        endOffsetM: h,
        structures: const [(0.0, 400.0)]);
    final decks = CityLayout();
    decks.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)], deck: onPiers(20));
    decks.commitRoad(
        controls: const [Vec2(-200, 0), Vec2(200, 0)], deck: onPiers(24));
    final g = RoadGraph.of(decks);
    expect(g.roadCount, 4, reason: 'the layout cut both');
    final x = g.nodeNear(const Vec2(0, 0))!;
    expect(x.legs, hasLength(4));
    expect(x.atGrade, isFalse);
    expect(edgesOut(g, const Vec2(0, 0)), hasLength(4));

    // A road sunk one 3 m step into a cutting (3 m of cover is short of a
    // tunnel), ending on a street: the snap lands it on the street and the
    // layout cuts the street at the T.
    const cutting =
        RoadDeck(startM: -3, endM: -3, startOffsetM: -3, endOffsetM: -3);
    final t = CityLayout();
    t.commitRoad(controls: const [Vec2(-200, 0), Vec2(200, 0)]);
    t.commitRoad(controls: const [Vec2(0, 150), Vec2(0, 0)], deck: cutting);
    final tg = RoadGraph.of(t);
    expect(tg.roadCount, 3, reason: 'the layout cut the street');
    final tj = tg.nodeNear(const Vec2(0, 0))!;
    expect(tj.legs, hasLength(3), reason: 'the sunk road is no island');
    expect(tj.atGrade, isTrue);

    // Lying against the street with nothing cut, it joins part way along;
    // in its tunnel it passes under.
    RoadGraph stub(RoadDeck deck) {
      final layout = CityLayout();
      layout.addRoad(const RoadSpline(
          id: 'main', controls: [Vec2(-200, 0), Vec2(200, 0)]));
      layout.addRoad(RoadSpline(
          id: 'sunk', controls: const [Vec2(0, 5), Vec2(0, 150)], deck: deck));
      return RoadGraph.of(layout);
    }

    expect(stub(cutting).nodeNear(const Vec2(0, 2))!.legs, hasLength(3));
    const tunnel = RoadDeck(
        startM: -12,
        endM: -12,
        startOffsetM: -12,
        endOffsetM: -12,
        tunnels: [(0.0, 145.0)]);
    expect(stub(tunnel).nodeCount, 4);
  });

  test('an alley meeting a street is a curb cut: no stop, as the tiles '
      'draw it', () {
    final layout = CityLayout();
    layout.commitRoad(controls: const [Vec2(-200, 0), Vec2(200, 0)]);
    layout.commitRoad(
        controls: const [Vec2(0, 0), Vec2(0, 150)],
        roadClass: RoadClass.alley);
    final g = RoadGraph.of(layout);
    final t = g.nodeNear(const Vec2(0, 0))!;
    // Still a way in and out for routing...
    expect(t.legs, hasLength(3));
    expect(edgesOut(g, const Vec2(0, 0)), hasLength(3));
    // ...but no junction: the street runs on past it, nobody waits.
    expect(t.control, JunctionControl.none);
    expect(arrivalDelays(g, t), everyElement(0.0));
    expect(tilesPlanNear(layout, const Vec2(0, 0)), isNull,
        reason: 'the tiles draw nothing there either');
  });

  test('an alley at a crossing never stops, and never takes a stop sign',
      () {
    // Raw inserts, the alley first, so its leg is the node's first and the
    // stop legs have to be numbered past it.
    final layout = CityLayout();
    layout.addRoad(const RoadSpline(
        id: 'alley',
        controls: [Vec2(0, 0), Vec2(-100, -100)],
        roadClass: RoadClass.alley));
    for (final (id, to) in const [
      ('n', Vec2(0, 200)),
      ('s', Vec2(0, -200)),
      ('e', Vec2(200, 0)),
      ('w', Vec2(-200, 0)),
    ]) {
      layout.addRoad(RoadSpline(id: id, controls: [const Vec2(0, 0), to]));
    }
    final g = RoadGraph.of(layout);
    final x = g.nodeNear(const Vec2(0, 0))!;
    expect(x.legRoadIds.first, 'alley');
    expect(x.control, JunctionControl.stop);
    expect(x.plan.stopLegs, {1, 2, 3, 4}, reason: 'the four streets');
    final tiles = tilesPlanNear(layout, const Vec2(0, 0))!;
    expect(tiles.control, x.control);
    expect(tiles.stopLegs, hasLength(x.plan.stopLegs.length));
    for (var e = 0; e < g.edgeCount; e++) {
      if (g.edgeTo[e] != x.id) continue;
      final alley = x.legRoadIds[g.edgeLeg[e]] == 'alley';
      expect(delayOf(g, e), alley ? 0.0 : RoadGraph.stopDelaySec);
    }
    // The player names every leg a stop, the alley's too: it is no leg of
    // the drawn junction, so it takes no sign — on a re-plan as on a build.
    final every = JunctionOverride(
        at: const Vec2(0, 0), stopHeadings: [for (final l in x.legs) l.heading]);
    final patched = g.withOverrides([every]).nodeNear(const Vec2(0, 0))!;
    expect(patched.plan.stopLegs, {1, 2, 3, 4});
    expect(
        RoadGraph.of(layout, overrides: [every])
            .nodeNear(const Vec2(0, 0))!
            .plan
            .stopLegs,
        patched.plan.stopLegs);
  });

  test('a road leaving the through road stops nothing on it', () {
    // A highway's exit ramp: the mainline runs on past it.
    final exit = CityLayout();
    exit.commitRoad(
        controls: const [Vec2(-400, 0), Vec2(400, 0)],
        roadClass: RoadClass.motorway);
    exit.commitRoad(
        controls: const [Vec2(0, 0), Vec2(0, 150)], roadClass: RoadClass.ramp);
    final g = RoadGraph.of(exit);
    final x = g.nodeNear(const Vec2(0, 0))!;
    expect(x.legs, hasLength(3));
    expect(x.plan.stopLegs, isEmpty);
    expect(arrivalDelays(g, x), everyElement(0.0));
    // A one-way street leaving an avenue: nothing crosses the avenue.
    final side = CityLayout();
    side.commitRoad(
        controls: const [Vec2(-200, 0), Vec2(200, 0)],
        roadClass: RoadClass.avenue);
    side.commitRoad(
        controls: const [Vec2(0, 0), Vec2(0, 150)],
        roadClass: RoadClass.streetOneWay);
    final sg = RoadGraph.of(side);
    final sx = sg.nodeNear(const Vec2(0, 0))!;
    expect(sx.legs, hasLength(3));
    expect(sx.plan.stopLegs, isEmpty);
    expect(arrivalDelays(sg, sx), everyElement(0.0));
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

  test('a rename or an override patches the graph; a new class rebuilds it',
      () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)],
        roadClass: RoadClass.avenue);
    layout.commitRoad(
        controls: const [Vec2(-200, 0), Vec2(200, 0)],
        roadClass: RoadClass.avenue);
    final g = RoadGraph.of(layout);
    expect(g.refreshedFor(layout), same(g), reason: 'nothing changed');

    // Renamed: routing never reads a name.
    final id = layout.roads.first.id;
    layout.updateRoad(layout.roadById(id)!.copyWith(name: 'High Street'));
    final renamed = g.refreshedFor(layout)!;
    expect(renamed.sharesStructureWith(g), isTrue);
    expect(renamed.roads[renamed.roadNoOf(id)!].name, 'High Street');
    expect(renamed.edgeTime, same(g.edgeTime));

    // The lights taken off: the crossing re-planned exactly as a rebuild
    // plans it, nothing else touched.
    const off = [JunctionOverride(at: Vec2(2, -1), lights: false)];
    final patched = renamed.refreshedFor(layout, overrides: off)!;
    final rebuilt = RoadGraph.of(layout, overrides: off);
    expect(patched.sharesStructureWith(g), isTrue);
    expect(patched.nodeNear(const Vec2(0, 0))!.control, JunctionControl.stop);
    expect(patched.edgeTime, rebuilt.edgeTime);
    for (var n = 0; n < rebuilt.nodeCount; n++) {
      expect(patched.nodes[n].control, rebuilt.nodes[n].control);
      expect(patched.nodes[n].plan.stopLegs, rebuilt.nodes[n].plan.stopLegs);
    }
    // And back on.
    final back = patched.withOverrides(const []);
    expect(back.nodeNear(const Vec2(0, 0))!.control, JunctionControl.signals);
    expect(back.edgeTime, g.edgeTime);

    // A different class is a different graph.
    layout.updateRoad(
        layout.roadById(id)!.copyWith(roadClass: RoadClass.street));
    expect(patched.refreshedFor(layout, overrides: off), isNull);
  });

  test('a building off the plat hangs on the nearest road within reach', () {
    final layout = CityLayout();
    final id =
        layout.commitRoad(controls: const [Vec2(0, 0), Vec2(600, 0)]).roadId;
    final g = RoadGraph.of(layout);
    final near = g.attachFootprint(const [
      Vec2(290, -70),
      Vec2(310, -70),
      Vec2(310, -50),
      Vec2(290, -50),
    ]);
    expect(near, isNotNull);
    expect(g.roads[g.pieceRoad[near!.piece]].id, id);
    expect(near.sM, closeTo(300, 12));
    expect(near.dirs, RoadGraph.forwardBit | RoadGraph.backwardBit);
    expect(
        g.attachFootprint(const [
          Vec2(290, -300),
          Vec2(310, -300),
          Vec2(310, -280),
          Vec2(290, -280),
        ]),
        isNull,
        reason: '280 m off is out of reach');
  });
}
