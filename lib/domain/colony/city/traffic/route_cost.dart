// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a route costs, in seconds (docs/plans/agent-traffic.md §4.1, §4.3),
/// and the parts every search shares: where it starts and may stop
/// ([PathEnds]), its open list ([SearchHeap]) and how it stands
/// ([SearchStatus]).
///
/// One price list for every planner — the edge A* (`SearchContext`), the
/// (edge, lane) state search (`LaneStateSearch`) and, from slice 2, the
/// delay table, whose observations subtract [junctionPenaltyS] as the
/// control delay a route already pays, so that no wait is charged twice. It
/// has a file of its own so that the delay table can read the penalties
/// without pulling in the queue.
///
/// A route of edges e₁…e_k across nodes n₁…n_{k−1} costs
///
///     C = Σ_i [ len(e_i)/limit(e_i) · wType(e_i) · wVeh + D_i ]
///       + Σ_j [ J(n_j) + T(turn_j) ]
///
/// with the first and last edges charged only for the part driven. `D` is
/// the measured delay each edge had when the search began: the slice-2
/// seam. A search is handed the published delay buffer, or null, and null
/// prices every edge at D = 0 — slice 1's free-flow routing.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import 'agent_kind.dart';
import 'lane_connectors.dart';
import 'lane_graph.dart';
import 'node_control.dart';

// ---- J: entering a node, by its control and the leg's role (seconds) ------

/// A leg that gives way without stopping: a ramp at its merge, and — the
/// design's table being silent on it — a lower-ranked leg at a node the
/// warrant left without a plan.
const double kYieldPenaltyS = 1.5;

/// A leg that must come to rest at the line: a stop plan's stop leg, and
/// every leg of an all-way stop.
const double kStopPenaltyS = 5.0;

/// A stop plan's leg that does not stop: it slows, and looks.
const double kPriorityPenaltyS = 0.5;

/// A light: the expected red wait over a 32 s cycle, plus the start-up.
const double kSignalPenaltyS = 6.0;

const double kRoundaboutPenaltyS = 3.0;

/// Turning round where the road ends: dear, so that a car turns round only
/// where nothing else takes it the way it wants to go.
const double kTurnRoundPenaltyS = 20.0;

// ---- T: the turn (seconds) ----------------------------------------------------

const double kRightTurnS = 2.0;
const double kLeftTurnS = 4.0;

/// What a left turn adds where no light holds the oncoming traffic for it.
const double kUnprotectedLeftS = 3.0;

const double kSharpTurnS = 6.0;

/// A U-turn anywhere a road does not end — a roundabout, the only such
/// place the connector rules allow one.
const double kUTurnS = 20.0;

/// wVeh: what a metre of minor road costs a lorry over a car, so trucks keep
/// to the arterials — except on the street they start or end on, where
/// there is no choosing.
const double kHeavyMinorFactor = 1.5;

/// A lane mask with every lane in it.
const int kAllLanes = -1;

/// J: what entering a node of [kind] costs a vehicle whose arriving leg
/// [stops] or [yields] there (`NodeControls.edgeStops`, `edgeYields`).
///
/// It is DEFINED as the control delay such a node is expected to cost, so
/// the delay table (slice 2) subtracts it from what it measures: a light's
/// wait is priced here once, and never again in `D`.
double junctionPenaltyS(NodeControlKind kind,
        {bool stops = false, bool yields = false}) =>
    switch (kind) {
      NodeControlKind.continuation => 0.0,
      NodeControlKind.rampMerge ||
      NodeControlKind.uncontrolled =>
        yields ? kYieldPenaltyS : 0.0,
      NodeControlKind.stop => stops ? kStopPenaltyS : kPriorityPenaltyS,
      NodeControlKind.allWayStop => kStopPenaltyS,
      NodeControlKind.signals => kSignalPenaltyS,
      NodeControlKind.roundabout => kRoundaboutPenaltyS,
      // The only way on from a turning place is round.
      NodeControlKind.deadEnd ||
      NodeControlKind.stub ||
      NodeControlKind.danglingDeck =>
        kTurnRoundPenaltyS,
    };

/// T: what a movement of [turn] costs at a node of [kind].
double turnPenaltyS(TurnClass turn, NodeControlKind kind) => switch (turn) {
      TurnClass.straight => 0.0,
      TurnClass.right => kRightTurnS,
      TurnClass.left => kind == NodeControlKind.signals
          ? kLeftTurnS
          : kLeftTurnS + kUnprotectedLeftS,
      TurnClass.sharp => kSharpTurnS,
      // Where the road ends, turning round is the node's own penalty.
      TurnClass.uTurn => isTurningPlace(kind) ? 0.0 : kUTurnS,
    };

/// Whether a vehicle of [kind] pays [kHeavyMinorFactor] on minor roads.
bool paysMinorSurcharge(AgentKind kind) =>
    kind == AgentKind.truck ||
    kind == AgentKind.semi ||
    kind == AgentKind.deliveryVan;

/// The prices of one [LaneGraph], worked out once when the graph is
/// installed. Every search on that graph reads these arrays and nothing
/// else, so its inner loop is a few array reads per movement.
///
/// A graph whose controls were refreshed (a light switched on) is a new
/// `LaneGraph` object and gets a new [RouteCost]: J follows the controls.
class RouteCost {
  RouteCost._(this.lg, this.edgePerM, this.edgeTime, this.moveCost,
      this.conCost, this.edgeEndE, this.edgeEndN, this.hPerM);

  /// The prices of [lg].
  factory RouteCost(LaneGraph lg) {
    final nE = lg.edgeCount, nC = lg.connectorCount;
    final perM = Float64List(nE), time = Float64List(nE);
    var hPerM = double.infinity;
    for (var e = 0; e < nE; e++) {
      final limit = lg.edgeLimit[e];
      final p = limit > 0 ? lg.edgeWType[e] / limit : 0.0;
      perM[e] = p;
      time[e] = lg.edgeLen[e] * p;
      if (p < hPerM) hPerM = p;
    }
    if (hPerM.isInfinite) hPerM = 0;

    // Where each edge starts and ends. A node is the mean of the road ends
    // that meet there (and of any dead end attached part way along a road),
    // so the edge a route leaves may end metres from where the next begins.
    final startE = Float64List(nE), startN = Float64List(nE);
    final endE = Float64List(nE), endN = Float64List(nE);
    final pt = Float64List(2);
    for (var e = 0; e < nE; e++) {
      if (e < lg.roadEdgeCount) {
        pointOn(lg, e, 0.0, pt, 0);
        startE[e] = pt[0];
        startN[e] = pt[1];
        pointOn(lg, e, lg.edgeLen[e], pt, 0);
        endE[e] = pt[0];
        endN[e] = pt[1];
      } else {
        // An outside connection's sink edge (slice 8) is no road: its ends
        // are its nodes.
        final a = lg.graph.nodes[lg.edgeFrom[e]].at;
        final b = lg.graph.nodes[lg.edgeTo[e]].at;
        startE[e] = a.e;
        startN[e] = a.n;
        endE[e] = b.e;
        endN[e] = b.n;
      }
    }

    // J + T of every movement, read off the controls the graph carries —
    // and never less than the straight-line time of the gap the route jumps
    // across the node, from the end of one edge to the start of the next.
    // The heuristic is measured from each edge's own end, and it is a lower
    // bound only while every such gap is paid for: where the ends of a
    // continuation lie metres apart and J + T is 0, that gap would be
    // ground a route covers for nothing, and A* would stop short (§4.3).
    final ctl = lg.controls;
    final moves = Float64List(lg.moveOut.length);
    for (var e = 0; e < nE; e++) {
      final kind = lg.kindOf(lg.edgeTo[e]);
      final road = e < ctl.edgeStops.length;
      final j = junctionPenaltyS(kind,
          stops: road && ctl.edgeStops[e] == 1,
          yields: road && ctl.edgeYields[e] == 1);
      for (var i = lg.moveStart[e]; i < lg.moveStart[e + 1]; i++) {
        final o = lg.moveOut[i];
        final de = startE[o] - endE[e], dn = startN[o] - endN[e];
        final gap = math.sqrt(de * de + dn * dn) * hPerM;
        final m = j + turnPenaltyS(TurnClass.values[lg.moveTurn[i]], kind);
        moves[i] = m > gap ? m : gap;
      }
    }
    // A connector costs its movement plus the lane planner's charge for
    // the lanes it joins (§4.5): the state search's whole transition.
    final cons = Float64List(nC);
    for (var c = 0; c < nC; c++) {
      final e = lg.conFromEdge(c), o = lg.conToEdge(c);
      var m = 0.0;
      for (var i = lg.moveStart[e]; i < lg.moveStart[e + 1]; i++) {
        if (lg.moveOut[i] == o) {
          m = moves[i];
          break;
        }
      }
      cons[c] = m + lg.conPen[c];
    }

    return RouteCost._(lg, perM, time, moves, cons, endE, endN, hPerM);
  }

  final LaneGraph lg;

  /// Seconds per metre of each edge for a car: `wType / limit`.
  final Float64List edgePerM;

  /// Seconds the whole of each edge costs a car: `len · wType / limit`.
  final Float64List edgeTime;

  /// J + T of each movement (`LaneGraph.moveOut` order).
  final Float64List moveCost;

  /// J + T of each connector's movement, plus its lane charge (§4.5).
  final Float64List conCost;

  /// Where each edge ends, colony metres: what the heuristic measures from.
  final Float64List edgeEndE, edgeEndN;

  /// The least any metre of this network costs: the heuristic's rate. Read
  /// off the graph rather than fixed at the design's 1/29.9 s/m (100 km/h
  /// over the limited-access weight): it is the tightest rate that is still
  /// a lower bound — a street-only town gets a sharper heuristic — and it
  /// stays one if the catalogue ever gains a faster road, where a fixed rate
  /// would overestimate and A* would stop returning the cheapest route.
  final double hPerM;

  static final int _minorRank = RoadTier.minor.rank;

  /// Seconds to drive the whole of [edge]: its time, a lorry's surcharge
  /// on a minor road when [heavy], and its measured delay from [delays]
  /// (null: none).
  double fullCost(int edge, bool heavy, Float32List? delays) {
    var c = edgeTime[edge];
    if (heavy && lg.edgeTier[edge] == _minorRank) c *= kHeavyMinorFactor;
    if (delays != null) c += delays[edge];
    return c;
  }

  /// Seconds to drive [metres] of [edge] — the first or the last edge of a
  /// route, which pay for the part driven and no lorry surcharge (§4.1).
  double partialCost(int edge, double metres, Float32List? delays) {
    final m = metres > 0 ? metres : 0.0;
    var c = m * edgePerM[edge];
    if (delays != null) {
      final len = lg.edgeLen[edge];
      if (len > 0) c += delays[edge] * (m / len);
    }
    return c;
  }

  /// A lower bound on the seconds from the END of [edge] to the nearest of
  /// [count] goals (east, north pairs in [goals]): the straight line at the
  /// network's cheapest rate. No penalty enters it, and it never
  /// overestimates (§4.3): every edge costs at least its chord at that rate,
  /// and every movement at least the gap it jumps across its node
  /// ([moveCost]) — so it is consistent, too.
  double heuristic(int edge, Float64List goals, int count) {
    final e = edgeEndE[edge], n = edgeEndN[edge];
    var best = double.infinity;
    for (var k = 0; k < count; k++) {
      final de = goals[2 * k] - e, dn = goals[2 * k + 1] - n;
      final d2 = de * de + dn * dn;
      if (d2 < best) best = d2;
    }
    if (best == double.infinity) return 0;
    return math.sqrt(best) * hPerM;
  }

  /// Where travel arc [t] along [edge] lies: east into `out[at]`, north
  /// into `out[at + 1]`. No allocation.
  void pointAt(int edge, double t, Float64List out, [int at = 0]) =>
      pointOn(lg, edge, t, out, at);

  /// [pointAt] for any lane graph.
  static void pointOn(
      LaneGraph lg, int edge, double t, Float64List out, int at) {
    final rec = lg.graph.roadRecs[lg.edgeRoad[edge]];
    final s = lg.roadArc(edge, t);
    final cum = rec.cum;
    final nS = rec.sampleCount;
    var lo = 0, hi = nS;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] < s) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var i = lo;
    if (i < 1) i = 1;
    if (i > nS - 1) i = nS - 1;
    final seg = cum[i] - cum[i - 1];
    var u = seg <= 1e-12 ? 0.0 : (s - cum[i - 1]) / seg;
    if (u < 0) {
      u = 0;
    } else if (u > 1) {
      u = 1;
    }
    out[at] = rec.e[i - 1] + (rec.e[i] - rec.e[i - 1]) * u;
    out[at + 1] = rec.n[i - 1] + (rec.n[i] - rec.n[i - 1]) * u;
  }
}

/// Where a search may start and where it may stop, on the graph it runs on
/// (§4.4): the origin's serving edges, each at the travel arc it is left
/// from, and the destination's, each at the arc it is reached at.
///
/// An origin may fix its lane — a vehicle already on the road re-planning
/// from the lane it is in — and a goal may say which lanes it can be
/// reached from (a lane mask by index, 0 the kerb lane: the kerb for a
/// building on the right, the innermost lane for one across the road).
/// Reused, never reallocated once warm.
class PathEnds {
  int originCount = 0;
  int goalCount = 0;

  /// Origin k: its edge, its lane id or −1 for any lane of the edge, and the
  /// travel arc (metres from the edge's start) it sets off from.
  Int32List originEdge = Int32List(4);
  Int32List originLane = Int32List(4);
  Float64List originT = Float64List(4);

  /// Goal k: its edge, the lanes (by index) it may be reached in, and the
  /// travel arc it is reached at.
  Int32List goalEdge = Int32List(4);
  Int32List goalMask = Int32List(4);
  Float64List goalT = Float64List(4);

  void clear() {
    originCount = 0;
    goalCount = 0;
  }

  void addOrigin(int edge, double t, {int lane = -1}) {
    if (originCount == originEdge.length) {
      originEdge = _grownI(originEdge);
      originLane = _grownI(originLane);
      originT = _grownD(originT);
    }
    originEdge[originCount] = edge;
    originLane[originCount] = lane;
    originT[originCount] = t;
    originCount++;
  }

  void addGoal(int edge, double t, {int laneMask = kAllLanes}) {
    if (goalCount == goalEdge.length) {
      goalEdge = _grownI(goalEdge);
      goalMask = _grownI(goalMask);
      goalT = _grownD(goalT);
    }
    goalEdge[goalCount] = edge;
    goalMask[goalCount] = laneMask;
    goalT[goalCount] = t;
    goalCount++;
  }

  /// Becomes a copy of [other].
  void copyFrom(PathEnds other) {
    if (identical(other, this)) return;
    clear();
    for (var k = 0; k < other.originCount; k++) {
      addOrigin(other.originEdge[k], other.originT[k],
          lane: other.originLane[k]);
    }
    for (var k = 0; k < other.goalCount; k++) {
      addGoal(other.goalEdge[k], other.goalT[k],
          laneMask: other.goalMask[k]);
    }
  }

  static Int32List _grownI(Int32List a) =>
      Int32List(a.length * 2)..setRange(0, a.length, a);
  static Float64List _grownD(Float64List a) =>
      Float64List(a.length * 2)..setRange(0, a.length, a);
}

/// Where a search stands.
enum SearchStatus {
  /// Nothing begun.
  idle,

  /// Begun, and stopped at the end of its budget: step it again.
  running,

  /// Done: the cheapest route is ready.
  found,

  /// Done: no route joins the ends.
  noPath,
}

/// A search's open list: a binary heap on three parallel typed columns,
/// ordered by (f, g, id) — a total order, so which of two routes of equal
/// cost a search returns depends on the network and nothing else (§4.3).
/// It grows by doubling, only while warming up.
class SearchHeap {
  SearchHeap([int capacity = 256])
      : _id = Int32List(capacity),
        _f = Float64List(capacity),
        _g = Float64List(capacity);

  Int32List _id;
  Float64List _f, _g;
  int _n = 0;

  int get length => _n;
  bool get isEmpty => _n == 0;

  /// The first entry: its id, its f (cost so far plus the heuristic) and
  /// its g (cost so far).
  int get topId => _id[0];
  double get topF => _f[0];
  double get topG => _g[0];

  void clear() => _n = 0;

  static bool _before(
          double fa, double ga, int ia, double fb, double gb, int ib) =>
      fa < fb || (fa == fb && (ga < gb || (ga == gb && ia < ib)));

  void push(int id, double f, double g) {
    if (_n == _id.length) _grow();
    var i = _n++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (!_before(f, g, id, _f[p], _g[p], _id[p])) break;
      _id[i] = _id[p];
      _f[i] = _f[p];
      _g[i] = _g[p];
      i = p;
    }
    _id[i] = id;
    _f[i] = f;
    _g[i] = g;
  }

  /// Removes the first entry.
  void pop() {
    final n = --_n;
    if (n <= 0) {
      _n = 0;
      return;
    }
    final id = _id[n], f = _f[n], g = _g[n];
    var i = 0;
    while (true) {
      var c = 2 * i + 1;
      if (c >= n) break;
      if (c + 1 < n &&
          _before(_f[c + 1], _g[c + 1], _id[c + 1], _f[c], _g[c], _id[c])) {
        c++;
      }
      if (!_before(_f[c], _g[c], _id[c], f, g, id)) break;
      _id[i] = _id[c];
      _f[i] = _f[c];
      _g[i] = _g[c];
      i = c;
    }
    _id[i] = id;
    _f[i] = f;
    _g[i] = g;
  }

  void _grow() {
    final cap = _id.length * 2;
    _id = Int32List(cap)..setRange(0, _n, _id);
    _f = Float64List(cap)..setRange(0, _n, _f);
    _g = Float64List(cap)..setRange(0, _n, _g);
  }
}
