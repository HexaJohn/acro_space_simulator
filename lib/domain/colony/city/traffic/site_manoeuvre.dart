// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The scripted poses of a stall manoeuvre and a home back-out
/// (docs/plans/t4a-implementation.md §1.6; site-access.md §7.4).
///
/// The wire's capture (package F) calls the same functions the simulation
/// does, so a car is drawn exactly where the simulation put it — one
/// definition of the curve, never two.
///
/// - A manoeuvre is a parameter `u` in 0..1 along a CUBIC BÉZIER, and the
///   pose at `u` is `(e, n, dirE, dirN)`: the car's CENTRE and the way its
///   nose points, which is exactly the shape of a stall row. So the final
///   pose of [stallPose] at `u = 1` IS the stall pose — "within 0.05 m and
///   2°" is a snap, not an IDM tolerance — and the reverse traversal
///   (`u` from 1 to 0) is the pull-out, on the very same curve.
/// - **No trigonometry** (D27): Béziers, dot products and `sqrt` only, so
///   two machines agree bit for bit. A heading that has to turn through a
///   right angle — the back-out's swing — is the NORMALISED blend of the two
///   unit directions, never an angle interpolated and turned back into a
///   vector.
/// - The poses are colony-local east/north; heights come from R3's
///   `SiteChunkGeometry` by reference (§0 A14), never from a ground query.
///
/// A back-out is TWO phases in one parameter, because §7.4 describes two
/// (§7.4 Home back-out, Manoeuvre): the car reverses straight down the pad
/// and the throat, and then, at the kerb line, swings its tail upstream into
/// the target lane. [backOutCommitU] is the parameter where the first phase
/// ends — the instant the car's REAR crosses the kerb line, which is when
/// `EXIT` is logged.
///
/// Everything here is static and allocation-free but for two shared scratch
/// buffers, so nothing on this path may be re-entered from itself.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../site_access/site_access_constants.dart';
import '../site_access/site_access_plan.dart';
import 'lane_graph.dart';
import 'route_cost.dart';

/// A polyline piece shorter than this has no direction, so it is skipped:
/// the same floor `SiteGeometry` walks a lane with.
const double _tinyM = 1e-9;

/// Two unit directions closer than this in cosine are the same direction, so
/// a Bézier's own tangent — which would be degenerate — is not asked for.
const double _tinyDir = 1e-12;

/// How far short of a stall a car turns in, metres along its aisle, where
/// the stall's axis is NOT its aisle's: V9's run-up, which the generator
/// guarantees exists before it sets an in-direction (§7.2 ask 7).
/// An `inline` stall — a home pad's — lies ON its aisle, so it is entered by
/// simply driving along it and takes no run-up at all.
const double kStallRunUpM = 5.0;

/// The downstream handle of a back-out's swing, as a share of its chord. It
/// is short on purpose: the longer it is, the further downstream the nose
/// swings before the car settles, and the body must never leave the
/// footprint the gap rules cleared for it (`site_manoeuvre_test`).
const double kSwingEndHandle = 0.12;

/// The manoeuvre curves. See the library comment.
abstract final class SiteManoeuvre {
  /// Doubles a pose takes in a caller's buffer: east, north, and the unit
  /// direction the nose points.
  static const int poseStride = 4;

  /// Shared scratch: the ends of the curve being asked about. Static because
  /// these functions are asked once per manoeuvring car per sub-step and may
  /// not allocate (§15.2); safe because nothing here calls itself.
  static final Float64List _a = Float64List(8);
  static final Float64List _b = Float64List(8);

  // ---- Lanes, as plain plan geometry ---------------------------------------

  /// The pose at centreline arc [s] along site [lane] of [p], written into
  /// [out] at [o] as east, north, dirE, dirN.
  ///
  /// This is `SiteGeometry.pointAt` over the PLAN alone: a manoeuvre is asked
  /// for with a plan and a stall and nothing else (§1.6), because the capture
  /// holds a chunk and not a synced site table. `site_manoeuvre_test` pins
  /// the two walks equal on every fixture, so the duplication can never
  /// drift into two different curves.
  static void lanePose(
      SiteAccessPlan p, int lane, double s, Float64List out, int o) {
    final k = lane >> 1;
    final fwd = lane & 1 == 0;
    final n = p.segPointCount(k);
    final off = laneOffsetM(p, lane);
    final p0 = _pointOf(p, k, 0, fwd, n);
    var lastE = p.ptE(p0), lastN = p.ptN(p0);
    var lastUE = 0.0, lastUN = 0.0;
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
        _write(out, o, ae + ue * t + un * off, an + un * t - ue * off, ue, un);
        return;
      }
      acc += len;
      lastE = ae + ue * len + un * off;
      lastN = an + un * len - ue * off;
      lastUE = ue;
      lastUN = un;
    }
    _write(out, o, lastE, lastN, lastUE, lastUN);
  }

  /// Metres right of travel of [lane]'s centre: `SiteLaneGraph.laneOffsetM`
  /// read off the plan, for the same reason [lanePose] walks the plan.
  static double laneOffsetM(SiteAccessPlan p, int lane) {
    final k = lane >> 1;
    return p.segLaneMode(k) == SiteLaneMode.twoWay ? p.segWidthM(k) / 4 : 0.0;
  }

  /// The site lane a car enters [stall] of [p] by, for direction bit [dir].
  static int entryLane(SiteAccessPlan p, int stall, int dir) =>
      2 * p.stallSeg(stall) + (dir == kSiteDirFwd ? 0 : 1);

  /// The arc along [stall]'s entry lane where its manoeuvre starts: where a
  /// car driving that lane MEETS the stall, less the run-up a stall across
  /// the aisle needs to swing in (V9). Clamped onto the lane.
  ///
  /// A car drives its aisle under IDM up to exactly this arc and no further;
  /// from here the pose is [stallPose]'s, not the lane's.
  static double mouthS(SiteAccessPlan p, int stall, int dir) {
    final k = p.stallSeg(stall);
    final len = p.segLenM(k);
    final fwd = dir == kSiteDirFwd;
    // `stallS` is the arc along the segment, from→to, at which the stall is
    // met — which is what `SiteTable._reach` prices a stall by.
    final meet = fwd ? p.stallS(stall) : len - p.stallS(stall);
    final back = p.stallAngle(stall) == StallAngle.inline ? 0.0 : kStallRunUpM;
    var s = meet - back;
    if (s < 0) s = 0;
    if (s > len) s = len;
    return s;
  }

  // ---- The stall manoeuvre --------------------------------------------------

  /// The pose at [u] (0..1) of the manoeuvre into — or, run from 1 down to
  /// 0, out of — [stall] of [p] for direction bit [dir] (`kSiteDir*`),
  /// written into [out] at [o] as east, north, dirE, dirN.
  ///
  /// `u = 0` is the car on its aisle at [mouthS], pointing along it; `u = 1`
  /// is the stall pose itself. The heading is the curve's OWN tangent, which
  /// the control points make exactly the lane's direction at one end and
  /// exactly the stall's at the other, so the manoeuvre lands on the stall to
  /// the last bit rather than within a tolerance.
  static void stallPose(SiteAccessPlan p, int stall, int dir, double u,
      Float64List out, int o) {
    _stallEnds(p, stall, dir);
    _cubic(_a, _a, u, out, o);
  }

  /// The metres [stallPose]'s curve runs, for pacing the manoeuvre at a
  /// speed: the mean of its chord and its control polygon, which is within a
  /// per cent of the arc for a curve this gentle and costs no integration.
  static double stallCurveM(SiteAccessPlan p, int stall, int dir) {
    _stallEnds(p, stall, dir);
    return _polyLength(_a, _a);
  }

  /// [_a] and [_b] as the four control points of [stall]'s curve: the aisle
  /// pose at the mouth, then the two handles, then the stall pose.
  static void _stallEnds(SiteAccessPlan p, int stall, int dir) {
    final lane = entryLane(p, stall, dir);
    lanePose(p, lane, mouthS(p, stall, dir), _a, 0);
    _a[4] = p.stallE(stall);
    _a[5] = p.stallN(stall);
    _a[6] = p.stallDirE(stall);
    _a[7] = p.stallDirN(stall);
    _handles(_a[0], _a[1], _a[2], _a[3], _a[4], _a[5], _a[6], _a[7]);
  }

  // ---- The home back-out ----------------------------------------------------

  /// The pose at [u] (0..1) of a home back-out from [stall] of [p] through
  /// [join], reversing down the drive and swinging the tail upstream into
  /// road lane [lane] of [lg], written into [out] at [o] as east, north,
  /// dirE, dirN. The car is [lenM] metres long, which is what decides where
  /// its rear is and so where it comes to rest.
  ///
  /// `u = 0` is the car nose-in in its stall. Up to [backOutCommitU] it
  /// reverses STRAIGHT down the drive, its heading unchanged, until its rear
  /// is on the kerb line. From there it swings, its heading turning from the
  /// stall's to the lane's, and `u = 1` is the car in its lane, aligned with
  /// travel, nose downstream, its front on the join's `T` ([restLaneS]) —
  /// so its body lies inside the footprint it cleared and nowhere else.
  static void backOutPose(SiteAccessPlan p, int join, int stall, int lane,
      LaneGraph lg, double u, Float64List out, int o,
      {required double lenM}) {
    final uk = _backOutEnds(p, join, stall, lane, lg, lenM);
    if (u <= uk) {
      // Straight back down the drive: the pose is the stall's, slid along
      // the nose direction it still points in.
      final t = uk <= 0 ? 0.0 : u / uk;
      final d = _backM * t;
      _write(out, o, _a[0] - _a[2] * d, _a[1] - _a[3] * d, _a[2], _a[3]);
      return;
    }
    final t = uk >= 1 ? 1.0 : (u - uk) / (1 - uk);
    _cubic(_b, _b, t, out, o);
    // Reversing, the curve's tangent is the car's TAIL, not its nose, so the
    // heading is the blend of the two end directions rather than the
    // tangent: it leaves the stall pointing exactly where it was parked and
    // arrives pointing exactly along its lane (§7.4's "aligned with its
    // travel, nose downstream").
    final w = t * t * (3 - 2 * t);
    var he = _a[2] + (_b[6] - _a[2]) * w, hn = _a[3] + (_b[7] - _a[3]) * w;
    final l = math.sqrt(he * he + hn * hn);
    if (l > _tinyDir) {
      he /= l;
      hn /= l;
    } else {
      he = _b[6];
      hn = _b[7];
    }
    out[o + 2] = he;
    out[o + 3] = hn;
  }

  /// The parameter of [backOutPose] at which the car's REAR crosses the kerb
  /// line: the end of the straight reverse, and the instant `EXIT` is logged
  /// (§7.4 EXIT logging). From here the car is in its lane.
  static double backOutCommitU(SiteAccessPlan p, int join, int stall, int lane,
          LaneGraph lg, double lenM) =>
      _backOutEnds(p, join, stall, lane, lg, lenM);

  /// The metres a back-out runs, for pacing it at `backOutMaxMps`.
  static double backOutLengthM(SiteAccessPlan p, int join, int stall, int lane,
      LaneGraph lg, double lenM) {
    _backOutEnds(p, join, stall, lane, lg, lenM);
    return _backM + _polyLength(_b, _b);
  }

  /// The straight reverse's length, metres, of the back-out last asked for.
  static double _backM = 0;

  /// Sets [_a] to the stall pose, [_b] to the swing's ends (its start in
  /// `_b[0..3]`, its finish in `_b[4..7]`) with [_h] its handles and [_backM]
  /// the straight reverse, and answers the parameter the two phases meet at.
  static double _backOutEnds(SiteAccessPlan p, int join, int stall, int lane,
      LaneGraph lg, double lenM) {
    final se = p.stallE(stall), sn = p.stallN(stall);
    final de = p.stallDirE(stall), dn = p.stallDirN(stall);
    _write(_a, 0, se, sn, de, dn);
    // How far back the car reverses: until its rear is on the kerb line,
    // which passes through the join's kerb node across the drive.
    final kn = p.joinKerbNode(join);
    final ke = p.nodeE(kn), kNorth = p.nodeN(kn);
    var back = (se - ke) * de + (sn - kNorth) * dn - lenM / 2;
    if (back < 0) back = 0;
    _backM = back;
    final pe = se - de * back, pn = sn - dn * back;
    // The swing ends with the car's CENTRE half a length behind the front
    // [restLaneS] answers: a pose is a centre, `VehicleTable.s` is a front
    // (§2.3), and the half length between them is taken HERE, once.
    roadPose(lg, lane, restLaneS(p, join, lane, lg) - lenM / 2, _b, 4);
    final qe = _b[4], qn = _b[5], ue = _b[6], un = _b[7];
    _write(_b, 0, pe, pn, de, dn);
    // The swing's handles: away from the kerb along the drive at one end,
    // and DOWNSTREAM at the other, because a car still reversing when it
    // stops arrives at its place moving upstream. That downstream handle is
    // the SHORT one ([kSwingEndHandle]): a long one would carry the nose
    // past `T + backOutDownM` mid-swing and out of the very footprint the
    // car cleared, which is the one thing the manoeuvre may never do.
    _handles(pe, pn, -de, -dn, qe, qn, -ue, -un, b: kSwingEndHandle);
    final total = back + _polyLength(_b, _b);
    return total <= _tinyM ? 0.0 : back / total;
  }

  /// Lane metres a back-out comes to rest at: its FRONT on the join's own
  /// `T`, the axis it backed down.
  ///
  /// A FRONT, because `VehicleTable.s` is one (§2.3, §5.3) and this very arc
  /// is what `attach` is handed as the rear crosses the kerb (§7.4 EXIT
  /// logging): ONE definition of the place, so the car the road mover takes
  /// over is drawn where the swing left it rather than half a length
  /// upstream of it. Whoever wants the CENTRE — a POSE, which is what the
  /// curve's own end is — takes half a length off, as [_backOutEnds] does.
  /// No length enters the arc itself, so it is exactly the arc
  /// `SiteMover._takeFootprint` claims the footprint about.
  ///
  /// Everything the swing sweeps then lies inside the footprint
  /// `[T − backOutUpM, T + backOutDownM]` the gap rules cleared — the body
  /// at rest runs back to `T − lenM`, the tail never reaches `T − 10`, and
  /// the nose's excursion past `T` mid-swing is centimetres — so the
  /// downstream two metres stay what they are for: clearance ahead, not
  /// room the car itself takes. `site_manoeuvre_test` pins it.
  static double restLaneS(SiteAccessPlan p, int join, int lane, LaneGraph lg) {
    final e = lg.laneEdge[lane];
    return lg.travelArc(e, p.joinRoadS(join)) - lg.edgeLaneS0[e];
  }

  /// The pose of a car whose CENTRE is [laneS] lane metres along road [lane]
  /// of [lg], written into [out] at [o] as east, north, dirE, dirN: the
  /// road's own line at that travel arc, `laneOff` to the right of travel —
  /// where the renderer draws a vehicle on that lane, which it does half a
  /// length behind the front `VehicleTable.s` counts, so a caller holding an
  /// `s` takes that half length off before it asks.
  static void roadPose(
      LaneGraph lg, int lane, double laneS, Float64List out, int o) {
    final e = lg.laneEdge[lane];
    final len = lg.edgeLen[e];
    var t = lg.edgeLaneS0[e] + laneS;
    if (t < 0) t = 0;
    if (t > len) t = len;
    // The heading from a quarter metre along, taken backwards where that
    // runs off the end: no trigonometry, just two samples and a normalise.
    final ahead = t + 0.25 <= len;
    RouteCost.pointOn(lg, e, t, out, o);
    RouteCost.pointOn(lg, e, ahead ? t + 0.25 : t - 0.25, out, o + 2);
    var de = out[o + 2] - out[o], dn = out[o + 3] - out[o + 1];
    if (!ahead) {
      de = -de;
      dn = -dn;
    }
    final l = math.sqrt(de * de + dn * dn);
    if (l <= _tinyM) {
      out[o + 2] = 0;
      out[o + 3] = 0;
      return;
    }
    final ue = de / l, un = dn / l;
    final off = lg.laneOff[lane];
    out[o] += un * off;
    out[o + 1] -= ue * off;
    out[o + 2] = ue;
    out[o + 3] = un;
  }

  // ---- The arithmetic -------------------------------------------------------

  /// The two Bézier handles of the curve last set up: a third of the chord
  /// along each end's own direction, which is the interpolation that makes
  /// the curve's tangent exactly those directions at `u = 0` and `u = 1`.
  static final Float64List _h = Float64List(4);

  static void _handles(double e0, double n0, double d0e, double d0n, double e1,
      double n1, double d1e, double d1n,
      {double a = 1 / 3, double b = 1 / 3}) {
    final ce = e1 - e0, cn = n1 - n0;
    var chord = math.sqrt(ce * ce + cn * cn);
    if (chord < 0.15) chord = 0.15;
    _h[0] = e0 + d0e * chord * a;
    _h[1] = n0 + d0n * chord * a;
    _h[2] = e1 - d1e * chord * b;
    _h[3] = n1 - d1n * chord * b;
  }

  /// The cubic through `(from[0], from[1])`, the handles [_h] set for it, and
  /// `(to[4], to[5])`, at [u]; its own tangent is the heading.
  static void _cubic(
      Float64List from, Float64List to, double u, Float64List out, int o) {
    var t = u;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final m = 1 - t;
    final b0 = m * m * m, b1 = 3 * m * m * t, b2 = 3 * m * t * t, b3 = t * t * t;
    final x0 = from[0], y0 = from[1], x3 = to[4], y3 = to[5];
    final x1 = _h[0], y1 = _h[1], x2 = _h[2], y2 = _h[3];
    out[o] = b0 * x0 + b1 * x1 + b2 * x2 + b3 * x3;
    out[o + 1] = b0 * y0 + b1 * y1 + b2 * y2 + b3 * y3;
    final g0 = 3 * m * m, g1 = 6 * m * t, g2 = 3 * t * t;
    var de = g0 * (x1 - x0) + g1 * (x2 - x1) + g2 * (x3 - x2);
    var dn = g0 * (y1 - y0) + g1 * (y2 - y1) + g2 * (y3 - y2);
    final l = math.sqrt(de * de + dn * dn);
    if (l > _tinyDir) {
      de /= l;
      dn /= l;
    } else {
      de = to[6];
      dn = to[7];
    }
    out[o + 2] = de;
    out[o + 3] = dn;
  }

  /// The mean of a cubic's chord and its control polygon: the classic cheap
  /// bound on its arc, good to well under a per cent on a curve that turns
  /// through a right angle or less.
  static double _polyLength(Float64List from, Float64List to) {
    final x0 = from[0], y0 = from[1], x3 = to[4], y3 = to[5];
    final x1 = _h[0], y1 = _h[1], x2 = _h[2], y2 = _h[3];
    final poly = _dist(x0, y0, x1, y1) +
        _dist(x1, y1, x2, y2) +
        _dist(x2, y2, x3, y3);
    return (poly + _dist(x0, y0, x3, y3)) / 2;
  }

  static double _dist(double ae, double an, double be, double bn) =>
      math.sqrt((be - ae) * (be - ae) + (bn - an) * (bn - an));

  /// Polyline point [i] of segment [k], counted along the lane's travel.
  static int _pointOf(SiteAccessPlan p, int k, int i, bool fwd, int n) =>
      p.segPoint(k, fwd ? i : n - 1 - i);

  static void _write(
      Float64List out, int o, double e, double n, double ue, double un) {
    out[o] = e;
    out[o + 1] = n;
    out[o + 2] = ue;
    out[o + 3] = un;
  }
}
