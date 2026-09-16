// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How vehicles move (docs/plans/agent-traffic.md §5.1–5.3, §5.5, §5.6):
/// the car-following, the hand-over from one element of a route to the
/// next, and the clocks that decide a vehicle is stuck.
///
/// One [VehicleMover.step] is one 0.2 s sub-step of agent time, in a fixed
/// order (§5.2), so two runs fed the same ticks make the same history:
///
/// 1. Every vehicle moves, element by element in id order and, within an
///    element, from the one furthest along to the last. A follower on the
///    same element sees its leader where the leader has just moved to; a
///    follower looking into ANOTHER element sees that element's tail where
///    it stood when the sub-step began ([VehicleTable.sPre]), so the order
///    the elements are visited in never changes what anyone sees.
/// 2. Hand-overs, in the order the vehicles moved: past the end of its
///    element, a vehicle moves onto the next element of its route and
///    joins the back of it. Onto a connector only with the arbiter's pass.
/// 3. The wedge breaker (§5.8).
/// 4. Arrivals and the stuck timer, in slot order.
///
/// Car-following is the Intelligent Driver Model with the design's
/// ballistic update (§5.3), which is stable at h = 0.2 s and stops exactly
/// inside a step. A vehicle's leader is the car ahead on its own element;
/// else the last car on the next elements of ITS route (at most
/// [kLookAheadElems] elements or [kLookAheadM] metres on); else a virtual
/// standing car at a stop line the arbiter refuses it, at its own stop, at
/// the end of the edge it is held on, or at an obstacle [LaneObstacles]
/// reports in its lane (a home back-out's footprint or claim,
/// site-access.md §7.4). A hard limit on top keeps the
/// front [kLeaderClearM] behind the leader's tail whatever the model says:
/// nothing ever overlaps.
///
/// The lane changes only when the element does, and consecutive elements of
/// a route are always joined by a connector (§5.5): no vehicle ever moves
/// sideways into a sibling lane.
///
/// On the way it keeps the books the measurements are read from: per edge,
/// the distance driven against the limit (the congestion index), the
/// vehicles through, and — for the delay table (edge_delay.dart, §4.2) — a
/// log of delay observations, taken as a vehicle leaves an edge's connector
/// or arrives on it, and per lane the speeds of the vehicles on it.
///
/// Nothing in a step allocates (§15.2): the leader search answers through
/// fields, the hand-over list and the observation log are typed columns,
/// events go to a [VehicleSink].
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'junction_arbiter.dart';
import 'lane_graph.dart';
import 'lane_obstacles.dart';
import 'slot_pool.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';
import 'vehicle_table.dart';

/// Why a vehicle was taken off the road before it arrived. Append-only.
enum DespawnReason {
  /// Stationary past `AgentTuning.stuckDespawnS` (§5.6).
  stuck,

  /// The longest waiter at a wedged node (§5.8).
  wedge,

  /// A network edit took the road from under it (§3.9).
  edit,
}

/// Told what the step did to vehicles, before their slots are freed, so
/// the owner can still read their columns.
abstract interface class VehicleSink {
  /// [handle] reached its stop. It is `leaving`; set it driving again with
  /// a new route — an appended leg — and it stays.
  void arrived(int handle);

  /// [handle] is being taken off the road for [reason].
  void despawned(int handle, DespawnReason reason);
}

/// A vehicle at rest before a stop line or its stop has its front this far
/// short of it.
const double kStopShortM = 0.5;

/// A vehicle whose front is within this of its stop has arrived.
const double kArriveM = 1.0;

/// The least a front ever comes to the tail of the vehicle ahead.
const double kLeaderClearM = 0.1;

/// How short of a stop line a refused front is held, so it never stands on
/// the line itself.
const double kLineClearM = 0.05;

/// How far, and over how many elements, a vehicle looks for its leader.
/// Four elements: a sub-step's travel can cross a short connector, a short
/// lane and another connector, and every line it could cross must have been
/// asked about.
const double kLookAheadM = 150;
const int kLookAheadElems = 4;

/// A vehicle whose tail is still within this of the start of a connector
/// leaving a lane blocks that lane's exit, whichever connector it took.
const double kThroatM = 3.0;

/// Below this speed a driving vehicle is not getting anywhere (§5.6); once
/// it has moved this far since the timer was last reset, it was.
const double kStuckMps = 0.1;
const double kStuckResetM = 1.0;

/// A refused vehicle below this speed is waiting at its line.
const double kWaitingMps = 0.5;

/// The decision distance: braking distance at the comfortable deceleration
/// plus this, and never less than [kDecisionMinM] (§5.4).
const double kDecisionMarginM = 5;
const double kDecisionMinM = 12;

/// The Intelligent Driver Model (§5.3).
class Idm {
  Idm._();

  /// A gap is never taken as less than this: the model's answer at a gap of
  /// zero is an infinite deceleration.
  static const double minGapM = 0.01;

  /// The acceleration of a vehicle at speed [v] wanting [v0], [gap] metres
  /// behind a leader it closes on at [dv] (its speed minus the leader's);
  /// [gap] infinite for none. [a], [headwayS], [jamM] and [sqrtAb] are its
  /// kind's (`VehicleKinds`). `(v/v0)⁴` is squared twice (§5.3).
  static double accel(double v, double v0, double gap, double dv, double a,
      double headwayS, double jamM, double sqrtAb) {
    final r = v / v0;
    final r2 = r * r;
    var acc = a * (1 - r2 * r2);
    if (gap < double.infinity) {
      var dyn = v * headwayS + v * dv / (2 * sqrtAb);
      if (dyn < 0) dyn = 0;
      final g = gap > minGapM ? gap : minGapM;
      final q = (jamM + dyn) / g;
      acc -= a * q * q;
    }
    return acc;
  }
}

/// One ballistic step of the IDM (§5.3): the metres moved, [ds], and the
/// speed at the end, [v]. A vehicle that would reverse inside the step
/// stops inside it instead, exactly where its deceleration puts it.
class IdmStep {
  double ds = 0;
  double v = 0;

  void run(double speed, double acc, double h) {
    final vn = speed + acc * h;
    if (vn < 0) {
      ds = acc < 0 ? speed * speed / (2 * -acc) : 0;
      v = 0;
    } else {
      ds = (speed + vn) / 2 * h;
      v = vn;
    }
  }
}

/// Moves every vehicle of a [VehicleTable] one sub-step at a time.
class VehicleMover {
  VehicleMover(this.table, this.arbiter);

  final VehicleTable table;
  final JunctionArbiter arbiter;

  /// Obstacles in road lanes that are on no list: the site mover's back-out
  /// footprints and far-direction claims (docs/plans/t4a-implementation.md
  /// §2). Null, or a count of 0, and no vehicle asks — the road mover costs
  /// what it did before sites.
  LaneObstacles? obstacles;

  LaneGraph? _lg;

  // ---- Counters -------------------------------------------------------------

  int arrivals = 0;
  int despawnStuck = 0;
  int despawnWedge = 0;
  int despawnEdit = 0;
  int handOvers = 0;

  /// Vehicles that reached a line without a clearance and were held there:
  /// the safety net under the leader search, which should never be needed.
  int lineStops = 0;

  // ---- The edges' books ------------------------------------------------------

  /// Per edge, since the last [clearBooks]: metres driven on its lanes, and
  /// the metres the same vehicle-time would have covered at its limit —
  /// what the congestion index is read from (§4.2) — the vehicles that
  /// left it through a connector, and the vehicles despawned stuck on it.
  Float64List edgeDrivenM = Float64List(0);
  Float64List edgeLimitM = Float64List(0);
  Int32List edgeExits = Int32List(0);
  Int32List edgeStuck = Int32List(0);

  /// [edgeDrivenM] and [edgeLimitM] over the whole network.
  double drivenM = 0;
  double limitM = 0;

  // ---- The delay table's books (§4.2, edge_delay.dart) ------------------------

  /// This sub-step's delay observations, in the order they happened, until
  /// the delay table takes them in (`EdgeDelayTable.absorb`): the edge, the
  /// seconds it and its connector took over their free time, and 1 where
  /// the vehicle left through a node — whose expected control delay the
  /// table subtracts — or 0 where it stopped on the edge at the end of its
  /// trip.
  Int32List obsEdge = Int32List(0);
  Float32List obsS = Float32List(0);
  Uint8List obsAtNode = Uint8List(0);
  int observationCount = 0;

  /// Per edge, since the delay table last took them: vehicles that left it,
  /// through a connector or by arriving — its flow.
  Int32List edgeDeparts = Int32List(0);

  /// Per lane, since the delay table last took them: the sum over sub-steps
  /// of each vehicle's `v / limit` on it, and how many were summed — the
  /// lane speeds' samples. A vehicle standing on purpose (a stall, a dwell)
  /// samples 0: the lane is blocked all the same.
  Float64List laneVSum = Float64List(0);
  Int32List laneSamples = Int32List(0);

  // ---- Scratch ------------------------------------------------------------------

  Int32List _hand = Int32List(0);
  int _nHand = 0;
  final Int32List _victims = Int32List(64);
  final IdmStep _idm = IdmStep();

  /// [LaneObstacles.obstacleAhead]'s answer: near end (lane metres), speed.
  final Float64List _obsOut = Float64List(2);

  /// The leader search's answer: the IDM gap and the leader's speed, the
  /// hard limit on how far the front may move and the speed that goes with
  /// it, and the desired speed, lowered for slower elements ahead.
  double _gap = double.infinity;
  double _lv = 0;
  double _room = double.infinity;
  double _roomV = 0;
  double _v0 = 0;

  static final int _driving = VehicleState.driving.index;
  static final int _hold = VehicleState.holdAtEdgeEnd.index;
  static final int _dwelling = VehicleState.dwelling.index;
  static final int _parking = VehicleState.parkingSearch.index;
  static final int _leaving = VehicleState.leaving.index;
  static final int _manoeuvre = VehicleState.manoeuvre.index;

  LaneGraph get graph {
    final lg = _lg;
    if (lg == null) throw StateError('the mover has no lane graph');
    return lg;
  }

  /// Puts the table, the arbiter and the books on [lg]. After a rebuild
  /// (a graph that does not share [lg]'s structure) the owner places every
  /// vehicle on the new graph and relinks the table (`VehicleTable.bind`).
  void bind(LaneGraph lg) {
    final old = _lg;
    _lg = lg;
    table.bind(lg);
    arbiter.bind(lg);
    if (old == null || !lg.sharesStructureWith(old)) {
      final nE = lg.edgeCount;
      edgeDrivenM = Float64List(nE);
      edgeLimitM = Float64List(nE);
      edgeExits = Int32List(nE);
      edgeStuck = Int32List(nE);
      drivenM = 0;
      limitM = 0;
      // Edge and lane ids mean nothing across two builds.
      edgeDeparts = Int32List(nE);
      laneVSum = Float64List(lg.laneCount);
      laneSamples = Int32List(lg.laneCount);
      observationCount = 0;
    }
  }

  /// Every buffer the mover keeps from one sub-step to the next — the
  /// edges' books and its scratch — by name into [into], for the
  /// allocation test (§15.2): none is replaced while one graph runs.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.edgeDrivenM'] = edgeDrivenM;
    into['$name.edgeLimitM'] = edgeLimitM;
    into['$name.edgeExits'] = edgeExits;
    into['$name.edgeStuck'] = edgeStuck;
    into['$name.hand'] = _hand;
    into['$name.victims'] = _victims;
    into['$name.obsOut'] = _obsOut;
    into['$name.obsEdge'] = obsEdge;
    into['$name.obsS'] = obsS;
    into['$name.obsAtNode'] = obsAtNode;
    into['$name.edgeDeparts'] = edgeDeparts;
    into['$name.laneVSum'] = laneVSum;
    into['$name.laneSamples'] = laneSamples;
  }

  /// Zeroes the departures book.
  void clearDepartures() => edgeDeparts.fillRange(0, edgeDeparts.length, 0);

  /// Zeroes the lane-speed samples.
  void clearLaneBooks() {
    laneVSum.fillRange(0, laneVSum.length, 0);
    laneSamples.fillRange(0, laneSamples.length, 0);
  }

  /// Zeroes the edges' books.
  void clearBooks() {
    edgeDrivenM.fillRange(0, edgeDrivenM.length, 0);
    edgeLimitM.fillRange(0, edgeLimitM.length, 0);
    edgeExits.fillRange(0, edgeExits.length, 0);
    edgeStuck.fillRange(0, edgeStuck.length, 0);
    drivenM = 0;
    limitM = 0;
  }

  /// One sub-step, at agent time [nowUs] — the time the signals are read at.
  void step(int nowUs, [VehicleSink? sink]) {
    final lg = graph, t = table;
    final hw = t.highWater;
    if (_hand.length < t.capacity) _hand = Int32List(t.capacity);
    // A vehicle observes at most one edge per two hand-overs, and once more
    // when it arrives: the log never fills, and is sized once.
    final obsCap =
        t.capacity * ((AgentTuning.maxHandOversPerStep + 1) ~/ 2 + 1);
    if (obsEdge.length < obsCap) {
      obsEdge = Int32List(obsCap)..setRange(0, observationCount, obsEdge);
      obsS = Float32List(obsCap)..setRange(0, observationCount, obsS);
      obsAtNode = Uint8List(obsCap)..setRange(0, observationCount, obsAtNode);
    }
    arbiter.beginStep();
    for (var sl = 0; sl < hw; sl++) {
      t.flags[sl] &= ~(kHandedOver | kRefused);
    }
    t.sPre.setRange(0, hw, t.s);
    t.vPre.setRange(0, hw, t.v);

    // 1. Move, element by element, leader first.
    _nHand = 0;
    final nEl = lg.elementCount;
    for (var el = 0; el < nEl; el++) {
      for (var sl = t.elemHead[el]; sl >= 0; sl = t.next[sl]) {
        _move(sl, el, nowUs);
      }
    }

    // 2. Hand over, in the order they moved.
    for (var i = 0; i < _nHand; i++) {
      _handOver(_hand[i], nowUs);
    }

    // 3. Break wedges.
    final nv = arbiter.wedgeVictims(_victims);
    for (var i = 0; i < nv; i++) {
      despawn(_victims[i], DespawnReason.wedge, sink);
    }

    // 4. Arrivals and stuck timers.
    _settle(nowUs, sink);
  }

  /// Takes [handle] off the road: [sink] told first, then everything it
  /// held at junctions released, its route returned, its slot freed. False
  /// for a stale handle.
  bool despawn(int handle, DespawnReason reason, [VehicleSink? sink]) {
    final t = table;
    if (!t.isLive(handle)) return false;
    switch (reason) {
      case DespawnReason.stuck:
        despawnStuck++;
      case DespawnReason.wedge:
        despawnWedge++;
      case DespawnReason.edit:
        despawnEdit++;
    }
    sink?.despawned(handle, reason);
    if (!t.isLive(handle)) return true;
    arbiter.release(SlotPool.slotOf(handle));
    t.free(handle);
    return true;
  }

  // ---- 1. Moving -------------------------------------------------------------

  void _move(int sl, int el, int nowUs) {
    final t = table, lg = graph;
    final st = t.state[sl];
    // A manoeuvring car stands as a dwelling one does: the site mover owns
    // its pose (a back-out's reverse and swing, site-access.md §7.4), and to
    // the road it is a stationary obstacle its followers stop behind.
    if (st == _dwelling || st == _manoeuvre || st == _leaving) {
      t.v[sl] = 0;
      t.a[sl] = 0;
      // Standing in its lane on purpose, it blocks the lane all the same.
      if (st != _leaving && el < lg.laneCount) laneSamples[el]++;
      return;
    }
    final k = t.kind[sl];
    final b = VehicleKinds.brake[k], s0 = VehicleKinds.jamM[k];
    final v = t.v[sl].toDouble(), s = t.s[sl].toDouble();
    final nL = lg.laneCount;
    final onLane = el < nL;
    final elemLen =
        onLane ? lg.laneLength(el) : lg.conLen[el - nL].toDouble();
    _gap = double.infinity;
    _lv = 0;
    _room = double.infinity;
    _roomV = 0;
    _v0 = t.v0[sl].toDouble();

    final p = t.prev[sl];
    if (p >= 0) {
      final g = t.s[p] - t.len[p] - s;
      _lead(g, t.v[p], g - kLeaderClearM);
      if (onLane) _anticipateNext(sl, elemLen - s, b);
    } else {
      _lookAhead(sl, el, s, v, elemLen, nowUs, b, s0);
    }
    // Its own stops: where the trip ends, and the end of the edge it holds
    // at while a re-plan is queued.
    if (onLane) {
      if (t.routeCur[sl] >= t.routeLen[sl] - 1) {
        final dist = t.destS[sl] - lg.edgeLaneS0[lg.laneEdge[el]] - s;
        _lead(dist + s0 - kStopShortM, 0, dist);
      } else if (st == _hold) {
        final dist = elemLen - s;
        _lead(dist + s0 - kStopShortM, 0, dist - kLineClearM);
      }
    }
    // An obstacle on no list — a back-out's footprint, a far-direction
    // claim — in the lane it is on or, from a connector, the lane it is
    // entering: a leader like any other (§7.4). A local, promoted directly:
    // never through a boolean (agent_traffic_readout.dart `_lotsStep`).
    final obs = obstacles;
    if (obs != null && obs.count > 0) {
      final lane = onLane ? el : lg.conToLane[el - nL];
      final at = onLane ? s : s - elemLen;
      if (obs.obstacleAhead(lane, at, _obsOut)) {
        final g = _obsOut[0] - at;
        _lead(g, _obsOut[1], g - kLeaderClearM);
      }
    }

    final v0 = _v0 < 0.1 ? 0.1 : _v0;
    final acc = Idm.accel(v, v0, _gap, v - _lv, VehicleKinds.accel[k],
        VehicleKinds.headwayS[k], s0, VehicleKinds.sqrtAb[k]);
    _idm.run(v, acc, kStepS);
    var ds = _idm.ds, vn = _idm.v;
    if (ds > _room) {
      ds = _room > 0 ? _room : 0.0;
      if (vn > _roomV) vn = _roomV;
    }
    final sn = s + ds;
    t.s[sl] = sn;
    t.v[sl] = vn;
    t.a[sl] = (vn - v) / kStepS;
    t.odo[sl] += ds;
    t.movedM[sl] += ds;
    if (onLane) {
      final e = lg.laneEdge[el];
      final limit = lg.edgeLimit[e];
      final lim = limit * kStepS;
      edgeDrivenM[e] += ds;
      edgeLimitM[e] += lim;
      drivenM += ds;
      limitM += lim;
      if (limit > 0) laneVSum[el] += vn / limit;
      laneSamples[el]++;
    }
    if (t.flags[sl] & kRefused != 0 && vn < kWaitingMps) {
      // Saturating, not wrapping: only a grant clears this clock, and a car
      // that creeps a metre now and then keeps resetting its STUCK timer
      // without ever being let through — so nothing bounds this one by an
      // hour. Wrapped negative it would tell the impatient grant (§5.4) and
      // the wedge breaker (§5.8) that the longest waiter at the node had
      // only just arrived (traffic_time.dart, "clocks that only count up").
      t.waitUs[sl] = addClock(t.waitUs[sl], kStepUs);
    }
    if (sn >= elemLen) _hand[_nHand++] = sl;
  }

  /// Takes the nearer of what the search has and a leader [g] metres ahead
  /// moving at [lv], with the front allowed [room] metres further at most.
  void _lead(double g, double lv, double room) {
    if (g < _gap) {
      _gap = g;
      _lv = lv;
    }
    if (room < _room) {
      _room = room;
      _roomV = lv;
    }
  }

  /// Lowers the desired speed so the vehicle is down to [v0next] by the
  /// time it has come [rem] metres, braking comfortably at [b]: it slows for
  /// a tight turn before it, not on it.
  void _anticipate(double v0next, double rem, double b) {
    if (v0next >= _v0) return;
    final cap = math.sqrt(v0next * v0next + 2 * b * (rem > 0 ? rem : 0));
    if (cap < _v0) _v0 = cap;
  }

  /// [_anticipate] for the connector at the end of the lane [sl] is on.
  void _anticipateNext(int sl, double rem, double b) {
    final t = table;
    final i = t.routeCur[sl] + 1;
    if (i >= t.routeLen[sl]) return;
    _anticipate(_conV0(t.arena.data[t.routeOff[sl] + i], t.f[sl]), rem, b);
  }

  /// The desired speed on connector [c] of a trip with factor [f]: the
  /// slower of the two roads' limits, and no faster than its bend allows
  /// (§5.3).
  double _conV0(int c, double f) {
    final lg = graph;
    final a = lg.edgeLimit[lg.conFromEdge(c)], b = lg.edgeLimit[lg.conToEdge(c)];
    final v = (a < b ? a : b) * f;
    final cap = lg.conVmax[c];
    return v < cap ? v : cap.toDouble();
  }

  double _laneV0(int lane, double f) => graph.edgeLimit[graph.laneEdge[lane]] * f;

  /// The leader of the vehicle at the front of its element: the last
  /// vehicle on the next elements of its route, a line it may not cross,
  /// or its stop — and, on the way, the arbiter's answer at the first line.
  void _lookAhead(int sl, int el, double s, double v, double elemLen,
      int nowUs, double b, double s0) {
    final t = table, lg = graph;
    final nL = lg.laneCount;
    final data = t.arena.data;
    final off = t.routeOff[sl], rLen = t.routeLen[sl];
    final hold = t.state[sl] == _hold;
    final dDec = math.max(v * v / (2 * b) + kDecisionMarginM, kDecisionMinM);
    final f = t.f[sl].toDouble();
    var i = t.routeCur[sl];
    var cur = el;
    var rem = elemLen - s;
    var asked = false;
    for (var hop = 0; hop < kLookAheadElems; hop++) {
      if (cur < nL) {
        // A lane of route edge i: its end is a stop line, or the stop.
        if (i >= rLen - 1) return;
        if (hold) {
          _lead(rem + s0 - kStopShortM, 0, rem - kLineClearM);
          return;
        }
        final c = data[off + i + 1];
        if (rem <= dDec || t.pass[sl] == c) {
          final ok = arbiter.decide(sl, c, rem, nowUs, commit: !asked);
          asked = true;
          if (!ok) {
            _lead(rem + s0 - kStopShortM, 0, rem - kLineClearM);
            return;
          }
        }
        if (rem < kThroatM) _throat(cur, rem);
        cur = nL + c;
        i++;
        final tail = t.elemTail[cur];
        if (tail >= 0) {
          final g = rem + t.sPre[tail] - t.len[tail];
          _lead(g, t.vPre[tail], g - kLeaderClearM);
          return;
        }
        _anticipate(_conV0(c, f), rem, b);
        rem += lg.conLen[c];
      } else {
        // A connector onto route edge i.
        final lane = lg.conToLane[cur - nL];
        final last = i >= rLen - 1;
        if (last) {
          // Its stop, taken no nearer than [kArriveM] into the lane: a
          // vehicle comes to rest [kStopShortM] short of its stop, and it
          // arrives only on a lane, so a stop at the lane's very start — a
          // building met at the stop bar, a stop an edit's new junction
          // box swallowed — would hold it on the connector for good.
          final dl = math.max(
              t.destS[sl] - lg.edgeLaneS0[lg.laneEdge[lane]], kArriveM);
          _lead(rem + dl + s0 - kStopShortM, 0, rem + dl);
        }
        final tail = t.elemTail[lane];
        if (tail >= 0) {
          final g = rem + t.sPre[tail] - t.len[tail];
          _lead(g, t.vPre[tail], g - kLeaderClearM);
          return;
        }
        if (last) return;
        _anticipate(_laneV0(lane, f), rem, b);
        cur = lane;
        rem += lg.laneLength(lane);
      }
      if (rem > kLookAheadM) return;
    }
  }

  /// A vehicle that has just gone through a connector leaving [lane] — any
  /// of them, not only this vehicle's — still has its tail across the
  /// lane's end: it is in the way until it has pulled clear.
  void _throat(int lane, double rem) {
    final t = table, lg = graph;
    final nL = lg.laneCount;
    for (var c = lg.laneConStart[lane]; c < lg.laneConStart[lane + 1]; c++) {
      final tail = t.elemTail[nL + c];
      if (tail < 0) continue;
      final rear = t.sPre[tail] - t.len[tail];
      if (rear < kThroatM) {
        final g = rem + rear;
        _lead(g, t.vPre[tail], g - kLeaderClearM);
      }
    }
  }

  // ---- 2. Hand-overs ---------------------------------------------------------

  void _handOver(int sl, int nowUs) {
    final t = table, lg = graph;
    final nL = lg.laneCount;
    for (var n = 0; n < AgentTuning.maxHandOversPerStep; n++) {
      final el = t.elem[sl];
      final onLane = el < nL;
      final elemLen =
          onLane ? lg.laneLength(el) : lg.conLen[el - nL].toDouble();
      final sNow = t.s[sl].toDouble();
      if (sNow < elemLen) return;
      if (onLane) {
        final i = t.routeCur[sl] + 1;
        if (i >= t.routeLen[sl] || t.state[sl] == _hold) {
          _holdAt(sl, sNow, elemLen);
          return;
        }
        final c = t.arena.data[t.routeOff[sl] + i];
        // The leader search asked at every line this vehicle could reach;
        // one it did not is asked now, at the line, and held if refused.
        if (t.pass[sl] != c && !arbiter.decide(sl, c, 0, nowUs)) {
          _holdAt(sl, sNow, elemLen - kLineClearM);
          t.v[sl] = 0;
          lineStops++;
          return;
        }
        t.unlink(sl);
        edgeExits[lg.laneEdge[el]]++;
        edgeDeparts[lg.laneEdge[el]]++;
        arbiter.entered(sl, c);
        t.elem[sl] = nL + c;
        t.routeCur[sl] = i;
        t.s[sl] = sNow - elemLen;
        t.v0[sl] = _conV0(c, t.f[sl]);
        t.link(sl);
      } else {
        final c = el - nL;
        final lane = lg.conToLane[c];
        _observeThrough(sl, c, nowUs);
        t.unlink(sl);
        t.elem[sl] = lane;
        t.s[sl] = sNow - elemLen;
        t.v0[sl] = _laneV0(lane, t.f[sl]);
        t.edgeEnterUs[sl] = nowUs.toDouble();
        t.link(sl);
        arbiter.left(sl, c);
      }
      t.flags[sl] |= kHandedOver;
      handOvers++;
    }
    // Out of hand-overs for this sub-step: it waits at the end of the
    // element it has reached.
    final el = t.elem[sl];
    final elemLen = el < nL ? lg.laneLength(el) : lg.conLen[el - nL].toDouble();
    if (t.s[sl] > elemLen) _holdAt(sl, t.s[sl].toDouble(), elemLen);
  }

  // ---- Delay observations (§4.2) ---------------------------------------------

  /// Whether [sl] came onto the edge it is on at the start of its lane, at
  /// `edgeEnterUs`: through a connector, after its trip began. A vehicle
  /// that pulled out part way along, or whose time on the edge an edit or a
  /// wait for a plan made meaningless (`CityAgents` marks those −1),
  /// observes nothing there.
  bool _observable(int sl) {
    final t = table;
    return t.edgeEnterUs[sl] > t.tripT0Us[sl];
  }

  /// [sl] is leaving connector [c] at [nowUs]: one observation for the edge
  /// the connector leaves — its lane and the connector against their free
  /// time at the vehicle's own desired speed (the table subtracts the
  /// node's expected control delay).
  void _observeThrough(int sl, int c, int nowUs) {
    if (!_observable(sl)) return;
    final t = table, lg = graph;
    final from = lg.conFromLane[c];
    final e = lg.laneEdge[from];
    final f = t.f[sl].toDouble();
    final vLane = lg.edgeLimit[e] * f;
    final vCon = _conV0(c, f);
    if (vLane <= 0 || vCon <= 0) return;
    final free = lg.laneLength(from) / vLane + lg.conLen[c] / vCon;
    _book(e, (nowUs - t.edgeEnterUs[sl]) / kUsPerSecond - free, 1);
  }

  /// [sl] has arrived on lane [lane] at [nowUs]: its lane time up to its
  /// stop, against the free time of the metres to it — no connector, and no
  /// node to wait at.
  void _observeArrival(int sl, int lane, int nowUs) {
    final t = table, lg = graph;
    final e = lg.laneEdge[lane];
    edgeDeparts[e]++;
    if (!_observable(sl)) return;
    final v = lg.edgeLimit[e] * t.f[sl];
    if (v <= 0) return;
    final m = t.destS[sl] - lg.edgeLaneS0[e];
    final free = (m > 0 ? m : 0.0) / v;
    _book(e, (nowUs - t.edgeEnterUs[sl]) / kUsPerSecond - free, 0);
  }

  void _book(int edge, double seconds, int atNode) {
    final i = observationCount;
    if (i >= obsEdge.length) return;
    obsEdge[i] = edge;
    obsS[i] = seconds;
    obsAtNode[i] = atNode;
    observationCount = i + 1;
  }

  /// Puts [sl]'s front back from [sNow] to [at], and its odometers with it.
  void _holdAt(int sl, double sNow, double at) {
    final t = table;
    final back = sNow - at;
    if (back <= 0) return;
    t.s[sl] = at;
    t.odo[sl] -= back;
    t.movedM[sl] -= back;
  }

  // ---- 4. Arrivals and stuck timers ------------------------------------------

  void _settle(int nowUs, VehicleSink? sink) {
    final t = table, lg = graph;
    final nL = lg.laneCount;
    final stuckLimit = usOf(AgentTuning.stuckDespawnS);
    final hw = t.highWater;
    for (var sl = 0; sl < hw; sl++) {
      if (!t.isSlotLive(sl)) continue;
      final st = t.state[sl];
      final h = t.handleOf(sl);
      if (st == _leaving) {
        arbiter.release(sl);
        t.free(h);
        continue;
      }
      final el = t.elem[sl];
      // Off the road, inside a site: its arrival and its clocks are the
      // site mover's (docs/plans/t4a-implementation.md §1.2).
      if (el < 0) continue;
      if (st == _driving &&
          el < nL &&
          t.routeCur[sl] >= t.routeLen[sl] - 1 &&
          t.s[sl] >= t.destS[sl] - lg.edgeLaneS0[lg.laneEdge[el]] - kArriveM) {
        arrivals++;
        _observeArrival(sl, el, nowUs);
        t.state[sl] = _leaving;
        sink?.arrived(h);
        if (t.isLive(h) && t.state[sl] == _leaving) {
          arbiter.release(sl);
          t.free(h);
        }
        continue;
      }
      if (st != _driving && st != _parking) continue;
      if (t.movedM[sl] > kStuckResetM) {
        t.stuckUs[sl] = 0;
        t.movedM[sl] = 0;
      } else if (t.v[sl] < kStuckMps && t.flags[sl] & kHandedOver == 0) {
        t.stuckUs[sl] += kStepUs;
        if (t.stuckUs[sl] >= stuckLimit) {
          edgeStuck[el < nL ? lg.laneEdge[el] : lg.conFromEdge(el - nL)]++;
          despawn(h, DespawnReason.stuck, sink);
        }
      }
    }
  }
}
