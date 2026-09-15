// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Kerb cuts: where a site's joins break the kerb of a road
/// (docs/plans/site-access.md §5.2, §5.5).
///
/// **Canonical form.** Per road, flat quintuples `(side, c, h, σ, kind)` in
/// the road's INDEX arc, measured from its first control (the arc `joinS` and
/// `joinRoadS` use):
/// - `side` 1 for the kerb right of the first → last polyline, 0 the left;
/// - `c` the join's arc, `h` its `joinCutHalfM`;
/// - `σ` the travel sign of the lane beside that kerb (+1 toward larger arc):
///   on a two-way road +1 on side 1 and −1 on side 0, on a one-way road the
///   road's own direction on both kerbs;
/// - `kind` [kindDropped] for the lot-side kerb of a non-home cut,
///   [kindHomeLot] for a `homeDriveway` cut's lot-side kerb, and
///   [kindHomeFarSwing] for the far kerb of a home join a far-direction
///   back-out may use (a join served both ways on a two-way road): a swing
///   mask, never drawn.
///
/// Entries of one road are ordered by (side, c, kind), so the form is a pure
/// function of the plans. The renderer's copy ([toDrawn]) is rescaled to its
/// drawn arc and flipped for reversed roads. The mask functions ([blocked],
/// [parkingBlocked], [shiftOut]) read either copy: an arc and its entries
/// must be in the same frame (canonical for the agents, drawn for the tiles).
///
/// Determinism (§3.9): no platform hash, draw, clock, map or set iteration,
/// no trigonometry.
library;

import 'dart:typed_data';

import '../road_graph.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';

abstract final class KerbCuts {
  /// Doubles per entry.
  static const int stride = 5;

  /// Entry kinds (§5.2): drawn dropped kerbs are [kindDropped] and
  /// [kindHomeLot]; [kindHomeFarSwing] is a swing mask only.
  static const int kindDropped = 0, kindHomeLot = 1, kindHomeFarSwing = 2;

  /// The canonical cuts of every cut join in [chunks], per road number of
  /// [g] (null for a road with none).
  ///
  /// A site resolved against [g] (`graphStamp == g.structureStamp`) names its
  /// road by `joinRoadNo`. A site still resolved against an older graph is
  /// stale (§4.2 step 3) and keeps drawing its old plan: its road number is
  /// mapped through the road ids of the graph it was resolved against
  /// ([roadIdsAt], by stamp) to the road of that id in [g]; with no such
  /// graph or no such road its cut is left out (the road it named is gone,
  /// and the edit re-cut its tile anyway).
  static List<Float64List?> canonicalOf(
      List<SiteAccessChunk> chunks, RoadGraph g,
      {List<String>? Function(int graphStamp)? roadIdsAt}) {
    final nR = g.roadCount;
    final stamp = g.structureStamp;
    final byRoad = List<List<double>?>.filled(nR, null);
    for (final chunk in chunks) {
      for (var k = 0; k < chunk.siteCount; k++) {
        final j0 = chunk.joinStart(k), nJ = chunk.joinCountOf(k);
        if (nJ == 0) continue;
        final home = chunk.program(k) == SiteProgram.homeDriveway;
        final siteStamp = chunk.graphStamp(k);
        List<String>? ids;
        if (siteStamp != stamp) ids = roadIdsAt?.call(siteStamp);
        for (var row = j0; row < j0 + nJ; row++) {
          if (chunk.joinKind(row) != SiteJoinKind.cut) continue;
          var r = chunk.joinRoadNo(row);
          if (siteStamp != stamp) {
            if (ids == null || r < 0 || r >= ids.length) continue;
            r = g.roadNoOf(ids[r]) ?? -1;
          }
          if (r < 0 || r >= nR) continue;
          final road = g.roads[r];
          final side = chunk.joinRight(row) ? 1 : 0;
          final c = chunk.joinRoadS(row);
          final h = chunk.joinCutHalfM(row);
          final list = byRoad[r] ??= <double>[];
          list
            ..add(side.toDouble())
            ..add(c)
            ..add(h)
            ..add(sigmaOf(road.oneWay, road.reversed, side).toDouble())
            ..add((home ? kindHomeLot : kindDropped).toDouble());
          if (home &&
              !road.oneWay &&
              chunk.joinDirs(row) == (kSiteDirFwd | kSiteDirBwd)) {
            final far = 1 - side;
            list
              ..add(far.toDouble())
              ..add(c)
              ..add(h)
              ..add(sigmaOf(false, false, far).toDouble())
              ..add(kindHomeFarSwing.toDouble());
          }
        }
      }
    }
    return [
      for (final list in byRoad) list == null ? null : _sorted(list),
    ];
  }

  /// The travel sign of the lane beside kerb [side] (1 right of the first →
  /// last polyline): a two-way road drives on the right, a one-way road runs
  /// first → last unless [reversed].
  static int sigmaOf(bool oneWay, bool reversed, int side) {
    if (oneWay) return reversed ? -1 : 1;
    return side == 1 ? 1 : -1;
  }

  /// [canonical] as a renderer draws it (§5.2): the centres rescaled from
  /// the road's index arc ([indexLengthM]) to its drawn arc ([drawnLengthM]),
  /// the scale `TrafficGeometry` documents, and for a road the frame sends
  /// flipped ([reversed]) mirrored: `c → L − c`, the side swapped, `σ → −σ`.
  /// Half widths stay metres. Re-ordered by (side, c, kind).
  static Float64List toDrawn(Float64List canonical,
      {required double indexLengthM,
      required double drawnLengthM,
      required bool reversed}) {
    final scale = indexLengthM > 0 ? drawnLengthM / indexLengthM : 1.0;
    final out = <double>[];
    for (var i = 0; i + stride <= canonical.length; i += stride) {
      final side = canonical[i];
      final c = canonical[i + 1] * scale;
      final sigma = canonical[i + 3];
      out
        ..add(reversed ? 1 - side : side)
        ..add(reversed ? drawnLengthM - c : c)
        ..add(canonical[i + 2])
        ..add(reversed ? -sigma : sigma)
        ..add(canonical[i + 4]);
    }
    return _sorted(out);
  }

  /// The asymmetric mask (§5.5): whether an entry of [entries] on kerb [side]
  /// holds `−(h + upstreamM) < σ·(s − c) < h + downstreamM` at arc [s].
  /// Upstream and downstream run along the travel of the lane beside that
  /// kerb (σ), so the upstream side flips with the direction served. With
  /// equal extents it is the symmetric `|s − c| < h + x`. [drawnOnly] leaves
  /// out the far-swing masks ([kindHomeFarSwing]), which break no kerb.
  /// Allocates nothing.
  static bool blocked(Float64List? entries, int side, double s,
      {required double upstreamM,
      required double downstreamM,
      bool drawnOnly = false}) {
    if (entries == null) return false;
    for (var i = 0; i + stride <= entries.length; i += stride) {
      if (entries[i] != side) continue;
      if (drawnOnly && entries[i + 4] == kindHomeFarSwing) continue;
      final h = entries[i + 2];
      final x = entries[i + 3] * (s - entries[i + 1]);
      if (-(h + upstreamM) < x && x < h + downstreamM) return true;
    }
    return false;
  }

  /// Kerb parking (§5.5, A12): whether a kerb slot centred at arc [s] on kerb
  /// [side] is masked. Every entry with its program's extents: home kinds
  /// ([kindHomeLot], [kindHomeFarSwing]) at `(kHomeSwingUpM,
  /// kHomeSwingDownM)` — the back-out swing `[T − 12, T + 3]` in travel terms
  /// — and [kindDropped] at the symmetric `kKerbMaskM`. The agents' kerb
  /// slots (canonical arc) and the baked kerb cars (drawn arc) both ask this.
  /// Allocates nothing.
  static bool parkingBlocked(Float64List? entries, int side, double s) {
    if (entries == null) return false;
    for (var i = 0; i + stride <= entries.length; i += stride) {
      if (entries[i] != side) continue;
      final home = entries[i + 4] != kindDropped;
      final up = home ? kHomeSwingUpM : kKerbMaskM;
      final down = home ? kHomeSwingDownM : kKerbMaskM;
      final h = entries[i + 2];
      final x = entries[i + 3] * (s - entries[i + 1]);
      if (-(h + up) < x && x < h + down) return true;
    }
    return false;
  }

  /// A station (lamp, post) at arc [s] on kerb [side] moved out of any drawn
  /// cut: toward the nearer end of the first cut it stands in, to that end
  /// plus [kKerbShiftOutM], and on the same way past every further cut that
  /// lands it in (so two overlapping cuts cannot bounce it back). [s] itself
  /// when it stands in none. Far-swing masks move nothing.
  static double shiftOut(Float64List? entries, int side, double s) {
    if (entries == null) return s;
    var at = s;
    var dir = 0; // −1 toward smaller arc, +1 larger; 0 until the first cut
    final passes = entries.length ~/ stride;
    for (var pass = 0; pass <= passes; pass++) {
      var moved = false;
      for (var i = 0; i + stride <= entries.length; i += stride) {
        if (entries[i] != side || entries[i + 4] == kindHomeFarSwing) continue;
        final c = entries[i + 1], h = entries[i + 2];
        if ((at - c).abs() < h) {
          if (dir == 0) dir = at < c ? -1 : 1;
          at = dir < 0 ? c - h - kKerbShiftOutM : c + h + kKerbShiftOutM;
          moved = true;
        }
      }
      if (!moved) break;
    }
    return at;
  }

  /// [flat] entries ordered by (side, c, kind), as a typed list.
  static Float64List _sorted(List<double> flat) {
    final n = flat.length ~/ stride;
    final order = List<int>.generate(n, (i) => i);
    order.sort((a, b) {
      final x = a * stride, y = b * stride;
      final bySide = flat[x].compareTo(flat[y]);
      if (bySide != 0) return bySide;
      final byC = flat[x + 1].compareTo(flat[y + 1]);
      if (byC != 0) return byC;
      final byKind = flat[x + 4].compareTo(flat[y + 4]);
      if (byKind != 0) return byKind;
      return a.compareTo(b);
    });
    final out = Float64List(n * stride);
    for (var i = 0; i < n; i++) {
      out.setRange(i * stride, (i + 1) * stride, flat, order[i] * stride);
    }
    return out;
  }
}
