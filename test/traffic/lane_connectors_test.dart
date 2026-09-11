// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_connectors.dart';
import 'package:flutter_test/flutter_test.dart';

/// The connector rules (docs/plans/agent-traffic.md §3.5), on nodes
/// described by hand: which lane may reach which, and never anything a
/// driver could not do.
///
/// Arms here are numbered by where they point: an arm arriving from the
/// south heads north into the node. A four-way node's in-arm `2i` and
/// out-arm `2i + 1` are one stretch's two directions, so each is the
/// other's U-turn.
void main() {
  group('the band rule and the alignment', () {
    test('one lane, three movements: the lane makes all three', () {
      for (var j = 0; j < 3; j++) {
        expect(bandOverlaps(0, j, 1, 3), isTrue);
      }
    });

    test('two lanes, three movements: right and straight from the kerb '
        'lane, straight and left from the inner', () {
      expect([for (var j = 0; j < 3; j++) bandOverlaps(0, j, 2, 3)],
          [true, true, false]);
      expect([for (var j = 0; j < 3; j++) bandOverlaps(1, j, 2, 3)],
          [false, true, true]);
    });

    test('three lanes, three movements: one each', () {
      for (var i = 0; i < 3; i++) {
        expect([for (var j = 0; j < 3; j++) bandOverlaps(i, j, 3, 3)],
            [for (var j = 0; j < 3; j++) i == j]);
      }
    });

    test('every movement holds a lane, and every lane a movement', () {
      for (var n = 1; n <= 5; n++) {
        for (var m = 1; m <= 6; m++) {
          for (var j = 0; j < m; j++) {
            expect([for (var i = 0; i < n; i++) bandOverlaps(i, j, n, m)],
                contains(true),
                reason: 'movement $j of $m on $n lanes');
          }
          for (var i = 0; i < n; i++) {
            expect([for (var j = 0; j < m; j++) bandOverlaps(i, j, n, m)],
                contains(true),
                reason: 'lane $i of $n with $m movements');
          }
        }
      }
    });

    test('lanes pair off from the median: a drop loses the kerb lane', () {
      // 3 -> 2: in-lanes 2 and 1 to 1 and 0; in-lane 0 has none.
      expect([for (var i = 0; i < 3; i++) alignedLane(i, 3, 2)], [-1, 0, 1]);
      // 2 -> 3: in-lanes 1 and 0 to 2 and 1.
      expect([for (var i = 0; i < 2; i++) alignedLane(i, 2, 3)], [1, 2]);
    });

    test('turns are classed by angle; negative is right', () {
      double deg(double d) => d * math.pi / 180;
      expect(turnClassOf(deg(10)), TurnClass.straight);
      expect(turnClassOf(deg(-29)), TurnClass.straight);
      expect(turnClassOf(deg(-90)), TurnClass.right);
      expect(turnClassOf(deg(90)), TurnClass.left);
      expect(turnClassOf(deg(150)), TurnClass.sharp);
      expect(turnClassOf(deg(-150)), TurnClass.sharp);
      // Heading north, turning east, is a right turn.
      expect(turnAngle(0, 1, 1, 0), lessThan(0));
    });
  });

  group('real junctions', () {
    test('a street crossing: the one lane makes right, straight and left, '
        'and no shift exists to make', () {
      final cons = _connect(NodeControlKind.allWayStop, _fourWay(1));
      final fromSouth = cons.where((c) => c.fromEdge == 0).toList();
      expect(fromSouth, hasLength(3));
      expect(_turnsFrom(fromSouth, 0),
          {TurnClass.right, TurnClass.straight, TurnClass.left});
      expect(cons.where((c) => c.kind == ConnectorKind.shift), isEmpty);
      expect(cons.where((c) => c.kind == ConnectorKind.uTurn), isEmpty,
          reason: 'no U-turn at a crossing');
      // Four approaches, three movements each.
      expect(cons, hasLength(12));
    });

    test('an avenue crossing: the kerb lane turns right and goes straight, '
        'the inner lane goes straight and turns left', () {
      final cons =
          _connect(NodeControlKind.signals, _fourWay(2)).where((c) => c.fromEdge == 0);
      expect(_turnsFrom(cons, 0), {TurnClass.right, TurnClass.straight});
      expect(_turnsFrom(cons, 1), {TurnClass.straight, TurnClass.left});
      // Turns land in any lane of the road turned onto.
      expect(
          cons
              .where((c) => c.turn == TurnClass.right)
              .map((c) => c.toLane)
              .toSet(),
          {0, 1});
      // A right turn costs nothing into the kerb lane, one lane's worth into
      // the other; a left, the reverse.
      for (final c in cons.where((c) => c.kind == ConnectorKind.turn)) {
        final natural = c.turn == TurnClass.right ? 0 : 1;
        expect(c.pen, (c.toLane - natural).abs().toDouble());
      }
    });

    test('a six-lane crossing: straight from all three lanes, right from '
        'the kerb lane only, left from the inner only, and a shift each way '
        'on the straight', () {
      final cons =
          _connect(NodeControlKind.signals, _fourWay(3)).where((c) => c.fromEdge == 0).toList();
      expect(_turnsFrom(cons, 0), {TurnClass.right, TurnClass.straight});
      expect(_turnsFrom(cons, 1), {TurnClass.straight});
      expect(_turnsFrom(cons, 2), {TurnClass.straight, TurnClass.left});
      final aligned = cons.where((c) => c.kind == ConnectorKind.aligned);
      expect(aligned.map((c) => (c.fromLane, c.toLane)).toSet(),
          {(0, 0), (1, 1), (2, 2)});
      final shifts = cons.where((c) => c.kind == ConnectorKind.shift);
      expect(shifts.map((c) => (c.fromLane, c.toLane)).toSet(),
          {(0, 1), (1, 0), (1, 2), (2, 1)});
      expect(shifts.every((c) => c.pen == kPenShift), isTrue);
    });

    test('a roundabout lets the innermost lane round, and nothing else', () {
      final cons = _connect(NodeControlKind.roundabout, _fourWay(2))
          .where((c) => c.kind == ConnectorKind.uTurn)
          .toList();
      expect(cons.every((c) => c.fromLane == 1), isTrue);
      expect(cons, hasLength(4 * 2), reason: 'into both lanes, per approach');
      for (final c in cons) {
        expect(c.toEdge, c.fromEdge + 1, reason: 'back the way it came');
      }
    });
  });

  group('continuations and merges', () {
    test('a lane drop is median-aligned and the dropped lane merges into '
        'the kerb lane', () {
      final cons = _connect(NodeControlKind.continuation, _seam(3, 2));
      final east = cons.where((c) => c.fromEdge == 0).toList();
      expect(
          east.map((c) => (c.fromLane, c.toLane, c.kind)).toSet(),
          {
            (2, 1, ConnectorKind.aligned),
            (1, 0, ConnectorKind.aligned),
            (0, 0, ConnectorKind.dropped),
          });
      // The other way, the lane is added and fed from the kerb lane.
      final west = cons.where((c) => c.fromEdge == 2).toList();
      expect(
          west.map((c) => (c.fromLane, c.toLane, c.kind)).toSet(),
          {
            (1, 2, ConnectorKind.aligned),
            (0, 1, ConnectorKind.aligned),
            (0, 0, ConnectorKind.fanOut),
          });
      expect(cons.every((c) => c.turn == TurnClass.straight), isTrue,
          reason: 'the road carries on');
    });

    test('a ramp merges into the kerb lane of its own carriageway, never '
        'the far one', () {
      final cons = _connect(NodeControlKind.rampMerge, _rampNode());
      final fromRamp = cons.where((c) => c.fromEdge == 4).toList();
      expect(fromRamp, hasLength(1));
      expect(fromRamp.single.toEdge, 1, reason: 'the eastbound carriageway');
      expect(fromRamp.single.toLane, 0);
      expect(fromRamp.single.kind, ConnectorKind.merge);
      // The mainline runs on, lane for lane, both ways.
      expect(
          cons
              .where((c) => c.fromEdge == 0)
              .map((c) => (c.toEdge, c.fromLane, c.toLane))
              .toSet(),
          {(1, 0, 0), (1, 1, 1), (1, 2, 2)});
      expect(cons.where((c) => c.fromEdge == 2).map((c) => c.toEdge).toSet(),
          {3});
    });

    test('a ramp leaving takes the kerb lane of the carriageway it leaves '
        'on the right of', () {
      final cons = _connect(NodeControlKind.rampMerge, _rampNode(leaving: true));
      final onto = cons.where((c) => c.toEdge == 5).toList();
      expect(onto, hasLength(1));
      expect((onto.single.fromEdge, onto.single.fromLane), (0, 0));
      expect(onto.single.kind, ConnectorKind.diverge);
    });

    test('a mainline that ends in a ramp runs every lane onto it', () {
      // The eastbound carriageway goes no further than the ramp.
      final arms = (
        ins: [
          const NodeArm(
              edge: 0,
              lanes: 3,
              roadClass: RoadClass.expressway6,
              reverse: 3,
              dirE: 1,
              dirN: 0),
        ],
        outs: [
          const NodeArm(
              edge: 3,
              lanes: 3,
              roadClass: RoadClass.expressway6,
              reverse: 0,
              dirE: -1,
              dirN: 0),
          NodeArm(
              edge: 5,
              lanes: 1,
              roadClass: RoadClass.ramp,
              dirE: math.cos(-0.3),
              dirN: math.sin(-0.3),
              endE: 2,
              endN: -3),
        ],
      );
      final cons = _connect(NodeControlKind.rampMerge, arms);
      expect({for (final c in cons) c.fromLane}, {0, 1, 2},
          reason: 'no lane is stranded');
      expect(cons.every((c) => c.toEdge == 5 && c.toLane == 0), isTrue);
    });

    test('no shift at a continuation, a ramp merge or a stub', () {
      for (final (kind, arms) in [
        (NodeControlKind.continuation, _seam(2, 2)),
        (NodeControlKind.rampMerge, _rampNode()),
        (NodeControlKind.stub, _deadEnd(2)),
      ]) {
        expect(_connect(kind, arms).where((c) => c.kind == ConnectorKind.shift),
            isEmpty,
            reason: '$kind');
      }
    });

    test('a dead end turns every lane round into every lane', () {
      final cons = _connect(NodeControlKind.deadEnd, _deadEnd(2));
      expect(cons, hasLength(4));
      expect(cons.every((c) => c.kind == ConnectorKind.uTurn), isTrue);
      expect(cons.every((c) => c.turn == TurnClass.uTurn), isTrue);
    });

    test('an arriving edge the rules do not foresee still gets a way on', () {
      // Two ramps meeting at a merge node with no mainline at all.
      final arms = (
        ins: [
          const NodeArm(
              edge: 0, lanes: 1, roadClass: RoadClass.ramp, dirE: 1, dirN: 0),
        ],
        outs: [
          const NodeArm(
              edge: 1, lanes: 1, roadClass: RoadClass.ramp, dirE: 1, dirN: 0),
        ],
      );
      final cons = _connect(NodeControlKind.rampMerge, arms);
      expect(cons.map((c) => (c.fromEdge, c.toEdge)).toList(), [(0, 1)]);
    });
  });

  group('geometry', () {
    test('a right-angle turn is a parabola, tightest at its apex', () {
      final pts = Float64List(16);
      final shape = connectorCurve(0, 0, 0, 1, 8, 8, 1, 0, pts, 0);
      expect(pts[0], 0);
      expect(pts[1], 0);
      expect(pts[14], closeTo(8, 1e-12));
      expect(pts[15], closeTo(8, 1e-12));
      expect(shape.rMin, closeTo(8 / math.sqrt2, 1e-9));
      expect(connectorVmax(shape.rMin),
          closeTo(math.sqrt(3 * 8 / math.sqrt2), 1e-9));
      // Longer than the chord, shorter than the two legs.
      expect(shape.length, greaterThan(8 * math.sqrt2));
      expect(shape.length, lessThan(16));
    });

    test('a straight connector is capped, not infinite', () {
      final pts = Float64List(16);
      final shape = connectorCurve(0, 0, 0, 1, 0, 20, 0, 1, pts, 0);
      expect(shape.length, closeTo(20, 1e-9));
      expect(connectorVmax(shape.rMin), kConVmaxCap);
    });

    test('a U-turn is a half circle of half the gap, never under 4 m', () {
      final pts = Float64List(16);
      final wide = uTurnCurve(6, 0, 0, 1, -6, 0, pts, 0);
      expect(wide.length, closeTo(math.pi * 6, 1e-9));
      expect(pts[14], closeTo(-6, 1e-9), reason: 'it ends in the other lane');
      final narrow = uTurnCurve(2, 0, 0, 1, -2, 0, pts, 0);
      expect(narrow.length, closeTo(math.pi * kMinUTurnRadiusM, 1e-9));
      expect(narrow.rMin, kMinUTurnRadiusM);
    });

    test('crossing paths meet where they cross', () {
      final a = Float64List(16), b = Float64List(16);
      connectorCurve(0, -10, 0, 1, 0, 10, 0, 1, a, 0);
      connectorCurve(-10, 0, 1, 0, 10, 0, 1, 0, b, 0);
      final hit = firstCrossing(a, 0, b, 0)!;
      expect(hit.arcA, closeTo(10, 1e-9));
      expect(hit.arcB, closeTo(10, 1e-9));
      final c = Float64List(16);
      connectorCurve(20, -10, 0, 1, 20, 10, 0, 1, c, 0);
      expect(firstCrossing(a, 0, c, 0), isNull);
    });
  });
}

/// One connector as the rules emitted it.
typedef _Con = ({
  int fromEdge,
  int fromLane,
  int toEdge,
  int toLane,
  ConnectorKind kind,
  TurnClass turn,
  double pen,
});

typedef _Arms = ({List<NodeArm> ins, List<NodeArm> outs});

List<_Con> _connect(NodeControlKind kind, _Arms arms) {
  final out = <_Con>[];
  connectNode(kind, arms.ins, arms.outs,
      (from, fromLane, to, toLane, k, turn, theta, pen) {
    out.add((
      fromEdge: from.edge,
      fromLane: fromLane,
      toEdge: to.edge,
      toLane: toLane,
      kind: k,
      turn: turn,
      pen: pen,
    ));
  });
  return out;
}

Set<TurnClass> _turnsFrom(Iterable<_Con> cons, int lane) =>
    {for (final c in cons) if (c.fromLane == lane) c.turn};

/// A four-way crossing of two-way roads of [lanes] lanes each way. Approach
/// i comes from the south, west, north and east in turn: in-arm `2i`
/// arrives heading into the node, out-arm `2i + 1` leaves back that way.
_Arms _fourWay(int lanes) {
  const from = [(0.0, -1.0), (-1.0, 0.0), (0.0, 1.0), (1.0, 0.0)];
  final cls = switch (lanes) {
    1 => RoadClass.street,
    2 => RoadClass.avenue,
    _ => RoadClass.boulevard,
  };
  return (
    ins: [
      for (var i = 0; i < 4; i++)
        NodeArm(
            edge: 2 * i,
            lanes: lanes,
            roadClass: cls,
            reverse: 2 * i + 1,
            dirE: -from[i].$1,
            dirN: -from[i].$2),
    ],
    outs: [
      for (var i = 0; i < 4; i++)
        NodeArm(
            edge: 2 * i + 1,
            lanes: lanes,
            roadClass: cls,
            reverse: 2 * i,
            dirE: from[i].$1,
            dirN: from[i].$2),
    ],
  );
}

/// Where a road of [west] lanes each way meets one of [east], end to end:
/// edge 0 runs east into the node and edge 1 on out of it; edge 2 runs west
/// into it and edge 3 on.
_Arms _seam(int west, int east) {
  RoadClass cls(int n) => n >= 3 ? RoadClass.expressway6 : RoadClass.expressway4;
  return (
    ins: [
      NodeArm(edge: 0, lanes: west, roadClass: cls(west), reverse: 3, dirE: 1, dirN: 0),
      NodeArm(edge: 2, lanes: east, roadClass: cls(east), reverse: 1, dirE: -1, dirN: 0),
    ],
    outs: [
      NodeArm(edge: 1, lanes: east, roadClass: cls(east), reverse: 2, dirE: 1, dirN: 0),
      NodeArm(edge: 3, lanes: west, roadClass: cls(west), reverse: 0, dirE: -1, dirN: 0),
    ],
  );
}

/// A six-lane expressway running east–west through a node, and a ramp
/// south of it: arriving (edge 4, ending 6.4 m south of the node) or,
/// [leaving], departing (edge 5, starting there). Edges 0/1 run east in and
/// out; 2/3 west.
_Arms _rampNode({bool leaving = false}) {
  const x = RoadClass.expressway6;
  return (
    ins: [
      const NodeArm(edge: 0, lanes: 3, roadClass: x, reverse: 3, dirE: 1, dirN: 0),
      const NodeArm(edge: 2, lanes: 3, roadClass: x, reverse: 1, dirE: -1, dirN: 0),
      if (!leaving)
        NodeArm(
            edge: 4,
            lanes: 1,
            roadClass: RoadClass.ramp,
            dirE: math.cos(0.2),
            dirN: math.sin(0.2),
            endE: 0,
            endN: -6.4),
    ],
    outs: [
      const NodeArm(edge: 1, lanes: 3, roadClass: x, reverse: 2, dirE: 1, dirN: 0),
      const NodeArm(edge: 3, lanes: 3, roadClass: x, reverse: 0, dirE: -1, dirN: 0),
      if (leaving)
        NodeArm(
            edge: 5,
            lanes: 1,
            roadClass: RoadClass.ramp,
            dirE: math.cos(-0.2),
            dirN: math.sin(-0.2),
            endE: 0,
            endN: -6.4),
    ],
  );
}

/// The end of a two-way road of [lanes] lanes each way: edge 0 arrives
/// heading north, edge 1 leaves heading south.
_Arms _deadEnd(int lanes) => (
      ins: [
        NodeArm(
            edge: 0,
            lanes: lanes,
            roadClass: RoadClass.avenue,
            reverse: 1,
            dirE: 0,
            dirN: 1),
      ],
      outs: [
        NodeArm(
            edge: 1,
            lanes: lanes,
            roadClass: RoadClass.avenue,
            reverse: 0,
            dirE: 0,
            dirN: -1),
      ],
    );
