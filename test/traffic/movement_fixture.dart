// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the movement tests share (docs/plans/agent-traffic.md §17.1–17.3):
/// a lane graph with vehicles on it — the table, the arbiter and the mover
/// wired the way the facade wires them — new trips planned the way the
/// queue plans them, and the checks every movement test repeats: the lists
/// in order, nothing overlapping, no two crossing movements at once, no
/// lane change but through a connector.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/junction_arbiter.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_connectors.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';

import 'routing_fixture.dart';

/// One pass the arbiter reported: who (and what kind of vehicle), into
/// which connector, why, how far short of the line and how fast, when.
class Commit {
  const Commit(this.handle, this.kind, this.connector, this.reason,
      this.dist, this.speed, this.nowUs);

  final int handle, kind, connector;
  final GrantReason reason;
  final double dist, speed;
  final int nowUs;
}

/// Vehicles driving [lg]: the table, the arbiter and the mover, a clock,
/// and what they reported.
class Drive implements VehicleSink, ArbiterObserver {
  Drive(this.lg, {int capacity = 2048})
      : table = VehicleTable(capacity: capacity) {
    arbiter = JunctionArbiter(table)..observer = this;
    mover = VehicleMover(table, arbiter)..bind(lg);
    cost = RouteCost(lg);
  }

  final LaneGraph lg;
  final VehicleTable table;
  late final JunctionArbiter arbiter;
  late final VehicleMover mover;
  late final RouteCost cost;

  /// Agent time of the last sub-step run.
  int nowUs = 0;

  /// Every pass the arbiter reported, when [logCommits] is set.
  bool logCommits = false;
  final List<Commit> commits = [];

  final List<int> arrivedHandles = [];
  final Map<int, DespawnReason> despawns = {};
  final Map<int, int> despawnUs = {};

  @override
  void arrived(int handle) => arrivedHandles.add(handle);

  @override
  void despawned(int handle, DespawnReason reason) {
    despawns[handle] = reason;
    despawnUs[handle] = nowUs;
  }

  @override
  void committed(
      int slot, int connector, GrantReason reason, double dist, int nowUs) {
    if (!logCommits) return;
    commits.add(Commit(table.handleOf(slot), table.kind[slot], connector,
        reason, dist, table.v[slot].toDouble(), nowUs));
  }

  /// A new trip from travel arc [fromT] of [fromEdge] to [toT] of [toEdge],
  /// planned the way the queue plans one (edge A*, then the lane pass) and
  /// put on the road if there is room to pull out ([checkRoom]). Returns
  /// its handle, or [SlotPool.none].
  int trip(int fromEdge, double fromT, int toEdge, double toT,
      {AgentKind kind = AgentKind.car,
      int destMask = 1,
      double speedFactor = 1.0,
      double speed = 0,
      bool checkRoom = true}) {
    final planned = planTrip(lg, fromEdge, fromT, toEdge, toT,
        destMask: destMask, cost: cost, load: table);
    if (planned == null) return SlotPool.none;
    final route = Int32List.fromList(planned.route);
    final lane = route[0];
    final at = fromT - lg.edgeLaneS0[lg.laneEdge[lane]];
    if (checkRoom &&
        !arbiter.canJoin(lane, at, VehicleKinds.lengthM[kind.index], kind)) {
      return SlotPool.none;
    }
    return table.spawn(
      kind: kind,
      route: route,
      routeLength: route.length,
      originT: fromT,
      destT: toT,
      nowUs: nowUs,
      speedFactor: speedFactor,
      speed: speed,
    );
  }

  /// A random new trip, between two random places of two random edges, by
  /// a car four times in five and a lorry or a semi otherwise.
  int randomTrip(TrafficRng rng) {
    final e1 = _randomEdge(rng), e2 = _randomEdge(rng);
    if (e1 < 0 || e2 < 0) return SlotPool.none;
    final r = rng.nextInt(10);
    final kind = r < 8
        ? AgentKind.car
        : (r == 8 ? AgentKind.truck : AgentKind.semi);
    return trip(e1, _randomT(rng, e1), e2, _randomT(rng, e2),
        kind: kind, speedFactor: VehicleKinds.drawFactor(kind, rng));
  }

  int _randomEdge(TrafficRng rng) {
    for (var tries = 0; tries < 20; tries++) {
      final e = rng.nextInt(lg.roadEdgeCount);
      if (lg.edgeLaneS1[e] - lg.edgeLaneS0[e] > 30) return e;
    }
    return -1;
  }

  /// Somewhere on [e]'s lanes, clear of both ends: a car pulling out right
  /// at a junction's mouth would be cut off by whoever is coming through.
  double _randomT(TrafficRng rng, int e) {
    final lo = lg.edgeLaneS0[e] + 12, hi = lg.edgeLaneS1[e] - 6;
    return lo + (hi - lo) * rng.nextUnit();
  }

  /// Keeps [target] vehicles on the road, spawning at most [perStep] a
  /// sub-step (the design's spawn cap, §5.2, is 24).
  void topUp(TrafficRng rng, int target, {int perStep = 8}) {
    for (var i = 0; i < perStep && table.liveCount < target; i++) {
      randomTrip(rng);
    }
  }

  /// One sub-step.
  void step() {
    nowUs += kStepUs;
    mover.step(nowUs, this);
  }

  /// [seconds] of sub-steps, calling [each] after every one.
  void run(double seconds, [void Function()? each]) {
    final n = (seconds / kStepS).round();
    for (var i = 0; i < n; i++) {
      step();
      each?.call();
    }
  }

  /// The slot of live [handle].
  int slot(int handle) => SlotPool.slotOf(handle);
}

/// One straight [cls] road from the origin east for [lengthM]: a dead end
/// at each end. Its id is `r0`.
LaneGraph straightRoad(
    {double lengthM = 2000, RoadClass cls = RoadClass.street}) {
  final layout = CityLayout()
    ..commitRoad(
        controls: [const Vec2(0, 0), Vec2(lengthM, 0)],
        roadClass: cls,
        regenerateLots: false);
  return lanesOf(layout);
}

/// Two streets crossing at the origin, [halfM] out each way: the starter
/// kit's crossroads, an all-way stop with four dead ends.
LaneGraph crossroads({double halfM = 300}) {
  final layout = CityLayout()
    ..commitRoad(
        controls: [Vec2(-halfM, 0), Vec2(halfM, 0)], regenerateLots: false)
    ..commitRoad(
        controls: [Vec2(0, -halfM), Vec2(0, halfM)], regenerateLots: false);
  return lanesOf(layout);
}

/// A 5 × 5 grid, 220 m apart, of every class a town's roads come in —
/// streets, avenues, a boulevard, one-way streets both ways — so one map
/// holds every control the warrant gives them: lights, all-way stops,
/// the dead ends round the rim.
CityLayout mixedGrid() {
  const vertical = [
    RoadClass.street,
    RoadClass.avenue,
    RoadClass.streetOneWay,
    RoadClass.boulevard,
    RoadClass.street,
  ];
  const horizontal = [
    RoadClass.avenue,
    RoadClass.street,
    RoadClass.streetOneWay,
    RoadClass.street,
    RoadClass.street,
  ];
  const spacing = 220.0;
  const half = 2 * spacing;
  const lo = -half - spacing / 2, hi = half + spacing / 2;
  final layout = CityLayout();
  for (var i = 0; i < 5; i++) {
    final at = -half + i * spacing;
    layout.commitRoad(
        controls: [Vec2(at, lo), Vec2(at, hi)],
        roadClass: vertical[i],
        reversed: vertical[i].oneWay && i.isEven,
        regenerateLots: false);
    layout.commitRoad(
        controls: [Vec2(lo, at), Vec2(hi, at)],
        roadClass: horizontal[i],
        reversed: horizontal[i].oneWay && i.isOdd,
        regenerateLots: false);
  }
  return layout;
}

/// Where a vehicle's front is, [s] metres along element [elem] of [lg]
/// (colony-local east, north): on a lane, the lane's own line — its road's
/// line at the travel arc, `laneOff` to the right of travel; on a connector,
/// its path, [kConnectorPoints] points, walked [s] metres along. Where the
/// renderer draws it, so a place kept across a rebuild is one on screen.
Vec2 elementPoint(LaneGraph lg, int elem, double s) {
  if (elem < lg.laneCount) {
    final e = lg.laneEdge[elem];
    final t = lg.edgeLaneS0[e] + s;
    final pt = Float64List(4);
    // The heading from a quarter metre along, back where that runs off the
    // edge.
    final ahead = t + 0.25 <= lg.edgeLen[e];
    RouteCost.pointOn(lg, e, t, pt, 0);
    RouteCost.pointOn(lg, e, ahead ? t + 0.25 : t - 0.25, pt, 2);
    var de = pt[2] - pt[0], dn = pt[3] - pt[1];
    if (!ahead) {
      de = -de;
      dn = -dn;
    }
    final l = math.sqrt(de * de + dn * dn);
    final off = lg.laneOff[elem];
    return l < 1e-9
        ? Vec2(pt[0], pt[1])
        : Vec2(pt[0] + dn / l * off, pt[1] - de / l * off);
  }
  final at = 2 * kConnectorPoints * (elem - lg.laneCount);
  final p = lg.conPts;
  var left = s;
  for (var k = 1; k < kConnectorPoints; k++) {
    final ae = p[at + 2 * k - 2], an = p[at + 2 * k - 1];
    final be = p[at + 2 * k], bn = p[at + 2 * k + 1];
    final seg = math.sqrt((be - ae) * (be - ae) + (bn - an) * (bn - an));
    if (left <= seg || k == kConnectorPoints - 1) {
      final u = seg < 1e-9 ? 0.0 : math.min(1.0, math.max(0.0, left / seg));
      return Vec2(ae + (be - ae) * u, an + (bn - an) * u);
    }
    left -= seg;
  }
  return Vec2(p[at], p[at + 1]);
}

/// Whatever is wrong with the table's lists: a vehicle listed where it is
/// not, out of order, overlapping the one ahead, listed twice or not at all;
/// a head, tail or count that does not match.
List<String> occupancyErrors(VehicleTable t) {
  final errs = <String>[];
  final lg = t.graph;
  final seen = <int>{};
  for (var el = 0; el < lg.elementCount; el++) {
    var n = 0;
    var p = -1;
    for (var sl = t.elemHead[el]; sl >= 0; sl = t.next[sl]) {
      if (!t.isSlotLive(sl)) errs.add('dead slot $sl on element $el');
      if (t.elem[sl] != el) errs.add('slot $sl listed on $el, is on ${t.elem[sl]}');
      if (t.prev[sl] != p) errs.add('slot $sl: prev ${t.prev[sl]}, not $p');
      if (p >= 0) {
        if (t.s[sl] > t.s[p]) errs.add('element $el out of order at $sl');
        final gap = t.s[p] - t.len[p] - t.s[sl];
        if (gap < -1e-3) errs.add('slot $sl overlaps $p on $el by ${-gap} m');
      }
      if (!seen.add(sl)) {
        errs.add('slot $sl listed twice');
        break;
      }
      p = sl;
      n++;
    }
    if (t.elemTail[el] != p) errs.add('element $el: tail ${t.elemTail[el]}, not $p');
    if (t.elemCount[el] != n) errs.add('element $el: count ${t.elemCount[el]}, not $n');
  }
  for (var sl = 0; sl < t.highWater; sl++) {
    // A vehicle inside a site is on no element and on no list, by design
    // (T4a, docs/plans/t4a-implementation.md §1.2): only a vehicle ON the
    // road must be listed.
    if (t.isSlotLive(sl) && t.elem[sl] >= 0 && !seen.contains(sl)) {
      errs.add('slot $sl not listed');
    }
  }
  return errs;
}

/// Where every vehicle's body lies on connectors: per connector, each
/// vehicle on it — its front on it, or its front beyond and its tail still
/// on or behind it — with its tail's place along the connector (metres
/// from its start; below 0 where the tail has not reached it). Computed
/// from positions and routes alone, not from the arbiter's own books.
Map<int, List<(int, double)>> connectorFootprints(Drive d) {
  final t = d.table, lg = d.lg;
  final nL = lg.laneCount;
  final out = <int, List<(int, double)>>{};
  for (var sl = 0; sl < t.highWater; sl++) {
    if (!t.isSlotLive(sl)) continue;
    final len = t.len[sl].toDouble();
    var el = t.elem[sl];
    var i = t.routeCur[sl];
    // Metres from the front back to the start of element el.
    var back = t.s[sl].toDouble();
    while (true) {
      if (el >= nL) {
        (out[el - nL] ??= []).add((sl, back - len));
        if (back >= len) break;
        el = t.laneOfRouteEdge(sl, i - 1);
        i -= 1;
        back += lg.laneLength(el);
      } else {
        if (back >= len || i == 0) break;
        final c = t.connectorOfRouteEdge(sl, i);
        el = nL + c;
        back += lg.conLen[c];
      }
    }
  }
  return out;
}

/// Every pair of vehicles on two connectors that cross, each with its tail
/// short of the crossing point on its own connector: what the arbiter must
/// never allow (§17.2 arbiter safety).
List<String> crossingViolations(Drive d) {
  final lg = d.lg;
  final fp = connectorFootprints(d);
  final bad = <String>[];
  for (final c in fp.keys) {
    final on = fp[c]!;
    for (var j = lg.conConflictStart[c]; j < lg.conConflictStart[c + 1]; j++) {
      final other = fp[lg.conflictWith[j]];
      if (other == null) continue;
      final pc = lg.conflictAtSelf[j], pd = lg.conflictAtOther[j];
      for (final (x, rx) in on) {
        for (final (y, ry) in other) {
          if (x != y && rx < pc - 1e-3 && ry < pd - 1e-3) {
            bad.add('t=${secondsOf(d.nowUs)} s: slot $x on connector $c '
                '(tail ${rx.toStringAsFixed(2)} of crossing at '
                '${pc.toStringAsFixed(2)}) and slot $y on connector '
                '${lg.conflictWith[j]} (tail ${ry.toStringAsFixed(2)} of '
                '${pd.toStringAsFixed(2)})');
          }
        }
      }
    }
  }
  return bad;
}

/// Watches every vehicle's element from one sub-step to the next: a
/// vehicle that changes element must have moved along its own route —
/// lane, its next connector, the lane that connector reaches — at most
/// `maxHandOversPerStep` elements, and never sideways onto another lane of
/// the edge it was on (§5.5, §17.2). A vehicle seen for the first time has
/// just pulled out of an access point.
class LaneWatch {
  final Map<int, (int, int)> _last = {};

  /// The lane each vehicle was last on.
  final Map<int, int> _lane = {};

  /// Element changes seen, and arrivals on a new lane among them.
  int moves = 0, laneChanges = 0;

  List<String> check(Drive d) {
    final t = d.table, lg = d.lg;
    final nL = lg.laneCount;
    final bad = <String>[];
    final now = <int, (int, int)>{};
    final lanes = <int, int>{};
    for (var sl = 0; sl < t.highWater; sl++) {
      if (!t.isSlotLive(sl)) continue;
      final h = t.handleOf(sl);
      final el = t.elem[sl], cur = t.routeCur[sl];
      now[h] = (el, cur);
      final lastLane = _lane[h];
      lanes[h] = el < nL ? el : (lastLane ?? -1);
      final was = _last[h];
      if (was == null) continue;
      final (e0, c0) = was;
      if (e0 == el) continue;
      moves++;
      if (el < nL && lastLane != null && lastLane != el) laneChanges++;
      if (e0 < nL && el < nL && lg.laneEdge[e0] == lg.laneEdge[el]) {
        bad.add('handle $h moved sideways from lane $e0 to lane $el');
        continue;
      }
      var x = e0, i = c0;
      var ok = false;
      for (var k = 0; k < AgentTuning.maxHandOversPerStep; k++) {
        if (x < nL) {
          if (i + 1 >= t.routeLen[sl]) break;
          i++;
          x = nL + t.connectorOfRouteEdge(sl, i);
        } else {
          x = lg.conToLane[x - nL];
        }
        if (x == el && i == cur) {
          ok = true;
          break;
        }
      }
      if (!ok) {
        bad.add('handle $h jumped from element $e0 (route edge $c0) to $el '
            '(route edge $cur) off its route');
      }
    }
    _last
      ..clear()
      ..addAll(now);
    _lane
      ..clear()
      ..addAll(lanes);
    return bad;
  }
}
