// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The lane a vehicle drives on every edge of its route, fixed when the
/// route is planned (docs/plans/agent-traffic.md §4.5, §3.9 step 3).
///
/// Lanes change only at nodes, through connectors (§3.5), so a route is not
/// a list of edges but a list of connectors: `[firstLane, c₁, …, c_n]`, the
/// arena's format. This file turns the edge sequence the edge A* returns
/// into that list, for a trip that may choose its first lane — a new trip
/// leaving an access point, which acts as a node for lane choice (§5.5).
///
/// Two passes. Backwards, the lanes of each edge from which the rest of
/// the route can still be driven, and the least lane charge from each (the
/// connector's `conPen`: nothing for the lane a driver simply stays in or
/// a natural landing, half a lane for a lane add or drop, a lane per lane
/// shifted or landed away from the natural one). Forwards, the cheapest
/// start lane — the rightmost on a tie — and at each node the cheapest
/// landing, the emptiest lane on a tie. The connector rules make the
/// backward sets non-empty for any sequence the router returns, save one
/// known gap (a ramp's merge, which lands only in the kerb lane, followed by
/// a turn that needs another lane before any junction lets it change); the
/// planner answers "no" there, and the queue plans that trip by the state
/// search instead.
///
/// The same file holds the sticky repair a remap uses when an edit breaks a
/// connector a route relied on: it re-assigns lanes over the broken span
/// only, keeping every lane it can, and leaves every connector outside the
/// span exactly as planned.
///
/// Scratch is typed and reused, grown only when a longer route or a wider
/// graph arrives; neither pass allocates (§15.2).
library;

import 'dart:typed_data';

import 'lane_graph.dart';
import 'route_cost.dart';

/// How many vehicles are on each lane now: the forward pass's tie-break,
/// which spreads through traffic across lanes at plan time. Read, never
/// kept.
abstract interface class LaneLoad {
  int vehiclesOn(int lane);
}

/// Plans lanes for edge sequences ([plan]), and repairs them after an edit
/// ([repair]). The result is in [route], [routeLength] long.
class LanePlanner {
  /// The last plan or repair: `[firstLane, c₁, …]`.
  Int32List route = Int32List(64);
  int routeLength = 0;

  /// The lane charges (§4.5) the last [plan] chose.
  double penalty = 0;

  /// Whether the last [repair] had to change anything.
  bool repaired = false;

  LaneGraph? _lg;
  int _stride = 1;
  Float64List _cost = Float64List(0);
  Int32List _back = Int32List(0);
  Int32List _lane = Int32List(0);
  Int32List _con = Int32List(0);

  static const double _inf = double.infinity;

  /// Two lane charges this close are equal: they are sums of halves.
  static const double _tie = 1e-9;

  static bool _has(int mask, int lane) => (mask >> lane) & 1 != 0;

  /// Lanes for the [count] edges of [edges] on [lg], free to start in any
  /// lane of the first edge in [startMask] and to end in any lane of the
  /// last in [destMask] (lane masks by index, 0 the kerb lane). False when
  /// no assignment drives the sequence.
  bool plan(LaneGraph lg, Int32List edges, int count,
      {int startMask = kAllLanes, int destMask = kAllLanes, LaneLoad? load}) {
    routeLength = 0;
    penalty = 0;
    if (count <= 0) return false;
    _prepare(lg, count);
    final s = _stride;
    final cost = _cost;
    final last = count - 1;

    // Backwards: the least charge from each lane to the end, infinite where
    // the rest cannot be driven from it at all.
    var e = edges[last];
    var any = false;
    for (var j = 0; j < lg.edgeLaneCount[e]; j++) {
      final ok = _has(destMask, j);
      cost[last * s + j] = ok ? 0.0 : _inf;
      if (ok) any = true;
    }
    if (!any) return false;
    for (var i = last - 1; i >= 0; i--) {
      e = edges[i];
      final next = edges[i + 1];
      final nb = lg.edgeLaneBase[next], nn = lg.edgeLaneCount[next];
      final base = lg.edgeLaneBase[e];
      any = false;
      for (var j = 0; j < lg.edgeLaneCount[e]; j++) {
        final l = base + j;
        var best = _inf;
        for (var c = lg.laneConStart[l]; c < lg.laneConStart[l + 1]; c++) {
          final k = lg.conToLane[c] - nb;
          if (k < 0 || k >= nn) continue;
          final v = cost[(i + 1) * s + k];
          if (v == _inf) continue;
          final w = v + lg.conPen[c];
          if (w < best) best = w;
        }
        cost[i * s + j] = best;
        if (best < _inf) any = true;
      }
      if (!any) return false;
    }

    // Forwards: the cheapest start lane, the rightmost of equals.
    e = edges[0];
    var j0 = -1;
    var best = _inf;
    for (var j = 0; j < lg.edgeLaneCount[e]; j++) {
      if (!_has(startMask, j)) continue;
      final v = cost[j];
      if (v < best) {
        best = v;
        j0 = j;
      }
    }
    if (j0 < 0) return false;
    _ensureRoute(count);
    var l = lg.edgeLaneBase[e] + j0;
    route[0] = l;
    // At each node the cheapest landing; of equals the lane with fewest
    // vehicles on it, and of those the lower. A lane's connectors run in
    // lane order, so the first equal found is the lower.
    for (var i = 0; i < last; i++) {
      final next = edges[i + 1];
      final nb = lg.edgeLaneBase[next], nn = lg.edgeLaneCount[next];
      var bestV = _inf;
      for (var c = lg.laneConStart[l]; c < lg.laneConStart[l + 1]; c++) {
        final k = lg.conToLane[c] - nb;
        if (k < 0 || k >= nn) continue;
        final v = cost[(i + 1) * s + k];
        if (v == _inf) continue;
        final w = v + lg.conPen[c];
        if (w < bestV) bestV = w;
      }
      var pick = -1, pickLoad = 0;
      for (var c = lg.laneConStart[l]; c < lg.laneConStart[l + 1]; c++) {
        final k = lg.conToLane[c] - nb;
        if (k < 0 || k >= nn) continue;
        final v = cost[(i + 1) * s + k];
        if (v == _inf || v + lg.conPen[c] > bestV + _tie) continue;
        final ld = load == null ? 0 : load.vehiclesOn(lg.conToLane[c]);
        if (pick < 0 || ld < pickLoad) {
          pick = c;
          pickLoad = ld;
        }
      }
      route[i + 1] = pick;
      penalty += lg.conPen[pick];
      l = lg.conToLane[pick];
    }
    routeLength = count;
    return true;
  }

  /// A route over the [count] edges of [edges] on [lg] that keeps the
  /// planned lane index [want] on each edge wherever the graph still lets
  /// it, starting FIXED in lane `want[0]` of the first edge (the lane the
  /// vehicle is in) and ending in a lane of [destMask] (§3.9 step 3).
  ///
  /// Each planned connector that still exists is kept exactly. Where one is
  /// gone, the lanes are re-chosen over the shortest span that mends it:
  /// from the last kept connector before the break — reaching further back
  /// only when no assignment from there can mend it — to the first edge
  /// after it where the planned lane is reachable again and the plan's next
  /// connector exists. Inside the span a lane costs a second per lane away
  /// from the planned one, plus the connectors' §4.5 charges. False when no
  /// assignment exists with the first lane fixed: the route is impossible
  /// in lane terms, and must be planned afresh.
  bool repair(LaneGraph lg, Int32List edges, Int32List want, int count,
      {int destMask = kAllLanes}) {
    repaired = false;
    routeLength = 0;
    if (count <= 0) return false;
    _prepare(lg, count);
    final n0 = lg.edgeLaneCount[edges[0]];
    var k0 = want[0];
    if (k0 < 0) k0 = 0;
    if (k0 >= n0) k0 = n0 - 1;
    _lane[0] = k0;
    var pos = 0;
    while (pos < count - 1) {
      final c = _plannedStep(lg, edges, want, count, pos, destMask);
      if (c >= 0) {
        _con[pos] = c;
        _lane[pos + 1] = want[pos + 1];
        pos++;
        continue;
      }
      repaired = true;
      var end = -1;
      for (var a = pos; a >= 0 && end < 0; a--) {
        end = _span(lg, edges, want, count, a, pos, destMask);
      }
      if (end < 0) return false;
      pos = end;
    }
    if (count == 1 && !_has(destMask, _lane[0])) return false;
    _ensureRoute(count);
    route[0] = lg.edgeLaneBase[edges[0]] + _lane[0];
    for (var i = 0; i + 1 < count; i++) {
      route[i + 1] = _con[i];
    }
    routeLength = count;
    return true;
  }

  /// The planned connector out of position [pos] — from the lane held
  /// there to the planned lane of the next edge — or −1 where the graph
  /// lacks it, or where it would end the trip in a lane it may not end in.
  int _plannedStep(LaneGraph lg, Int32List edges, Int32List want, int count,
      int pos, int destMask) {
    final next = edges[pos + 1];
    final k = want[pos + 1];
    if (k < 0 || k >= lg.edgeLaneCount[next]) return -1;
    if (pos + 1 == count - 1 && !_has(destMask, k)) return -1;
    return lg.connector(
        lg.edgeLaneBase[edges[pos]] + _lane[pos], lg.edgeLaneBase[next] + k);
  }

  /// Re-chooses lanes from position [a], whose lane stays as held, to the
  /// first position past [pos] where the plan can resume; writes the span
  /// into the lane and connector scratch and returns where it ends, or −1
  /// when no position can be reached from [a].
  int _span(LaneGraph lg, Int32List edges, Int32List want, int count, int a,
      int pos, int destMask) {
    final s = _stride;
    final cost = _cost, back = _back;
    final na = lg.edgeLaneCount[edges[a]];
    for (var x = 0; x < na; x++) {
      cost[a * s + x] = x == _lane[a] ? 0.0 : _inf;
    }
    for (var j = a + 1; j < count; j++) {
      final prev = edges[j - 1], e = edges[j];
      final pb = lg.edgeLaneBase[prev], np = lg.edgeLaneCount[prev];
      final eb = lg.edgeLaneBase[e], ne = lg.edgeLaneCount[e];
      var kw = want[j];
      if (kw < 0) kw = 0;
      if (kw >= ne) kw = ne - 1;
      for (var x = 0; x < ne; x++) {
        cost[j * s + x] = _inf;
        back[j * s + x] = -1;
      }
      var any = false;
      for (var y = 0; y < np; y++) {
        final v0 = cost[(j - 1) * s + y];
        if (v0 == _inf) continue;
        final l = pb + y;
        for (var c = lg.laneConStart[l]; c < lg.laneConStart[l + 1]; c++) {
          final x = lg.conToLane[c] - eb;
          if (x < 0 || x >= ne) continue;
          final away = x > kw ? x - kw : kw - x;
          final v = v0 + lg.conPen[c] + away;
          if (v < cost[j * s + x]) {
            cost[j * s + x] = v;
            back[j * s + x] = c;
            any = true;
          }
        }
      }
      if (!any) return -1;
      if (j <= pos) continue;

      // Can the plan resume at j?
      var end = -1;
      if (j == count - 1) {
        var best = _inf;
        for (var x = 0; x < ne; x++) {
          if (!_has(destMask, x)) continue;
          final v = cost[j * s + x];
          if (v < best) {
            best = v;
            end = x;
          }
        }
      } else {
        final k = want[j];
        if (k >= 0 && k < ne && cost[j * s + k] < _inf) {
          final nx = edges[j + 1];
          final kn = want[j + 1];
          final ok = kn >= 0 &&
              kn < lg.edgeLaneCount[nx] &&
              (j + 1 < count - 1 || _has(destMask, kn)) &&
              lg.connector(eb + k, lg.edgeLaneBase[nx] + kn) >= 0;
          if (ok) end = k;
        }
      }
      if (end < 0) continue;
      var x = end;
      for (var i = j; i > a; i--) {
        final c = back[i * s + x];
        _con[i - 1] = c;
        _lane[i] = x;
        x = lg.laneIdx[lg.conFromLane[c]];
      }
      return j;
    }
    return -1;
  }

  void _prepare(LaneGraph lg, int count) {
    if (!identical(lg, _lg)) {
      _lg = lg;
      var m = 1;
      for (var e = 0; e < lg.edgeCount; e++) {
        if (lg.edgeLaneCount[e] > m) m = lg.edgeLaneCount[e];
      }
      _stride = m;
    }
    final need = count * _stride;
    if (_cost.length < need) {
      _cost = Float64List(need * 2);
      _back = Int32List(need * 2);
    }
    if (_lane.length < count) {
      _lane = Int32List(count * 2);
      _con = Int32List(count * 2);
    }
  }

  void _ensureRoute(int count) {
    if (route.length < count) route = Int32List(count * 2);
  }
}
