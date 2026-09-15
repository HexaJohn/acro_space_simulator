// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a building meets the road, as a vehicle leaves or reaches it
/// (docs/plans/agent-traffic.md §3.10; site-access.md §2.3, §7.3).
///
/// A building's access is a JOIN: a place on a road where cars may turn in or
/// pull out. The road graph places up to four join slots per lot (§2.2) and
/// decided, per slot, the piece it hangs on, the arc along that piece's road,
/// which SIDE of the road polyline the lot lies on (`joinRight`), and from
/// which directions of travel it may be reached (`joinDirs`: either way on a
/// two-way road with one lane each way; only from its own side on anything
/// wider, whose median or four lanes a car may not cross mid-block; from the
/// travel direction on a one-way road). Slot 0 is the lot's own access, which
/// is what `lotPiece` / `lotS` / `lotDirs` hold (C1).
///
/// This file reads one join and adds the one thing a lane needs: the lane a
/// vehicle arrives in, which follows the side — the kerb lane when the
/// building is on its right, the innermost when it turns in across the road
/// or pulls up at a one-way road's left kerb (D6).
///
/// **The side comes from `joinRight`, never from the lot centroid** and never
/// from the `r` or `l` in a lot's id, which is named the other way round
/// (road-topology trap 14). A site with a plan reads the join columns the
/// plan COPIED at its sync ([ofPlanJoin]), so resolving a join costs no graph
/// look-up and holds for the side-street slot 2, which is not packed.
library;

import '../parcel.dart';
import '../road_graph.dart';
import '../site_access/site_access_constants.dart';
import '../site_access/site_access_plan.dart';
import '../site_access/site_join.dart';
import 'lane_graph.dart';

/// One join of one building, resolved onto a lane graph.
class AccessPoint {
  const AccessPoint._({
    required this.piece,
    required this.roadS,
    required this.dirs,
    required this.rightOfForward,
    required this.fwdEdge,
    required this.bwdEdge,
    required this.joinRef,
    required this.canIn,
    required this.canOut,
    required this.isCut,
  });

  /// The road-graph piece it hangs on, and the arc along that piece's road
  /// (on the road's own polyline).
  final int piece;
  final double roadS;

  /// `RoadGraph.forwardBit` / `backwardBit`: the directions of travel it is
  /// reached (and left) by.
  final int dirs;

  /// Whether the building lies to the right of the road's polyline, first
  /// point to last — the graph's or the plan's `joinRight`, never a centroid
  /// test of this file's own.
  final bool rightOfForward;

  /// The directed edges that serve it — running the polyline's way, and the
  /// other — or −1 for a direction that does not.
  final int fwdEdge, bwdEdge;

  /// The join's identity (site-access.md §2.3 join handles): a packed join
  /// index (≥ 0), `kJoinRefSideStreetBase − lot` for a corner lot's side
  /// street (≤ −2), or [kJoinRefNone] for a join no graph slot names — a
  /// footprint's own join.
  final int joinRef;

  /// Its role (§2.3 `SiteJoinRole`): whether a car may turn IN here, and
  /// whether one may pull OUT. A graph slot with no plan is both.
  final bool canIn, canOut;

  /// Whether a kerb CUT is built here, rather than a stop at the kerb: a
  /// plan's `joinKind`. A bare graph slot is no cut — it may ADMIT one
  /// (`kJoinCut`, the room the placer found), but nothing is built there
  /// until a plan says so, and a site with no current plan is kerbside
  /// (§0 Q5).
  final bool isCut;

  /// Whether [edge] is one of the edges that serve it.
  bool serves(int edge) => edge >= 0 && (edge == fwdEdge || edge == bwdEdge);

  /// Whether the building is on the right of travel along [edge].
  bool rightOfTravel(LaneGraph lg, int edge) =>
      lg.edgeForward[edge] == 1 ? rightOfForward : !rightOfForward;

  /// The lane (0 the kerb lane) a trip along [edge] arrives at the building
  /// in, and leaves it from: the kerb lane with the building on its right,
  /// the innermost with it on its left — a driveway turn across the road,
  /// or a one-way road's left kerb.
  int destLane(LaneGraph lg, int edge) =>
      rightOfTravel(lg, edge) ? 0 : lg.edgeLaneCount[edge] - 1;

  /// Where along [edge] (travel metres) the building is met, kept on the
  /// lane: a lot beside a junction is met at the stop bar, not on the plate.
  /// The clamp never fires for a cut join (site-access.md V1).
  double sOn(LaneGraph lg, int edge) {
    final t = lg.travelArc(edge, roadS);
    final lo = lg.edgeLaneS0[edge], hi = lg.edgeLaneS1[edge];
    return t < lo ? lo : (t > hi ? hi : t);
  }

  /// Whether no vehicle from the rest of the network can reach it and leave
  /// again: neither serving edge lies in the network's largest strongly
  /// connected part. Site-level reachability is per ROLE and lives on
  /// `BuildingTable`, which sees every join of the site; this is the one-join
  /// answer.
  bool isolated(LaneGraph lg) =>
      !(fwdEdge >= 0 && lg.edgeInMainScc[fwdEdge] == 1) &&
      !(bwdEdge >= 0 && lg.edgeInMainScc[bwdEdge] == 1);
}

/// Resolves joins onto a [LaneGraph]. Null means no access: no road within
/// reach, or a join this graph no longer holds.
class AccessPoints {
  AccessPoints._();

  /// The layout lot [lotId] (auto or hand-drawn), at its slot 0.
  static AccessPoint? ofLot(LaneGraph lg, String lotId) {
    final i = lg.graph.lotNoOf(lotId);
    return i == null ? null : ofLotIndex(lg, i);
  }

  /// The road graph's lot number [i], at its slot 0 — which is exactly what
  /// `lotPiece` / `lotS` / `lotDirs` hold (C1).
  static AccessPoint? ofLotIndex(LaneGraph lg, int i) {
    final g = lg.graph;
    if (i < 0 || i >= g.lotCount) return null;
    final k = g.lotJoinStart[i];
    return k < g.lotJoinStart[i + 1] ? ofJoin(lg, k) : null;
  }

  /// The join [joinRef] names (site-access.md §2.3): a packed join index
  /// (≥ 0) read straight off the graph's join columns, or a corner lot's
  /// side-street slot (≤ −2) placed by the graph on first ask. Null for
  /// [kJoinRefNone] and for a handle this graph does not hold.
  ///
  /// The side-street path allocates a `JoinSlot`, so it belongs to a sync or
  /// a test; nothing per sub-step resolves a join (§2.3, no look-up per
  /// sub-step). A site with a plan never comes here at all: its joins are
  /// [ofPlanJoin], off the columns the plan copied.
  static AccessPoint? ofJoin(LaneGraph lg, int joinRef) {
    final g = lg.graph;
    if (joinRef >= 0) {
      if (joinRef >= g.joinCount) return null;
      return _at(
        lg,
        g.joinPiece[joinRef],
        g.joinS[joinRef],
        g.joinDirs[joinRef],
        g.joinRight[joinRef] == 1,
        joinRef: joinRef,
      );
    }
    if (joinRef == kJoinRefNone) return null;
    final slot = g.joinOfRef(joinRef);
    return slot == null ? null : _ofSlot(lg, slot, joinRef);
  }

  /// Join [j] of [plan]: its COPIED `joinPiece`, `joinRoadS`, `joinDirs` and
  /// `joinRight`, with its role and kind (site-access.md §2.3). The plan's
  /// copies equal the graph slot's bit for bit while the plan is current
  /// (V3), so this agrees with [ofJoin] of the same `joinRef` — including
  /// slot 2, and including a footprint join no slot names.
  static AccessPoint? ofPlanJoin(LaneGraph lg, SiteAccessPlan plan, int j) {
    if (j < 0 || j >= plan.joinCount) return null;
    return _at(
      lg,
      plan.joinPiece(j),
      plan.joinRoadS(j),
      plan.joinDirs(j),
      plan.joinRight(j),
      joinRef: plan.joinRef(j),
      isCut: plan.joinIsCut(j),
      canIn: plan.joinCanIn(j),
      canOut: plan.joinCanOut(j),
    );
  }

  /// A building off the plat — one the colony's grid placed — with
  /// footprint [polygon]: slot 0 of the road graph's own footprint placer,
  /// the same call the routed model makes for it. Its side is the slot's,
  /// not a centroid test's, and it has no graph handle ([kJoinRefNone]).
  static AccessPoint? ofFootprint(LaneGraph lg, List<Vec2> polygon,
      {Vec2? centroid}) {
    final slots = lg.graph.attachFootprintJoins(polygon, centroid: centroid);
    return slots.isEmpty ? null : _ofSlot(lg, slots.first, kJoinRefNone);
  }

  static AccessPoint? _ofSlot(LaneGraph lg, JoinSlot slot, int joinRef) =>
      _at(lg, slot.piece, slot.s, slot.dirs, slot.right, joinRef: joinRef);

  static AccessPoint? _at(
    LaneGraph lg,
    int piece,
    double s,
    int dirs,
    bool right, {
    required int joinRef,
    bool isCut = false,
    bool canIn = true,
    bool canOut = true,
  }) {
    if (piece < 0 || piece >= lg.graph.pieceCount) return null;
    final g = lg.graph;
    return AccessPoint._(
      piece: piece,
      roadS: s,
      dirs: dirs,
      rightOfForward: right,
      fwdEdge: dirs & RoadGraph.forwardBit != 0 ? g.pieceFwdEdge[piece] : -1,
      bwdEdge: dirs & RoadGraph.backwardBit != 0 ? g.pieceBwdEdge[piece] : -1,
      joinRef: joinRef,
      canIn: canIn,
      canOut: canOut,
      isCut: isCut,
    );
  }
}
