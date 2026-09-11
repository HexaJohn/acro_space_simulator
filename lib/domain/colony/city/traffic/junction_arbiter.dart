// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Who may cross a stop line, and when (docs/plans/agent-traffic.md §5.4,
/// §5.5, §5.8).
///
/// A vehicle nearing the end of its lane asks once it is within braking
/// reach of the line (`dDec = max(v²/2b + 5, 12)` m). The answer follows the
/// node's own control, read from the network's plan and never re-decided
/// (node_control.dart): the light the leg shows, whether the leg stops, who
/// gives way to whom. A vehicle refused stops at the line, behind a virtual
/// standing car the mover puts there.
///
/// SAFETY comes from one rule that no control, exemption or impatience ever
/// waives: a connector is entered only while every connector crossing it is
/// clear short of the point where the two cross — no vehicle on it whose
/// tail has not passed that point, and no vehicle cleared into it that has
/// not yet reached it. Two vehicles deciding in one sub-step could each see
/// the other's connector empty, so a clearance is a PASS the vehicle
/// commits to once it is close enough to cross (a sub-step's travel and two
/// metres), counted on the connector like a vehicle already on it: whoever
/// asks second sees it. The mover refuses to hand a vehicle into a connector
/// it holds no pass for, so this is enforced, not hoped for. A pass is given
/// up again while its holder can still stop comfortably — a light gone
/// amber, an exit lane that filled — and kept once it cannot.
///
/// Everything else is courtesy, and gives way to the deadlock breaker: after
/// `impatientGrantS` at a line, the arrival-order and gap-acceptance parts
/// are waived (a FORCED clearance, counted), the safety rule and the box
/// check still hold. A red light is never waived: it changes by itself.
///
/// Nothing here allocates once bound: the queues, claims and counters are
/// typed columns sized to the graph.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'agent_kind.dart';
import 'lane_connectors.dart';
import 'lane_graph.dart';
import 'node_control.dart';
import 'route_cost.dart';
import 'slot_pool.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';
import 'vehicle_table.dart';

/// Why a vehicle was cleared into a connector — the last answer, kept in
/// `VehicleTable.grant` for the inspector, and handed to [ArbiterObserver].
/// Append-only.
enum GrantReason {
  /// Refused, or never asked.
  none,

  /// Nothing to wait for: its crossings clear, and nobody it must yield to.
  clear,

  /// A green light.
  green,

  /// Amber, too close to stop comfortably: the dilemma rule.
  amberDilemma,

  /// Amber, a left-turner already waiting at the line with its crossings
  /// clear.
  amberLeftClear,

  /// It stopped or gave way, and took a gap.
  gap,

  /// Its turn at an all-way stop.
  allWayTurn,

  /// It waited past `AgentTuning.impatientGrantS`, and the gap rules' ETA
  /// and arrival-order parts were waived.
  forced,
}

/// Told of every pass a vehicle commits to: the tests' audit of the rules,
/// and the route inspector's.
abstract interface class ArbiterObserver {
  void committed(
      int slot, int connector, GrantReason reason, double dist, int nowUs);
}

/// The opposing-left gap, and the gap a stopping or lower-ranked leg needs
/// from traffic with priority (§5.4): no such vehicle nearer than 4 s.
const double kOpposingGapS = 4.0;

/// A ramp's merge waits for a mainline follower at least this far off.
const double kMergeGapS = 2.5;

/// A dropped lane zips in behind the lane it joins at this gap.
const double kZipperGapS = 2.0;

/// A vehicle this close to its line, and slower than [kRestMps], is at the
/// line and at rest — as a stop sign demands.
const double kAtLineM = 3.0;
const double kRestMps = 0.3;

/// A clearance becomes a pass once the vehicle is within a sub-step's travel
/// of the line plus this.
const double kCommitSlackM = 2.0;

/// An ETA is taken at no slower than this: a vehicle stopped just short of
/// its line is about to go, not an hour away.
const double kEtaFloorMps = 0.5;

/// An exit lane whose last vehicle moves faster than this is emptying: the
/// box check lets a vehicle in behind it.
const double kBoxTailMovingMps = 3.0;

/// How far across another's path (the sine of the angle) an approach must
/// come for it to come "from the right".
const double kFromRightSin = 0.3;

/// The junction rules. Bound to one lane graph at a time ([bind]); asked by
/// the mover for every vehicle nearing a line ([decide]).
class JunctionArbiter {
  JunctionArbiter(this.table);

  final VehicleTable table;

  /// Told of every committed pass; null in play.
  ArbiterObserver? observer;

  /// Passes committed, passes given up, and clearances that waived the gap
  /// rules to break a deadlock (§5.4: every forced grant is counted).
  int commits = 0;
  int revokes = 0;
  int forcedGrants = 0;

  LaneGraph? _lg;

  /// Per connector: vehicles holding a pass into it, not yet on it.
  Int32List _claims = Int32List(0);

  /// Per connector: the last vehicle to leave it (its handle), and the
  /// odometer reading at which its front did. At most one vehicle can have
  /// left a connector with its tail still on it — any before it is further
  /// on still — so one is all there is to remember.
  Int32List _leaver = Int32List(0);
  Float64List _leaverOdo = Float64List(0);

  /// Per edge: the travel direction where its lanes end, and whether its
  /// road is a leg the junction plan was drawn over (an alley or a path is
  /// not: it gives way to every leg that is).
  Float32List _arrE = Float32List(0), _arrN = Float32List(0);
  Uint8List _drawn = Uint8List(0);

  /// All-way stops: per node its queue number or −1, and per queue its
  /// entries (handle, arrival µs, connector wanted), [_fifoCap] each, oldest
  /// first by (arrival, handle).
  Int32List _awOf = Int32List(0);
  Int32List _fifoH = Int32List(0), _fifoC = Int32List(0);
  Float64List _fifoUs = Float64List(0);
  Int32List _fifoLen = Int32List(0);
  int _fifoCap = 16;

  /// The wedge breaker's books for the sub-step: per node, the approach
  /// heads refused there after waiting past `wedgeWaitS`, and the longest
  /// waiter; the nodes touched, in the order they were.
  Int32List _wStamp = Int32List(0), _wCount = Int32List(0);
  Int32List _wBest = Int32List(0), _touched = Int32List(0);
  int _stamp = 0, _nTouched = 0;

  static final int _signals = NodeControlKind.signals.index;
  static final int _allWay = NodeControlKind.allWayStop.index;
  static final int _stop = NodeControlKind.stop.index;
  static final int _uncontrolled = NodeControlKind.uncontrolled.index;
  static final int _rampMerge = NodeControlKind.rampMerge.index;
  static final int _continuation = NodeControlKind.continuation.index;
  static final int _left = TurnClass.left.index;
  static final int _sharp = TurnClass.sharp.index;
  static final int _uTurn = TurnClass.uTurn.index;
  static final int _mergeYield = ConnectorRole.mergeYield.index;
  static final int _droppedLane = ConnectorRole.droppedLane.index;
  static final int _driving = VehicleState.driving.index;

  LaneGraph get graph {
    final lg = _lg;
    if (lg == null) throw StateError('the arbiter has no lane graph');
    return lg;
  }

  /// Puts the rules on [lg].
  ///
  /// A graph sharing [lg]'s structure (a control refresh) keeps every
  /// connector id, so passes and leavers stand; only the all-way queues are
  /// re-sorted onto the nodes that are still all-way stops. Any other graph
  /// numbers everything afresh, and every pass, queue place and halt goes:
  /// each vehicle asks again at its next line.
  void bind(LaneGraph lg) {
    final old = _lg;
    _lg = lg;
    final t = table;
    final nC = lg.connectorCount, nE = lg.edgeCount, nN = lg.nodeCount;
    final same = old != null && lg.sharesStructureWith(old);
    if (!same) {
      _claims = Int32List(nC);
      _leaver = Int32List(nC)..fillRange(0, nC, -1);
      _leaverOdo = Float64List(nC);
      _arrE = Float32List(nE);
      _arrN = Float32List(nE);
      _drawn = Uint8List(nE);
      final pt = Float64List(4);
      for (var e = 0; e < nE; e++) {
        if (e >= lg.roadEdgeCount) {
          _drawn[e] = 1;
          continue;
        }
        _drawn[e] =
            lg.graph.roads[lg.edgeRoad[e]].roadClass.joinsJunctions ? 1 : 0;
        final t1 = lg.edgeLaneS1[e].toDouble();
        final t0 = math.max(0.0, t1 - 3.0);
        RouteCost.pointOn(lg, e, t0, pt, 0);
        RouteCost.pointOn(lg, e, t1, pt, 2);
        final de = pt[2] - pt[0], dn = pt[3] - pt[1];
        final l = math.sqrt(de * de + dn * dn);
        if (l > 1e-9) {
          _arrE[e] = de / l;
          _arrN[e] = dn / l;
        }
      }
      for (var sl = 0; sl < t.highWater; sl++) {
        t.pass[sl] = -1;
        t.flags[sl] &= ~(kHalted | kInFifo);
      }
    }
    _bindQueues(lg, same);
    if (_wStamp.length != nN) {
      _wStamp = Int32List(nN);
      _wCount = Int32List(nN);
      _wBest = Int32List(nN);
      _touched = Int32List(nN);
    }
    _nTouched = 0;
  }

  void _bindQueues(LaneGraph lg, bool same) {
    final t = table;
    final nN = lg.nodeCount;
    final cap = AgentTuning.allWayStopQueueCap;
    final oldAw = _awOf, oldH = _fifoH, oldC = _fifoC, oldUs = _fifoUs;
    final oldLen = _fifoLen, oldCap = _fifoCap;
    final aw = Int32List(nN)..fillRange(0, nN, -1);
    var q = 0;
    for (var n = 0; n < nN; n++) {
      if (lg.controls.kind[n] == _allWay) aw[n] = q++;
    }
    _awOf = aw;
    _fifoCap = cap;
    _fifoH = Int32List(q * cap);
    _fifoC = Int32List(q * cap);
    _fifoUs = Float64List(q * cap);
    _fifoLen = Int32List(q);
    if (!same) return;
    // Carry each queue whose node is still an all-way stop; a vehicle whose
    // queue went with its node's control asks afresh.
    for (var n = 0; n < oldAw.length && n < nN; n++) {
      final k0 = oldAw[n];
      if (k0 < 0) continue;
      final k1 = aw[n];
      for (var i = 0; i < oldLen[k0]; i++) {
        final h = oldH[k0 * oldCap + i];
        if (k1 >= 0 && _fifoLen[k1] < cap) {
          final j = k1 * cap + _fifoLen[k1]++;
          _fifoH[j] = h;
          _fifoC[j] = oldC[k0 * oldCap + i];
          _fifoUs[j] = oldUs[k0 * oldCap + i];
        } else if (t.isLive(h)) {
          t.flags[SlotPool.slotOf(h)] &= ~kInFifo;
        }
      }
    }
  }

  /// Starts a sub-step's books.
  void beginStep() {
    _stamp++;
    _nTouched = 0;
  }

  // ---- The question -----------------------------------------------------------

  /// Whether [slot], [dist] metres short of its line, may go on into
  /// connector [c] at agent time [nowUs].
  ///
  /// With [commit] (the first line ahead of it), a clearance close enough to
  /// act on becomes its pass, and a refusal counts towards the wedge
  /// breaker. A pass already held is kept while the vehicle could not stop
  /// comfortably, and given up otherwise.
  bool decide(int slot, int c, double dist, int nowUs, {bool commit = true}) {
    final t = table;
    final v = t.v[slot].toDouble();
    final b = VehicleKinds.brake[t.kind[slot]];
    final d = dist > 0 ? dist : 0.0;
    final canStop = v * v <= 2 * b * d;
    final reason = _rules(slot, c, d, v, canStop, nowUs);
    final held = t.pass[slot] == c;
    if (reason != GrantReason.none) {
      t.grant[slot] = reason.index;
      if (!held &&
          commit &&
          (d <= v * kStepS + kCommitSlackM ||
              reason == GrantReason.amberDilemma)) {
        _take(slot, c);
        commits++;
        if (reason == GrantReason.forced) forcedGrants++;
        observer?.committed(slot, c, reason, d, nowUs);
      }
      return true;
    }
    if (held) {
      // Too late to stop: it goes on the clearance it had.
      if (!canStop) return true;
      _drop(slot);
      revokes++;
    }
    t.grant[slot] = GrantReason.none.index;
    if (commit && t.flags[slot] & kRefused == 0) {
      t.flags[slot] |= kRefused;
      if (t.waitUs[slot] > usOf(AgentTuning.wedgeWaitS)) {
        _noteWaiting(slot, graph.conNode[c]);
      }
    }
    return false;
  }

  GrantReason _rules(
      int slot, int c, double dist, double v, bool canStop, int nowUs) {
    final lg = graph, t = table;
    final ctl = lg.controls;
    final node = lg.conNode[c];
    final kind = ctl.kind[node];
    final from = lg.laneEdge[lg.conFromLane[c]];
    final road = from < lg.roadEdgeCount;
    var ok = road && ctl.edgeYields[from] == 1
        ? GrantReason.gap
        : GrantReason.clear;

    // The light, where there is one: red never goes, amber only as the
    // dilemma rule or a waiting left-turner allows.
    if (kind == _signals && road) {
      final phase = ctl.edgePhase[from];
      final plan = ctl.planOf(node);
      if (phase >= 0 && plan != null) {
        final st = plan.stateAt(phase, nowUs);
        if (st == SignalState.green) {
          ok = GrantReason.green;
        } else if (st == SignalState.amber) {
          if (!canStop) {
            // It goes; only a crossing still occupied can hold it now.
            return _clear(c) ? GrantReason.amberDilemma : GrantReason.none;
          }
          if (_isLeft(c) && dist <= kAtLineM && v < kRestMps && _clear(c)) {
            return GrantReason.amberLeftClear;
          }
          return GrantReason.none;
        } else {
          return GrantReason.none;
        }
      }
    }

    // A stop sign: come to rest at the line first. At an all-way stop, that
    // also takes a place in the arrival queue.
    final allWay = kind == _allWay;
    if (allWay || (kind == _stop && road && ctl.edgeStops[from] == 1)) {
      if (t.flags[slot] & kHalted == 0) {
        if (dist > kAtLineM || v >= kRestMps) return GrantReason.none;
        t.flags[slot] |= kHalted;
      }
      if (allWay &&
          t.flags[slot] & kInFifo == 0 &&
          !_join(slot, c, node, nowUs)) {
        return GrantReason.none;
      }
      ok = allWay ? GrantReason.allWayTurn : GrantReason.gap;
    }

    // Safety: never into a crossing still occupied, under any control.
    if (!_clear(c)) return GrantReason.none;

    // Don't block the box: into a real junction only with room to leave it.
    if (AgentTuning.dontBlockBox &&
        isRealJunction(NodeControlKind.values[kind]) &&
        !_boxRoom(slot, c)) {
      return GrantReason.none;
    }

    // Courtesy: arrival order, gaps and merges — waived once it has waited
    // too long.
    final forced = t.waitUs[slot] > usOf(AgentTuning.impatientGrantS);
    var waived = false;
    if (allWay && !_firstInQueue(slot, c, node)) {
      if (!forced) return GrantReason.none;
      waived = true;
    }
    if (_mustYield(c, kind, from)) {
      if (!forced) return GrantReason.none;
      waived = true;
    }
    if (lg.conRole[c] == _mergeYield && !_mergeRoom(slot, c, v)) {
      if (!forced) return GrantReason.none;
      waived = true;
    }
    return waived ? GrantReason.forced : ok;
  }

  // ---- Crossings ----------------------------------------------------------------

  /// Whether every connector crossing [c] is clear short of its crossing
  /// point: the one rule nothing waives.
  bool _clear(int c) {
    final lg = graph;
    for (var i = lg.conConflictStart[c]; i < lg.conConflictStart[c + 1]; i++) {
      if (_occupied(lg.conflictWith[i], lg.conflictAtOther[i])) return false;
    }
    return true;
  }

  /// Whether some vehicle is on connector [d] — or cleared into it, or just
  /// out of it with its tail still on it — short of [at] metres along it.
  bool _occupied(int d, double at) {
    if (_claims[d] > 0) return true;
    final lg = graph, t = table;
    // The last vehicle on it has the rearmost tail.
    final tail = t.elemTail[lg.laneCount + d];
    if (tail >= 0 && t.s[tail] - t.len[tail] < at) return true;
    final h = _leaver[d];
    if (h >= 0 && t.isLive(h)) {
      final sl = SlotPool.slotOf(h);
      if (lg.conLen[d] + (t.odo[sl] - _leaverOdo[d]) - t.len[sl] < at) {
        return true;
      }
    }
    return false;
  }

  /// Whether connectors [c] and [d] cross.
  bool _conflicts(int c, int d) {
    final lg = graph;
    for (var i = lg.conConflictStart[c]; i < lg.conConflictStart[c + 1]; i++) {
      if (lg.conflictWith[i] == d) return true;
    }
    return false;
  }

  /// A left turn: it crosses the opposing carriageway.
  bool _isLeft(int c) {
    final lg = graph;
    final turn = lg.conTurn[c];
    return turn == _left ||
        turn == _uTurn ||
        (turn == _sharp && lg.conTheta[c] > 0);
  }

  /// Whether a vehicle about to take [c] must wait for a vehicle
  /// approaching some crossing connector with priority over it.
  bool _mustYield(int c, int kind, int from) {
    final lg = graph;
    for (var i = lg.conConflictStart[c]; i < lg.conConflictStart[c + 1]; i++) {
      final d = lg.conflictWith[i];
      final gap = _yieldGap(c, d, kind, from);
      if (gap > 0 && _approaching(d, gap)) return true;
    }
    return false;
  }

  /// The gap, seconds, a vehicle taking [c] (arriving along [from]) needs
  /// from traffic approaching [d] at a node of [kind]; 0 where [d] has no
  /// priority over it and the two simply take turns by occupancy.
  double _yieldGap(int c, int d, int kind, int from) {
    final lg = graph;
    final ctl = lg.controls;
    final other = lg.laneEdge[lg.conFromLane[d]];
    if (other == from) return 0;
    // A leg outside the junction's plan — an alley, a path — gives way to
    // every leg the plan was drawn over, whatever the control (§3.7).
    final drawnC = _drawn[from] == 1, drawnD = _drawn[other] == 1;
    if (drawnC != drawnD) return drawnC ? 0 : kOpposingGapS;
    final road = from < lg.roadEdgeCount && other < lg.roadEdgeCount;
    if (kind == _signals) {
      // The permissive left: it waits for the oncoming green.
      return road &&
              _isLeft(c) &&
              !_isLeft(d) &&
              ctl.edgePhase[from] == ctl.edgePhase[other]
          ? kOpposingGapS
          : 0;
    }
    if (kind == _stop) {
      final sc = road && ctl.edgeStops[from] == 1;
      final sd = road && ctl.edgeStops[other] == 1;
      if (sc && !sd) return kOpposingGapS;
      if (!sc && !sd && _isLeft(c) && !_isLeft(d)) return kOpposingGapS;
      return 0;
    }
    if (kind == _uncontrolled) {
      final rc = lg.edgeTier[from], rd = lg.edgeTier[other];
      if (rc != rd) return rc < rd ? kOpposingGapS : 0;
      if (_fromRight(from, other)) return kOpposingGapS;
      if (_isLeft(c) && !_isLeft(d)) return kOpposingGapS;
      return 0;
    }
    if (kind == _rampMerge) {
      return lg.conRole[c] == _mergeYield && lg.conRole[d] != _mergeYield
          ? kMergeGapS
          : 0;
    }
    if (kind == _continuation) {
      return lg.conRole[c] == _droppedLane && lg.conRole[d] != _droppedLane
          ? kZipperGapS
          : 0;
    }
    // All-way stops go by arrival, roundabouts by occupancy, turning places
    // by occupancy: none of them by gap.
    return 0;
  }

  /// Whether traffic arriving along [other] comes from the right of traffic
  /// arriving along [from]: it runs across [from]'s path from right to
  /// left.
  bool _fromRight(int from, int other) =>
      _arrE[from] * _arrN[other] - _arrN[from] * _arrE[other] > kFromRightSin;

  /// Whether a vehicle whose next connector is [d] is within [gap] seconds
  /// of its line.
  bool _approaching(int d, double gap) {
    final lg = graph, t = table;
    final lane = lg.conFromLane[d];
    final laneLen = lg.laneLength(lane);
    // Nothing further back than this can arrive in time.
    final reach = gap * (lg.edgeLimit[lg.laneEdge[lane]] * 1.2 + 1);
    final data = t.arena.data;
    for (var w = t.elemHead[lane]; w >= 0; w = t.next[w]) {
      final dist = laneLen - t.s[w];
      if (dist > reach) break;
      if (t.state[w] != _driving) continue;
      final i = t.routeCur[w] + 1;
      if (i >= t.routeLen[w] || data[t.routeOff[w] + i] != d) continue;
      final vw = t.v[w];
      if (dist / (vw > kEtaFloorMps ? vw : kEtaFloorMps) < gap) return true;
    }
    return false;
  }

  /// Don't block the box: the exit lane has room for [slot] and for
  /// everything already on the connector ahead of it — or its last vehicle
  /// is moving off.
  bool _boxRoom(int slot, int c) {
    final lg = graph, t = table;
    var need = t.len[slot] + VehicleKinds.jamM[t.kind[slot]];
    for (var w = t.elemHead[lg.laneCount + c]; w >= 0; w = t.next[w]) {
      need += t.len[w] + VehicleKinds.jamM[t.kind[w]];
    }
    final tail = t.elemTail[lg.conToLane[c]];
    if (tail < 0 || t.v[tail] > kBoxTailMovingMps) return true;
    return t.s[tail] - t.len[tail] >= need;
  }

  /// A ramp's merge: room behind the mainline's last vehicle — its jam gap
  /// plus its headway at [v].
  bool _mergeRoom(int slot, int c, double v) {
    final lg = graph, t = table;
    final tail = t.elemTail[lg.conToLane[c]];
    if (tail < 0) return true;
    final k = t.kind[slot];
    return t.s[tail] - t.len[tail] >=
        VehicleKinds.jamM[k] + v * VehicleKinds.headwayS[k];
  }

  // ---- All-way stops ------------------------------------------------------------

  /// Puts [slot] in [node]'s arrival queue, in (arrival, handle) order;
  /// false while the queue is full.
  bool _join(int slot, int c, int node, int nowUs) {
    final k = _awOf[node];
    if (k < 0) return true;
    final t = table;
    if (_fifoLen[k] >= _fifoCap) {
      _purge(k);
      if (_fifoLen[k] >= _fifoCap) return false;
    }
    final base = k * _fifoCap;
    final h = t.handleOf(slot);
    final us = nowUs.toDouble();
    var i = _fifoLen[k];
    while (i > 0) {
      final pu = _fifoUs[base + i - 1], ph = _fifoH[base + i - 1];
      if (pu < us || (pu == us && ph < h)) break;
      _fifoUs[base + i] = pu;
      _fifoH[base + i] = ph;
      _fifoC[base + i] = _fifoC[base + i - 1];
      i--;
    }
    _fifoUs[base + i] = us;
    _fifoH[base + i] = h;
    _fifoC[base + i] = c;
    _fifoLen[k]++;
    t.flags[slot] |= kInFifo;
    return true;
  }

  /// Whether no vehicle that arrived at [node] before [slot], and is still
  /// waiting, wants a connector crossing [c]. Movements that do not cross
  /// go together, in any order.
  bool _firstInQueue(int slot, int c, int node) {
    final k = _awOf[node];
    if (k < 0) return true;
    final t = table;
    final h = t.handleOf(slot);
    final base = k * _fifoCap;
    for (var i = 0; i < _fifoLen[k]; i++) {
      final o = _fifoH[base + i];
      if (o == h) return true;
      if (!t.isLive(o)) continue;
      final d = _fifoC[base + i];
      if (d == c || _conflicts(c, d)) return false;
    }
    return true;
  }

  /// Takes [slot] out of [node]'s queue.
  void _leaveQueue(int slot, int node) {
    final t = table;
    if (t.flags[slot] & kInFifo == 0) return;
    t.flags[slot] &= ~kInFifo;
    if (node < 0 || node >= _awOf.length) return;
    final k = _awOf[node];
    if (k < 0) return;
    final h = t.handleOf(slot);
    final base = k * _fifoCap;
    final n = _fifoLen[k];
    for (var i = 0; i < n; i++) {
      if (_fifoH[base + i] != h) continue;
      for (var j = i; j + 1 < n; j++) {
        _fifoH[base + j] = _fifoH[base + j + 1];
        _fifoC[base + j] = _fifoC[base + j + 1];
        _fifoUs[base + j] = _fifoUs[base + j + 1];
      }
      _fifoLen[k] = n - 1;
      return;
    }
  }

  /// Drops the entries of queue [k] whose vehicles are gone or no longer
  /// queued.
  void _purge(int k) {
    final t = table;
    final base = k * _fifoCap;
    var w = 0;
    for (var i = 0; i < _fifoLen[k]; i++) {
      final h = _fifoH[base + i];
      if (!t.isLive(h) || t.flags[SlotPool.slotOf(h)] & kInFifo == 0) continue;
      _fifoH[base + w] = h;
      _fifoC[base + w] = _fifoC[base + i];
      _fifoUs[base + w] = _fifoUs[base + i];
      w++;
    }
    _fifoLen[k] = w;
  }

  // ---- Passes ---------------------------------------------------------------------

  void _take(int slot, int c) {
    final t = table;
    if (t.pass[slot] >= 0) _drop(slot);
    t.pass[slot] = c;
    _claims[c]++;
  }

  void _drop(int slot) {
    final t = table;
    final c = t.pass[slot];
    if (c >= 0 && c < _claims.length && _claims[c] > 0) _claims[c]--;
    t.pass[slot] = -1;
  }

  /// [slot] has driven into connector [c]: its pass becomes its presence
  /// there, its queue place and its halt are spent, its wait is over.
  void entered(int slot, int c) {
    final t = table;
    if (t.pass[slot] >= 0) _drop(slot);
    _leaveQueue(slot, graph.conNode[c]);
    t.flags[slot] &= ~kHalted;
    t.waitUs[slot] = 0;
  }

  /// [slot]'s front has left connector [c], and its tail may not have: call
  /// it once the vehicle's `s` is its place on the lane beyond.
  void left(int slot, int c) {
    final t = table;
    _leaver[c] = t.handleOf(slot);
    _leaverOdo[c] = t.odo[slot] - t.s[slot];
  }

  /// Gives up everything [slot] holds here — its pass, its queue place, its
  /// halt: before it despawns, or when its route is replaced.
  void release(int slot) {
    final lg = _lg;
    final t = table;
    if (t.pass[slot] >= 0) _drop(slot);
    if (lg != null) {
      final el = t.elem[slot];
      final node = el >= 0 && el < lg.laneCount
          ? lg.edgeTo[lg.laneEdge[el]]
          : -1;
      _leaveQueue(slot, node);
    }
    t.flags[slot] &= ~(kHalted | kInFifo);
  }

  // ---- Access points (§5.5) ---------------------------------------------------

  /// Whether a vehicle of [kind], [len] metres long, may pull out of an
  /// access point into [lane] with its front at [at] lane metres.
  ///
  /// It needs a gap in every lane it crosses to get there: from the kerb in
  /// to its lane, or — pulling out of a building on the left of travel
  /// ([fromLeft]) — from the left kerb, having crossed every lane of the
  /// opposing carriageway, which must be clear with nothing arriving there
  /// inside [kOpposingGapS].
  bool canJoin(int lane, double at, double len, AgentKind kind,
      {bool fromLeft = false}) {
    final lg = graph;
    final e = lg.laneEdge[lane];
    final k = lg.laneIdx[lane];
    final n = lg.edgeLaneCount[e];
    final s0 = VehicleKinds.jamM[kind.index];
    final lo = fromLeft ? k : 0, hi = fromLeft ? n - 1 : k;
    for (var j = lo; j <= hi; j++) {
      if (!_laneRoom(lg.laneOf(e, j), at, len, s0)) return false;
    }
    final r = lg.edgeReverse[e];
    if (fromLeft && r >= 0) {
      final t = lg.edgeLen[e] - (lg.edgeLaneS0[e] + at);
      final atR = t - lg.edgeLaneS0[r];
      for (var j = 0; j < lg.edgeLaneCount[r]; j++) {
        if (!_crossingClear(lg.laneOf(r, j), atR, len)) return false;
      }
    }
    return true;
  }

  /// Room in [lane] for a vehicle [len] long with its front at [at]: the
  /// vehicle ahead [s0] clear of its front, and the one behind its own jam
  /// gap and headway clear of its tail.
  bool _laneRoom(int lane, double at, double len, double s0) {
    final t = table;
    for (var w = t.elemHead[lane]; w >= 0; w = t.next[w]) {
      final sw = t.s[w];
      if (sw >= at) {
        if (sw - t.len[w] - at < s0) return false;
        continue;
      }
      final k = t.kind[w];
      final need =
          VehicleKinds.jamM[k] + t.v[w] * VehicleKinds.headwayS[k];
      return at - len - sw >= need;
    }
    return true;
  }

  /// Whether [lane] is clear across the point [at], with nothing arriving
  /// there inside [kOpposingGapS].
  bool _crossingClear(int lane, double at, double len) {
    final t = table;
    for (var w = t.elemHead[lane]; w >= 0; w = t.next[w]) {
      final sw = t.s[w];
      if (sw - t.len[w] <= at + len && sw >= at - len) return false;
      if (sw < at) {
        final vw = t.v[w];
        return (at - sw) / (vw > kEtaFloorMps ? vw : kEtaFloorMps) >=
            kOpposingGapS;
      }
    }
    return true;
  }

  // ---- The wedge breaker (§5.8) ----------------------------------------------

  void _noteWaiting(int slot, int node) {
    final t = table;
    if (_wStamp[node] != _stamp) {
      _wStamp[node] = _stamp;
      _wCount[node] = 0;
      _wBest[node] = -1;
      _touched[_nTouched++] = node;
    }
    _wCount[node]++;
    final best = _wBest[node];
    if (best < 0 ||
        t.waitUs[slot] > t.waitUs[best] ||
        (t.waitUs[slot] == t.waitUs[best] &&
            t.handleOf(slot) < t.handleOf(best))) {
      _wBest[node] = slot;
    }
  }

  /// The handles to despawn this sub-step, into [out]: at every node where
  /// `wedgeHeads` approach heads have each waited past `wedgeWaitS`, the
  /// longest waiter (ties to the smaller handle). Returns how many.
  int wedgeVictims(Int32List out) {
    var n = 0;
    for (var i = 0; i < _nTouched && n < out.length; i++) {
      final node = _touched[i];
      if (_wCount[node] >= AgentTuning.wedgeHeads) {
        out[n++] = table.handleOf(_wBest[node]);
      }
    }
    return n;
  }
}
