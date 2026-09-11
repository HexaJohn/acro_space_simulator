// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Which lane may reach which at a node, and the shape of the path between
/// them (docs/plans/agent-traffic.md §3.5, §3.6).
///
/// A connector is the ONLY place a vehicle changes lane: it runs from the
/// end of one lane of an arriving edge, across the node, to the start of one
/// lane of a leaving edge. The rules decide which pairs exist, and they are
/// written so that a new trip — free to enter any lane of its first edge —
/// can drive ANY edge sequence the router returns: every movement's band
/// holds at least one lane (rule 1), every lane of every movement's out-edge
/// is fed (rules 2 and 3). A router that could return an undrivable
/// sequence would need a retry loop; these rules make it unnecessary.
///
/// The rules read a node as a set of [NodeArm]s, never the city, so they can
/// be tested on a node described by hand (lane_connectors_test).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import 'agent_kind.dart';
import 'node_control.dart';

/// A movement's turn, by the angle between the arriving and the leaving
/// direction (§3.5). Append-only: the lane graph stores the index.
enum TurnClass { straight, right, left, sharp, uTurn }

/// What a connector IS in the lane rules — fixed for a graph's life, and
/// what the lane planner's penalty is read from. Append-only.
enum ConnectorKind {
  /// Rule 2: in-lane `n−1−t` to out-lane `M−1−t` on the straight — the lane
  /// a driver simply stays in.
  aligned,

  /// Rule 2's lane add: the kerb in-lane also feeds the new kerb lanes.
  fanOut,

  /// Rule 2's lane drop: an in-lane with no lane ahead merges into the kerb
  /// lane.
  dropped,

  /// Rule 5: straight on into the lane beside the aligned one — the lane
  /// change a real junction allows.
  shift,

  /// Rules 1 and 3: a turn, into any lane of the edge it turns onto.
  turn,

  /// Rule 4: a ramp's lane into the mainline's kerb lane.
  merge,

  /// Rule 4: the mainline's kerb lane onto a ramp leaving it.
  diverge,

  /// §3.6: round, into the other direction of the same stretch.
  uTurn,
}

/// How a connector enters its node: who it gives way to (§3.5 `conRole`).
/// Unlike [ConnectorKind] this follows the node's control, so a patched
/// graph (a light switched on) recomputes it. Append-only.
enum ConnectorRole { priority, yield, mergeYield, droppedLane, shift, uTurn }

/// Below this angle a movement is straight on; above [kSharpRad] it is a
/// sharp turn.
const double kStraightRad = 30 * math.pi / 180;
const double kSharpRad = 135 * math.pi / 180;

/// The lane planner's charge per connector, §4.5: a natural landing or the
/// aligned lane costs nothing; a lane add or drop half a lane; a rule-5
/// shift one lane; a turn one per lane away from its natural landing.
const double kPenFanOut = 0.5;
const double kPenDropped = 0.5;
const double kPenShift = 1.0;
const double kPenPerLaneAway = 1.0;

/// The lateral acceleration a connector's speed is capped by: `v = √(3·R)`,
/// so a turn of radius 8 m takes 4.9 m/s.
const double kConLateralAccel = 3.0;

/// A connector that barely curves is capped here, not at infinity: faster
/// than any road's limit, and finite for the arithmetic that reads it.
const double kConVmaxCap = 50.0;

/// The tightest a U-turn is taken as, however narrow the road (§3.6).
const double kMinUTurnRadiusM = 4.0;

/// The angle from arriving direction (inE, inN) to leaving direction
/// (outE, outN), radians: negative is a right turn in the east–north frame.
double turnAngle(double inE, double inN, double outE, double outN) =>
    math.atan2(inE * outN - inN * outE, inE * outE + inN * outN);

/// The class of a movement turning through [theta].
TurnClass turnClassOf(double theta) {
  final a = theta.abs();
  if (a > kSharpRad) return TurnClass.sharp;
  if (a < kStraightRad) return TurnClass.straight;
  return theta < 0 ? TurnClass.right : TurnClass.left;
}

/// Rule 1: whether in-lane [lane] of [n] may make movement [movement] of
/// [m] (movements numbered right to left). Movement j owns `[j·n/m,
/// (j+1)·n/m)` of the lanes and lane i owns `[i, i+1)`; they overlap when
/// `j·n/m < i+1` and `(j+1)·n/m > i` — compared here multiplied through by
/// [m], so it is exact.
bool bandOverlaps(int lane, int movement, int n, int m) =>
    movement * n < (lane + 1) * m && (movement + 1) * n > lane * m;

/// Rule 2's median alignment: the out-lane (of [m]) in-lane [lane] (of [n])
/// runs straight into, or −1 for a dropped lane. Lanes pair off from the
/// median outwards, so a road that loses a lane loses its kerb lane.
int alignedLane(int lane, int n, int m) {
  final t = n - 1 - lane;
  return t < m ? m - 1 - t : -1;
}

/// One directed edge meeting a node, as the rules see it.
class NodeArm {
  const NodeArm({
    required this.edge,
    required this.lanes,
    required this.roadClass,
    this.reverse = -1,
    required this.dirE,
    required this.dirN,
    this.endE = 0,
    this.endN = 0,
  });

  final int edge;
  final int lanes;
  final RoadClass roadClass;

  /// The same stretch's other direction, or −1 on a one-way road: the edge
  /// a U-turn from this one leaves by.
  final int reverse;

  /// Unit travel direction AT the node: arriving for an in-arm, leaving for
  /// an out-arm.
  final double dirE, dirN;

  /// Where this arm's road end lies from the node, metres — which side of a
  /// mainline a ramp joins or leaves on.
  final double endE, endN;

  bool get isRamp => roadClass == RoadClass.ramp;
}

/// Receives one connector: from lane [fromLane] of [from] to lane [toLane]
/// of [to].
typedef ConnectorSink = void Function(NodeArm from, int fromLane, NodeArm to,
    int toLane, ConnectorKind kind, TurnClass turn, double theta, double pen);

/// Every connector at a node of [kind], from the arriving arms [ins] to the
/// leaving arms [outs], in a fixed order: arm by arm as given, lane by lane.
///
/// - Turning places (dead ends, stubs, a deck ending in the air): every
///   in-lane to every lane of the reverse edge.
/// - Continuations: rule 2's alignment into every leaving edge but the
///   reverse, whatever the bend — the road carries on, so the movement is
///   classed straight.
/// - Ramp merges (rule 4): the mainline aligned; a ramp's lane into the kerb
///   lane of the carriageway on its side; the kerb lane of the carriageway
///   a ramp leaves from onto the ramp.
/// - Real junctions: turn bands (rule 1), straight from every aligned lane
///   (rule 2) with rule 5's shifts, turns into any lane (rule 3); and at a
///   roundabout a U-turn from the innermost lane.
///
/// Whatever the kind, an arriving edge that could leave the node but was
/// given no connector gets rule 2's alignment onto its straightest way on,
/// so no road the rules did not foresee becomes a trap.
void connectNode(NodeControlKind kind, List<NodeArm> ins, List<NodeArm> outs,
    ConnectorSink emit) {
  final served = List<bool>.filled(ins.length, false);
  void out(NodeArm from, int fromLane, NodeArm to, int toLane,
      ConnectorKind k, TurnClass turn, double theta, double pen) {
    for (var i = 0; i < ins.length; i++) {
      if (identical(ins[i], from)) served[i] = true;
    }
    emit(from, fromLane, to, toLane, k, turn, theta, pen);
  }

  if (isTurningPlace(kind)) {
    for (final a in ins) {
      final rev = _armOf(outs, a.reverse);
      if (rev != null) _uTurns(a, rev, false, out);
    }
    return;
  }
  switch (kind) {
    case NodeControlKind.continuation:
      for (final a in ins) {
        for (final o in outs) {
          if (o.edge == a.reverse) continue;
          _straight(a, o, TurnClass.straight, _theta(a, o), false, out);
        }
      }
    case NodeControlKind.rampMerge:
      _rampMerge(ins, outs, out);
    case NodeControlKind.stop:
    case NodeControlKind.allWayStop:
    case NodeControlKind.signals:
    case NodeControlKind.roundabout:
    case NodeControlKind.uncontrolled:
      for (final a in ins) {
        _junction(a, outs, kind == NodeControlKind.roundabout, out);
      }
    case NodeControlKind.deadEnd:
    case NodeControlKind.stub:
    case NodeControlKind.danglingDeck:
      break;
  }

  // The safety net: nothing that can leave is left without a way to.
  for (var i = 0; i < ins.length; i++) {
    if (served[i]) continue;
    final a = ins[i];
    NodeArm? best;
    var bestAbs = double.infinity;
    for (final o in outs) {
      if (o.edge == a.reverse) continue;
      final t = _theta(a, o).abs();
      if (t < bestAbs) {
        bestAbs = t;
        best = o;
      }
    }
    if (best != null) {
      _straight(a, best, TurnClass.straight, _theta(a, best), false, out);
    }
  }
}

NodeArm? _armOf(List<NodeArm> arms, int edge) {
  if (edge < 0) return null;
  for (final a in arms) {
    if (a.edge == edge) return a;
  }
  return null;
}

double _theta(NodeArm from, NodeArm to) =>
    turnAngle(from.dirE, from.dirN, to.dirE, to.dirN);

/// Which side of travel direction (dirE, dirN) the point (pE, pN) lies
/// on: negative is the right.
double _side(double dirE, double dirN, double pE, double pN) =>
    dirE * pN - dirN * pE;

/// Rule 2 from [a] onto [o], and rule 5's shifts when [shifts]: aligned
/// lanes, the dropped lanes into the kerb lane, the added lanes fed from the
/// kerb lane, and each aligned lane also into its neighbours.
void _straight(NodeArm a, NodeArm o, TurnClass turn, double theta, bool shifts,
    ConnectorSink emit) {
  final n = a.lanes, m = o.lanes;
  for (var i = 0; i < n; i++) {
    final al = alignedLane(i, n, m);
    if (al >= 0) {
      emit(a, i, o, al, ConnectorKind.aligned, turn, theta, 0);
    } else {
      emit(a, i, o, 0, ConnectorKind.dropped, turn, theta, kPenDropped);
    }
  }
  for (var l = 0; l < m - n; l++) {
    emit(a, 0, o, l, ConnectorKind.fanOut, turn, theta, kPenFanOut);
  }
  if (!shifts) return;
  for (var i = 0; i < n; i++) {
    final al = alignedLane(i, n, m);
    if (al < 0) continue;
    for (var d = -1; d <= 1; d += 2) {
      final l = al + d;
      if (l < 0 || l >= m) continue;
      // The kerb lane's fan-out already reaches the added lanes.
      if (i == 0 && l < m - n) continue;
      emit(a, i, o, l, ConnectorKind.shift, turn, theta, kPenShift);
    }
  }
}

/// Every lane of [a] (or only its innermost, [innermostOnly]) round into
/// every lane of [rev].
void _uTurns(
    NodeArm a, NodeArm rev, bool innermostOnly, ConnectorSink emit) {
  final m = rev.lanes;
  for (var i = innermostOnly ? a.lanes - 1 : 0; i < a.lanes; i++) {
    for (var l = 0; l < m; l++) {
      // At a roundabout the natural landing is the innermost lane, as a
      // left turn's is; a dead end's turning circle has none.
      final pen = innermostOnly ? (m - 1 - l) * kPenPerLaneAway : 0.0;
      emit(a, i, rev, l, ConnectorKind.uTurn, TurnClass.uTurn, math.pi, pen);
    }
  }
}

/// Rules 1, 2, 3 and 5 for one arriving arm [a] at a real junction.
void _junction(
    NodeArm a, List<NodeArm> outs, bool roundabout, ConnectorSink emit) {
  // The movements: every leaving arm but the U-turn, right to left.
  final moves = <NodeArm>[
    for (final o in outs)
      if (o.edge != a.reverse) o,
  ];
  final theta = <double>[for (final o in moves) _theta(a, o)];
  final order = List<int>.generate(moves.length, (i) => i)
    ..sort((x, y) {
      final c = theta[x].compareTo(theta[y]);
      return c != 0 ? c : moves[x].edge.compareTo(moves[y].edge);
    });
  // The straight: the leaving arm nearest dead ahead, within 30°.
  var straight = -1;
  var best = kStraightRad;
  for (final j in order) {
    final t = theta[j].abs();
    if (t < best) {
      best = t;
      straight = j;
    }
  }
  final n = a.lanes, m = order.length;
  for (var band = 0; band < m; band++) {
    final j = order[band];
    final o = moves[j];
    if (j == straight) {
      _straight(a, o, TurnClass.straight, theta[j], true, emit);
      continue;
    }
    final turn = turnClassOf(theta[j]);
    // A right turn lands naturally in the kerb lane, a left in the
    // innermost; any other landing costs a lane's worth per lane away.
    final natural = theta[j] < 0 ? 0 : o.lanes - 1;
    for (var i = 0; i < n; i++) {
      if (!bandOverlaps(i, band, n, m)) continue;
      for (var l = 0; l < o.lanes; l++) {
        emit(a, i, o, l, ConnectorKind.turn, turn, theta[j],
            (l - natural).abs() * kPenPerLaneAway);
      }
    }
  }
  if (roundabout) {
    final rev = _armOf(outs, a.reverse);
    if (rev != null) _uTurns(a, rev, true, emit);
  }
}

/// Rule 4 at a ramp merge (or diverge, or both).
void _rampMerge(List<NodeArm> ins, List<NodeArm> outs, ConnectorSink emit) {
  // The mainline runs on, aligned lane for lane.
  final fed = <int>[], through = <int>[];
  for (final a in ins) {
    if (a.isRamp) continue;
    for (final o in outs) {
      if (o.isRamp || o.edge == a.reverse) continue;
      _straight(a, o, TurnClass.straight, _theta(a, o), false, emit);
      fed.add(o.edge);
      if (!through.contains(a.edge)) through.add(a.edge);
    }
  }
  // A ramp leaving: from the kerb lane of the carriageway it leaves on the
  // right of — the straightest such; failing one, the straightest. Where
  // that carriageway goes no further and the ramp IS its way on, every lane
  // runs onto the ramp, as at any lane drop, rather than strand all but the
  // kerb lane.
  for (final r in outs) {
    if (!r.isRamp) continue;
    NodeArm? from;
    var fromRight = false;
    var fromAbs = double.infinity;
    for (final a in ins) {
      if (a.isRamp || a.reverse == r.edge) continue;
      final right = _side(a.dirE, a.dirN, r.endE, r.endN) < 0;
      final t = _theta(a, r).abs();
      if ((right && !fromRight) || (right == fromRight && t < fromAbs)) {
        from = a;
        fromRight = right;
        fromAbs = t;
      }
    }
    if (from == null) continue;
    if (through.contains(from.edge)) {
      emit(from, 0, r, 0, ConnectorKind.diverge, TurnClass.straight,
          _theta(from, r), 0);
    } else {
      _straight(from, r, TurnClass.straight, _theta(from, r), false, emit);
    }
  }
  // A ramp arriving: into the kerb lane of the carriageway on its side, and
  // nothing else — never the far carriageway. Where it lands on the very
  // end of a mainline that nothing else feeds, it IS the mainline's start,
  // and feeds every lane.
  for (final r in ins) {
    if (!r.isRamp) continue;
    NodeArm? to;
    var toRight = false;
    var toAbs = double.infinity;
    for (final o in outs) {
      if (o.isRamp) continue;
      // Half a metre off the mainline's line: a ramp that ends ON the
      // mainline's end has no side.
      final right = _side(o.dirE, o.dirN, r.endE, r.endN) < -0.5;
      final t = _theta(r, o).abs();
      if ((right && !toRight) || (right == toRight && t < toAbs)) {
        to = o;
        toRight = right;
        toAbs = t;
      }
    }
    if (to == null) continue;
    if (fed.contains(to.edge)) {
      for (var i = 0; i < r.lanes; i++) {
        emit(r, i, to, 0, ConnectorKind.merge, TurnClass.straight,
            _theta(r, to), 0);
      }
    } else {
      _straight(r, to, TurnClass.straight, _theta(r, to), false, emit);
    }
  }
}

// ---- Geometry ---------------------------------------------------------------

/// Points each connector's path is sampled at: its length is measured on
/// them, conflicts are found between them, and the renderer lerps along
/// them, so all three agree.
const int kConnectorPoints = 8;

/// The quadratic Bézier from P0 (heading d0, a unit vector) to P2 (heading
/// d2), its control point where the two headings' lines cross — clamped to
/// twice the chord, and at the chord's middle where they do not cross ahead
/// of both. Its [kConnectorPoints] points go into [pts] from [at] (east,
/// north pairs); returns its length along them and its tightest radius.
({double length, double rMin}) connectorCurve(
    double p0e,
    double p0n,
    double d0e,
    double d0n,
    double p2e,
    double p2n,
    double d2e,
    double d2n,
    Float64List pts,
    int at) {
  final ce = p2e - p0e, cn = p2n - p0n;
  final chord = math.sqrt(ce * ce + cn * cn);
  var p1e = (p0e + p2e) / 2, p1n = (p0n + p2n) / 2;
  final den = d0e * d2n - d0n * d2e;
  if (den.abs() > 1e-6) {
    // P0 + a·d0 = P2 − b·d2.
    final a = (ce * d2n - cn * d2e) / den;
    final b = (d0e * cn - d0n * ce) / den;
    if (a > 0 && b > 0) {
      final cap = 2 * chord;
      if (a <= cap && b <= cap) {
        p1e = p0e + d0e * a;
        p1n = p0n + d0n * a;
      } else {
        final ac = math.min(a, cap), bc = math.min(b, cap);
        p1e = ((p0e + d0e * ac) + (p2e - d2e * bc)) / 2;
        p1n = ((p0n + d0n * ac) + (p2n - d2n * bc)) / 2;
      }
    }
  }
  var len = 0.0;
  var pe = p0e, pn = p0n;
  for (var k = 0; k < kConnectorPoints; k++) {
    final t = k / (kConnectorPoints - 1);
    final u = 1 - t;
    final e = u * u * p0e + 2 * u * t * p1e + t * t * p2e;
    final n = u * u * p0n + 2 * u * t * p1n + t * t * p2n;
    pts[at + 2 * k] = e;
    pts[at + 2 * k + 1] = n;
    if (k > 0) {
      final de = e - pe, dn = n - pn;
      len += math.sqrt(de * de + dn * dn);
    }
    pe = e;
    pn = n;
  }
  return (length: len, rMin: quadraticMinRadius(p0e, p0n, p1e, p1n, p2e, p2n));
}

/// The tightest radius of the quadratic Bézier P0, P1, P2, exactly.
///
/// Its second derivative is constant, so `B′ × B″ = 4·(u × v)` (u = P1 − P0,
/// v = P2 − P1) is too, and the curvature is greatest where the speed
/// `|B′| = 2·|u + t(v − u)|` is least: `R = 2·|w|³ / |u × v|` at that t.
/// A parabola is tighter at its apex than the circle through its ends —
/// a symmetric right-angle turn of legs L bends at L/√2, not L.
double quadraticMinRadius(
    double p0e, double p0n, double p1e, double p1n, double p2e, double p2n) {
  final ue = p1e - p0e, un = p1n - p0n;
  final ve = p2e - p1e, vn = p2n - p1n;
  final cross = (ue * vn - un * ve).abs();
  if (cross < 1e-9) return double.infinity;
  final de = ve - ue, dn = vn - un;
  final dd = de * de + dn * dn;
  final t = dd < 1e-12 ? 0.0 : (-(ue * de + un * dn) / dd).clamp(0.0, 1.0);
  final we = ue + t * de, wn = un + t * dn;
  final w = math.sqrt(we * we + wn * wn);
  return 2 * w * w * w / cross;
}

/// A U-turn from P0 (heading d0) round to P2, across the road: a half
/// ellipse ahead of P0, its cross axis the gap between the lanes and its
/// reach at least [kMinUTurnRadiusM]. Its length is the design's semicircle
/// of radius half the gap, and never tighter than [kMinUTurnRadiusM].
({double length, double rMin}) uTurnCurve(double p0e, double p0n, double d0e,
    double d0n, double p2e, double p2n, Float64List pts, int at) {
  final ce = (p0e + p2e) / 2, cn = (p0n + p2n) / 2;
  final he = p0e - ce, hn = p0n - cn;
  final r = math.sqrt(he * he + hn * hn);
  final reach = math.max(kMinUTurnRadiusM, r);
  for (var k = 0; k < kConnectorPoints; k++) {
    final phi = math.pi * k / (kConnectorPoints - 1);
    final c = math.cos(phi), s = math.sin(phi);
    pts[at + 2 * k] = ce + he * c + d0e * reach * s;
    pts[at + 2 * k + 1] = cn + hn * c + d0n * reach * s;
  }
  return (length: math.pi * reach, rMin: reach);
}

/// The speed a connector of tightest radius [rMin] is taken at.
double connectorVmax(double rMin) => rMin.isInfinite
    ? kConVmaxCap
    : math.min(kConVmaxCap, math.sqrt(kConLateralAccel * rMin));

/// Where the path at [a] in [pts] first crosses the path at [b] in [ptsB]
/// (each [kConnectorPoints] points): metres along each path, or null where
/// they never cross. "First" is along [a], then along [b].
({double arcA, double arcB})? firstCrossing(
    Float64List pts, int a, Float64List ptsB, int b) {
  var bestA = double.infinity, bestB = double.infinity;
  var arcA = 0.0;
  for (var i = 0; i + 1 < kConnectorPoints; i++) {
    // A crossing already found strictly before this segment starts is
    // before anything this segment or a later one can hold.
    if (bestA < arcA) break;
    final a0e = pts[a + 2 * i], a0n = pts[a + 2 * i + 1];
    final a1e = pts[a + 2 * i + 2], a1n = pts[a + 2 * i + 3];
    final re = a1e - a0e, rn = a1n - a0n;
    final lenA = math.sqrt(re * re + rn * rn);
    // Plain comparisons: math.min and math.max take nums, and cost more
    // than the test they would save.
    final aLoE = a0e < a1e ? a0e : a1e, aHiE = a0e < a1e ? a1e : a0e;
    final aLoN = a0n < a1n ? a0n : a1n, aHiN = a0n < a1n ? a1n : a0n;
    var arcB = 0.0;
    for (var j = 0; j + 1 < kConnectorPoints; j++) {
      final b0e = ptsB[b + 2 * j], b0n = ptsB[b + 2 * j + 1];
      final b1e = ptsB[b + 2 * j + 2], b1n = ptsB[b + 2 * j + 3];
      final se = b1e - b0e, sn = b1n - b0n;
      final lenB = math.sqrt(se * se + sn * sn);
      final den = re * sn - rn * se;
      // Two segments whose boxes do not touch cannot cross.
      final apart = (b0e < b1e ? b1e : b0e) < aLoE ||
          (b0e < b1e ? b0e : b1e) > aHiE ||
          (b0n < b1n ? b1n : b0n) < aLoN ||
          (b0n < b1n ? b0n : b1n) > aHiN;
      if (!apart && den.abs() > 1e-12) {
        final qe = b0e - a0e, qn = b0n - a0n;
        final t = (qe * sn - qn * se) / den;
        final u = (qe * rn - qn * re) / den;
        if (t >= 0 && t <= 1 && u >= 0 && u <= 1) {
          final atA = arcA + t * lenA, atB = arcB + u * lenB;
          if (atA < bestA || (atA == bestA && atB < bestB)) {
            bestA = atA;
            bestB = atB;
          }
        }
      }
      arcB += lenB;
    }
    arcA += lenA;
  }
  if (bestA.isInfinite) return null;
  return (arcA: bestA, arcB: bestB);
}

/// The length of the path at [at] in [pts], along its points.
double pathLength(Float64List pts, int at) {
  var len = 0.0;
  for (var k = 1; k < kConnectorPoints; k++) {
    final de = pts[at + 2 * k] - pts[at + 2 * k - 2];
    final dn = pts[at + 2 * k + 1] - pts[at + 2 * k - 1];
    len += math.sqrt(de * de + dn * dn);
  }
  return len;
}
