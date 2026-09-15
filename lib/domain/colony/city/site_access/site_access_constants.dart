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

// ---- Join handles (§2.3), slice R2a ----

/// A plan join with no graph join: a footprint site's own join
/// (`RoadGraph.attachFootprintJoins`) or a kerbside plan with no slot.
const int kJoinRefNone = -1;

/// A corner lot's side-street slot 2 is named `kJoinRefSideStreetBase − lot`,
/// so `lot = kJoinRefSideStreetBase − joinRef` (every such handle is ≤ −2).
const int kJoinRefSideStreetBase = -2;

/// `SiteAccessChunk.joinSlot` of the side-street slot (not packed on
/// `RoadGraph`, §3.2 as built).
const int kJoinSlotSideStreet = 2;

// ---- Plan flags (§2.3): `SiteAccessPlan.flags` bits, slice R2a ----

/// The plan has nodes and segments: cars drive in (every program but
/// `kerbOnly`).
const int kPlanNetwork = 1;

/// Some in→bay→out path takes trucks (V13).
const int kPlanAdmitsTrucks = 2;

/// The generator fell back to a lesser program.
const int kPlanFallback = 4;

/// Slot 0's corridor is blocked or crosses a built lot (§3.3 row 0c).
const int kPlanAccessBlocked = 8;

/// Public parking (reserved for R8).
const int kPlanPublic = 16;

// ---- Node flags (§2.3): `SiteAccessChunk.nodeFlags` bits ----

/// The kerb node of a cut join: site degree 1, reached from the road only by
/// access events.
const int kNodeKerb = 1;

/// An installation gate.
const int kNodeGate = 2;

/// Three or more segments meet here.
const int kNodeBranch = 4;

/// A dead end.
const int kNodeDeadEnd = 8;

// ---- Segment flags (§2.3): `SiteAccessChunk.segFlags` bits ----

/// The segment leaving a cut join's kerb node (V5).
const int kSegThroat = 1;

/// A pavement lies within the segment's first 3 m.
const int kSegCrossesPavement = 2;

/// Built for trucks.
const int kSegTruck = 4;

// ---- Direction bits of stalls (§2.3): `stallInDirs` / `stallOutDirs` ----

/// The segment's from→to lane (site lane `2k`).
const int kSiteDirFwd = 1;

/// The segment's to→from lane (site lane `2k + 1`).
const int kSiteDirBwd = 2;

// ---- Chunks (§2.3, §3.10) ----

/// At most this many sites per `SiteAccessChunk`.
const int kSitesPerChunk = 1024;

/// Plan-local limits (V6, V9).
const int kMaxPlanNodes = 4096;
const int kMaxPlanStalls = 1024;

// ---- Invariant thresholds (§2.4) ----

/// A throat is at least this long, and no stall mouth, bay mouth or branch
/// node lies nearer its kerb node along the site path (V5).
const double kThroatMinM = 7.0;

/// A throat's via points lie within this of its kerb→far chord; a home pad's
/// end node within this of the throat's chord extended (V5).
const double kThroatStraightM = 0.1;

/// cos 10°: a throat (and a home's `v`) within 10° of the road normal
/// (V5, §3.3 rule 4). A constant, never trigonometry (C-11).
const double kCos10 = 0.98481;

/// cos 150°: the sharpest deflection a site movement may take (§2.5).
const double kCos150 = -0.8660254;

/// Via points of a segment are at most this far apart (V5, V8).
const double kViaMaxGapM = 24.0;

/// Home cut half width, for the back-out's tail swing (V5, §3.3 rule 2).
const double kHomeCutHalfM = 4.0;

/// Lane upstream of a home join per served direction (V1, §3.3 rule 3).
const double kHomeSwingMarginM = 12.0;

/// A pavement within this of the kerb node sets `kSegCrossesPavement` (V5).
const double kCrossesPavementM = 3.0;

/// Nodes lie at least this far apart; segments are at least this long (V6).
const double kNodeMinGapM = 0.5;
const double kSegMinLenM = 1.0;

/// Segment widths (V8): the range; two-way; two-way with perpendicular
/// stalls; one-way with angled stalls. `sharedSingle` is narrower than
/// [kTwoWayMinWidthM].
const double kSegMinWidthM = 3.0;
const double kSegMaxWidthM = 12.0;
const double kTwoWayMinWidthM = 5.5;
const double kTwoWayPerpendicularMinWidthM = 6.0;
const double kAngledMinWidthM = 3.5;

/// Site speed limits (V8): the ceiling (20 km/h) and the defaults.
const double kSiteMaxSpeedMps = 20 / 3.6;
const double kAisleSpeedMps = 10 / 3.6;
const double kAccessRoadSpeedMps = 20 / 3.6;

/// `segMaxVehLenM` is at least this (V8).
const double kSegMinVehLenM = 5.5;

/// `segLenM` equals the 2-D polyline length to this (V8).
const double kSegLenTolM = 1e-6;

/// Stalls (V9): nose alignment, run-up for a forward turn in, half stall
/// width counted against it.
const double kStallNoseDot = 0.9;
const double kStallRunupM = 5.0;
const double kStallRunupHalfWidthM = 1.3;

/// Turnarounds (V7): a circle's radius; a hammerhead's clear apron (form a);
/// a T end's stall-free tail, its aisle, and its paved row depth (form b).
const double kTurnCircleMinM = 6.0;
const double kHammerheadApronM = 6.0;
const double kTEndClearM = 3.0;
const double kTEndAisleMinM = 6.0;
const double kTEndRowDepthM = 5.2;

/// Trucks (V13): width, turning radius and vehicle length on the path.
const double kTruckMinWidthM = 3.5;
const double kTruckTurnMinM = 12.5;
const double kTruckMinVehLenM = 12.0;

/// A network plan's door lies within this of its entrance node (V11).
const double kEntranceMaxM = 60.0;

/// A kerbside plan's pavement point lies within this of its slot's kerb
/// point (V11).
const double kPavementPointMaxM = 3.5;

/// Revision quantisation (V12): coordinates and metres to 1 cm, unit
/// vectors ×1000.
const double kRevMetresScale = 100.0;
const double kRevUnitScale = 1000.0;
