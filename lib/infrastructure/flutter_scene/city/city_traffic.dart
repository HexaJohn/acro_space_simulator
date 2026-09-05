// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The traffic pass's tables and placement: vehicles running the colony's
/// roads, trains on its railway, the L on its elevated line.
///
/// Traffic is derived entirely from the frame — road polylines plus
/// [WorldSnapshot.epoch] — the way street lamps and junctions are, so there
/// is no traffic state anywhere in the sim, nothing on the wire, and every
/// client watching the same tick sees the same cars in the same places.
/// That invariant is the reason this file exists as a separate class: the
/// pass used to re-derive EVERYTHING from the colony every frame — every
/// road in every tile in range parsed into points, every rail piece
/// re-chained, all hundred-odd thousand buildings scanned for stations —
/// which was correct and cost seven milliseconds a frame for six hundred
/// cars. Here everything that does not depend on the epoch or on where the
/// camera is comes out of the frame ONCE, per tile, per structure change,
/// and the per-frame work is arithmetic on those tables into matrices that
/// are rewritten in place.
///
/// COSMETIC. Nothing here routes, yields, or knows a signal exists; vehicles
/// slide along their road and wrap. It is scenery, and the moment it stops
/// being scenery it belongs in the tick instead.
///
/// No scene in here: this produces pose buffers, and `CityNodes` owns the
/// resident nodes that draw them, so the placement is testable without a
/// renderer.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/sprawl_plan.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'elevated_structure.dart';
import 'rail_vehicles.dart';
import 'railway.dart';
import 'vehicle_meshes.dart';

/// A growable list of instance matrices with a live count, so a frame
/// rewrites last frame's matrices in place and allocates only when the
/// count grows past what it has.
class TrafficBuffer {
  final List<vm.Matrix4> matrices = [];

  /// How many of [matrices] are live this frame.
  int count = 0;

  /// The next matrix to write, allocated only past the high-water mark.
  vm.Matrix4 next() {
    if (count == matrices.length) matrices.add(vm.Matrix4.zero());
    return matrices[count++];
  }

  void reset() => count = 0;
}

/// A road as the traffic pass sees it, with everything that does not
/// depend on the epoch or the focus worked out at build time: its points
/// relative to the body's anchor, the cumulative length along them, each
/// segment's direction, how many vehicles a lane holds and how fast they
/// go, where the lanes are, where the deck rises onto a bridge.
///
/// Doubles rather than floats, deliberately: the placement is the same
/// arithmetic the per-frame pass used to do from the snapshot's doubles,
/// and keeping the operands the same keeps the matrices byte-identical to
/// what it produced — the determinism test is an equality, not a tolerance.
class TrafficRoad {
  TrafficRoad._({
    required this.pts,
    required this.seg,
    required this.segDir,
    required this.cum,
    required this.total,
    required this.roadClass,
    required this.perLane,
    required this.speed,
    required this.family,
    required this.seed,
    required this.laneOffsetsM,
    required this.oneWay,
    required this.ranges,
    required this.ax,
    required this.ay,
    required this.az,
    required this.bx,
    required this.by,
    required this.bz,
  });

  /// Anchor-relative xyz triples.
  final Float64List pts;

  /// Per segment: the raw difference `pts[i+1] - pts[i]`, and its
  /// normalised direction (zero where the segment is degenerate).
  final Float64List seg, segDir;

  /// Cumulative length at each point, and its last entry.
  final Float64List cum;
  final double total;
  final RoadClass roadClass;

  /// Vehicles per lane, and metres per second along the road.
  final int perLane;
  final double speed;

  /// The models a vehicle on this road is drawn from.
  final List<VehicleKind> family;

  /// The hash seed every vehicle on the road derives from.
  final int seed;

  /// Lateral offset of each drivable lane from the centreline, metres,
  /// already scaled to this road's width; one stream per lane per
  /// direction.
  final Float64List laneOffsetsM;
  final bool oneWay;

  /// Start,end pairs along the road that ride a bridge.
  final List<(double, double)> ranges;

  /// The road's two ends, BODY-FIXED, for the range gate — the focus comes
  /// in the body's frame, so the gate is a subtraction rather than a
  /// rotation.
  final double ax, ay, az, bx, by, bz;

  /// Streams times vehicles per stream: the most this road can place.
  int get capacity => (oneWay ? 1 : 2) * laneOffsetsM.length * perLane;

  /// Metres of road per vehicle PER LANE, and speed, by class.
  ///
  /// Both were derived from `cls.index` arithmetic, which happened to
  /// work while there were four classes and broke the moment there were
  /// seven: the spacing divisor `110 - index*22` reached zero at the
  /// elevated tier and went negative at rail. An enum's index is not a
  /// quantity — writing the quantity down is both correct and readable.
  static (double, double) spacingAndSpeed(RoadClass cls) => switch (cls) {
        RoadClass.street => (110.0, 8.0),
        RoadClass.avenue => (120.0, 13.0),
        RoadClass.highway => (110.0, 22.0),
        RoadClass.elevated => (95.0, 24.0),
        RoadClass.alley => (200.0, 4.0),
        RoadClass.path => (150.0, 6.0),
        // Out of town: sparse and fast.
        RoadClass.trunk => (140.0, 30.0),
        RoadClass.expressway4 => (90.0, 31.0),
        RoadClass.expressway6 => (95.0, 31.0),
        RoadClass.expressway8 => (100.0, 31.0),
        RoadClass.ramp => (160.0, 14.0),
        RoadClass.transit || RoadClass.rail => (0.0, 0.0),
      };

  /// Least distance from [focus] (body-fixed) to either end.
  double nearestEndTo(Vector3 focus) {
    final dax = ax - focus.x, day = ay - focus.y, daz = az - focus.z;
    final dbx = bx - focus.x, dby = by - focus.y, dbz = bz - focus.z;
    return math.min(math.sqrt(dax * dax + day * day + daz * daz),
        math.sqrt(dbx * dbx + dby * dby + dbz * dbz));
  }

  /// Place this road's vehicles at [epochS] into [into], until [into]
  /// reports full. Returns how many were placed.
  ///
  /// Each vehicle's model and phase come from a hash of (road seed, lane,
  /// index), so a car keeps its identity from frame to frame; its distance
  /// along the road is that phase advanced by the epoch and wrapped, so a
  /// paused clock is a stopped street.
  int place(double epochS, TrafficSink into) {
    final n = pts.length ~/ 3;
    var placed = 0;
    var stream = 0;
    for (var dirIndex = 0; dirIndex < (oneWay ? 1 : 2); dirIndex++) {
      final dirSign = dirIndex == 0 ? 1.0 : -1.0;
      for (var l = 0; l < laneOffsetsM.length; l++) {
        final laneOffset = laneOffsetsM[l];
        final lane = stream++;
        for (var i = 0; i < perLane; i++) {
          if (into.full) return placed;
          final h = hash(seed + lane * 7919 + i * 104729);
          final kind = family[h % family.length];
          // Longer vehicles need more room; spacing them by their own
          // length keeps a semi from sitting inside the car behind it.
          final phase = (h >> 8 & 0xFFFF) / 65536.0;
          var d = (total * (i + phase) / perLane + dirSign * epochS * speed) %
              total;
          if (d < 0) d += total;
          // Point and direction [d] metres along the polyline — a vehicle
          // is placed at a distance rather than at a vertex, or it would
          // snap between samples.
          var k = -1;
          var t = 0.0;
          for (var j = 1; j < n; j++) {
            if (d > cum[j]) continue;
            final s = j - 1;
            final sx = seg[s * 3], sy = seg[s * 3 + 1], sz = seg[s * 3 + 2];
            final len = math.sqrt(sx * sx + sy * sy + sz * sz);
            if (len < 1e-6) continue;
            k = s;
            t = ((d - cum[s]) / len).clamp(0.0, 1.0);
            break;
          }
          if (k < 0) continue;
          final px = pts[k * 3] + seg[k * 3] * t;
          final py = pts[k * 3 + 1] + seg[k * 3 + 1] * t;
          final pz = pts[k * 3 + 2] + seg[k * 3 + 2] * t;
          final fx = segDir[k * 3] * dirSign;
          final fy = segDir[k * 3 + 1] * dirSign;
          final fz = segDir[k * 3 + 2] * dirSign;
          // Up is radial on the body: the point in the body's frame.
          var ux = px + into.anchorBF.x,
              uy = py + into.anchorBF.y,
              uz = pz + into.anchorBF.z;
          final ul = math.sqrt(ux * ux + uy * uy + uz * uz);
          if (ul == 0) {
            ux = 0;
            uy = 0;
            uz = 0;
          } else {
            final inv = 1.0 / ul;
            ux *= inv;
            uy *= inv;
            uz *= inv;
          }
          // side = fwd × up, normalised.
          var sx = fy * uz - fz * uy, sy = fz * ux - fx * uz, sz = fx * uy - fy * ux;
          final sl = math.sqrt(sx * sx + sy * sy + sz * sz);
          if (sl == 0) {
            sx = 0;
            sy = 0;
            sz = 0;
          } else {
            final inv = 1.0 / sl;
            sx *= inv;
            sy *= inv;
            sz *= inv;
          }
          // In its lane, to the right of the centreline in its own
          // direction of travel — and on the DECK of an elevated road or a
          // bridge rather than the ground the columns stand on.
          final lift =
              roadClass.deckHeightM + SprawlPlan.bridgeLiftAt(d, ranges);
          final ox = sx * laneOffset + ux * lift;
          final oy = sy * laneOffset + uy * lift;
          final oz = sz * laneOffset + uz * lift;
          // Model space is +Y forward, +Z up, so the instance rotation is
          // the basis (side, forward, up) expressed as a quaternion.
          writePose(into.vehicle(kind), px + ox, py + oy, pz + oz, sx, sy, sz,
              fx, fy, fz, ux, uy, uz);
          placed++;
        }
      }
    }
    return placed;
  }

  /// A cheap integer scramble, so two vehicles from adjacent indices do not
  /// come out the same model at the same offset.
  static int hash(int x) {
    var h = x & 0x7FFFFFFF;
    h = (h ^ (h >> 15)) * 0x2C1B3C6D & 0x7FFFFFFF;
    h = (h ^ (h >> 12)) * 0x297A2D39 & 0x7FFFFFFF;
    return h ^ (h >> 15);
  }

  static final vm.Vector3 _t = vm.Vector3.zero();
  static final vm.Quaternion _q = vm.Quaternion.identity();

  /// Write the instance matrix for a model centred at (cx, cy, cz)
  /// anchor-relative metres with basis (side, forward, up) into [m] — the
  /// same matrix `Matrix4.compose(scene(centre), quatToScene(
  /// Quaternion.fromBasis(side, forward, up)), 1)` builds, without building
  /// it: the basis to quaternion here is that factory's arithmetic in
  /// scalars, and the unit scale it applied is a multiplication by one.
  ///
  /// UNIT scale: the vehicle meshes already build their vertices in scene
  /// units, unlike the building library which works in metres. Applying
  /// the metres-to-scene factor again here made every vehicle a thousand
  /// times too small.
  static void writePose(
      vm.Matrix4 m,
      double cx,
      double cy,
      double cz,
      double sx,
      double sy,
      double sz,
      double fx,
      double fy,
      double fz,
      double ux,
      double uy,
      double uz) {
    final m00 = sx, m10 = sy, m20 = sz;
    final m01 = fx, m11 = fy, m21 = fz;
    final m02 = ux, m12 = uy, m22 = uz;
    final trace = m00 + m11 + m22;
    double qw, qx, qy, qz;
    if (trace > 0) {
      final s = math.sqrt(trace + 1.0) * 2;
      qw = 0.25 * s;
      qx = (m21 - m12) / s;
      qy = (m02 - m20) / s;
      qz = (m10 - m01) / s;
    } else if (m00 > m11 && m00 > m22) {
      final s = math.sqrt(1.0 + m00 - m11 - m22) * 2;
      qw = (m21 - m12) / s;
      qx = 0.25 * s;
      qy = (m01 + m10) / s;
      qz = (m02 + m20) / s;
    } else if (m11 > m22) {
      final s = math.sqrt(1.0 + m11 - m00 - m22) * 2;
      qw = (m02 - m20) / s;
      qx = (m01 + m10) / s;
      qy = 0.25 * s;
      qz = (m12 + m21) / s;
    } else {
      final s = math.sqrt(1.0 + m22 - m00 - m11) * 2;
      qw = (m10 - m01) / s;
      qx = (m02 + m20) / s;
      qy = (m12 + m21) / s;
      qz = 0.25 * s;
    }
    final ql = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz);
    if (ql == 0) {
      qw = 1;
      qx = 0;
      qy = 0;
      qz = 0;
    } else {
      final inv = 1.0 / ql;
      qw *= inv;
      qx *= inv;
      qy *= inv;
      qz *= inv;
    }
    _q.setValues(qx, qy, qz, qw);
    _t.setValues(lengthToScene(cx), lengthToScene(cy), lengthToScene(cz));
    m.setFromTranslationRotation(_t, _q);
  }

  /// The pose of one rail or train car from its frame vectors.
  static void writeCarPose(
          vm.Matrix4 m, Vector3 centre, Vector3 side, Vector3 along, Vector3 up) =>
      writePose(m, centre.x, centre.y, centre.z, side.x, side.y, side.z,
          along.x, along.y, along.z, up.x, up.y, up.z);
}

/// One piece of elevated rail: the L's train runs it.
class TrafficTrainPiece {
  const TrafficTrainPiece(this.pts, this.total, this.seed, this.ax, this.ay,
      this.az, this.bx, this.by, this.bz);

  /// Anchor-relative.
  final List<Vector3> pts;
  final double total;
  final int seed;

  /// Its ends, body-fixed, for the range gate.
  final double ax, ay, az, bx, by, bz;

  double nearestEndTo(Vector3 focus) {
    final dax = ax - focus.x, day = ay - focus.y, daz = az - focus.z;
    final dbx = bx - focus.x, dby = by - focus.y, dbz = bz - focus.z;
    return math.min(math.sqrt(dax * dax + day * day + daz * daz),
        math.sqrt(dbx * dbx + dby * dby + dbz * dbz));
  }
}

/// One tile's roads as the traffic pass sees them, sorted by what runs on
/// them: cars, the L, the railway. Built once per tile structure key.
class TrafficTile {
  TrafficTile._(this.structureKey, this.bodyId, this.anchorBF, this.density,
      this.roads, this.trains, this.rail);

  final String structureKey;
  final String bodyId;

  /// The anchor every point is relative to: the body root's, which is
  /// fixed for the root's life. The pass used to anchor on the first road
  /// point of whatever tile came first in range, which moved with the
  /// camera — and a table built against an anchor that moves is stale the
  /// moment it does.
  final Vector3 anchorBF;

  /// The [CityTraffic.density] the tables were built at.
  final double density;
  final List<TrafficRoad> roads;
  final List<TrafficTrainPiece> trains;

  /// Ground railway pieces, anchor-relative; chained per body.
  final List<List<Vector3>> rail;

  /// Whether this frame visited the tile (see [CityTraffic.end]).
  bool touched = false;

  /// Parse [roads] once: every piece into the list its class runs on, or
  /// dropped if nothing could run on it.
  static TrafficTile build(
    String structureKey,
    String bodyId,
    Vector3 anchorBF,
    List<RoadSnapshot> roads, {
    required double density,
  }) {
    final cars = <TrafficRoad>[];
    final trains = <TrafficTrainPiece>[];
    final rail = <List<Vector3>>[];
    for (final r in roads) {
      if (r.points.length < 6) continue;
      final cls = RoadClass
          .values[r.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
      final n = r.points.length ~/ 3;
      final pts = Float64List(n * 3);
      for (var i = 0; i < n; i++) {
        pts[i * 3] = r.points[i * 3] - anchorBF.x;
        pts[i * 3 + 1] = r.points[i * 3 + 1] - anchorBF.y;
        pts[i * 3 + 2] = r.points[i * 3 + 2] - anchorBF.z;
      }
      // Cumulative length, so a vehicle can be placed at a distance rather
      // than at a vertex — otherwise they would snap between samples.
      final seg = Float64List((n - 1) * 3);
      final segDir = Float64List((n - 1) * 3);
      final cum = Float64List(n);
      for (var i = 1; i < n; i++) {
        final s = i - 1;
        final sx = pts[i * 3] - pts[s * 3];
        final sy = pts[i * 3 + 1] - pts[s * 3 + 1];
        final sz = pts[i * 3 + 2] - pts[s * 3 + 2];
        seg[s * 3] = sx;
        seg[s * 3 + 1] = sy;
        seg[s * 3 + 2] = sz;
        final len = math.sqrt(sx * sx + sy * sy + sz * sz);
        cum[i] = cum[s] + len;
        if (len != 0) {
          final inv = 1.0 / len;
          segDir[s * 3] = sx * inv;
          segDir[s * 3 + 1] = sy * inv;
          segDir[s * 3 + 2] = sz * inv;
        }
      }
      final total = cum[n - 1];
      if (total < 30) continue;
      final ax = r.points[0], ay = r.points[1], az = r.points[2];
      final bx = r.points[3 * n - 3],
          by = r.points[3 * n - 2],
          bz = r.points[3 * n - 1];

      if (cls == RoadClass.rail) {
        rail.add([
          for (var i = 0; i < n; i++)
            Vector3(pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2]),
        ]);
        continue;
      }
      // Elevated rail carries the L's train, not cars: one canonical car,
      // instanced at each pose, on the same convention as the road vehicles
      // (model +X across, +Y along, +Z up; vertices in scene units).
      if (!cls.carriesCars) {
        trains.add(TrafficTrainPiece(
          [
            for (var i = 0; i < n; i++)
              Vector3(pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2]),
          ],
          total,
          r.points.length,
          ax, ay, az, bx, by, bz,
        ));
        continue;
      }
      final (spacingM, speed) = TrafficRoad.spacingAndSpeed(cls);
      if (spacingM <= 0) continue;
      final perLane = (total / spacingM * density).floor();
      if (perLane <= 0) continue;
      final family = r.sealed ? VehicleKind.airless : VehicleKind.road;
      final seed = r.points.length * 2654435761 + bodyId.hashCode;
      // A piece that tapers is driven at its narrower width, so nothing
      // runs in the lane that is dropped along it.
      var narrow = r.halfWidthM;
      for (final w in [r.startHalfWidthM, r.endHalfWidthM]) {
        if (w != null && w < narrow) narrow = w;
      }
      // Where the lanes are. A road with no layout — there is none — gets
      // one stream each way, half way out to the curb.
      final layout = cls.lanes;
      final laneScale = layout == null ? 1.0 : r.halfWidthM / layout.halfWidthM;
      // Only the lanes that run the piece's whole length.
      final drivable = narrow - (layout?.shoulderM ?? 0) * laneScale;
      final laneOffsets = Float64List.fromList([
        for (final o in layout?.laneOffsets ?? [r.halfWidthM * 0.5])
          if (o.abs() * laneScale + 1.0 <= drivable) o * laneScale
      ]);
      final ranges = <(double, double)>[
        for (var i = 0; i + 1 < r.bridges.length; i += 2)
          (r.bridges[i], r.bridges[i + 1]),
      ];
      cars.add(TrafficRoad._(
        pts: pts,
        seg: seg,
        segDir: segDir,
        cum: cum,
        total: total,
        roadClass: cls,
        perLane: perLane,
        speed: speed,
        family: family,
        seed: seed,
        laneOffsetsM: laneOffsets,
        oneWay: layout?.oneWay ?? false,
        ranges: ranges,
        ax: ax, ay: ay, az: az, bx: bx, by: by, bz: bz,
      ));
    }
    return TrafficTile._(
        structureKey, bodyId, anchorBF, density, cars, trains, rail);
  }
}

/// One scheduled working on one chained line.
class _RailRun {
  const _RailRun(this.consist, this.stopsM, this.phaseS, this.moving,
      this.parkedAtM);
  final RailConsist consist;
  final List<double> stopsM;
  final double phaseS;
  final bool moving;
  final double parkedAtM;
}

/// A chained railway line with its timetable worked out.
class _RailLine {
  const _RailLine(this.pts, this.cum, this.runs);
  final List<Vector3> pts;
  final List<double> cum;
  final List<_RailRun> runs;
}

/// Where one body's vehicles go this frame: the pose buffers the resident
/// draws read, plus what the body's pass caches between frames.
class TrafficSink {
  TrafficSink(this.bodyId);
  final String bodyId;

  /// The anchor the poses are relative to — the tables' (see
  /// [TrafficTile.anchorBF]).
  Vector3 anchorBF = Vector3.zero;

  final Map<VehicleKind, TrafficBuffer> byKind = {};
  final Map<RailCarKind, TrafficBuffer> railCars = {};
  final TrafficBuffer trainCars = TrafficBuffer();

  /// Road vehicles placed this frame, against [CityTraffic.maxVehicles].
  int placed = 0;
  int _cap = 0;

  /// Whether the road-vehicle cap is spent. Trains and rail pieces are not
  /// counted: they are placed from their own lists, so a train no longer
  /// appears or disappears with the tile order the cap happened to fall in.
  bool get full => placed >= _cap;

  vm.Matrix4 vehicle(VehicleKind kind) {
    placed++;
    return (byKind[kind] ??= TrafficBuffer()).next();
  }

  /// Visited by a tile this frame.
  bool touched = false;

  /// Structure signature the stop list was built for, and the stops: every
  /// station and freight yard on the body, anchor-relative, from ONE scan
  /// of the buildings — not one per frame per body.
  String _stopsSig = '';
  List<(String, Vector3)> _stops = const [];

  /// The in-range rail tiles, in visit order, the chains were built from,
  /// and the lines. The chaining is greedy over the pieces in that order,
  /// so the key is the order, not the set, to keep the output the same.
  String _chainKey = '';
  List<_RailLine> _lines = const [];

  /// Tiles visited this frame, in visit order — the caller's tile order,
  /// which is the frame's, so the cap falls on the same roads for every
  /// client at the same focus. Placing from this pass's own table map
  /// would order them by when each tile FIRST came into range, which is
  /// a camera history no other client shares.
  final List<TrafficTile> _visitedTiles = [];

  /// The visited tiles holding rail, and their keys, in visit order.
  final List<String> _railTileKeys = [];
  final List<TrafficTile> _railTiles = [];

  void _reset(int cap) {
    for (final b in byKind.values) {
      b.reset();
    }
    for (final b in railCars.values) {
      b.reset();
    }
    trainCars.reset();
    placed = 0;
    _cap = cap;
    touched = false;
    _visitedTiles.clear();
    _railTileKeys.clear();
    _railTiles.clear();
  }
}

/// The traffic pass: per-tile road tables, per-body caches, and the per-
/// frame placement into pose buffers. `CityNodes` owns one, feeds it the
/// tiles within range each frame, and draws what its sinks hold.
class CityTraffic {
  /// Scales how many vehicles a road carries. A hook for the colony's own
  /// congestion once that reaches the frame; 1.0 is an ordinary working day.
  double density = 1.0;

  /// Hard ceiling on ROAD vehicles per frame per body, spent in tile
  /// order — nearest tiles are visited first only if the caller visits
  /// them so; the cap is what keeps the buffer bounded either way.
  int maxVehicles = 600;

  /// Roads whose nearer end is further than this from the focus carry no
  /// vehicles: a car six kilometres away is under a pixel. Rail pieces
  /// are kept regardless — a train is a long thing on a long line, and
  /// the chains want every piece of a line the tiles in range hold.
  double rangeM = 3500;

  final Map<String, TrafficTile> _tiles = {};
  final Map<String, TrafficSink> _bodies = {};

  /// Bodies visited this frame, in visit order.
  final List<String> _visited = [];

  String _structureSig = '';
  bool _pruneAfterFrame = false;

  /// The tile tables held, for the panel and the tests.
  int get tileCount => _tiles.length;

  /// Bodies at least one in-range tile belongs to, this frame.
  Iterable<String> get visitedBodies => _visited;

  TrafficSink? sinkOf(String bodyId) => _bodies[bodyId];

  /// Start a frame. [structureSig] is the colony's structure signature:
  /// when it changes the per-body caches are dropped, and tile tables that
  /// go unvisited this frame with it, since the tiles were re-cut.
  void begin(String structureSig) {
    if (structureSig != _structureSig) {
      _structureSig = structureSig;
      _pruneAfterFrame = true;
      for (final sink in _bodies.values) {
        sink._stopsSig = '';
        sink._chainKey = '';
        sink._lines = const [];
      }
    }
    _visited.clear();
    for (final sink in _bodies.values) {
      sink._reset(maxVehicles);
    }
  }

  /// One tile within range: its table is built now if it has none for
  /// [structureKey] against [anchorBF] at [density], and its rail pieces
  /// are noted for the body's chaining.
  void visitTile(String tileKey, String structureKey, String bodyId,
      List<RoadSnapshot> roads, Vector3 anchorBF) {
    var tile = _tiles[tileKey];
    if (tile == null ||
        tile.structureKey != structureKey ||
        tile.anchorBF != anchorBF ||
        tile.density != density ||
        tile.bodyId != bodyId) {
      tile = _tiles[tileKey] = TrafficTile.build(
          structureKey, bodyId, anchorBF, roads,
          density: density);
    }
    tile.touched = true;
    // A sink made mid-frame starts with this frame's cap, like the ones
    // [begin] reset.
    final sink = _bodies.putIfAbsent(
        bodyId, () => TrafficSink(bodyId).._reset(maxVehicles));
    if (!sink.touched) {
      sink.touched = true;
      sink.anchorBF = anchorBF;
      _visited.add(bodyId);
    }
    sink._visitedTiles.add(tile);
    if (tile.rail.isNotEmpty) {
      sink._railTileKeys.add(tileKey);
      sink._railTiles.add(tile);
    }
  }

  /// Place one visited body's vehicles for this frame at [epochS], with
  /// the focus at [focusBF] in the body's frame. [buildings] is scanned
  /// only when the stop list is stale.
  TrafficSink place(String bodyId, double epochS, Vector3 focusBF,
      Map<String, BuildingSnapshot> buildings) {
    final sink = _bodies[bodyId]!;
    final anchorBF = sink.anchorBF;
    // Road vehicles and the L, tile by tile in visit order, gated per
    // piece on its nearer end. The gate is on the precomputed body-fixed
    // ends, so an out-of-range road costs two subtractions.
    for (final tile in sink._visitedTiles) {
      for (final road in tile.roads) {
        if (sink.full) break;
        if (road.nearestEndTo(focusBF) > rangeM) continue;
        road.place(epochS, sink);
      }
      for (final piece in tile.trains) {
        if (piece.nearestEndTo(focusBF) > rangeM) continue;
        for (final car in ElevatedStructure.trainCarPoses(
          pts: piece.pts,
          anchorBF: anchorBF,
          lengthM: piece.total,
          epochS: epochS,
          seed: piece.seed,
        )) {
          TrafficRoad.writeCarPose(
              sink.trainCars.next(), car.centre, car.side, car.along, car.up);
        }
      }
    }
    // The railway's trains: a passenger shuttle calling at the stations
    // and a freight working calling at the yard, on every line long
    // enough to hold one; a short line with no stops is a siding, and a
    // freight rake stands on it.
    if (sink._railTiles.isNotEmpty) {
      final chainKey = sink._railTileKeys.join(',');
      if (chainKey != sink._chainKey) {
        sink._chainKey = chainKey;
        sink._lines = _chain(sink, buildings);
      }
      for (final line in sink._lines) {
        for (final run in line.runs) {
          _placeConsist(sink, line, run, epochS);
        }
      }
    }
    return sink;
  }

  /// End the frame: tables and sinks nothing visited after a structure
  /// change are dropped — their tiles were re-cut, or their body is out of
  /// the frame.
  void end() {
    if (_pruneAfterFrame) {
      _pruneAfterFrame = false;
      _tiles.removeWhere((_, t) => !t.touched);
      _bodies.removeWhere((_, s) => !s.touched);
    }
    for (final t in _tiles.values) {
      t.touched = false;
    }
  }

  /// Forget everything.
  void drop() {
    _tiles.clear();
    _bodies.clear();
    _visited.clear();
    _structureSig = '';
    _pruneAfterFrame = false;
  }

  /// Stitch the body's in-range rail pieces into lines and schedule each.
  List<_RailLine> _chain(
      TrafficSink sink, Map<String, BuildingSnapshot> buildings) {
    if (sink._stopsSig != _structureSig) {
      sink._stopsSig = _structureSig;
      sink._stops = [
        for (final b in buildings.values)
          if (b.body == sink.bodyId &&
              (b.type == 'station' || b.type == 'freightyard'))
            (b.type, Vector3(b.px, b.py, b.pz) - sink.anchorBF),
      ];
    }
    final segments = <List<Vector3>>[
      for (final tile in sink._railTiles) ...tile.rail,
    ];
    final out = <_RailLine>[];
    var line = 0;
    for (final chain in Railway.chains(segments)) {
      final cum = RailConsist.cumulative(chain);
      if (cum.last < 200) continue;
      final stationsM = <double>[];
      final yardsM = <double>[];
      for (final (type, at) in sink._stops) {
        final n = RailConsist.nearestOn(chain, cum, at);
        if (n.offM > 160) continue;
        (type == 'station' ? stationsM : yardsM).add(n.alongM);
      }
      final phase = ((line++ * 977 + sink.bodyId.hashCode) % 1000).toDouble();
      final siding = cum.last < 900 && stationsM.isEmpty && yardsM.isEmpty;
      final parkedAtM = cum.last / 2 + RailConsist.freight.lengthM / 2;
      final runs = siding
          ? [_RailRun(RailConsist.freight, const [], 0.0, false, parkedAtM)]
          : [
              _RailRun(RailConsist.passenger, stationsM, phase, true,
                  cum.last / 2 + RailConsist.passenger.lengthM / 2),
              _RailRun(
                  RailConsist.freight,
                  yardsM,
                  phase + cum.last / RailConsist.freight.speedMs,
                  true,
                  parkedAtM),
            ];
      out.add(_RailLine(chain, cum, runs));
    }
    return out;
  }

  /// [RailConsist.posesAt] over the line's cached cumulative length,
  /// written straight into the sink: the head leads in the direction of
  /// travel and the rest trail behind it, each centred on its own slot;
  /// cars that would hang off the start of the line before the train has
  /// fully entered are simply not drawn. Same arithmetic, so the poses
  /// equal what `posesAt` returns — the tests hold it to that.
  void _placeConsist(
      TrafficSink sink, _RailLine line, _RailRun run, double epochS) {
    final pts = line.pts, cum = line.cum;
    if (pts.length < 2) return;
    final consist = run.consist;
    final lineM = cum.last;
    final lengthM = consist.lengthM;
    if (lineM < lengthM + 10) return;
    final double head;
    final double dir;
    if (run.moving) {
      final h = consist.headAt(
          lineM: lineM, stopsM: run.stopsM, epochS: epochS, phaseS: run.phaseS);
      head = h.headM;
      dir = h.direction;
    } else {
      head = run.parkedAtM.clamp(lengthM, lineM);
      dir = 1;
    }
    var offset = 0.0;
    for (final kind in consist.cars) {
      final s = head - dir * (offset + kind.lengthM / 2);
      offset += kind.lengthM + RailConsist.couplingM;
      if (s < 0 || s > lineM) continue;
      final at = RailConsist.pointAt(pts, cum, s);
      final ahead = RailConsist.pointAt(pts, cum, (s + 2.0).clamp(0.0, lineM));
      final behind = RailConsist.pointAt(pts, cum, (s - 2.0).clamp(0.0, lineM));
      final d = ahead - behind;
      if (d.length < 1e-6) continue;
      final along = d.normalized * dir;
      final up = (at + sink.anchorBF).normalized;
      final side = along.cross(up).normalized;
      TrafficRoad.writeCarPose(
          (sink.railCars[kind] ??= TrafficBuffer()).next(),
          at + up * RailVehicleMeshes.railHeadM,
          side,
          along,
          up);
    }
  }
}
