// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The home driveway and pad (docs/plans/site-access.md §3.4): one straight
/// run from the kerb, cars in forward and out backing into the street
/// (§10.2 Q3, §7.4 Home back-out).
///
/// ```
///   K (kerb node, exactly slot 0's kerb point)
///   │ throat K→H: driveway, sharedSingle, width w, along the ROAD normal n,
///   │             k + yT metres of frame depth (≥ 7 m), kSegThroat
///   H (the throat's far node, frame y = yT = max(7 − k, 1))
///   │ pad H→P: apron, sharedSingle, width w, collinear, 5.2·r m
///   P (the pad end: kNodeDeadEnd, no turnaround; V7's home exception)
/// ```
///
/// Variants in order, the first that fits wins: two side by side on a 5.2 m
/// drive, two in tandem on a 3.2 m drive, one on a 3.2 m drive. The house
/// stands beside the drive on the larger side (ties by the seed), inside
/// `[drive edge + 1, W − 1.5] × [yT, D − 3]`, at least 8 × 8 m.
///
/// The drive is laid along the slot's road normal, which §3.3 rule 4 keeps
/// within 10° of the frame's `v`; every threshold is measured on the drive's
/// real corners in the frame, so on a square lot (`v` = the normal) they are
/// exactly §3.4's: W ≥ x_d + 13.1 side by side, W ≥ x_d + 12.1 tandem, D ≥ 15.
///
/// Back-out eligibility (§3.3 rules 1–4) is the dispatcher's; this file owns
/// rule 5, the geometry.
library;

import 'dart:math' as math;

import '../parcel.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_envelope.dart';
import 'site_frame.dart';
import 'site_plan_builder.dart';
import 'site_plan_generator.dart';

/// §3.4's variants, in the order they are tried.
enum HomeVariant {
  sideBySide(kHomeSideBySideWidthM, 1, 2),
  tandem(kHomeTandemWidthM, kHomeMaxTandem, 2),
  single(kHomeTandemWidthM, 1, 1);

  const HomeVariant(this.widthM, this.rows, this.stalls);

  /// Drive width w, stall rows r along the pad, stalls.
  final double widthM;
  final int rows;
  final int stalls;
}

/// A fitted home plan (§3.4), ready to write.
class HomeDrivewayPlan implements SiteGeneratedPlan {
  HomeDrivewayPlan._({
    required this.variant,
    required this.houseOnRight,
    required this.envelope,
    required this.frontY,
    required this.throatLengthM,
  });

  final HomeVariant variant;

  /// Whether the house stands at larger frame x than the drive.
  final bool houseOnRight;

  /// The house envelope, frame metres.
  final SiteEnvelope envelope;

  /// `yT`: the frame y of the throat's far node `H`.
  final double frontY;

  /// `|K→H|` along the road normal.
  final double throatLengthM;

  @override
  SiteProgram get program => SiteProgram.homeDriveway;

  @override
  void emit(PlanBuilder b, SiteContext ctx, int dispatchFlags) {
    final slot = ctx.slot0;
    final w = variant.widthM;
    final ne = slot.normE, nn = slot.normN;
    final ue = nn, un = -ne; // the normal turned a quarter clockwise
    final ke = slot.kerbE, kn = slot.kerbN;
    final he = ke + ne * throatLengthM, hn = kn + nn * throatLengthM;
    final padM = kStallLengthM * variant.rows;
    final pe = he + ne * padM, pn = hn + nn * padM;

    ctx.beginSite(b, program, dispatchFlags | kPlanNetwork, envelope);
    final cut = math.max(kHomeCutHalfM, w / 2 + kCutFlareM);
    final j = ctx.addJoin(b, 0, cutHalfM: cut);
    final kNode = ctx.kerbNode(b, slot, j);
    final hNode = b.node(b.point(he, hn));
    final pNode = b.node(b.point(pe, pn), flags: kNodeDeadEnd);
    // A site set far back from its kerb (a footprint, a curved road) has a
    // throat longer than V5's via gap: evenly spaced vias on the chord.
    final gaps = (throatLengthM / kViaMaxGapM).ceil();
    final vias = [
      for (var i = 1; i < gaps; i++)
        b.point(ke + ne * throatLengthM * i / gaps,
            kn + nn * throatLengthM * i / gaps),
    ];
    final throat = b.segment(kNode, hNode,
        vias: vias,
        kind: SiteSegmentKind.driveway,
        mode: SiteLaneMode.sharedSingle,
        widthM: w,
        flags: kSegThroat |
            (ctx.crossesPavement(slot) ? kSegCrossesPavement : 0));
    final pad = b.segment(hNode, pNode,
        kind: SiteSegmentKind.apron,
        mode: SiteLaneMode.sharedSingle,
        widthM: w);
    b.setJoinNetwork(j, kerbNode: kNode, throatSeg: throat);

    void stall(double along, double across, double s, int side, int bay) {
      b.stall(
        seg: pad,
        s: s,
        side: side,
        angle: StallAngle.inline,
        inDirs: kSiteDirFwd,
        outDirs: kSiteDirBwd,
        e: he + ne * along + ue * across,
        n: hn + nn * along + un * across,
        dirE: ne,
        dirN: nn,
        lenM: kStallLengthM,
        widthM: kStallWidthM,
        row: 0,
        bay: bay,
      );
    }

    final half = kStallLengthM / 2;
    switch (variant) {
      case HomeVariant.sideBySide:
        // S0 right of +n travel (side 0), S1 left (side 1), both at s = 0.
        stall(half, kStallWidthM / 2, 0, 0, 0);
        stall(half, -kStallWidthM / 2, 0, 1, 0);
      case HomeVariant.tandem:
        stall(half, 0, 0, 0, 0);
        stall(half + kStallLengthM, 0, kStallLengthM, 0, 1);
      case HomeVariant.single:
        stall(half, 0, 0, 0, 0);
    }

    // The drive's pave: the kerb corners blend from the kerb, the pad's are
    // the pad's (§6.3 ramp). Counter-clockwise.
    final hw = w / 2;
    b.pave([
      b.point(ke + ue * hw, kn + un * hw,
          ref: SiteHeightRef.blend, hJoin: j, hT: 1),
      b.point(pe + ue * hw, pn + un * hw),
      b.point(pe - ue * hw, pn - un * hw),
      b.point(ke - ue * hw, kn - un * hw,
          ref: SiteHeightRef.blend, hJoin: j, hT: 1),
    ]);

    final (dx, dy) = envelopeDoor(envelope);
    final door = ctx.localPoint(b, dx, dy);
    final pavement = ctx.localPoint(b, dx, 0);
    ctx.finishPedestrians(b, door, pavement, entranceNode: hNode);
    b.endSite();
  }
}

/// §3.4 on [ctx], or null when no variant fits (rule 5, geometry). The
/// caller has checked back-out rules 1–4; [ctx] has a frame and slot 0.
HomeDrivewayPlan? homeDrivewayPlanOf(SiteContext ctx) {
  final frame = ctx.frame;
  if (frame == null || ctx.slotCount == 0) return null;
  final slot = ctx.slot0;
  final profile = frame.profile;
  final wLot = frame.widthM;
  final kerb = frame.toLocal(Vec2(slot.kerbE, slot.kerbN));
  final k = -kerb.n;
  final ne = slot.normE, nn = slot.normN;
  final c = ne * frame.v.e + nn * frame.v.n;
  if (!(c > 0)) return null;
  final yT = math.max(kHomeThroatReachM - k, kHomeMinFrontYM);
  final throatM = (k + yT) / c;
  final ue = nn, un = -ne;

  for (final variant in HomeVariant.values) {
    final hw = variant.widthM / 2;
    final lengthM = throatM + kStallLengthM * variant.rows;
    // The drive's corners in the frame.
    var minX = double.infinity, maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final along in [0.0, lengthM]) {
      for (final across in [-hw, hw]) {
        final p = frame.toLocal(Vec2(slot.kerbE + ne * along + ue * across,
            slot.kerbN + nn * along + un * across));
        minX = math.min(minX, p.e);
        maxX = math.max(maxX, p.e);
        maxY = math.max(maxY, p.n);
      }
    }
    // The house: right of the drive, or left of it.
    final rightX0 = maxX + kHomeDriveGapM, rightX1 = wLot - kHomeSideSetbackM;
    final leftX0 = kHomeSideSetbackM, leftX1 = minX - kHomeDriveGapM;
    final rightOk = rightX1 - rightX0 >= kHomeMinHouseM - kGenEpsM &&
        minX >= kHomeOuterEdgeM - kGenEpsM;
    final leftOk = leftX1 - leftX0 >= kHomeMinHouseM - kGenEpsM &&
        wLot - maxX >= kHomeOuterEdgeM - kGenEpsM;
    if (!rightOk && !leftOk) continue;
    bool right;
    if (rightOk && leftOk) {
      final dr = rightX1 - rightX0, dl = leftX1 - leftX0;
      right = (dr - dl).abs() <= kGenEpsM
          ? ctx.tieBreak('home-side') & 1 == 0
          : dr > dl;
    } else {
      right = rightOk;
    }
    final hx0 = right ? rightX0 : leftX0, hx1 = right ? rightX1 : leftX1;

    // Depth over the drive: the deepest stall and 0.5 m behind it.
    final driveDepth = depthOver(profile, math.max(minX, 0), maxX);
    if (driveDepth < maxY + kHomeStallClearM - kGenEpsM) continue;
    // Depth over the house: yT + 8 + the 3 m rear yard.
    final houseDepth = depthOver(profile, hx0, hx1);
    final hy1 = houseDepth - kHomeRearYardM;
    if (hy1 - yT < kHomeMinHouseM - kGenEpsM) continue;
    // Exact containment of the drive's on-parcel stretch and the house.
    if (!profile.containsRect(SiteRect(minX, kContainsInsetM, maxX, maxY)) ||
        !profile.containsRect(SiteRect(hx0, yT, hx1, hy1))) {
      continue;
    }
    return HomeDrivewayPlan._(
      variant: variant,
      houseOnRight: right,
      envelope: SiteEnvelope(hx0, yT, hx1, hy1),
      frontY: yT,
      throatLengthM: throatM,
    );
  }
  return null;
}
