// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a site lane runs, and where a point on the ground is on one
/// (docs/plans/t4a-implementation.md §1.3 item 7; site-access.md §2.5, §7.6).
///
/// The site mover drives along a lane by its arc `s`, and a site sync that
/// changed a plan has to put the cars it was carrying back on the new lanes
/// (`AgentTuning.siteSnapM` / `siteSnapCos`, §7.6 row 1). Both are the same
/// two questions — the pose at `s`, and the nearest point to (e, n) — so
/// they live here once, and the capture (package F) draws from the same
/// answer rather than from a second one of its own.
///
/// A lane is its segment's polyline walked in the lane's own travel
/// direction, offset `SiteLaneGraph.laneOffsetM` to the RIGHT of travel
/// (§2.5: `twoWay` lane centres sit at ±width/4, everything else on the
/// centreline). Right of travel in the colony's east/north frame is the
/// direction turned a quarter CLOCKWISE — `(dirN, −dirE)` — the same
/// convention the road side lays its stalls out by.
///
/// The arc is the CENTRELINE arc, which is what `SiteAccessPlan.segLenM`
/// measures and what `SiteTable.elemLen` publishes, so one number places a
/// car on the lane, bounds it against the lane's end and feeds the IDM. On
/// a bend the offset lane is a hair longer or shorter than the centreline;
/// a site lane is a driveway or an aisle, and that hair is well under the
/// 0.05 m the stall manoeuvre lands within.
///
/// No trigonometry (D27): dot products, offsets and `sqrt` only, so two
/// machines agree. Allocation-free: every answer is written into a
/// caller's buffer.
library;

import 'dart:math' as math;

import 'dart:typed_data';

import '../site_access/site_access_plan.dart';
import '../site_access/site_lane_graph.dart';

/// A polyline piece shorter than this has no direction, so it is skipped:
/// a plan's nodes are at least `kNodeMinGapM` (0.5 m) apart, so this only
/// ever guards a duplicated via point.
const double _tinyM = 1e-9;

/// Lanes as geometry. See the library comment.
abstract final class SiteGeometry {
  /// Doubles a pose takes in a caller's buffer: east, north, the unit
  /// travel direction's east and north, and the centreline arc it is at.
  static const int poseStride = 5;

  /// The centreline length of [lane] — its segment's, whichever way the
  /// lane runs. The arc every other call here speaks in.
  static double laneLengthM(SiteAccessPlan p, int lane) =>
      p.segLenM(SiteLaneGraph.segOf(lane));

  /// The speed cap of [lane], metres a second.
  static double laneVmax(SiteAccessPlan p, int lane) =>
      p.segSpeedMps(SiteLaneGraph.segOf(lane));

  /// The pose at arc [s] along [lane] of [g], written into [out] at [o] as
  /// east, north, dirE, dirN, arc ([poseStride] doubles). [s] is clamped to
  /// the lane, so a car that overran its element is placed at the end
  /// rather than off the plan.
  static void pointAt(
      SiteLaneGraph g, int lane, double s, Float64List out, int o) {
    final p = g.plan;
    final k = SiteLaneGraph.segOf(lane);
    final fwd = SiteLaneGraph.isForward(lane);
    final n = p.segPointCount(k);
    final off = g.laneOffsetM(lane);
    // The start point with no direction: what a segment of duplicated
    // points would answer, and the seed of the running fallback below.
    final p0 = _pointOf(p, k, 0, fwd, n);
    var lastE = p.ptE(p0), lastN = p.ptN(p0);
    var lastUE = 0.0, lastUN = 0.0, lastS = 0.0;
    var acc = 0.0;
    for (var i = 0; i + 1 < n; i++) {
      final a = _pointOf(p, k, i, fwd, n);
      final b = _pointOf(p, k, i + 1, fwd, n);
      final ae = p.ptE(a), an = p.ptN(a);
      final de = p.ptE(b) - ae, dn = p.ptN(b) - an;
      final len = math.sqrt(de * de + dn * dn);
      if (len <= _tinyM) continue;
      final ue = de / len, un = dn / len;
      if (s <= acc + len) {
        var t = s - acc;
        if (t < 0) t = 0;
        _write(out, o, ae + ue * t + un * off, an + un * t - ue * off, ue, un,
            acc + t);
        return;
      }
      acc += len;
      lastE = ae + ue * len + un * off;
      lastN = an + un * len - ue * off;
      lastUE = ue;
      lastUN = un;
      lastS = acc;
    }
    _write(out, o, lastE, lastN, lastUE, lastUN, lastS);
  }

  /// The distance in metres from (e, n) to [lane] of [g], with the nearest
  /// pose on the lane written into [out] at [o] ([poseStride] doubles).
  /// `double.infinity` — and nothing written — for a lane with no length.
  ///
  /// Every piece of the lane is tried and the nearest kept, the earliest
  /// piece winning a tie, so the answer never depends on where the walk
  /// started.
  static double project(
      SiteLaneGraph g, int lane, double e, double n, Float64List out, int o) {
    final p = g.plan;
    final k = SiteLaneGraph.segOf(lane);
    final fwd = SiteLaneGraph.isForward(lane);
    final np = p.segPointCount(k);
    final off = g.laneOffsetM(lane);
    var best = double.infinity;
    var acc = 0.0;
    for (var i = 0; i + 1 < np; i++) {
      final a = _pointOf(p, k, i, fwd, np);
      final b = _pointOf(p, k, i + 1, fwd, np);
      final ae = p.ptE(a), an = p.ptN(a);
      final de = p.ptE(b) - ae, dn = p.ptN(b) - an;
      final len = math.sqrt(de * de + dn * dn);
      if (len <= _tinyM) continue;
      final ue = de / len, un = dn / len;
      // The piece, moved bodily to the lane's own side of the centreline.
      final oe = ae + un * off, on = an - ue * off;
      var t = (e - oe) * ue + (n - on) * un;
      if (t < 0) t = 0;
      if (t > len) t = len;
      final qe = oe + ue * t, qn = on + un * t;
      final d2 = (e - qe) * (e - qe) + (n - qn) * (n - qn);
      if (d2 < best) {
        best = d2;
        _write(out, o, qe, qn, ue, un, acc + t);
      }
      acc += len;
    }
    return best.isFinite ? math.sqrt(best) : double.infinity;
  }

  /// The present lane of [g] nearest (e, n) within [maxM] metres whose
  /// travel direction is within the angle of cosine [minCos] of
  /// (dirE, dirN), with its pose written into [out] at [o]; −1 when no lane
  /// qualifies. This is §7.6 row 1's snap, with `AgentTuning.siteSnapM` and
  /// `siteSnapCos` as the two bounds.
  ///
  /// Ties go to the lower lane, so a car on a two-way segment snaps the
  /// same way on every machine.
  static int snap(SiteLaneGraph g, double e, double n, double dirE,
      double dirN, double maxM, double minCos, Float64List out, int o) {
    var bestLane = -1;
    var bestD = maxM;
    final lanes = g.laneCount;
    for (var l = 0; l < lanes; l++) {
      if (g.present[l] == 0) continue;
      final d = project(g, l, e, n, out, o);
      if (d > bestD) continue;
      if (out[o + 2] * dirE + out[o + 3] * dirN < minCos) continue;
      if (bestLane >= 0 && d >= bestD) continue;
      bestLane = l;
      bestD = d;
    }
    if (bestLane < 0) return -1;
    // [out] holds whatever lane was tried last: answer with the winner's.
    project(g, bestLane, e, n, out, o);
    return bestLane;
  }

  /// Polyline point [i] of segment [k], counted along the lane's travel:
  /// from→to for a forward lane, to→from for a backward one.
  static int _pointOf(SiteAccessPlan p, int k, int i, bool fwd, int n) =>
      p.segPoint(k, fwd ? i : n - 1 - i);

  static void _write(Float64List out, int o, double e, double n, double ue,
      double un, double s) {
    out[o] = e;
    out[o + 1] = n;
    out[o + 2] = ue;
    out[o + 3] = un;
    out[o + 4] = s;
  }
}
