// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The route inspector's side of the agents (docs/plans/agent-traffic.md
/// §13.9, §18 slice 2): which vehicle is under a click, what the inspector
/// says about it, and the road it still has to drive.
///
/// The words come from ONE place, [CityAgents.describe], which is also what
/// the `vehicle=` dev hook returns. [VehicleInspection] is only a reading of
/// that map — built from the live map or from the hook's JSON, it says the
/// same thing — so the sheet a player opens and the dump a driver script
/// reads can never disagree about a car.
///
/// The pick reads the frame the agents last published ([CityAgents.frame]),
/// which is what the renderer draws the cars from, and places each vehicle
/// on the lane graph the frame was cut against. It is asked from the pick
/// layer's hit test, so it allocates nothing once a graph's element boxes
/// are built, and rejects nearly every vehicle on a box compare.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import 'city_agents.dart';
import 'lane_connectors.dart' show kConnectorPoints;
import 'lane_graph.dart';
import 'route_cost.dart';
import 'slot_pool.dart';

/// What the inspector shows for one vehicle: a reading of the map
/// [CityAgents.describe] returned for it.
class VehicleInspection {
  VehicleInspection._(this.describe, this.remainingRoads);

  /// [handle]'s inspection, or null for a handle no longer on the road.
  /// [roadName] turns a road id into what the player calls it (the colony's
  /// `roadNameOf`); without it the ids stand.
  static VehicleInspection? of(CityAgents agents, int handle,
          {String Function(String roadId)? roadName}) =>
      fromDescribe(agents.describe(handle), roadName: roadName);

  /// The inspection of a [CityAgents.describe] map — the map itself, or the
  /// `vehicle=` hook's JSON of it read back — or null for none.
  static VehicleInspection? fromDescribe(Map<String, Object?>? d,
      {String Function(String roadId)? roadName}) {
    if (d == null) return null;
    final roads = <String>[];
    final route = d['route'];
    if (route is List) {
      for (final step in route) {
        if (step is! Map) continue;
        final id = step['road'];
        if (id is! String) continue;
        final name = roadName == null ? id : roadName(id);
        // One entry per stretch of road: a route runs a road's pieces one
        // after another, junction by junction — a split road's pieces
        // under one name — and "Main St, Main St, Main St" says nothing
        // the first one did not.
        if (roads.isNotEmpty && roads.last == name) continue;
        roads.add(name);
      }
    }
    return VehicleInspection._(d, roads);
  }

  /// The map it reads, exactly as [CityAgents.describe] returned it.
  final Map<String, Object?> describe;

  /// The roads still ahead, in order, the one it is on first; one entry per
  /// stretch.
  final List<String> remainingRoads;

  int get handle => _int(describe['handle']);
  String get kind => describe['kind'] as String? ?? '?';
  String get state => describe['state'] as String? ?? '?';
  String get purpose => describe['purpose'] as String? ?? '?';

  /// The sites it drives from and to; null where it has none (a forced
  /// trip's building gone, a service vehicle between calls).
  String? get from => describe['from'] as String?;
  String? get to => describe['to'] as String?;

  /// Metres a second, as last sampled.
  double get speedMps => _double(describe['v']);

  /// Seconds on the road, and what the trip would take in free flow.
  double get tripS => _double(describe['tripS']);
  double get freeFlowS => _double(describe['freeFlowS']);

  /// Seconds it has stood still where it should have moved.
  double get stuckS => _double(describe['stuckS']);

  /// The inspector's lines, top to bottom: what it is, where from and to,
  /// what it is doing and how fast, how its trip is going, and the roads
  /// ahead.
  List<String> get lines => [
        '${words(kind)} #$handle · ${words(purpose)}',
        '${from ?? 'nowhere'} → ${to ?? 'nowhere'}',
        '${words(state)} · ${(speedMps * 3.6).round()} km/h',
        'Trip ${tripS.round()} s · free flow ${freeFlowS.round()} s'
            '${stuckS >= 1 ? ' · stuck ${stuckS.round()} s' : ''}',
        remainingRoads.isEmpty
            ? 'No road ahead'
            : 'Ahead: ${remainingRoads.join(' → ')}',
      ];

  String get text => lines.join('\n');

  /// An enum name as words: `garbageTruck` → `garbage truck`,
  /// `holdAtEdgeEnd` → `hold at edge end`; the first letter capitalised.
  static String words(String name) {
    final spaced = name.replaceAllMapped(
        RegExp('[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}');
    return spaced.isEmpty
        ? spaced
        : '${spaced[0].toUpperCase()}${spaced.substring(1)}';
  }

  // A JSON round trip reads a whole double back as an int, and an int the
  // map held stays one.
  static int _int(Object? v) => v is num ? v.toInt() : -1;
  static double _double(Object? v) => v is num ? v.toDouble() : 0.0;
}

/// Finds the vehicle under a point, and lays out a vehicle's road ahead.
///
/// One per view: it keeps a box per lane-graph element for the graph it was
/// last asked about, rebuilt when the agents' graph object changes (a road
/// laid, a junction overridden), never per call.
class VehiclePicker {
  LaneGraph? _boxesOf;

  /// Per edge, then per connector: east min, north min, east max, north max.
  Float32List _edgeBox = Float32List(0), _conBox = Float32List(0);

  final Float64List _pt = Float64List(4);

  /// How far past an edge's centreline its lanes may lie, metres: the widest
  /// road's outer lane, and a car's half length over it.
  static const double _boxMarginM = 16;

  /// The handle of the vehicle nearest [p] (colony-local metres) within
  /// [radiusM] in the frame [agents] last published, or −1 for none —
  /// agents off, no vehicle there, or a frame cut against a lane graph that
  /// has since been replaced.
  int pick(CityAgents agents, Vec2 p, {double radiusM = 4}) {
    if (!agents.enabled || agents.liveVehicles == 0) return -1;
    final lg = agents.laneGraph;
    final f = agents.frame;
    if (lg == null || f.count == 0 || f.graphRev != agents.graphRev) return -1;
    _boxes(lg);
    final nL = lg.laneCount;
    final eb = _edgeBox, cb = _conBox;
    final pe = p.e, pn = p.n;
    var best = -1;
    var bestD2 = radiusM * radiusM;
    for (var row = 0; row < f.count; row++) {
      final h = f.handle[row], el = f.elem[row];
      if (h < 0 || el < 0 || el >= lg.elementCount) continue;
      final Float32List box;
      final int b;
      if (el < nL) {
        box = eb;
        b = 4 * lg.laneEdge[el];
      } else {
        box = cb;
        b = 4 * (el - nL);
      }
      if (pe < box[b] - radiusM ||
          pn < box[b + 1] - radiusM ||
          pe > box[b + 2] + radiusM ||
          pn > box[b + 3] + radiusM) {
        continue;
      }
      if (!positionOn(lg, el, f.s[row], _pt)) continue;
      final de = _pt[0] - pe, dn = _pt[1] - pn;
      final d2 = de * de + dn * dn;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = h;
      }
    }
    return best;
  }

  /// Where on [lg] a vehicle [s] metres along element [elem] stands: east
  /// into `out[0]`, north into `out[1]` (colony-local metres; `out[2..3]`
  /// are scratch). A lane is measured from its stop bar behind, a
  /// connector along its path. False for no such element. No allocation.
  static bool positionOn(LaneGraph lg, int elem, double s, Float64List out) {
    final nL = lg.laneCount;
    if (elem < 0 || elem >= lg.elementCount) return false;
    if (elem < nL) {
      final e = lg.laneEdge[elem];
      if (e >= lg.roadEdgeCount) return false;
      final s0 = lg.edgeLaneS0[e].toDouble(), s1 = lg.edgeLaneS1[e].toDouble();
      final t = (s0 + s).clamp(s0, math.max(s0, s1)).toDouble();
      // The heading a quarter metre on, or back where that runs off the
      // edge: the lane's offset lies to the right of it.
      final ahead = t + 0.25 <= lg.edgeLen[e];
      RouteCost.pointOn(lg, e, ahead ? t + 0.25 : t - 0.25, out, 2);
      final ae = out[2], an = out[3];
      RouteCost.pointOn(lg, e, t, out, 0);
      var de = ae - out[0], dn = an - out[1];
      if (!ahead) {
        de = -de;
        dn = -dn;
      }
      final l = math.sqrt(de * de + dn * dn);
      if (l >= 1e-9) {
        final off = lg.laneOff[elem].toDouble();
        out[0] += dn / l * off;
        out[1] -= de / l * off;
      }
      return true;
    }
    final c = elem - nL;
    const k = kConnectorPoints;
    final len = lg.conLen[c].toDouble();
    final u = len > 0 ? (s / len).clamp(0.0, 1.0) * (k - 1) : 0.0;
    final i = math.min(k - 2, u.floor());
    final w = u - i;
    final at = 2 * (k * c + i);
    final pts = lg.conPts;
    out[0] = pts[at] + (pts[at + 2] - pts[at]) * w;
    out[1] = pts[at + 1] + (pts[at + 3] - pts[at + 1]) * w;
    return true;
  }

  /// [handle]'s road ahead as one line, colony-local: the lane it is on
  /// from its stop bar, then each connector and lane it has still to take.
  /// Empty for a handle no longer on the road. Allocates: for a view to
  /// call once when it opens an inspector, not per frame.
  static List<Vec2> routeAhead(CityAgents agents, int handle,
      {double stepM = 8}) {
    final t = agents.vehicles, lg = agents.laneGraph;
    if (t == null || lg == null || !t.isLive(handle)) return const [];
    final sl = SlotPool.slotOf(handle);
    final out = <Vec2>[];
    final speeds = agents.laneSpeeds;
    for (var i = t.routeCur[sl]; i < t.routeLen[sl]; i++) {
      if (i > t.routeCur[sl]) {
        final c = t.connectorOfRouteEdge(sl, i);
        if (c >= 0 && c < lg.connectorCount) {
          for (var k = 0; k < kConnectorPoints; k++) {
            final at = 2 * (kConnectorPoints * c + k);
            out.add(Vec2(lg.conPts[at].toDouble(), lg.conPts[at + 1].toDouble()));
          }
        }
      }
      out.addAll(speeds.laneLine(t.laneOfRouteEdge(sl, i), stepM: stepM));
    }
    return out;
  }

  /// Boxes for [lg]'s edges and connectors, built once per graph object.
  void _boxes(LaneGraph lg) {
    if (identical(lg, _boxesOf)) return;
    _boxesOf = lg;
    final nE = lg.roadEdgeCount, nC = lg.connectorCount;
    _edgeBox = Float32List(4 * lg.edgeCount);
    for (var e = 0; e < lg.edgeCount; e++) {
      _empty(_edgeBox, 4 * e);
    }
    for (var e = 0; e < nE; e++) {
      final len = lg.edgeLen[e];
      final n = math.max(1, (len / 10).ceil());
      for (var j = 0; j <= n; j++) {
        RouteCost.pointOn(lg, e, len * j / n, _pt, 0);
        _grow(_edgeBox, 4 * e, _pt[0], _pt[1], _boxMarginM);
      }
    }
    _conBox = Float32List(4 * nC);
    for (var c = 0; c < nC; c++) {
      _empty(_conBox, 4 * c);
      for (var k = 0; k < kConnectorPoints; k++) {
        final at = 2 * (kConnectorPoints * c + k);
        _grow(_conBox, 4 * c, lg.conPts[at].toDouble(),
            lg.conPts[at + 1].toDouble(), 3);
      }
    }
  }

  static void _empty(Float32List box, int b) {
    box[b] = double.infinity;
    box[b + 1] = double.infinity;
    box[b + 2] = -double.infinity;
    box[b + 3] = -double.infinity;
  }

  static void _grow(Float32List box, int b, double e, double n, double m) {
    if (e - m < box[b]) box[b] = e - m;
    if (n - m < box[b + 1]) box[b + 1] = n - m;
    if (e + m > box[b + 2]) box[b + 2] = e + m;
    if (n + m > box[b + 3]) box[b + 3] = n + m;
  }
}
