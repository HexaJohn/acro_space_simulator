// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a route goes: the edge A* every new trip is planned by, and the
/// budgeted queue every plan waits its turn in (docs/plans/agent-traffic.md
/// §4.3, §4.4, §4.8).
///
/// Routing happens once, at spawn (§4.6). A search is resumable: its open
/// list and its scratch live in its [SearchContext], so a search that uses
/// up its share of a sub-step's budget stops where it is and carries on at
/// the next sub-step. The route it returns is the same whatever the budget,
/// because the budget decides only WHEN expansions run, never which — and it
/// is counted in expansions, never in microseconds (D9), so no result
/// depends on the machine it ran on.
///
/// The scratch is stamped by generation, so beginning a search clears
/// nothing; it is sized to the graph, and reallocated only when a graph
/// larger than any before arrives. Nothing in [SearchContext.step] or
/// [PathQueue.pump] allocates once warm (§15.2).
///
/// A new trip is planned in two passes (§4.5): this edge A* finds the
/// cheapest sequence of directed edges, and the lane pass (`LanePlanner`)
/// then fixes a lane on each. A plan that must start in the lane a vehicle
/// is already in runs the (edge, lane) state search (`LaneStateSearch`)
/// instead, which only ever expands real connectors.
library;

import 'dart:typed_data';

import 'agent_kind.dart';
import 'lane_planner.dart';
import 'lane_state_search.dart';
import 'route_cost.dart';
import 'traffic_rng.dart';
import 'traffic_tuning.dart';

/// The edge A* (§4.3). A state is a directed edge, its cost the cost of
/// reaching the END of that edge; a move is a movement across the node
/// ahead, priced J + T, then the next edge. A goal is met part way along its
/// edge, and so is priced when the edge is entered rather than when it is
/// left.
///
/// Begin it with [begin], then [step] it with budgets of expansions until it
/// is no longer [SearchStatus.running]. The route is [path] — edge ids, the
/// first an origin's edge and the last a goal's — and its cost [cost].
class SearchContext {
  RouteCost? _cost;
  Float64List _g = Float64List(0);
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
  int _bestFrom = -1;
  int _bestGoal = -1;
  int _bestOrigin = -1;
  Int32List _path = Int32List(0);
  int _pathLength = 0;

  /// Expansions this search has made in all, and in its last [step].
  int expansions = 0;
  int lastStepExpansions = 0;

  /// [_bestFrom] for a goal met on the origin's own edge, ahead of it.
  static const int _direct = -2;
  static const int _genLimit = 0x3FFFFFFF;

  SearchStatus get status => _status;
  PathEnds get ends => _ends;

  /// The delay buffer this search prices by: the one current when it began.
  Float32List? get delays => _delays;

  /// The route found, as edge ids.
  Int32List get path => _path;
  int get pathLength => _pathLength;

  /// Its cost in seconds (§4.1).
  double get cost => _best;

  /// Which of [ends]' goals and origins it joins, and where on them.
  int get goalIndex => _bestGoal;
  int get originIndex => _bestOrigin;
  double get goalT => _bestGoal < 0 ? 0 : _ends.goalT[_bestGoal];
  double get originT => _bestOrigin < 0 ? 0 : _ends.originT[_bestOrigin];

  /// Starts a search on [cost]'s graph between [ends] for a vehicle of
  /// [kind] (lorries pay the minor-road surcharge), pricing each edge's
  /// measured delay from [delays] — the buffer published when the search
  /// began (§4.2), kept for its whole run; null prices every edge at D = 0.
  /// Lane masks and fixed lanes in [ends] are the lane pass's business, not
  /// this search's. [heuristic] false makes it Dijkstra, for the tests that
  /// check A* against it.
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
    _bestFrom = _bestGoal = _bestOrigin = -1;
    _pathLength = 0;
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
      final g0 = cost.partialCost(e, lg.edgeLen[e] - t, delays);
      // A goal further along the origin's own edge: no node to cross.
      if (_goalAt[e] == _gen) {
        for (var j = 0; j < nG; j++) {
          if (_ends.goalEdge[j] != e || _ends.goalT[j] < t) continue;
          final c = cost.partialCost(e, _ends.goalT[j] - t, delays);
          if (c < _best) {
            _best = c;
            _bestFrom = _direct;
            _bestGoal = j;
            _bestOrigin = k;
          }
        }
      }
      if (_stamp[e] != _gen || g0 < _g[e]) {
        _stamp[e] = _gen;
        _g[e] = g0;
        _parent[e] = -1;
        _origin[e] = k;
        _heap.push(e, g0 + _h(cost, e), g0);
      }
    }
    _status = SearchStatus.running;
  }

  /// Runs up to [budget] expansions. Stops early when done; the result is
  /// the same for any split of the work into budgets.
  ///
  /// Done means no open state can beat the best route found: the heuristic
  /// never overestimates, so the cheapest open state bounds every route not
  /// yet seen. A state met again more cheaply is opened again. On the price
  /// list alone the heuristic is consistent (`RouteCost.heuristic`) and that
  /// never happens; allowing it costs nothing, and keeps the search exact
  /// should a measured delay ever price an edge below its chord.
  SearchStatus step(int budget) {
    lastStepExpansions = 0;
    if (_status != SearchStatus.running) return _status;
    final cost = _cost!;
    var used = 0;
    while (true) {
      if (_heap.isEmpty || _heap.topF >= _best) {
        _finish();
        break;
      }
      if (used >= budget) break;
      final e = _heap.topId, ge = _heap.topG;
      _heap.pop();
      used++;
      if (ge > _g[e]) continue; // superseded by a cheaper arrival
      _expand(cost, e, ge);
    }
    expansions += used;
    lastStepExpansions = used;
    return _status;
  }

  /// Drops the search: [status] goes back to idle.
  void abort() => _status = SearchStatus.idle;

  void _expand(RouteCost cost, int e, double ge) {
    final lg = cost.lg;
    final moveOut = lg.moveOut;
    final moveCost = cost.moveCost;
    for (var i = lg.moveStart[e]; i < lg.moveStart[e + 1]; i++) {
      final o = moveOut[i];
      final base = ge + moveCost[i];
      if (_goalAt[o] == _gen) {
        for (var k = 0; k < _ends.goalCount; k++) {
          if (_ends.goalEdge[k] != o) continue;
          final cand = base + cost.partialCost(o, _ends.goalT[k], _delays);
          if (cand < _best) {
            _best = cand;
            _bestFrom = e;
            _bestGoal = k;
          }
        }
      }
      final gn = base + cost.fullCost(o, _heavy, _delays);
      if (_stamp[o] != _gen || gn < _g[o]) {
        _stamp[o] = _gen;
        _g[o] = gn;
        _parent[o] = e;
        _heap.push(o, gn + _h(cost, o), gn);
      }
    }
  }

  void _finish() {
    if (_best == double.infinity) {
      _status = SearchStatus.noPath;
      return;
    }
    _status = SearchStatus.found;
    final goal = _ends.goalEdge[_bestGoal];
    if (_bestFrom == _direct) {
      _path[0] = goal;
      _pathLength = 1;
      return;
    }
    var n = 1;
    var root = _bestFrom;
    for (var e = _bestFrom; e >= 0; e = _parent[e]) {
      n++;
      root = e;
    }
    if (_path.length < n) _path = Int32List(2 * n);
    _path[n - 1] = goal;
    var i = n - 2;
    for (var e = _bestFrom; e >= 0; e = _parent[e]) {
      _path[i--] = e;
    }
    _pathLength = n;
    _bestOrigin = _origin[root];
  }

  /// The heuristic of a state: from the end of its [edge].
  double _h(RouteCost cost, int edge) =>
      _useH ? cost.heuristic(edge, _goalPt, _ends.goalCount) : 0.0;

  static double _clampT(RouteCost cost, int edge, double t) {
    final len = cost.lg.edgeLen[edge];
    return t < 0 ? 0.0 : (t > len ? len : t);
  }

  void _bind(RouteCost cost) {
    if (identical(cost, _cost)) return;
    _cost = cost;
    final nE = cost.lg.edgeCount;
    // Fresh stamps are 0, and the generation is never 0 once a search has
    // begun, so a new array reads as unstamped with no reset — and an array
    // kept keeps only stamps older than the next generation.
    if (_g.length < nE) {
      _g = Float64List(nE);
      _parent = Int32List(nE);
      _stamp = Int32List(nE);
      _origin = Int32List(nE);
      _goalAt = Int32List(nE);
    }
    if (_path.length < nE + 2) _path = Int32List(nE + 2);
  }

  /// Its scratch, by name into [into], for the allocation test (§15.2):
  /// sized by the graph it is bound to, and reset by generation stamp, so
  /// none of it is replaced while that graph runs.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.g'] = _g;
    into['$name.parent'] = _parent;
    into['$name.stamp'] = _stamp;
    into['$name.origin'] = _origin;
    into['$name.goalAt'] = _goalAt;
    into['$name.goalPt'] = _goalPt;
    into['$name.path'] = _path;
    _heap.collectBuffers(into, '$name.heap');
    _ends.collectBuffers(into, '$name.ends');
  }
}

/// The priority lanes of the [PathQueue] (§4.8), served in this order, and
/// first come first served within each. Pedestrian legs (slice 4) and zone
/// skims (slice 3) join them later, after these. Append-only.
enum PathPriority {
  /// A vehicle whose route a network edit made impossible (§3.9): it is on
  /// the road now, holding at the end of its edge.
  replan,

  /// Service, transit and freight legs: never deferred for the car caps.
  service,

  /// New car trips.
  car,
}

/// How a request ended.
enum PathOutcome {
  /// A route, in [PlannedRoute].
  found,

  /// Both ends are on the network, and nothing joins them.
  noPath,

  /// An end is not on the network: no access point, or no lane to start in.
  noAccess,
}

/// One request as the queue holds it: who asked, for what vehicle, and
/// between which ends — as the owner's own handles (a building, a vehicle,
/// a stop), never as edge ids. The owner turns them into edges on the graph
/// the search runs on ([PathResolver]), so a request queued before a road
/// edit is re-rooted on the new network simply by asking again (§4.8).
///
/// The queue owns and reuses these: read one during a callback, never keep
/// it.
class PathRequest {
  /// Whoever asked: a citizen, vehicle, request, visitor or line handle.
  int requester = -1;
  PathPriority priority = PathPriority.car;

  /// The [AgentKind] index of what will drive.
  int kind = 0;

  /// Whether the route must start in the lane the vehicle is in (§4.5).
  bool fixedStart = false;

  /// The two ends, in the owner's terms, with a position each if it wants
  /// one.
  int origin = -1;
  double originS = 0;
  int dest = -1;
  double destS = 0;

  /// The owner's own note: a purpose, a leg number.
  int tag = 0;

  /// Enqueue order, across every priority.
  double seq = 0;

  AgentKind get agentKind => AgentKind.values[kind];
}

/// A route the queue delivers: `[firstLane, c₁, …, c_n]`, the arena's format
/// (§2.10), with where on its first and last edges it starts and stops.
/// Owned and reused by the queue: copy it out during the callback.
class PlannedRoute {
  Int32List elems = Int32List(64);
  int length = 0;

  /// Which of the resolved ends it joins ([PathEnds] indices), and the
  /// travel arcs it leaves the first edge at and stops on the last at.
  int origin = -1;
  double originT = 0;
  int goal = -1;
  double destT = 0;

  /// Its cost in seconds (§4.1).
  double cost = 0;

  void _set(Int32List src, int n,
      {required int origin,
      required double originT,
      required int goal,
      required double destT,
      required double cost}) {
    if (elems.length < n) elems = Int32List(2 * n);
    elems.setRange(0, n, src);
    length = n;
    this.origin = origin;
    this.originT = originT;
    this.goal = goal;
    this.destT = destT;
    this.cost = cost;
  }

  void _clear() {
    length = 0;
    origin = goal = -1;
    originT = destT = cost = 0;
  }
}

/// Turns a request's handles into edges on the graph now running: the
/// origin's serving edges and the destination's, with their arcs, lane
/// masks and — for a fixed start — the lane (§3.10, §4.4). False when an
/// end has no access.
abstract interface class PathResolver {
  bool resolve(PathRequest request, PathEnds ends);
}

/// Receives every request's outcome, once.
abstract interface class PathSink {
  void onPath(PathRequest request, PathOutcome outcome, PlannedRoute route);
}

/// The budgeted, deterministic request queue (§4.8): a ring per
/// [PathPriority], served first come first served within its priority, by a
/// few resumable search contexts that share one budget of expansions per
/// sub-step.
///
/// The best queued request — highest priority, then oldest — runs first. A
/// search that exhausts the budget keeps its context and resumes on the
/// next [pump]; only a request of a HIGHER priority takes a second context
/// meanwhile, so a re-plan never waits behind a car trip half searched.
///
/// A free-start request runs the edge A* and then the lane pass; should the
/// lane pass find the sequence undrivable (§3.5's one known gap: a ramp
/// merge into the kerb lane followed by a turn from another lane, with no
/// junction between to change at), the same request runs the state search,
/// which returns a drivable route or none. A fixed-start request runs the
/// state search from the start.
class PathQueue {
  /// A queue with [contexts] search contexts.
  PathQueue({int contexts = 4})
      : _slots = List<_Slot>.generate(contexts, (_) => _Slot(),
            growable: false);

  final List<_Slot> _slots;
  final List<_Ring> _rings = List<_Ring>.generate(
      PathPriority.values.length, (_) => _Ring(64),
      growable: false);
  final LanePlanner _planner = LanePlanner();
  final PlannedRoute _route = PlannedRoute();
  RouteCost? _cost;
  double _seq = 0;

  /// The delay buffer a search captures when it begins (slice 2, §4.2): set
  /// by the owner at every publish. Null prices every edge at D = 0.
  Float32List? delays;

  /// Lane occupancy for the lane pass's tie-break; null reads every lane
  /// empty.
  LaneLoad? load;

  /// Trips the lane pass could not drive, planned by the state search
  /// instead.
  int fallbacks = 0;

  RouteCost? get routeCost => _cost;

  /// Runs every search from now on [cost]'s graph. Searches in flight
  /// restart from their requests — re-resolved, so on the new network —
  /// and queued requests keep their places.
  void bind(RouteCost cost) {
    if (identical(cost, _cost)) return;
    _cost = cost;
    for (var i = 0; i < _slots.length; i++) {
      if (_slots[i].busy) _slots[i].restart = true;
    }
  }

  /// Queues a request; false when its priority's queue is at its cap
  /// (`AgentTuning.maxQueuedPaths` for car trips,
  /// `maxQueuedServicePaths` for the reserved lane; re-plans are never
  /// refused). The owner defers what is refused (D9, D10).
  bool enqueue(PathPriority priority,
      {required int requester,
      AgentKind kind = AgentKind.car,
      bool fixedStart = false,
      int origin = -1,
      double originS = 0,
      int dest = -1,
      double destS = 0,
      int tag = 0}) {
    final ring = _rings[priority.index];
    final cap = switch (priority) {
      PathPriority.replan => -1,
      PathPriority.service => AgentTuning.maxQueuedServicePaths,
      PathPriority.car => AgentTuning.maxQueuedPaths,
    };
    if (cap >= 0 && ring.live >= cap) return false;
    ring.push(requester, kind.index, fixedStart ? _Ring.fixed : 0, origin,
        originS, dest, destS, tag, _seq);
    _seq += 1;
    return true;
  }

  /// Requests waiting at [priority], not yet searching.
  int lengthOf(PathPriority priority) => _rings[priority.index].live;

  /// Requests waiting at every priority.
  int get length {
    var n = 0;
    for (var p = 0; p < _rings.length; p++) {
      n += _rings[p].live;
    }
    return n;
  }

  /// Requests being searched now.
  int get searching {
    var n = 0;
    for (var i = 0; i < _slots.length; i++) {
      if (_slots[i].busy) n++;
    }
    return n;
  }

  bool get idle => length == 0 && searching == 0;

  /// Every buffer the queue keeps from one sub-step to the next — its
  /// rings, its lane pass, the route it hands out, and each search context
  /// with its ends — by name into [into], for the allocation test (§15.2):
  /// once warm, none is ever replaced. A context not yet made is not
  /// listed, so one first made in steady state shows as a buffer new since.
  void collectBuffers(Map<String, Object> into, String name) {
    for (var p = 0; p < _rings.length; p++) {
      _rings[p].collectBuffers(into, '$name.ring$p');
    }
    _planner.collectBuffers(into, '$name.lanes');
    into['$name.route'] = _route.elems;
    for (var i = 0; i < _slots.length; i++) {
      final s = _slots[i];
      s.ends.collectBuffers(into, '$name.slot$i.ends');
      s.edge?.collectBuffers(into, '$name.slot$i.edge');
      s.state?.collectBuffers(into, '$name.slot$i.state');
    }
  }

  /// [hash] with every request folded in — each queued one, per priority
  /// in queue order, and each being searched, with how far its search has
  /// got — for `CityAgents.digest`. Two queues that agree on it will serve
  /// the same requests in the same order.
  int digest(int hash) {
    var h = hash;
    for (var p = 0; p < _rings.length; p++) {
      h = _rings[p].digest(h);
    }
    for (var i = 0; i < _slots.length; i++) {
      final s = _slots[i];
      if (!s.busy) {
        h = fnv1aU32(h, 0);
        continue;
      }
      final r = s.request;
      h = fnv1aU32(h, 1 | (s.restart ? 2 : 0) | (s.byState ? 4 : 0));
      h = fnv1aU32(h, r.requester);
      h = fnv1aU32(h, r.priority.index | r.kind << 8 | r.tag << 16);
      h = fnv1aU32(h, r.origin);
      h = fnv1aU32(h, r.dest);
      h = fnv1aU32(h, r.seq.toInt());
      h = fnv1aU32(h, s.byState ? s.state!.expansions : s.edge!.expansions);
    }
    return fnv1aU32(h, fallbacks);
  }

  /// Withdraws every request of [requester], queued or searching; none of
  /// them is delivered. Returns how many there were.
  int cancel(int requester) {
    var n = 0;
    for (var p = 0; p < _rings.length; p++) {
      n += _rings[p].cancel(requester);
    }
    for (var i = 0; i < _slots.length; i++) {
      final s = _slots[i];
      if (s.busy && s.request.requester == requester) {
        s.busy = false;
        s.restart = false;
        n++;
      }
    }
    return n;
  }

  /// Spends up to [budget] expansions on the requests, best first, and
  /// hands each finished one to [sink]. Returns the expansions spent. An
  /// end [resolver] cannot place costs one expansion, so a flood of them
  /// cannot hold the loop.
  int pump(int budget, PathResolver resolver, PathSink sink) {
    final cost = _cost;
    if (cost == null) return 0;
    var used = 0;
    while (used < budget) {
      final s = _bestSlot();
      final p = _headPriority();
      if (p >= 0) {
        final ring = _rings[p];
        final ahead = s < 0 ||
            _before(p, ring.headSeq, _slots[s].request.priority.index,
                _slots[s].request.seq);
        if (ahead) {
          final free = _freeSlot();
          if (free >= 0) {
            final slot = _slots[free];
            ring.popInto(slot.request, PathPriority.values[p]);
            slot.busy = true;
            used += _start(slot, cost, resolver, sink);
            continue;
          }
        }
      }
      if (s < 0) break;
      final slot = _slots[s];
      if (slot.restart) {
        used += _start(slot, cost, resolver, sink);
        continue;
      }
      used += _run(slot, cost, budget - used, sink);
    }
    return used;
  }

  int _start(_Slot slot, RouteCost cost, PathResolver resolver, PathSink sink) {
    slot.restart = false;
    final ends = slot.ends..clear();
    if (!resolver.resolve(slot.request, ends) ||
        ends.originCount == 0 ||
        ends.goalCount == 0) {
      _route._clear();
      _deliver(slot, PathOutcome.noAccess, sink);
      return 1;
    }
    final kind = slot.request.agentKind;
    if (slot.request.fixedStart) {
      slot.byState = true;
      (slot.state ??= LaneStateSearch())
          .begin(cost, ends, kind: kind, delays: delays);
    } else {
      slot.byState = false;
      (slot.edge ??= SearchContext())
          .begin(cost, ends, kind: kind, delays: delays);
    }
    return 0;
  }

  int _run(_Slot slot, RouteCost cost, int left, PathSink sink) {
    if (!slot.byState) {
      final search = slot.edge!;
      final st = search.step(left);
      final used = search.lastStepExpansions;
      if (st == SearchStatus.running) return used;
      if (st == SearchStatus.noPath) {
        _route._clear();
        _deliver(slot, PathOutcome.noPath, sink);
        return used;
      }
      final k = search.goalIndex;
      if (_planner.plan(cost.lg, search.path, search.pathLength,
          destMask: slot.ends.goalMask[k], load: load)) {
        _route._set(_planner.route, _planner.routeLength,
            origin: search.originIndex,
            originT: search.originT,
            goal: k,
            destT: search.goalT,
            cost: search.cost);
        _deliver(slot, PathOutcome.found, sink);
        return used;
      }
      // The lane pass found the cheapest edge sequence undrivable. The
      // state search, from every lane of the origin, finds the cheapest
      // route that can be driven — at the same delay buffer.
      fallbacks++;
      slot.byState = true;
      (slot.state ??= LaneStateSearch()).begin(cost, slot.ends,
          kind: slot.request.agentKind, delays: search.delays);
      return used;
    }
    final search = slot.state!;
    final st = search.step(left);
    final used = search.lastStepExpansions;
    if (st == SearchStatus.running) return used;
    if (st == SearchStatus.noPath) {
      _route._clear();
      _deliver(slot, PathOutcome.noPath, sink);
      return used;
    }
    _route._set(search.route, search.routeLength,
        origin: search.originIndex,
        originT: search.originT,
        goal: search.goalIndex,
        destT: search.goalT,
        cost: search.cost);
    _deliver(slot, PathOutcome.found, sink);
    return used;
  }

  void _deliver(_Slot slot, PathOutcome outcome, PathSink sink) {
    slot.busy = false;
    slot.restart = false;
    sink.onPath(slot.request, outcome, _route);
  }

  static bool _before(int pa, double seqA, int pb, double seqB) =>
      pa < pb || (pa == pb && seqA < seqB);

  /// The busy context whose request comes first, or −1.
  int _bestSlot() {
    var best = -1;
    for (var i = 0; i < _slots.length; i++) {
      final s = _slots[i];
      if (!s.busy) continue;
      if (best < 0 ||
          _before(s.request.priority.index, s.request.seq,
              _slots[best].request.priority.index, _slots[best].request.seq)) {
        best = i;
      }
    }
    return best;
  }

  int _freeSlot() {
    for (var i = 0; i < _slots.length; i++) {
      if (!_slots[i].busy) return i;
    }
    return -1;
  }

  /// The first priority with a request waiting, or −1.
  int _headPriority() {
    for (var p = 0; p < _rings.length; p++) {
      final r = _rings[p]..trim();
      if (r.live > 0) return p;
    }
    return -1;
  }
}

/// One search context of the queue, with the request it serves.
class _Slot {
  final PathRequest request = PathRequest();
  final PathEnds ends = PathEnds();
  SearchContext? edge;
  LaneStateSearch? state;
  bool busy = false;
  bool restart = false;
  bool byState = false;
}

/// One priority's requests: a ring of typed columns. A cancelled request
/// stays in place, flagged, until it reaches the head.
class _Ring {
  _Ring(int capacity)
      : requester = Int32List(capacity),
        origin = Int32List(capacity),
        dest = Int32List(capacity),
        tag = Int32List(capacity),
        kind = Uint8List(capacity),
        flags = Uint8List(capacity),
        originS = Float64List(capacity),
        destS = Float64List(capacity),
        seq = Float64List(capacity);

  static const int fixed = 1;
  static const int cancelled = 2;

  Int32List requester, origin, dest, tag;
  Uint8List kind, flags;
  Float64List originS, destS, seq;
  int head = 0;
  int size = 0;
  int live = 0;

  int get capacity => requester.length;

  /// The enqueue order of the head, once [trim] has run.
  double get headSeq => seq[head];

  void push(int who, int kindIndex, int flagBits, int from, double fromS,
      int to, double toS, int note, double order) {
    if (size == capacity) _grow();
    final i = (head + size) % capacity;
    requester[i] = who;
    kind[i] = kindIndex;
    flags[i] = flagBits;
    origin[i] = from;
    originS[i] = fromS;
    dest[i] = to;
    destS[i] = toS;
    tag[i] = note;
    seq[i] = order;
    size++;
    live++;
  }

  /// Drops cancelled requests from the head.
  void trim() {
    while (size > 0 && flags[head] & cancelled != 0) {
      head = (head + 1) % capacity;
      size--;
    }
  }

  /// Takes the head into [r].
  void popInto(PathRequest r, PathPriority priority) {
    trim();
    final i = head;
    r.requester = requester[i];
    r.priority = priority;
    r.kind = kind[i];
    r.fixedStart = flags[i] & fixed != 0;
    r.origin = origin[i];
    r.originS = originS[i];
    r.dest = dest[i];
    r.destS = destS[i];
    r.tag = tag[i];
    r.seq = seq[i];
    head = (head + 1) % capacity;
    size--;
    live--;
  }

  int cancel(int who) {
    var n = 0;
    for (var k = 0; k < size; k++) {
      final i = (head + k) % capacity;
      if (requester[i] == who && flags[i] & cancelled == 0) {
        flags[i] |= cancelled;
        live--;
        n++;
      }
    }
    return n;
  }

  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.requester'] = requester;
    into['$name.origin'] = origin;
    into['$name.dest'] = dest;
    into['$name.tag'] = tag;
    into['$name.kind'] = kind;
    into['$name.flags'] = flags;
    into['$name.originS'] = originS;
    into['$name.destS'] = destS;
    into['$name.seq'] = seq;
  }

  /// [hash] with every live request folded in, in queue order.
  int digest(int hash) {
    var h = fnv1aU32(hash, live);
    for (var k = 0; k < size; k++) {
      final i = (head + k) % capacity;
      if (flags[i] & cancelled != 0) continue;
      h = fnv1aU32(h, requester[i]);
      h = fnv1aU32(h, kind[i] | flags[i] << 8 | tag[i] << 16);
      h = fnv1aU32(h, origin[i]);
      h = fnv1aU32(h, dest[i]);
      h = fnv1aU32(h, seq[i].toInt());
    }
    return h;
  }

  void _grow() {
    final cap = capacity * 2;
    Int32List i32(Int32List a) {
      final b = Int32List(cap);
      for (var k = 0; k < size; k++) {
        b[k] = a[(head + k) % a.length];
      }
      return b;
    }

    Uint8List u8(Uint8List a) {
      final b = Uint8List(cap);
      for (var k = 0; k < size; k++) {
        b[k] = a[(head + k) % a.length];
      }
      return b;
    }

    Float64List f64(Float64List a) {
      final b = Float64List(cap);
      for (var k = 0; k < size; k++) {
        b[k] = a[(head + k) % a.length];
      }
      return b;
    }

    requester = i32(requester);
    origin = i32(origin);
    dest = i32(dest);
    tag = i32(tag);
    kind = u8(kind);
    flags = u8(flags);
    originS = f64(originS);
    destS = f64(destS);
    seq = f64(seq);
    head = 0;
  }
}
