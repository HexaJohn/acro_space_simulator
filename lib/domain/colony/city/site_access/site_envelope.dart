// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The building envelope rules a site is measured by
/// (docs/plans/site-access.md §2.1, §6.1).
///
/// R0 moved the legacy footprint rule here from the world snapshot, unchanged
/// and pure, so the domain envelope (R2/R4) and the renderer read one rule.
/// `world_snapshot.dart` re-exports these names, so no caller changed.
library;

import 'dart:math' as math;

import '../city_building_spec.dart';
import '../parcel.dart';

/// The footprint a building takes on [parcel], metres.
///
/// One rule, because two things need the same answer: the building itself, and
/// the ring of ZONED GROUND drawn around it. Compute them separately and the
/// yard either overlaps the walls or leaves a gap of bare terrain.
({double width, double depth}) buildingFootprint(
    Parcel parcel, CityBuildingSpec spec) {
  final extent = parcel.inscribedExtent;
  final back = lotSetbackFor(spec);
  final cover = lotCoverageFor(spec);
  final lotW = math.max((extent.width - 2 * back) * cover, extent.width * 0.35);
  final lotD = math.max((extent.depth - 2 * back) * cover, extent.depth * 0.35);
  return (
    width: spec.siteWidthM > 0 ? math.min(lotW, spec.siteWidthM) : lotW,
    depth: spec.siteDepthM > 0 ? math.min(lotD, spec.siteDepthM) : lotD,
  );
}

/// Smallest setback from a lot line, metres.
///
/// Wider than `CityTerrainShaper.padEdgeM`, which is what makes it work: the
/// pad is flat right out to the lot line and eases off over that edge, so a
/// building inset past the ease-off stands wholly on level ground. Nothing may
/// be inset less than this or it starts straddling the step to the terrace
/// next door.
const double kLotSetbackM = 1.2;

/// Setback for [spec], metres.
///
/// Density decides how much of its plot a building takes. A tower downtown
/// meets the pavement and leaves no slack; a low-density house sits back
/// behind a garden. Every building used the SAME setback before, so a dense
/// street had the same gaps as a suburban one and the whole colony read at one
/// density however it was zoned.
///
/// Intensity — residents plus workers per building — is the density signal a
/// spec actually carries; `Density` itself does not survive onto the spec.
double lotSetbackFor(CityBuildingSpec spec) {
  final intensity = spec.housing + spec.jobs;
  if (intensity >= 90) return kLotSetbackM; // towers meet the street
  if (intensity >= 30) return 2.2;
  return 4.0; // detached, with room around it
}

/// Share of its plot [spec] covers, once set back.
///
/// The other half of the same idea: a dense block fills what it is given, a
/// low-density one leaves garden around the footprint.
double lotCoverageFor(CityBuildingSpec spec) {
  final intensity = spec.housing + spec.jobs;
  if (intensity >= 90) return 0.96;
  if (intensity >= 30) return 0.86;
  return 0.72;
}
