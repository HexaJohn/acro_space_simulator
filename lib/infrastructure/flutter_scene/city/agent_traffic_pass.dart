// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where an agent colony's vehicles are drawn (docs/plans/agent-traffic.md
/// §13.3–13.8).
///
/// Pure arithmetic and no scene: this turns the frame's (element, s, v, a)
/// into instance matrices in pose buffers, and `CityNodes` (its
/// `agent_nodes.dart` part) owns the draws that read them — so every rule
/// here is testable without a renderer, as the cosmetic pass's are
/// (city_traffic.dart).
///
/// - Where. A vehicle is placed on the geometry the capture sliced from the
///   road snapshots — the ribbons' own points and lifts — made relative to
///   the body root's anchor once per (geometry, anchor) ([AgentPoseTables]).
///   A connector's path is bent at its ends onto the lanes it joins, so a
///   vehicle crossing from one to the other never jumps.
/// - When. The renderer keeps its own agent clock ([AgentRenderClock]),
///   advanced by wall time at the rate the frames measure, and extrapolates
///   each vehicle from its sample to it. A frame without a tick is normal —
///   world ticks are 20 ms — so the clock never waits for one; it stops only
///   when the host's warp is 0.
/// - Which. Nearest first: rings of 0–500, 500–1,500 and 1,500–3,500 m, in
///   slot order within a ring, until the cap — the same vehicles for every
///   client at the same focus, and the cap spent where the camera is.
/// - As what. The domain publishes an `AgentKind` and an opaque variant
///   byte (D42); the model is chosen here ([agentVehicleKind]).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../application/snapshot/city_traffic_frame.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/colony/city/traffic/agent_frame.dart';
import '../../../domain/colony/city/traffic/agent_kind.dart';
import '../../../domain/colony/city/traffic/traffic_time.dart';
import '../../../domain/shared/vector3.dart';
import 'city_traffic.dart';
import 'road_mesher.dart';
import 'vehicle_meshes.dart';

/// The model that draws an agent of [kind] (an `AgentKind` index) with
/// [variant], or null for one this pass does not draw: trains run the
/// rails, and are the rail pass's (slice 9b).
///
/// The service fleets and the bus have no models of their own until E21
/// appends them (slice 5), and borrow the nearest silhouette meanwhile. On
/// a sealed world everything on the road is a rover, the cosmetic pass's
/// rule, until those models exist.
VehicleKind? agentVehicleKind(int kind, int variant, {bool sealed = false}) {
  if (kind < 0 || kind >= AgentKind.values.length) return null;
  final vk = switch (AgentKind.values[kind]) {
    AgentKind.car => variant & 1 == 0 ? VehicleKind.coupe : VehicleKind.sedan,
    AgentKind.truck ||
    AgentKind.bus ||
    AgentKind.garbageTruck ||
    AgentKind.fireEngine =>
      VehicleKind.truck,
    AgentKind.semi => VehicleKind.semi,
    AgentKind.hearse ||
    AgentKind.policeCar ||
    AgentKind.ambulance ||
    AgentKind.mailVan ||
    AgentKind.deliveryVan =>
      VehicleKind.sedan,
    AgentKind.train || AgentKind.lTrain || AgentKind.freightTrain => null,
  };
  if (vk == null) return null;
  return sealed ? VehicleKind.rover : vk;
}

/// The renderer's agent clock (§13.4): the agent time vehicles are drawn
/// at, in seconds.
///
/// Each sub-step's frame is stamped with its own agent time, and the clock
/// runs between samples at the rate they arrive — measured in AGENT time
/// against WALL time, so 1× reads 1, a warp reads its factor, and a frame
/// that ran no tick moves the vehicles on all the same. It stays within one
/// sub-step of the latest sample either way, snaps to it after a hitch, and
/// stands still while the host's warp is 0.
class AgentRenderClock {
  /// The sub-step: no vehicle is drawn more than this before or after its
  /// sample.
  static const double h = kStepS;

  /// Wall seconds of samples one rate measurement spans, and the weight of
  /// each measurement in the running rate.
  static const double rateWindowS = 0.5;
  static const double rateAlpha = 0.5;

  /// The highest rate believed: the frame hold runs at most a few sub-steps
  /// per UI frame, so anything above this is a measurement across a stall.
  static const double maxRate = 64;

  /// Agent seconds the vehicles are drawn at.
  double renderT = 0;

  /// Agent seconds per wall second, as measured.
  double rate = 1;

  /// [renderT] less the latest sample's time: how far each vehicle is
  /// extrapolated, seconds, negative when drawn behind its sample.
  double tau = 0;

  bool _started = false;
  double _lastWall = 0;
  double _lastSampleWall = 0;
  AgentFrame? _frame;
  bool _window = false;
  double _winWall = 0, _winT = 0;

  /// [renderT] in whole agent microseconds: what a signal plan is asked at.
  int get renderTimeUs => (renderT * 1e6).round();

  /// Advances to wall time [wallNowS] (seconds, any origin) with [frame] the
  /// latest sample, the host's warp [warp]; returns [tau].
  double advance(AgentFrame frame, double wallNowS, {double warp = 1}) {
    final t = frame.timeUs / 1e6;
    final wallDt = _started ? math.max(0.0, wallNowS - _lastWall) : 0.0;
    _lastWall = wallNowS;
    if (!identical(frame, _frame)) {
      _frame = frame;
      // A first sample, a clock that went back (the agents restarted), or a
      // sample after a stall starts the measurement afresh: a window that
      // spans a stall would read the stall as a slow rate.
      if (!_window ||
          t < _winT ||
          wallNowS - _lastSampleWall > 2 * rateWindowS) {
        _window = true;
        _winWall = wallNowS;
        _winT = t;
      } else if (wallNowS - _winWall >= rateWindowS) {
        final measured =
            ((t - _winT) / (wallNowS - _winWall)).clamp(0.0, maxRate);
        rate += (measured - rate) * rateAlpha;
        _winWall = wallNowS;
        _winT = t;
      }
      _lastSampleWall = wallNowS;
    }
    var next = renderT + wallDt * (warp > 0 ? rate : 0.0);
    // The first frame, a hitch or a warp change: whatever the clock thought,
    // the sample is where the vehicles are.
    if (!_started || (next - t).abs() > 2 * h) {
      next = t;
      _started = true;
    }
    // Within one sub-step of the sample either way. This is also the stall
    // guard: with no new sample the clock runs on to t + h and waits there.
    renderT = next.clamp(t - h, t + h);
    return tau = renderT - t;
  }
}

/// A vehicle's pose: where its centre is, anchor-relative metres, and its
/// basis — side (right of travel), forward, up, orthonormal with
/// determinant +1, never mirrored.
class AgentPose {
  double px = 0, py = 0, pz = 0;

  /// The point on the drape under the centre — the lane's offset applied,
  /// no lift — anchor-relative: where a connector meeting this lane ends.
  double gx = 0, gy = 0, gz = 0;
  double sx = 0, sy = 0, sz = 0;
  double fx = 0, fy = 0, fz = 0;
  double ux = 0, uy = 0, uz = 0;

  /// Metres above the drape, the ribbon's lift included.
  double lift = 0;
}

/// One draw's worth of poses: a model, near (casting shadows) or far.
class AgentDrawBatch {
  AgentDrawBatch(this.kind, this.near);

  final VehicleKind kind;
  final bool near;

  /// Instances a draw grows by: its count moves in steps of this, so the
  /// vehicles coming and going within a step never change it.
  static const int bucket = 64;

  /// What to upload: [live] poses, then zero-scale matrices up to
  /// [highWater].
  final TrafficBuffer poses = TrafficBuffer();

  /// Poses placed this frame.
  int live = 0;

  /// The most this draw has held, rounded up to [bucket]. It only grows —
  /// until [resetHighWater] — so the draw's instance count stands still and
  /// its instances are moved in place rather than cleared and re-added.
  int highWater = 0;

  void _begin() {
    poses.reset();
    live = 0;
  }

  void _finish() {
    live = poses.count;
    if (live == 0) return;
    final want = (live + bucket - 1) ~/ bucket * bucket;
    if (want > highWater) highWater = want;
    while (poses.count < highWater) {
      poses.next().setZero();
    }
  }

  /// Forget the high-water mark: the draw was dropped.
  void resetHighWater() => highWater = 0;
}

/// A geometry's tables made relative to one anchor, and the pose of any
/// point on any lane or connector. Built once per (geometry, anchor).
class AgentPoseTables {
  AgentPoseTables(this.geometry, this.anchorBF) {
    _build();
  }

  final TrafficGeometry geometry;
  final Vector3 anchorBF;

  /// Metres a lane's centre keeps from the edge of the running lanes where
  /// a taper narrows them: about a car's half width.
  static const double laneEdgeMarginM = 1.0;

  /// The share of a connector at either end over which a vehicle rises onto
  /// a junction plate.
  static const double plateRampShare = 0.15;

  static const int _k = TrafficGeometry.conPoints;

  /// Anchor-relative xyz per point, and the unit direction of the segment
  /// leaving each (the last point: the one arriving).
  late final Float64List _p;
  late final Float64List _dir;

  /// Per connector: its points bent onto its lanes' ends, anchor-relative;
  /// the arc at each; the unit direction of the segment leaving each; and
  /// the road's own lift at either end.
  late final Float64List _cp, _cc, _cd, _cl;

  /// Per element: a bounding sphere, anchor-relative (xyz, radius).
  late final Float64List _eb;

  void _build() {
    final g = geometry;
    final nPt = g.pointCount;
    _p = Float64List(3 * nPt);
    for (var i = 0; i < nPt; i++) {
      _p[3 * i] = g.pts[3 * i] - anchorBF.x;
      _p[3 * i + 1] = g.pts[3 * i + 1] - anchorBF.y;
      _p[3 * i + 2] = g.pts[3 * i + 2] - anchorBF.z;
    }
    _dir = Float64List(3 * nPt);
    for (var e = 0; e < g.edgeCount; e++) {
      _directions(_p, _dir, g.edgePtStart[e], g.edgePtStart[e + 1]);
    }

    final nL = g.laneCount, nC = g.connectorCount;
    _eb = Float64List(4 * (nL + nC));
    final edgeSphere = Float64List(4 * g.edgeCount);
    for (var e = 0; e < g.edgeCount; e++) {
      _sphere(_p, g.edgePtStart[e], g.edgePtStart[e + 1], edgeSphere, e);
    }
    for (var l = 0; l < nL; l++) {
      final e = g.laneEdge[l];
      for (var j = 0; j < 4; j++) {
        _eb[4 * l + j] = edgeSphere[4 * e + j];
      }
    }

    _cp = Float64List(3 * _k * nC);
    _cc = Float64List(_k * nC);
    _cd = Float64List(3 * _k * nC);
    _cl = Float64List(2 * nC);
    final end = AgentPose(), start = AgentPose();
    for (var c = 0; c < nC; c++) {
      final base = _k * c;
      for (var i = 0; i < _k; i++) {
        final o = 3 * (base + i);
        _cp[o] = g.conPts[o] - anchorBF.x;
        _cp[o + 1] = g.conPts[o + 1] - anchorBF.y;
        _cp[o + 2] = g.conPts[o + 2] - anchorBF.z;
      }
      // Bend the path onto the lanes it joins: the domain's Bézier was
      // sampled on its own polyline, and the lanes here are the capture's,
      // decimetres apart. Blended end to end, so the ends meet the lanes
      // exactly and the middle keeps the domain's curve.
      //
      // Read off the lanes whether or not a tunnel hides them: a connector
      // between two lanes underground — a junction or a turning place sunk
      // with its roads — takes their lifts, and its own pose hides it
      // there, rather than keep no lift and draw its cars on the ground
      // above the tunnel.
      final from = g.conFromLane[c], to = g.conToLane[c];
      final hasEnd = _lanePose(from, g.laneLen[from], 0, end, null, -1, false);
      final hasStart = _lanePose(to, 0, 0, start, null, -1, false);
      final o0 = 3 * base, o1 = 3 * (base + _k - 1);
      // (On the drape: the lift is the pose's, added along the same
      // direction on either side of the join.)
      final d0x = hasEnd ? end.gx - _cp[o0] : 0.0;
      final d0y = hasEnd ? end.gy - _cp[o0 + 1] : 0.0;
      final d0z = hasEnd ? end.gz - _cp[o0 + 2] : 0.0;
      final d1x = hasStart ? start.gx - _cp[o1] : 0.0;
      final d1y = hasStart ? start.gy - _cp[o1 + 1] : 0.0;
      final d1z = hasStart ? start.gz - _cp[o1 + 2] : 0.0;
      for (var i = 0; i < _k; i++) {
        final w = i / (_k - 1);
        final o = 3 * (base + i);
        _cp[o] += d0x * (1 - w) + d1x * w;
        _cp[o + 1] += d0y * (1 - w) + d1y * w;
        _cp[o + 2] += d0z * (1 - w) + d1z * w;
      }
      // The ends' exact positions: the blend is exact in arithmetic, not
      // always in floating point.
      if (hasEnd) {
        _cp[o0] = end.gx;
        _cp[o0 + 1] = end.gy;
        _cp[o0 + 2] = end.gz;
      }
      if (hasStart) {
        _cp[o1] = start.gx;
        _cp[o1 + 1] = start.gy;
        _cp[o1 + 2] = start.gz;
      }
      _cl[2 * c] = hasEnd ? end.lift - RoadMesher.ribbonLiftM : 0;
      _cl[2 * c + 1] = hasStart ? start.lift - RoadMesher.ribbonLiftM : 0;
      _cc[base] = 0;
      for (var i = 1; i < _k; i++) {
        final o = 3 * (base + i);
        final dx = _cp[o] - _cp[o - 3];
        final dy = _cp[o + 1] - _cp[o - 2];
        final dz = _cp[o + 2] - _cp[o - 1];
        _cc[base + i] = _cc[base + i - 1] + math.sqrt(dx * dx + dy * dy + dz * dz);
      }
      _directions(_cp, _cd, base, base + _k);
      // A path with no length at all (lanes that meet end to end) points
      // the way the lane it leaves does.
      if (_cc[base + _k - 1] == 0 && hasEnd) {
        for (var i = 0; i < _k; i++) {
          _cd[3 * (base + i)] = end.fx;
          _cd[3 * (base + i) + 1] = end.fy;
          _cd[3 * (base + i) + 2] = end.fz;
        }
      }
      _sphere(_cp, base, base + _k, _eb, nL + c);
    }
  }

  /// Unit directions of the segments of points `a .. b − 1`, a zero-length
  /// segment taking its neighbour's, and the last point its arrival's.
  static void _directions(Float64List p, Float64List dir, int a, int b) {
    if (b - a < 2) return;
    var have = false;
    for (var k = a; k < b - 1; k++) {
      final dx = p[3 * k + 3] - p[3 * k];
      final dy = p[3 * k + 4] - p[3 * k + 1];
      final dz = p[3 * k + 5] - p[3 * k + 2];
      final l = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (l > 1e-9) {
        dir[3 * k] = dx / l;
        dir[3 * k + 1] = dy / l;
        dir[3 * k + 2] = dz / l;
        have = true;
      } else if (k > a) {
        dir[3 * k] = dir[3 * k - 3];
        dir[3 * k + 1] = dir[3 * k - 2];
        dir[3 * k + 2] = dir[3 * k - 1];
      }
    }
    if (!have) return;
    // Leading zero-length segments take the first real direction.
    var first = a;
    while (dir[3 * first] == 0 && dir[3 * first + 1] == 0 && dir[3 * first + 2] == 0) {
      first++;
    }
    for (var k = a; k < first; k++) {
      dir[3 * k] = dir[3 * first];
      dir[3 * k + 1] = dir[3 * first + 1];
      dir[3 * k + 2] = dir[3 * first + 2];
    }
    final last = b - 1;
    dir[3 * last] = dir[3 * last - 3];
    dir[3 * last + 1] = dir[3 * last - 2];
    dir[3 * last + 2] = dir[3 * last - 1];
  }

  /// The bounding sphere of points `a .. b − 1` into slot [i] of [out].
  static void _sphere(Float64List p, int a, int b, Float64List out, int i) {
    if (b <= a) {
      out[4 * i + 3] = -1;
      return;
    }
    var x0 = double.infinity, y0 = double.infinity, z0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity, z1 = -double.infinity;
    for (var k = a; k < b; k++) {
      x0 = math.min(x0, p[3 * k]);
      x1 = math.max(x1, p[3 * k]);
      y0 = math.min(y0, p[3 * k + 1]);
      y1 = math.max(y1, p[3 * k + 1]);
      z0 = math.min(z0, p[3 * k + 2]);
      z1 = math.max(z1, p[3 * k + 2]);
    }
    out[4 * i] = (x0 + x1) / 2;
    out[4 * i + 1] = (y0 + y1) / 2;
    out[4 * i + 2] = (z0 + z1) / 2;
    final dx = x1 - x0, dy = y1 - y0, dz = z1 - z0;
    out[4 * i + 3] = math.sqrt(dx * dx + dy * dy + dz * dz) / 2;
  }

  /// Metres from [x], [y], [z] (anchor-relative) to element [elem]'s
  /// bounds; infinity for an element with no geometry.
  double distanceTo(int elem, double x, double y, double z) {
    final r = _eb[4 * elem + 3];
    if (r < 0) return double.infinity;
    final dx = _eb[4 * elem] - x;
    final dy = _eb[4 * elem + 1] - y;
    final dz = _eb[4 * elem + 2] - z;
    return math.max(0.0, math.sqrt(dx * dx + dy * dy + dz * dz) - r);
  }

  /// Simulation length of element [elem].
  double lengthOf(int elem) {
    final nL = geometry.laneCount;
    return elem < nL ? geometry.laneLen[elem] : geometry.conLen[elem - nL];
  }

  /// The edge element [elem] runs along, or leaves for a connector.
  int edgeOf(int elem) {
    final g = geometry;
    return elem < g.laneCount
        ? g.laneEdge[elem]
        : g.laneEdge[g.conFromLane[elem - g.laneCount]];
  }

  /// Writes into [out] the pose [s] metres (simulation arc) along element
  /// [elem], [lat] metres right of its lane. False when there is nothing
  /// to draw there: no geometry, or a road in a tunnel.
  ///
  /// [s] may run off either end of the element: the pose carries straight
  /// on from the end it passed, which is how a vehicle's centre is drawn
  /// half a length behind a front that has just crossed onto the next.
  /// [hints] (one per frame row) remember each row's last segment, so the
  /// search is a compare or two frame to frame; [row] −1 skips them.
  bool poseAt(int elem, double s, double lat, AgentPose out,
      [Int32List? hints, int row = -1]) {
    if (elem < 0) return false;
    final nL = geometry.laneCount;
    if (elem < nL) return _lanePose(elem, s, lat, out, hints, row, true);
    final c = elem - nL;
    if (c >= geometry.connectorCount) return false;
    return _connectorPose(c, s, lat, out);
  }

  /// [hideTunnel] false poses a lane under the ground too: the tables read
  /// a connector's ends, and their lifts, off lanes a tunnel hides.
  bool _lanePose(int l, double s, double lat, AgentPose out, Int32List? hints,
      int row, bool hideTunnel) {
    final g = geometry;
    final e = g.laneEdge[l];
    final a = g.edgePtStart[e], b = g.edgePtStart[e + 1];
    if (b - a < 2) return false;
    final cum = g.cum;
    final sim = g.edgeSimLen[e];
    final x = (g.laneS0[l] + s) * (sim > 0 ? cum[b - 1] / sim : 1.0);
    var k = -1;
    if (hints != null && row >= 0) {
      final hk = hints[row];
      if (hk >= a && hk < b - 1 && cum[hk] <= x && (x < cum[hk + 1] || hk == b - 2)) {
        k = hk;
      }
    }
    if (k < 0) {
      var lo = a, hi = b - 2;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (cum[mid] <= x) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      k = lo;
      if (hints != null && row >= 0) hints[row] = k;
    }
    final span = cum[k + 1] - cum[k];
    // Unclamped: before the first point or past the last it carries on
    // along the end segment.
    final u = span > 0 ? (x - cum[k]) / span : 0.0;
    final uc = u < 0 ? 0.0 : (u > 1 ? 1.0 : u);
    final roadLift = g.lift[k] + (g.lift[k + 1] - g.lift[k]) * uc;
    // In a tunnel the road is under the ground, and so is the car.
    if (hideTunnel && roadLift < -RoadElevation.tunnelCoverM) return false;
    final room = g.room[k] + (g.room[k + 1] - g.room[k]) * uc;
    var off = g.laneOff[l] * g.edgeOffScale[e];
    // Where a taper narrows the road, a lane outside the narrowed edge
    // rides it — the paint's own rule — and lanes inside keep their place.
    final limit = math.max(0.0, room - laneEdgeMarginM);
    if (off > limit) off = limit;
    if (off < -limit) off = -limit;
    final p = _p;
    return _frame(
      out,
      p[3 * k] + (p[3 * k + 3] - p[3 * k]) * u,
      p[3 * k + 1] + (p[3 * k + 4] - p[3 * k + 1]) * u,
      p[3 * k + 2] + (p[3 * k + 5] - p[3 * k + 2]) * u,
      _dir[3 * k],
      _dir[3 * k + 1],
      _dir[3 * k + 2],
      off + lat,
      RoadMesher.ribbonLiftM + roadLift,
    );
  }

  bool _connectorPose(int c, double s, double lat, AgentPose out) {
    final base = _k * c;
    final total = _cc[base + _k - 1];
    final sim = geometry.conLen[c];
    final x = total > 0 && sim > 0 ? s * total / sim : 0.0;
    var k = 0;
    while (k < _k - 2 && _cc[base + k + 1] <= x) {
      k++;
    }
    final span = _cc[base + k + 1] - _cc[base + k];
    final u = span > 0 ? (x - _cc[base + k]) / span : 0.0;
    final t = total > 0 ? (x / total).clamp(0.0, 1.0) : 0.5;
    final roadLift = _cl[2 * c] + (_cl[2 * c + 1] - _cl[2 * c]) * t;
    if (roadLift < -RoadElevation.tunnelCoverM) return false;
    // Onto the junction plate, which stands a few centimetres over the
    // ribbon, over the first and last stretch of the crossing.
    final plate = geometry.conPlate[c] == 0
        ? 0.0
        : math.min(1.0, math.min(t, 1 - t) / plateRampShare) *
            (RoadMesher.plateLiftM - RoadMesher.ribbonLiftM);
    final o = 3 * (base + k);
    return _frame(
      out,
      _cp[o] + (_cp[o + 3] - _cp[o]) * u,
      _cp[o + 1] + (_cp[o + 4] - _cp[o + 1]) * u,
      _cp[o + 2] + (_cp[o + 5] - _cp[o + 2]) * u,
      _cd[o],
      _cd[o + 1],
      _cd[o + 2],
      lat,
      RoadMesher.ribbonLiftM + roadLift + plate,
    );
  }

  /// The pose at point (px, py, pz) on the drape heading (fx, fy, fz):
  /// [lateral] metres to its right and [lift] up, with up radial on the
  /// body (as city_traffic.dart), side = forward × up, and the basis's up
  /// re-derived as side × forward so a vehicle on a slope pitches with it
  /// and the basis stays orthonormal.
  ///
  /// The lift is along the radial of the point BESIDE the line, not of the
  /// line itself: a connector's end is that very point, so a vehicle
  /// crossing from a lane onto it is lifted along the same direction and
  /// does not move.
  bool _frame(AgentPose out, double px, double py, double pz, double fx,
      double fy, double fz, double lateral, double lift) {
    var ux = px + anchorBF.x, uy = py + anchorBF.y, uz = pz + anchorBF.z;
    final ul = math.sqrt(ux * ux + uy * uy + uz * uz);
    if (ul == 0) return false;
    ux /= ul;
    uy /= ul;
    uz /= ul;
    var sx = fy * uz - fz * uy, sy = fz * ux - fx * uz, sz = fx * uy - fy * ux;
    final sl = math.sqrt(sx * sx + sy * sy + sz * sz);
    if (sl < 1e-9) return false;
    sx /= sl;
    sy /= sl;
    sz /= sl;
    final gx = px + sx * lateral, gy = py + sy * lateral, gz = pz + sz * lateral;
    var lx = gx + anchorBF.x, ly = gy + anchorBF.y, lz = gz + anchorBF.z;
    final ll = math.sqrt(lx * lx + ly * ly + lz * lz);
    lx /= ll;
    ly /= ll;
    lz /= ll;
    out
      ..gx = gx
      ..gy = gy
      ..gz = gz
      ..px = gx + lx * lift
      ..py = gy + ly * lift
      ..pz = gz + lz * lift
      ..lift = lift;
    // Forward within the plane the side leaves: the segment's own direction,
    // pitched with the road.
    final fl = math.sqrt(fx * fx + fy * fy + fz * fz);
    final nfx = fx / fl, nfy = fy / fl, nfz = fz / fl;
    // side × forward: up, tilted with the road, unit because the two are.
    final bx = sy * nfz - sz * nfy;
    final by = sz * nfx - sx * nfz;
    final bz = sx * nfy - sy * nfx;
    final bl = math.sqrt(bx * bx + by * by + bz * bz);
    out
      ..sx = sx
      ..sy = sy
      ..sz = sz
      ..fx = nfx
      ..fy = nfy
      ..fz = nfz
      ..ux = bx / bl
      ..uy = by / bl
      ..uz = bz / bl;
    return true;
  }
}

/// One agent colony's pose pass: its clock, its tables, and the batches it
/// places into. `CityNodes` keeps one per colony.
class AgentTrafficPass {
  // ---- Render knobs (§15.4): views of the scene, never of the simulation.

  /// Whether agents are drawn at all.
  static bool drawn = true;

  /// Vehicles drawn per colony per frame, nearest first.
  static int renderCap = 1500;

  /// Vehicles further than this from the focus are not drawn.
  static double rangeM = 3500;

  /// Vehicles nearer than this cast shadows; further ones are drawn by
  /// draws that do not, which saves the shadow pass one packing per
  /// instance.
  static double shadowRangeM = 800;

  /// The host's warp (E26): the render clock stands still at 0 or below.
  static double simWarp = 1;

  /// The inner rings of the selection.
  static const double nearRingM = 500, midRingM = 1500;

  final AgentRenderClock clock = AgentRenderClock();

  AgentPoseTables? _tables;
  final List<AgentDrawBatch?> _batches =
      List<AgentDrawBatch?>.filled(VehicleKind.values.length * 2, null);
  Int32List _hints = Int32List(0);
  Int32List _rings = Int32List(0);
  final Int32List _ringCount = Int32List(3);
  final AgentPose _pose = AgentPose();

  /// Vehicles placed this frame; in range; in range but hidden (in a
  /// tunnel, or on a road with no geometry).
  int placed = 0;
  int inRange = 0;
  int hidden = 0;

  /// The tables the last frame was placed from.
  AgentPoseTables? get tables => _tables;

  /// Every batch by `VehicleKind.index * 2` (+1 far); null where none was
  /// ever placed. A batch with [AgentDrawBatch.live] 0 drew nothing.
  List<AgentDrawBatch?> get batches => _batches;

  /// The batch for [kind], [near] or far.
  AgentDrawBatch batchOf(VehicleKind kind, bool near) {
    final i = kind.index * 2 + (near ? 0 : 1);
    return _batches[i] ??= AgentDrawBatch(kind, near);
  }

  /// Forget every batch's high-water mark: the draws were dropped.
  void resetHighWater() {
    for (final b in _batches) {
      b?.resetHighWater();
    }
  }

  /// Places [frame]'s vehicles for this frame at wall time [wallNowS], the
  /// focus at [focusBF] (body-fixed) and every pose relative to [anchorBF].
  /// Returns how many were placed.
  int place(CityTrafficFrame frame, Vector3 anchorBF, Vector3 focusBF,
      {required double wallNowS, double? warp}) {
    for (final b in _batches) {
      b?._begin();
    }
    placed = 0;
    inRange = 0;
    hidden = 0;
    final f = frame.agents;
    final g = frame.geometry;
    final tau = clock.advance(f, wallNowS, warp: warp ?? simWarp);
    if (f.count > 0 && g.graphRev == f.graphRev && g.laneCount > 0) {
      _placeAll(f, g, anchorBF, focusBF, tau);
    }
    for (final b in _batches) {
      b?._finish();
    }
    return placed;
  }

  void _placeAll(AgentFrame f, TrafficGeometry g, Vector3 anchorBF,
      Vector3 focusBF, double tau) {
    var t = _tables;
    if (t == null || !identical(t.geometry, g) || t.anchorBF != anchorBF) {
      t = _tables = AgentPoseTables(g, anchorBF);
      _hints.fillRange(0, _hints.length, -1);
    }
    final n = f.count;
    if (_hints.length < n) {
      _hints = Int32List(n)..fillRange(0, n, -1);
      _rings = Int32List(3 * n);
    }
    final qx = focusBF.x - anchorBF.x;
    final qy = focusBF.y - anchorBF.y;
    final qz = focusBF.z - anchorBF.z;
    final nElem = g.elementCount;
    _ringCount.fillRange(0, 3, 0);
    for (var i = 0; i < n; i++) {
      final elem = f.elem[i];
      if (f.handle[i] < 0 || elem < 0 || elem >= nElem) continue;
      final d = t.distanceTo(elem, qx, qy, qz);
      final ring = d < nearRingM
          ? 0
          : d < midRingM
              ? 1
              : d <= rangeM
                  ? 2
                  : -1;
      if (ring < 0) continue;
      _rings[ring * n + _ringCount[ring]++] = i;
    }
    inRange = _ringCount[0] + _ringCount[1] + _ringCount[2];
    final cap = renderCap;
    for (var ring = 0; ring < 3 && placed < cap; ring++) {
      for (var j = 0; j < _ringCount[ring] && placed < cap; j++) {
        if (_placeRow(f, t, _rings[ring * n + j], tau, qx, qy, qz)) {
          placed++;
        } else {
          hidden++;
        }
      }
    }
  }

  /// Row [i] extrapolated by [tau] and written to its batch; false when it
  /// is not drawn.
  bool _placeRow(AgentFrame f, AgentPoseTables t, int i, double tau,
      double qx, double qy, double qz) {
    final g = t.geometry;
    var elem = f.elem[i];
    final kind = agentVehicleKind(f.kind[i], f.variant[i],
        sealed: g.edgeSealed[t.edgeOf(elem)] != 0);
    if (kind == null) return false;
    final s = advanceAlong(t, elem, f.next[i], f.s[i], f.v[i], f.a[i], tau,
        stopping: f.flags[i] & kFrameStopping != 0);
    elem = _elem;
    // The frame's s is the FRONT of the vehicle; the model stands on its
    // centre.
    if (!t.poseAt(elem, s - kind.lengthM / 2, f.lat[i], _pose, _hints, i)) {
      return false;
    }
    final p = _pose;
    final dx = p.px - qx, dy = p.py - qy, dz = p.pz - qz;
    final near = dx * dx + dy * dy + dz * dz < shadowRangeM * shadowRangeM;
    TrafficRoad.writePose(batchOf(kind, near).poses.next(), p.px, p.py, p.pz,
        p.sx, p.sy, p.sz, p.fx, p.fy, p.fz, p.ux, p.uy, p.uz);
    return true;
  }

  /// The element [advanceAlong] ended on.
  int _elem = -1;

  /// Where a vehicle sampled at [s] on [elem] (next [next]) with speed [v]
  /// and acceleration [a] is [tau] seconds later: `s + v·τ + ½·a·τ²`, never
  /// backwards past a stop and never below 0, rolled on into [next] — and
  /// from a connector into the lane it reaches — with the remainder, but
  /// never past a point it may not pass ([stopping], or the end of its
  /// route). Returns the arc; the element is left in [lastElement].
  double advanceAlong(AgentPoseTables t, int elem, int next, double s,
      double v, double a, double tau,
      {bool stopping = false}) {
    double ds;
    if (tau >= 0) {
      // Braking to a stand inside the interval: it stops, it does not
      // reverse.
      ds = a < 0 && v + a * tau < 0 ? v * v / (-2 * a) : v * tau + 0.5 * a * tau * tau;
    } else {
      // Back in time: pulling away from rest had not begun yet.
      ds = a > 0 && v + a * tau < 0 ? -v * v / (2 * a) : v * tau + 0.5 * a * tau * tau;
      if (ds > 0) ds = 0;
    }
    var at = math.max(0.0, s + ds);
    final g = t.geometry;
    final nL = g.laneCount, nElem = g.elementCount;
    var e = elem, nx = next;
    while (true) {
      final len = t.lengthOf(e);
      if (at <= len) break;
      if (stopping || nx < 0 || nx >= nElem) {
        at = len;
        break;
      }
      at -= len;
      e = nx;
      // A connector reaches one lane; past that lane the route is not in
      // the frame, and the vehicle waits at its end for the next sample.
      nx = e >= nL ? g.conToLane[e - nL] : -1;
    }
    _elem = e;
    return at;
  }

  /// The element the last [advanceAlong] ended on.
  int get lastElement => _elem;
}
