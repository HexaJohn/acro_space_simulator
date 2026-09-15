// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Every metre and threshold site access generation reads
/// (docs/plans/site-access.md).
///
/// Traffic READS these and never re-declares them. Values copied from another
/// module are pinned equal to their source by a test, so the two cannot
/// drift. Slice R-F declares the site frame's and road eligibility's
/// constants; later slices append their own.
library;

// ---- Site frame (§3.1) ----

/// A frontage shorter than this is degenerate: it has no direction, so the
/// site has no frame.
const double kFrameDegenerateM = 1e-6;

/// A polygon under this area (m²) has no frame (§3.8): no plan, legacy slot.
/// The same 30 m² floor the plat drops auto lots below.
const double kMinSiteAreaM2 = 30.0;

/// A stored frontage whose midpoint lies further than this from the polygon's
/// boundary is not trusted: `effectiveFrontage` replaces it.
const double kFrontageOffPolygonM = 1.0;

/// Only polygon edges at least this long are `effectiveFrontage` candidates.
const double kEffectiveFrontageMinEdgeM = 6.0;

/// Score weight of edge/road parallelism in `dist − 15·|t_edge·t_road|`.
const double kEffectiveFrontageTangentWeight = 15.0;

/// How far past its half width a road may lie from a lot edge and still be
/// that lot's road. Pinned equal to `RoadGraph.manualReachM`.
const double kSiteReachM = 90.0;

// ---- Depth profile (§3.1) ----

/// Column pitch of a `DepthProfile`, metres along the frontage.
const double kDepthProfileStepM = 0.5;

/// Margin a profile column's inside interval is shrunk by at each end.
const double kDepthProfileMarginM = 0.3;
