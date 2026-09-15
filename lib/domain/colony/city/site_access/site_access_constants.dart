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

// ---- Node reserve (§3.2), slice R1 ----

/// Radius of the turning circle the tiles draw at a street end nothing else
/// meets. Pinned against the literal in `city_tile_mesher.dart`.
const double kCulDeSacRadiusM = 11.0;

/// The flare a kerb cut adds beyond its throat, each side: part of every cut
/// half width, and of the cul-de-sac reserve.
const double kCutFlareM = 1.0;

/// A crossing plate's radius per unit of the widest leg's half width, and the
/// stop bar's place on it. Pinned against `traffic/node_control.dart`.
const double kReservePlatePerHalfWidth = 1.45;
const double kReserveStopBarAt = 0.92;

/// How far past the plate the tiles pull a pavement back from a junction
/// (its zebra). Pinned against `city_tile_mesher.dart`'s pull-back.
const double kReservePavementPullBackM = 5.5;

/// A roundabout's radius, `max(14, 2·hw + 6)`, and its yield line's place on
/// it. Pinned against `traffic/node_control.dart`.
const double kReserveRoundaboutMinRadiusM = 14.0;
const double kReserveRoundaboutPerHalfWidth = 2.0;
const double kReserveRoundaboutExtraM = 6.0;
const double kReserveYieldLineAt = 0.96;

// ---- Kerb windows (§3.2) ----

/// Clear lane every cut keeps from a node's reserve, each end of a piece.
const double kJoinWindowClearM = 6.0;

/// Clearance kept either side of a bridge.
const double kJoinBridgeClearM = 3.0;

/// The stretch at a road's tapered end where no cut goes. Pinned against
/// `TrafficCapture.taperM`.
const double kJoinTaperM = 90.0;

/// A deck stretch whose elevation above the laid ground is at least this is
/// off grade: no cut there.
const double kJoinOffGradeM = 0.5;

// ---- Slot placement (§3.2) ----

/// A frontage narrower than this is narrow: its slot sits at one end.
const double kNarrowFrontageM = 30.0;

/// Preferred cut half widths (flare included): narrow and wide frontages.
const double kNarrowCutHalfM = 4.0;
const double kWideCutHalfM = 4.5;

/// The half width a slot is retried at when the preferred one fits nowhere:
/// room for a single-lane throat only.
const double kJoinMinRoomM = 2.5;

/// A narrow lot's target lies this far in from its lot line.
const double kNarrowTargetInsetM = 4.5;

/// Within this of equidistant from its piece's two nodes, a narrow lot's
/// target goes to the larger-s end.
const double kNarrowTieM = 2.0;

/// Corner clear inside the lot span: small frontages, and frontages of at
/// least [kWideCornerFrontageM].
const double kCornerClearM = 0.5;
const double kWideCornerClearM = 5.0;
const double kWideCornerFrontageM = 150.0;

/// Slot arcs are quantised to this; a slot moved further than
/// [kJoinClampedM] from its target is flagged clamped.
const double kJoinQuantumM = 0.25;
const double kJoinClampedM = 0.25;

/// A frontage line further behind the kerb than
/// `max(sidewalkM + kSetBackSidewalkSlackM, kSetBackMinM)` is set back: its
/// slot runs the §3.7a corridor search.
const double kSetBackMinM = 3.0;
const double kSetBackSidewalkSlackM = 0.5;

/// Slot 1 (a second own-road slot at the far end of the span) is offered from
/// this frontage, at least [kSecondSlotMinGapM] from slot 0.
const double kSecondSlotMinFrontageM = 60.0;
const double kSecondSlotMinGapM = 30.0;

/// At most this many join slots per lot.
const int kMaxJoinSlots = 4;

// ---- Access corridors (§3.7a) ----

/// Half width of an access corridor: a 7 m road and a metre each side.
const double kAccessCorridorHalfM = 4.5;

/// An auto lot is crossed when a corridor overlaps it by more than this.
const double kCorridorOverlapM = 0.05;

/// The join road within this arc of the slot is not an obstacle to its own
/// corridor.
const double kCorridorJoinRoadSkipM = 12.0;

/// Hard-obstacle retries: the target moved by each of these, both ways.
const List<double> kCorridorRetryM = [5.0, 10.0, 15.0];

/// A dogleg's straight throat from the kerb, and how far its frontage leg
/// keeps from the lot's side lines.
const double kDoglegThroatM = 12.0;
const double kDoglegSideClearM = 30.0;

// ---- Join flags (§2.2): `RoadGraph.joinFlags` bits ----

/// A kerb cut fits at the slot.
const int kJoinCut = 1;

/// No span fitted: today's access point, kept as it was (room 0).
const int kJoinLegacy = 2;

/// On a corner lot's side street, not its own road.
const int kJoinSideStreet = 4;

/// The slot moved more than [kJoinClampedM] from its target.
const int kJoinClamped = 8;

/// The lot span met no window on this road; the nearest window point was
/// taken (a lot wholly past a road end), bridged by a dogleg.
const int kJoinOffFrontage = 16;

/// The slot's access corridor crosses at least one auto lot.
const int kJoinEasement = 32;

/// Every corridor candidate hit a manual parcel or a road.
const int kJoinCorridorBlocked = 64;

/// A rear alley slot (reserved for R8).
const int kJoinAlley = 128;
