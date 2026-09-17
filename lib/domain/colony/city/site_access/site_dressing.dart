// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a site's DRESSING is decided by (docs/plans/site-access.md §5.5, §9
/// R6): the rules the renderer draws fences and lot cars by, kept on the
/// domain side so "the domain decides what is open" holds and so a rule can
/// be tested without a mesh.
///
/// - **Fence gaps** ([SiteDressing.fenceGapsOf]). A plan's own `fenceGap`
///   rows win where it has any. No generator writes them (R2 as built), and
///   writing them now would move every plan's `rev` — its site key, its
///   corridor brush keys (§6.3) and every digest downstream. So where a plan
///   has none, its gaps are DERIVED from the plan alone: wherever one of its
///   segments or footpaths crosses an edge of the real parcel polygon, that
///   stretch of the edge is open, the segment's half width plus
///   [SiteDressing.fenceGapMarginM] either side, stretched by the crossing
///   angle. A fence therefore never stands across a drive or a path.
/// - **Lot cars** ([SiteDressing.stallSeed], [SiteDressing.occupied]). A
///   site's occupancy is `0.25 + (fnv1a32(siteId) % 1000)/1000 · 0.6`
///   (§5.5), in integer per-mille. Whether a stall holds a car, and which
///   car, is seeded by `(siteId, stallKey)` — never by stall index — so a
///   re-plan that keeps a stall's key keeps its car.
///
/// Deterministic and web-safe: `fnv1a32` / `fnv1aU32` only, integer
/// arithmetic for every choice, no trigonometry, no map or set iteration.
library;

import 'dart:math' as math;

import '../hash32.dart';
import 'site_access_plan.dart';

/// One open stretch of a parcel polygon's edge: edge [edge] runs from
/// vertex `edge` to vertex `edge + 1` (wrapping), and the gap covers the
/// edge parameters [t0]..[t1] in [0, 1].
class SiteFenceGap {
  const SiteFenceGap(this.edge, this.t0, this.t1);
  final int edge;
  final double t0, t1;

  @override
  String toString() => 'SiteFenceGap($edge, $t0..$t1)';
}

abstract final class SiteDressing {
  /// Clearance a fence leaves each side of a drive or a path it would
  /// otherwise cross, metres.
  static const double fenceGapMarginM = 0.5;

  /// A footpath's drawn width (§6.1 step 6).
  static const double footpathWidthM = 1.5;

  /// A crossing flatter than this sine (about 11.5°) opens no more than
  /// the edge's length: a drive running nearly along a lot line would
  /// otherwise open the whole of it.
  static const double _minCrossingSin = 0.2;

  /// [siteId]'s occupancy, per mille: `250 + (h % 1000) · 3/5`, i.e.
  /// `0.25 + frac · 0.6` of §5.5 without a floating-point step.
  static int occupancyPerMille(String siteId) =>
      250 + ((fnv1a32(siteId) % 1000) * 3) ~/ 5;

  /// The seed of the stall keyed [stallKey] on [siteId]: what decides
  /// whether it holds a car and which one. The key is read unsigned, so a
  /// key stored signed (V10) seeds as the same word.
  static int stallSeed(String siteId, int stallKey) =>
      fnv1aU32(fnv1a32(siteId), stallKey & 0xFFFFFFFF);

  /// Whether a stall of seed [seed] holds a car at [occupancyPerMille].
  static bool occupied(int seed, int occupancyPerMille) =>
      seed % 1000 < occupancyPerMille;

  /// Which of [count] vehicle kinds a stall of seed [seed] holds.
  static int variantOf(int seed, int count) =>
      count <= 0 ? 0 : ((seed >> 12) & 0xFFFF) % count;

  /// The fence gaps of [plan] on the parcel ring ([ringE], [ringN]:
  /// colony-local vertices, either winding, the closing edge implied),
  /// sorted by edge then start, overlaps merged. See the library docs.
  static List<SiteFenceGap> fenceGapsOf(
      SiteAccessPlan plan, List<double> ringE, List<double> ringN) {
    final n = ringE.length;
    if (n < 3 || ringN.length != n) return const [];
    final raw = <SiteFenceGap>[];
    if (plan.fenceGapCount > 0) {
      for (var g = 0; g < plan.fenceGapCount; g++) {
        final e = plan.fenceGapEdge(g);
        if (e < 0 || e >= n) continue;
        raw.add(SiteFenceGap(e, plan.fenceGapT0(g), plan.fenceGapT1(g)));
      }
      return _merged(raw);
    }
    for (var k = 0; k < plan.segCount; k++) {
      final m = plan.segPointCount(k);
      final half = plan.segWidthM(k) / 2 + fenceGapMarginM;
      for (var i = 1; i < m; i++) {
        final a = plan.segPoint(k, i - 1), b = plan.segPoint(k, i);
        _crossings(raw, ringE, ringN, plan.ptE(a), plan.ptN(a), plan.ptE(b),
            plan.ptN(b), half);
      }
    }
    for (var q = 0; q < plan.pathCount; q++) {
      final from = plan.pathStart(q), to = plan.pathStart(q + 1);
      const half = footpathWidthM / 2 + fenceGapMarginM / 2;
      for (var i = from + 1; i < to; i++) {
        final a = plan.pathPt(i - 1), b = plan.pathPt(i);
        _crossings(raw, ringE, ringN, plan.ptE(a), plan.ptN(a), plan.ptE(b),
            plan.ptN(b), half);
      }
    }
    return _merged(raw);
  }

  /// Every crossing of the piece ([ae], [an]) → ([be], [bn]) with an edge of
  /// the ring, as a gap [half] metres either side of it (both ends of the
  /// piece included: a path that ends ON the lot line crosses it).
  static void _crossings(List<SiteFenceGap> out, List<double> ringE,
      List<double> ringN, double ae, double an, double be, double bn,
      double half) {
    final n = ringE.length;
    final pe = be - ae, pn = bn - an;
    final pLen2 = pe * pe + pn * pn;
    if (pLen2 < 1e-12) return;
    for (var i = 0; i < n; i++) {
      final j = i + 1 < n ? i + 1 : 0;
      final ee = ringE[j] - ringE[i], en = ringN[j] - ringN[i];
      final eLen2 = ee * ee + en * en;
      if (eLen2 < 1e-12) continue;
      final denom = ee * pn - en * pe;
      if (denom.abs() < 1e-12) continue; // parallel
      final de = ae - ringE[i], dn = an - ringN[i];
      // Edge parameter t and piece parameter s of the crossing.
      final t = (de * pn - dn * pe) / denom;
      final s = (de * en - dn * ee) / denom;
      const eps = 1e-9;
      if (t < -eps || t > 1 + eps || s < -eps || s > 1 + eps) continue;
      final eLen = _sqrt(eLen2), pLen = _sqrt(pLen2);
      var sin = denom.abs() / (eLen * pLen);
      if (sin < _minCrossingSin) sin = _minCrossingSin;
      final dt = half / sin / eLen;
      final t0 = t - dt, t1 = t + dt;
      out.add(SiteFenceGap(i, t0 < 0 ? 0 : t0, t1 > 1 ? 1 : t1));
      // A crossing near a corner opens the neighbouring edge too, by the
      // metres the gap overran this one.
      if (t0 < 0) {
        final p = i > 0 ? i - 1 : n - 1;
        final pl = _edgeLen(ringE, ringN, p);
        if (pl > 1e-6) {
          final u = 1 + t0 * eLen / pl;
          out.add(SiteFenceGap(p, u < 0 ? 0 : u, 1));
        }
      }
      if (t1 > 1) {
        final nl = _edgeLen(ringE, ringN, j);
        if (nl > 1e-6) {
          final u = (t1 - 1) * eLen / nl;
          out.add(SiteFenceGap(j, 0, u > 1 ? 1 : u));
        }
      }
    }
  }

  static List<SiteFenceGap> _merged(List<SiteFenceGap> raw) {
    if (raw.isEmpty) return const [];
    raw.sort((a, b) {
      final c = a.edge.compareTo(b.edge);
      return c != 0 ? c : a.t0.compareTo(b.t0);
    });
    final out = <SiteFenceGap>[];
    var cur = raw.first;
    for (var i = 1; i < raw.length; i++) {
      final g = raw[i];
      if (g.edge == cur.edge && g.t0 <= cur.t1) {
        if (g.t1 > cur.t1) cur = SiteFenceGap(cur.edge, cur.t0, g.t1);
      } else {
        out.add(cur);
        cur = g;
      }
    }
    out.add(cur);
    return out;
  }

  /// The runs of edge [edge] a fence stands on, as parameter pairs, given
  /// the sorted, merged [gaps] of its ring.
  static List<(double, double)> fenceRunsOf(
      int edge, List<SiteFenceGap> gaps) {
    final out = <(double, double)>[];
    var from = 0.0;
    for (final g in gaps) {
      if (g.edge != edge) continue;
      if (g.t0 > from) out.add((from, g.t0));
      if (g.t1 > from) from = g.t1;
    }
    if (from < 1) out.add((from, 1));
    return out;
  }

  static double _edgeLen(List<double> ringE, List<double> ringN, int i) {
    final j = i + 1 < ringE.length ? i + 1 : 0;
    final de = ringE[j] - ringE[i], dn = ringN[j] - ringN[i];
    return _sqrt(de * de + dn * dn);
  }

  static double _sqrt(double x) => x <= 0 ? 0 : math.sqrt(x);
}
