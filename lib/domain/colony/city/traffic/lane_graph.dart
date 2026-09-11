// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The network as vehicles drive it: directed edges cut into lanes, and the
/// connectors that join a lane of one edge to a lane of the next across a
/// node (docs/plans/agent-traffic.md §3).
///
/// Derived from the road agent's `RoadGraph`, never re-clustered: its
/// nodes, pieces and directed edges are used as they are — lane-graph edge
/// `e` IS `RoadGraph` edge `e` — so the agents, the routed model's fire
/// reach and its delivery reach agree about what connects to what. Built by
/// `LaneGraphBuilder`; immutable after that. A patched `RoadGraph` (a
/// junction override, a road renamed) gets a copy that shares every array
/// here but the node controls and the connector roles ([withControls]).
///
/// Structure of arrays throughout, with compressed-row adjacency: the mover,
/// the arbiter and the planner walk these typed lists every sub-step, and
/// nothing here allocates to answer them.
///
/// Ids:
/// - edge `e` is `RoadGraph` edge `e`; [roadEdgeCount] of them, then (slice
///   8) the outside connections' sink edges, up to [edgeCount];
/// - lane `l` of edge `e` is `edgeLaneBase[e] + k`, `k = 0` the kerb lane;
/// - connectors are numbered by the lane they leave, then the lane they
///   reach, so a lane's connectors are one contiguous run;
/// - a vehicle's element is a lane id below [laneCount], or
///   `laneCount + c` on connector `c` ([elementCount] in all).
library;

import 'dart:typed_data';

import '../parcel.dart';
import '../road_graph.dart';
import 'agent_kind.dart';
import 'lane_connectors.dart';
import 'node_control.dart';

/// Bits of [LaneGraph.edgeFlags].
const int kEdgeSealed = 1;
const int kEdgePavement = 2;
const int kEdgeParking = 4;
const int kEdgeDivided = 8;
const int kEdgeBridge = 16;
const int kEdgeBus = 32;

/// An outside connection's virtual edge (slice 8).
const int kEdgeSink = 64;

/// §4.1's road-type weight: what a metre of each class costs a route over
/// and above its time, so through traffic keeps to the arterials and out of
/// the alleys. Exhaustive: a new class must say.
double roadTypeWeight(RoadClass c) => switch (c) {
      RoadClass.street || RoadClass.streetOneWay || RoadClass.ramp => 1.00,
      RoadClass.avenue || RoadClass.boulevard => 0.97,
      RoadClass.highway ||
      RoadClass.trunk ||
      RoadClass.motorway ||
      RoadClass.expressway4 ||
      RoadClass.expressway6 ||
      RoadClass.expressway8 ||
      RoadClass.elevated =>
        0.93,
      RoadClass.alley => 1.60,
      RoadClass.path => 1.80,
      // Not in the road graph: a train's, not a car's.
      RoadClass.transit || RoadClass.rail => 1.00,
    };

/// Lanes one direction of [road] has — all of them on a one-way road. A
/// road with no lanes marked (a path, an alley) carries one each way.
int lanesPerDirection(RoadSpline road) => road.lanes?.lanesEachWay ?? 1;

/// Lane [k]'s centre (0 the kerb lane), metres RIGHT of travel: the
/// road's own `LaneLayout.laneOffsets` read from the kerb inwards, so a car
/// sits on the paint. An unmarked road's one lane each way is half way to
/// its edge.
double laneOffsetRight(RoadSpline road, int k) {
  final lay = road.lanes;
  if (lay == null) return road.halfWidth / 2;
  final l = lay.lanesEachWay;
  final kk = l - 1 - k;
  final w = lay.laneWidthM;
  // Spelled as LaneLayout.laneOffsets spells it, so the two agree to the bit.
  if (lay.oneWay) return (kk + 0.5) * w - (l * w) / 2;
  return lay.medianM / 2 + (kk + 0.5) * w;
}

/// The lane graph. See the library comment.
class LaneGraph {
  /// Built by `LaneGraphBuilder`; every list is owned by the graph from here.
  LaneGraph({
    required this.graph,
    required this.stubNode,
    required this.controls,
    required this.roadEdgeCount,
    required this.edgeRoad,
    required this.edgeFrom,
    required this.edgeTo,
    required this.edgeForward,
    required this.edgeS0,
    required this.edgeS1,
    required this.edgeLen,
    required this.edgeLimit,
    required this.edgeWType,
    required this.edgeTier,
    required this.edgeLaneBase,
    required this.edgeLaneCount,
    required this.edgeFlags,
    required this.edgeReverse,
    required this.edgeLaneS0,
    required this.edgeLaneS1,
    required this.edgeOutLeg,
    required this.edgeInMainScc,
    required this.moveStart,
    required this.moveOut,
    required this.moveTurn,
    required this.inStart,
    required this.inEdges,
    required this.laneEdge,
    required this.laneIdx,
    required this.laneOff,
    required this.laneConStart,
    required this.conNode,
    required this.conFromLane,
    required this.conToLane,
    required this.conLen,
    required this.conVmax,
    required this.conPen,
    required this.conTheta,
    required this.conTurn,
    required this.conKind,
    required this.conRole,
    required this.conPts,
    required this.conConflictStart,
    required this.conflictWith,
    required this.conflictAtSelf,
    required this.conflictAtOther,
    required this.nodeConStart,
    required this.nodeCons,
  });

  /// The road graph this was derived from: its roads, their sampled lines,
  /// its nodes and plans. Kept for geometry, and — one rebuild long — for
  /// remapping routes onto its successor (§3.9).
  final RoadGraph graph;

  /// Per node, 1 where an outside connection made a dead end a stub; null
  /// for none (every colony before slice 8).
  final Uint8List? stubNode;

  /// What each node's plan means to traffic — the only part a patched graph
  /// changes.
  final NodeControls controls;

  // ---- Edges ----------------------------------------------------------------

  /// `RoadGraph.edgeCount`: the edges that are real road.
  final int roadEdgeCount;

  /// Graph road number, from node, to node.
  final Int32List edgeRoad, edgeFrom, edgeTo;

  /// 1 where travel runs the road's polyline first point to last.
  final Uint8List edgeForward;

  /// The edge's arc range on its road's own polyline, metres. A backward
  /// edge maps travel arc t to road arc `edgeS1 − t`.
  final Float64List edgeS0, edgeS1;

  /// Metres, `RoadGraph.edgeLength`.
  final Float64List edgeLen;

  /// Speed limit (m/s) and §4.1's road-type weight.
  final Float32List edgeLimit, edgeWType;

  /// `RoadTier.rank` of the road: who gives way to whom.
  final Int8List edgeTier;

  /// The edge's lanes are `edgeLaneBase[e] .. + edgeLaneCount[e] − 1`.
  final Int32List edgeLaneBase;
  final Uint8List edgeLaneCount;

  /// [kEdgeSealed], [kEdgePavement], [kEdgeParking], [kEdgeDivided],
  /// [kEdgeBridge], [kEdgeBus], [kEdgeSink].
  final Uint8List edgeFlags;

  /// The same stretch run the other way, or −1 on a one-way road.
  final Int32List edgeReverse;

  /// Travel arc (metres from the edge's start) where its lanes begin and
  /// end: the stop bar of the node behind and the node ahead, so the
  /// connectors cross the junction plate.
  final Float32List edgeLaneS0, edgeLaneS1;

  /// The leg (`RoadNode.legs` index) of [edgeFrom]'s node the edge leaves
  /// by. The leg it arrives by is `RoadGraph.edgeLeg`.
  final Int32List edgeOutLeg;

  /// 1 for an edge in the largest strongly connected part of the network:
  /// from it a vehicle can reach every other such edge, and come back.
  final Uint8List edgeInMainScc;

  // ---- Movements: which edge may follow which ---------------------------

  /// The edges a vehicle on edge e may take next are
  /// `moveOut[moveStart[e] .. moveStart[e + 1] − 1]`, ascending, with the
  /// turn each is ([TurnClass] index).
  final Int32List moveStart, moveOut;
  final Uint8List moveTurn;

  /// The edges arriving at node n are
  /// `inEdges[inStart[n] .. inStart[n + 1] − 1]`, ascending. The edges
  /// leaving it are `RoadGraph.outEdges`.
  final Int32List inStart, inEdges;

  // ---- Lanes ----------------------------------------------------------------

  final Int32List laneEdge;

  /// The lane's index on its edge, 0 the kerb lane.
  final Uint8List laneIdx;

  /// The lane's centre, metres right of travel.
  final Float32List laneOff;

  /// Connectors leaving lane l are `laneConStart[l] .. laneConStart[l + 1] − 1`.
  final Int32List laneConStart;

  // ---- Connectors -----------------------------------------------------------

  final Int32List conNode, conFromLane, conToLane;

  /// Metres along the path; the speed its tightest bend allows (m/s); the
  /// lane planner's charge for taking it (§4.5); the turn angle, radians
  /// (negative right).
  final Float32List conLen, conVmax, conPen, conTheta;

  /// [TurnClass], [ConnectorKind] and [ConnectorRole] indices.
  final Uint8List conTurn, conKind, conRole;

  /// The path: [kConnectorPoints] points (east, north, colony-local metres)
  /// per connector, from `16·c`. The renderer lerps along exactly these.
  final Float32List conPts;

  /// Connector c conflicts with `conflictWith[conConflictStart[c] ..
  /// conConflictStart[c + 1] − 1]`: their paths cross, or they merge into one
  /// lane. [conflictAtSelf] is where on c (metres), [conflictAtOther] where
  /// on the other.
  final Int32List conConflictStart, conflictWith;
  final Float32List conflictAtSelf, conflictAtOther;

  /// The connectors across node n are
  /// `nodeCons[nodeConStart[n] .. nodeConStart[n + 1] − 1]`, ascending.
  final Int32List nodeConStart, nodeCons;

  // ---- Counts and helpers ---------------------------------------------------

  int get edgeCount => edgeFrom.length;
  int get nodeCount => graph.nodeCount;
  int get laneCount => laneEdge.length;
  int get connectorCount => conNode.length;

  /// Lanes plus connectors: the ids a vehicle's element can take.
  int get elementCount => laneCount + connectorCount;

  NodeControlKind kindOf(int node) => controls.kindOf(node);

  /// Lane [k] (0 the kerb lane) of edge [edge].
  int laneOf(int edge, int k) => edgeLaneBase[edge] + k;

  /// Metres of lane [lane], from the stop bar behind to the one ahead.
  double laneLength(int lane) {
    final e = laneEdge[lane];
    return edgeLaneS1[e] - edgeLaneS0[e];
  }

  /// Metres of element [elem]: a lane, or a connector past [laneCount].
  double elementLength(int elem) =>
      elem < laneCount ? laneLength(elem) : conLen[elem - laneCount];

  int conFromEdge(int c) => laneEdge[conFromLane[c]];
  int conToEdge(int c) => laneEdge[conToLane[c]];

  TurnClass turnOf(int c) => TurnClass.values[conTurn[c]];
  ConnectorKind connectorKindOf(int c) => ConnectorKind.values[conKind[c]];
  ConnectorRole roleOf(int c) => ConnectorRole.values[conRole[c]];

  /// The connector from lane [fromLane] to lane [toLane], or −1.
  int connector(int fromLane, int toLane) {
    for (var c = laneConStart[fromLane]; c < laneConStart[fromLane + 1]; c++) {
      if (conToLane[c] == toLane) return c;
    }
    return -1;
  }

  /// Whether a vehicle on edge [from] may take edge [to] next.
  bool canFollow(int from, int to) {
    for (var i = moveStart[from]; i < moveStart[from + 1]; i++) {
      if (moveOut[i] == to) return true;
    }
    return false;
  }

  bool hasFlag(int edge, int flag) => edgeFlags[edge] & flag != 0;

  /// Road arc (on the road's own polyline) of travel arc [t] along [edge].
  double roadArc(int edge, double t) =>
      edgeForward[edge] == 1 ? edgeS0[edge] + t : edgeS1[edge] - t;

  /// Travel arc along [edge] of road arc [s].
  double travelArc(int edge, double s) =>
      edgeForward[edge] == 1 ? s - edgeS0[edge] : edgeS1[edge] - s;

  /// This graph under the controls of [patched], a graph that
  /// [RoadGraph.sharesStructureWith] this one's: every array shared but the
  /// node controls and the connector roles, which follow them.
  LaneGraph withControls(
          RoadGraph patched, NodeControls controls, Uint8List conRole) =>
      LaneGraph(
        graph: patched,
        stubNode: stubNode,
        controls: controls,
        roadEdgeCount: roadEdgeCount,
        edgeRoad: edgeRoad,
        edgeFrom: edgeFrom,
        edgeTo: edgeTo,
        edgeForward: edgeForward,
        edgeS0: edgeS0,
        edgeS1: edgeS1,
        edgeLen: edgeLen,
        edgeLimit: edgeLimit,
        edgeWType: edgeWType,
        edgeTier: edgeTier,
        edgeLaneBase: edgeLaneBase,
        edgeLaneCount: edgeLaneCount,
        edgeFlags: edgeFlags,
        edgeReverse: edgeReverse,
        edgeLaneS0: edgeLaneS0,
        edgeLaneS1: edgeLaneS1,
        edgeOutLeg: edgeOutLeg,
        edgeInMainScc: edgeInMainScc,
        moveStart: moveStart,
        moveOut: moveOut,
        moveTurn: moveTurn,
        inStart: inStart,
        inEdges: inEdges,
        laneEdge: laneEdge,
        laneIdx: laneIdx,
        laneOff: laneOff,
        laneConStart: laneConStart,
        conNode: conNode,
        conFromLane: conFromLane,
        conToLane: conToLane,
        conLen: conLen,
        conVmax: conVmax,
        conPen: conPen,
        conTheta: conTheta,
        conTurn: conTurn,
        conKind: conKind,
        conRole: conRole,
        conPts: conPts,
        conConflictStart: conConflictStart,
        conflictWith: conflictWith,
        conflictAtSelf: conflictAtSelf,
        conflictAtOther: conflictAtOther,
        nodeConStart: nodeConStart,
        nodeCons: nodeCons,
      );

  /// Whether [other] shares this graph's lanes and connectors — the same
  /// structure under (perhaps) other controls.
  bool sharesStructureWith(LaneGraph other) =>
      identical(laneEdge, other.laneEdge);
}
