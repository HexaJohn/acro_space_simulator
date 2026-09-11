// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a building meets the road, as a vehicle leaves or reaches it
/// (docs/plans/agent-traffic.md §3.10).
///
/// The road graph already decided where every lot hangs — an auto lot on its
/// frontage road at its frontage midpoint, a hand-drawn lot and a grid
/// building on the nearest road within 90 m of any part of them — and from
/// which directions of travel it may be reached (`lotDirs`: either way on a
/// two-way road with one lane each way; only from its own side on anything
/// wider, whose median or four lanes a car may not cross mid-block; from the
/// travel direction on a one-way road). This file reads that, and adds the
/// one thing a lane needs: which SIDE of the road the building is on, which
/// decides the lane a vehicle arrives in — the kerb lane when the building is
/// on its right, the innermost when it turns in across the road or pulls up
/// at a one-way road's left kerb.
///
/// The side comes from geometry, never from the `r` or `l` in a lot's id,
/// which is named the other way round (road-topology trap 14).
library;

import 'dart:typed_data';

import '../parcel.dart';
import '../road_graph.dart';
import '../spatial_index.dart';
import 'lane_graph.dart';

/// One building's place on the network.
class AccessPoint {
  const AccessPoint._({
    required this.piece,
    required this.roadS,
    required this.dirs,
    required this.rightOfForward,
    required this.fwdEdge,
    required this.bwdEdge,
  });

  /// The road-graph piece it hangs on, and the arc along that piece's road
  /// (on the road's own polyline).
  final int piece;
  final double roadS;

  /// `RoadGraph.forwardBit` / `backwardBit`: the directions of travel it is
  /// reached (and left) by.
  final int dirs;

  /// Whether the building lies to the right of the road's polyline, first
  /// point to last.
  final bool rightOfForward;

  /// The directed edges that serve it — running the polyline's way, and the
  /// other — or −1 for a direction that does not.
  final int fwdEdge, bwdEdge;

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
  double sOn(LaneGraph lg, int edge) {
    final t = lg.travelArc(edge, roadS);
    final lo = lg.edgeLaneS0[edge], hi = lg.edgeLaneS1[edge];
    return t < lo ? lo : (t > hi ? hi : t);
  }

  /// Whether no vehicle from the rest of the network can reach it and leave
  /// again: neither serving edge lies in the network's largest strongly
  /// connected part.
  bool isolated(LaneGraph lg) =>
      !(fwdEdge >= 0 && lg.edgeInMainScc[fwdEdge] == 1) &&
      !(bwdEdge >= 0 && lg.edgeInMainScc[bwdEdge] == 1);
}

/// Resolves buildings onto a [LaneGraph]. Null means no access: no road
/// within reach.
class AccessPoints {
  AccessPoints._();

  /// The layout lot [lotId] (auto or hand-drawn).
  static AccessPoint? ofLot(LaneGraph lg, String lotId) {
    final i = lg.graph.lotNoOf(lotId);
    return i == null ? null : ofLotIndex(lg, i);
  }

  /// The road graph's lot number [i].
  static AccessPoint? ofLotIndex(LaneGraph lg, int i) {
    final g = lg.graph;
    final p = g.lotPiece[i];
    if (p < 0) return null;
    return _at(lg, p, g.lotS[i], g.lotDirs[i], Vec2(g.lotE[i], g.lotN[i]));
  }

  /// A building off the plat — one the colony's grid placed — with
  /// footprint [polygon]: the road graph's own attach, the same call the
  /// routed model makes for it.
  static AccessPoint? ofFootprint(LaneGraph lg, List<Vec2> polygon,
      {Vec2? centroid}) {
    final hit = lg.graph.attachFootprint(polygon, centroid: centroid);
    if (hit == null) return null;
    var c = centroid;
    if (c == null) {
      var e = 0.0, n = 0.0;
      for (final v in polygon) {
        e += v.e;
        n += v.n;
      }
      c = Vec2(e / polygon.length, n / polygon.length);
    }
    return _at(lg, hit.piece, hit.sM, hit.dirs, c);
  }

  static AccessPoint _at(
      LaneGraph lg, int piece, double s, int dirs, Vec2 centroid) {
    final g = lg.graph;
    final rec = g.roadRecs[g.pieceRoad[piece]];
    return AccessPoint._(
      piece: piece,
      roadS: s,
      dirs: dirs,
      rightOfForward: rightOf(rec, s, centroid),
      fwdEdge: dirs & RoadGraph.forwardBit != 0 ? g.pieceFwdEdge[piece] : -1,
      bwdEdge: dirs & RoadGraph.backwardBit != 0 ? g.pieceBwdEdge[piece] : -1,
    );
  }

  /// Whether [p] lies to the right of road [rec] at arc [s], first point to
  /// last: a negative cross of the segment's direction with the way to [p].
  /// `RoadGraph`'s own test is private; this is the same test.
  static bool rightOf(IndexedRoad rec, double s, Vec2 p) {
    final cum = rec.cum;
    final nS = rec.sampleCount;
    var i = _firstAtOrAfter(cum, s);
    if (i < 1) i = 1;
    if (i > nS - 1) i = nS - 1;
    final ae = rec.e[i - 1], an = rec.n[i - 1];
    final ex = rec.e[i] - ae, en = rec.n[i] - an;
    final seg = cum[i] - cum[i - 1];
    final u = seg <= 1e-12 ? 0.0 : ((s - cum[i - 1]) / seg).clamp(0.0, 1.0);
    final qe = ae + ex * u, qn = an + en * u;
    return ex * (p.n - qn) - en * (p.e - qe) < 0;
  }

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
