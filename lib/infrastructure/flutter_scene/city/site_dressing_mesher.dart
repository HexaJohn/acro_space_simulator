// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a site access plan DRESSES its paving with (docs/plans/site-access.md
/// §5.4, §5.5, §9 R6): the arrows and the bay hatch on its paint, the cars
/// standing in its stalls, the wheel stops at their noses, the footpath from
/// its door to the pavement, its car-park lamps, the fence ring round the
/// REAL parcel polygon with the plan's gaps left open, and the sign beside
/// its throat.
///
/// Every piece is a pure function of the plan, its heights and the wire's
/// own lot ring: no `hashCode`, no `Random`, no clock, no map iteration, and
/// every seed is `fnv1a32` over `(siteId, stallKey)` (`SiteDressing`), so a
/// re-plan that keeps a stall keeps its car and two isolates meshing one
/// tile agree to the byte.
///
/// The tiers are §5.4's. A BIG site's arrows, hatch, cars and lamps are its
/// near tile's structure; a small site's are the detail pass's, drawn with
/// the lot furniture of the building they serve, so the same geometry is
/// drawn with the detail layer on and off.
library;

import 'dart:math' as math;

import '../../../application/snapshot/city_site_frame.dart';
import '../../../domain/colony/city/site_access/site_access_constants.dart';
import '../../../domain/colony/city/site_access/site_access_plan.dart';
import '../../../domain/colony/city/site_access/site_dressing.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_texture_bakes.dart';
import 'lot_features.dart';
import 'oriented_box.dart';
import 'road_mesher.dart';
import 'site_access_mesher.dart';
import 'vehicle_meshes.dart';

/// One site being drawn: its plan, its heights and the frame they are placed
/// in, with the anchor every vertex is relative to.
class SiteDraw {
  SiteDraw(this.frame, this.geo, this.site, this.anchorBF)
      : plan = geo.plan.plan(site),
        _p0 = geo.plan.ptStart(site),
        _st0 = geo.plan.stallStart(site);

  final CitySiteFrame frame;
  final SiteChunkGeometry geo;
  final int site;
  final SiteAccessPlan plan;
  final Vector3 anchorBF;
  final int _p0, _st0;

  /// Plan-local point [p], anchor-relative.
  Vector3 at(int p) => frame.localToBodyFixed(
          plan.ptE(p), plan.ptN(p), geo.ptUp(_p0 + p)) -
      anchorBF;

  /// Colony-local ([e], [n]) at [upM] above the datum, anchor-relative.
  Vector3 atLocal(double e, double n, double upM) =>
      frame.localToBodyFixed(e, n, upM) - anchorBF;

  /// The radial at an anchor-relative point.
  Vector3 upAt(Vector3 p) => (p + anchorBF).normalized;

  /// The pave under stall [i], as `ptUp`.
  double stallUp(int i) => geo.stallUp(_st0 + i);

  /// What the lot's fence and sign stand on.
  double get padUp => geo.padUp(site);

  /// A colony-local direction as a unit tangent at [up].
  Vector3? tangent(double e, double n, Vector3 up) {
    var v = frame.east * e + frame.north * n;
    v = v - up * v.dot(up);
    return v.length < 1e-9 ? null : v.normalized;
  }

  /// The height of segment [seg]'s polyline [s] metres along it, from the
  /// point heights the geometry carries (the rule `SiteCapture` puts a
  /// stall on).
  double upAlong(int seg, double s) {
    if (seg < 0 || seg >= plan.segCount) return padUp;
    final m = plan.segPointCount(seg);
    var at = 0.0;
    for (var i = 1; i < m; i++) {
      final a = plan.segPoint(seg, i - 1), b = plan.segPoint(seg, i);
      final de = plan.ptE(b) - plan.ptE(a), dn = plan.ptN(b) - plan.ptN(a);
      final len = math.sqrt(de * de + dn * dn);
      if (s <= at + len || i == m - 1) {
        final u = len > 0 ? ((s - at) / len).clamp(0.0, 1.0) : 0.0;
        return geo.ptUp(_p0 + a) + (geo.ptUp(_p0 + b) - geo.ptUp(_p0 + a)) * u;
      }
      at += len;
    }
    return geo.ptUp(_p0 + plan.segPoint(seg, 0));
  }

  /// The lot ring the fence walks, colony-local — the REAL parcel polygon
  /// (§5.5), empty for a site whose lot is gone.
  (List<double>, List<double>) lotRing() {
    final n = geo.lotRingCount(site);
    final e = <double>[], nn = <double>[];
    for (var i = 0; i < n; i++) {
      e.add(plan.frameE + geo.lotRingDE(site, i));
      nn.add(plan.frameN + geo.lotRingDN(site, i));
    }
    return (e, nn);
  }
}

abstract final class SiteDressingMesher {
  /// A wheel stop: how wide, how deep, how tall, and how far its face
  /// stands back from the stall's nose.
  static const double wheelStopWidthM = 1.6;
  static const double wheelStopDepthM = 0.18;
  static const double wheelStopHeightM = 0.12;
  static const double wheelStopSetbackM = 0.85;

  /// A car-park lamp: the column and the head it carries.
  static const double lampHeightM = 8.0;
  static const double lampPostM = 0.18;
  static const double lampHeadM = 0.9;

  /// A footpath's drawn width and its lift over the site's paving.
  static const double pathWidthM = SiteDressing.footpathWidthM;
  static const double pathLiftM = SiteAccessMesher.paintLiftM + 0.005;

  /// An arrow on a drive: how long, how wide its head, and how far apart
  /// two of them stand along a one-way run.
  static const double arrowLenM = 2.4;
  static const double arrowWidthM = 1.1;
  static const double arrowSpacingM = 18.0;

  /// The narrowest throat that carries a pair of direction arrows: under
  /// this a drive is one lane and there is nothing to keep apart.
  static const double arrowThroatWidthM = 5.5;

  /// How far a fence stands inside its own lot line, so two neighbours'
  /// fences do not draw in the same plane.
  static const double fenceInsetM = 0.12;

  /// The sign's clearance from the edge of the throat it stands beside
  /// (§5.5: `segWidth/2 + 1.5` to the building side).
  static const double signClearanceM = 1.5;

  // ---- Paint ---------------------------------------------------------------

  /// [arrows] drawn.
  static void emitArrows(MeshBuilder m, SiteDraw d) {
    for (final a in arrows(d)) {
      _arrow(m, d, a);
    }
  }

  /// Direction arrows: down every one-way segment, and a pair on a
  /// two-lane throat — one pointing in, one out — so a car park reads as
  /// somewhere you drive in at. A home drive takes none: it is one car
  /// wide, and its car backs out (§7.4).
  static List<SiteArrow> arrows(SiteDraw d) {
    final out = <SiteArrow>[];
    final plan = d.plan;
    for (var k = 0; k < plan.segCount; k++) {
      final mode = plan.segLaneMode(k);
      final throat = plan.segFlags(k) & kSegThroat != 0;
      final oneWay = mode == SiteLaneMode.oneWayForward ||
          mode == SiteLaneMode.oneWayBackward;
      if (!oneWay && !(throat && plan.segWidthM(k) >= arrowThroatWidthM)) {
        continue;
      }
      if (plan.program == SiteProgram.homeDriveway) continue;
      final len = plan.segLenM(k);
      if (len < arrowLenM + 2) continue;
      // Which way the segment runs from its kerb end.
      final fromKerb = _kerbAtStart(plan, k);
      final backward = mode == SiteLaneMode.oneWayBackward;
      if (oneWay) {
        var s = arrowSpacingM / 2;
        while (s < len - arrowLenM / 2) {
          out.add(SiteArrow(k, s, !backward, 0));
          s += arrowSpacingM;
        }
        continue;
      }
      // A two-way throat: in on one side, out on the other, a quarter of
      // the width either side of the axis, just inside the lot line.
      final off = plan.segWidthM(k) / 4;
      final s = fromKerb
          ? math.min(len - arrowLenM, 6.0)
          : math.max(arrowLenM, len - 6.0);
      out
        ..add(SiteArrow(k, s, fromKerb, fromKerb ? off : -off))
        ..add(SiteArrow(k, s, !fromKerb, fromKerb ? -off : off));
    }
    return out;
  }

  /// One arrow: on its segment's polyline, [SiteArrow.offsetM] to the right
  /// of the way that segment runs, pointing along it or against it.
  static void _arrow(MeshBuilder m, SiteDraw d, SiteArrow a) {
    final plan = d.plan;
    final k = a.seg, s = a.s, forward = a.forward, offsetM = a.offsetM;
    final (e, n, de, dn) = _alongSegment(plan, k, s);
    if (de == 0 && dn == 0) return;
    final up0 = d.atLocal(e, n, d.upAlong(k, s));
    final up = d.upAt(up0);
    final ahead = d.tangent(forward ? de : -de, forward ? dn : -dn, up);
    if (ahead == null) return;
    final side = ahead.cross(up).normalized;
    final c = up0 + side * offsetM + up * SiteAccessMesher.paintLiftM;
    final band = CityTextureBakes.roadWhite;
    final u0 = RoadMesher.bandU(band, 0), u1 = RoadMesher.bandU(band, 1);
    final tip = c + ahead * (arrowLenM / 2);
    final neck = c + ahead * (arrowLenM / 2 - arrowWidthM * 0.8);
    final tail = c - ahead * (arrowLenM / 2);
    // The head.
    final head = [
      m.vertex(tip * kRenderScale, up, u0, 0),
      m.vertex((neck - side * (arrowWidthM / 2)) * kRenderScale, up, u1, 1),
      m.vertex((neck + side * (arrowWidthM / 2)) * kRenderScale, up, u1, 1),
    ];
    m.triangle(head[0], head[2], head[1]);
    // The shaft.
    const shaft = 0.22;
    final q = [
      m.vertex((tail - side * shaft) * kRenderScale, up, u0, 0),
      m.vertex((tail + side * shaft) * kRenderScale, up, u1, 0),
      m.vertex((neck + side * shaft) * kRenderScale, up, u1, 1),
      m.vertex((neck - side * shaft) * kRenderScale, up, u0, 1),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  /// How many of [d]'s loading bays take a hatch: those with a real size.
  static int hatchedBays(SiteDraw d) {
    var n = 0;
    for (var b = 0; b < d.plan.bayCount; b++) {
      if (d.plan.bayLenM(b) > 0 && d.plan.bayWidthM(b) > 0) n++;
    }
    return n;
  }

  /// The hatch on a loading bay: the bay painted in the atlas's hatch band,
  /// so a truck dock reads as a place nothing parks across.
  static void emitBayHatch(MeshBuilder m, SiteDraw d) {
    final plan = d.plan;
    for (var b = 0; b < plan.bayCount; b++) {
      final len = plan.bayLenM(b), wide = plan.bayWidthM(b);
      if (!(len > 0) || !(wide > 0)) continue;
      final upM = d.upAlong(plan.baySeg(b), plan.bayS(b));
      final c0 = d.atLocal(plan.bayE(b), plan.bayN(b), upM);
      final up = d.upAt(c0);
      final along = d.tangent(plan.bayDirE(b), plan.bayDirN(b), up);
      if (along == null) continue;
      final side = along.cross(up).normalized;
      final c = c0 + up * SiteAccessMesher.paintLiftM;
      final band = CityTextureBakes.roadHatch;
      final u0 = RoadMesher.bandU(band, 0), u1 = RoadMesher.bandU(band, 1);
      final a = c - along * (len / 2), z = c + along * (len / 2);
      final q = [
        m.vertex((a - side * (wide / 2)) * kRenderScale, up, u0, 0),
        m.vertex((a + side * (wide / 2)) * kRenderScale, up, u1, 0),
        m.vertex((z + side * (wide / 2)) * kRenderScale, up, u1,
            len / RoadMesher.tileM),
        m.vertex((z - side * (wide / 2)) * kRenderScale, up, u0,
            len / RoadMesher.tileM),
      ];
      m.quad(q[0], q[1], q[2], q[3]);
    }
  }

  // ---- Wheel stops ---------------------------------------------------------

  /// A wheel stop at the nose of every bay stall: a low concrete block
  /// across the stall, [wheelStopSetbackM] back from its nose. An `inline`
  /// stall (a home drive) has none — there is nothing to stop short of.
  static void emitWheelStops(MeshBuilder m, SiteDraw d) {
    final plan = d.plan;
    final band = RoadMesher.bandU(CityTextureBakes.roadConcrete, 0.5);
    for (var i = 0; i < plan.stallCount; i++) {
      if (plan.stallAngle(i) == StallAngle.inline) continue;
      final len = plan.stallLenM(i), wide = plan.stallWidthM(i);
      if (!(len > 0) || !(wide > 0)) continue;
      final centre = d.atLocal(plan.stallE(i), plan.stallN(i), d.stallUp(i));
      final up = d.upAt(centre);
      final nose = d.tangent(plan.stallDirE(i), plan.stallDirN(i), up);
      if (nose == null) continue;
      final base = centre +
          nose * (len / 2 - wheelStopSetbackM) +
          up * SiteAccessMesher.paveLiftM;
      OrientedBox.upright(
          m,
          base,
          nose,
          up,
          math.min(wheelStopWidthM, wide - 0.4),
          wheelStopDepthM,
          wheelStopHeightM,
          u: band);
    }
  }

  // ---- Lot cars ------------------------------------------------------------

  /// The cars baked into [d]'s stalls, at most [maxCars] of them, in stall
  /// order — the poses [emitLotCars] draws, exposed so a test can hold them
  /// against the plan's own stalls.
  static List<SiteLotCar> lotCars(SiteDraw d,
      {required int maxCars, required bool airless}) {
    final out = <SiteLotCar>[];
    if (maxCars <= 0) return out;
    final plan = d.plan;
    final family = airless ? VehicleKind.airless : VehicleKind.road;
    final occ = SiteDressing.occupancyPerMille(plan.siteId);
    for (var i = 0; i < plan.stallCount && out.length < maxCars; i++) {
      final seed = SiteDressing.stallSeed(plan.siteId, plan.stallKey(i));
      if (!SiteDressing.occupied(seed, occ)) continue;
      final len = plan.stallLenM(i);
      if (!(len > 0)) continue;
      // The kind the seed picks, or the next one along that fits the stall.
      VehicleKind? kind;
      final first = SiteDressing.variantOf(seed, family.length);
      for (var v = 0; v < family.length; v++) {
        final k = family[(first + v) % family.length];
        if (k.lengthM <= len * 1.1) {
          kind = k;
          break;
        }
      }
      if (kind == null) continue;
      final centre = d.atLocal(plan.stallE(i), plan.stallN(i),
          d.stallUp(i) + SiteAccessMesher.paveLiftM);
      final up = d.upAt(centre);
      final nose = d.tangent(plan.stallDirE(i), plan.stallDirN(i), up);
      if (nose == null) continue;
      out.add(SiteLotCar(i, kind, centre, nose, up,
          ((seed >> 16) & 0xFF) / 255.0));
    }
    return out;
  }

  /// [lotCars] drawn. Returns how many stood, so a tile can budget them.
  static int emitLotCars(MeshBuilder cars, MeshBuilder glass, SiteDraw d,
      {required int maxCars, required bool airless}) {
    final placed = lotCars(d, maxCars: maxCars, airless: airless);
    for (final c in placed) {
      VehicleMeshes.emit(cars, glass, c.kind, c.at, c.nose, c.up, u: c.u);
    }
    return placed.length;
  }

  // ---- Footpaths and lamps -------------------------------------------------

  /// The plan's footpaths (§6.1 step 6): a concrete ribbon from the door to
  /// the pavement, over the site's own paving.
  static void emitFootpaths(MeshBuilder m, SiteDraw d) {
    final plan = d.plan;
    final band = CityTextureBakes.roadConcrete;
    final u0 = RoadMesher.bandU(band, 0), u1 = RoadMesher.bandU(band, 1);
    for (var q = 0; q < plan.pathCount; q++) {
      final from = plan.pathStart(q), to = plan.pathStart(q + 1);
      if (to - from < 2) continue;
      int? prevL, prevR;
      var arc = 0.0;
      for (var i = from; i < to; i++) {
        final p = plan.pathPt(i);
        final here = d.at(p);
        final next = i + 1 < to ? d.at(plan.pathPt(i + 1)) : null;
        final prev = i > from ? d.at(plan.pathPt(i - 1)) : null;
        final ahead = next != null ? next - here : here - prev!;
        if (ahead.length < 1e-6) continue;
        if (prev != null) arc += (here - prev).length;
        final up = d.upAt(here);
        final side = ahead.normalized.cross(up).normalized;
        final c = here + up * (SiteAccessMesher.paveLiftM + pathLiftM);
        final v = arc / RoadMesher.tileM;
        final l = m.vertex(
            (c - side * (pathWidthM / 2)) * kRenderScale, up, u0, v);
        final r = m.vertex(
            (c + side * (pathWidthM / 2)) * kRenderScale, up, u1, v);
        if (prevL != null && prevR != null) m.quad(prevL, prevR, r, l);
        prevL = l;
        prevR = r;
      }
    }
  }

  /// The car-park lamps the plan places (§3.5): a column on the facade
  /// material with a lit head on the glazing, at each `lampPt`.
  static void emitLamps(MeshBuilder solid, MeshBuilder glow, SiteDraw d) {
    final plan = d.plan;
    for (var l = 0; l < plan.lampCount; l++) {
      final p = plan.lampPt(l);
      if (p < 0 || p >= plan.pointCount) continue;
      final base = d.at(p);
      final up = d.upAt(base);
      final along = d.tangent(plan.frameUE, plan.frameUN, up) ?? d.frame.east;
      OrientedBox.upright(
          solid, base, along, up, lampPostM, lampPostM, lampHeightM);
      final head = base + up * (lampHeightM + 0.1);
      final side = along.cross(up).normalized;
      OrientedBox.emit(glow, head, side, along, up, lampHeadM / 2, 0.22, 0.08);
    }
  }

  // ---- The fence ring and the sign -----------------------------------------

  /// The lot's fence: the REAL parcel polygon walked run by run, with the
  /// plan's gaps left open (`SiteDressing.fenceGapsOf`), standing
  /// [fenceInsetM] inside its own lot line so two neighbours never draw a
  /// fence in one plane. Nothing for a site whose lot ring is gone.
  static void emitFenceRing(MeshBuilder m, SiteDraw d, LotEdging kind,
      {required bool coarse}) {
    if (kind == LotEdging.none) return;
    final (ringE, ringN) = d.lotRing();
    final n = ringE.length;
    if (n < 3) return;
    final gaps = SiteDressing.fenceGapsOf(d.plan, ringE, ringN);
    // Counter-clockwise in (east, north) puts the lot on the left of every
    // edge; clockwise on the right.
    var twice = 0.0;
    for (var i = 0; i < n; i++) {
      final j = i + 1 < n ? i + 1 : 0;
      twice += ringE[i] * ringN[j] - ringE[j] * ringN[i];
    }
    final inward = twice > 0 ? 1.0 : -1.0;
    final upM = d.padUp;
    for (var i = 0; i < n; i++) {
      final j = i + 1 < n ? i + 1 : 0;
      final de = ringE[j] - ringE[i], dn = ringN[j] - ringN[i];
      final len = math.sqrt(de * de + dn * dn);
      if (len < 0.5) continue;
      // The inward normal of edge i, in colony-local metres.
      final ne = -dn / len * inward, nn = de / len * inward;
      for (final (t0, t1) in SiteDressing.fenceRunsOf(i, gaps)) {
        if ((t1 - t0) * len < 0.5) continue;
        final a = d.atLocal(ringE[i] + de * t0 + ne * fenceInsetM,
            ringN[i] + dn * t0 + nn * fenceInsetM, upM);
        final b = d.atLocal(ringE[i] + de * t1 + ne * fenceInsetM,
            ringN[i] + dn * t1 + nn * fenceInsetM, upM);
        LotFeatures.emitFenceRun(m, kind, a, b, d.upAt(a), coarse: coarse);
      }
    }
  }

  /// The lot's sign, beside its primary throat at the lot line
  /// (§5.5: `segWidth/2 + 1.5` m to the building side), or beside its
  /// footpath where the plan has no throat.
  static void emitSign(MeshBuilder solid, MeshBuilder glow, SiteDraw d,
      double scale) {
    final pose = signPose(d);
    if (pose == null) return;
    final (e, n, faceE, faceN) = pose;
    final base = d.atLocal(e, n, d.padUp);
    final up = d.upAt(base);
    final along = d.tangent(faceE, faceN, up);
    if (along == null) return;
    // `emitSign` offsets from a lot rectangle's centre; with no half
    // extents it stands exactly where it is put.
    LotFeatures.emitSign(solid, glow, base, along, up, 0, 0, scale);
  }

  /// Where the sign stands and which way it faces, colony-local: beside the
  /// primary FRONTAGE throat where it crosses the lot line, on the side the
  /// building is; null when the plan gives nowhere to stand it.
  static (double, double, double, double)? signPose(SiteDraw d) =>
      signPoseOf(d.plan);

  /// [signPose] read off the plan alone — it needs nothing else of the draw —
  /// so an alley-backed plan's sign can be pinned without a capture.
  static (double, double, double, double)? signPoseOf(SiteAccessPlan plan) {
    // The frame's v runs from the frontage into the lot, so the lot line is
    // y = 0 in frame metres.
    final ve = plan.frameVE, vn = plan.frameVN;
    double y(double e, double n) =>
        (e - plan.frameE) * ve + (n - plan.frameN) * vn;
    double x(double e, double n) =>
        (e - plan.frameE) * plan.frameUE + (n - plan.frameN) * plan.frameUN;
    final envX = (plan.envX0 + plan.envX1) / 2;
    var seg = -1;
    for (var j = 0; j < plan.joinCount && seg < 0; j++) {
      // A REAR join is no sign's throat (§5.5, R8): its drive leaves the
      // ALLEY behind the lot, tens of metres from the street the sign is
      // read from, and the whole point of the alley is that the frontage
      // stays an unbroken run of shopfronts. An F2a site (§3.5) therefore
      // falls to the footpath rule below and signs its FRONTAGE, exactly as
      // a kerbside plan does — never nothing, and never a board up the
      // service alley behind the shops.
      if (plan.joinSlot(j) == kJoinSlotAlley) continue;
      final t = plan.joinThroatSeg(j);
      if (t >= 0 && t < plan.segCount) seg = t;
    }
    double? atX;
    double? atY;
    double widthM = 0;
    if (seg >= 0) {
      widthM = plan.segWidthM(seg);
      final m = plan.segPointCount(seg);
      for (var i = 1; i < m && atX == null; i++) {
        final a = plan.segPoint(seg, i - 1), b = plan.segPoint(seg, i);
        final ya = y(plan.ptE(a), plan.ptN(a)), yb = y(plan.ptE(b), plan.ptN(b));
        if ((ya <= 0 && yb >= 0) || (ya >= 0 && yb <= 0)) {
          final t = (yb - ya).abs() < 1e-9 ? 0.0 : (0 - ya) / (yb - ya);
          atX = x(plan.ptE(a), plan.ptN(a)) +
              (x(plan.ptE(b), plan.ptN(b)) - x(plan.ptE(a), plan.ptN(a))) * t;
          atY = 0.0;
        }
      }
      if (atX == null) {
        // No crossing: the throat's own end nearest the lot line.
        final p = plan.segPoint(seg, 0);
        atX = x(plan.ptE(p), plan.ptN(p));
        atY = y(plan.ptE(p), plan.ptN(p));
      }
    } else {
      final p = plan.pavementPt;
      if (p < 0 || p >= plan.pointCount) return null;
      widthM = pathWidthM;
      atX = x(plan.ptE(p), plan.ptN(p));
      atY = 0.0;
    }
    final side = envX >= atX ? 1.0 : -1.0;
    final sx = atX + side * (widthM / 2 + signClearanceM);
    final sy = (atY ?? 0) + 1.0;
    // Frame metres back into colony-local, facing the street (−v).
    return (
      plan.frameE + plan.frameUE * sx + ve * sy,
      plan.frameN + plan.frameUN * sx + vn * sy,
      ve,
      vn,
    );
  }

  // ---- Helpers -------------------------------------------------------------

  /// The point [s] metres along segment [k]'s polyline, and the direction
  /// it runs there: (e, n, de, dn), the direction unit.
  static (double, double, double, double) _alongSegment(
      SiteAccessPlan plan, int k, double s) {
    final m = plan.segPointCount(k);
    var at = 0.0;
    for (var i = 1; i < m; i++) {
      final a = plan.segPoint(k, i - 1), b = plan.segPoint(k, i);
      final de = plan.ptE(b) - plan.ptE(a), dn = plan.ptN(b) - plan.ptN(a);
      final len = math.sqrt(de * de + dn * dn);
      if (len < 1e-9) continue;
      if (s <= at + len || i == m - 1) {
        final u = ((s - at) / len).clamp(0.0, 1.0);
        return (
          plan.ptE(a) + de * u,
          plan.ptN(a) + dn * u,
          de / len,
          dn / len,
        );
      }
      at += len;
    }
    final p = plan.segPoint(k, 0);
    return (plan.ptE(p), plan.ptN(p), 0, 0);
  }

  static bool _kerbAtStart(SiteAccessPlan plan, int k) {
    final from = plan.segFrom(k);
    return from >= 0 &&
        from < plan.nodeCount &&
        plan.nodeFlags(from) & kNodeKerb != 0;
  }
}

/// One direction arrow: where on a segment's polyline it lies, which way it
/// points, and how far to the right of the segment's own run it stands.
class SiteArrow {
  const SiteArrow(this.seg, this.s, this.forward, this.offsetM);
  final int seg;
  final double s;
  final bool forward;
  final double offsetM;
}

/// One baked lot car: the stall it stands in and the pose it stands at.
class SiteLotCar {
  const SiteLotCar(this.stall, this.kind, this.at, this.nose, this.up, this.u);

  /// The plan-local stall index.
  final int stall;
  final VehicleKind kind;

  /// Anchor-relative metres, the way it noses, and the local radial.
  final Vector3 at, nose, up;

  /// Its column in the vehicle palette.
  final double u;
}
