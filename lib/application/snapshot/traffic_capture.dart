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
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/parcel.dart';
import '../../domain/colony/city/road_graph.dart';
import '../../domain/colony/city/spatial_index.dart';
import '../../domain/colony/city/sprawl_plan.dart';
import '../../domain/colony/city/traffic/agent_frame.dart';
import '../../domain/colony/city/traffic/lane_graph.dart';
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
  /// just added.
  static CityTrafficFrame frameFor(
      CitySim city, String bodyId, List<RoadSnapshot> roads) {
    final agents = city.agents;
    final lg = agents.laneGraph;
    if (lg == null) {
      return CityTrafficFrame(
        colonyId: city.id,
        bodyId: bodyId,
        agents: agents.frame,
        geometry: TrafficGeometry.empty,
        net: TrafficNetColumns.empty,
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
    );
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

  /// The lane-graph object [net] was built from.
  LaneGraph? netGraph;
  TrafficNetColumns? net;
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
