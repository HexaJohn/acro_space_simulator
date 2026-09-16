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
import 'city_site_frame.dart';

/// One agent colony's traffic in one frame.
class CityTrafficFrame {
  CityTrafficFrame({
    required this.colonyId,
    required this.bodyId,
    required this.agents,
    required this.geometry,
    required this.net,
    this.sites,
    SitePoseColumns? sitePoses,
    ParkedColumns? parked,
    Uint8List? agentManaged,
    this.agentManagedRev = 0,
  })  : sitePoses = sitePoses ?? SitePoseColumns.empty,
        parked = parked ?? ParkedColumns.empty,
        agentManaged = agentManaged ?? _noManaged;

  static final Uint8List _noManaged = Uint8List(0);

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

  /// The colony's site access plans and their heights — the SAME object as
  /// this colony's `WorldSnapshot.sites` entry, never a copy (§13.1,
  /// site-access.md §5.2), so a frame costs one reference and the renderer
  /// draws cars and lots off one geometry. Null while the colony's book has
  /// published nothing.
  final CitySiteFrame? sites;

  /// Where the cars INSIDE those sites are, this sample: new identity every
  /// capture, its columns never written again once handed out.
  final SitePoseColumns sitePoses;

  /// The parked cars: identity per parked revision (§7.4, §13.2), so a layer
  /// rewrites its instances only when a car actually came or went.
  final ParkedColumns parked;

  /// E36 stage 1 (t4a-implementation.md §0 Q4): 1 at the BOOK SLOT of every
  /// site whose parking the agents manage, so the road side's tile baking
  /// skips those sites' lot cars and the two never draw one car twice. A
  /// slot past its length reads 0. [agentManagedRev] moves whenever the list
  /// may have changed and never goes back, so a consumer compares one int.
  final Uint8List agentManaged;
  final int agentManagedRev;
}

/// Where a car that is inside a site stands, colony-local (site-access.md
/// §7.4, agent-traffic.md §13.1 site elements, D19/D20).
///
/// A site lane is not a road element, so a car on one is not placed by the
/// road geometry: the capture walks the plan the simulation is driving —
/// `SiteManoeuvre`'s own curves, the very functions the site mover steps by,
/// so the drawn car and the simulated one are one thing — and writes the
/// answer here. Heights come from the site frame's `ptUp`/`stallUp` by
/// reference; the ground is never asked (D19/D20), because a ground query in
/// a built city costs milliseconds and this runs every frame.
///
/// Rows are COMPACT — there are a handful of cars inside lots, against
/// thousands on the road — and each names the `AgentFrame` row it is of, so
/// its kind, variant and flags are read there.
///
/// The pose is the car's CENTRE and the way its NOSE points, which is what a
/// stall pose is. On a SITE lane it is taken at the simulation's own `s`,
/// because a manoeuvre's `u = 0` is the lane pose at the stall's mouth (see
/// `TrafficCapture`'s `_poseOf`); on the ROAD the renderer draws that centre
/// half a length behind `VehicleTable.s`, which is a FRONT (§13.3), and a
/// back-out is attached at the front its swing ends on
/// (`SiteManoeuvre.restLaneS`) — so the drawn pose does not step half a
/// length when the road mover takes the car over (`home_back_out_test`).
class SitePoseColumns {
  SitePoseColumns({
    required this.count,
    required this.sitesRev,
    required this.sealed,
    required this.row,
    required this.e,
    required this.n,
    required this.up,
    required this.dirE,
    required this.dirN,
  });

  /// No cars inside any site.
  static final SitePoseColumns empty = SitePoseColumns(
    count: 0,
    sitesRev: 0,
    sealed: false,
    row: Int32List(0),
    e: Float32List(0),
    n: Float32List(0),
    up: Float32List(0),
    dirE: Float32List(0),
    dirN: Float32List(0),
  );

  /// Rows in use: `0 <= i < count`, all of them live.
  final int count;

  /// The site revision the poses were taken on ([AgentFrame.sitesRev]): a
  /// consumer holding a site frame of another revision knows they are not
  /// its plans'.
  final int sitesRev;

  /// Whether the colony's roads are sealed — an airless world's, where every
  /// road vehicle is drawn as a rover (the cosmetic rule, §13.7). A car
  /// inside a lot is on no road edge, so it is told here.
  final bool sealed;

  /// The `AgentFrame` row each pose is of.
  final Int32List row;

  /// Colony-local east and north of the car's centre, metres above the body
  /// datum, and the unit direction its nose points (east, north).
  final Float32List e, n, up, dirE, dirN;
}

/// The parked cars on the wire (§7.4, site-access.md §7.5).
///
/// A parked car is not a vehicle — it is off the road and costs no vehicle
/// row — so it is published apart, and only when [parkedRev] moves: a lot
/// full of cars that nobody touched is one identity compare a frame, and the
/// draw that holds them is never rewritten.
///
/// **Lot rows** are the plan's own: `lotSite` the site's BOOK SLOT (the wire
/// ordinal settled in t4a-implementation.md §0 Q4 — `CitySiteFrame.locate`
/// takes it, and unlike a position in frame order it does not move when
/// another site appears), `lotStall` the stall index in the plan of
/// [sitesRev], and `lotKind`/`lotVariant` the `AgentKind` index and the
/// opaque model byte (D42), so yards and depots parking vans and trucks in a
/// later slice change nothing here. The pose columns beside them are the
/// stall pose and its pave height, worked out once per publish by the same
/// rule the site mesher lays the stall out by.
///
/// A row is drawn only while [sitesRev] matches the site frame's; a capture
/// whose two disagree holds this object one publish rather than putting a
/// car on a stall index that has moved.
///
/// Kerb cars are T4b's (§7.4): they are placed on road geometry by the pose
/// pass, which is the pedestrian and kerb work of that slice.
class ParkedColumns {
  ParkedColumns({
    required this.parkedRev,
    required this.sitesRev,
    required this.lotCount,
    required this.lotSite,
    required this.lotStall,
    required this.lotKind,
    required this.lotVariant,
    required this.lotE,
    required this.lotN,
    required this.lotUp,
    required this.lotDirE,
    required this.lotDirN,
  });

  /// Nothing parked anywhere.
  static final ParkedColumns empty = ParkedColumns(
    parkedRev: -1,
    sitesRev: -1,
    lotCount: 0,
    lotSite: Int32List(0),
    lotStall: Int32List(0),
    lotKind: Uint8List(0),
    lotVariant: Uint8List(0),
    lotE: Float32List(0),
    lotN: Float32List(0),
    lotUp: Float32List(0),
    lotDirE: Float32List(0),
    lotDirN: Float32List(0),
  );

  /// The `ParkedCarTable` revision these rows were taken at, and the site
  /// revision the stall indices are the plans of.
  final int parkedRev, sitesRev;

  /// Cars on lot stalls.
  final int lotCount;

  /// Per lot car: its site's book slot, its stall in that site's plan, its
  /// `AgentKind` index and its model byte.
  final Int32List lotSite, lotStall;
  final Uint8List lotKind, lotVariant;

  /// Per lot car: the stall pose — colony-local east and north of the car's
  /// centre, metres above the body datum, and the unit direction its nose
  /// points.
  final Float32List lotE, lotN, lotUp, lotDirE, lotDirN;
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
