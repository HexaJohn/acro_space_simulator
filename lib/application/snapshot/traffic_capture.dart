// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// An agent colony's traffic, captured for the frame
/// (docs/plans/agent-traffic.md §13.1–13.3, E19).
///
/// Per frame this is a lookup: the agents' latest [AgentFrame] goes out by
/// reference, and so do the geometry and the network columns, which are
/// built only when what they depend on moves — the geometry per (lane-graph
/// structure, the drape of each of its roads), the network columns per
/// lane-graph object. The cache hangs off the colony in an [Expando], so
/// the colony carries no field of the renderer's.
///
/// The geometry is sliced from the road snapshots THIS capture just made
/// for the colony, never re-sampled and never re-draped: every height in
/// it is the ribbon's own, so a vehicle sits exactly on the paint, and the
/// capture asks the ground nothing — a ground query in a built city costs
/// milliseconds, and the capture runs every frame.
///
/// Heights: `CitySim.localToBodyFixed` lays (east, north) on the tangent
/// plane at the colony's centre, at a given radius along the centre's up
/// (`SurfacePlacement.place`), and the capture put every road point down
/// that way at its own ground radius. That radius is the point's height
/// along the colony's up, `p · up`, and it is what the connectors and the
/// nodes here are put down at: on the same surface as the road points,
/// however far from the centre — a point's length would be a little more,
/// by `(e² + n²) / 2r`, which is most of a metre three kilometres out.
///
/// The SITE half (T4a, site-access.md §7.4–7.5) follows the same rule from
/// the other source: a car inside a lot, and a car parked on a stall, are
/// placed off the plan the simulation is driving, at the heights R3's
/// `CitySiteFrame` published for that plan's own points and stalls. Nothing
/// is re-draped and nothing is asked of the ground there either (D19/D20).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/parcel.dart';
import '../../domain/colony/city/road_graph.dart';
import '../../domain/colony/city/site_access/site_access_constants.dart';
import '../../domain/colony/city/site_access/site_access_plan.dart';
import '../../domain/colony/city/site_access/site_lane_graph.dart';
import '../../domain/colony/city/spatial_index.dart';
import '../../domain/colony/city/sprawl_plan.dart';
import '../../domain/colony/city/traffic/agent_frame.dart';
import '../../domain/colony/city/traffic/lane_graph.dart';
import '../../domain/colony/city/traffic/parked_cars.dart';
import '../../domain/colony/city/traffic/site_manoeuvre.dart';
import '../../domain/colony/city/traffic/site_vehicles.dart';
import '../../domain/colony/city/traffic/vehicle_table.dart';
import '../../domain/shared/vector3.dart';
import 'city_traffic_frame.dart';
import 'world_snapshot.dart';

/// Builds [CityTrafficFrame]s. See the library comment.
class TrafficCapture {
  TrafficCapture._();

  /// Over how much road the mesher tapers a width change (`RoadMesher.taperM`,
  /// which the application layer cannot import): the lanes' room narrows
  /// over exactly the stretch the ribbon does. A test pins the two equal.
  static const double taperM = 90.0;

  /// How far a snapshot's end may lie from where the lane graph has its
  /// road's end and still be that road: nothing apart when it is, metres
  /// when the capture saw an edit the agents have not caught up with.
  static const double sameRoadM = 0.5;

  static final Expando<_Cache> _cache = Expando<_Cache>('TrafficCapture');

  /// [city]'s traffic for this frame. [roads] is the capture's road list so
  /// far, holding this colony's snapshots — the ones [city]'s road loop has
  /// just added — and [sites] the colony's site frame, the very object the
  /// snapshot carries (§13.1: shared, never copied).
  static CityTrafficFrame frameFor(
      CitySim city, String bodyId, List<RoadSnapshot> roads,
      {CitySiteFrame? sites}) {
    final agents = city.agents;
    final lg = agents.laneGraph;
    if (lg == null) {
      return CityTrafficFrame(
        colonyId: city.id,
        bodyId: bodyId,
        agents: agents.frame,
        geometry: TrafficGeometry.empty,
        net: TrafficNetColumns.empty,
        sites: sites,
        agentManaged: agents.agentManaged,
        agentManagedRev: agents.agentManagedRev,
      );
    }
    final c = _cache[city] ??= _Cache();
    var geometry = c.geometry;
    // A geometry the capture could not complete (it ran between an edit and
    // the agents' next advance) is tried again once the roads move on; the
    // agents' own rebuild makes a new structure anyway.
    if (geometry == null ||
        !identical(c.structure, lg.laneEdge) ||
        !c.drapesHold(city, lg.graph) ||
        (!geometry.complete && c.roadsRevision != city.roadsRevision)) {
      geometry = c.geometry =
          geometryOf(city, lg, roads, graphRev: agents.graphRev);
      c.structure = lg.laneEdge;
      c.holdDrapes(city, lg.graph);
      c.roadsRevision = city.roadsRevision;
      c.sealed = _allSealed(geometry);
    }
    var net = c.net;
    if (net == null || !identical(c.netGraph, lg)) {
      net = c.net = TrafficNetColumns.of(lg,
          graphRev: agents.graphRev, controlsRev: agents.controlsRev);
      c.netGraph = lg;
    }
    return CityTrafficFrame(
      colonyId: city.id,
      bodyId: bodyId,
      agents: agents.frame,
      geometry: geometry,
      net: net,
      sites: sites,
      sitePoses: _SiteCars.poses(city, sites, c),
      parked: _SiteCars.parked(city, sites, c),
      agentManaged: agents.agentManaged,
      agentManagedRev: agents.agentManagedRev,
    );
  }

  /// Whether every road edge of [g] is sealed: an airless world's colony,
  /// where the cosmetic rule draws every car as a rover (§13.7). Worked out
  /// with the geometry, so a frame reads a bool.
  static bool _allSealed(TrafficGeometry g) {
    final n = g.edgeSealed.length;
    if (n == 0) return false;
    for (var e = 0; e < n; e++) {
      if (g.edgeSealed[e] == 0) return false;
    }
    return true;
  }

  /// The geometry of [lg] from [city]'s snapshots among [roads]: what
  /// [frameFor] caches. Allocates freely; it runs on a rebuild only.
  static TrafficGeometry geometryOf(
          CitySim city, LaneGraph lg, List<RoadSnapshot> roads,
          {int graphRev = 0}) =>
      _GeometryBuild(city, lg, roads).run(graphRev);

  /// The half width at arc [s] of a road [hw] wide that starts at [hw0] and
  /// ends at [hw1] (null: its own width): the mesher's `_taperedHalfWidth`,
  /// spelled the same way so the two agree.
  static double taperedHalfWidth(
      double s, double total, double hw, double? hw0, double? hw1) {
    var w = hw;
    if (hw0 != null && s < taperM) w = hw0 + (hw - hw0) * (s / taperM);
    if (hw1 != null && s > total - taperM) {
      w = hw + (hw1 - hw) * ((s - (total - taperM)) / taperM);
    }
    return w;
  }
}

/// What [TrafficCapture] keeps per colony between frames.
class _Cache {
  /// The lane structure (its `laneEdge` list, shared by every refresh of
  /// one build) and the roads revision [geometry] was built at.
  Object? structure;
  int roadsRevision = 0;
  TrafficGeometry? geometry;

  /// The drape of each of the graph's roads, by road number, that
  /// [geometry] was sliced from: its points and the ground radius under
  /// each, as the capture worked them out and holds them
  /// (`CitySim.drapeCache`). Null for a road the capture held none for.
  List<List<Vec2>?> drapePts = const [];
  List<Float64List?> drapeRadii = const [];

  /// Whether every road of [g] is still draped as [geometry] was sliced:
  /// the same drape, or one worked out again to the same points at the
  /// same heights.
  ///
  /// The capture works a drape out again whenever something MAY have
  /// moved it — a road edit anywhere, a junction override, the shaper
  /// settling, a brush laid within its reach — and holds it otherwise, so
  /// a frame in which nothing changed finds every drape the one it had,
  /// for a lookup a road. One worked out again to what it was (the ground
  /// under it never moved) is taken as the one held, and the geometry
  /// stands: an override re-times a light and moves no car.
  bool drapesHold(CitySim city, RoadGraph g) {
    final n = g.roadCount;
    if (drapeRadii.length != n) return false;
    for (var r = 0; r < n; r++) {
      final d = city.drapeCache[g.roads[r].id];
      final held = drapeRadii[r];
      if (d == null) {
        if (held != null) return false;
        continue;
      }
      if (identical(d.radii, held)) continue;
      if (held == null || !_sameDrape(d.pts, d.radii, drapePts[r]!, held)) {
        return false;
      }
      drapePts[r] = d.pts;
      drapeRadii[r] = d.radii;
    }
    return true;
  }

  /// Holds the drape of every road of [g], as [geometry] was just sliced.
  void holdDrapes(CitySim city, RoadGraph g) {
    final n = g.roadCount;
    drapePts = List<List<Vec2>?>.filled(n, null);
    drapeRadii = List<Float64List?>.filled(n, null);
    for (var r = 0; r < n; r++) {
      final d = city.drapeCache[g.roads[r].id];
      if (d == null) continue;
      drapePts[r] = d.pts;
      drapeRadii[r] = d.radii;
    }
  }

  static bool _sameDrape(List<Vec2> pts, Float64List radii, List<Vec2> heldPts,
      Float64List heldRadii) {
    final n = radii.length;
    if (heldRadii.length != n || pts.length != n || heldPts.length != n) {
      return false;
    }
    for (var i = 0; i < n; i++) {
      if (radii[i] != heldRadii[i]) return false;
      final a = pts[i], b = heldPts[i];
      if (a.e != b.e || a.n != b.n) return false;
    }
    return true;
  }

  /// Whether every road edge of [geometry] is sealed (see `_allSealed`).
  bool sealed = false;

  /// The lane-graph object [net] was built from.
  LaneGraph? netGraph;
  TrafficNetColumns? net;

  // ---- The site half (T4a) ---------------------------------------------------

  /// Three site-pose column sets, written in turn, as the agents' own frames
  /// are (§13.2): a set is written again only two publishes later, so a
  /// frame a renderer still holds is never changed under it.
  final List<_PoseSet> poseSets = [_PoseSet(), _PoseSet(), _PoseSet()];
  int _nextPoseSet = 0;

  _PoseSet takePoseSet() {
    final set = poseSets[_nextPoseSet];
    _nextPoseSet = (_nextPoseSet + 1) % poseSets.length;
    return set;
  }

  /// The parked cars last published, and the site frame they were placed
  /// against: both compared by identity, so a steady frame republishes
  /// nothing (§7.4, §13.2).
  ParkedColumns? parked;
  CitySiteFrame? parkedFor;
}

/// One reusable set of site-pose columns. It grows to the most cars that
/// have ever been inside this colony's lots at once and is then never
/// replaced (§15.2), which on any real town is a few dozen rows.
class _PoseSet {
  Int32List row = Int32List(0);
  Float32List e = Float32List(0),
      n = Float32List(0),
      up = Float32List(0),
      dirE = Float32List(0),
      dirN = Float32List(0);

  int get capacity => row.length;

  /// Room for one more row.
  void grow() {
    final was = capacity;
    final want = was == 0 ? 16 : was * 2;
    row = Int32List(want)..setRange(0, was, row);
    Float32List f(Float32List a) => Float32List(want)..setRange(0, was, a);
    e = f(e);
    n = f(n);
    up = f(up);
    dirE = f(dirE);
    dirN = f(dirN);
  }
}

/// One road's snapshot as the slicing reads it: its points with their arc,
/// lift and room, and how the lane graph's arcs land on them.
class _Road {
  _Road._(this.p, this.arc, this.lift, this.room, this.recLen, this.reversed,
      this.offScale);

  /// Body-fixed xyz, the snapshot's own.
  final List<double> p;

  /// Metres along the snapshot's points; the last is its length.
  final Float64List arc;

  /// Per point: the road's own lift and the lanes' room (see
  /// [TrafficGeometry.lift], [TrafficGeometry.room]).
  final Float64List lift, room;

  /// The lane graph's length of the road, on its index polyline.
  final double recLen;

  /// The snapshot runs last control to first: a reversed one-way road,
  /// which the capture flips.
  final bool reversed;
  final double offScale;

  int get n => arc.length;
  double get total => arc[arc.length - 1];

  /// [snap] read against the lane graph's [road] and its index polyline
  /// [rec]; null when it is not that road as the graph has it — another
  /// class, other ends — because the capture saw an edit the agents' graph
  /// has not caught up with. [up] is the colony's up.
  static _Road? of(CitySim city, RoadSpline road, IndexedRoad rec,
      RoadSnapshot snap, Vector3 up) {
    final p = snap.points;
    final n = p.length ~/ 3;
    final last = rec.sampleCount - 1;
    if (n < 2 || last < 1 || snap.roadClassIndex != road.roadClass.index) {
      return null;
    }
    final head = road.reversed ? rec.sampleAt(last) : rec.sampleAt(0);
    final tail = road.reversed ? rec.sampleAt(0) : rec.sampleAt(last);
    if (!_at(city, p, 0, head, up) || !_at(city, p, n - 1, tail, up)) {
      return null;
    }

    final arc = Float64List(n);
    for (var i = 1; i < n; i++) {
      final dx = p[3 * i] - p[3 * i - 3];
      final dy = p[3 * i + 1] - p[3 * i - 2];
      final dz = p[3 * i + 2] - p[3 * i - 1];
      arc[i] = arc[i - 1] + math.sqrt(dx * dx + dy * dy + dz * dz);
    }
    final total = arc[n - 1];
    final cls = road.roadClass;
    final decks = snap.lifts.length == n;
    final ranges = <(double, double)>[
      for (var i = 0; i + 1 < snap.bridges.length; i += 2)
        (snap.bridges[i], snap.bridges[i + 1]),
    ];
    final layout = cls.lanesFor(RoadDecoration.values[
        snap.decoration.clamp(0, RoadDecoration.values.length - 1)]);
    final hw = snap.halfWidthM;
    final offScale = layout == null ? 1.0 : hw / layout.halfWidthM;
    final shoulder = (layout?.shoulderM ?? 0) * offScale;
    final lift = Float64List(n);
    final room = Float64List(n);
    for (var i = 0; i < n; i++) {
      // One height reference per road (D20): a deck road's deck, or a
      // draped road's class height and bridges — the cosmetic pass's own
      // term — never both.
      lift[i] = decks
          ? snap.lifts[i]
          : cls.deckHeightM + SprawlPlan.bridgeLiftAt(arc[i], ranges);
      room[i] = TrafficCapture.taperedHalfWidth(
              arc[i], total, hw, snap.startHalfWidthM, snap.endHalfWidthM) -
          shoulder;
    }
    return _Road._(p, arc, lift, room, rec.lengthM, road.reversed, offScale);
  }

  /// Whether the snapshot's point [k] is where [local] is, put down at the
  /// radius the capture put it down at.
  static bool _at(
      CitySim city, List<double> p, int k, Vec2 local, Vector3 up) {
    final x = p[3 * k], y = p[3 * k + 1], z = p[3 * k + 2];
    final want = city.localToBodyFixed(local,
        bodyRadiusM: x * up.x + y * up.y + z * up.z);
    final dx = want.x - x, dy = want.y - y, dz = want.z - z;
    return dx * dx + dy * dy + dz * dz <=
        TrafficCapture.sameRoadM * TrafficCapture.sameRoadM;
  }

  /// Arc on the snapshot of road arc [a] on the lane graph's polyline: the
  /// same fraction of the road, counted from the other end on a flipped one.
  double snapArc(double a) {
    var f = recLen > 0 ? a / recLen : 0.0;
    if (reversed) f = 1 - f;
    return f.clamp(0.0, 1.0) * total;
  }

  /// The segment `i .. i + 1` arc [x] falls on.
  int segmentAt(double x) {
    var lo = 0, hi = n - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (arc[mid] <= x) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

/// One geometry build. See [TrafficCapture.geometryOf].
class _GeometryBuild {
  _GeometryBuild(this.city, this.lg, this.roads)
      : up = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: 1);

  final CitySim city;
  final LaneGraph lg;
  final List<RoadSnapshot> roads;

  /// The colony's up: the radial at its centre, a unit vector.
  final Vector3 up;

  /// Vertices within this of a slice's end are that end.
  static const double _endEpsM = 1e-6;

  final List<double> _pts = [];
  final List<double> _cum = [];
  final List<double> _lift = [];
  final List<double> _room = [];

  TrafficGeometry run(int graphRev) {
    final g = lg.graph;
    final byId = <String, RoadSnapshot>{};
    for (final r in roads) {
      final id = r.id;
      if (id != null && r.colonyId == city.id) byId[id] = r;
    }
    var complete = true;
    final slices = List<_Road?>.filled(g.roadCount, null);
    for (var r = 0; r < g.roadCount; r++) {
      final road = g.roads[r];
      final snap = byId[road.id];
      final s =
          snap == null ? null : _Road.of(city, road, g.roadRecs[r], snap, up);
      if (s == null) complete = false;
      slices[r] = s;
    }

    // ---- Edges: each the slice of its road's points between its arc
    // range, in travel order.
    final nE = lg.edgeCount;
    final edgePtStart = Int32List(nE + 1);
    final edgeSimLen = Float32List(nE);
    final edgeOffScale = Float32List(nE);
    final edgeSealed = Uint8List(nE);
    for (var e = 0; e < nE; e++) {
      edgePtStart[e] = _cum.length;
      edgeSimLen[e] = lg.edgeLen[e];
      edgeSealed[e] = lg.hasFlag(e, kEdgeSealed) ? 1 : 0;
      edgeOffScale[e] = 1;
      // An outside connection's sink edge (slice 8) is no road.
      if (e >= lg.roadEdgeCount) continue;
      final road = slices[lg.edgeRoad[e]];
      if (road == null) continue;
      edgeOffScale[e] = road.offScale;
      _slice(road, e);
    }
    edgePtStart[nE] = _cum.length;
    final pts = Float64List.fromList(_pts);
    final cum = Float32List.fromList(_cum);
    final lift = Float32List.fromList(_lift);
    final room = Float32List.fromList(_room);

    // ---- Nodes: on the drape of the edge ends that meet there.
    final nN = g.nodeCount;
    final rSum = Float64List(nN), liftSum = Float64List(nN);
    final ends = Int32List(nN);
    var allR = 0.0;
    var allN = 0;
    for (var e = 0; e < nE; e++) {
      final a = edgePtStart[e], b = edgePtStart[e + 1];
      if (b - a < 2) continue;
      for (final (k, node) in [(a, lg.edgeFrom[e]), (b - 1, lg.edgeTo[e])]) {
        final r = _radius(pts, k);
        rSum[node] += r;
        liftSum[node] += lift[k];
        ends[node]++;
        allR += r;
        allN++;
      }
    }
    final fallbackR = allN == 0 ? 0.0 : allR / allN;
    final nodePts = Float64List(3 * nN);
    final nodeLift = Float32List(nN);
    final nodeEast = Float32List(3 * nN);
    final nodeNorth = Float32List(3 * nN);
    for (var n = 0; n < nN; n++) {
      final at = g.nodes[n].at;
      final r = ends[n] == 0 ? fallbackR : rSum[n] / ends[n];
      nodeLift[n] = ends[n] == 0 ? 0 : liftSum[n] / ends[n];
      final p = city.localToBodyFixed(at, bodyRadiusM: r);
      nodePts[3 * n] = p.x;
      nodePts[3 * n + 1] = p.y;
      nodePts[3 * n + 2] = p.z;
      _unit(nodeEast, n, city.localToBodyFixed(at + const Vec2(1, 0),
              bodyRadiusM: r) -
          p);
      _unit(nodeNorth, n, city.localToBodyFixed(at + const Vec2(0, 1),
              bodyRadiusM: r) -
          p);
    }

    // ---- Lanes: the graph's own offsets, and where on its edge each runs.
    final nL = lg.laneCount;
    final laneS0 = Float32List(nL), laneLen = Float32List(nL);
    for (var l = 0; l < nL; l++) {
      final e = lg.laneEdge[l];
      laneS0[l] = lg.edgeLaneS0[e];
      laneLen[l] = lg.edgeLaneS1[e] - lg.edgeLaneS0[e];
    }

    // ---- Connectors: the domain's Bézier samples (east, north) put down
    // on the drape of the two lanes they join, the radius blended end to
    // end.
    const k = TrafficGeometry.conPoints;
    final nC = lg.connectorCount;
    final conPts = Float64List(3 * k * nC);
    final conPlate = Uint8List(nC);
    for (var c = 0; c < nC; c++) {
      final fromLane = lg.conFromLane[c], toLane = lg.conToLane[c];
      final eIn = lg.laneEdge[fromLane], eOut = lg.laneEdge[toLane];
      final node = lg.conNode[c];
      final rNode = ends[node] == 0 ? fallbackR : rSum[node] / ends[node];
      final r0 = _radiusOnEdge(
          pts, cum, edgePtStart, eIn, lg.edgeLaneS1[eIn], edgeSimLen, rNode);
      final r1 = _radiusOnEdge(
          pts, cum, edgePtStart, eOut, lg.edgeLaneS0[eOut], edgeSimLen, rNode);
      for (var i = 0; i < k; i++) {
        final w = i / (k - 1);
        final local = Vec2(lg.conPts[2 * k * c + 2 * i],
            lg.conPts[2 * k * c + 2 * i + 1]);
        final p = city.localToBodyFixed(local, bodyRadiusM: r0 + (r1 - r0) * w);
        final o = 3 * (k * c + i);
        conPts[o] = p.x;
        conPts[o + 1] = p.y;
        conPts[o + 2] = p.z;
      }
      conPlate[c] = lg.controls.stopBack[node] > 0 ? 1 : 0;
    }

    return TrafficGeometry(
      graphRev: graphRev,
      complete: complete,
      edgePtStart: edgePtStart,
      edgeSimLen: edgeSimLen,
      edgeOffScale: edgeOffScale,
      edgeSealed: edgeSealed,
      pts: pts,
      cum: cum,
      lift: lift,
      room: room,
      // Shared, not copied: the lane graph's lists are never written after
      // its build, and the geometry lives exactly as long as its structure.
      laneEdge: lg.laneEdge,
      laneOff: lg.laneOff,
      laneS0: laneS0,
      laneLen: laneLen,
      conFromLane: lg.conFromLane,
      conToLane: lg.conToLane,
      conLen: lg.conLen,
      conPlate: conPlate,
      conPts: conPts,
      nodePts: nodePts,
      nodeLift: nodeLift,
      nodeEast: nodeEast,
      nodeNorth: nodeNorth,
    );
  }

  /// Appends edge [e]'s slice of [road]: the point at its start, every
  /// snapshot point strictly inside, the point at its end — in travel order,
  /// which runs against the snapshot for a backward edge of a two-way road
  /// and with it for a reversed one-way road's, whose snapshot is flipped.
  void _slice(_Road road, int e) {
    final x0 = road.snapArc(lg.roadArc(e, 0));
    final x1 = road.snapArc(lg.roadArc(e, lg.edgeLen[e]));
    final base = _cum.length;
    _addAt(road, x0, base);
    if (x0 <= x1) {
      for (var i = 0; i < road.n; i++) {
        final a = road.arc[i];
        if (a > x0 + _endEpsM && a < x1 - _endEpsM) _addVertex(road, i, base);
      }
    } else {
      for (var i = road.n - 1; i >= 0; i--) {
        final a = road.arc[i];
        if (a < x0 - _endEpsM && a > x1 + _endEpsM) _addVertex(road, i, base);
      }
    }
    _addAt(road, x1, base);
  }

  /// The snapshot at arc [x]: its own point where [x] is one, else the
  /// interpolation along the segment [x] falls on.
  void _addAt(_Road road, double x, int base) {
    final i = road.segmentAt(x);
    if ((x - road.arc[i]).abs() <= _endEpsM) return _addVertex(road, i, base);
    if ((road.arc[i + 1] - x).abs() <= _endEpsM) {
      return _addVertex(road, i + 1, base);
    }
    final u = (x - road.arc[i]) / (road.arc[i + 1] - road.arc[i]);
    final p = road.p;
    _add(
      p[3 * i] + (p[3 * i + 3] - p[3 * i]) * u,
      p[3 * i + 1] + (p[3 * i + 4] - p[3 * i + 1]) * u,
      p[3 * i + 2] + (p[3 * i + 5] - p[3 * i + 2]) * u,
      road.lift[i] + (road.lift[i + 1] - road.lift[i]) * u,
      road.room[i] + (road.room[i + 1] - road.room[i]) * u,
      base,
    );
  }

  void _addVertex(_Road road, int i, int base) => _add(road.p[3 * i],
      road.p[3 * i + 1], road.p[3 * i + 2], road.lift[i], road.room[i], base);

  void _add(double x, double y, double z, double lift, double room, int base) {
    var cum = 0.0;
    if (_cum.length > base) {
      final j = _pts.length - 3;
      final dx = x - _pts[j], dy = y - _pts[j + 1], dz = z - _pts[j + 2];
      cum = _cum.last + math.sqrt(dx * dx + dy * dy + dz * dz);
    }
    _pts
      ..add(x)
      ..add(y)
      ..add(z);
    _cum.add(cum);
    _lift.add(lift);
    _room.add(room);
  }

  /// The radius point [k] of [pts] was put down at: its height along the
  /// colony's up (see the library comment).
  double _radius(Float64List pts, int k) =>
      pts[3 * k] * up.x + pts[3 * k + 1] * up.y + pts[3 * k + 2] * up.z;

  /// The drape's radius [t] travel metres along edge [e], or [fallback]
  /// where the edge has no points.
  double _radiusOnEdge(Float64List pts, Float32List cum, Int32List start,
      int e, double t, Float32List simLen, double fallback) {
    final a = start[e], b = start[e + 1];
    if (b - a < 2) return fallback;
    final len = cum[b - 1];
    final x = simLen[e] > 0 ? t * len / simLen[e] : 0.0;
    var k = a;
    while (k < b - 2 && cum[k + 1] < x) {
      k++;
    }
    final span = cum[k + 1] - cum[k];
    final u = span > 0 ? ((x - cum[k]) / span).clamp(0.0, 1.0) : 0.0;
    final r0 = _radius(pts, k), r1 = _radius(pts, k + 1);
    return r0 + (r1 - r0) * u;
  }

  static void _unit(Float32List out, int n, Vector3 v) {
    final l = v.length;
    if (l == 0) return;
    out[3 * n] = v.x / l;
    out[3 * n + 1] = v.y / l;
    out[3 * n + 2] = v.z / l;
  }
}

/// The cars a site holds, placed for the frame: the ones driving inside it
/// and the ones parked on its stalls (site-access.md §7.4–7.5, D19/D20).
///
/// Everything here reads the plan the SIMULATION is driving (`SiteTable`'s
/// own view) for where a car is, and the frame's [SiteChunkGeometry] for how
/// high the ground under it is — and only when the two are the same plan
/// object, so a site re-planned under a car is never drawn against another
/// revision's points. The curves are `SiteManoeuvre`'s, the very functions
/// the site mover steps by: one definition of a turn-in, never two.
abstract final class _SiteCars {
  /// Scratch for one pose: east, north, dirE, dirN, and the metres above the
  /// datum worked out beside it. Static because this runs once per car per
  /// frame and may not allocate; safe because nothing here re-enters it.
  static final Float64List _scratch = Float64List(8);

  static final int _none = SitePhase.none.index;
  static final int _gateHeld = SitePhase.gateHeld.index;
  static final int _kerbBound = SitePhase.kerbBound.index;
  static final int _inbound = SitePhase.inbound.index;
  static final int _stallIn = SitePhase.stallIn.index;
  static final int _stallOut = SitePhase.stallOut.index;
  static final int _toThroat = SitePhase.toThroat.index;
  static final int _throatWait = SitePhase.throatWait.index;
  static final int _lot = CarWhere.lot.index;

  // ---- The cars driving inside sites ----------------------------------------

  /// Every vehicle inside one of [sf]'s sites, placed into the next of [c]'s
  /// three pose sets.
  static SitePoseColumns poses(CitySim city, CitySiteFrame? sf, _Cache c) {
    final agents = city.agents;
    final sites = agents.sites;
    final cols = agents.siteVehicles;
    final table = agents.vehicles;
    final lg = agents.laneGraph;
    if (sf == null ||
        sites == null ||
        cols == null ||
        table == null ||
        lg == null ||
        sites.highWater == 0) {
      return SitePoseColumns.empty;
    }
    final set = c.takePoseSet();
    final out = _scratch;
    final hw = table.highWater;
    var n = 0;
    for (var sl = 0; sl < hw; sl++) {
      if (!table.isSlotLive(sl)) continue;
      // A car held at a gate, or bound for a kerb slot, is still out on the
      // street: the road geometry places it, as it always did.
      final ph = cols.phase[sl];
      if (ph == _none || ph == _gateHeld || ph == _kerbBound) continue;
      final row = cols.row[sl];
      if (row < 0 || !sites.isRowLive(row)) continue;
      final plan = sites.plan[row];
      if (plan == null) continue;
      final at = sf.locate(sites.bookSlot[row]);
      if (at == null) continue;
      final g = at.$1, k = at.$2;
      // The frame's heights are this very plan's, or they are no use: a site
      // re-planned since, or a car still driving a LIMBO plan (§7.6 row 3),
      // is left undrawn for that publish rather than put down on another
      // revision's points.
      if (!identical(g.plan, plan.chunk) || k != plan.site) continue;
      if (!_poseOf(plan, g, k, table, cols, sl, lg, ph, out)) continue;
      if (n == set.capacity) set.grow();
      set.row[n] = sl;
      set.e[n] = out[0];
      set.n[n] = out[1];
      set.dirE[n] = out[2];
      set.dirN[n] = out[3];
      set.up[n] = out[4];
      n++;
    }
    return SitePoseColumns(
      count: n,
      sitesRev: sites.syncedSitesRev,
      sealed: c.sealed,
      row: set.row,
      e: set.e,
      n: set.n,
      up: set.up,
      dirE: set.dirE,
      dirN: set.dirN,
    );
  }

  /// Vehicle slot [sl]'s pose into [out] as east, north, dirE, dirN and the
  /// metres above the datum; false when its columns describe none.
  ///
  /// **The pose is the car's CENTRE.** On a site lane it is taken at the
  /// simulation's own `s` rather than half a length behind it, because a
  /// manoeuvre's `u = 0` IS the lane pose at the stall's mouth
  /// (`SiteManoeuvre.stallPose`): drawing both by one convention is what
  /// makes a car turning into its stall carry on from where it was driving
  /// rather than jump half its length.
  static bool _poseOf(
      SiteAccessPlan plan,
      SiteChunkGeometry g,
      int k,
      VehicleTable table,
      SiteVehicles cols,
      int sl,
      LaneGraph lg,
      int ph,
      Float64List out) {
    final ptBase = g.plan.ptStart(k);
    final lane = cols.lane[sl];
    if (ph == _inbound || ph == _toThroat || ph == _throatWait) {
      if (lane < 0 || lane >= 2 * plan.segCount) return false;
      return _lanePose(plan, g, ptBase, lane, table.s[sl].toDouble(), out);
    }
    if (ph == _stallIn || ph == _stallOut) {
      if (lane < 0 || lane >= 2 * plan.segCount) return false;
      final stall = cols.claim[sl];
      // A pull-out drops its stall the moment its nose is clear of it (§7.4
      // departure step 3); from then the curve cannot be rebuilt, and the
      // car is drawn on its aisle at the mouth — where that curve's own
      // `u = 0` stands.
      if (stall < 0 || stall >= plan.stallCount) {
        return _lanePose(plan, g, ptBase, lane, table.s[sl].toDouble(), out);
      }
      final fwd = SiteLaneGraph.isForward(lane);
      final dir = fwd ? kSiteDirFwd : kSiteDirBwd;
      final u = cols.manU[sl].toDouble();
      SiteManoeuvre.stallPose(plan, stall, dir, u, out, 0);
      final seg = SiteLaneGraph.segOf(lane);
      final mouth = SiteManoeuvre.mouthS(plan, stall, dir);
      final aisle = _upAlong(
          g, plan, ptBase, seg, fwd ? mouth : plan.segLenM(seg) - mouth);
      final onStall = g.stallUp(g.plan.stallStart(k) + stall);
      out[4] = aisle + (onStall - aisle) * u;
      return true;
    }
    // A home back-out: waiting in its stall, reversing down the drive, or
    // stopped in its lane to shift (§7.4 Home back-out). Its road lane is
    // the first element of the route it locked before it moved.
    final stall = cols.claim[sl];
    final join = cols.join[sl];
    if (stall < 0 ||
        stall >= plan.stallCount ||
        join < 0 ||
        join >= plan.joinCount ||
        table.routeLen[sl] <= 0) {
      return false;
    }
    final road = table.arena.data[table.routeOff[sl]];
    if (road < 0 || road >= lg.laneCount) return false;
    final u = cols.manU[sl].toDouble();
    SiteManoeuvre.backOutPose(plan, join, stall, road, lg, u, out, 0,
        lenM: table.len[sl].toDouble());
    // It reverses off the pave of its stall onto the kerb line, so its
    // height runs between the two: the kerb node stands on the road's own
    // drape, which is where it ends up.
    final onStall = g.stallUp(g.plan.stallStart(k) + stall);
    final kerbNode = plan.joinKerbNode(join);
    final onKerb =
        kerbNode < 0 ? onStall : g.ptUp(ptBase + plan.nodePt(kerbNode));
    out[4] = onStall + (onKerb - onStall) * u;
    return true;
  }

  /// The pose [s] metres along site [lane] of [plan] into [out].
  static bool _lanePose(SiteAccessPlan plan, SiteChunkGeometry g, int ptBase,
      int lane, double s, Float64List out) {
    var at = s;
    if (at < 0) at = 0;
    SiteManoeuvre.lanePose(plan, lane, at, out, 0);
    final seg = SiteLaneGraph.segOf(lane);
    final len = plan.segLenM(seg);
    if (at > len) at = len;
    // The lane's arc runs the way the LANE does and the points the way the
    // SEGMENT does, so a backward lane reads them from the other end.
    out[4] = _upAlong(g, plan, ptBase, seg,
        SiteLaneGraph.isForward(lane) ? at : len - at);
    return true;
  }

  /// Metres above the datum at [s] along segment [seg]'s polyline, from the
  /// heights R3 published for its points — `SiteCapture._upAlong` read from
  /// the other side of the wire.
  static double _upAlong(SiteChunkGeometry g, SiteAccessPlan plan, int ptBase,
      int seg, double s) {
    if (seg < 0 || seg >= plan.segCount) return 0;
    final m = plan.segPointCount(seg);
    final first = plan.segPoint(seg, 0);
    if (m < 2) return g.ptUp(ptBase + first);
    var acc = 0.0;
    for (var i = 1; i < m; i++) {
      final a = plan.segPoint(seg, i - 1), b = plan.segPoint(seg, i);
      final de = plan.ptE(b) - plan.ptE(a), dn = plan.ptN(b) - plan.ptN(a);
      final len = math.sqrt(de * de + dn * dn);
      if (s <= acc + len || i == m - 1) {
        final u = len > 0 ? ((s - acc) / len).clamp(0.0, 1.0) : 0.0;
        final ua = g.ptUp(ptBase + a), ub = g.ptUp(ptBase + b);
        return ua + (ub - ua) * u;
      }
      acc += len;
    }
    return g.ptUp(ptBase + first);
  }

  // ---- The cars parked on stalls --------------------------------------------

  /// The colony's lot cars, rebuilt only when one came or went or the site
  /// geometry moved, and HELD one publish whenever the agents' site revision
  /// and the frame's disagree (§7.5): a stall index means something only
  /// against the plan it was taken from, so a car is better drawn where it
  /// stood a moment ago than on some other stall.
  static ParkedColumns parked(CitySim city, CitySiteFrame? sf, _Cache c) {
    final agents = city.agents;
    final cars = agents.parkedCars;
    final sites = agents.sites;
    if (cars == null || sites == null || sf == null) return ParkedColumns.empty;
    final held = c.parked;
    if (sites.syncedSitesRev != sf.sitesRev) {
      return held ?? ParkedColumns.empty;
    }
    if (held != null &&
        held.parkedRev == cars.parkedRev &&
        identical(c.parkedFor, sf)) {
      return held;
    }
    final cap = cars.lotCars;
    final site = Int32List(cap), stall = Int32List(cap);
    final kind = Uint8List(cap), variant = Uint8List(cap);
    final e = Float32List(cap),
        n = Float32List(cap),
        up = Float32List(cap),
        dirE = Float32List(cap),
        dirN = Float32List(cap);
    var count = 0;
    final hw = cars.pool.highWater;
    for (var i = 0; i < hw && count < cap; i++) {
      if (!cars.pool.isSlotLive(i) || cars.where[i] != _lot) continue;
      final row = cars.row[i], st = cars.stall[i];
      if (row < 0 || !sites.isRowLive(row)) continue;
      final plan = sites.plan[row];
      if (plan == null || st < 0 || st >= plan.stallCount) continue;
      final slot = sites.bookSlot[row];
      final at = sf.locate(slot);
      if (at == null) continue;
      final g = at.$1, k = at.$2;
      if (!identical(g.plan, plan.chunk) || k != plan.site) continue;
      site[count] = slot;
      stall[count] = st;
      kind[count] = cars.kind[i];
      variant[count] = cars.variant[i];
      // The stall pose itself (§7.4): the car's centre, its nose along the
      // stall's direction, on the pave R3 measured under it.
      e[count] = plan.stallE(st);
      n[count] = plan.stallN(st);
      dirE[count] = plan.stallDirE(st);
      dirN[count] = plan.stallDirN(st);
      up[count] = g.stallUp(g.plan.stallStart(k) + st);
      count++;
    }
    c.parkedFor = sf;
    return c.parked = ParkedColumns(
      parkedRev: cars.parkedRev,
      sitesRev: sf.sitesRev,
      lotCount: count,
      lotSite: site,
      lotStall: stall,
      lotKind: kind,
      lotVariant: variant,
      lotE: e,
      lotN: n,
      lotUp: up,
      lotDirE: dirE,
      lotDirN: dirN,
    );
  }
}
