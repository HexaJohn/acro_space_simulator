// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The ONE height rule a site's access is cut to and drawn on
/// (docs/plans/site-access.md §6.3, §6.4).
///
/// The shaper cuts a site's access corridor to [SiteGrade.radiusAt] along
/// the ramp of [SiteCorridorRun], records what it cut to
/// (`CitySim.corridorDatums`, `CitySim.padDatums`), and the capture reads
/// those datums back through [SiteCorridorRun.radiusAt]. Neither side
/// models the other: they share this file, so the drawn paving IS the
/// graded ground.
///
/// Pure: no ground query, no clock, no hash, no map iteration.
library;

import 'dart:math' as math;

import '../parcel.dart';
import 'site_access_plan.dart';

/// The shared height rule and the keys the two sides trade it through.
abstract final class SiteGrade {
  /// The radius a corridor point [t] of the way from the pad to the kerb
  /// stands at: the straight line between them, clamped to its ends.
  ///
  /// `t = 0` is the pad, `t = 1` the kerb — the plan's own `ptHT`
  /// convention (§2.3 `SiteHeightRef.blend`).
  static double radiusAt(double t, double padRadiusM, double kerbRadiusM) {
    final u = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
    return padRadiusM + (kerbRadiusM - padRadiusM) * u;
  }

  /// The shaped key of [siteId]'s pad (`CitySim.padDatums`,
  /// `CityTerrainShaper.pending`).
  static String padKey(String siteId) => 'pad:$siteId';

  /// The settled key of [siteId]'s access corridor run at plan [rev]
  /// (`CitySim.shapedSites`): the shaper decides ONCE per plan revision
  /// whether that site needs a cut at all.
  static String runKey(String siteId, int rev) =>
      'site:$siteId:${_hex8(rev)}';

  /// The shaped key of [siteId]'s pad RE-cut at plan [rev]
  /// (`CityTerrainShaper.pending`): the same platform, laid again after the
  /// roads, where the site's ground is being cut anyway (§6.3 as built).
  static String padRecutKey(String siteId, int rev) =>
      'sitepad:$siteId:${_hex8(rev)}';

  /// The shaped key of corridor segment [seg] of [siteId] at plan [rev]
  /// (`CitySim.shapedTerrain`, `CitySim.corridorDatums`). Keyed by `rev`, so
  /// a re-plan cuts a new corridor and leaves the old one — the trade roads
  /// make (`CityTerrainShaper.pending`).
  static String corridorKey(String siteId, int rev, int seg) =>
      'site:$siteId:${_hex8(rev)}:$seg';

  /// [rev] as eight lower-case hex digits. Web-safe: 32 bits unsigned, no
  /// literal at or past 2^31.
  static String _hex8(int rev) =>
      rev.toUnsigned(32).toRadixString(16).padLeft(8, '0');

  /// How far past a corridor segment's own half width the ground is
  /// levelled flat: the shoulder the drive is drawn on (§6.3).
  ///
  /// A metre, not §6.3's half: the throat's pave ring runs `width/2 + 0.5`
  /// either side of the drive, so half a metre put its corners exactly ON
  /// the levelling edge — where a hair outside costs a centimetre of the
  /// ease, which is the whole probe budget. The ring is inside the
  /// levelled core, as a road's kerb is inside its carriageway's.
  static const double corridorShoulderM = 1.0;

  /// Whether segment [k] of [p] is an access corridor the shaper cuts: a
  /// drive or an access road at least one of whose points does not follow
  /// the pad (§6.3). A segment wholly on the pad is already levelled by the
  /// pad brush, and an aisle or an apron never leaves it.
  static bool isCorridorSeg(SiteAccessPlan p, int k) {
    final kind = p.segKind(k);
    if (kind != SiteSegmentKind.driveway &&
        kind != SiteSegmentKind.accessRoad) {
      return false;
    }
    final m = p.segPointCount(k);
    for (var i = 0; i < m; i++) {
      if (p.ptHRef(p.segPoint(k, i)) != SiteHeightRef.pad) return true;
    }
    return false;
  }
}

/// A site's access corridor: the segments the shaper cuts, the ramp from
/// the kerb to the pad along them, and — once cut — the datums they were
/// cut to.
///
/// Built from the plan alone (§6.3 as built): the ramp falls linearly by
/// arc from 1 at a cut join's kerb node to 0 at the far end of the
/// corridor chain that leaves it. On a set-back lot that chain is exactly
/// the off-parcel throat `K → F`, which is §6.3's rule; on an auto lot it
/// is the drive, whose far end is the first pad node.
class SiteCorridorRun {
  SiteCorridorRun._(this.segs, this.a, this.b, this.tStart, this.tEnd,
      this.halfM, this.segOffParcelM, this.kerbAt);

  /// [p]'s corridor run, or null when it has none (a kerbside plan, a plan
  /// whose drives never leave the pad, a cut join with no kerb node).
  ///
  /// [parcel], where given, measures [segOffParcelM] — each segment's arc
  /// outside the lot line, which decides whether the ground needs cutting at
  /// all (§6.3). The capture passes none: it only reads back.
  static SiteCorridorRun? of(SiteAccessPlan p, {Parcel? parcel}) {
    final nSeg = p.segCount;
    if (nSeg == 0) return null;
    // The corridor segments, and each segment's chord.
    final segs = <int>[];
    for (var k = 0; k < nSeg; k++) {
      if (SiteGrade.isCorridorSeg(p, k)) segs.add(k);
    }
    if (segs.isEmpty) return null;
    // Arc from a kerb node, out along the corridor chain. Every cut join's
    // kerb node starts at 0; a node is reached once, by the first segment
    // that reaches it, so the walk terminates on any shape of chain.
    final arc = List<double>.filled(p.nodeCount, -1);
    var any = false;
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinIsCut(j)) continue;
      final kn = p.joinKerbNode(j);
      if (kn < 0 || kn >= p.nodeCount) continue;
      arc[kn] = 0;
      any = true;
    }
    if (!any) return null;
    for (var pass = 0; pass < segs.length; pass++) {
      var moved = false;
      for (final k in segs) {
        final f = p.segFrom(k), t = p.segTo(k);
        if (f < 0 || t < 0 || f >= arc.length || t >= arc.length) continue;
        final len = _chordLen(p, k);
        if (arc[f] >= 0 && arc[t] < 0) {
          arc[t] = arc[f] + len;
          moved = true;
        } else if (arc[t] >= 0 && arc[f] < 0) {
          arc[f] = arc[t] + len;
          moved = true;
        }
      }
      if (!moved) break;
    }
    var rampM = 0.0;
    for (final x in arc) {
      if (x > rampM) rampM = x;
    }
    final a = <Vec2>[], b = <Vec2>[];
    final t0 = <double>[], t1 = <double>[], half = <double>[];
    final kept = <int>[];
    for (final k in segs) {
      final f = p.segFrom(k), t = p.segTo(k);
      if (f < 0 || t < 0 || f >= arc.length || t >= arc.length) continue;
      if (arc[f] < 0 || arc[t] < 0) continue; // not on a kerb node's chain
      final m = p.segPointCount(k);
      final pa = p.segPoint(k, 0), pb = p.segPoint(k, m - 1);
      final av = Vec2(p.ptE(pa), p.ptN(pa)), bv = Vec2(p.ptE(pb), p.ptN(pb));
      if (av.distanceTo(bv) < 1e-6) continue;
      kept.add(k);
      a.add(av);
      b.add(bv);
      t0.add(rampM <= 0 ? 0.0 : (1 - arc[f] / rampM).clamp(0.0, 1.0));
      t1.add(rampM <= 0 ? 0.0 : (1 - arc[t] / rampM).clamp(0.0, 1.0));
      half.add(p.segWidthM(k) / 2 + SiteGrade.corridorShoulderM);
    }
    if (kept.isEmpty) return null;
    // Per SEGMENT, as §6.3 asks it ("the segment has an off-parcel stretch
    // longer than ..."), not summed over the run: a corridor that leaves the
    // lot in several short stubs, none of them over the threshold, is one
    // §6.3 says to leave alone.
    final off = <double>[];
    if (parcel != null) {
      for (var i = 0; i < kept.length; i++) {
        off.add(_outsideLength(parcel, a[i], b[i]));
      }
    }
    // The kerb end of the run: the endpoint standing highest on the ramp,
    // which is a cut join's kerb node (arc 0 → t 1). Not simply the first
    // segment's first point — a plan is free to store a drive running from
    // its pad out to the street, and the ground under the wrong end would
    // grade the whole corridor backwards.
    var kerbAt = a[0];
    var best = t0[0];
    for (var i = 0; i < kept.length; i++) {
      if (t0[i] > best) {
        best = t0[i];
        kerbAt = a[i];
      }
      if (t1[i] > best) {
        best = t1[i];
        kerbAt = b[i];
      }
    }
    return SiteCorridorRun._(kept, a, b, t0, t1, half, off, kerbAt);
  }

  /// The plan-local segments cut, in order.
  final List<int> segs;

  /// Each segment's chord ends (its polyline's first and last point: the
  /// vias between lie on it, V5).
  final List<Vec2> a, b;

  /// The ramp at each chord's ends: 1 at the kerb, 0 at the pad.
  final List<double> tStart, tEnd;

  /// Half the ground each segment levels either side of its chord.
  final List<double> halfM;

  /// How much of EACH segment lies outside the lot line, in [segs] order
  /// (empty when the run was built without a parcel).
  final List<double> segOffParcelM;

  /// The run's kerb end: the endpoint at the top of the ramp, where it
  /// meets the road. What the ground is asked for the corridor's kerb
  /// datum (§6.3 as built).
  final Vec2 kerbAt;

  /// The longest single segment's stretch outside the lot line — §6.3's cut
  /// clause, which is per segment.
  double get maxSegOffParcelM {
    var m = 0.0;
    for (final x in segOffParcelM) {
      if (x > m) m = x;
    }
    return m;
  }

  int get length => segs.length;

  /// The radius segment [i] is cut to at its chord's start and end, from
  /// the pad and kerb radii it grades between.
  (double, double) datumsOf(int i, double padRadiusM, double kerbRadiusM) => (
        SiteGrade.radiusAt(tStart[i], padRadiusM, kerbRadiusM),
        SiteGrade.radiusAt(tEnd[i], padRadiusM, kerbRadiusM),
      );

  /// The radius the ground stands at under local ([e], [n]), given each
  /// segment's cut datums in [datums] (null where that segment was not
  /// cut), or null where no cut segment covers the point.
  ///
  /// EXACTLY as the brush levels it: a point within a segment's [halfM] of
  /// its chord is levelled outright, to the datum interpolated by where the
  /// point projects onto the chord. The projection is taken in plan, which
  /// is the fixed point of the brush's own three-dimensional one — a point
  /// at the interpolated radius lies ON the chord, and a lateral offset is
  /// square to it (`TerrainBrush.cutFill`).
  ///
  /// Later segments win, as later brushes do.
  double? radiusAt(double e, double n, List<(double, double)?> datums) {
    double? out;
    for (var i = 0; i < segs.length; i++) {
      final d = i < datums.length ? datums[i] : null;
      if (d == null) continue;
      final ae = a[i].e, an = a[i].n;
      final de = b[i].e - ae, dn = b[i].n - an;
      final len2 = de * de + dn * dn;
      if (len2 <= 1e-12) continue;
      var t = ((e - ae) * de + (n - an) * dn) / len2;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      final ce = ae + de * t - e, cn = an + dn * t - n;
      if (ce * ce + cn * cn > halfM[i] * halfM[i]) continue;
      out = d.$1 + (d.$2 - d.$1) * t;
    }
    return out;
  }

  static double _chordLen(SiteAccessPlan p, int k) {
    final m = p.segPointCount(k);
    final pa = p.segPoint(k, 0), pb = p.segPoint(k, m - 1);
    final de = p.ptE(pb) - p.ptE(pa), dn = p.ptN(pb) - p.ptN(pa);
    return math.sqrt(de * de + dn * dn);
  }

  /// How much of the chord [from] → [to] lies outside [parcel], sampled at
  /// [_sampleM]. Sampled, not clipped: a parcel is any polygon, and the
  /// figure only has to decide a metre-scale threshold (§6.3).
  static double _outsideLength(Parcel parcel, Vec2 from, Vec2 to) {
    final len = from.distanceTo(to);
    if (len <= 0) return 0;
    final n = (len / _sampleM).ceil();
    var out = 0.0;
    for (var i = 0; i < n; i++) {
      final t = (i + 0.5) / n;
      final at = Vec2(from.e + (to.e - from.e) * t, from.n + (to.n - from.n) * t);
      if (!parcel.contains(at)) out += len / n;
    }
    return out;
  }

  static const double _sampleM = 0.5;
}
