// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// THE definition of site connectivity (docs/plans/site-access.md §2.5): the
/// directed lanes of one [SiteAccessPlan] and the links between them.
///
/// - Segment `k` gives lane `2k` (from→to) and `2k + 1` (to→from), present
///   per `segLaneMode`: `twoWay` and `sharedSingle` both, `oneWayForward`
///   only `2k`, `oneWayBackward` only `2k + 1`. `twoWay` lane centres sit at
///   ±width/4 right of travel; the others on the centreline ([laneOffsetM]).
/// - A MOVEMENT at node `n` from arriving lane `a` to leaving lane `b` exists
///   when they belong to different segments and the deflection is ≤ 150°
///   ([kSiteLinkMovement]), or when `n` is a turnaround and `b` is `a`
///   reversed ([kSiteLinkUTurn]).
/// - An `inline` stall of a `homeDriveway` plan links its pad's forward lane
///   to its backward lane ([kSiteLinkInlineStall]): a REVERSE-ONLY link (the
///   car parks nose-in and reverses out to the street, §7.4 Home back-out).
///   It is what connects a home pad's dead end `P`; no movement exists at
///   `P`. The link exists for `homeDriveway` plans only.
/// - A kerb node has site degree 1; its road side is reached only through
///   access events. So that "strongly connected" can mean anything for a
///   site, the road is modelled as ROAD links ([kSiteLinkRoad]) from every
///   out-capable cut join's out-lane to every in-capable cut join's in-lane.
///   They are never a path a car drives inside the site: a car leaves by an
///   EXIT event and comes back by an ENTER event.
///
/// Built by [SiteLaneGraph.of] at build and sync only; it allocates.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'site_access_constants.dart';
import 'site_access_plan.dart';

/// Link kinds ([SiteLaneGraph.linkKind]).
const int kSiteLinkMovement = 0;
const int kSiteLinkUTurn = 1;
const int kSiteLinkInlineStall = 2;
const int kSiteLinkRoad = 3;

/// The directed site network of one plan. See the library comment.
class SiteLaneGraph {
  SiteLaneGraph._({
    required this.plan,
    required this.present,
    required this.linkStart,
    required this.linkTo,
    required this.linkKind,
    required this.linkVia,
    required this.strongComponent,
    required this.componentCount,
    required Int32List inLanes,
    required Int32List outLanes,
  })  : _inLanes = inLanes,
        _outLanes = outLanes;

  final SiteAccessPlan plan;

  /// 1 where lane l exists.
  final Uint8List present;

  /// Links leaving lane l: `linkTo[linkStart[l] .. linkStart[l + 1] − 1]`,
  /// with their kind (`kSiteLink*`) and what they pass through: the node for
  /// a movement or U-turn, the stall for an inline-stall link, the target
  /// join for a road link.
  final Int32List linkStart, linkTo, linkVia;
  final Uint8List linkKind;

  /// Per lane, its strongly connected component (links of every kind
  /// counted), or −1 for an absent lane.
  final Int32List strongComponent;
  final int componentCount;

  final Int32List _inLanes, _outLanes;

  int get laneCount => present.length;
  int get linkCount => linkTo.length;

  /// Lane of segment [seg], from→to when [forward].
  static int laneOf(int seg, {required bool forward}) =>
      2 * seg + (forward ? 0 : 1);
  static int segOf(int lane) => lane >> 1;
  static bool isForward(int lane) => lane & 1 == 0;

  /// The same segment run the other way.
  static int reverseOf(int lane) => lane ^ 1;

  bool isPresent(int lane) => present[lane] == 1;

  /// The lane cars enter join [join] by (its throat leaving the kerb node),
  /// or −1 for a kerbside join or an absent lane.
  int inLane(int join) => _inLanes[join];

  /// The lane cars leave join [join] by (its throat toward the kerb node), or
  /// −1.
  int outLane(int join) => _outLanes[join];

  /// The node lane [lane] starts at and ends at.
  int startNode(int lane) => isForward(lane)
      ? plan.segFrom(segOf(lane))
      : plan.segTo(segOf(lane));
  int endNode(int lane) => isForward(lane)
      ? plan.segTo(segOf(lane))
      : plan.segFrom(segOf(lane));

  /// Metres right of travel of lane [lane]'s centre: ±width/4 on a `twoWay`
  /// segment, 0 otherwise.
  double laneOffsetM(int lane) =>
      plan.segLaneMode(segOf(lane)) == SiteLaneMode.twoWay
          ? plan.segWidthM(segOf(lane)) / 4
          : 0.0;

  /// The lane a car enters stall [stall] from, for direction bit [dir]
  /// ([kSiteDirFwd] / [kSiteDirBwd]).
  int stallLane(int stall, int dir) =>
      laneOf(plan.stallSeg(stall), forward: dir == kSiteDirFwd);

  /// Whether every present lane lies in one strongly connected component.
  bool get isStronglyConnected {
    var comp = -1;
    for (var l = 0; l < laneCount; l++) {
      if (present[l] == 0) continue;
      if (comp < 0) {
        comp = strongComponent[l];
      } else if (strongComponent[l] != comp) {
        return false;
      }
    }
    return true;
  }

  /// The present lanes of segment [seg] as `kSiteDir*` bits.
  static int presentDirs(SiteLaneMode mode) => switch (mode) {
        SiteLaneMode.twoWay || SiteLaneMode.sharedSingle =>
          kSiteDirFwd | kSiteDirBwd,
        SiteLaneMode.oneWayForward => kSiteDirFwd,
        SiteLaneMode.oneWayBackward => kSiteDirBwd,
      };

  /// The unit travel direction of lane [lane] where it leaves its start node
  /// ([atEnd] false) or arrives at its end node ([atEnd] true).
  (double, double) tangent(int lane, {required bool atEnd}) =>
      _tangent(plan, lane, atEnd: atEnd);

  static (double, double) _tangent(SiteAccessPlan p, int lane,
      {required bool atEnd}) {
    final k = segOf(lane);
    final n = p.segPointCount(k);
    // Along from→to: the first piece at the start, the last at the end.
    final fwd = isForward(lane);
    final useLast = fwd == atEnd;
    int a, b;
    if (useLast) {
      a = p.segPoint(k, n - 2);
      b = p.segPoint(k, n - 1);
    } else {
      a = p.segPoint(k, 0);
      b = p.segPoint(k, 1);
    }
    var de = p.ptE(b) - p.ptE(a), dn = p.ptN(b) - p.ptN(a);
    if (!fwd) {
      de = -de;
      dn = -dn;
    }
    final len = math.sqrt(de * de + dn * dn);
    if (len <= 1e-12) return (0.0, 0.0);
    return (de / len, dn / len);
  }

  /// The site lane graph of [plan].
  static SiteLaneGraph of(SiteAccessPlan plan) {
    final nSeg = plan.segCount;
    final nLane = 2 * nSeg;
    final nNode = plan.nodeCount;
    final present = Uint8List(nLane);
    for (var k = 0; k < nSeg; k++) {
      final dirs = presentDirs(plan.segLaneMode(k));
      if (dirs & kSiteDirFwd != 0) present[2 * k] = 1;
      if (dirs & kSiteDirBwd != 0) present[2 * k + 1] = 1;
    }
    bool nodeOk(int n) => n >= 0 && n < nNode;

    // Lanes arriving at / leaving each node, CSR by node.
    final arriveCount = Int32List(nNode + 1);
    final leaveCount = Int32List(nNode + 1);
    for (var l = 0; l < nLane; l++) {
      if (present[l] == 0) continue;
      final k = segOf(l);
      final from = plan.segFrom(k), to = plan.segTo(k);
      if (!nodeOk(from) || !nodeOk(to)) continue;
      final s = isForward(l) ? from : to;
      final e = isForward(l) ? to : from;
      arriveCount[e + 1]++;
      leaveCount[s + 1]++;
    }
    for (var n = 0; n < nNode; n++) {
      arriveCount[n + 1] += arriveCount[n];
      leaveCount[n + 1] += leaveCount[n];
    }
    final arrive = Int32List(arriveCount[nNode]);
    final leave = Int32List(leaveCount[nNode]);
    final aFill = Int32List.fromList(arriveCount.sublist(0, nNode));
    final lFill = Int32List.fromList(leaveCount.sublist(0, nNode));
    for (var l = 0; l < nLane; l++) {
      if (present[l] == 0) continue;
      final k = segOf(l);
      final from = plan.segFrom(k), to = plan.segTo(k);
      if (!nodeOk(from) || !nodeOk(to)) continue;
      final s = isForward(l) ? from : to;
      final e = isForward(l) ? to : from;
      arrive[aFill[e]++] = l;
      leave[lFill[s]++] = l;
    }

    final from = <int>[], to = <int>[], kind = <int>[], via = <int>[];
    void link(int a, int b, int k, int v) {
      from.add(a);
      to.add(b);
      kind.add(k);
      via.add(v);
    }

    // Movements and U-turns, node by node.
    for (var n = 0; n < nNode; n++) {
      final turn = plan.nodeTurnKind(n) != TurnaroundKind.none;
      for (var i = arriveCount[n]; i < arriveCount[n + 1]; i++) {
        final a = arrive[i];
        final (ae, an) = _tangent(plan, a, atEnd: true);
        for (var j = leaveCount[n]; j < leaveCount[n + 1]; j++) {
          final b = leave[j];
          if (segOf(a) == segOf(b)) {
            if (turn && b == reverseOf(a)) link(a, b, kSiteLinkUTurn, n);
            continue;
          }
          final (be, bn) = _tangent(plan, b, atEnd: false);
          if (ae * be + an * bn >= kCos150) link(a, b, kSiteLinkMovement, n);
        }
      }
    }

    // Inline stalls of a home pad: forward lane to backward lane.
    if (plan.program == SiteProgram.homeDriveway) {
      for (var i = 0; i < plan.stallCount; i++) {
        if (plan.stallAngle(i) != StallAngle.inline) continue;
        final k = plan.stallSeg(i);
        if (k < 0 || k >= nSeg) continue;
        if (present[2 * k] == 1 && present[2 * k + 1] == 1) {
          link(2 * k, 2 * k + 1, kSiteLinkInlineStall, i);
        }
      }
    }

    // Joins: in and out lanes, and the road between them.
    final nJ = plan.joinCount;
    final inLanes = Int32List(nJ)..fillRange(0, nJ, -1);
    final outLanes = Int32List(nJ)..fillRange(0, nJ, -1);
    for (var j = 0; j < nJ; j++) {
      if (plan.joinKind(j) != SiteJoinKind.cut) continue;
      final t = plan.joinThroatSeg(j), kn = plan.joinKerbNode(j);
      if (t < 0 || t >= nSeg || !nodeOk(kn)) continue;
      final fromKerb = plan.segFrom(t) == kn;
      if (!fromKerb && plan.segTo(t) != kn) continue;
      final li = fromKerb ? 2 * t : 2 * t + 1;
      final lo = reverseOf(li);
      if (present[li] == 1) inLanes[j] = li;
      if (present[lo] == 1) outLanes[j] = lo;
    }
    for (var j = 0; j < nJ; j++) {
      if (!plan.joinCanOut(j) || outLanes[j] < 0) continue;
      for (var j2 = 0; j2 < nJ; j2++) {
        if (!plan.joinCanIn(j2) || inLanes[j2] < 0) continue;
        link(outLanes[j], inLanes[j2], kSiteLinkRoad, j2);
      }
    }

    // CSR by source lane, stable.
    final linkStart = Int32List(nLane + 1);
    for (final a in from) {
      linkStart[a + 1]++;
    }
    for (var l = 0; l < nLane; l++) {
      linkStart[l + 1] += linkStart[l];
    }
    final nL = from.length;
    final linkTo = Int32List(nL);
    final linkKind = Uint8List(nL);
    final linkVia = Int32List(nL);
    final fill = Int32List.fromList(linkStart.sublist(0, math.max(nLane, 0)));
    for (var i = 0; i < nL; i++) {
      final at = fill[from[i]]++;
      linkTo[at] = to[i];
      linkKind[at] = kind[i];
      linkVia[at] = via[i];
    }

    final (comp, count) = _tarjan(nLane, present, linkStart, linkTo);
    return SiteLaneGraph._(
      plan: plan,
      present: present,
      linkStart: linkStart,
      linkTo: linkTo,
      linkKind: linkKind,
      linkVia: linkVia,
      strongComponent: comp,
      componentCount: count,
      inLanes: inLanes,
      outLanes: outLanes,
    );
  }

  /// Iterative Tarjan over the present lanes; components numbered in the
  /// order they complete.
  static (Int32List, int) _tarjan(
      int n, Uint8List present, Int32List start, Int32List to) {
    final index = Int32List(n)..fillRange(0, n, -1);
    final low = Int32List(n);
    final comp = Int32List(n)..fillRange(0, n, -1);
    final onStack = Uint8List(n);
    final stack = Int32List(n);
    var sp = 0;
    final callNode = Int32List(n);
    final callEdge = Int32List(n);
    var next = 0, count = 0;
    for (var root = 0; root < n; root++) {
      if (present[root] == 0 || index[root] >= 0) continue;
      var depth = 0;
      callNode[0] = root;
      callEdge[0] = start[root];
      index[root] = low[root] = next++;
      stack[sp++] = root;
      onStack[root] = 1;
      while (depth >= 0) {
        final v = callNode[depth];
        if (callEdge[depth] < start[v + 1]) {
          final w = to[callEdge[depth]++];
          if (present[w] == 0) continue;
          if (index[w] < 0) {
            index[w] = low[w] = next++;
            stack[sp++] = w;
            onStack[w] = 1;
            depth++;
            callNode[depth] = w;
            callEdge[depth] = start[w];
          } else if (onStack[w] == 1 && index[w] < low[v]) {
            low[v] = index[w];
          }
          continue;
        }
        if (low[v] == index[v]) {
          int w;
          do {
            w = stack[--sp];
            onStack[w] = 0;
            comp[w] = count;
          } while (w != v);
          count++;
        }
        depth--;
        if (depth >= 0) {
          final u = callNode[depth];
          if (low[v] < low[u]) low[u] = low[v];
        }
      }
    }
    return (comp, count);
  }
}
