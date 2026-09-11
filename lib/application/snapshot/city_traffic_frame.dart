// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The agents on the wire: what one agent colony tells the renderer each
/// frame (docs/plans/agent-traffic.md §13.1–13.3).
///
/// Everything here is passed BY REFERENCE. The vehicles are the domain's
/// own triple-buffered [AgentFrame] — a new identity every agent sub-step,
/// never written again once handed out — and the geometry and the network
/// columns are built once per graph and handed out frame after frame, so
/// capturing a colony's traffic costs a cache lookup and nothing per
/// vehicle.
///
/// A vehicle is placed by the renderer, not here: the frame says which lane
/// or connector it is on and how far along, and [TrafficGeometry] says where
/// that lane runs — sliced from the very road points the ribbons are drawn
/// from, so a car sits on the paint without a ground query anywhere.
///
/// NOT serialised. Traffic is transient and a JSON frame is not a save, so
/// `WorldSnapshot.toJson` leaves it out, and the hand-built frames (the
/// studios', the wire codec's) carry none.
library;

import 'dart:typed_data';

import '../../domain/colony/city/traffic/agent_frame.dart';
import '../../domain/colony/city/traffic/lane_connectors.dart';

/// One agent colony's traffic in one frame.
class CityTrafficFrame {
  const CityTrafficFrame({
    required this.colonyId,
    required this.bodyId,
    required this.agents,
    required this.geometry,
    required this.net,
  });

  final String colonyId;
  final String bodyId;

  /// Every vehicle, as the agents last published it: a new identity every
  /// agent sub-step.
  final AgentFrame agents;

  /// Where the lanes and connectors run: identity per (lane-graph
  /// structure, ground cache stamp).
  final TrafficGeometry geometry;

  /// The signal heads and their plans: identity per lane-graph object, so
  /// a junction override that re-times a light is a new one.
  final TrafficNetColumns net;
}

/// Where every lane and connector of one lane graph runs, body-fixed —
/// what the renderer maps a vehicle's (element, s) through (§13.1, §13.3).
///
/// Built by `TrafficCapture` from the SAME capture's `RoadSnapshot`s, never
/// re-sampled and never re-draped: each directed edge's polyline is the
/// slice of its road's points between the edge's arc range, in travel
/// order. A reversed one-way road's snapshot already comes flipped, so the
/// renderer never flips anything; it adds the ribbon's lift and the lane's
/// offset, and that is the whole of it.
///
/// Arc: a vehicle's `s` is simulation arc, measured on the road's index
/// polyline; the points here are the capture's coarser samples, whose
/// length differs by decimetres. The renderer rescales per edge
/// (`s × cum.last / edgeSimLen`), which puts the error along the road,
/// never across it.
class TrafficGeometry {
  TrafficGeometry({
    required this.graphRev,
    required this.complete,
    required this.edgePtStart,
    required this.edgeSimLen,
    required this.edgeOffScale,
    required this.edgeSealed,
    required this.pts,
    required this.cum,
    required this.lift,
    required this.room,
    required this.laneEdge,
    required this.laneOff,
    required this.laneS0,
    required this.laneLen,
    required this.conFromLane,
    required this.conToLane,
    required this.conLen,
    required this.conPlate,
    required this.conPts,
    required this.nodePts,
    required this.nodeLift,
    required this.nodeEast,
    required this.nodeNorth,
  });

  /// No network: what a colony whose lane graph is not built yet sends.
  static final TrafficGeometry empty = TrafficGeometry(
    graphRev: 0,
    complete: true,
    edgePtStart: Int32List(1),
    edgeSimLen: Float32List(0),
    edgeOffScale: Float32List(0),
    edgeSealed: Uint8List(0),
    pts: Float64List(0),
    cum: Float32List(0),
    lift: Float32List(0),
    room: Float32List(0),
    laneEdge: Int32List(0),
    laneOff: Float32List(0),
    laneS0: Float32List(0),
    laneLen: Float32List(0),
    conFromLane: Int32List(0),
    conToLane: Int32List(0),
    conLen: Float32List(0),
    conPlate: Uint8List(0),
    conPts: Float64List(0),
    nodePts: Float64List(0),
    nodeLift: Float32List(0),
    nodeEast: Float32List(0),
    nodeNorth: Float32List(0),
  );

  /// Points per connector path: the lane graph's own ([kConnectorPoints]).
  static const int conPoints = kConnectorPoints;

  /// The agents' graph revision this was built for ([AgentFrame.graphRev]):
  /// an element id means something only against the geometry of its own
  /// revision, and a frame of another is not drawn.
  final int graphRev;

  /// Whether every edge found its road among the capture's own. False when
  /// the capture ran between a road edit and the agents' next advance: the
  /// edges of the roads the edit changed have no points until the lane
  /// graph catches up, and their vehicles are not drawn meanwhile.
  final bool complete;

  // ---- Edges (lane-graph edge ids) --------------------------------------------

  /// Edge e's points are `edgePtStart[e] .. edgePtStart[e + 1] − 1`, first
  /// to last in travel order. An edge with none is not drawn.
  final Int32List edgePtStart;

  /// The edge's length in simulation arc (`LaneGraph.edgeLen`), which the
  /// renderer rescales vehicle positions by.
  final Float32List edgeSimLen;

  /// What the lane offsets are multiplied by to sit on the paint: the
  /// road's drawn half width over its lane layout's — the mesher's own
  /// `scale` — and 1 for a road with no layout.
  final Float32List edgeOffScale;

  /// 1 on a sealed road: an airless world's, where every vehicle is a rover.
  final Uint8List edgeSealed;

  // ---- Points -----------------------------------------------------------------

  /// Body-fixed xyz, metres, three per point.
  final Float64List pts;

  /// Metres along the edge's polyline from its first point.
  final Float32List cum;

  /// The road's own lift above the drape at the point, metres: its deck
  /// (`RoadSnapshot.lifts`) on a raised or sunk road — below
  /// `-RoadElevation.tunnelCoverM` it is in a tunnel — and its class's deck
  /// height plus the bridge lift on a draped one. The renderer adds the
  /// ribbon's own lift; nothing here is counted twice.
  final Float32List lift;

  /// Metres from the centreline to the edge of the running lanes, as the
  /// mesher narrows it over a taper (its `hwAt(s) − shoulder`).
  final Float32List room;

  // ---- Lanes (lane-graph lane ids) --------------------------------------------

  final Int32List laneEdge;

  /// The lane's centre, metres right of travel, at the layout's own width.
  final Float32List laneOff;

  /// Travel arc along its edge where the lane begins (the stop bar behind),
  /// and its length: a vehicle `s` metres along lane l is at travel arc
  /// `laneS0[l] + s`.
  final Float32List laneS0, laneLen;

  // ---- Connectors -------------------------------------------------------------

  final Int32List conFromLane, conToLane;

  /// Simulation length: what a vehicle's `s` on the connector runs to.
  final Float32List conLen;

  /// 1 where the connector crosses a drawn junction plate (a stop, a light,
  /// a roundabout), which stands a few centimetres over the ribbon.
  final Uint8List conPlate;

  /// The connector's path, [conPoints] body-fixed points (xyz) per
  /// connector: the domain's own Bézier samples, lifted onto the drape of
  /// the lanes either side.
  final Float64List conPts;

  // ---- Nodes (road-graph node ids) --------------------------------------------

  /// Where each node is, body-fixed on the drape (xyz), and the road's own
  /// lift there (as [lift]).
  final Float64List nodePts;
  final Float32List nodeLift;

  /// The colony's east and north at each node, body-fixed unit vectors
  /// (xyz): what a leg's heading turns into a direction on the ground.
  final Float32List nodeEast, nodeNorth;

  int get edgeCount => edgePtStart.length - 1;
  int get pointCount => cum.length;
  int get laneCount => laneEdge.length;
  int get connectorCount => conLen.length;
  int get nodeCount => nodeLift.length;

  /// Lanes plus connectors: the element ids a vehicle can be on.
  int get elementCount => laneCount + connectorCount;
}
