// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Program classification (docs/plans/site-access.md §3.3): which generator a
/// built site asks first, the home back-out eligibility of its slot 0, the
/// capacity targets and the minimum envelope, and the demotion counters the
/// sprawl audit reads.
///
/// [classifyProgram] decides the program a site is OFFERED by the table's
/// first matching row; the dispatcher (`site_plan_generator.dart`) then runs
/// the generators in fall-through order and counts every demotion by rule in
/// a [SiteProgramStats].
///
/// Reads only the site's spec, frame and slots, its road and its piece's kerb
/// windows: never a junction override, the ground or the clock. Determinism
/// (§3.9): no platform hash, draw, map iteration or trigonometry.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../architecture/building_massing.dart';
import '../city_building_spec.dart';
import '../parcel.dart';
import '../road_catalog.dart';
import '../road_graph.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_join.dart';

/// The massing rules whose `requiredArea` and `parkingSpaces` §3.3 reads.
const BuildingMassingRules kSiteMassingRules = BuildingMassingRules();

/// Why a site did not get the program its row offered, or why it got a
/// lesser one. Append-only: the sprawl audit pins counts by index.
enum SiteDemotion {
  /// §3.3 back-out rule 1: the road's class, speed or median.
  homeRoad,

  /// Rule 2: `joinRoomM(slot 0) < kHomeCutHalfM`.
  homeRoom,

  /// Rule 3: no 12 m swing margin inside the kerb windows.
  homeSwingMargin,

  /// Rule 4: `v` more than 10° off the road normal at the join.
  homeSkew,

  /// Rule 5: §3.4 does not fit.
  homeGeometry,

  /// Row 1: an installation site under 60 × 120 m, handed to row 4.
  installationTooSmall,

  /// The installation generator found nothing.
  installationNoFit,

  /// The yard generator's apron did not fit: its car park alone was written
  /// (`carPark`, `kPlanFallback`), or, when that did not fit either,
  /// `kerbOnly`.
  yardNoFit,

  /// The car park generator found nothing.
  carParkNoFit,

  /// Row 0b: slot 0 is legacy.
  legacySlot,

  /// Row 0c: the corridor is blocked, or crosses a built lot.
  accessBlocked,

  /// Row 2: a megatower parks in its podium.
  mega,

  /// §3.8: a true depth D under 8 m or a frontage under 6 m.
  sliver,

  /// §3.8: no site frame (degenerate polygon); kerbside at slot 0.
  degenerate,
}

/// Counts of the programs emitted and the demotions met, by
/// [SiteProgram] / [SiteDemotion] index. One per full-town run; the
/// dispatcher adds to it.
class SiteProgramStats {
  final Int32List programs = Int32List(SiteProgram.values.length);
  final Int32List demotions = Int32List(SiteDemotion.values.length);

  /// Sites that got no plan (unbuilt, no slot, no frontage road).
  int unplanned = 0;

  int programCount(SiteProgram p) => programs[p.index];
  int demotionCount(SiteDemotion d) => demotions[d.index];

  void addAll(SiteProgramStats other) {
    for (var i = 0; i < programs.length; i++) {
      programs[i] += other.programs[i];
    }
    for (var i = 0; i < demotions.length; i++) {
      demotions[i] += other.demotions[i];
    }
    unplanned += other.unplanned;
  }

  @override
  String toString() => [
        for (final p in SiteProgram.values) '${p.name} ${programs[p.index]}',
        for (final d in SiteDemotion.values)
          if (demotions[d.index] != 0) '-${d.name} ${demotions[d.index]}',
        'unplanned $unplanned',
      ].join(', ');
}

/// What §3.3's rows offer a built site before any generator runs.
class ProgramOffer {
  const ProgramOffer(this.program, {this.flags = 0, this.demotion});

  /// The first program the dispatcher tries (`kerbOnly` when a row settles
  /// it outright).
  final SiteProgram program;

  /// `kPlanAccessBlocked` for row 0c.
  final int flags;

  /// The rule that settled a `kerbOnly` offer, when one did.
  final SiteDemotion? demotion;
}

/// Whether [spec] is industrial (§3.3 row 4).
bool isIndustrialSpec(CityBuildingSpec spec) =>
    kIndustrialGroups.contains(spec.group);

/// §3.3 rows 0b–5 for a BUILT site (row 0a, unbuilt, is the caller's: it
/// stores no plan). [slot0] is the site's slot 0, [widthM] and [depthM] its
/// frame W and true D (0 when it has no frame; the sliver row tests this true
/// D, not an inscribed depth, §3.8 as built), [hasFrame] whether it has a
/// frame, [lotBuilt] whether a graph lot has a building.
ProgramOffer classifyProgram({
  required CityBuildingSpec spec,
  required JoinSlot slot0,
  required double widthM,
  required double depthM,
  required bool hasFrame,
  required bool Function(int lot) lotBuilt,
}) {
  if (slot0.flags & kJoinLegacy != 0) {
    return const ProgramOffer(SiteProgram.kerbOnly,
        demotion: SiteDemotion.legacySlot);
  }
  if (slot0.flags & kJoinCorridorBlocked != 0) {
    return const ProgramOffer(SiteProgram.kerbOnly,
        flags: kPlanAccessBlocked, demotion: SiteDemotion.accessBlocked);
  }
  for (final lot in slot0.crossLots) {
    if (lotBuilt(lot)) {
      return const ProgramOffer(SiteProgram.kerbOnly,
          flags: kPlanAccessBlocked, demotion: SiteDemotion.accessBlocked);
    }
  }
  if (!hasFrame) {
    return const ProgramOffer(SiteProgram.kerbOnly,
        demotion: SiteDemotion.degenerate);
  }
  if (depthM < kSliverMinDepthM - kGenEpsM ||
      widthM < kSliverMinWidthM - kGenEpsM) {
    return const ProgramOffer(SiteProgram.kerbOnly,
        demotion: SiteDemotion.sliver);
  }
  final group = spec.group;
  final ownSiteInstallation = spec.claimsOwnSite &&
      math.min(widthM, depthM) >= kInstallationMinSiteM - kGenEpsM &&
      group != kResidentialGroup &&
      group != kCommercialGroup;
  if (spec.siteKind != SiteKind.building || ownSiteInstallation) {
    if (widthM < kInstallationMinWidthM - kGenEpsM ||
        depthM < kInstallationMinDepthM - kGenEpsM) {
      return const ProgramOffer(SiteProgram.yard,
          demotion: SiteDemotion.installationTooSmall);
    }
    return const ProgramOffer(SiteProgram.installation);
  }
  if (spec.type == kMegaSpecType) {
    return const ProgramOffer(SiteProgram.kerbOnly,
        demotion: SiteDemotion.mega);
  }
  if (group == kResidentialGroup && spec.housing <= kHomeMaxHousing) {
    return const ProgramOffer(SiteProgram.homeDriveway);
  }
  if (isIndustrialSpec(spec)) return const ProgramOffer(SiteProgram.yard);
  return const ProgramOffer(SiteProgram.carPark);
}

/// Whether `[lo, hi]` lies in one kerb window of [piece] (within
/// [kGenEpsM]): the validator's V1 test.
bool inKerbWindow(KerbWindows w, int piece, double lo, double hi) {
  if (piece < 0 || piece >= w.pieceCount) return false;
  for (var k = w.start[piece]; k < w.start[piece + 1]; k++) {
    if (lo >= w.lo[k] - kGenEpsM && hi <= w.hi[k] + kGenEpsM) return true;
  }
  return false;
}

/// The first §3.3 back-out rule slot 0 fails (road, room, swing margin,
/// skew), or null when it is eligible for `homeDriveway`. Rule 5 (geometry)
/// is §3.4's. [v] is the site frame's inward unit vector.
///
/// Rule 1 reads [RoadType.of] the road's speed and its cross-section's
/// median (`RoadSpline.lanes`, decoration included: a planted median is a
/// median). Rule 3 tests the use-free window form of V1's swing margin:
/// forward travel needs `[s − 6, s + 4]`, backward `[s − 4, s + 6]`, both
/// `[s − 6, s + 6]`.
SiteDemotion? homeBackOutFailure(RoadGraph g, JoinSlot slot, Vec2 v) {
  if (slot.piece < 0 || slot.piece >= g.pieceCount) return SiteDemotion.homeRoad;
  final road = g.roads[g.pieceRoad[slot.piece]];
  if (!homeRoadEligible(road)) return SiteDemotion.homeRoad;
  if (slot.roomM < kHomeCutHalfM - kGenEpsM) return SiteDemotion.homeRoom;
  final margin = kHomeSwingMarginM - kJoinWindowClearM;
  final fwd = slot.dirs & RoadGraph.forwardBit != 0;
  final bwd = slot.dirs & RoadGraph.backwardBit != 0;
  final lo = slot.s - (fwd ? margin : kHomeCutHalfM);
  final hi = slot.s + (bwd ? margin : kHomeCutHalfM);
  if (!inKerbWindow(g.kerbWindows, slot.piece, lo, hi)) {
    return SiteDemotion.homeSwingMargin;
  }
  if (v.e * slot.normE + v.n * slot.normN < kCos10) {
    return SiteDemotion.homeSkew;
  }
  return null;
}

/// Back-out rule 1 on [road] alone (§3.3, §7.4 restrictions).
bool homeRoadEligible(RoadSpline road) {
  final lanes = road.lanes;
  if (lanes != null && lanes.medianM > 0) return false;
  final speed = RoadType.of(road).speedKmh;
  switch (road.roadClass) {
    case RoadClass.street:
    case RoadClass.streetOneWay:
    case RoadClass.alley:
    case RoadClass.path:
      return speed <= kHomeMinorMaxSpeedKmh;
    case RoadClass.avenue:
      return speed <= kHomeAvenueMaxSpeedKmh;
    default:
      return false;
  }
}

/// §3.3 capacity target for [program] on [spec] (`C* = parkingSpaces`).
int capacityTarget(SiteProgram program, CityBuildingSpec spec) {
  final c = kSiteMassingRules.parkingSpaces(spec);
  switch (program) {
    case SiteProgram.homeDriveway:
      return kHomeStalls;
    case SiteProgram.carPark:
    case SiteProgram.yard:
      if (spec.group == kCommercialGroup) {
        return math.max(c, kCarParkMinStallsCom);
      }
      if (spec.group == kResidentialGroup || isIndustrialSpec(spec)) {
        return math.max(c, kCarParkMinStalls);
      }
      return math.max(c, kCarParkMinStallsCivic);
    case SiteProgram.installation:
      return math.min(kInstallationMaxStalls,
          math.max(kInstallationMinStalls, c));
    case SiteProgram.none:
    case SiteProgram.kerbOnly:
      return 0;
  }
}

/// The stall count a car park's score rewards up to (§3.5 `cap`): 1.5·C* for
/// `com`, C* otherwise.
double capacityScoreCap(CityBuildingSpec spec) {
  final c = kSiteMassingRules.parkingSpaces(spec).toDouble();
  return spec.group == kCommercialGroup ? kCapacityScoreComFactor * c : c;
}

/// `A_min = requiredArea(spec) / floorsCap` (§3.3 minimum envelope).
double minEnvelopeArea(CityBuildingSpec spec) {
  final intensity = spec.housing + spec.jobs;
  final double cap;
  if (isIndustrialSpec(spec)) {
    cap = kFloorsCapIndustrial;
  } else if (intensity >= kFloorsIntensityTall) {
    cap = kFloorsCapTall;
  } else if (intensity >= kFloorsIntensityMid) {
    cap = kFloorsCapMid;
  } else {
    cap = kFloorsCapLow;
  }
  return kSiteMassingRules.requiredArea(spec) / cap;
}
