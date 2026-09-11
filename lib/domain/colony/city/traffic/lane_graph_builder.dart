// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Derives the [LaneGraph] from the road agent's `RoadGraph`
/// (docs/plans/agent-traffic.md §3.1, §3.8).
///
/// No clustering, no attach pass, no warrant of its own: the nodes, pieces,
/// directed edges, legs and plans are the road graph's, read as they are.
/// What this adds is what a vehicle needs and a trip model does not: lanes,
/// the connectors across each node ([connectNode]), where on each connector
/// two paths cross, the stop bars the lanes end at, and which edges can
/// reach which.
///
/// Built in phases — controls, edges, lanes, connectors, packing,
/// conflicts, and a finish — each budgeted by items, so a network too big to
/// build inside one tick ([step]) is built across several while the old
/// graph keeps running (§3.8). A City Builder colony builds in one
/// ([build]). Derivation may allocate: it runs on an edit, never per
/// sub-step.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import '../road_catalog.dart';
import '../road_graph.dart';
import 'agent_kind.dart';
import 'lane_connectors.dart';
import 'lane_graph.dart';
import 'node_control.dart';

enum _Phase { controls, edges, lanes, connectors, pack, conflicts, finish, done }

/// Builds one [LaneGraph] from one `RoadGraph`, a budget of items at a time.
class LaneGraphBuilder {
  LaneGraphBuilder(this.graph, {this.stubNode});

  /// The road graph being derived from.
  final RoadGraph graph;

  /// Per node, 1 where an outside connection made a dead end a stub (slice
  /// 8); null for none.
  final Uint8List? stubNode;

  /// The lane graph of [graph], built at once.
  static LaneGraph build(RoadGraph graph, {Uint8List? stubNode}) {
    final b = LaneGraphBuilder(graph, stubNode: stubNode);
    while (!b.step(_unbounded)) {}
    return b.result;
  }

  /// [built] brought under the plans of [patched] without a rebuild, where
  /// none is needed (§3.8):
  ///
  /// - [built] itself, when [patched] is its own graph;
  /// - a copy sharing every lane and connector, with the new node controls
  ///   and connector roles, when [patched] only re-planned junctions or
  ///   renamed roads ([RoadGraph.sharesStructureWith]);
  /// - null when anything else changed, and only [build] will do.
  ///
  /// An override only ever toggles a stop and a signal, or which legs stop,
  /// so the connectors at a node never change with it. Should a re-plan ever
  /// move a node to a kind whose connectors differ — or whose stop bar sits
  /// elsewhere — this returns null rather than keep lanes that no longer fit.
  static LaneGraph? refresh(LaneGraph built, RoadGraph patched) {
    if (identical(patched, built.graph)) return built;
    if (!patched.sharesStructureWith(built.graph)) return null;
    final ctl = NodeControls.of(patched, stubNode: built.stubNode);
    final old = built.controls;
    for (var n = 0; n < built.nodeCount; n++) {
      if (_ruleClass(ctl.kindOf(n)) != _ruleClass(old.kindOf(n))) return null;
      if (ctl.stopBack[n] != old.stopBack[n]) return null;
    }
    return built.withControls(patched, ctl,
        rolesFor(ctl, built.conKind, built.conFromLane, built.laneEdge));
  }

  /// Which rules a node's connectors came from: nodes alike here have alike
  /// connectors, whatever their control.
  static int _ruleClass(NodeControlKind k) {
    if (isTurningPlace(k)) return 0;
    return switch (k) {
      NodeControlKind.continuation => 1,
      NodeControlKind.rampMerge => 2,
      NodeControlKind.roundabout => 3,
      _ => 4,
    };
  }

  /// Every connector's [ConnectorRole] under [ctl]: a lane drop, a shift, a
  /// ramp's merge and a U-turn are what they are; anything else gives way
  /// where its arriving leg does, and has priority where it does not.
  static Uint8List rolesFor(NodeControls ctl, Uint8List conKind,
      Int32List conFromLane, Int32List laneEdge) {
    final roles = Uint8List(conKind.length);
    for (var c = 0; c < conKind.length; c++) {
      final yields = ctl.edgeYields[laneEdge[conFromLane[c]]] == 1;
      final role = switch (ConnectorKind.values[conKind[c]]) {
        ConnectorKind.uTurn => ConnectorRole.uTurn,
        ConnectorKind.merge => ConnectorRole.mergeYield,
        ConnectorKind.dropped => ConnectorRole.droppedLane,
        ConnectorKind.shift => ConnectorRole.shift,
        ConnectorKind.aligned ||
        ConnectorKind.fanOut ||
        ConnectorKind.turn ||
        ConnectorKind.diverge =>
          yields ? ConnectorRole.yield : ConnectorRole.priority,
      };
      roles[c] = role.index;
    }
    return roles;
  }

  static const int _unbounded = 0x3FFFFFFF;

  /// Arc from a node along an edge to the sample its direction is read at:
  /// close enough to be the direction at the node, far enough that a
  /// sampling kink right at the end does not set it (§3.5).
  static const double _tangentReachM = 3.0;

  /// The shortest a lane is left when the stop bars at both ends would
  /// overlap on a short stretch between two junctions.
  static const double _minLaneM = 1.0;

  _Phase _phase = _Phase.controls;
  int _cursor = 0;
  LaneGraph? _result;

  /// Whether [result] is ready.
  bool get done => _phase == _Phase.done;

  /// The lane graph, once [done].
  LaneGraph get result {
    final r = _result;
    if (r == null) throw StateError('the lane graph is still being built');
    return r;
  }

  /// Builds up to [budget] items — a node, an edge, the packing — and
  /// returns whether the graph is done. The result is the same for any
  /// budget.
  bool step(int budget) {
    var left = budget;
    while (left > 0 && _phase != _Phase.done) {
      switch (_phase) {
        case _Phase.controls:
          _beginControls();
          left--;
          _advance();
        case _Phase.edges:
          while (left > 0 && _cursor < graph.edgeCount) {
            _edge(_cursor++);
            left--;
          }
          if (_cursor >= graph.edgeCount) {
            _endEdges();
            _advance();
          }
        case _Phase.lanes:
          while (left > 0 && _cursor < graph.edgeCount) {
            _lanes(_cursor++);
            left--;
          }
          if (_cursor >= graph.edgeCount) _advance();
        case _Phase.connectors:
          while (left > 0 && _cursor < graph.nodeCount) {
            _connectors(_cursor++);
            left--;
          }
          if (_cursor >= graph.nodeCount) _advance();
        case _Phase.pack:
          _pack();
          left--;
          _advance();
        case _Phase.conflicts:
          while (left > 0 && _cursor < graph.nodeCount) {
            _conflicts(_cursor++);
            left--;
          }
          if (_cursor >= graph.nodeCount) _advance();
        case _Phase.finish:
          _finish();
          left--;
          _advance();
        case _Phase.done:
          break;
      }
    }
    return done;
  }

  void _advance() {
    _phase = _Phase.values[_phase.index + 1];
    _cursor = 0;
  }

  // ---- Controls ---------------------------------------------------------------

  late NodeControls _ctl;

  late Int32List _edgeRoad, _edgeReverse, _edgeOutLeg, _edgeLaneBase;
  late Uint8List _edgeLaneCount, _edgeFlags;
  late Float64List _edgeS0, _edgeS1, _edgeLen;
  late Float32List _edgeLimit, _edgeWType, _edgeLaneS0, _edgeLaneS1;
  late Int8List _edgeTier;

  /// Unit travel direction leaving each edge's start node, and arriving at
  /// its end node.
  late Float64List _depE, _depN, _arrE, _arrN;

  /// Where each edge's lanes start and end, on its centreline, and the
  /// travel direction there: every connector leaving the edge starts at the
  /// end one and every connector reaching it ends at the start one, offset
  /// by its lane — worked out once per edge, not once per connector.
  late Float64List _startE, _startN, _startDe, _startDn;
  late Float64List _endE, _endN, _endDe, _endDn;
  int _laneTotal = 0;

  void _beginControls() {
    _ctl = NodeControls.of(graph, stubNode: stubNode);
    final nE = graph.edgeCount;
    _edgeRoad = Int32List(nE);
    _edgeReverse = Int32List(nE);
    _edgeOutLeg = Int32List(nE);
    _edgeLaneBase = Int32List(nE);
    _edgeLaneCount = Uint8List(nE);
    _edgeFlags = Uint8List(nE);
    _edgeS0 = Float64List(nE);
    _edgeS1 = Float64List(nE);
    _edgeLen = Float64List(nE);
    _edgeLimit = Float32List(nE);
    _edgeWType = Float32List(nE);
    _edgeLaneS0 = Float32List(nE);
    _edgeLaneS1 = Float32List(nE);
    _edgeTier = Int8List(nE);
    _depE = Float64List(nE);
    _depN = Float64List(nE);
    _arrE = Float64List(nE);
    _arrN = Float64List(nE);
    _startE = Float64List(nE);
    _startN = Float64List(nE);
    _startDe = Float64List(nE);
    _startDn = Float64List(nE);
    _endE = Float64List(nE);
    _endN = Float64List(nE);
    _endDe = Float64List(nE);
    _endDn = Float64List(nE);
  }

  // ---- Edges ------------------------------------------------------------------

  /// Whether each kind of road parks cars at the kerb, looked up once per
  /// kind — the catalogue look-up is a scan.
  final Map<int, bool> _parking = {};

  void _edge(int e) {
    final g = graph;
    final p = g.edgePiece[e];
    final r = g.pieceRoad[p];
    final road = g.roads[r];
    final fwd = g.edgeForward[e] == 1;
    final s0 = g.pieceS0[p], s1 = g.pieceS1[p];
    _edgeRoad[e] = r;
    _edgeS0[e] = s0;
    _edgeS1[e] = s1;
    _edgeLen[e] = g.edgeLength[e];
    _edgeLimit[e] = g.roadSpeedMps[r];
    _edgeWType[e] = roadTypeWeight(road.roadClass);
    _edgeTier[e] = road.roadClass.tier.rank;
    _edgeLaneCount[e] = lanesPerDirection(road);
    _edgeFlags[e] = _flagsOf(road, s0, s1);
    _edgeReverse[e] = fwd ? g.pieceBwdEdge[p] : g.pieceFwdEdge[p];
    _laneTotal += _edgeLaneCount[e];

    // The directions at the two nodes: from each node to the first sample
    // at least a few metres in, within the piece.
    final rec = g.roadRecs[r];
    final cum = rec.cum;
    final nS = rec.sampleCount;
    final start = g.pointAt(r, fwd ? s0 : s1);
    final end = g.pointAt(r, fwd ? s1 : s0);
    Vec2 inward(double from, bool up) {
      if (up) {
        final i = _firstAtOrAfter(cum, from + _tangentReachM);
        return i < nS && cum[i] <= s1 ? rec.sampleAt(i) : g.pointAt(r, s1);
      }
      final i = _firstAtOrAfter(cum, from - _tangentReachM + 1e-9) - 1;
      return i >= 0 && cum[i] >= s0 ? rec.sampleAt(i) : g.pointAt(r, s0);
    }

    final dep = _unit(inward(fwd ? s0 : s1, fwd) - start, end - start);
    final arr = _unit(end - inward(fwd ? s1 : s0, !fwd), end - start);
    _depE[e] = dep.e;
    _depN[e] = dep.n;
    _arrE[e] = arr.e;
    _arrN[e] = arr.n;
    _edgeOutLeg[e] = _outLeg(e, road.id, dep);
  }

  /// [d] as a unit vector; [fallback]'s direction where [d] has none, and
  /// north where neither has.
  static Vec2 _unit(Vec2 d, Vec2 fallback) {
    if (d.length > 1e-9) return d.normalized;
    if (fallback.length > 1e-9) return fallback.normalized;
    return const Vec2(0, 1);
  }

  /// The leg edge [e] leaves its start node by. Where the stretch runs both
  /// ways it is the leg its other direction arrives by; on a one-way road,
  /// the leg of the same road pointing the way the edge sets off.
  int _outLeg(int e, String roadId, Vec2 dep) {
    final rev = _edgeReverse[e];
    if (rev >= 0) return graph.edgeLeg[rev];
    final node = graph.nodes[graph.edgeFrom[e]];
    final h = dep.heading;
    var best = -1;
    var bestD = double.infinity;
    for (var k = 0; k < node.legs.length; k++) {
      if (node.legRoadIds[k] != roadId) continue;
      final d = _angleBetween(node.legs[k].heading, h);
      if (d < bestD) {
        bestD = d;
        best = k;
      }
    }
    return best;
  }

  static double _angleBetween(double a, double b) {
    const tau = 2 * math.pi;
    var d = (a - b) % tau;
    if (d < 0) d += tau;
    return d > math.pi ? tau - d : d;
  }

  int _flagsOf(RoadSpline road, double s0, double s1) {
    final c = road.roadClass;
    var f = 0;
    if (road.sealed) f |= kEdgeSealed;
    if (c.hasPavement) f |= kEdgePavement;
    // A highway's kerb is a shoulder, whatever its menu entry says.
    if (c != RoadClass.highway && _parksAtKerb(road)) f |= kEdgeParking;
    if ((road.lanes?.divided ?? false) || c.limitedAccess) f |= kEdgeDivided;
    for (final (a, b) in road.bridges) {
      if (a < s1 && b > s0) {
        f |= kEdgeBridge;
        break;
      }
    }
    if (c != RoadClass.path && c != RoadClass.alley) f |= kEdgeBus;
    return f;
  }

  bool _parksAtKerb(RoadSpline road) {
    final kind = (road.roadClass.index * RoadDecoration.values.length +
                road.decoration.index) *
            2 +
        (road.soundWalls ? 1 : 0);
    return _parking[kind] ??= RoadType.of(road).hasParking;
  }

  late Int32List _inStart, _inEdges;

  void _endEdges() {
    // The edges arriving at each node, ascending.
    final nN = graph.nodeCount, nE = graph.edgeCount;
    _inStart = Int32List(nN + 1);
    for (var e = 0; e < nE; e++) {
      _inStart[graph.edgeTo[e] + 1]++;
    }
    for (var n = 0; n < nN; n++) {
      _inStart[n + 1] += _inStart[n];
    }
    final fill = Int32List.fromList(_inStart.sublist(0, nN));
    _inEdges = Int32List(nE);
    for (var e = 0; e < nE; e++) {
      _inEdges[fill[graph.edgeTo[e]]++] = e;
    }
    _laneEdge = Int32List(_laneTotal);
    _laneIdx = Uint8List(_laneTotal);
    _laneOff = Float32List(_laneTotal);
    _laneTotal = 0;
  }

  // ---- Lanes ------------------------------------------------------------------

  late Int32List _laneEdge;
  late Uint8List _laneIdx;
  late Float32List _laneOff;

  void _lanes(int e) {
    final road = graph.roads[_edgeRoad[e]];
    final n = _edgeLaneCount[e];
    _edgeLaneBase[e] = _laneTotal;
    for (var k = 0; k < n; k++) {
      final l = _laneTotal + k;
      _laneEdge[l] = e;
      _laneIdx[l] = k;
      _laneOff[l] = laneOffsetRight(road, k);
    }
    _laneTotal += n;
    // The lanes run from the stop bar behind to the stop bar ahead. Between
    // two junctions closer than their plates, both back off in proportion
    // and leave the lane a metre.
    final len = _edgeLen[e];
    var back0 = _ctl.stopBack[graph.edgeFrom[e]].toDouble();
    var back1 = _ctl.stopBack[graph.edgeTo[e]].toDouble();
    final keep = math.min(_minLaneM, len);
    if (len - back0 - back1 < keep && back0 + back1 > 0) {
      final f = math.max(0.0, len - keep) / (back0 + back1);
      back0 *= f;
      back1 *= f;
    }
    _edgeLaneS0[e] = back0;
    _edgeLaneS1[e] = len - back1;
    final a = _frame(e, _edgeLaneS0[e]);
    _startE[e] = a.e;
    _startN[e] = a.n;
    _startDe[e] = a.de;
    _startDn[e] = a.dn;
    final b = _frame(e, _edgeLaneS1[e]);
    _endE[e] = b.e;
    _endN[e] = b.n;
    _endDe[e] = b.de;
    _endDn[e] = b.dn;
  }

  // ---- Connectors -------------------------------------------------------------

  // Drafts, in the order the rules emit them; packed by lane later.
  final List<int> _dNode = [], _dFrom = [], _dTo = [];
  final List<int> _dTurn = [], _dKind = [];
  final List<double> _dLen = [], _dRMin = [], _dPen = [], _dTheta = [];
  Float64List _dPts = Float64List(1024);
  int _curNode = 0;

  void _connectors(int n) {
    final g = graph;
    final at = g.nodes[n].at;
    final ins = <NodeArm>[
      for (var i = _inStart[n]; i < _inStart[n + 1]; i++)
        _arm(_inEdges[i], at, arriving: true),
    ];
    final outs = <NodeArm>[
      for (var k = g.outStart[n]; k < g.outStart[n + 1]; k++)
        _arm(g.outEdges[k], at, arriving: false),
    ];
    if (ins.isEmpty || outs.isEmpty) return;
    _curNode = n;
    connectNode(_ctl.kindOf(n), ins, outs, _emit);
  }

  NodeArm _arm(int e, Vec2 nodeAt, {required bool arriving}) {
    final r = _edgeRoad[e];
    final fwd = graph.edgeForward[e] == 1;
    // The road's end at this node: the edge's last point arriving, its
    // first leaving.
    final end = graph.pointAt(
        r, (arriving == fwd) ? _edgeS1[e] : _edgeS0[e]);
    return NodeArm(
      edge: e,
      lanes: _edgeLaneCount[e],
      roadClass: graph.roads[r].roadClass,
      reverse: _edgeReverse[e],
      dirE: arriving ? _arrE[e] : _depE[e],
      dirN: arriving ? _arrN[e] : _depN[e],
      endE: end.e - nodeAt.e,
      endN: end.n - nodeAt.n,
    );
  }

  void _emit(NodeArm from, int fromK, NodeArm to, int toK, ConnectorKind kind,
      TurnClass turn, double theta, double pen) {
    final fe = from.edge, te = to.edge;
    final fromLane = _edgeLaneBase[fe] + fromK;
    final toLane = _edgeLaneBase[te] + toK;
    // From the end of the in-lane, at the stop bar, to the start of the
    // out-lane, each offset right of its own travel.
    final offA = _laneOff[fromLane].toDouble(), offB = _laneOff[toLane].toDouble();
    final ade = _endDe[fe], adn = _endDn[fe];
    final bde = _startDe[te], bdn = _startDn[te];
    final p0e = _endE[fe] + adn * offA, p0n = _endN[fe] - ade * offA;
    final p2e = _startE[te] + bdn * offB, p2n = _startN[te] - bde * offB;
    final at = _dNode.length * 2 * kConnectorPoints;
    if (_dPts.length < at + 2 * kConnectorPoints) {
      final grown = Float64List(_dPts.length * 2);
      grown.setRange(0, _dPts.length, _dPts);
      _dPts = grown;
    }
    final shape = kind == ConnectorKind.uTurn
        ? uTurnCurve(p0e, p0n, ade, adn, p2e, p2n, _dPts, at)
        : connectorCurve(p0e, p0n, ade, adn, p2e, p2n, bde, bdn, _dPts, at);
    _dNode.add(_curNode);
    _dFrom.add(fromLane);
    _dTo.add(toLane);
    _dTurn.add(turn.index);
    _dKind.add(kind.index);
    _dLen.add(shape.length);
    _dRMin.add(shape.rMin);
    _dPen.add(pen);
    _dTheta.add(theta);
  }

  /// Where travel arc [t] along [edge] is, and the unit travel direction
  /// there.
  ({double e, double n, double de, double dn}) _frame(int edge, double t) {
    final rec = graph.roadRecs[_edgeRoad[edge]];
    final fwd = graph.edgeForward[edge] == 1;
    final s = fwd ? _edgeS0[edge] + t : _edgeS1[edge] - t;
    final cum = rec.cum;
    final nS = rec.sampleCount;
    var i = _firstAtOrAfter(cum, s);
    if (i < 1) i = 1;
    if (i > nS - 1) i = nS - 1;
    final seg = cum[i] - cum[i - 1];
    final u = seg <= 1e-12 ? 0.0 : ((s - cum[i - 1]) / seg).clamp(0.0, 1.0);
    final pe = rec.e[i - 1] + (rec.e[i] - rec.e[i - 1]) * u;
    final pn = rec.n[i - 1] + (rec.n[i] - rec.n[i - 1]) * u;
    // The segment's direction — or, on a zero-length one, the nearest
    // segment's that has one.
    var de = 0.0, dn = 0.0;
    for (var k = 0; k < nS && de == 0 && dn == 0; k++) {
      for (var side = 0; side < 2; side++) {
        final j = side == 0 ? i + k : i - k;
        if (j < 1 || j > nS - 1) continue;
        final ex = rec.e[j] - rec.e[j - 1], ey = rec.n[j] - rec.n[j - 1];
        final l = math.sqrt(ex * ex + ey * ey);
        if (l > 1e-9) {
          de = ex / l;
          dn = ey / l;
          break;
        }
      }
    }
    if (de == 0 && dn == 0) dn = 1;
    return fwd
        ? (e: pe, n: pn, de: de, dn: dn)
        : (e: pe, n: pn, de: -de, dn: -dn);
  }

  // ---- Packing ----------------------------------------------------------------

  late Int32List _conNode, _conFrom, _conTo, _laneConStart;
  late Int32List _nodeConStart, _nodeCons, _draftOf;
  late Float32List _conLen, _conVmax, _conPen, _conTheta;
  late Uint8List _conTurn, _conKind;
  late Float64List _box, _scale;

  void _pack() {
    // Connectors by the lane they leave, then the lane they reach: a lane's
    // connectors are then one run. One pair, one connector.
    final nD = _dNode.length;
    final order = List<int>.generate(nD, (i) => i)
      ..sort((x, y) {
        var c = _dFrom[x].compareTo(_dFrom[y]);
        if (c != 0) return c;
        c = _dTo[x].compareTo(_dTo[y]);
        return c != 0 ? c : x.compareTo(y);
      });
    final keep = <int>[];
    for (final d in order) {
      if (keep.isNotEmpty) {
        final last = keep.last;
        if (_dFrom[last] == _dFrom[d] && _dTo[last] == _dTo[d]) continue;
      }
      keep.add(d);
    }
    final nC = keep.length;
    _conNode = Int32List(nC);
    _conFrom = Int32List(nC);
    _conTo = Int32List(nC);
    _conLen = Float32List(nC);
    _conVmax = Float32List(nC);
    _conPen = Float32List(nC);
    _conTheta = Float32List(nC);
    _conTurn = Uint8List(nC);
    _conKind = Uint8List(nC);
    _draftOf = Int32List(nC);
    _box = Float64List(4 * nC);
    _scale = Float64List(nC);
    for (var c = 0; c < nC; c++) {
      final d = keep[c];
      _draftOf[c] = d;
      _conNode[c] = _dNode[d];
      _conFrom[c] = _dFrom[d];
      _conTo[c] = _dTo[d];
      _conLen[c] = _dLen[d];
      _conVmax[c] = connectorVmax(_dRMin[d]);
      _conPen[c] = _dPen[d];
      _conTheta[c] = _dTheta[d];
      _conTurn[c] = _dTurn[d];
      _conKind[c] = _dKind[d];
      final at = d * 2 * kConnectorPoints;
      var minE = double.infinity, minN = double.infinity;
      var maxE = -double.infinity, maxN = -double.infinity;
      for (var k = 0; k < kConnectorPoints; k++) {
        final pe = _dPts[at + 2 * k], pn = _dPts[at + 2 * k + 1];
        if (pe < minE) minE = pe;
        if (pe > maxE) maxE = pe;
        if (pn < minN) minN = pn;
        if (pn > maxN) maxN = pn;
      }
      _box[4 * c] = minE;
      _box[4 * c + 1] = minN;
      _box[4 * c + 2] = maxE;
      _box[4 * c + 3] = maxN;
      // Conflict points are found on the drawn path and reported in the
      // connector's own metres (they differ only for a U-turn).
      final path = pathLength(_dPts, at);
      _scale[c] = path > 1e-9 ? _dLen[d] / path : 1.0;
    }
    final nL = _laneEdge.length, nN = graph.nodeCount;
    _laneConStart = Int32List(nL + 1);
    for (var c = 0; c < nC; c++) {
      _laneConStart[_conFrom[c] + 1]++;
    }
    for (var l = 0; l < nL; l++) {
      _laneConStart[l + 1] += _laneConStart[l];
    }
    _nodeConStart = Int32List(nN + 1);
    for (var c = 0; c < nC; c++) {
      _nodeConStart[_conNode[c] + 1]++;
    }
    for (var n = 0; n < nN; n++) {
      _nodeConStart[n + 1] += _nodeConStart[n];
    }
    final fill = Int32List.fromList(_nodeConStart.sublist(0, nN));
    _nodeCons = Int32List(nC);
    for (var c = 0; c < nC; c++) {
      _nodeCons[fill[_conNode[c]]++] = c;
    }
  }

  // ---- Conflicts --------------------------------------------------------------

  final List<int> _pSelf = [], _pOther = [];
  final List<double> _pAtSelf = [], _pAtOther = [];

  void _conflicts(int n) {
    final lo = _nodeConStart[n], hi = _nodeConStart[n + 1];
    for (var i = lo; i < hi; i++) {
      final a = _nodeCons[i];
      for (var j = i + 1; j < hi; j++) {
        final b = _nodeCons[j];
        // Diverging from one lane is no conflict: the two never share the
        // road at once.
        if (_conFrom[a] == _conFrom[b]) continue;
        final merge = _conTo[a] == _conTo[b];
        if (!merge &&
            (_box[4 * a] > _box[4 * b + 2] ||
                _box[4 * b] > _box[4 * a + 2] ||
                _box[4 * a + 1] > _box[4 * b + 3] ||
                _box[4 * b + 1] > _box[4 * a + 3])) {
          continue;
        }
        final hit = firstCrossing(_dPts, _draftOf[a] * 2 * kConnectorPoints,
            _dPts, _draftOf[b] * 2 * kConnectorPoints);
        double atA, atB;
        if (hit != null) {
          atA = hit.arcA * _scale[a];
          atB = hit.arcB * _scale[b];
        } else if (merge) {
          // Two lanes funnelling into one meet where they join it.
          atA = _conLen[a].toDouble();
          atB = _conLen[b].toDouble();
        } else {
          continue;
        }
        _pSelf.add(a);
        _pOther.add(b);
        _pAtSelf.add(atA);
        _pAtOther.add(atB);
        _pSelf.add(b);
        _pOther.add(a);
        _pAtSelf.add(atB);
        _pAtOther.add(atA);
      }
    }
  }

  // ---- Finish -----------------------------------------------------------------

  void _finish() {
    final nC = _conNode.length;
    final nE = graph.edgeCount;

    // Conflicts by connector, each list in the order it was found (which
    // is by the other connector's id).
    final conflictStart = Int32List(nC + 1);
    for (final c in _pSelf) {
      conflictStart[c + 1]++;
    }
    for (var c = 0; c < nC; c++) {
      conflictStart[c + 1] += conflictStart[c];
    }
    final nP = _pSelf.length;
    final withId = Int32List(nP);
    final atSelf = Float32List(nP), atOther = Float32List(nP);
    final fill = Int32List.fromList(conflictStart.sublist(0, nC));
    for (var i = 0; i < nP; i++) {
      final k = fill[_pSelf[i]]++;
      withId[k] = _pOther[i];
      atSelf[k] = _pAtSelf[i];
      atOther[k] = _pAtOther[i];
    }

    // Movements: the edges each edge's connectors reach, ascending.
    final moveStart = Int32List(nE + 1);
    final moveOut = <int>[], moveTurn = <int>[];
    final seen = <int>[];
    for (var e = 0; e < nE; e++) {
      moveStart[e] = moveOut.length;
      final base = _edgeLaneBase[e];
      seen.clear();
      for (var c = _laneConStart[base];
          c < _laneConStart[base + _edgeLaneCount[e]];
          c++) {
        final to = _laneEdge[_conTo[c]];
        if (!seen.contains(to)) seen.add(to);
      }
      seen.sort();
      for (final to in seen) {
        moveOut.add(to);
        var turn = 0;
        for (var c = _laneConStart[base];
            c < _laneConStart[base + _edgeLaneCount[e]];
            c++) {
          if (_laneEdge[_conTo[c]] == to) {
            turn = _conTurn[c];
            break;
          }
        }
        moveTurn.add(turn);
      }
    }
    moveStart[nE] = moveOut.length;
    final moveOutL = Int32List.fromList(moveOut);

    final pts = Float32List(nC * 2 * kConnectorPoints);
    for (var c = 0; c < nC; c++) {
      final at = _draftOf[c] * 2 * kConnectorPoints;
      for (var k = 0; k < 2 * kConnectorPoints; k++) {
        pts[c * 2 * kConnectorPoints + k] = _dPts[at + k];
      }
    }

    _result = LaneGraph(
      graph: graph,
      stubNode: stubNode,
      controls: _ctl,
      roadEdgeCount: nE,
      edgeRoad: _edgeRoad,
      edgeFrom: graph.edgeFrom,
      edgeTo: graph.edgeTo,
      edgeForward: graph.edgeForward,
      edgeS0: _edgeS0,
      edgeS1: _edgeS1,
      edgeLen: _edgeLen,
      edgeLimit: _edgeLimit,
      edgeWType: _edgeWType,
      edgeTier: _edgeTier,
      edgeLaneBase: _edgeLaneBase,
      edgeLaneCount: _edgeLaneCount,
      edgeFlags: _edgeFlags,
      edgeReverse: _edgeReverse,
      edgeLaneS0: _edgeLaneS0,
      edgeLaneS1: _edgeLaneS1,
      edgeOutLeg: _edgeOutLeg,
      edgeInMainScc: _mainScc(nE, moveStart, moveOutL),
      moveStart: moveStart,
      moveOut: moveOutL,
      moveTurn: Uint8List.fromList(moveTurn),
      inStart: _inStart,
      inEdges: _inEdges,
      laneEdge: _laneEdge,
      laneIdx: _laneIdx,
      laneOff: _laneOff,
      laneConStart: _laneConStart,
      conNode: _conNode,
      conFromLane: _conFrom,
      conToLane: _conTo,
      conLen: _conLen,
      conVmax: _conVmax,
      conPen: _conPen,
      conTheta: _conTheta,
      conTurn: _conTurn,
      conKind: _conKind,
      conRole: rolesFor(_ctl, _conKind, _conFrom, _laneEdge),
      conPts: pts,
      conConflictStart: conflictStart,
      conflictWith: withId,
      conflictAtSelf: atSelf,
      conflictAtOther: atOther,
      nodeConStart: _nodeConStart,
      nodeCons: _nodeCons,
    );
  }

  /// 1 for each edge in the largest strongly connected part of the edge
  /// graph — ties to the part holding the lowest edge id. Tarjan's
  /// algorithm, iteratively, over the movements.
  static Uint8List _mainScc(int nE, Int32List moveStart, Int32List moveOut) {
    final index = Int32List(nE)..fillRange(0, nE, -1);
    final low = Int32List(nE);
    final onStack = Uint8List(nE);
    final stack = Int32List(nE);
    final callV = Int32List(nE), callIt = Int32List(nE);
    final comp = Int32List(nE)..fillRange(0, nE, -1);
    var next = 0, sp = 0, nComp = 0;
    var best = -1, bestSize = 0;
    for (var root = 0; root < nE; root++) {
      if (index[root] >= 0) continue;
      var csp = 0;
      index[root] = low[root] = next++;
      stack[sp++] = root;
      onStack[root] = 1;
      callV[csp] = root;
      callIt[csp++] = moveStart[root];
      while (csp > 0) {
        final v = callV[csp - 1];
        final it = callIt[csp - 1];
        if (it < moveStart[v + 1]) {
          callIt[csp - 1] = it + 1;
          final w = moveOut[it];
          if (index[w] < 0) {
            index[w] = low[w] = next++;
            stack[sp++] = w;
            onStack[w] = 1;
            callV[csp] = w;
            callIt[csp++] = moveStart[w];
          } else if (onStack[w] == 1 && index[w] < low[v]) {
            low[v] = index[w];
          }
          continue;
        }
        if (low[v] == index[v]) {
          var size = 0;
          while (true) {
            final w = stack[--sp];
            onStack[w] = 0;
            comp[w] = nComp;
            size++;
            if (w == v) break;
          }
          // Components complete in an order that depends only on ids, and
          // the first of the largest to complete wins.
          if (size > bestSize) {
            bestSize = size;
            best = nComp;
          }
          nComp++;
        }
        csp--;
        if (csp > 0) {
          final u = callV[csp - 1];
          if (low[v] < low[u]) low[u] = low[v];
        }
      }
    }
    final out = Uint8List(nE);
    for (var e = 0; e < nE; e++) {
      out[e] = comp[e] == best ? 1 : 0;
    }
    return out;
  }

  /// The first index of sorted [cum] at or after [x] ([cum]'s length when
  /// none is).
  static int _firstAtOrAfter(Float64List cum, double x) {
    var lo = 0, hi = cum.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
