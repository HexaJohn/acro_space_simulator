// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Plans that must start in the lane a vehicle is already in: an A* over
/// (edge, lane) states whose moves are the connectors themselves
/// (docs/plans/agent-traffic.md §4.5, D34).
///
/// A new trip may enter any lane of its first edge, and for it the connector
/// rules guarantee that every edge sequence can be driven (§3.5). A vehicle
/// already on the road has no such freedom. Held in the kerb lane of an
/// avenue, it cannot make the left the next node asks for — that lane turns
/// only right or goes straight on — and an edge sequence that turns left
/// there is one it cannot drive. So a plan from a fixed lane — a re-plan
/// after an edit broke the route (§3.9), a parking or service leg that
/// begins where the vehicle is — searches states, not edges: its only moves
/// are the connectors that really leave the lane it is in. Whatever it
/// returns can be driven, and when it finds nothing, there is nothing.
/// Rule 5's shifts are what widen its reach: straight on into the next lane
/// at one junction, then the left at the next; or a right and a block round.
///
/// The costs are the edge A*'s, §4.1, plus each connector's lane charge;
/// the heuristic is its too, at the end node of a state's edge. Each state
/// expansion spends one expansion of the path budget, and a search resumes
/// across sub-steps exactly as the edge A* does. Its scratch is sized to the
/// lane count — two to three times the edges — which is why new trips, the
/// great majority, do not use it.
///
/// Its answer is the route itself, `[firstLane, c₁, …, c_n]`: the lanes are
/// locked by construction.
library;

import 'dart:typed_data';

import 'agent_kind.dart';
import 'route_cost.dart';

/// The (edge, lane) A*. Begin it with [begin], then [step] it with budgets
/// of expansions until it is no longer [SearchStatus.running].
class LaneStateSearch {
  RouteCost? _cost;
  Float64List _g = Float64List(0);

  /// The connector into each lane on its best route so far; −1 at a start.
  Int32List _parent = Int32List(0);
  Int32List _stamp = Int32List(0);
  Int32List _origin = Int32List(0);

  /// Per edge: the generation in which it holds a goal.
  Int32List _goalAt = Int32List(0);
  int _gen = 0;
  final SearchHeap _heap = SearchHeap();
  final PathEnds _ends = PathEnds();
  Float64List _goalPt = Float64List(8);
  bool _heavy = false;
  bool _useH = true;
  Float32List? _delays;

  SearchStatus _status = SearchStatus.idle;
  double _best = double.infinity;
  int _bestCon = -1;
  int _bestGoal = -1;
  int _bestOrigin = -1;
  int _bestLane = -1;
  Int32List _route = Int32List(0);
  int _routeLength = 0;

  /// Expansions this search has made in all, and in its last [step].
  int expansions = 0;
  int lastStepExpansions = 0;

  static const int _direct = -2;
  static const int _genLimit = 0x3FFFFFFF;

  SearchStatus get status => _status;
  PathEnds get ends => _ends;
  Float32List? get delays => _delays;

  /// The route found: `[firstLane, c₁, …]`.
  Int32List get route => _route;
  int get routeLength => _routeLength;

  /// Its cost in seconds, lane charges included.
  double get cost => _best;

  /// Which of [ends]' goals and origins it joins, and where on them.
  int get goalIndex => _bestGoal;
  int get originIndex => _bestOrigin;
  double get goalT => _bestGoal < 0 ? 0 : _ends.goalT[_bestGoal];
  double get originT => _bestOrigin < 0 ? 0 : _ends.originT[_bestOrigin];

  /// Starts a search on [cost]'s graph between [ends], for a vehicle of
  /// [kind], pricing each edge's measured delay from [delays] (null: none).
  /// An origin with a lane starts in that lane only; one without, in every
  /// lane of its edge. A goal is met only in a lane of its mask.
  /// [heuristic] false makes it Dijkstra, for the tests that check A*.
  void begin(RouteCost cost, PathEnds ends,
      {AgentKind kind = AgentKind.car,
      Float32List? delays,
      bool heuristic = true}) {
    _bind(cost);
    final lg = cost.lg;
    if (++_gen >= _genLimit) {
      _stamp.fillRange(0, _stamp.length, 0);
      _goalAt.fillRange(0, _goalAt.length, 0);
      _gen = 1;
    }
    _heap.clear();
    _best = double.infinity;
    _bestCon = _bestGoal = _bestOrigin = _bestLane = -1;
    _routeLength = 0;
    expansions = lastStepExpansions = 0;
    _heavy = paysMinorSurcharge(kind);
    _useH = heuristic;
    _delays = delays;
    _ends.copyFrom(ends);

    final nG = _ends.goalCount;
    if (_goalPt.length < 2 * nG) _goalPt = Float64List(4 * nG);
    for (var k = 0; k < nG; k++) {
      final e = _ends.goalEdge[k];
      final t = _clampT(cost, e, _ends.goalT[k]);
      _ends.goalT[k] = t;
      _goalAt[e] = _gen;
      cost.pointAt(e, t, _goalPt, 2 * k);
    }

    for (var k = 0; k < _ends.originCount; k++) {
      final e = _ends.originEdge[k];
      final t = _clampT(cost, e, _ends.originT[k]);
      _ends.originT[k] = t;
      final fixed = _ends.originLane[k];
      if (fixed >= 0 && lg.laneEdge[fixed] != e) continue;
      final lo = fixed >= 0 ? fixed : lg.edgeLaneBase[e];
      final hi = fixed >= 0 ? fixed + 1 : lo + lg.edgeLaneCount[e];
      final g0 = cost.partialCost(e, lg.edgeLen[e] - t, delays);
      for (var l = lo; l < hi; l++) {
        // A goal further along the edge, in this lane: no node to cross.
        if (_goalAt[e] == _gen) {
          final kl = lg.laneIdx[l];
          for (var j = 0; j < nG; j++) {
            if (_ends.goalEdge[j] != e || _ends.goalT[j] < t) continue;
            if ((_ends.goalMask[j] >> kl) & 1 == 0) continue;
            final c = cost.partialCost(e, _ends.goalT[j] - t, delays);
            if (c < _best) {
              _best = c;
              _bestCon = _direct;
              _bestLane = l;
              _bestGoal = j;
              _bestOrigin = k;
            }
          }
        }
        if (_stamp[l] != _gen || g0 < _g[l]) {
          _stamp[l] = _gen;
          _g[l] = g0;
          _parent[l] = -1;
          _origin[l] = k;
          _heap.push(l, g0 + _h(cost, e), g0);
        }
      }
    }
    _status = SearchStatus.running;
  }

  /// Runs up to [budget] state expansions. Stops early when done; the result
  /// is the same for any split of the work into budgets.
  SearchStatus step(int budget) {
    lastStepExpansions = 0;
    if (_status != SearchStatus.running) return _status;
    final cost = _cost!;
    var used = 0;
    while (true) {
      if (_heap.isEmpty || _heap.topF >= _best) {
        _finish(cost);
        break;
      }
      if (used >= budget) break;
      final l = _heap.topId, gl = _heap.topG;
      _heap.pop();
      used++;
      if (gl > _g[l]) continue; // superseded by a cheaper arrival
      _expand(cost, l, gl);
    }
    expansions += used;
    lastStepExpansions = used;
    return _status;
  }

  /// Drops the search: [status] goes back to idle.
  void abort() => _status = SearchStatus.idle;

  void _expand(RouteCost cost, int l, double gl) {
    final lg = cost.lg;
    final conCost = cost.conCost;
    for (var c = lg.laneConStart[l]; c < lg.laneConStart[l + 1]; c++) {
      final l2 = lg.conToLane[c];
      final o = lg.laneEdge[l2];
      final base = gl + conCost[c];
      if (_goalAt[o] == _gen) {
        final k2 = lg.laneIdx[l2];
        for (var k = 0; k < _ends.goalCount; k++) {
          if (_ends.goalEdge[k] != o) continue;
          if ((_ends.goalMask[k] >> k2) & 1 == 0) continue;
          final cand = base + cost.partialCost(o, _ends.goalT[k], _delays);
          if (cand < _best) {
            _best = cand;
            _bestCon = c;
            _bestGoal = k;
          }
        }
      }
      final gn = base + cost.fullCost(o, _heavy, _delays);
      if (_stamp[l2] != _gen || gn < _g[l2]) {
        _stamp[l2] = _gen;
        _g[l2] = gn;
        _parent[l2] = c;
        _heap.push(l2, gn + _h(cost, o), gn);
      }
    }
  }

  void _finish(RouteCost cost) {
    if (_best == double.infinity) {
      _status = SearchStatus.noPath;
      return;
    }
    _status = SearchStatus.found;
    if (_bestCon == _direct) {
      _route[0] = _bestLane;
      _routeLength = 1;
      return;
    }
    final lg = cost.lg;
    var n = 1;
    var lane = lg.conFromLane[_bestCon];
    while (_parent[lane] >= 0) {
      n++;
      lane = lg.conFromLane[_parent[lane]];
    }
    if (_route.length < n + 1) _route = Int32List(2 * (n + 1));
    _route[0] = lane;
    _bestOrigin = _origin[lane];
    var i = n;
    var c = _bestCon;
    while (c >= 0) {
      _route[i--] = c;
      c = _parent[lg.conFromLane[c]];
    }
    _routeLength = n + 1;
  }

  /// The heuristic of a state: from the end of its lane's [edge].
  double _h(RouteCost cost, int edge) =>
      _useH ? cost.heuristic(edge, _goalPt, _ends.goalCount) : 0.0;

  static double _clampT(RouteCost cost, int edge, double t) {
    final len = cost.lg.edgeLen[edge];
    return t < 0 ? 0.0 : (t > len ? len : t);
  }

  void _bind(RouteCost cost) {
    if (identical(cost, _cost)) return;
    _cost = cost;
    final nL = cost.lg.laneCount, nE = cost.lg.edgeCount;
    // Fresh stamps are 0, and the generation is never 0 once a search has
    // begun, so a new array reads as unstamped with no reset — and an array
    // kept keeps only stamps older than the next generation.
    if (_g.length < nL) {
      _g = Float64List(nL);
      _parent = Int32List(nL);
      _stamp = Int32List(nL);
      _origin = Int32List(nL);
    }
    if (_goalAt.length < nE) _goalAt = Int32List(nE);
    if (_route.length < nL + 2) _route = Int32List(nL + 2);
  }
}
