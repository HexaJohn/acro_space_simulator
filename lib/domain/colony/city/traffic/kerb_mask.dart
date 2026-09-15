// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What masks kerb parking away from a kerb cut
/// (docs/plans/t4a-implementation.md §0 Q1, §1.7; site-access.md §7.5).
///
/// The one real implementation ([CutKerbMask]) wraps the road side's
/// `KerbCuts.parkingBlocked(entries, side, s)`. Its asymmetric form is
/// `(12, 3)` metres for a `homeDriveway` join on each served side (a kerb
/// car in the swing path would block every departure) and `(3.25, 3.25)` for
/// every other program, and A12 checks both halves — the agents' slots and
/// the baked kerb cars — against that one function. There is NO copy of the
/// formula here, and no constant of it is re-declared.
///
/// Entries and the arc must be in the SAME frame (§0 Q1): traffic works in
/// the canonical index arc, the renderer in the drawn one. So the only
/// conversion in the agents' half is this file's, and it is §5.5's exactly:
///
/// - the arc is `LaneGraph.roadArc`, the travel arc of the edge mapped onto
///   the road's own polyline (`s = T` where the edge runs forward from the
///   road's start, `L − T` where it runs against it) — the arc the cuts'
///   `joinRoadS` is measured on;
/// - the side is the canonical one: kerb 1 is right of the road's first →
///   last polyline, so "right of travel" IS side 1 on a forward edge and
///   side 0 on a backward one.
library;

import 'dart:typed_data';

import '../site_access/kerb_cuts.dart';
import 'lane_graph.dart';
import 'site_plan_source.dart';

/// Whether kerb parking is blocked at a point on the road. Implemented by
/// [CutKerbMask] over the live plans, and by test doubles.
abstract interface class KerbMask {
  /// Whether a kerb slot at travel arc [travelT] of road [edge], on the
  /// kerb [rightOfTravel] of that edge's travel, falls inside a live
  /// network plan's cut mask. The caller converts the slot's travel arc and
  /// side to the canonical index arc and side (§5.5).
  bool parkingBlocked(int edge, double travelT, bool rightOfTravel);
}

/// No cuts at all: every kerb parks. What a colony without site plans has,
/// and the mask a test uses when it is not the subject.
final class OpenKerbs implements KerbMask {
  const OpenKerbs();

  @override
  bool parkingBlocked(int edge, double travelT, bool rightOfTravel) => false;
}

/// The road side's kerb cuts, as the agents' kerb mask. See the library
/// comment.
final class CutKerbMask implements KerbMask {
  /// [byRoad] is `KerbCuts.canonicalOf`'s table: the canonical entries of
  /// each road of [lg]'s graph by road number, null for a road with none.
  CutKerbMask(this.lg, this.byRoad);

  /// The cuts of every live plan of [src] on [lg]'s graph. Built once per
  /// `sitesRev` (it allocates), and asked per slot after that.
  ///
  /// [roadIdsAt] answers with the road ids of an older graph by its
  /// structure stamp, so a site still resolved against that graph names its
  /// road across the edit (`KerbCuts.canonicalOf`); without it such a site's
  /// cut is left out, which is what a colony that keeps no history gets.
  factory CutKerbMask.of(LaneGraph lg, SitePlanSource src,
          {List<String>? Function(int graphStamp)? roadIdsAt}) =>
      CutKerbMask(lg,
          KerbCuts.canonicalOf(src.chunks, lg.graph, roadIdsAt: roadIdsAt));

  /// The graph whose edges the questions are asked in.
  final LaneGraph lg;

  /// Canonical entries by road number; null for a road with no cut.
  final List<Float64List?> byRoad;

  /// The cuts of the road [edge] runs along, in the canonical arc.
  Float64List? entriesOf(int edge) {
    if (edge < 0 || edge >= lg.roadEdgeCount) return null;
    final r = lg.edgeRoad[edge];
    return r >= 0 && r < byRoad.length ? byRoad[r] : null;
  }

  /// The canonical kerb of [rightOfTravel] on [edge]: 1 is right of the
  /// road's first → last polyline, and a backward edge's right is that
  /// road's left.
  int sideOf(int edge, bool rightOfTravel) =>
      (lg.edgeForward[edge] == 1) == rightOfTravel ? 1 : 0;

  /// The canonical index arc of travel arc [travelT] along [edge].
  double arcOf(int edge, double travelT) => lg.roadArc(edge, travelT);

  @override
  bool parkingBlocked(int edge, double travelT, bool rightOfTravel) =>
      KerbCuts.parkingBlocked(entriesOf(edge), sideOf(edge, rightOfTravel),
          arcOf(edge, travelT));
}
