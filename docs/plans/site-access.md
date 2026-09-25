# Site access: driveways, car parks and access roads

Status: authoritative design, 2026-09-14, revised after review round 1 (24 findings resolved in place; decisions that
belong to the user are in §10.2; revised 2026-09-15 for the user's §10.2 decisions and the Agent Traffic session's
home back-out constraints), for review before a multi-agent build. Baseline `dev` at `690cbd4`
(`== feat/agent-traffic`). Paths are relative to the repo root; `file:line` anchors were read at that commit.
This document merges three independent designs (generation, integration, traffic contract) and the Agent
Traffic session's 14 required constraints. Where the designs disagreed, §1.3 records what was decided and why.

Owners: **road side** (the road-placement session) builds everything outside `lib/domain/colony/city/traffic/**`.
The **Agent Traffic session** owns that directory and `docs/plans/agent-traffic.md`. §7 is the contract between
the two; this document does not design traffic internals beyond it.

---

## 1. Goal and locked decisions

### 1.1 Goal

Procedurally generate DRIVEWAYS, PARKING LOTS and ACCESS ROADS for every city parcel from the parcel's SHAPE,
drawn in the city tiles and USABLE BY TRAFFIC AGENTS: a car turns in at a kerb cut, circulates, parks
forward-in in a stall and pulls back out (on a home driveway it backs out into the street, §10.2 Q3).

Motivating case: the starter kit's four utility sites have no visible link to their street
(city_starter_kit.dart:187-240). There are four stacked causes. First, no car park is generated: perimeter
fences in the massing block it (building_massing.dart:814-823, :1430-1444, :2032-2046) and `_farm` has none (:984-990), and the only
driveway drawn hangs off a car park. Second, each front line is 60 m from the street centreline. Third, that gap
is NOT bare ground: the starter streets plat 82 auto lots, and a row of zonable 32 m-deep lots stands between each
street and its utility sites (e ±[7, 39]; n 12..276 on both sides of the north piece, n −288..−24 on both sides of
the south piece; verified by a probe of `CityStarterKit.found` at `690cbd4`). Only the last 21 m, e ±[39, 60], is
unowned. Any link from a site to its street therefore crosses a lot (§3.7a). Fourth, lot dressing is gated on the
building centre being within 300 m of the eye (city_nodes.dart:158), and a 900 m site's centre rarely is.

| Site | Parcel | Frontage (road) | Auto-lot row in front |
|---|---|---|---|
| Spaceport | 900 × 900 m, NE | e = 60, n 60..960 (the N–S street ends at n = 300 in a drawn cul-de-sac) | lot-r0x1-l1..l10, e 7..39, n 36..276 |
| Solar farm | 780 × 780 m, SE | e = 60, n −840..−60 (the street ends at n = −300) | lot-r0x0-l0..l10, e 7..39, n −288..−24 |
| Farm | 400 × 400 m, SW | e = −60, n −460..−60 | lot-r0x0-r0..r10, e −39..−7, n −288..−24 |
| Aquifer pump | 260 (e) × 180 (n) m, NW | e = −60, n 60..240 | lot-r0x1-r1..r10, e −39..−7, n 36..276 |

### 1.2 Locked user decisions

1. **Scope: all colonies**, generated towns included. City LAYOUTS and roads stay byte-identical. Lot
   dressing, massing and terrain may change, and tile mesh digests are re-pinned deliberately and recorded in
   the ledger (Appendix A).
2. **Homes get "both".** A residential lot gets its own driveway and parking pad where its shape allows it.
   Narrow or dense lots rely on kerb parking. Kerb parking stays everywhere except across driveways.
3. **Agents drive in and park.** This is built with the Agent Traffic session as its parking slice (their slice
   4). Road side defines the data contract and the road-side changes. Traffic side implements the rest (§7).
4. **Built with a multi-agent workflow** after this design is reviewed (slices in §9).

Design principles that follow from these decisions and the project invariants:

- **The domain is the single source of truth** for the lot line, the building envelope, the paving, the kerb joins
  and the stalls. The renderer draws what the domain publishes and derives no lot geometry of its own. Today
  there are four or five lot lines that disagree (the parcel, the wire footprint, the renderer's inflated
  canonical lot, LotFeatures' lot line, and CityLighting's own massing). Afterwards there are two, both from the
  domain: the parcel polygon and the envelope.
- **The LaneGraph stays roads only.** Site networks are separate, rebuilt on the site revision, never on
  `graphRev`. The only handover is at a join.
- **Plans are derived, never saved.** They are a pure function of the saved layout, the specs and the road
  graph.
- **Access roads are plan segments, not `RoadSpline`s.** A `RoadSpline` into a lot would:
  (1) trip `_hitsRoad` (city_layout.dart:1522-1557), re-plat lots and change the starter graph pin (4 roads,
  5 nodes, 8 edges, traffic_fixture_test.dart:32-34);
  (2) move `roadsRevision` on every placement, rebuilding the lane graph and remapping locked routes;
  (3) be saved, priced, taxed and demolishable, and get a junction warrant (a stop sign at every driveway);
  (4) need stop bars and connectors;
  (5) be state, where a plan is derived.
  (6) A player who wants a public road to a gate draws one, and the plan re-derives onto it.
- **Invariants kept:**
  - Plans never move `roadsRevision` or `layout.revision`.
  - Generated layouts stay byte-identical.
  - Site geometry is at grade only: joins are never on decks, and access corridors never cross another road.
    The one grade-separation rule is untouched.
  - Heights on the wire are measured above the body datum.
  - Hashing is web-safe 32-bit `fnv1a32`, with no 64-bit int literals.
  - Plans are generated on the main isolate only; tile workers receive columns.
  - No `hashCode`, `Random`, clock or map iteration in plan code.
  - Every new source file carries the PolyForm licence header.

### 1.3 Conflicts between the three designs, decided

| # | Question | Decision | Why (one line) |
|---|---|---|---|
| C-1 | Where slot 0 (the lot's access) sits | Frontage < 30 m: 4.5 m in from the lot line at the end away from the nearer junction. Wider: the frontage-midpoint projection clamped into the window. Set-back lots (frontage line > 3.5 m behind the kerb): the corridor search of §3.7a | A mid-frontage drive on a 17–24 m house lot leaves no room for a house, and slot 0 must not depend on use, so the home rule has to be the lot rule |
| C-2 | Node reserve | Junctions: `max(pavement pull-back hw·1.45+5.5, stop bar hw·1.45·0.92, roundabout yield only if the warrant plan is a roundabout)`. Street dead ends: the drawn cul-de-sac radius 11 m + the 1 m flare | Overrides only toggle lights and stops (road_junction.dart:136-147), the pull-back keeps cuts off the pavement corner the tiles draw (city_tile_mesher.dart:1628-1629), and a cut inside the bulb (:1604-1621) disagrees with the drawn kerb |
| C-3 | Several joins | Up to 4 join slots on `RoadGraph`, and a plan SELECTS slots | One window computation and bit-equal V3 checks, and traffic resolves any join without reading the generator |
| C-4 | Taper exclusion | Only the first/last 90 m (`TrafficCapture.taperM`, traffic_capture.dart:53) | A whole-piece ban would empty long tapered avenues for nothing |
| C-5 | Generation seed | Position-free: `fnv1a32` over (program version, frame W and D quantised to 0.5 m, road class, spec type), not `fnv1a32(siteId)` and not coordinates (§3.9). Slot placement uses no seed | The plan must survive `_carryRenamedLots` renames and loads (ask 8), and a coordinate hash flips on the millimetre re-sample of curved roads; the determinism properties are the same. **Needs the traffic session's ack** |
| C-6 | Revision | `rev` = content hash (site id excluded); the book keeps a `sitesRev` counter | Rename-stable by construction, and there is no per-site counter to persist |
| C-7 | Storage | Immutable chunks of 1024 sites with a `SiteAccessPlan` view | About 40 typed lists per plan over 127k buildings is millions of old-space objects, and old space drives the worst frame |
| C-8 | When plans are generated | Only in `CitySim.advance`, and in generate/load drains. The capture only reads | Rendered and headless runs must see plans appear in the same sub-step (determinism digest) |
| C-9 | Per-tick budget | Weighted count units (§4.3) | An installation costs about 150× a home; counts, not time, keep D9 |
| C-10 | Eviction | None | Chunks are small, and eviction breaks identity-keyed caches |
| C-11 | Trig in generation | None: headings are frame unit vectors | Stall keys are saved, and web and native trig differ in the last bits |
| C-12 | Site geometry in `WorldSnapshot` JSON | Serialised, excluded from `fingerprint` | A renderer must build a colony from a frame alone (world_snapshot.dart:1622-1625) |
| C-13 | Capacity target | `parkingSpaces(spec)` (building_massing.dart:289) with program caps | It is what is drawn today, and only the stall count is contractual |
| C-14 | Pin policy | Existing digests stay byte-identical until the legacy-removal slice R7, then one ledgered re-pin | Every slice proves it changed nothing else |
| C-15 | Hash quantisation | Coordinates to 1 cm in `rev` and `inSig` (change detection only, never persisted identity); join `s` to 0.25 m; stall keys from site-frame lattice integers, never coordinates (V10); seed position-free (C-5) | Loads re-sample curved roads by millimetres (parcel.dart:692-700), so nothing saved or tie-breaking may hash a coordinate |
| C-16 | `lotE/lotN` | Stay the centroid. Side comes from `joinRight` | Fewer ripples, since the side is no longer read from them |
| C-17 | Hammerhead | A 6 × 6 m clear apron (installation gates), or a T end whose empty last bays take the reverse (car parks). A home pad has none: its end is a dead end whose stalls are left by backing out to the street (§3.4, V7) | A 3 m arm alone gives no room to reverse, and both forms cost no frontage; a car that reverses out of its home stall never turns on the pad (§10.2 Q3) |
| C-18 | Schedule | Traffic 2 → 4a → 3 → 4b; road side R0–R4 now | §10 Q1 |
| C-19 | Stall index stability (ask 8 says "unchanged by edits that don't touch that aisle") | **Amended:** indices are stable only per plan `rev`. Generation is whole-plan, so a changed capacity target or envelope can move every aisle of that site and renumber its stalls; traffic remaps by `stallKey` (V10, §7.6) | Per-aisle stability would need incremental generation with saved lattice state, which contradicts "plans are derived, never saved". **Needs the traffic session's ack** |
| C-20 | Direction of the lot-access dependency (ask 2 says "RoadGraph's lot access should come FROM the plan's primary join") | **Amended:** the plan's `joins[0]` comes FROM `RoadGraph` slot 0 (slot → plan). One function (`SiteJoinPlacer.primary`) is still the single source | Zoning does not bump `layout.version` (city_layout.dart:1128), so a use-dependent join would go stale inside an unchanged graph. **Needs the traffic session's ack** |
| C-21 | Installations behind a row of auto lots | Access easement over the fewest unbuilt auto lots (§3.7a) | Without it the pump, farm and solar farm are `kPlanAccessBlocked` (the motivating case fails); layouts stay byte-identical. **User decision, §10.2 Q12** |
| C-22 | Where the home back-out's road rules apply (the traffic session asks for a 12 m upstream window margin, a ≥ 4.0 m cut half and road-class limits on `homeDriveway` joins) | At program classification (§3.3): a lot whose slot 0 fails them is demoted from `homeDriveway` to `kerbOnly`. Slots in `RoadGraph.of` stay use-independent and R1 is unchanged | A use-dependent slot would go stale inside an unchanged graph (C-20); the rules read only the slot, its road and its piece's windows, so classification can apply them exactly |

---

## 2. The domain model

### 2.1 Files (new, road side, pure Dart, licence header on each)

```
lib/domain/colony/city/hash32.dart                 fnv1a32 + xorshift32 (copy of traffic_rng.dart:78-98, pinned equal)
lib/domain/colony/city/site_access/
  site_access_constants.dart   every metre/threshold below; traffic READS these, never re-declares them (R-F creates it)
  site_frame.dart              SiteFrame (winding + frontage normalised), effectiveFrontage, interiorPoint, DepthProfile (R-F)
  site_join.dart               nodeReserveM, KerbWindows, SiteJoinPlacer (join slots, §3.2; corridor search, §3.7a)
  site_access_plan.dart        enums, SiteAccessPlan (view), SiteAccessChunk (columns)
  site_plan_builder.dart       PlanBuilder: nodes/segments/stalls, ordering, stall keys, rev; runs the validator
  site_plan_validator.dart     V1-V13 (§2.4)
  site_lane_graph.dart         THE definition of site connectivity (§2.5)
  site_program.dart            classifyProgram, capacity targets (§3.3)
  home_driveway.dart           §3.4
  car_park_packer.dart         carPark + yard (§3.5, §3.6)
  installation_access.dart     access road, gate, forecourt, yard (§3.7)
  site_envelope.dart           SiteEnvelope, entrance, footpaths, lamps; lotSetbackFor/lotCoverageFor/buildingFootprint
                               MOVED here from world_snapshot.dart:1031-1042, 1577-1605 (re-exported there)
  site_grade.dart              SiteGrade: height rule shared by shaper and capture (§6.3)
                               (R5 as built: also SiteCorridorRun — which segments a site's access corridor is, the
                               ramp along it, and the readback of the datums it was cut to)
  kerb_cuts.dart               KerbCut, KerbCuts.blocked/shiftOut: shared by renderer, lighting, traffic kerb masks
                               (R3 as built: the canonical form `canonicalOf`, `toDrawn`, `sigmaOf`; masks in R4)
  site_access_book.dart        SiteAccessBook: slots, chunks, sync, budget, renames, clears (§4)
```

`site_access/` is outside `traffic/` because massing, terrain, lighting and the renderer read it. It follows the
traffic hygiene rules all the same, and a new `site_access_source_hygiene_test` runs the
`traffic_source_hygiene_test.dart:131-157` scan over it.

**Deviation (R2 core, as built):** two files are added. `site_plan_generator.dart` holds the entry point shared by
every generator: `SiteContext` (graph + stamp, parcel, spec, frame, slots, emission helpers), `SiteGeneratedPlan`
(a generator's finished plan, written only once complete, since `PlanBuilder` has no rollback), the dispatcher
`planSite`, `emitKerbOnly`, and the full-town `planSites` / `siteContextsOf` / `planCity`. `site_easement.dart` holds
the pure `easementOf` (§3.7a rule 2), so the installation/easement track owns it apart from the book.

**R2 core repair, as built:** a third file, `site_paving_check.dart`, holds `sitePavingViolations(SiteContext,
SiteAccessPlan) → List<String>`. It covers the two R2 checks the frozen R2a validator leaves open: paving inside
parcel ∪ corridor, and corridor clearance. A1 calls it on every plan. `planSite` / `planSites` / `planCity` take an
optional `SiteGenerators` (the four generator entry points, default `SiteGenerators.standard`) so dispatch tests can
use fakes. Ownership inside R2, so the parallel tracks neither collide nor drop work:

| Owner | Files (lib) | Tests and R2 acceptance items |
|---|---|---|
| core | `site_access_constants.dart` (the only editor), `site_program.dart`, `site_plan_generator.dart`, `home_driveway.dart`, `site_envelope.dart`, `road_graph.dart` `structureStamp` | `home_driveway_test`, `site_plan_generator_test`, `site_plan_dispatch_test`, `site_program_constants_pin_test`, `site_envelope_helpers_test`, `road_graph_structure_stamp_test`, **A1** `site_plan_contract_test` (with `site_random_sites.dart`), `site_plan_property_test`, `site_plan_revision_test`, `site_program_sprawl_audit_test` (the full mix is re-pinned at the R2 merge), `bench/site_generation_bench_test`, the §3.10 report |
| car park / yard | `car_park_packer.dart` (`carParkPlanOf`, `yardPlanOf`) | `car_park_packer_test` (§8.3), with a yard-to-car-park fallback case |
| installation / easement | `installation_access.dart` (`installationPlanOf`), `site_easement.dart` (`easementOf`), `site_paving_check.dart` (`sitePavingViolations`) | `installation_access_test`, `site_easement_test` (the pure half), `site_paving_check_test`; the starter-site acceptance items (56 m throat, yard, gate, ≥ 12 stalls, four easement lots) |
| book | `site_access_book.dart`, the `CitySim` hooks, `CityLayout.easementOf` hook, `setUse`/`placeOnParcel`/growth refusal, inspector string, starter-kit drain, dev hook | `site_access_persistence_test`, `site_access_sync_test`, `site_access_tick_order_test`, `site_easement_test` (the refusal half), `city_starter_kit_test` easement assertion, the road-edit sync bench |

### 2.2 Join slots on `RoadGraph` (beside the lot columns, road_graph.dart:286-295)

```dart
/// Lot i owns slots lotJoinStart[i] .. lotJoinStart[i+1]-1, slot 0 first.
/// lotPiece[i] / lotS[i] / lotDirs[i] are ALWAYS slot 0's (or -1/0/0 when the lot has none).
final Int32List lotJoinStart;            // lotCount + 1
final Int32List joinPiece;
final Float64List joinS;                 // arc on the piece's road from its first control, quantised to 0.25 m
final Uint8List joinDirs;                // == _dirsFor(road, joinRight == 1) (road_graph.dart:685-694, D7)
final Uint8List joinRight;               // 1: lot right of the road polyline (first -> last) at joinS
final Uint16List joinFlags;              // kJoinCut | kJoinLegacy | kJoinSideStreet | kJoinClamped | kJoinOffFrontage
                                         // | kJoinEasement | kJoinCorridorBlocked | kJoinAlley(reserved)
final Float32List joinRoomM;             // largest kerb-cut half width (flare included) legal here; 0 for legacy
final Float64List joinKerbE, joinKerbN;  // kerb point: centreline(joinS) + inward normal × road.halfWidth
final Float64List joinNormE, joinNormN;  // unit road normal at joinS, pointing into the lot
final Int32List joinCrossStart;          // slotCount + 1; CSR into joinCrossLot
final Int32List joinCrossLot;            // graph lot indices of the AUTO lots this slot's access corridor crosses (§3.7a)
final KerbWindows kerbWindows;           // per piece; reads no override, so withOverrides shares it
List<JoinSlot> attachFootprintJoins(List<Vec2> polygon, {Vec2? centroid}); // grid cells; attachFootprint = slot 0
```

Flag meanings (the two clamp cases are distinct; only the second triggers the §3.7 dogleg):

- `kJoinClamped`: `s` moved more than 0.25 m from the placer's target (lots near junctions, installations whose
  midpoint lies past the window).
- `kJoinOffFrontage`: the lot span ∩ window is EMPTY on this road, and `F` was taken from the nearest window point
  (a manual lot lying wholly beside or past a road end).
- `kJoinEasement`: the slot's access corridor crosses ≥ 1 auto lot (`joinCrossLot` non-empty).
- `kJoinCorridorBlocked`: every corridor candidate hit another manual parcel or road (§3.7a); the lot's programs
  reduce to `kerbOnly`.

These columns ride `_copy`, `withOverrides` and `refreshedFor`, so `sharesStructureWith` (road_graph.dart:384)
keeps its meaning. `LotAccess`, `PieceAccess` and `accessOf` (:322-330) keep their signatures and report slot 0.

### 2.3 `SiteAccessPlan` and its chunk

```dart
// Append-only enums: indices are hashed and persisted.
enum SiteProgram     { none, kerbOnly, homeDriveway, carPark, yard, installation }
enum SiteJoinRole    { both, inOnly, outOnly }
enum SiteJoinKind    { kerbside, cut }
enum SiteSegmentKind { driveway, accessRoad, aisle, apron }                   // apron: home pad, truck yard
enum SiteLaneMode    { twoWay, oneWayForward, oneWayBackward, sharedSingle }  // sharedSingle: one lane, alternating
enum StallAngle      { perpendicular, angled60, angled45, parallel, inline }   // v1 emits perpendicular, and inline on home pads
                                                                               // inline: the stall lies ON its pad segment, nose along from→to
enum TurnaroundKind  { none, hammerhead, circle }
enum SiteHeightRef   { pad, kerb, blend }
enum PaveSurface     { asphalt, concrete, gravel }
enum BayKind         { dock, kerbBay }                                         // reserved (ask 9)

/// Immutable packed columns for up to 1024 sites. Every per-site family is CSR: site k owns rows
/// xStart[k] .. xStart[k+1]-1, and indices stored INSIDE a family (node, seg, pt) are plan-local.
/// The LOGICAL columns are listed below. PHYSICALLY a chunk holds five typed lists (f64, f32, i32, u16/u8
/// packed as one Uint8List, and an Int32List family offset table) plus `siteId`, whose strings are the
/// layout's own id instances (no copies): column `x` of type T is `backingT[offset[x] + row]`.
class SiteAccessChunk {
  // site
  final List<String> siteId; final Int32List rev, flags, graphStamp; final Uint8List program; // graphStamp: RoadGraph.structureStamp the joins were resolved against
  final Int32List graphLot;                                                      // the site's RoadGraph lot index at graphStamp; -1 for a site that is not a graph lot
  final Float64List frameE, frameN; final Float32List frameUE, frameUN;          // SiteFrame origin + unit u
  final Float32List envX0, envX1, envY0, envY1, envFrontInset, gateX, gateW;    // frame metres
  // points: every position that carries a height (node, via, pave vertex, lamp, entrance, path)
  final Float64List ptE, ptN; final Uint8List ptHRef, ptHJoin; final Float32List ptHT, ptDz;
  // joins (joins[0] = slot 0)
  final Uint8List joinSlot, joinRight, joinDirs, joinRole, joinKind;            // joinSlot 0, 1, or 2 = side street (unpacked)
  final Int32List joinRef, joinPiece;                                            // join handle (below) and piece, resolved at graphStamp
  final Int32List joinRoadNo, joinRoadIdIdx, joinKerbNode, joinThroatSeg;       // road no. diagnostic; re-resolved per graph
  final Float64List joinRoadS; final Float32List joinCutHalfM;
  // nodes
  final Int32List nodePt; final Uint8List nodeFlags, nodeTurnKind;               // kNodeKerb|Gate|Branch|DeadEnd
  final Float32List nodeTurnR, nodeTurnHx, nodeTurnHn;                           // radius / hammerhead arm + direction
  // segments: polyline = nodePt[from], vias, nodePt[to]
  final Int32List segFrom, segTo, segViaStart;
  final Float64List segLenM;                                                     // Float64: V8 compares to 1e-6
  final Float32List segWidthM, segSpeedMps, segMaxVehLenM;
  final Uint8List segKind, segLaneMode, segFlags;                                 // kSegThroat|CrossesPavement|Truck
  // stalls: ordered by (seg asc, s asc, side asc); index = position
  final Int32List stallSeg, stallKey, stallKeySorted, stallKeyIdx;
  final Float32List stallS, stallDirE, stallDirN, stallLenM, stallWidthM;
  final Float64List stallE, stallN;
  final Uint8List stallSide, stallAngle, stallInDirs, stallOutDirs;              // side 0 right (or on the axis), 1 left; dirs bit0 fwd, bit1 bwd
  // loading bays (reserved; filled for yards/installations)
  final Float64List bayE, bayN; final Float32List bayDirE, bayDirN, bayLenM, bayWidthM, bayS;
  final Int32List baySeg; final Uint8List baySide, bayKind;
  final Float32List truckTurnRadiusM;                                            // per site; 0 unless kPlanAdmitsTrucks
  // paving, dressing, pedestrians
  final Int32List paveStart; final Uint8List paveSurface, paveClass;            // convex CCW rings of pts
  final Int32List lampPt, entrancePt, pavementPt, entranceNode, pathStart;
  final Int32List fenceGapEdge; final Float32List fenceGapT0, fenceGapT1;       // on the REAL parcel polygon
}

/// Cheap view over one site's rows. Allocated only at sync time and in tests, never per frame.
class SiteAccessPlan {
  final SiteAccessChunk chunk; final int site;
  String get siteId; int get rev; SiteProgram get program; int get flags; // kPlanNetwork|AdmitsTrucks|Fallback|AccessBlocked|Public(reserved)
  int get joinCount, nodeCount, segCount, stallCount, bayCount;
  double nodeE(int n); double nodeN(int n); /* ... one accessor per column, plan-local indices ... */
  int get capacity => stallCount;          // ask 10
  bool get hasNetwork;
  int stallIndexOfKey(int key);            // binary search; -1 when gone
}
```

**Join handles (`joinRef`).** Every plan join names its graph join with one Int32 that the book resolves once, at sync,
against the graph it stamps into `graphStamp`. The encoding (constants and helpers in `site_access_constants.dart` and
on `RoadGraph`):

| `joinRef` | Meaning | Graph read (sync only) |
|---|---|---|
| `≥ 0` | packed join index: slot 0 or slot 1, `lotJoinStart[graphLot] + position` | the `join*` columns at that index |
| `−1` (`kJoinRefNone`) | no graph join: a footprint site's own join (`attachFootprintJoins`) or a kerbside plan with no slot | none; the plan's copied columns are the only source |
| `≤ −2` | the corner lot's side-street slot 2: `kJoinRefSideStreetBase − lot` with `kJoinRefSideStreetBase = −2`, so `lot = −2 − joinRef` | `RoadGraph.sideStreetJoinOf(lot)` |

- `RoadGraph.joinRefOf(int lot, int slot)` returns the handle, or −1 when the lot has no such slot.
  `RoadGraph.joinOfRef(int ref)` returns a `JoinSlot`, or null for −1. Both run at sync and in tests only.
- **Stable while `sharesStructureWith` holds.** Copies made by `withOverrides` and `refreshedFor` share `lotJoinStart`,
  the join columns and the side-street cache. `graphLot`, every `joinRef` and the values behind them are therefore
  identical across such rebuilds, and `(graphLot, joinSlot) ↔ joinRef` is a bijection for the plan's joins.
- **Across a structure change.** Handles are never carried over. `graphStamp` changes, `isCurrentFor` turns false and
  the book re-resolves on its next check (§4.2). Nothing persisted stores a `joinRef`: saves key on `siteId + stallKey`
  (§7.5).
- **No lookup per sub-step.** Every value a car needs is copied into the plan's columns at sync: `joinPiece`,
  `joinRoadS`, `joinDirs`, `joinRight`, `joinCutHalfM`, and the kerb point via `joinKerbNode`. That includes slot 2.
  Traffic reads the columns, and uses `joinRef` only as the join's identity (with `(edge, T)`, V4) and for diagnostics.
  V3 checks that the copies equal `joinOfRef(joinRef)` bit for bit.

Kerbside plans carry exactly one join (slot 0, `kerbside`) and no nodes, segments or stalls. They are stored
as a single site row with empty ranges, so a kerb-only town costs almost nothing. A chunk retains ≤ 7 objects
(itself, five typed lists, the `siteId` list) and its `SiteChunkGeometry` (§5.2) ≤ 3 (itself, one Float32List, one
Int32List), so the heap cost is ≤ 10 objects per 1024 sites, i.e. ≤ 1 retained object per 100 sites (§3.10, §8.4).

**Immutable after publish.** A published chunk is never mutated. A changed site publishes a NEW chunk object
(copy-on-write, §4.1) and the book swaps its reference; the old chunk stays valid for as long as anything references
it. Limbo plans (§7.6) and cars mid-manoeuvre hold the old chunk and keep reading it unchanged.

**Deviations (R2a, as built):**
- Three index columns are added: `viaPt`, `pavePt`, `pathPt`. `segViaStart`, `paveStart` and `pathStart` are CSR into
  them (plan-local), and they hold plan-local point indices. Without them vias, rings and paths would need contiguous
  point runs. A CSR column inside a plan has count + 1 rows per site, so its rows for site k start at its count
  family's start + k. The chunk has 104 logical columns (`SiteCol`). No logical column is u16, so the u8 backing is
  plain bytes. Column accessors live on the chunk (chunk-global rows) and on the plan (plan-local indices).
- `joinRoadIdIdx` is reserved and written −1: a road-id string table would break the 7-object bound.
- `RoadGraph` has no `structureStamp` yet. `PlanBuilder` stores the caller's int, and R2's book supplies the stamp.
  **R2 core:** `RoadGraph.structureStamp` exists: a signed 32-bit word hash (web-safe `mul32`) over the roads (id,
  class, decoration, direction, samples), nodes, pieces, edges, lots, join and crossed-lot columns and kerb windows,
  hashed on first read into a cell every `withOverrides` / `refreshedFor` copy shares. Copies that
  `sharesStructureWith` stamp equal; a structure change stamps differently (up to a 32-bit collision). A rebuild of
  an unchanged layout stamps the SAME (every lot index and join handle it gives is the same), so `isCurrentFor`
  stays true across it. Doubles are hashed by their bits, so a stamp is per platform, like `rev`.
- `rev` hashes each site's family counts instead of the chunk-global starts. It excludes the graph resolution
  (`graphStamp`, `graphLot`, `joinRef`, `joinPiece`, `joinRoadNo`, `joinRoadIdIdx`), so re-resolving a plan against a
  new graph keeps its `rev`. `rev` and `stallKey` are stored signed (`toSigned(32)`), and `stallIndexOfKey` accepts
  either sign.
- `PlanBuilder` computes what no generator may get wrong: `segLenM`, stall order `(seg, s, side)` and stall keys.
  The heading octant has sectors centred on multiples of 45° from `u`, picked by comparison with tan 22.5°.
- **R2a-frozen file touched (R2 integration repair, notice line sent):** `SiteAccessChunk.adopt(...)` is added
  beside `SiteAccessChunk.packed`, with the same arguments. It TAKES the typed lists rather than copying them, so the
  book can re-publish a re-resolved chunk that shares its unchanged `f64` / `f32` / `u8` / offset lists with the
  chunk it replaces, and a whole re-pack need not copy its fresh lists twice (§4.1 as built: the copies and their GC
  were most of the road-edit tick). Like `packed`, it is not for traffic. Nothing a reader sees changes: both
  chunks are published and never written, and the bytes are identical (`site_access_sync_test`). No existing member
  changed.

### 2.4 Invariants (the validator; `assert` in the builder, always in tests)

- **V1 Window.** For each `cut` join, `joinRoadS ± joinCutHalfM` lies inside the slot window (§3.2). On EVERY
  lane graph built from that `RoadGraph` under ANY junction override, that is inside
  `[edgeLaneS0[e]+6, edgeLaneS1[e]−6]` for every serving edge. It also stays off bridges, off off-ground or
  off-grade deck stretches and tunnels, off tapers (90 m), and off limited-access, ramp, rail and car-less
  classes. `AccessPoint.sOn`'s clamp (access_points.dart:76-80) never fires for a cut join.
  A `homeDriveway` cut join also keeps its **swing margin**: for each direction in `joinDirs`, the 12 m of that
  direction's travel upstream of `T` lies inside `[edgeLaneS0[e], edgeLaneS1[e]]` under any override, so a back-out's
  tail swing never enters a junction box or crosses a stop bar (§3.3 applies it at classification; the slot itself
  stays use-independent, C-22).
- **V2 Side and directions.** `joinDirs == _dirsFor(road, joinRight)`. The side comes from geometry (§3.2),
  never from the `r`/`l` in a lot id.
- **V3 One source.** `joins[0]` is slot 0. Every join's `(piece, s, right, dirs, kerb point)` equals its slot's
  columns bit for bit in the graph the plan was synced against. For the side-street slot that is
  `joinOfRef(joinRef)`, and `joinRef == joinRefOf(graphLot, joinSlot)`.
- **V4 Roles.** A network plan has ≥ 1 in-capable and ≥ 1 out-capable cut join. Cuts on one edge do not
  overlap and are ≥ 6 m apart, so `(edge, T)` identifies a join.
- **V5 Throat (ask 3).** Each cut join's throat is the segment leaving its kerb node:
  - it is straight (every via point within 0.1 m of the kerb-node → far-node chord), ≥ 7 m long, within 10° of
    the road normal, and carries no stall or bay;
  - its via points are ≤ 24 m apart (V8), so a 56 m access-road throat carries vias;
  - its far node is ANY node: a branch, a bend, a gate, a frontage node or a turnaround;
  - no stall mouth, bay mouth or branch node lies within 7 m of the kerb node measured along the site path;
  - it is ≥ 3.0 m wide, and ≥ 5.5 m wide for `twoWay`;
  - it carries `kSegThroat`, plus `kSegCrossesPavement` when a pavement lies within its first 3 m;
  - **`homeDriveway` joins** (cars back out through it, §7.4): `joinCutHalfM ≥ kHomeCutHalfM = 4.0` for the tail
    swing; the pad segment continues the throat's axis (its end node within 0.1 m of the throat's chord extended), so
    the drive from the deepest stall to the kerb is one straight run within 10° of the road normal; the first 7 m
    from the kerb carries no stall (the rule above).
- **V6 Nodes (ask 4).** Segments reference node indices, and polyline ends ARE the node points. No two nodes
  lie within 0.5 m. No segment is shorter than 1 m. `nodeCount ≤ 4096`.
- **V7 Connected (ask 5).** Under §2.5 the present site lanes form ONE strongly connected component. It holds
  every cut join's in-lane and out-lane and every stall's entry and exit lanes, which is stronger than the ask:
  every stall reaches EVERY out-join. Every degree-1 non-kerb node is a turnaround. It is either a `circle` of
  radius ≥ 6 m (≥ 12.5 m for trucks), or a `hammerhead` that is one of:
  - (a) a clear paved rectangle ≥ 6 × 6 m adjoining the node (an installation gate apron);
  - (b) a T end: the last ≥ 3 m of a ≥ 6 m aisle is stall-free on both rows, with ≥ 5.2 m of paved row depth on at
    least one side to reverse into.

  **The one exception is a home pad end** (`P`, §3.4): the `to` node of an `apron` segment whose stalls are all
  `inline` with `stallInDirs = {fwd}` and `stallOutDirs = {bwd}`. It has `nodeTurnKind = none` and `kNodeDeadEnd`;
  its stalls link the pad's forward lane to its backward lane (§2.5), which keeps the component strongly connected.
  No car turns there: it reverses out of its stall to the street.

  One-way segments occur only inside cycles.
- **V8 Segments (ask 6).**
  - Width is in [3, 12] m and speed in (0, 20 km/h].
  - Defaults: 10 km/h for aisles and driveways, 20 km/h for access roads.
  - `twoWay` needs ≥ 5.5 m, or ≥ 6.0 m with perpendicular stalls. Angled stalls need a one-way segment of
    ≥ 3.5 m. `sharedSingle` is < 5.5 m.
  - `segMaxVehLenM` ≥ 5.5.
  - `segLenM` (Float64) equals the 2-D polyline length to 1e-6.
  - Via points are at most 24 m apart.
- **V9 Stalls (ask 7).**
  - `stallDir` is the nose parked forward-in: dot(dir, mouth→centre) ≥ 0.9.
  - The mouth lies on its segment: `0 ≤ stallS ≤ segLenM`.
  - `stallInDirs` names present lanes of `stallSeg` from which entry is a forward turn. Perpendicular on
    `twoWay` (≥ 6 m) MAY allow both directions; one-way and angled allow the segment's direction only. A direction
    bit is set only when the car has run-up for the turn (`kStallRunupM = 5.0`, half stall width 1.3):
    - the forward bit only if `stallS − 1.3 ≥ 5.0` from the segment's from-node;
    - the backward bit only if `segLenM − stallS − 1.3 ≥ 5.0`.
  - **Home stalls are `inline`** (§3.4): they lie on their pad segment, nose along its from→to direction, and are
    entered forward, straight up the drive: `stallInDirs = {fwd}` exactly. The run-up rule does not apply (the car
    arrives aligned along the ≥ 7 m straight throat on the same axis).
  - Every stall has at least one `stallInDirs` bit; a stall that would have none is not emitted.
  - Perpendicular and angled stalls are left by reversing. `stallOutDirs` names the lanes a car may take after
    reversing out.
  - **Home stalls are left by reversing out to the street:** `stallOutDirs = {bwd}` exactly, naming the pad's and
    then the throat's to→from lane, which the car runs in reverse to the kerb before it backs out onto the road
    (§7.4 Home back-out). Stall order along the pad is from the street outward (V10 already orders by `s`).
  - Rectangles do not overlap each other, any carriageway (except the mouth edge), the throat or the envelope. An
    `inline` stall lies on its own pad segment, which this rule exempts; inline stalls may share an edge with each
    other and with the throat's far end, never overlap.
  - `stallCount ≤ 1024`.
- **V10 Order and keys (ask 8).** Stalls are strictly ordered by `(seg, s, side)`. Segment order is: throats in
  join order, then aisles by the `(y, x)` of their start in the frame, then access-road pieces in path order, then
  aprons (home pads, truck yards) in path order.
  - `stallKey` is an `fnv1aU32` chain over generator-lattice INTEGERS in the site frame, never world
    coordinates: `(segment kind ordinal, module or row index, bay index along the row, side, heading octant
    relative to the frame's u)`. A millimetre shift of the frame (a curved-road re-sample) cannot change a key.
  - On a collision the colliding stalls are ranked by their lattice tuple's own order `(segment kind ordinal,
    module or row index, bay index, side, heading octant)`, never by stall index or segment order: the first keeps
    the key and each later one takes `key+1`, repeated until unique. A regeneration that only reorders segments
    cannot swap two stalls' keys.
  - Keys are stable while the generator picks the same lattice (same family, module count and row start),
    whatever the frame's world position. Indices are stable per `rev` only (C-19).
- **V11 Entrance (ask 10).** A plan has exactly one entrance (the door) and one `pavementPt`.
  - Network plans: `entranceNode` is valid and within 60 m.
  - Kerbside plans: `entranceNode = −1` and `pavementPt` is the pavement point at slot 0.
- **V12 Revision.** `rev = fnv1a32` over the canonical bytes: every column in order, coordinates at 1 cm,
  unit vectors ×1000, site id excluded. `rev` is never 0 (0 maps to 1). The same inputs give the same `rev` on
  any isolate of one platform.
- **V13 Reserved fields (ask 9).** Bay columns always exist. `kPlanAdmitsTrucks` is set only if some
  in→bay→out path has width ≥ 3.5 m, turnarounds ≥ 12.5 m and `segMaxVehLenM` ≥ 12. Adding truck data later
  appends and changes no existing field.
- **Geometry invariants (road side).**
  - Everything paved lies inside `parcel ∪ access corridor`.
  - The envelope ∩ paving = ∅.
  - Every coordinate is finite.
  - Access corridors are clear of other manual parcels, of built auto lots, and of every other at-grade road's
    carriageway and pavement; the unbuilt auto lots they cross are easements (§3.7a).

**Deviations (R2a, as built, `site_plan_validator.dart`):** each rule belongs to exactly one V, so one defect is
reported under one name.
- V1 reads `kerbWindows`, which hold for every override. Given lane graphs' spans (`SiteLaneSpans`, a record, so
  `site_access/` imports no traffic), it also checks `[edgeLaneS0 + 6, edgeLaneS1 − 6]` and the home swing margin
  `t − 12 ≥ edgeLaneS0`. The window form of the swing margin is `[s − 6, s + m]` forward and `[s − m, s + 6]` backward.
- V4 also requires `kPlanNetwork` ⇔ segments ⇔ a program other than `none`/`kerbOnly`, and cut joins only on a network
  plan. Cuts on one piece need a 6 m gap between their EDGES: `|Δs| − m₁ − m₂ ≥ 6`.
- V5 owns a throat's via spacing, and V8 owns every other segment's and all widths. V7 owns circles ≥ 6 m. V13 owns
  the ≥ 12.5 m truck circle, which may be a pass-through node (the installation yard `Y`). V9 owns stall direction
  bits: V7's home-pad exception asks only for ≥ 1 stall, all `inline`, and only in a `homeDriveway` plan. The home
  pad's straight run checks every via point of the pad, not only its end node.
- V7's strong connectivity counts `SiteLaneGraph`'s road links (§2.5). A kerb node has site degree 1, so without them
  no site is strongly connected. A role-only break (no out-capable join) therefore also fails V7. Because a road link
  is no site path, V7 also walks the site links alone (road links excluded): from every in-capable join's in-lane,
  every stall entry lane (per `stallInDirs`) and every out-capable join's out-lane are reachable; from every stall exit
  lane (per `stallOutDirs`, the pad's backward lane for `inline`), every out-capable join's out-lane is reachable. So
  two halves joined only by the road fail V7. A node of site degree 0 fails V7.
- V9: a perpendicular or angled stall's nose is tested against the vector from the centreline point at `stallS`
  to its centre. An inline or parallel stall's nose is tested against the tangent there. An inline stall "lies on
  its pad" when its centre is within half the pad width of the centreline. A stall is tested for overlap against
  every segment except its own. On its own segment only the mouth edge is exempt: a non-`inline` stall's mouth-edge
  midpoint (`centre − dir·len/2`) lies ≥ `width/2 − 0.01` m from that segment's centreline at `stallS`, so an angled
  stall's corner wedge may cross the carriageway rectangle but no stall sits in its aisle. A perpendicular stall
  that takes BOTH in-dirs needs a `twoWay` segment ≥ 6 m, so a narrower `sharedSingle` aisle cannot slip past V8's
  two-way width rule.
- V5: `kSegCrossesPavement` is checked both ways against the join road's class: a throat off a road with a pavement
  must carry it, and a throat off a road without one must not.
- V11 owns `entrancePt` and `pavementPt` (a real point each) and `entranceNode` in range; V6's index check does not.
- V13 walks `SiteLaneGraph` lanes of truck segments (width ≥ 3.5 m, `segMaxVehLenM` ≥ 12): movements as §2.5 allows,
  U-turns only at a `circle` of radius ≥ 12.5 m, no inline-stall or road links. Some bay on a truck segment `k` needs
  a lane `L` of `k` reachable from an in-capable join's in-lane, from which an out-capable join's out-lane is reachable;
  or, when an end node of `k` is a ≥ 12.5 m circle, the truck may reverse out of the bay into it and leave by `L`
  reversed (the §3.7 bays sit on the circle's far edge).
- V10's segment ranks are: throats in join order, then aisles by `(y, x)`, then access-road and non-throat driveway
  pieces, then aprons. "Path order" inside a rank is not checkable and is not checked.
- V11: a kerbside plan's `pavementPt` lies within 3.5 m of slot 0's kerb point. A footprint kerbside plan
  (`joinRef == −1`) has no graph kerb point and no kerb node, so its pavement point is not distance-checked in R2a;
  R2's footprint generator places it from `attachFootprintJoins` and its test pins the distance.
- Not checked in R2a (they need the parcel and the corridor, R2): paving inside `parcel ∪ corridor`, and corridor
  clearance. Checked as `geometry`: finite numbers (fence-gap `t0/t1` included), convex CCW pave rings, and
  paving ∩ envelope = ∅.
- **R2 (`site_paving_check.dart`, `sitePavingViolations`):** the corridor of every cut join is its §3.7a polyline
  (kerb → frontage along the slot normal, or R1's dogleg), ±4.5 m, no end caps, its last leg run on past the frontage
  line until its whole width is inside the lot (`h·|d·u|/(d·v)`), so a drive off a skewed kerb is never read as
  outside. A kerb ON (or behind) the frontage line has no leg of its own, so it gets that run-on alone, from the kerb
  along the slot normal (repair: at `k = 0` on a lot skewed ≥ 12° the throat's kerb corners read as outside; pinned by
  `site_paving_check_test`). Past the frontage line (frame `y > 0`) every corridor leg, the run-on included, counts only
  between the lot's side lines `0 ≤ x ≤ W` (repair: at 60° skew the run-on reached ~7.8 m past the frontage line and
  read pave across a side line near the frontage corner as inside the corridor; pinned at `k = 0` and `k = 6`). Pave rings are sampled (vertices, edges every 0.25 m, inside every 1 m; 5 cm tolerance). Clearance: no used
  slot is `kJoinCorridorBlocked`, no crossed lot is built, and, only for a set-back corridor (longer than 3.5 m) or a
  dogleg — the corridors R1 searched — no other at-grade road's carriageway + pavement (the join road's beyond 12 m of
  arc) comes within it (a plat lot's 3 m kerb crossing beside another street's dead end is the plat's; the small
  generated town has one). Other manual parcels are not re-tested: `RoadGraph` exposes no lot polygons, so that stays
  R1's placement guarantee and the book's placement refusal (§3.7a rule 5). The other road's pavement width is the
  layout default 3 m (`RoadGraph`'s own `sidewalkM` is private).

### 2.5 Site lanes: the one definition of connectivity (`site_lane_graph.dart`)

- Segment `k` gives lane `2k` (from→to) and `2k+1` (to→from), present per `segLaneMode`. `twoWay` lane centres sit
  at ±width/4, right of travel. The others sit on the centreline.
- A movement at node `n` from arriving lane `a` to leaving lane `b` is allowed when they belong to different
  segments and the deflection is ≤ 150°, or when `n` is a turnaround and `b` is `a` reversed.
- An `inline` stall (home pads, V9) links its entry lane (the pad's forward lane) to its exit lane (the pad's backward
  lane, run in reverse). That link is what connects a home pad's dead end `P` (V7); no movement exists at `P`.
- A kerb node has site degree 1. Its road side is reached only through access events (§7.4).
- `SiteLaneGraph.of(plan)` returns CSR adjacency, `present[]`, `strongComponent[]`, `inLane(join)` and
  `outLane(join)`. It allocates and runs only at build and sync. If traffic copies the rule, a test pins the
  copy equal on the fixtures.
- **As built (R2a):** links carry a kind: movement, U-turn, inline stall (homes only) and ROAD. A road link runs from
  every out-capable cut join's out-lane to every in-capable one's in-lane. It stands for the road between EXIT and
  ENTER, so strong connectivity means something for a site. It is never a site path: V7 also checks reachability over
  the site links alone (§2.4 deviations), and traffic routes only over non-road links.

---

## 3. Generation rules

### 3.1 The site frame

Every generator works in one right-handed frame per site: **x along the frontage, y into the lot**.

```
SiteFrame.of(polygon, frontageOrNull, roadHint):
  P = polygon; if signedArea(P) < 0: P = reversed(P)       // never trust winding: `_subdivide` makes the
                                                           // `l`-side auto lots CW (city_layout.dart:1270-1289),
                                                           // and the starter pad/solar frontages run backwards
  (a, b) = frontage ?? effectiveFrontage(P, roadHint)
  |b - a| < 1e-6  -> degenerate (program none)
  u = (b - a).normalized; v = u.perp
  c = interiorPoint(P)
  if (c - a)·v < 0: swap(a, b); u = -u; v = u.perp          // v points INTO the lot (perp = CCW)
  origin = a; W = |b - a|
  streetHeading   = heading of -v in the Parcel.heading convention   // == Parcel.heading when Parcel.facing == -v
  buildingHeading = streetHeading + π                               // spin -buildingHeading: local +Y -> v, +X -> u
```

**The building-heading rule (one rule, used by §5.1, §5.2, §6.1 and §10.2 Q10):**

- A **plan-served** site (`BuildingSnapshot.siteSlot ≥ 0`, i.e. any stored plan, `kerbOnly` included) spins its
  building by `−SiteFrame.buildingHeading`. The envelope, the gate and the door are computed in the same frame,
  so they share the building's local axes by construction: local +X = `u`, local +Y = `v`, local −Y faces the
  street.
- A **legacy** site (`siteSlot < 0`: no plan yet, program `none`, hand-built snapshots) spins by
  `−(Parcel.heading + π)`: Parcel-based, with only R0's π fix.
- The two agree wherever `Parcel.facing == −v`: auto lots and manual lots whose stored frontage is used. They differ
  only where `effectiveFrontage` replaces a missing or fake frontage (frontage-less manual lots such as
  player-claimed sites and generator installations at city_generator.dart:2239, and grid cells). There the
  plan-served building TURNS to face its access road. That turn arrives with R4, behind the `CityNodes.siteAccess`
  knob, and it is visible on saved and generated sites (§10.2 Q10).

- **`effectiveFrontage`** is used for manual lots without a frontage, grid cells (their stored north edge is fake,
  city_sim.dart:4426-4445), and a stored frontage whose midpoint is more than 1 m off the polygon. Over the
  polygon edges of at least 6 m, it finds the nearest point `R` of an eligible road (§3.2) within
  `manualReachM + hw` (road_graph.dart:206), requiring `R` to lie outside the edge. The score is
  `dist − 15·|t_edge·t_road|`, and the lowest wins. Ties go to the smaller edge index, counted from the vertex
  with the smallest `(e, n)`. If no eligible road is in reach, the longest edge is used and the program is
  `none` (no plan is stored, so the building stays legacy and keeps `Parcel.facing`).
- **`interiorPoint`** is the vertex average if the polygon contains it. Otherwise it is the midpoint of the
  longest horizontal chord through that average, which handles concave L and U lots.
- **Deviation (R-F, as built): `v` is oriented by the edge, not by `interiorPoint`.** On a concave lot the interior
  point can lie across the frontage line (an L lot fronting its notch floor) or exactly on it, which flips `v`
  out of the lot or makes the two frontage orders disagree. `SiteFrame.of` instead takes the canonical CCW edge of
  `P` nearest the frontage midpoint (ties to the smaller index, zero-length edges skipped) and swaps `a`/`b` when
  `v·edge.perp < 0`. `interiorPoint` is only the fallback when `|v·edge.perp| < 1e-9` (that edge perpendicular to
  the frontage).
- **`DepthProfile`** has one column every 0.5 m across `P` in the frame. Each column keeps the single inside
  interval nearest the frontage, less a 0.3 m margin. A column whose kept interval starts more than 1 m (the
  stored-frontage tolerance) past the frontage line reads depth 0: it cannot be reached from the frontage (the
  notch of an open U). Search uses the profile. Every emitted rectangle must also
  pass the exact `containsRect` test: all corners inside and no edge crossing (Liang-Barsky). A rectangle that
  fails is dropped, never nudged. Cost: `W/0.5 × edges`, about 200 tests for a 24 m lot and 7,200 for the
  spaceport.
- `_clipToParcel` (building_massing.dart:315-320) and `CityLighting` (city_lighting.dart:152-160) switch to
  `SiteFrame`. `buildableExtent` and `inscribedExtent` do not depend on winding and stay as they are (a pin test
  confirms their results are unchanged).

### 3.2 Kerb joins (tier L, inside `RoadGraph.of`)

**Eligible roads:** `carriesCars && !limitedAccess && !isElevated && (platsLots || alley)`. So street, avenue,
urban highway, path, one-way street, boulevard and alley are eligible. Ramp, motorway, trunk, expressway, rail and
transit are not (parcel.dart:203-228).

**Node reserve** is independent of every override:

```
nodeReserveM(node):
  if node.legs.length <= 1:                              // dead end, stub, dangling deck
    if the leg's class is RoadClass.street:              // the tiles draw a cul-de-sac bulb at ANY street end
      return kCulDeSacRadiusM + kCutFlareM               //   nothing else meets (city_tile_mesher.dart:1604-1621): 11 + 1
    return 0
  hw = max over ALL legs of leg.roadClass.halfWidth      // >= junctionHalfWidthOf (node_control.dart:154)
  r  = max(hw * 1.45 * 0.92,                             // stop bar: signals / stop / all-way (node_control.dart:127-149)
           hw * 1.45 + 5.5)                              // pavement corner pull-back (city_tile_mesher.dart:1628-1629)
  if node.plan.control == roundabout (the WARRANT's plan, before overrides):
     r = max(r, max(14, 2*hw + 6) * 0.96)
  return r
```

The constants are re-declared in `site_access_constants.dart` and pinned against node_control.dart, and
`kCulDeSacRadiusM = 11.0` is pinned against the literal at city_tile_mesher.dart:1615/1618 (a test reads both). The
bulb reserve is applied whether or not the end is drawn (tunnel and structure ends skip the bulb): conservative
and override-free. The lane graph's back-off between close junctions (lane_graph_builder.dart:405-418) only shrinks
`stopBack`, so the bound survives it. For a street crossing with hw = 4 the reserve is 11.3 m; a street dead end
reserves 12.0 m.

**Window per piece** `p` of road `r`, arcs `[S0, S1]`:

```
W(p) = [S0 + reserve(from) + 6, S1 - reserve(to) - 6]
       minus road.bridges (± 3), deck stretches off ground or |offset| >= 0.5 and tunnels
       (range arc -> road arc: s = r·lengthM/rangeLengthM, parcel.dart:705-711), and the first/last 90 m of a
       road with startHalfWidthM/endHalfWidthM (a taper, D44)
```

A join of cut half-width `m` needs `[s−m, s+m] ⊆ W`. Both directed edges of a piece share the node reserves, so one
road-arc window serves both. Windows are stored as CSR per piece.

**Candidate roads, in order:**

1. An auto lot's `roadId`, then its `sideStreet`'s road.
2. A manual lot: the road of its (effective) frontage, then any other eligible road within `manualReachM` of
   another edge, nearest first, ties by road number. This replaces `_nearestRoadTo` (road_graph.dart:700-744) for
   lots, since that could pick a road touching a corner but facing no edge.
3. A grid cell: as a manual lot, over its effective frontage.

**Frontage span.** Project the frame's `a` and `b` onto the road to get `[sLo, sHi]`. The lot span is
`[sLo + m + cc, sHi − m − cc]`, with `cc` (corner clear) 0.5 m, or 5 m when `W ≥ 150 m`. The candidate spans are
the lot span intersected with the windows. When that is EMPTY on this road but the frontage lies beside the road's
end (a manual lot wholly past a dead end), `F` becomes the nearest window point, flagged `kJoinOffFrontage`, and
the plan bridges the gap with a dogleg access road of at most 120 m (§3.7). The starter sites are NOT this case:
their spans overlap the windows, and they are only `kJoinClamped`.

**Slot 0: `SiteJoinPlacer.primary`.** It does not depend on use. The home back-out's extra requirements (a 4.0 m
cut half, the 12 m swing margin, the road rules) are NOT applied here: §3.3 checks them when it classifies a lot as a
home, and demotes a lot that fails to `kerbOnly` (C-22).

| Frontage W | Preferred cut half `m` (incl. 1 m flare) | Target |
|---|---|---|
| < 30 m (narrow) | 4.0 | the point 4.5 m in from the lot line at the end AWAY from the nearer node of its piece (a tie within 2 m goes to the larger-`s` end: no hash, because slot 0 must not depend on use and a coordinate hash flips on a curved-road re-sample) |
| ≥ 30 m (wide) | 4.5 | the frontage-midpoint projection (today's `_nearestOnRoad` arithmetic) |

- `s` is the nearest span point to the target, flagged `kJoinClamped` if it moved more than 0.25 m.
- **Set-back lots.** When the frontage line at the target lies more than `max(sidewalkM + 0.5, 3.0)` = 3.5 m behind
  the kerb (manual lots and cells set back from their road), the placer runs the §3.7a corridor search, which may
  move `s` and fills `joinCrossStart/joinCrossLot`. This is geometry only (other parcels' polygons and roads), so
  slot 0 still does not depend on use.
- For a narrow lot pushed off its drive end, the placer tries the target from the other end first.
- `s` is quantised to 0.25 m and re-clamped.
- If no span fits `m`, the placer retries at `kJoinMinRoomM = 2.5`, which leaves room for a single-lane throat
  only.
- `joinRoomM` is the largest `m` legal at `s`.
- `joinRight` is the side of the lot's `interiorPoint` against the road tangent at `s`.
- `joinDirs = _dirsFor(road, joinRight)`.
- If no candidate road yields a span, the lot gets one **legacy slot**: today's exact point and dirs,
  `room = 0`, `kJoinLegacy`. The `lotPiece < 0` count and reachability then equal today's
  (`main_city_game_dev.dart:451`).

**Slots 1–3** are offered by the graph and used only if a plan picks them.

- Slot 1 is a second own-road slot at the far end of the span, when `W ≥ 60 m` and `|Δs| ≥ 30 m`.
- Slot 2 is the side-street slot of a corner lot, unless that is slot 0.
- Slot 3 is the REAR ALLEY join (R8, machinery landed): the one a downtown lot's bins, loading and back-of-house
  parking come off, so its street frontage stays an unbroken run of shopfronts. **Slot 0 stays the frontage and
  stays kerbside** — the alley is a second offer, never a move, so a stale or absent plan degrades to kerbside
  frontage and not to a driveway that no longer exists. Flagged `kJoinCut | kJoinAlley`; offered ON REQUEST like
  slot 2 (`RoadGraph.rearAlleyJoinOf`), handled by `kJoinRefAlleyBase − lot`.
  **The rear edge** (a `Parcel` stores a frontage and a side street, nothing rear) is read off the polygon: of the
  edges at least 6 m long whose outward normal lies within 45° of the frontage's inward normal (which rules out both
  side lines at 90° and the frontage at 180°), the DEEPEST from the frontage line, ties to the lower edge index. On
  the quad the plat cuts that is the back edge exactly. **Its alley** is the nearest `alley` whose carriageway edge
  (an alley has no pavement, §3.8) lies within 12 m of that edge — `_otherRoads` asked of the rear edge alone over
  that reach, not of the whole polygon, because a lot's side line ends ON its rear edge and would tie with it.
  12 m is a fraction of the shallowest block a generated town cuts (`blockDepthM` 104), so the alley found is the
  one behind THIS lot. On the 12-mile sprawl audit town (18 alley roads) 152 of 54,257 lots have a candidate.
- Ties go to the smaller road number, then the smaller `s`.

**Worked example: the starter kit.** The crossing node has a reserve of 11.3 m. Both street dead ends (n = ±300)
draw a cul-de-sac and reserve 12.0 m, so the north window is `[0 + 11.3 + 6, 300 − 12 − 6] = [17.3, 282]` and, at
m = 4.5, slot centres lie in `[21.8, 277.5]` (south mirrored). The installation cut half is 4.5 m, the corner clear
5 m, and the access corridor ±4.5 m (a 7 m road + 1 m each side). All four sites are set-back lots (the frontage
line is 56 m behind the kerb), so §3.7a runs; the auto lots are the probe's (§1.1).

| Site | Piece | Slot window at m = 4.5 (n) | Lot span (n) | Target | Corridor at the target crosses | **Slot 0** | Flags | Easement lot |
|---|---|---|---|---|---|---|---|---|
| Spaceport | north | [21.8, 277.5] | [69.5, 950.5] | mid 510 → clamped 277.5 | lot-r0x1-l10 (by 3 m) | **n = 264**, east kerb, both dirs | Clamped, Easement | lot-r0x1-l10 (n 252..276) |
| Solar farm | south | [−277.5, −21.8] | [−830.5, −69.5] | mid −450 → clamped −277.5 | lot-r0x0-l0 | **n = −276**, east kerb | Clamped, Easement | lot-r0x0-l0 (n −288..−264) |
| Farm | south | [−277.5, −21.8] | [−450.5, −69.5] | mid −260 | lot-r0x0-r1 and lot-r0x0-r0 (by 0.5 m) | **n = −252**, west kerb | Clamped, Easement | lot-r0x0-r1 (n −264..−240) |
| Aquifer pump | north | [21.8, 277.5] | [69.5, 230.5] | mid 150 | lot-r0x1-r5 | **n = 144**, west kerb | Clamped, Easement | lot-r0x1-r5 (n 132..156) |

Each site then gets a 56 m access road from the kerb (e = ±4) to its frontage line (e = ±60): 3 m of pavement,
32 m across its easement lot and 21 m of unowned ground. No site is `kJoinOffFrontage`, so none doglegs. Every cut
(`s ± 4.5`) lies inside its road window and clear of the n = ±300 bulbs.

**Deviations (R1, as built):**
- The set-back test (and so the corridor search) runs only for lots the plat did not cut (manual lots and footprints).
  An auto lot's frontage is its pavement line by construction; on a bend its chord reads up to ~1.7 m further back
  and would send every lot on a curve to the search.
- A lot with no access point today (`lotPiece < 0`) gets no slot at all, so the count is unchanged by construction.
  For a manual lot, today's point (`_nearestRoadTo`, a walk of every road segment near the whole site) is looked
  for only when the lot gets no cut or the road it was placed on has no corner or edge midpoint within
  `manualReachM + hw`; otherwise that road already proves today's rule finds a road (same arithmetic).
- Candidate intervals are narrowed to the 0.25 m quanta they hold (a bound within 1e-6 of a quantum is that quantum);
  a target is tested for membership within 1e-6 m. Without that, float noise in a corner's projection (492 of 600 m
  reads 491.99999999999994) pushed narrow lots to their other end.
- A corner lot's side street is looked up among the roads meeting the node at the nearer end of its piece (within
  12 m of its kerb line), and only else in the index. A manual lot's other candidate roads are looked up only when
  the road its frontage faces yields no span. Slot 1 on a tie takes the high end of the span.
- Slots of one lot are packed (slot 0, then slot 1 when offered). **Slot 2 is not packed** (R1 repair, for R-B1):
  `RoadGraph.sideStreetJoinOf(lot)` places it on the first ask and keeps it (shared by `withOverrides` /
  `refreshedFor` copies), flagged `kJoinCut | kJoinSideStreet`. Same answer the packed build gave (the sprawl
  offers 17,233; packed columns 72,038 -> 54,805). A slot 0 that fell back to the side street is still packed as
  slot 0 with `kJoinSideStreet`.
- **Slot 3 is not packed either** (R8, the same rule for the same reason): `RoadGraph.rearAlleyJoinOf(lot)` places it
  on the first ask and keeps it, and `RoadGraph.hasRearAlley(lot)` answers the CANDIDATE question alone — the rear
  search without the placement — as one cached byte a lot, because every built site's `inSig` carries that bit
  (§3.9) while only a plan that takes the slot needs the placement. Both caches are shared by `withOverrides` /
  `refreshedFor` copies, so the answer never depends on when it is asked. Measured on the 12-mile sprawl audit town:
  the bit costs **0.67–0.82 µs a lot** on its first ask (36–44 ms for all 54,257 lots; 20–25 ms for the 30,559
  built ones) and **0.005–0.011 µs** warm, so **0.34–0.42 ms of a 512-site hashing tick** (4096 checks at
  `_hashCheckUnits` 8) and 0.005 ms once warm. Over a whole road edit (70 ticks) an A/B against pre-warmed bits
  measured 3–45 ms of difference in total — inside that bench's own JIT/GC noise, whose worst ticks run 25–55 ms
  either way — so the bit is not measurable above the noise of a real edit.
- `refreshedFor` keeps a graph only if bridges and start/end tapers are also unchanged (`_routesAlike`): the
  windows and every slot read them.
- `effectiveFrontage` (R-F) walks each edge's own box rather than the polygon's: the same candidates and the same
  answer, measured 13-19 ms → 6-9 ms over the sprawl's 25 frontage-less installations.
- **R-B1 (repaired):** bench `road_graph_slots_bench_test` (5 warm-ups, 21 timed builds, same machine, base lib
  files of 40b9eb9 swapped in for the baseline): base median 117-121 / best 107-114 ms; first R1 build median 188 /
  best 170 ms (+59%); after the repair median 130-131 / best 125 ms (about +10%, within ≤ +15%). The repair: slot 2
  on request (about 19 ms), the manual-lot legacy look-up skipped where proven (about 20 ms), join columns sized to
  the lots and published as views (GC; about 20 ms of median), node legs by road number instead of id look-ups.

**How today's numbers move (C1 notice, §7.3):**
- Narrow lots move to their drive side: about 7.5 m on a 24 m lot. That covers most auto lots.
- Wide lots move only by the clamp and the 0.25 m quantum.
- Lots near junctions and street dead ends move by the clamp (the cul-de-sac reserve).
- Manual lots move to the road their frontage faces.
- Set-back lots move to their §3.7a corridor position (the four starter sites: table above).
- Sites past a road end move.
- Cells move to their effective frontage.

### 3.3 Program classification (`classifyProgram`; first match wins)

| # | Condition | Program |
|---|---|---|
| 0a | unbuilt (zoned or empty), including every access-easement lot (§3.7a) | no plan stored |
| 0b | slot 0 is `kJoinLegacy` | `kerbOnly` |
| 0c | slot 0 is `kJoinCorridorBlocked`, or its `joinCrossLot` holds a BUILT auto lot | `kerbOnly` + `kPlanAccessBlocked` |
| 1 | `spec.siteKind != building`, or `claimsOwnSite && min(W, D) ≥ 150` and the group is not `res`/`com` | `installation`; if `W < 60 or D < 120`, fall through to 4 |
| 2 | `spec.type == 'mega'` (`parkingSpaces` = 0) | `kerbOnly` (the mega rule below) |
| 3 | group `res` and `housing ≤ 24` (r-low; sprawl house lots) | `homeDriveway` if slot 0 is back-out eligible (below) and §3.4 fits, else `kerbOnly` |
| 4 | industrial groups (`_isIndustrial`, building_massing.dart:278-285) | `yard` if it fits, else `carPark`, else `kerbOnly` |
| 5 | everything else (commercial, civic, r-med, r-high, strip mall) | `carPark` if it fits, else `kerbOnly` |

- **Back-out eligibility (homes only, §10.2 Q3).** A home car leaves by backing out into the street (§7.4 Home
  back-out), so `homeDriveway` needs slot 0 to pass ALL of the following. They read only the slot, its road and its
  piece's `kerbWindows`, and are checked here, never in `RoadGraph.of` (slots stay use-independent, C-22). A lot that
  fails any of them is demoted to `kerbOnly` (kerb parking), and the sprawl audit counts demotions by rule.
  1. **Road** (`RoadType.of(road).speedKmh`, road_catalog.dart; `lanes.medianM`, parcel.dart:538-562):
     - a minor tier at ≤ 40 km/h: `street`, `streetOneWay` (40 km/h, so eligible), `alley`, `path`. Back-outs are
       allowed in every direction `joinDirs` allows (both on a 1+1 street; the one direction of a one-way street);
     - `avenue` (50 km/h, 2 lanes each way): near direction only, into the kerb lane, never across. `_dirsFor`
       (road_graph.dart:685-694) already gives it only the lot-side direction, and traffic's departure planner also
       restricts its origins to the near edge;
     - divided or medianed (`medianM > 0`), or above 50 km/h: `kerbOnly`. In the road catalog that is
       `boulevard` (60 km/h, barrier median) and `highway` (urban highway, 70 km/h, painted median); a minor tier
       whose type is faster than 40 km/h is also demoted (none exists in the catalog).
  2. **Cut half.** `joinRoomM(slot 0) ≥ kHomeCutHalfM = 4.0` (the tail swing, V5). A narrow slot's preferred room is
     already 4.0 and a wide one's 4.5 (§3.2), so this costs no frontage; it demotes homes whose slot only fit at
     `kJoinMinRoomM = 2.5`.
  3. **Swing margin** (`kHomeSwingMarginM = 12`, V1). For each direction in `joinDirs`, the 12 m upstream of the join
     along that direction's travel must lie inside the lane span under any override. The windows are 6 m inside the
     lane span (V1), so the use-free test on the piece's `kerbWindows` is: forward travel `[s − 6, s + 4.0]` lies in
     one window interval; backward travel `[s − 4.0, s + 6]`; a join with both directions (a 1+1 street) needs
     `[s − 6, s + 6]`. It keeps every tail swing out of junction boxes and behind stop bars.
  4. **Skew.** `v` is within 10° of the road normal at the join: `v · joinNorm ≥ 0.98481` (cos 10° as a constant,
     no trig, C-11). A back-out needs one straight run from the stall to the kerb, so homes get no bent throat.
  5. **Geometry.** §3.4 fits.
- `carPark`, `yard` and `installation` are allowed on any eligible road, because their throats hold cars off the
  carriageway and they leave forward.
- A generator returns null when nothing meets its minimum, and classification then falls to the next program.
- **Every generator sizes its throat to the slot.** It reads `room = joinRoomM(slot)` and sets
  `throatW = min(programWidth, 2·(room − kCutFlareM))`. If `throatW` is below the program minimum, the generator
  returns null and classification falls through:

  | Program | `programWidth` | Minimum `throatW` |
  |---|---|---|
  | homeDriveway | 5.2 side by side, 3.2 tandem or single (`sharedSingle`, §3.4) | the variant's full width (room ≥ 4.0 is required above, which always gives it) |
  | carPark | 6.0 (`twoWay`) | 5.5 `twoWay`; or 3.0 `sharedSingle`, only when the plan has ≤ 8 stalls |
  | yard, installation | 7.0 (`twoWay`) | 7.0 |

  The cut half is then `throatW/2 + kCutFlareM` (homes: `max(kHomeCutHalfM, throatW/2 + kCutFlareM)` = 4.0 for both
  widths), and the throat corridor used by the packers is `x_J ± (throatW/2 + 1)`. On a narrow slot (room 4.0) a yard
  gets `throatW = 6.0 < 7.0` and falls through to `carPark`; on a `kJoinMinRoomM` slot (room 2.5) a car park gets a
  3.0 m `sharedSingle` throat and at most 8 stalls, and a home is already `kerbOnly` (room < 4.0).

**Capacity targets:** `C* = parkingSpaces(spec)` (building_massing.dart:289-299).

| Program | Target |
|---|---|
| home | 2 (side by side, else tandem), or 1 where only a single stall fits |
| carPark | `max(C*, com ? 6 : 4)`; civic/utility `max(C*, 8)` |
| installation | `clamp(C*, 12, 240)` |

The score rewards stalls up to 1.5·C* for `com` and 1.0·C* otherwise. Overflow parks at the kerb.

**Minimum envelope:**
- `floorsCap` is 12 when `housing + jobs ≥ 90`, 4 when ≥ 30, and 2 otherwise; industrial uses 1.4.
- `A_min = requiredArea(spec)/floorsCap` (building_massing.dart:266).
- `w, d ≥ 8 m`.

**As built (R2 core, `site_program.dart`, `site_plan_generator.dart`):**
- `classifyProgram` returns the program a row OFFERS; `planSite` runs the generators in fall-through order. Rows 0b
  (legacy), 0c (blocked corridor, or a BUILT lot in slot 0's `joinCrossLot`) and 2 (mega) settle `kerbOnly` outright,
  as do two §3.8 rows placed after 0c: no frame (degenerate) and a sliver (true D < 8 m or W < 6 m). "Unbuilt", "no
  slot" and "a frontage-less site with no eligible road in reach" store no plan.
- A small installation site (row 1, `W < 60 or D < 120`) is offered `yard` and carries `kPlanFallback`. Every program
  lesser than the one offered carries `kPlanFallback`: a home demoted by a back-out rule or by §3.4, and a car park,
  yard or installation that falls through (to a car park or to `kerbOnly`). Row 0c carries `kPlanAccessBlocked`.
- **The yard rule (frozen, repair round):** `yardPlanOf` makes the car park attempt itself. It returns a `yard` plan,
  or a `carPark` plan when the apron does not fit, or null exactly when neither fits. The dispatcher writes a
  `carPark` result with `kPlanFallback` and counts `yardNoFit`. On null it counts `yardNoFit` and writes `kerbOnly`
  with `kPlanFallback`, without calling `carParkPlanOf` again. `site_plan_dispatch_test` pins this with fake
  generators.
- Demotions are counted by rule in `SiteProgramStats` (`SiteDemotion`: `homeRoad`, `homeRoom`, `homeSwingMargin`,
  `homeSkew`, `homeGeometry`, `installationTooSmall`, `installationNoFit`, `yardNoFit`, `carParkNoFit`,
  `legacySlot`, `accessBlocked`, `mega`, `sliver`, `degenerate`). Back-out rules are checked in the order 1–4, and
  only the first failure is counted.
- Rule 1 reads the median from `RoadSpline.lanes`, which includes the decoration: a decorated avenue's planted 2 m
  median is a median, so that avenue is `kerbOnly` for homes.
- W is the frame's frontage length. D is the profile's deepest column plus its 0.3 m margin (the lot's true depth).
  Thresholds compare with a 1e-6 m tolerance, so `16.6 = 4.5 + 12.1` holds whatever the float noise of the sum.

**The mega rule (closed, R8 scoping).** Row 2's `kerbOnly` is not a placeholder for a podium garage. A megatower's
parking demand is not absent, it is DECLARED ALREADY MET: `parkingSpaces` short-circuits to 0 for `type == 'mega'`
BEFORE its own formula (building_massing.dart:288-291), and the two comment lines above that `return` say why — "a
megatower parks inside its own podium: eighteen thousand workers on a surface lot would need more block than the
building has". Run the ordinary formula on `kMegatowerSpec` (jobs 18 000, housing 6 000, leisure 2 000;
city_building_spec.dart:218-232) and it asks for 18 000·0.55 + 2 000·0.04 + 6 000·0.35 ≈ **12 080** stalls, which is
the size of the demand the short-circuit is declaring met. `megatower_test.dart:40-42` pins the 0 and says the same
in words. So what row 2 means is that the site plan is owed no SURFACE stalls — not that a mega attracts no cars,
and not that the plan is carrying an unmet demand it will have to place somewhere later. Drawing a
portal through the podium into that garage was reserved for R8 and is CLOSED, for four reasons that do not turn on
effort. It is one site: the sprawl audit counts `-mega: 1` against 30,559 planned
(`site_program_sprawl_audit_test.dart:46,65`). Its aisles would stand under a podium nobody can see into, and a
third of megatowers have no podium volume at all — `profile < 0.34` takes the straight extrusion that runs the
whole footprint to the parapet (building_massing.dart:812-832). `MassShape` cannot express a hole, and
`_openGateLane` DROPS any non-fence volume standing in the lane rather than cutting it (building_massing.dart:412,
which keeps only a thin fence run and `continue`s past everything else), so a naive portal would delete the base of
a 90-to-150-storey tower (:773-775) instead of opening one. Worst, a portal needs the first-ever exemption to
§2.4's "envelope ∩ paving = ∅", enforced at site_plan_validator.dart:1267-1268 for a stall and :1525-1527 for a
pave — the one rule that keeps a driveway out of a building on every planned site. Buying a garage for one building
by making that rule optional for all 30,559 is the wrong trade, and it is the trade a podium portal asks for.

**Public lots (`kPlanPublic`), deferred with a design (R8 scoping).** A public lot is a site whose stalls serve
trips with no destination in the building beside them. Classifying one needs a row this table does not have and a
use this game does not have: `ParcelUse` (parcel.dart:1192) holds no parking entry, so a public lot would arrive
either as a staked own-site spec that asks for stalls and no floor area, or as a new use, and its row would offer
`carPark` with `kPlanPublic` set (site_access_constants.dart:225) so that the traffic search can tell these stalls
belong to the street rather than to one building. It is NOT built. §7.5 carries the decision and the evidence,
because what blocks it is on the traffic side and not here.

### 3.4 Home driveway and pad ("both")

Cars on a home lot drive in forward, park nose-in, and leave by **backing out into the street** (§10.2 Q3; the
manoeuvre, gap acceptance and event logging are traffic's, §7.4 Home back-out). So the drive and its pad are ONE
straight run from the kerb, with the stalls on it and no turnaround. In the frame, `k` is the distance from the kerb
to the frontage line (3 m on auto lots, `sidewalkM`, city_layout.dart:50), `x_d` is the join's frame x,
`yT = max(7 − k, 1)`, `w` is the drive width and `r` the number of stall rows along the pad (1, or 2 in tandem).

```
      y ▲                                              rear yard ≥ 3 m
        │                  ┌─ house envelope [xP+1, W−1.5] × [yT, D−3] ─┐
        │                  │                                            │
 yT+5.2 │  ┌─────┬─────┐ P │                                            │
        │  │ S1  │ S0  │   │                                            │
        │  │     │     │   │                                            │
     yT │  ├─────H─────┤   └────────────────────────────────────────────┘
        │  │  throat   │   K→H: straight along the road normal, sharedSingle,
        │  │   K→H     │   5.2 m wide side by side (3.2 m tandem or single)
      0 ├──┤           ├─────────────────────────────────────────── frontage line
     -k │  └─────K─────┘   kerb node: cut half 4.0 (x_d ± 4.0); x = x_d (4.5 on a narrow auto lot)
```

Side by side is drawn (the preferred form). **Tandem:** a 3.2 m drive, `S0` on the axis at `[yT, yT + 5.2]`, `S1`
behind it at `[yT + 5.2, yT + 10.4]`, `P` at `yT + 10.4`. **Single:** a 3.2 m drive, `S0` on the axis, `P` at
`yT + 5.2`.

- **Nodes:** `K` (kerb, ref `kerb`); `H = (x_d, yT)` (the throat's far node, `pad`); `P = (x_d, yT + 5.2r)` (the pad
  end, `pad`, `kNodeDeadEnd`, `nodeTurnKind = none`: V7's home exception).
- **Segments:**
  - `K→H`: driveway, width `w`, `sharedSingle`, 10 km/h, `kSegThroat|kSegCrossesPavement`. It runs along the road
    normal (within 10°, §3.3 rule 4) and its length `k + yT` is ≥ 7 m (7.0 on auto lots), so the first stall mouth
    is 7 m from the kerb (V5) and a parked car's rear stays off the pavement.
  - `H→P`: `apron` (the pad), width `w`, `sharedSingle`, 10 km/h, collinear with `K→H` (V5), length `5.2r`.
  - `K→H→P` is one `sharedSingle` claim unit (§7.4). The cut half is `kHomeCutHalfM = 4.0` for both widths (§3.3).
- **Stalls:** 2.6 × 5.2 m, `inline`, nose `+v`, `stallInDirs = {fwd}`, `stallOutDirs = {bwd}` (V9), ordered from the
  street outward.
  - **Side by side** (`w = 5.2`, preferred): two stalls at `s = 0`, centred at `x_d + 1.3` (`S0`, side 0, right of
    `+v` travel) and `x_d − 1.3` (`S1`, side 1). They fill the pad, and the drive keeps the pad's full 5.2 m width
    down to the kerb, so a car reversing out of either stall can reach the kerb line on the join axis `x_d`, where
    §7.4 measures its footprint.
  - **Tandem** (`w = 3.2`, at most 2 deep): `S0` (outer) at `s = 0` and `S1` (deep) at `s = 5.2`, both on the axis
    (side 0). An arriving car takes the deepest free stall; a deep car blocked by an outer one is traffic's (LIFO
    assignment and the 120 s shuffle, §7.5).
  - **Single** (`w = 3.2`): `S0` on the axis at `s = 0`.
- **Variant order:** side by side, then tandem, then single; the first that passes the thresholds below wins.
- **The manoeuvre** (traffic's, §7.4): in forward up the throat onto the pad, nose-in to the reserved stall; out by
  reversing down the pad and the throat in one straight run, then backing out into the street lane on a gap. No car
  turns on the pad.
- **Mirror:** if the join hugs `x = W`, every x is mirrored about `W/2` (the house then stands at `x < x_d`). A wide
  lot's mid join puts the house on the larger side, with ties broken by the seed.
- **Skew:** a lot whose `v` is more than 10° off the road normal at the join is `kerbOnly` (§3.3 rule 4). A home drive
  never bends, because a car reverses its whole length.

**Thresholds** (derived from the geometry above; `xP = x_d + w/2` is the drive's inner edge; side setback 1.5, gap
1.0, a house ≥ 8 × 8 standing beside the drive from the throat's far-node line, i.e. inside
`[xP + 1, W − 1.5] × [yT, D − 3]`; rear yard ≥ 3; 0.5 m clear behind the deepest stall):

| Rule | Auto lot (k = 3, x_d = 4.5, yT = 4) |
|---|---|
| 2 side by side (`w = 5.2`): `W ≥ x_d + 2.6 + 1 + 8 + 1.5 = x_d + 13.1`, and the drive's outer edge `x_d − 2.6 ≥ 0.3` (1.9) | **W ≥ 17.6 m** |
| 2 tandem (`w = 3.2`): `W ≥ x_d + 1.6 + 1 + 8 + 1.5 = x_d + 12.1`, and depth over the drive `≥ yT + 10.4 + 0.5` (14.9, weaker than the house rule on a rectangular lot) | **16.6 ≤ W < 17.6** |
| 1 stall (`w = 3.2`): `W ≥ x_d + 12.1`, and depth over the drive `≥ yT + 5.2 + 0.5` (9.7) | **W ≥ 16.6**, used only where the drive's columns are shallower than 14.9 m (irregular lots) |
| depth over the house x-range `≥ yT + 8 + 3` | **D ≥ 15 m** |
| slot 0 back-out eligible: road, room ≥ 4.0, 12 m swing margin, skew ≤ 10° (§3.3) | required |
| the drive `[x_d ± w/2] × [−k, yT + 5.2r]` and the stalls pass `containsRect` | required |
| otherwise | `kerbOnly` |

**What moved from the turn-on-the-pad design** (a 6 m apron beside the stalls with the house behind it):

- Two stalls: W ≥ 18.9 m → **W ≥ 17.6 m** (side by side). The pad is centred on the drive's axis instead of hanging
  off it, so its inner edge is 7.1 m, not 8.4 m.
- The narrowest home: W ≥ 16.3 m with 1 stall → **W ≥ 16.6 m with 2 stalls in tandem**. The 3.2 m drive now runs
  beside the house, so its edge at 6.1 m binds instead of the old stall edge at 5.8 m.
- Depth: D ≥ 22 m → **D ≥ 15 m**. The house front moves from behind the apron (y = 11) to `yT` (y = 4).
- The 4.0 m cut half (up from 1.6 + 1.0 = 2.6) moves no threshold: the cut lies in the kerb and pavement, and a
  narrow slot already sits `m + cc = 4.0 + 0.5 = 4.5 m` in from its lot line (§3.2). It only demotes homes on
  `kJoinMinRoomM` slots.

Against the plat, a downtown 24 × 32 lot gets 2 stalls side by side. Sprawl house lots of 17–33 × 36
(city_generator.dart:1963-1967) get 2 stalls in tandem below 17.6 m and side by side from 17.6 m. A 12 m infill lot
is kerb only, and so is any house lot whose slot 0 fails the §3.3 back-out rules.

**As built (R2 core, `home_driveway.dart`):**
- The drive is laid from the kerb point along the slot's ROAD normal `n`, because V5 and §3.4 make it straight along
  the normal. `H` lies where the drive reaches frame `y = yT`, so `|K→H| = (k + yT)/(n·v)`, which is 7.0 m when
  `v = n`. Every threshold is measured on the drive's real corners in the frame: the house starts 1 m past the
  drive's largest frame x (or ends 1 m before its smallest), the outer edge is the drive's nearer corner to its lot
  line, and "depth over the drive" is compared with the drive's deepest corner + 0.5 m. On a lot whose `v` is the
  normal these are exactly the table's rules. On a skewed lot (≤ 10°) they are conservative, and the envelope never
  meets the drive.
- The house side is the side with more room, ties broken by `tieBreak('home-side')`. The same rule covers the
  mirror.
- `containsRect` checks the drive's on-parcel bounding box `[minX, maxX] × [0.05, deepest corner]` (0.05 m in
  from the frontage line, where a corner would lie on the boundary) and the house rectangle
  `[x0, x1] × [yT, D_house − 3]` GROWN by `kContainsInsetM` (0.05 m) on every side, so the emitted envelope (inside
  that rectangle) stands at least 5 cm inside the lot and a millimetre re-sample cannot flip the fit (§4.4). A1
  checks every home envelope with the exact `containsRect`.
- The door is the envelope front midpoint `(x, yT)`. `pavementPt` is its projection onto `y = 0`, and the footpath
  reuses those two points. `entranceNode` is `H`. The drive pave's two kerb corners are `blend` with `hT = 1` on join
  0; every other point is `pad`.
- A site set far back from its kerb (a footprint, or a lot on a curved road, where `k` reaches 40 m) has a throat
  `K→H` longer than V5's 24 m via gap. It gets `ceil(|K→H|/24) − 1` evenly spaced vias on its chord. A1's random
  lots found this, and `home_driveway_test` pins it.
- The house envelope is the building footprint (§6.1 step 3, `fitFootprint` without A_min) fitted into the free side
  region `[drive edge + 1, W − 1.5] × [yT, D − 3]` and set against the drive. §3.4's 8 × 8 m house is the home's own
  minimum; the massing A_min is a whole-building figure (420 m² for r-low) that no home lot meets, so homes do not use
  it. The width is capped at `2·(60 − |near edge − H.x| − |yT − H.y|)`, so the door stays within V11's 60 m of `H` on
  any lot; below 8 m the variant is refused. Without this, a 250 m wide r-low lot put its door 63.55 m from `H` (V11).
  `home_driveway_test` pins 60, 250 and 300 m wide lots.

### 3.5 Car parks (`car_park_packer.dart`)

Everything is axis-aligned in the frame. Bays are 2.6 × 5.2 m, two-way aisles 6.0 m, the throat corridor has
1 m of clearance each side, and lamps are pitched at 25 m.

- **Modules.** A double-loaded module is row / aisle / row, pitched at 16.4 m. A single-loaded module is aisle
  then row, 11.2 m, with the row on the building side. A block is `k` modules back to back.
- **Connectivity.**
  - `k = 1`: the throat meets the aisle in a T. Each arm longer than 8.6 m ends in a `hammerhead` node, form (b)
    of V7, with no stall in its last 3 m on either row. Shorter arms are cut, giving an L.
  - `k ≥ 2`: 6 m cross aisles at both block ends join every aisle into a ring with no dead ends. v1 puts no
    stalls along cross aisles.
  - **Throat exclusion:** no stall rectangle intersects `[x_J − (throatW/2 + 1), x_J + (throatW/2 + 1)] ×
    [−k, first aisle's near edge]` (`[x_J ± 4]` for a 6 m throat). Stalls on the far side of the first aisle,
    across from the throat, are allowed.
  - Stalls obey V9: mouth on the segment (`s ≥ 0` from the throat's T node) and at least one run-up bit.
- **Families.** `yT = max(0, 7 − k_kerb)`.
  - **F1 FRONT:** the block is at the frontage, its first aisle centre ≥ `yT`, and the envelope sits behind it
    plus a 2 m walk strip.
  - **F2 REAR:** a 6 m side drive runs `[x_J ± 3]` to a block at the back. The drive is the throat segment (V5:
    straight, no stall or branch along it; vias when it exceeds 24 m). The
    envelope sits in front, beside the drive.
  - **F3 SIDE:** the aisles run along y, and the throat continues straight into the first aisle. The first stall
    is at `y ≥ yT`. `k ≥ 2` gets a rear cross aisle and `k = 1` a rear hammerhead. The envelope is on the other
    side.
- **Enumeration.** For each family, `k = 1..min(8, fit)`, single or double for the module nearest the building. It
  takes the widest profile interval that holds the block and contains the join, emits stalls, and computes the
  envelope (§6.1). A candidate is rejected if the envelope is smaller than 8 × 8 m or `A_min`.
- **Score:**
  `10·min(n, cap) − 2·max(0, n − cap) + 0.02·envelopeArea − 0.5·driveLength + bias`, where `driveLength` is
  Σ `segLenM` over the plan, `cap` is 1.5·C* for `com` and C* otherwise, and the bias is F2 +5 when
  `W < 40` (it keeps a street wall) and F3 −2. Scores within 1% are broken by
  `xorshift32(seed ^ fnv('family'))`. The best candidate with `n ≥ 1` wins; if none, fall through.
- **Envelope rule for the packers:** the envelope clears a stall row that faces it by the 2.0 m walk strip, and
  every other pave by the §6.1 1 m clearance; its sides are `[1.5, W − 1.5]` (side setback) unless a drive is
  beside it; its rear is `D − 0.3` (profile margin).
- **Worked example (pinned exactly by `car_park_packer_test`).** A c-med lot (jobs 24, C* 20, cap 1.5·C* = 30,
  A_min 264 m²) on a 24 × 32 auto lot: `k = 3`, narrow slot 0 at `x_J = 4.5` with room 4.0 → `throatW = 6.0`,
  `yT = 4`, profile x ∈ [0.3, 23.7], y ∈ [0.3, 31.7]. Throat exclusion `[0.5, 8.5] × [−3, aisle near edge]`.
  - **Aisle and arms (all F1 candidates).** The throat meets the aisle at `J = (4.5, y_a)`. The left arm would be
    4.2 m ≤ 8.6, so it is cut: the aisle pave starts at the throat's left edge, x = 1.5 (an L). The right arm is
    19.2 m > 8.6: it ends in node `E = (23.7, y_a)`, `segLen(J→E) = 19.2`, with the V7(b) stall-free zone
    x ∈ [20.7, 23.7].
  - **Stall x-range.** Mouth on the segment: left edge ≥ 4.5 − 1.3 = 3.2. Run-up: the forward bit holds for
    s ≥ 6.3 and the backward bit for s ≤ 12.9, so every s in [0, 19.2] has a bit and the run-up removes nothing.
    A row not under the throat exclusion packs x ∈ [3.2, 20.7]: ⌊17.5 / 2.6⌋ = **6 stalls** (left-packed,
    [3.2, 18.8]). A row under it packs x ∈ [8.5, 20.7]: ⌊12.2 / 2.6⌋ = **4 stalls** ([8.5, 18.9]).
  - **F1 single** (aisle y [1, 7], `y_a` = 4 = yT; row y [7, 12.2] across the aisle, so not excluded): throat
    K(4.5, −3)→J 7.0 m; 6 stalls; envelope `[1.5, 22.5] × [12.2 + 2.0, 31.7]` = 21 × 17.5 = **367.5 m²** ✓.
    Score `10·6 + 0.02·367.5 − 0.5·(7.0 + 19.2)` = 60 + 7.35 − 13.10 = **54.25**.
  - **F1 double** (row 1 y [0.3, 5.5], aisle [5.5, 11.5], `y_a` = 8.5, row 2 [11.5, 16.7]): throat 11.5 m; row 1
    is under the exclusion (4 stalls), row 2 is not (6 stalls): **10 stalls**; envelope
    `[1.5, 22.5] × [16.7 + 2.0, 31.7]` = 21 × 13 = **273 m²** ✓ (≥ 264, ≥ 8 × 8). Score
    `10·10 + 0.02·273 − 0.5·(11.5 + 19.2)` = 100 + 5.46 − 15.35 = **90.11**.
  - **F2 single** (rear: aisle y [25.7, 31.7], row on the building side y [20.5, 25.7], under the exclusion
    because the drive runs to the first aisle: 4 stalls; drive K→J 31.7 m): envelope beside the drive
    `[7.5 + 1, 22.5] × [0.3, 20.5 − 2.0]` = 14 × 18.2 = 254.8 m² < 264 ✗. F2 double: 14 × 13 = 182 m² ✗.
  - **F3** (aisle along y at x_J, stalls at x [7.5, 12.7]): envelope width 22.5 − (12.7 + 2.0) = 7.8 m < 8 ✗.
  - **Winner: F1 double, 10 stalls, envelope 21 × 13 m.** The other 10 of C* park at the kerb.
- **Second joins** (slot 1 or 2): used when `W ≥ 80 m`, ≥ 60 stalls, or a corner lot with ≥ 30 stalls. They
  attach to an existing aisle, never to a stall row.
- **Lamps:** one post every 25 m along each back-to-back line, starting 12.5 m in.

**As built (R2 car park / yard track, `car_park_packer.dart`):**
- **Throat.** Laid from slot 0's kerb point straight along the frame's `v`, so V5's 10° rule is the slot's skew, tested
  up front with a 0.002 margin on the cosine (the validator measures the normal from the road polyline). A slot more
  skewed than that (for example a corner lot whose slot 0 fell back to its side street) gets no car park: §3.8's bend
  for skews over 10° is not built. A `kJoinOffFrontage` slot gets no car park either (its corridor is §3.7's dogleg).
- **Bend node (repair round).** A throat along `v` drifts `k·tan θ` sideways off the road normal by the frontage, and
  §3.7a lays a set-back slot's corridor along that normal with a 4.5 m half width (1.5 m of slack beside a 6 m
  throat). So on a site with `k ≥ 7` whose drift exceeds `kThroatStraightM` (0.1 m), the throat runs along the ROAD
  normal to a bend node `B` where it meets `y = 0` (at least 7 m, so `yT = 0`), and the drive continues along `v`
  from `B`: `x_J` is `B`'s x. F1/F2 add a `driveway` segment `B → J`; F3's first aisle and a yard's spine start at
  `B`. The throat's pave is a quad along the normal (its kerb corners blend), and the drive's pave starts
  `throatW/2·|nu|` in front of the frontage so the two meet. Stalls beside a drive that starts at `B` start past the
  quad's far corner (V9). A site with `k < 7` drifts at most 1.23 m, inside a 6 m throat's slack, and keeps the
  straight throat; a 7 m yard throat whose side edge would leave the corridor there gets no yard (§3.6 as built).
  Pinned by `car_park_packer_test` (a set-back lot turned 5.7°, and 500 random sites: 43 of 116 car parks bend, every
  pave corner off the parcel, and every pave edge just below the frontage line, within 4.5 m of the normal).
- **Straight throat's kerb corners (R2 merge).** The straight throat's pave put its two kerb corners on the frame's
  `y = −k`, so on a skewed site one corner stood up to `hw·tan 10°` (0.05–0.5 m) behind the kerb line, in the
  carriageway and outside parcel ∪ corridor. The track's own test checks pave against the normal, not against
  `sitePavingViolations`, which landed on the other track; merged, A1 reported 1 small-town and at least 25
  random-site car parks and yards. The corners now sit on the kerb line through `K`, at `y = −k − (x − x_K)·nu/nv`. The rest of the
  plan (nodes, segments, stalls, keys) is unchanged.
- **Block interval.** The run of 0.5 m profile columns around `x_J` deep enough for the block, inset by the 0.3 m
  profile margin (the example's `[0.3, 23.7]`). F1's block moves back until its first aisle's centre is at least `yT`
  (the single-module example's aisle `[1, 7]`). F2 lays its modules from the depth of `x_J`'s column toward the
  frontage, and its drive runs to the front-most aisle. F3 centres module 0's aisle on `x_J`, grows toward the side of
  `x_J` with more room (ties by `tieBreak`), keeps stall rectangles at `y ≥ yT`, and for `m ≥ 2` puts the cross aisle at
  the rear, with the other aisles' front ends as T ends at `y = 0.3`. F1/F2 rings put their cross aisles 3 m inside the
  interval and reject a `J` within 1 m of one.
- **Arms.** One arm packs from `x_J ∓ 1.3` (the example's 3.2, mirrored on a lot whose join is at its other end); with
  both arms, the right arm starts at `x_J − 1.3` and the left arm stops there. On a ring's first aisle the segments on
  either side of `J`, and the bays next to a cross aisle, keep the same clearances.
- **Envelope rule.** The envelope is the free rectangle itself, not fitted to `buildingFootprint` (the worked example's
  21 × 13 m requires that). The walk strip is applied to one rectangle, the union of the packed stall rows. The free
  rectangle's 0.5 m columns start at the 1.5 m side setback, so the example's F3 measures 7.5 m wide, not 7.8 m (both
  are under 8 m). The door is the envelope's front midpoint, and `entranceNode` is the nearest non-kerb node (a
  candidate whose door is further than 60 m away is rejected).
- **Footpath (§6.1 step 6, repair round).** The path runs from the pavement point on `y = 0` straight along `v`, then
  jogs along `y = door.y` to the door. Its x is the door's own when that run crosses no stall or bay and runs along no
  drive laid along `v` (a throat, a bend's drive, an F2 side drive), each kept 0.75 m (half the path) away. Aisles
  count as gaps between rows and may be walked. Otherwise the x is the nearest end of a blocked run (ties to the smaller
  x) whose run and jog stay inside the lot and whose jog crosses nothing. The pavement point is where the path meets
  `y = 0`, not the door's projection. When no candidate is clear, the path runs straight (none on the test sets). In the
  worked example the path runs up `x = 19.65`, beside the right T end.
- **Score cap.** `max(capacityScoreCap, capacityTarget)`, so a spec whose `C*` lies under §3.3's minimum (4, 6 or 8)
  is still rewarded up to that minimum. A `sharedSingle` throat keeps the first 8 stalls packed.
- **Stall keys (V10, ask 8).** `row` is the row's index in the block's own module order (F1 from the frontage, F2 from
  the rear, F3 from the spine). `bay` is the lattice place along its aisle segment, counted from the segment's start
  (on a ring's first aisle, the segment ending at `J` counts from 4096). A dropped place keeps its number, so stalls on
  one aisle keep their keys when another aisle changes (pinned by `car_park_packer_test`).
- **Not built (left for a follow-up, open at the R2 merge report):** second joins (slot 1 or 2 when `W ≥ 80`, `≥ 60`
  stalls, or a corner lot with `≥ 30` stalls), and §3.8's bend for skews over 10° (those slots fall to `kerbOnly`,
  counted `carParkNoFit`). Neither is in the §8.3 or §9 R2 acceptance lists. As of the R8 scoping, NO plan this
  game has ever built emits more than one join: every `addJoin` call site passes slot 0 (car_park_packer.dart:1190,
  home_driveway.dart:97, installation_access.dart:199, and the kerbside plan at site_plan_generator.dart:368), so
  slots 1 and 2 are offered by the graph and never picked. That is what "second joins" still means in §9's R8 row,
  and it is a car-park feature: the gate is separately and permanently singular (§6.1 item 4).
- **Closed: one-way loops with angled stalls (R8 scoping).** Angled bays on one-way aisles were reserved for R8 on
  the intuition that they pack more cars into the same ground. In this repo's own dimensions they pack fewer, and
  the arithmetic is written down here so the question is never re-litigated from intuition. Today a double-loaded
  module is `kStallLengthM` + `kAisleTwoWayWidthM` + `kStallLengthM` = 5.2 + 6.0 + 5.2 = **16.4 m** deep and holds
  two stalls every `kStallWidthM` = 2.6 m along it (site_access_constants.dart:461, :462, :486), so a stall costs
  2.6 × 16.4 / 2 = **21.32 m²**. Turn the bays 60° and the pitch along the aisle becomes 2.6 / sin 60° = 3.002 m
  while a row deepens to 5.2·sin 60° + 2.6·cos 60° = 5.803 m — the standard module arithmetic, which reproduces the
  parking handbooks' 58 ft double-loaded 60° module at 9 × 18 ft bays, so it is not a figure invented here. At a
  shippable 5.0 m one-way aisle the module is 2 × 5.803 + 5.0 = 16.607 m and a stall costs
  3.002 × 16.607 / 2 = **24.93 m²**, 17 % worse than today; even at V8's own floor for an angled segment, 3.5 m, it
  is **22.68 m²**, still 6 % worse. The nesting that makes angled parking look competitive on paper — adjacent
  rows' rear sawteeth interlocking, worth `kStallWidthM`·cos 60° / 2 = 0.65 m a row, which is where the scoping
  pass's 22.98 m²/stall came from — is not expressible here: §3.5's blocks are axis-aligned rectangles and §6.1's
  free-rectangle search is a histogram over 0.5 m profile columns, so a sawtooth costs its bounding box.

  The run-up rule takes the rest. A one-way aisle presents ONE lane, so a stall can set only one V9 direction bit,
  and with no backward lane to rescue it every bay within `kStallRunupM` + 1.3 = 6.3 m of the aisle's from-node is
  not emitted at all. Re-run the worked example above on its winner: the aisle `J→E` runs 19.2 m from `x_J` = 4.5,
  so one-way packing starts at a stall edge of 4.5 + 5.0 = 9.5 m rather than 3.2 m, which also swallows the throat
  exclusion (9.5 > 8.5, so both rows now pack the same 11.2 m). That is ⌊11.2 / 3.002⌋ = 3 angled stalls a row,
  **6 in the module against the pinned winner's 10** — 8 if the bays stayed perpendicular, which is the scoping
  pass's "about 7" bracketed from both sides. And that example could not take a one-way aisle at all: V7 allows
  one-way segments only inside cycles, so a single L aisle ending in a hammerhead is not convertible, and the
  `k ≥ 2` ring a real one-way loop needs does not fit this lot. Take it at its cheapest, by the enumeration rule
  above (`k` modules, double except for the one nearest the building): 16.607 + (5.0 + 5.803) = **27.41 m** of
  block. On this lot's 31.4 m profile that block plus the 2.0 m walk strip leaves an envelope about **2 m** deep,
  which fails both the 8 × 8 m minimum and `A_min` = 264 m², so the candidate is rejected and the site falls to
  `kerbOnly` — no car park, not a smaller one. Angled parking's real benefit is turn-in clearance, and this sim cannot
  represent it: `SiteManoeuvre.stallPose` is a cubic through four control points (site_manoeuvre.dart:164-176) with
  no swept path, so an easier turn buys nothing that is simulated. Fewer stalls, a program that fits on fewer lots,
  and no modelled benefit: closed, not deferred.
- **Cost.** Generation is branch and bound. A candidate whose best possible score (stalls up to the cap, the free area
  of the envelope's region `[1.5, W − 1.5] × [0, maxDepth]` less the part of its block inside that region, its drive) is
  below the 1 % tie band of the best score so far is dropped before its envelope search, or while its stalls pack past
  the cap. A candidate whose block leaves less than `max(A_min, 64 m²)` of that region is dropped as well. The
  winner is the exhaustive enumeration's (pinned by `car_park_packer_test` against `carParkCandidatesOf`), and every
  valid candidate's score is at most the bound it was held to (pinned: counting the whole block, which reaches past
  the side setbacks, made that fail). Drafts are pooled per site (a rejected candidate's buffers are reused), module
  layouts are built once, and the free-rectangle search keeps its scratch on the site and cuts each blocked rectangle
  over only its own columns. A one-off A/B against the first landing (cf8f8b8) gave identical candidates (549,342) and
  winners (30,926) on every straight site of the starter kit, both towns, the sprawl and the random sites.

### 3.6 Yard (industrial)

A yard is a car-park candidate plus an 18 × 24 m truck apron beside the envelope's side or rear face.

- A 7 m driveway (`throatW` 7.0, so the slot needs room ≥ 4.5, §3.3) leads to the apron. Its first ≥ 7 m is the
  throat.
- The apron has a `circle` turnaround node of radius 12.5 m and two 3.5 × 15 m loading bays facing the envelope.
- `admitsTrucks` is set and `truckTurnRadiusM` is 12.5.
- If the apron does not fit, the car park is emitted alone, with trucks not admitted and no bays.

**As built (R2 car park / yard track, deviation).** "An 18 × 24 m apron with a 12.5 m circle and 15 m bays" does not
compose: 18 m holds neither a 25 m circle nor a 7 m lane plus a 15 m bay. The yard is built as one layout:
- **Spine.** The 7 m throat `K → T` continues as a 6 m stall aisle `T → A` along `v` (trucks: `segMaxVehLenM` 12,
  `kSegTruck`). It carries a stall row on the side away from the envelope, and optionally a row on the envelope side
  that stops short of the bays.
- **Apron.** At `A` the apron segment turns along `±u`, toward the side with more room, to the dead-end `circle` node
  `Y` (radius 12.5 m). The apron pave runs from 3.5 m beyond the spine's centre on the far side to `Y` across, and from
  18.5 m in front of the apron segment to 3.5 m behind it.
- **Circle (repair round).** §3.7 step 4's rule applies: the circle's bounding square `Y ± 12.5` must pass
  `containsRect`, or there is no yard. The square is paved as its own pave, so the envelope keeps clear of it.
- **Apron length (second repair round, deviation from `kYardApronWidthM`).** A truck's only U-turn (V13) is the
  circle, so no loading bay may lie inside its disc (§3.7: bays sit "on the circle's far edge", never inside): a truck
  parked in a bay would block the turnaround. The bays' far edge is 11.5 m from the spine, so the apron is
  `11.5 + 12.5` = 24 m long, not 18 m, and the pair's far edge stands a full radius short of `Y`. The apron never
  shortens: a lot with less than `24 + 12.5 + 0.3` m on the apron's side gets no yard (the car park fallback). (The
  first repair round kept 18 m and shortened it to 11.5 m on narrower lots. Both bays then lay inside the disc on
  every yard, their nearest points 6.1 m and 10.1 m from `Y`.) Pinned by `car_park_packer_test`: every bay rectangle's
  nearest point is at least 12.5 m from every circle node, on every yard of every test set.
- **Bays.** Two 3.5 × 15 m bays sit on the apron segment, 4.5 m apart, the inner one just clear of the 7 m lane band
  around the spine. Their noses point along `−v`. The envelope stands in front of them: the apron is beside the
  envelope's rear face. The envelope search is limited to the apron's side of the spine, and a candidate whose envelope
  does not meet the bays' front ends (within the 1 m clearance and one column) is rejected.
- **Lamps (second repair round).** One post every 25 m, starting 12.5 m in, along the outer edge of the far stall row.
  Where that row leaves the lot, along the near row's outer edge, or else along the spine's far edge. They always stand
  on an accepted pave, so inside the lot (the first landing put them on the far row's line even when that row was
  skipped: 3.7 m outside a 40 m lot joined 4.5 m from its side). Pinned: every lamp inside the parcel.
- **Throat corridor (second repair round).** A straight throat (no bend, `k < 7`) has its side edge meet the frontage
  `throatW/2 · nv + k · |nu|` off the road normal. For the 7 m yard throat on a skewed site with `k` just under 7 that
  can exceed the 4.5 m §3.7a half width, and a bend would be shorter than 7 m. Such a slot gets no yard (and no car
  park throat, though the 6 m one stays within 4.2 m). The test samples every pave edge where it crosses just below
  the frontage line, not only the corners.
- **Candidates.** The apron's `y` is taken at three values: the shallowest that leaves an 8 m envelope in front of the
  bays, the one whose spine holds the capacity target, and the deepest whose circle square stays within the depth over
  the apron and the circle (`y_A + 12.5 ≤ yRear`). No `num.clamp` is used: the bounds may meet within 1e-6 (pinned at
  depth 40.6 m ± 3e-7). Each value is tried with and without the envelope-side row, scored by §3.5's formula with no
  bias.
- **Where yards land.** A generated town's industrial lots (30 × 46 m) cannot hold a 25 m circle square beside the
  spine together with 18.5 m of bays in front of an 8 m envelope. Their yards fall back to car parks (`yardNoFit`):
  0 yards in six generated towns of 4–6 blocks. The sprawl's larger industrial lots get 40 yards from 62 offers (42
  with the 18 m apron).
- **Fallback.** A slot with room < 4.5, or no yard candidate, falls to `carParkPlanOf`. V13's truck path is the throat,
  the spine and the apron, reversing into the circle.

### 3.7 Installations (`installation_access.dart`)

```
  y ▲   envelope = parcel ∩ {y ≥ Df}; the massing's front fence run stands ON y = Df with its gap at gateX ± gateW/2
 Df ├───────────────────────────────G──────────────────── fence line   G: kNodeGate, dead end, hammerhead (a)
    │                               ║  last 6 m of Y→G: the 7 × 6 m clear gate apron
    │                        ▭ ▭   ║   ▭ ▭    loading bays 3.5 × 15, |x − x_G| ∈ [4, 11.5], y ∈ [Y+13, Y+28]
    │                             (Y)════════C═══╗   connector 6 m along u, at y = Y, to the car park's first aisle
    │                         circle r 13        ║   staff car park (F3, aisles along y), stalls at |x − x_G| ≥ 21
    │                               ║            ║
  0 ├───────────────────────────────F────────────────────── frontage line (F = T when k ≥ 12)
    │                               ║  throat K→T: straight along the road normal, vias ≤ 24 m apart
 -k └───────────────────────────────K kerb node               (crosses the easement lot on set-back sites, §3.7a)
```

All positions are in the site frame. `k` is the kerb-to-frontage distance at the join; `D` the frame depth.

1. **Throat.** `K` is the kerb point. The access road runs straight along the ROAD normal for `max(12, k)` m to the
   throat's far node `T`, so `T.y = max(0, 12 − k)`. When `k ≥ 12`, `T` is the frontage node `F` on `y = 0` (the
   starter sites: `k = 56`, a 56 m throat with vias at 24 and 48 m). `K→T` is `accessRoad`, `throatW` 7.0 m (§3.3),
   `twoWay`, 20 km/h, `kSegThroat` (plus `kSegCrossesPavement`).
2. **Dogleg** (`kJoinOffFrontage` only): `K`, straight 12 m to `T` (the throat), a bend, a frontage-parallel leg at
   `T.y` to `x = clamp(x_J', 30, W − 30)`, then `F` on `y = 0`. `K→F` is capped at 120 m. `kJoinClamped` alone never
   doglegs.
3. **Spine origin.** `S = F` for a dogleg, else `T`. `yS = max(S.y, 0)`, `x_G = S.x`. If the road normal and `v`
   differ by more than 3°, `S` is a bend node and the spine runs along `v` from it. `Dmax = max(40, 0.25·D)`.
4. **Yard.** `Y = (x_G, yS + 13 + 2)`: a `circle` node of radius 13 m (the circle starts 2 m past the throat's far
   node, never inside it). `Y + 13 = yS + 28 ≤ 40 ≤ Dmax` always holds because `yS ≤ 12`. If the circle's bounding
   square fails `containsRect` (a spine near a lot side), there is no yard: the branch node is
   `B = (x_G, yS + 7)` instead, and no bays are emitted.
5. **Loading bays.** Up to 4 bays, 3.5 × 15 m, nose `+v`, on the circle's far edge beside `Y→G`: x in
   `x_G ± [4, 7.5]` and `x_G ± [8, 11.5]` (clear of the 7 m road), y in `[Y + 13, Y + 28]`. `baySeg = Y→G`,
   `bayS = 13`, `baySide` from the sign of `x − x_G`. Bays failing `containsRect` are dropped; fewer than 2 left →
   none.
6. **Staff car park.** The §3.5 packer runs in F3 form (aisles along `y`) on the side of the spine with more room:
   band `x ∈ [x_G + 15, W − 0.3]` (or mirrored `[0.3, x_G − 15]`), `y ∈ [0.3, Dmax − 6]`. So the car park x-range
   excludes `[x_G − 13 − 2, x_G + 13 + 2]`. Its first aisle is centred at `x_C = x_G ± 18`; the stall row between that
   aisle and the spine would fall inside the exclusion and is not emitted, so stalls lie at `|x − x_G| ≥ 21`. A 6 m
   `twoWay` connector runs along `±u` from the branch node (`Y`, or `B`) to the branch node `C = (x_C, Y.y or B.y)`
   on the first aisle. Aisle ends that join nothing are V7(b) hammerheads. Target `clamp(C*, 12, 240)`.
   `carParkDepth` is the car park's far pave edge `y` (0 when none fits; a network with 0 stalls is legal).
7. **Forecourt depth, without `clamp`:**
   ```
   need = max(40, carParkDepth + 6, bays.isNotEmpty ? Y + 13 + 15 + 3 : 0)
   Df   = min(need, Dmax)                    // Dmax >= 40, so never lo > hi; no num.clamp anywhere
   if bays.isNotEmpty && Y + 13 + 15 + 3 > Df: drop the bays; clear kPlanAdmitsTrucks
   ```
   `carParkDepth + 6 ≤ Dmax` by the band in step 6, and `Y + 13 ≤ 40 ≤ Df` by step 4, so only the bays can be cut.
   `kPlanAdmitsTrucks` and `truckTurnRadiusM = 13` are set only when bays remain (V13).
8. **Gate.** `G = (x_G, Df)`: `kNodeGate`, a dead end with `hammerhead` form (a) over the last 6 m of the spine
   (a 7 × 6 m clear paved rectangle; bays sit at `|x − x_G| ≥ 4`, so they never intrude). The spine segment
   (`Y→G` or `B→G`) is `accessRoad`, 7 m, `twoWay`, 20 km/h. The full access road is
   `K → T (→ F) (→ bend) → Y|B → G`, and `gateX/gateW = (x_G, 7 + 2)` refer to this `G`.
9. **Envelope.** The parcel clipped to `y ≥ Df` (`clipHalfPlane`, parcel.dart:1161). Full width keeps convex lots
   convex. `envFrontInset = Df`. The massing's front fence run stands on the envelope's FRONT EDGE (`y = Df`, not
   inset by a style setback) with its gap at `[gateX ± gateW/2]` (§6.2), so the fence gap, the plan's gate node and
   the end of the access road coincide.
10. **Entrance.** The door is the gate `G`, which is also `entranceNode` (agent-traffic §8.1: manual sites use
    their gate).
11. **Corridor.** The off-parcel stretch of the access road is the slot's corridor, found by §3.7a in `RoadGraph.of`.
    The plan does not re-search it; at sync it only applies §3.3 row 0c (a built crossed lot blocks the site).

**Worked numbers.** With `yS = 0` (every starter site): `Y` at y = 15, circle y ∈ [2, 28], bays y ∈ [28, 43],
`need ≥ 46`. Spaceport `Dmax = 225`, solar farm 195, farm 100, pump 65: bays fit on all four. A 130 m-deep
installation (`D = 130`, allowed by §3.3 row 1) has `Dmax = 40`, `Df = 40`, no bays, trucks not admitted, and a car
park band `y ∈ [0.3, 34]` (pinned by `installation_access_test`; no `ArgumentError`).

The four starter sites each get a 56 m throat `K→F` across their easement lot, a yard circle with 4 bays, a staff
car park with at least 12 stalls on its connector, and a gate on the fence line at `y = Df`.

**As built (R2 installation track, `installation_access.dart`; pinned by `installation_access_test`):**
- Step 1 on a skewed slot: `T` is placed at frame depth `T.y = max(0, 12 − k)` along the road normal `n`, so
  `|K→T| = (k + T.y)/(n·v)` (exactly `max(12, k)` when `n = v`). The spine always leaves `T` along `v`; within 3° that
  is the straight run, beyond it `T` is the bend. A slot whose normal is more than 60° off `v` gets no plan (a private
  bound, not a §3.7 number). The throat's vias sit every 24 m from `K` (24 and 48 m on a 56 m throat); every other
  access-road, connector and aisle segment gets vias the same way (V8).
- Step 2: the dogleg is R1's corridor polyline exactly. One whose bend `T` does not lie in front of the frontage line
  (`T.y > −1`) gets no plan. The dogleg trusts R1's corridor search (step 11) for its legs' road clearance and does
  not re-test it: a `kJoinOffFrontage` slot R1 did not search (a fabricated one) can yield a plan
  `sitePavingViolations` rejects.
- Step 6: the staff car park is this file's own F3-form packer, not a call into `car_park_packer.dart` (another track's
  file, whose F3 starts from a throat, not a connector). Aisles run along `y` at `x_G ± (18 + 16.4 i)`; aisle 0 carries
  only its far row; the aisle end nodes lie 3 m inside the block pave (`y = 3.3` on the band's front), `C` splits aisle 0
  when both stretches are ≥ 6 m and is its near end otherwise; `k ≥ 2` aisles are joined by cross aisles at both ends,
  `k = 1` ends in two V7(b) T ends; stalls keep 3 m clear of every aisle end. Candidates `k = 1..8` × the block's far
  edge on a 2.6 m lattice (stopping at the first that reaches the target). The candidate holding the most stalls up to
  `clamp(C*, 12, 240)` wins, then the §3.5 score `10·min(n, C) − 2·max(0, n − C) − 0.5·(aisle + connector length) +
  0.02·envelope area` (the target first: on a 780 m field the area term prices each metre of forecourt at 15.6 points
  and stopped the car park at 10 stalls). Starter results: spaceport 2 aisles / 24 stalls / `Df` 46; solar farm and farm
  2 / 14 / 46; pump 1 / 12 / 50.8.
- Step 6 on a skewed throat: the car park band's front is `max(0.3, the throat footprint's highest y at |x − x_G| ≥
  15 on the car park's side)`, so on a lot skewed 50–59° with `k ≤ 3` the block pave starts behind the throat instead
  of overlapping it in front of aisle 0 (the aisle end nodes and stalls move with it).
- Step 9 (with §6.1 steps 2–3 and §3.8): the envelope columns hold one rectangle, so it is the largest frame
  rectangle inside the DepthProfile with its front on `y = Df` that spans the whole gate gap `gateX ± gateW/2`: 0.5 m
  columns from 0.3 m inside each lot line, each column's depth the shallower of its edges, heights swept outward from
  the gate (largest area, ties to the taller); a back edge the exact `containsRect` rejects is pulled in by bisection.
  No such rectangle with both sides ≥ 8 m → no plan (`installationNoFit`). Nothing of the plan lies past `Df`, so no
  pave blocks it. Not the unconstrained `largestFreeRect`: on L lots and triangles that is often a strip beside the
  gate, and requiring it to hold the gate turned 96 of the 196 A1 installation plans into fallbacks; the gate-spanning
  sweep keeps 156, every envelope inside its lot (the remaining 40 have under 8 m of lot behind the gate, or a gate
  gap past a lot line). Pinned by `installation_access_test` (an L lot, a trapezoid, a shallow gate).
- Paves: the throat in two rings split where it crosses the frontage line (the corridor stretch and the lot stretch,
  kerb corners `blend`), one ring per access-road leg, the yard circle's circumscribed octagon, one ring over the bays,
  the connector, and the car-park block. `pavementPt` is slot 0's kerb point moved 1.5 m along the normal; the footpath
  runs from it to the gate. No fence-gap rows yet (R6 dressing).

### 3.7a Access easements (set-back lots behind auto lots)

A set-back lot (§3.2: frontage line > 3.5 m behind the kerb) must cross whatever lies between its street and its
frontage. On the starter kit that is a row of zonable auto lots (§1.1). Layouts stay byte-identical (decision 1), so
no lot is re-platted: the corridor crosses the fewest UNBUILT auto lots, and those lots become access easements.

**Corridor geometry (tier L, `SiteJoinPlacer`, use-free).** For a candidate `s`, the corridor is the polyline
`K(s) → T → F` (the §3.7 dogleg polyline for `kJoinOffFrontage`) with half width `kAccessCorridorHalfM = 7/2 + 1 =
4.5`, restricted to the stretch outside the lot's own polygon. It is tested against:

- **Hard obstacles** (a candidate that hits one is discarded): other MANUAL parcels, via a new public
  `CityLayout.parcelsNear(Box2)` over `_lotIndex` (city_layout.dart:148); and the carriageway + pavement of every
  other road, and of the join road beyond 12 m of `K`, by the `_hitsRoad` distance test. Mirroring `_depthAt`
  (city_layout.dart:1396-1410), it SKIPS `RoadClass.isElevated` roads and any deck stretch where
  `deck.offGroundAt(s, lengthM)` holds (a raised stretch or a tunnel): nothing at grade is there to hit.
- **Soft obstacles** (counted): AUTO lots. A lot counts when the corridor overlaps it by more than 0.05 m.
- **As built (R1):** each corridor leg is a rectangle without end caps. A road hits it when its centreline comes
  within `halfWidth + sidewalkM` (`halfWidth` for a class without pavement) of the rectangle. The join road is skipped
  within 12 m of arc of `s`, and the first leg is tested against it from past its pavement. A candidate is
  best-first: the target crossing nothing ends the search; the choice order is unchanged.

**Candidates** (each quantised to 0.25 m, each with `[s ± m]` inside the slot window and `s` inside the lot span):

1. the clamped target;
2. the centre projection of every auto lot whose corridor at that centre crosses exactly that one lot
   (a 24 m lot holds the 9 m corridor with 7.5 m to spare each side);
3. every side line shared by two adjacent auto lots whose corridor crosses exactly those two (only needed where lots
   are narrower than the corridor + 0.1 m);
4. the target ± 5, 10 and 15 m (hard-obstacle retries);
5. for `kJoinOffFrontage`, the dogleg of each of the above.

**Choice:** discard hard hits, then order by `(crossed auto-lot count, centred ? 0 : 1, |s − target|, s)`, where
`centred` holds for candidates of kinds 2 and 3 and for any candidate crossing no lot. Centring keeps a paved road
7.5 m clear of the neighbouring lots' lines, and a curved-road re-sample cannot tip the count. The result is slot 0:
`joinCrossLot` lists the crossed lots, `kJoinEasement` is set when that list is non-empty, and `kJoinClamped` when
`s` moved. No candidate left → `kJoinCorridorBlocked` at the clamped target with no crossings (§3.3 row 0c).

**Plan-time rules (`SiteAccessBook`, at sync):**

1. **Built crossed lot → blocked.** If any `joinCrossLot` lot is BUILT (a placed or grown building), the site is
   `kerbOnly` + `kPlanAccessBlocked` (§3.3 row 0c). This also covers saves made before this feature.
2. **Unbuilt crossed lots → easements.** When a stored network plan uses a slot whose crossed lots are all unbuilt,
   each is an access easement of that site. The flag is DERIVED and never saved:
   - `SiteAccessBook.easementOf(lotId) → siteId?` is a lookup map rebuilt at sync, never iterated.
   - `CityLayout.easementOf` is a `String? Function(String lotId)?` hook that `CitySim` assigns when it creates the
     book (null in a bare layout, so layout-only tests are unaffected).
   - `CityLayout.setUse(id, use)` returns false for an easement lot and any `use` other than `unzoned`.
     `CitySim.placeOnParcel` refuses it. `advanceParcelGrowth` skips it; a lot zoned before it became an easement
     keeps its saved zoning entry, inert.
   - Its own plan is none (§3.3 row 0a: it never holds a building).
   - The lot inspector shows "access easement for <site name>".
   - The easement lifts at once (`sitesRev++`) when the site is cleared or its plan stops using the slot.
3. **Order.** Sites whose slot 0 carries `kJoinEasement` are checked at the head of EVERY sync walk, outside the
   per-tick check budget (§4.3; their count is pinned by the sprawl audit), so the easement exists in the same tick
   the site's building appears. `CityStarterKit.found`, the town generator and the loading phase end with a full
   drain, so the four starter easements exist before the player can zone.
4. **Signature.** `inSig` includes the crossed lots' built bits in `joinCrossLot` order (§3.9).
5. **Placement refusal.** `claimSite`/`addManualParcel` refuse a new parcel that overlaps a live access corridor
   (`SiteAccessBook.corridorHits(polygon)`).
6. **Honest limit.** An unbuilt set-back site has no plan, so no easement: an auto lot in front of it can be zoned
   and grow first, and the site is then blocked when it is built (rule 1). §10.2 Q12 asks whether to reserve the
   corridor from the slot geometry alone instead.

**Blocked sites on a generated town (R2 integration repair, a §10.2 Q12 input).** The sprawl audit pins
`accessBlocked 65` on the 12-mile sprawl, so 65 set-back sites start with no visible access. Split by cause: **62**
carry `kJoinCorridorBlocked` from slot placement. A hard obstacle (another manual parcel or an at-grade road) crosses
every candidate corridor, and no ordering can help those. 51 of them are medium commercial manual sites. Only **3** (a
station and two `c-med` sites) are blocked by rule 1: the generator zoned and grew the auto lot in front of them before
its closing drain made that lot an easement. Draining between placing manual sites and zoning would move those 3. It
would also change which lots the generator zones and grows, and so every generated town's buildings and the pins
downstream of them. That is not done in R2, and the figure is reported here and in §10.1.

**Starter kit result (pinned by `site_easement_test`):** easements are exactly `{lot-r0x1-l10, lot-r0x0-l0,
lot-r0x0-r1, lot-r0x1-r5}` (spaceport, solar farm, farm, pump), and 78 of the 82 auto lots stay zonable.

**As built (R2, `site_easement.dart` `easementOf`, the pure half):** the union of the crossed lots of the plan's CUT
joins' graph slots (`joinOfRef`), ascending and once, taken per slot: a slot any of whose crossed lots is built
contributes nothing and the plan's other slots keep theirs (row 0c blocks a site on slot 0 itself); none for a
kerbside plan, and for a plan whose `graphStamp` is not the graph's `structureStamp` (its handles name another structure's
joins; the book re-resolves it). A footprint join (`joinRef` −1) names no graph join and carries no easement.

### 3.8 Odd polygons

| Case | Detection | Result |
|---|---|---|
| < 3 vertices, area < 30 m², zero frontage | frame | `none` / `kerbOnly`, legacy slot |
| Sliver (inscribed depth < 8 m or W < 6 m) | profile | `kerbOnly` (as built, R2 core: the TRUE depth D, the profile's deepest column, not an inscribed depth; a pointed or spiky lot runs the generators, which fall back by fit) |
| Triangle | profile tapers | generators run; usually `kerbOnly` below ~400 m² |
| Concave L/U, self-touching | profile + exact `containsRect` | stalls never outside; pockets unused; never crashes |
| Frontage < 2(m + 0.5) | spans empty on that road | side street, other road, then legacy |
| Skewed lot or curved road | frame | throat along the road normal, bend node after ≥ 7 m; a home more than 10° off the normal is `kerbOnly` (§3.3 rule 4) |
| House lot whose slot 0 fails the back-out rules (road, room < 4.0, swing margin) | §3.3 | `kerbOnly` (kerb parking) |
| Piece shorter than `reserves + 12 + 2m` | no window | other road or legacy (counted by the sprawl audit) |
| Join road without pavement (path, alley) | class | kerb = carriageway edge; no kerb-cut mesh; throat still ≥ 7 m |
| Sealed (airless) road | flag | same geometry (rovers); a sealed road has NO pavement, so the pedestrian tube is the only thing a cut can break. **As built (R8, §10.2 Q8 option (a)):** the tube RISES over each drive on its own kerb — 2.3 m of headroom, 1:12 approaches, a box beam on legs that stand clear of the drive — and two holds closer than two ramps merge, so a terrace of drives is ONE continuous raised walkway. A cut on the far kerb, and a far-swing mask, lift nothing |
| Steep draped lot | capture | `siteMaxGrade` flag only (plans never read the ground) |
| Site beyond the road end | §3.2 | `kJoinOffFrontage`, dogleg access road |
| Target moved into the window (junction, dead end) | §3.2 | `kJoinClamped` only; no dogleg |
| Set-back lot behind a row of auto lots | §3.7a | corridor over the fewest unbuilt auto lots; `kJoinEasement`; crossed lots become easements |
| Corridor blocked (manual parcel, at-grade road, or a built crossed lot) | §3.7a, §3.3 row 0c | `kPlanAccessBlocked`, `kerbOnly` |
| Street dead end beside the lot | §3.2 | the cul-de-sac reserve keeps cuts out of the drawn bulb |

### 3.9 Determinism, keys and revisions

- **Seed (plans only; slot placement uses none):** `fnv1a32` over (the program-version constant, the frame's `W`
  and `D` quantised to 0.5 m, the join road's class ordinal, the spec `type`). It is position-free and rename-stable,
  and it is used only for tie-breaks via `xorshift32(seed ^ fnv1a32(tag))`. Honest limit: a curved-road re-sample
  can flip it only when `W` or `D` lies within the re-sample error (a few mm) of a 0.5 m quantum boundary.
- **No** `Random`, `hashCode`, `Object.hash`, `DateTime`, `Stopwatch`, map/set iteration, 64-bit literals or trig.
  `sqrt` is allowed. Hash inputs are ints built from quantised values.
- **Input signature** per site, `inSig = fnv1a32` over:
  - a program-version constant;
  - the polygon (1 cm), the frontage used, `graded`;
  - every slot of the lot (piece's road id, `s`, right, room, flags, and the crossed lots' ids); **as built (R2
    book repair):** the road's class and decoration too, which the seed and back-out rule 1 read and a decoration
    upgrade changes without moving a slot;
  - the BUILT bit of each crossed lot, in `joinCrossLot` order (§3.7a: the one cross-site input);
  - the spec (`type`, `housing`, `jobs`, `siteWidthM`, `siteDepthM`, `siteKind`, group);
  - whether an alley candidate exists (`RoadGraph.hasRearAlley`; **as built, R8:** hashed for EVERY lot, placed or
    not, and the side-street and rear-alley slots themselves only for the plans that take them, side street first).
    Without the bit §4.2's tuple diff would never re-plan for a new alley: an alley drawn behind a built lot moves
    no slot of it, so the diff would re-resolve it and stop there.

  Never utilisation, ground, controls, style or time. The same `inSig` gives the same plan rows, with no
  regeneration. The 1 cm polygon term is change detection only: nothing persisted or tie-breaking hashes a
  coordinate (C-15), so a signature that moves on a load's re-sample regenerates a plan with the same seed, the same
  lattice and the same stall keys.
- **`rev`** (V12) changes only when geometry changes, so a regenerated plan with equal bytes keeps its identity in
  the chunk.
- **Honest limit:** generation is whole-plan, so a changed capacity target can move every aisle of that site and
  renumber its stalls. Keys (V10) let traffic remap. This is an amendment to ask 8 (C-19).

### 3.10 Generation budgets (bench-gated, `test/colony/site_access/bench/`, skipped by default)

| Work | Target |
|---|---|
| `KerbWindows.of` | ≤ 1 µs per piece |
| Slots in `RoadGraph.of` | ≤ +15% of its cost on the sprawl fixture (bench R-B1) |
| `kerbOnly` / `homeDriveway` plan | ≤ 5 µs / ≤ 12 µs |
| `carPark` / `yard` plan | ≤ 60 µs (the integration design's figure; ≈ 15 candidates, profile search, no per-candidate allocation) |
| `installation` plan | ≤ 3 ms |
| Corridor search per set-back lot (§3.7a, in `RoadGraph.of`) | ≤ 200 µs |
| Full drain, 127k-building generated town | `Σ_p count_p × unitBudget_p` over the program mix, ≤ 3 s, inside generation/load progress only |
| Memory | ≤ 1 retained object per 100 sites (§2.3 packing); ≤ 512 B per home site; ≤ 4 KB per 50-stall car park |

**Measured (R2a):** a chunk retains 7 objects at 1, 64 and 1024 sites. The §2.3 column set packs the HOME fixture in
753 B per site, not ≤ 512 B: the site row is about 137 B, two stalls 112 B, and each point 26 B (3 nodes, a 4-point
pave, a 2-point path, door, pavement). `site_access_chunk_test` pins ≤ 768 B. This is a design budget miss, kept
as a deviation. **R2 owns the ≤ 512 B target:** its generation bench measures bytes per home site on the starter kit
and the small town and either meets 512 B (for example with parametric home rows, §10.1) or reports the miss with
the measured figure at R2 review.

**Measured (R2 core, `bench/site_generation_bench_test.dart`, `flutter test` JIT, car park / yard / installation
still stubs so their sites read `kerbOnly`):** on the sprawl fixture (`blocksAcross 4, seed 5, sprawlMiles 12`)
30,561 built sites became 24,996 `homeDriveway`, 5,563 `kerbOnly` and 2 unplanned, in 952 ms in all. That is
19.4 µs per home plan (budget 12) and 35.5 µs per `kerbOnly` plan (budget 5); each figure includes the site frame
and depth profile (about 6 µs) and, for kerbside, the §6.1 free-rectangle envelope (about 4 µs). With the frame
cached, `PlanBuilder` emission of a home plan is 8–10 µs of it (per-row boxed `List<num>` writes). Home demotions on
that fixture: room 154, swing margin 411, skew 36, geometry 107. Bytes: 694 B per home site (budget 512 B: MISSED,
down from R2a's 753 B because the footpath reuses the door and pavement points) and 254 B per kerbside site. **Both
unit budgets and the 512 B home target are missed, and this is reported, not re-budgeted.** At the measured
~31 µs/site average, the 127k-building town's drain would be about 4 s (> 3 s). The levers are typed per-column
buffers in `PlanBuilder` (unboxed), a profile-free kerbside envelope, and parametric home rows (§10.1).

**Corrected (repair round): that ~4 s is a LOWER BOUND, not the Σ this section asks for.** Two things make it low.
While the car park, yard and installation generators are stubs, their sites are costed at the `kerbOnly` figure. And
it is extrapolated from the 30.5k-site sprawl fixture, not measured on the 127k-building reference town. On the
sprawl, the bench now also prints Σ with each stubbed site at the unit budget of the program it was offered (its
`NoFit` demotion counts it). Re-run: 910 ms measured in all; 24,996 homes × 12 µs + 812 remaining `kerbOnly` × 5 µs
+ 4,542 car parks × 60 µs + 62 yards × 60 µs + 147 installations × 3 ms = **1.021 s**. That is 33.4 µs per site, or
**≈ 4.24 s scaled to 127k buildings** (> 3 s). Homes (17.2 µs) and `kerbOnly` (34.9 µs) already run over their unit
budgets, so the real drain will be higher once the tracks land. The drain is re-measured on the reference town, with
every generator in place, at the R2 merge, and the load-time risk is reported to the user then (§10.1).

**R2a-frozen file touched (R2 core):** `PlanBuilder`'s stall sort returns early when the rows are already in
`(seg, s, side)` order. The base comparator breaks ties by index, so ordered rows sort to the identity: output bytes
are unchanged and no API changed (an R2 budget change, no notice line).

**Measured (R2 car park / yard track, `bench/car_park_bench_test.dart` and the core generation bench, `flutter test`
JIT, frames and profiles warm, dispatcher time per written plan):** sprawl fixture 4,423 car parks at 150–215 µs and
44 yards at about 220 µs (a noisy 44-site sample, 110–730 µs); small generated town 106 car parks at about 210 µs; built
town 41 car parks at 220–310 µs. **The 60 µs unit budget is MISSED by about 3–4×**, and this is reported, not
re-budgeted. The sprawl's car parks average 41 stalls, and writing one into `PlanBuilder` (boxed rows, the O(n²)
stall-key collision scan) is about 60–100 µs of that time. Generation, the other part, is branch and bound (§3.5 as
built) with no envelope search on dominated candidates: 1.5 free-rectangle searches per site on the sprawl. The core
bench's measured sprawl drain went from 910 ms to 2.0 s with car parks and yards in place (installations still stubs),
so the load-time risk of §10.1 grows. The levers are `PlanBuilder`'s typed per-column buffers and key index (core), and
per-candidate allocation in the packer.

**Re-measured (repair round, `bench/car_park_bench_test.dart`).** The figures above are dispatcher time per written
plan. That time includes `PlanBuilder` emission (core's), and it was taken over a few hundred JIT-cold calls, which read
3–5× slower than warm code. The bench now also times the packer alone (`carParkPlanOf` / `yardPlanOf`, nothing
written) over exactly the sites the dispatcher offers each program, after 20,000 warm-up calls, best of three. A yard
call includes its car park fallback. Packer time per call:

| Fixture | car park (offered) | yard (offered) |
|---|---|---|
| built town | 11.0 µs (20) | 12.6 µs (21) |
| small generated town | 15.5 µs (143) | 20.3 µs (10) |
| sprawl | 24.7 µs (4,542) | 48.6 µs (62; 59–69 µs on other runs) |

**The packer meets the 60 µs unit budget**, the sprawl's yards only just. Over the same sites, the first landing's
packer measured warm at 18 / 41 / 46 µs for car parks and 600–1,100 µs for industrial sites. Most of that cost came
from a few huge manual lots (solar, refinery), where every candidate packed 1,024 stalls before its door failed V11;
the dispatcher offers those sites to the installation generator, not to these. Dispatcher time per written plan,
including `PlanBuilder` emission, is still 110–270 µs, so the drain risk of §10.1 stands. It is re-measured at the R2
merge.

**Re-measured at the R2 merge (every generator in place, `bench/site_generation_bench_test.dart`, `flutter test`
JIT, one run).** The bench now also plans the 20-mile sprawl (`blocksAcross 4, seed 5, sprawlMiles 20`, the studio
perf town's sprawl setting), which has 118,824 sites and so stands in for the 127k-building reference town:

| Fixture | Sites | Mix (kerbOnly / home / car park / yard / installation) | Measured, all in | Σ count × unit budget (no-fit at offered) |
|---|---|---|---|---|
| sprawl 12 mi | 30,561 | 952 / 24,996 / 4,427 / 40 / 144 | 1.49 s (48.9 µs/site) | 1.005 s (1.022 s) |
| sprawl 20 mi | 118,824 | 4,688 / 102,242 / 10,529 / 900 / 464 | **5.03 s** (42.4 µs/site) | **3.33 s (3.38 s)** |

Unit costs on the 20-mile sprawl, per written plan including emission: `kerbOnly` 19.9 µs (budget 5), home 21.5 µs
(12), car park 125.8 µs (60), yard 124.3 µs (60), installation 309.8 µs (3 ms, met). **The 3 s drain is MISSED** on
both measures: the Σ at unit budgets is 3.33 s, because homes are 86 % of sites, and the measured drain is 5.0 s (about
5.4 s scaled to 127k). This is the load-time risk of §10.1, reported to the user rather than re-budgeted: a generated
town or a load of that size spends about 5 s more in its progress phase. The levers are unchanged (typed per-column
`PlanBuilder` buffers and key index, a profile-free kerbside envelope, parametric home rows).

**Bytes per home site at the R2 merge: 694 B** (starter-sized built town 706 B; kerbside 254 B), against the 512 B
target: **MISSED**. Meeting it needs fewer stored points per home (3 nodes, a 4-point pave, door and pavement at 26 B
each) or parametric home rows, and both change what the frozen R2a columns hold for a home plan, so it is left for the
user's §10.1 decision rather than done inside R2.

**The drain budget is a sum, not a guess.** R1's sprawl audit already counts lots per road class on the sprawl
audit fixture; R2 adds program counts, and the generation bench prints the mix and the sum next to the measured
drain. Illustration only (the mix is measured in R2): 80% homes, 12% `kerbOnly`, 8% car parks and yards, 100
installations gives 101.6k × 12 µs + 15.2k × 5 µs + 10.2k × 60 µs + 100 × 3 ms ≈ 1.22 + 0.08 + 0.61 + 0.30 =
2.2 s. **If the recorded mix makes the sum exceed 3 s, R2 does not raise the budget silently: the added load time
is reported to the user as a visible risk (§10.1) before R2 merges.**

---

## 4. Where plans live, rebuild triggers, save and load

### 4.1 `SiteAccessBook` on `CitySim`

```dart
class SiteAccessBook {                       // CitySim: late final SiteAccessBook siteAccess (lazy, like CityAgents)
  int get sitesRev;                          // moves when any plan appears, goes or changes rev
  List<SiteAccessChunk> get chunks;          // a chunk's identity changes only when one of its sites changed
  int slotOf(String siteId);                 // stable while the site lives; renames keep the slot
  SiteAccessPlan? planOf(String siteId);     // lookup only (a Map used for lookup, never iterated)
  List<String>? changedSince(int sitesRev);  // ring log of the last 4096 changes, stable order; null when too old
  bool sync(CitySim city, RoadGraph g,
      {int maxUnits = kSyncUnitsPerTick, int maxChecks = kSyncCheckUnitsPerTick}); // true when complete
  bool isStale(String siteId);                // queued for a check since the last graph/layout change (§4.2)
  bool isCurrentFor(String siteId, RoadGraph g); // graphStamp == g.structureStamp && !isStale; decidable, same headless and rendered
  String? easementOf(String lotId);          // §3.7a: the site an unbuilt auto lot is an easement for
  void onLotsRenamed(Map<String, String> renamed);  // processed in sorted old-id order; rev unchanged
  void onLotCleared(String siteId);                 // drop now (lifts its easements); sitesRev++
  List<String> corridorHits(List<Vec2> polygon);    // for placement refusal (§3.7a)
}
```

- **Walk order** follows BuildingTable's: manual lots, auto lots, occupied cells, preceded in every walk by the
  sites whose slot 0 carries `kJoinEasement` (§3.7a rule 3). Slots are assigned on first appearance and freed slots
  are reused lowest-first. Slots are not saved, and nothing persisted refers to them.
  **As built (R2 core, `siteContextsOf`):** occupied cells are walked in ascending anchor order, and abandoned cells
  are skipped as BuildingTable skips them. `CitySim.occupiedCells` iterates a set and a map in insertion order, and a
  loaded save can differ from a live town there, which §3.9 forbids. The book orders its cells the same way.
- **The walk is resumable.** The book keeps a cursor over that walk order and a queue of sites to check. Each tick it
  spends at most `kSyncCheckUnitsPerTick` site checks (one `inSig` hash plus lookups each) and
  `kSyncUnitsPerTick` generation units (§4.3), then resumes from the cursor next tick.
- **Chunk writes** are copy-on-write, batched per chunk per sync.
- **Hooks (road side):**
  - `siteAccess.sync(this, roadGraph)` in `advance` immediately before `roadTraffic.advance(dt)` /
    `agents.advance(dt)` (city_sim.dart:1708-1709), so every consumer sees one book per tick and the D35 frame
    hold replays it with the tick; a plan made this tick is visible to agents this tick (pinned by
    `site_access_tick_order_test`);
  - `onLotsRenamed` in `_carryRenamedLots` (city_sim.dart:3626) and beside `agents.onLotsRenamed` at :4890;
  - `onLotCleared` beside `agents.onLotCleared` (:5094).
- **Generator, starter kit, studio and load:** `sync(maxUnits: unlimited, maxChecks: unlimited)` once at the end
  of generation, at the end of `CityStarterKit.found`, and in the loading phase.
- **The capture never generates.** A built site still awaiting its plan is `kerbside` to agents, and legacy to the
  renderer until R7.

**As built (R2 book, `site_access_book.dart`).** The §4.1 API is exact, plus what tests and the dev hook need. Small
deviations, each local:
- **Budget constants live on the book** (`SiteAccessBook.defaultUnitsPerTick = 128`, `defaultChecksPerTick = 4096`,
  `unlimited`): `site_access_constants.dart` is core's to edit and has no `kSyncUnitsPerTick` /
  `kSyncCheckUnitsPerTick`. Units are charged per §4.3 from `classifyProgram`'s offer.
- **Drains.** `CitySim.fromJson` ends with a full drain (`sync(maxUnits: unlimited, maxChecks: unlimited)`), so a
  load re-derives every plan inside the loading phase and the layout reads the book's easements before any UI
  action; `CityStarterKit.found` drains explicitly at its end. The generator has no separate hook: its closing
  `advance(0.1)` runs inside generation progress, and **the first `sync` of a book drains in full** whatever budget
  it is handed (the rule also covers any other colony built without either). (R2 book repair: the load drain first
  rode on the first `advance`, which stalled the first gameplay frame and left `layout.easementOf` unset until then;
  `site_access_persistence_test` now pins the drain before any advance.)
- **Checks.** A site whose `Parcel`, spec and graph stamp are unchanged (identity, or equal values after a re-cut)
  costs nothing. Otherwise the §3.9 signature is recomputed: the lot half (polygon at 1 cm, frontage, side-street
  edge, graded, spec) and the slot half, read straight off the graph's join columns (the road's id, class and
  decoration, `s`, side, dirs, room, flags, the kerb point and normal by their bits so V3 stays exact, the crossed
  lots and their built bits). The class and decoration are there because the seed and back-out rule 1 read them and
  a decoration upgrade moves no slot: hashed by id alone, a live book kept home drives on a newly divided avenue that
  a load re-derives as `kerbOnly` (`site_access_sync_test`, live against fresh). Equal,
  the plan is **re-resolved in place** (`graphStamp`, `graphLot`, `joinRef`, `joinPiece`, `joinRoadNo`; `rev`
  kept, `sitesRev` not moved); different, the site re-plans. Sites whose slot crosses lots are always re-hashed
  (their built bits). The signature is change detection only, never persisted: it hashes word by word, not byte by
  byte. **Limit:** the side-street slot is hashed only into plans that use it (placing it for every corner lot cost
  about a third of the drain); a corner car park, yard or installation inside a dirty box is re-planned instead.
- **Triggers.** A structure change (`structureStamp`) queues the built lots in the dirty box, sorted by id (the
  roads added, removed or changed, by id and samples, and any manual lot new to the graph, whose box covers the auto
  lots it re-cut; inflated by `dirtyReachM` = `max(manualReachM + widest half width, 120 m)`), and restarts the
  resumable walk, which re-resolves every other site: until the walk reaches it, a site outside the box is not stale
  but is not current either (its stamp). A `layout.version` change restarts the walk; a change of the cheap built
  key (placed, grown, grid counts, `CityLayout.useRevision`, `CitySim.siteBuiltRevision`, both new counters)
  re-walks after the walk in flight. A finished walk drops every site it did not see. `siteBuiltRevision` moves on
  every tier crossing and on every building removal that bumps no `layout.version` (burned out, cleared, flattened,
  bulldozed, a zoneless grown cell dropped, a lost lot dropped, a cell abandoned or reoccupied, a grid re-key): the
  counts alone missed a burnout cancelled by a growth start in the same tick.
- **Measured (`bench/site_access_sync_bench_test.dart`, `flutter test` JIT, sprawl fixture, 30,559 plans, generator
  stubs):** drain 1.08–1.35 s; steady tick 0.06 ms; one 1024-site chunk re-pack 1.3–2.0 ms; after a road edit
  (warm) 14–15 budgeted ticks, a first tick of 12.7–17.6 ms and ~10 ms a tick on average (4096 checks, ~2,100
  re-resolutions and 3–5 re-packed chunks). **The ≤ 2 ms road-edit tick is MISSED** (not re-budgeted): the checks
  run at ~2.5 µs each and every re-resolved chunk is re-packed. The graph's own `structureStamp` read after the edit
  costs 23–41 ms more (core's, once per structure change). Levers: fewer checks per tick while only re-resolving,
  re-packing a chunk by typed `setRange` runs, and a stamp hashed incrementally.
  **Design contradiction behind the miss (recorded, for the user, §10.1):** §4.2 step 1 says lots outside the dirty
  box "are not touched", but the contract says otherwise. `isCurrentFor` is `graphStamp == g.structureStamp`, and
  `joinRef` / `joinPiece` / `joinRoadNo` / `graphLot` index the rebuilt graph's columns. So after ANY road edit
  every plan in the town is out of date until it is re-resolved and its chunk re-packed, wherever the edit was. On
  the 127k town that walk is ~127k checks at 4096 per tick: about 31 ticks at ~10 ms each. The
  choice is the user's: (a) accept a town-wide re-resolution spread over ticks, at a lower check budget while only
  re-resolving (≤ 2 ms a tick, but plans away from the edit read kerbside to traffic for longer); (b) make the
  contract edit-local: `isCurrentFor` compares a per-site slot tuple, not the whole-graph stamp, and join handles
  become `(lotId, slot)` resolved through `RoadGraph.joinOfRef` at read time. That is an R2a contract change for the
  Agent Traffic session. Until decided, the book does (a); the R2 integration repair below shapes its ticks.
  **Re-measured at the R2 merge (every generator in place):** sprawl 12 mi (30,559 plans): drain 1.66 s, steady
  tick 0.055 ms, a 1024-site re-pack 3.1 ms, a road edit settles in 14–17 ticks with a worst tick of 18–43 ms
  (the first edit's includes the JIT and an installation re-plan). Sprawl 20 mi (118,823 plans, the 127k stand-in):
  drain 5.5 s, steady tick 0.006 ms, a road edit settles in 50–53 ticks of about 12–15 ms on average, worst 24–36 ms.
  The graph's `structureStamp` read after an edit is 24–29 ms (12 mi) and 79 ms (20 mi). **The ≤ 2 ms road-edit
  tick stays MISSED by about 10×**; a single chunk re-pack alone is over budget, so no budget constant meets it
  without the (a)/(b) decision above.
  **R2 integration repair: option (a) built, no R2a contract change beyond one additive constructor.** Profiling
  the edit ticks on the 20-mile sprawl showed where the time went: re-packing (copies and the GC they cause), then
  the checks, then one-off first-tick work. Five levers, each local to the book:
  1. A chunk whose rows were only re-resolved or renamed is re-published by `_derive`: its `f64`, `f32`, `u8` and
     offset lists are SHARED with the chunk it replaces (neither is ever written), and only `i32` is block-copied
     and patched (`graphStamp`, `graphLot`, `joinRef`, `joinPiece`, `joinRoadNo`). A graph lot's re-resolution
     is recorded as a shared marker and written straight from the graph's join columns at flush, with nothing
     allocated per site. A whole re-pack copies rows in runs, one `setRange` per column per run of consecutive rows,
     and adopts its fresh lists. Both need `SiteAccessChunk.adopt` (§2.3 as built).
  2. A check that recomputes a signature costs 8 check units, and an unchanged site costs 1. A re-resolving walk
     therefore takes about 500 sites a tick, while a built-state re-walk that finds nothing changed keeps its 4096.
  3. A budgeted sync re-packs at most ONE chunk whole (a write or a drop); the site that would re-pack a second
     waits for the next tick. Easement-priority sites and drains are exempt.
  4. The budgeted sync that diffs a structure change does only the diff and the priority sites. The queue and the
     walk start on the next tick. The road diff is one two-pointer pass that also carries each road's signature
     over: a road inserted mid-list had cost a lookup per road, 23 ms.
  5. The walk reads the layout's lot lists as views (restarting if a manual lot is staked without a re-cut),
     starts at most once per sync, and the sites a finished walk did not see are swept in budgeted steps (16 sites
     a unit), not in one 8 ms loop.
  **Measured after the repair** (`bench/site_access_sync_bench_test.dart`, `flutter test` JIT, five edits per
  fixture, the first also warming the JIT). Each tick is classed by whether it wrote or dropped a plan:

  | Fixture | Ticks per edit | Re-resolving ticks: p50 / p90 / max | Over 2 ms | Re-planning ticks: max |
  |---|---|---|---|---|
  | sprawl 12 mi (30,559 plans) | 67–72 (was 14–17) | 0.64–1.12 / 0.97–2.04 / 3.9–6.1 ms (cold first edit 1.67 / 2.4 / 11.3 ms) | 5–11 % (cold first edit 29 %) | 2.1–8.3 ms (cold 18 ms) |
  | sprawl 20 mi (118,823 plans) | 257–260 (was 50–53) | 0.76–1.15 / 0.99–1.79 / 4.0–8.8 ms | 2–7 % | 2.5–6.7 ms |

  Before the repair every tick of an edit ran 12–15 ms (worst 24–36 ms). **The typical tick now meets 2 ms at the
  127k stand-in (p90 under 1.8 ms), but the WORST tick is still MISSED:** 2–7 % of ticks run 2–9 ms.
  **Corrected at the R2 merge review:** the re-planning ticks are over 2 ms BY CONSTRUCTION, not by JIT or GC. A
  budgeted tick may run one whole 1024-site re-pack (measured 1.0–3.3 ms) plus a generator run, and a skeptic's
  re-run measured re-planning ticks at p50 2.1–5.2 ms on the 12-mile sprawl (worst 3.7–17.5 ms) and re-resolving
  ticks at p99 3.0–4.0 ms on the 20-mile one. Meeting 2 ms needs a patch or append into a chunk that does not copy
  all its rows, or re-packs deferred to ticks that do nothing else; the spikes on re-resolving ticks were not
  profiled. The price of (a) is latency: after an
  edit on the 127k town a plan away from the edit reads kerbside to traffic for about 260 ticks, not 50 (legal,
  §4.2 step 3). Option (b) stays open for §10.1. The `structureStamp` hash (79 ms at 20 mi) is left out of the
  tick figures, as before: it is the graph rebuild's cost (the rebuild itself is 5–10 s there), paid by its first
  reader.
  **Built-state latency (recorded, also for §10.1):** the built-state trigger (placed, grown, tier, removal) does not
  queue the site that changed; it re-walks the colony after the walk in flight, at 4096 checks a tick. On the 127k
  town a newly placed or grown building can therefore wait about 31 ticks (a fresh walk) to about 62 ticks (one in
  flight, then its own) for its plan, against §4.3's "placing 500 zoned houses completes in 8 ticks", which holds
  only where the walk is short (the starter kit and small towns drain in one tick). Until then the site reads
  kerbside to traffic (legal, §4.1). The lever, not taken: queue the ids of buildings placed, grown or cleared through
  the `CitySim` hooks ahead of the walk, as the dirty box is.
- **Chunks** are re-packed from published rows (`SiteChunkLayout` + `SiteAccessChunk.packed`, the R2a builder's
  own packing entry points; `site_access_sync_test` pins the re-pack byte-equal to `PlanBuilder.build`), so a
  copy-on-write never regenerates a neighbour. (R2 integration repair: in runs, into lists `SiteAccessChunk.adopt`
  takes; a chunk only re-resolved or renamed shares every column but `i32` with its predecessor, §4.1 below.) An anchor the grid reports twice is walked once.
- **`onLotsRenamed`** is order-independent (every new id is taken from the ids before the call) rather than "sorted
  old-id order": the book may not iterate the map (hygiene), and the result is the same. It re-keys the easement
  LOTS as well as the sites, so a renamed crossed lot answers `easementOf(newId)` at once, not after the next sync
  (R2 book repair). Both `CitySim` call sites (`_carryRenamedLots`, and `_carryLotsAcross` on the claim path) are
  pinned by `site_access_sync_test` ("CitySim rename hooks"): a renamed built lot keeps its slot and `sitesRev` does
  not move, before any sync.
- **An easement-priority site inside the dirty box** is checked as a queued site in the priority pass and leaves the
  queue there, so it is current at once and costs the check budget nothing (R2 book repair).
- **`corridorHits`** tests the sites whose slot 0 carries `kJoinEasement` or `kJoinOffFrontage`: the stretch of each
  cut join's throat outside the site's own lot, within `kAccessCorridorHalfM`. `claimSite` (with or without
  `checkAccess`) and `siteBlockedReason` refuse such a plot.
- **The inspector string** is `CitySim.lotInspectorNote(lotId)` (`access easement for <site label>`), shown by the
  edit overlay when zoning or placing on the lot is refused.
- **Extras:** constructor `generators`, `easements` (the `easementOf` rule, fakes in tests) and `validate`;
  `lastSync` (`SiteAccessSyncStats`), `debugCorridorHits`, `debugRepack`, `sitePlanJson` (the dev hook
  `ext.acro.citygame site=plan&id=`), `CitySim.debugTickProbe` (the tick-order test).
- The refusal half of `site_easement_test` is `site_easement_refusal_test.dart`, so the two tracks' files do not
  collide.

### 4.2 Triggers (cheap O(1) checks decide whether to walk)

| Change | RoadGraph | Lane graph | Plans / `sitesRev` |
|---|---|---|---|
| Junction override, road rename | patched (`sharesStructureWith`) | refresh | unchanged (windows ignore controls) |
| Road laid, removed, split, re-classed | rebuilt | rebuilt, `graphRev++` | slot tuples diffed inside the edit's dirty box only; sites whose tuples changed are queued and re-plan; `rev` moves only if geometry did |
| `layout.version` (re-plat, renames) | rebuilt | rebuilt | re-key renames; new or gone parcels; lots in the re-platted region queued for an `inSig` compare |
| Zoning (`setUse`, no version bump, city_layout.dart:1128) | unchanged | unchanged | nothing until a building exists (easement lots refuse, §3.7a) |
| Building placed, grown past a tier, upgraded, respecced | unchanged | unchanged | that site re-plans; so does any site whose `joinCrossLot` holds this lot (§3.7a rule 1) |
| Utilisation | unchanged | unchanged | unchanged (never an input) |
| Demolished, cleared, burned out | unchanged | unchanged | plan dropped |

The cheap triggers are the traffic ones (city_agents.dart:716-722: `layout.version`, placed/grown/util/cell counts,
lane graph identity), plus a tier-crossing counter bumped where `grownParcels` crosses 0.3/2.0/3.0
(city_sim.dart:4286-4296), plus `RoadGraph` identity.

**No unbudgeted town-wide walk.** A road edit or a `layout.version` bump never compares all 127k sites in one tick:

1. **Dirty-box diff first.** The dirty box is the union of the boxes of the added, removed or changed road pieces
   (and of the re-platted region on `layout.version`), inflated by `max(manualReachM + hw, 120 m)` (the longest
   access corridor). Only lots whose polygon box meets it can have a changed slot tuple; their tuples are compared
   by lot id against the previous graph and the changed ones are queued. Lots outside the box are not touched.
2. **Queued sites are checked at `kSyncCheckUnitsPerTick = 4096` per tick**, plus the generation units of §4.3.
3. **Until checked, a queued site is stale, which is legal (§4.1):** `planOf` still returns its old plan with
   `isStale == true`. Traffic treats any plan with `!isCurrentFor(siteId, g)`, for the `RoadGraph g` it runs, as
   kerbside at `g`'s slot 0 (never at the old joins); `graphStamp` makes this decidable and identical in headless and
   rendered runs.
   The renderer keeps drawing the old plan, so nothing flickers to legacy; its tiles inside the dirty box are re-cut
   by the road edit anyway.
4. **Bench:** a road edit on the 127k-building town costs a worst sync tick ≤ 2 ms (the dirty-box diff and the check
   units included).

**Invariant S1:** a plan change never moves `roadsRevision` or `layout.revision`, which drive the lane graph, the
drape cache and the road tiles (city_sim.dart:452; world_snapshot.dart:2626-2629).

**Invariant S2:** plans read no ground, traffic state, terrain edits, `shapedTerrain`, renderer style or time. A
load regrades from pristine ground and must re-derive identical plans. The one cross-site input is the built state
of the auto lots a slot's corridor crosses (§3.7a), which is saved city state and is hashed into `inSig`.

### 4.3 Per-tick budget (counted, never timed: D9)

Cost units: `kerbOnly` 1, `homeDriveway` 2, `carPark`/`yard` 16, `installation` 128. `kSyncUnitsPerTick = 128`,
and at least one plan runs per tick. Programs are classified first, which is cheap, and the units are charged
before generating. Placing 500 zoned houses completes in 8 ticks. Separately, `kSyncCheckUnitsPerTick = 4096` site
checks per tick bound the signature walk (§4.2). The easement-priority sites (§3.7a rule 3) are checked outside the
check budget, and their count is pinned by the sprawl audit. The benches confirm a worst tick ≤ 3 ms in steady
play and ≤ 2 ms for the sync of a road edit on the 127k town.

**As built (R2 integration repair, §4.1):** a check that recomputes a signature costs 8 of the 4096 check units and
an unchanged site costs 1. A budgeted sync re-packs at most one chunk whole. The sync that diffs a structure change
does only that and the priority sites. The post-walk sweep costs one unit per 16 sites. A sync with either budget
unlimited is a drain and is not shaped. The worst-tick figure for a road edit is still missed (§4.1).

### 4.4 Save and load

- **Nothing new is saved.** `CitySim.toJson` (city_sim.dart:4479-4590) is unchanged. Manual lots already persist
  `poly`, `front` and `graded` (:4552-4563).
- **Load order:** `fromJson` → `recompute()` → `RoadGraph` (slots) → first `advance` → `siteAccess.sync` (full
  drain) → traffic building sync.
- **Traffic saves** lot cars by `(siteId, stallKey)` (§7.5). A site unknown after load drops its lot cars on the
  traffic side.
- **`site_access_persistence_test`** covers the starter kit (easements included), a generated 2-block town, a
  colony after road edits that renamed lots, and 200 curved-road lots. Round trip: `toJson` → `fromJson` → sync.
  - Straight roads keep equal `rev` and stall order per siteId.
  - All 200 curved-road lots keep IDENTICAL stall keys and program (`rev` may differ there because of the millimetre
    re-sample). Keys hash frame-lattice integers (V10) and the seed is position-free (§3.9), so the only way a key
    can move is a seed flip at a 0.5 m boundary of `W` or `D`. Any key change fails the test, and the message
    prints that lot's distance from the nearest boundary, so a fixture that lands on one is diagnosed at once. The
    fixture is fixed, so the result never varies from run to run.

**As built (R2 book).** Two findings, both outside the book:
- A save restores placed buildings only from the utility catalogue (`CitySim.fromJson`), so a zone building PLACED
  on a lot (the built-town fixture, the generator's towns) is dropped by a load. The persistence fixtures therefore
  use GROWN buildings (`town(grown: true)`; the generated town's placed zone buildings are converted to grown ones
  before the round trip). Not a site access defect; reported.
- **R2 core finding:** on the curved-road fixture (324 lots on two S-bend streets), one lot, `lot-r2-r21`, flips
  `kerbOnly` (demotion `homeGeometry`) → `homeDriveway` over a load: the home generator's §3.4 fit decides
  differently on the millimetre re-sample (W 23.28716 → 23.28792 m, D 31.96215 → 31.96174 m, slot 0 unchanged at
  s = 535.5). Every other lot keeps its program and stall keys. **CLOSED at the R2 integration repair:** the cause
  was not `W` or `D` but the house containment test, `profile.containsRect(hx0, yT, hx1, hy1)` flush with the
  polygon; live, every variant failed only that test by under a millimetre, loaded, it passed (the other margins
  are metres). The house rectangle is now tested GROWN by `kContainsInsetM` (0.05 m) on every side (stricter: the
  envelope stands at least 5 cm inside the lot), which moves the decision far beyond the re-sample error; the lot
  stays `kerbOnly` both live and loaded. (The first repair shrank the tested rectangle instead, which admitted
  envelopes up to 5 cm OUTSIDE their lot, e.g. random site `cell-rand-446`; corrected at the R2 merge, and A1 now
  checks every home envelope.) The sprawl audit's demotions did not
  move (no Appendix A entry), and the test now expects no flip at all (`isEmpty`): this section's acceptance is met.
- **Live against loaded (R2 book repair).** Every other case compares two fresh drains. `site_access_persistence_test`
  also syncs `city.siteAccess` in budgeted ticks through a grown house avenue, a road edit that renames lots, a
  decoration upgrade, a tier change and a burnout, then compares every plan per site id (`sitePlanJson`, programs,
  `rev` and stall keys) against `drained(roundTrip(city))`. That is the comparison that catches a live book
  diverging from what a load re-derives.
- **Load order as built (R2 book repair):** `fromJson` → `recompute()` → `agents.restore` → `siteAccess.sync`
  (full drain, inside `fromJson`) → first `advance` (a no-op sync) → traffic building sync. The first gameplay frame
  no longer carries the drain; `site_access_persistence_test` checks the loaded book is complete, byte-identical and
  wired to `layout.easementOf` before any advance.
- **The `lot-r2-r21` pin** became `isEmpty` at the R2 integration repair (above).

---

## 5. Rendering

### 5.1 R0: the orientation fix (blocks everything else)

By reading, and confirmed by a scratch probe that runs the real `Quaternion`/`SurfacePlacement` code,
**every parcel building is drawn with its street face away from the street**:

- `_parcelTransform` spins by `−parcel.heading` (world_snapshot.dart:1888). That puts local +Y on `Parcel.facing`,
  which points toward the street (parcel.dart:1328-1334).
- The generator's street face is local −Y. The front wall is `_Wall(Vector3(0,-1,0))`
  (building_generator.dart:342), and bays and awnings are gated on `w.normal.y < 0` (:404, :430).
- The massing says "local y = −depth/2 IS the curb line" (building_massing.dart:371-373).
- LotFeatures sides with the massing, so signs, fence openings and front aprons are also on the wrong side.

**Test first** (`test/application/site_orientation_test.dart`). For each `(parcel, spec)` of the starter kit
(pump, backwards-wound pad, farm, solar field, warehouse auto lot) and for cells:

- map `q.rotate(0,−1,0)` to colony-local and expect `·parcel.facing > 0.99`;
- where `Parcel.facing == −SiteFrame.v` (auto lots and manual lots with a used stored frontage), also expect
  `q.rotate(unitX)·SiteFrame.of(parcel).u > 0.99` (not a mirror). Frontage-less manual lots and cells assert against
  `Parcel.facing` only in R0; their turn to the effective frontage is R4's (§3.1).

The renderer twin, `test/flutter_scene/building_front_test`, checks that `instanceTransform` applied to
`massing.entrance` lands nearer the frontage midpoint than the centroid.

**Fix (R0, legacy rule of §3.1):** `Quaternion.axisAngle(Vector3.unitZ, −(parcel.heading + π))`, i.e. only the π
flip, still from `Parcel.heading`. Cells get the same fix if their assertion fails. The plan-served rule
(`−SiteFrame.buildingHeading`) is introduced by R4 behind the knob and applies only to `siteSlot ≥ 0`.

**What moves:** every parcel building's quaternion, and screenshots. No mesh digest moves (fixtures hand-build
quaternions).

**As built (R0):** both tests failed before the fix (the drawn spaceport door stood 834 m from its frontage midpoint
against the centre's 450 m), so the stop rule did not fire. The π lives in one helper, `_legacyBuildingSpin`, used by
`_parcelTransform` and by `BuildingSnapshot.ofCityCell` (cells failed their assertion, so they take the spin with
street heading 0, their stored north frontage). `_parcelTransform` also places plat lot patches; they turn π too,
which draws the same centred rectangle. `buildingFootprint`, `lotSetbackFor`, `lotCoverageFor` and `kLotSetbackM`
moved unchanged to `site_envelope.dart` and are re-exported from `world_snapshot.dart`.

**Stop rule (keyed to the renderer, so a downstream compensation cannot be double-flipped):** both
`building_front_test` and `site_orientation_test` must FAIL before the fix and PASS after it. If
`building_front_test` already passes before the fix, some renderer step compensates for the flip: stop, report where
before anything else lands, and do not apply the fix.

### 5.2 Wire (application layer)

`lib/application/snapshot/city_site_frame.dart`:

```dart
class CitySiteFrame {                       // one per colony, by reference (like TrafficGeometry)
  final String colonyId, bodyId;
  final int sitesRev;
  final int geometryStamp;                  // bumps only when some site's siteKey changed
  final List<SiteChunkGeometry> chunks;
}
class SiteChunkGeometry {                  // ≤ 3 retained objects: itself, one Float32List, one Int32List
  final SiteAccessChunk plan;               // the domain chunk, by identity
  // f32 backing, per-family offsets:
  //   ptUp        per point: metres above the body datum radius, along the colony up
  //   stallUp     per stall: pave surface under the stall
  //   siteMaxGrade  diagnostics/overlay only; never read by the sim
  // i32 backing:
  //   siteKey     per site: rev mixed with its quantised heights (tile key term)
  //   siteTile    per site: owning tile cell (§5.3)
}
```

- **Placement:** `WorldSnapshot.sites: List<CitySiteFrame>` (default `const []`), carried by `copyWithEpoch`. In
  agent colonies `CityTrafficFrame.sites` is the SAME object (theirs to add, city_traffic_frame.dart:32).
- **Heights convention:** heights follow the road points' convention. A point is placed by `localToBodyFixed` at
  its radius along the colony up (traffic_capture.dart:22-30).
- **JSON:** `toJson` writes `'sites'` as column lists plus the string table, and `fromJson` rebuilds chunks.
  `fingerprint` excludes it, as it excludes descriptors (world_snapshot.dart:2434-2438). Hand-built frames (studios,
  codec) carry none and draw the legacy way.
- **Caching:** `CitySim.siteGeometryCache` maps chunk identity to `SiteChunkGeometry`, stamped with
  `(groundCacheShaped, groundCacheEditCount, drapeCacheRevision)`.
  - A steady frame costs one identity compare per chunk (127 on the reference town).
  - On a stamp change the heights are recomputed. If every site's quantised heights are unchanged, the OLD object is
    kept.
- **`BuildingSnapshot`** gains `siteSlot` (−1 selects the legacy path), `gateXM` and `gateWM`. Wire keys are
  `ss`, `gx` and `gw`, omitted at their defaults (world_snapshot.dart:1840-1866). They are hashed next to
  `siteKindIndex` in the tile structure key and packed in `CityTileColumns.buildingF/buildingI`.
- **Envelope placement (R4):** for `siteSlot ≥ 0`, `ofParcel` (world_snapshot.dart:1718) places the building at
  `frame.toLocal(envelope centre)`, spun by `−SiteFrame.buildingHeading` (§3.1), with `siteWidthM` = the envelope's
  extent along `u` (local X) and `siteDepthM` = its extent along `v` (local Y). The envelope, the gate
  (`gateXM` along local X, on the envelope front edge at local −Y) and the door therefore share the building's axes
  by construction, for frontage-less manual lots and cells too. Legacy sites keep the §5.1 R0 transform. The ground
  key stays `'lot:<id>'` at the centroid, so no new query is made.
  - **As built (R4 track B, deviations, each local):**
    - **The knob lives here.** Placement happens in the capture, which a renderer worker cannot reach, so the flag is
      `SiteCapture.envelopePlacement` (application) and `CityNodes.siteAccess` is a getter/setter onto it: ONE
      storage, because a frame placed one way and keyed the other draws a building beside its own driveway. With it
      off a served building's position, spin and size are the legacy ones to the bit (`envelope_axes_test`), while
      its slot and gate still ride the wire as R3 left them.
    - **`SiteCapture.placementOf(siteId)`** returns the whole placement (slot, envelope centre, extents, heading,
      gate) in one lookup; `buildingSiteOf` is now a wrapper on it, so the per-building cost is unchanged.
      `CitySiteFrame.buildingHeadingOf(chunk, site)` derives the heading from the STORED frame vector (`−v` in the
      `Parcel.heading` convention, plus π), never from a re-derived `SiteFrame`: a lot re-sampled since the plan was
      made must not turn the building.
    - **Cells** are placed from the envelope centre as a tangent offset (`SurfacePlacement.place`), keeping the
      cell's own reported elevation — the envelope is at most half a cell from where the cell stood, and no new
      terrain query is made.
    - An empty envelope (zero width or depth) keeps the legacy placement: there is nothing to stand on. **That is
      ONE predicate, in `SiteCapture.placementOf`,** which returns null for such a plan — so the building's wire
      `siteSlot` is −1 and the renderer's own test for plan-served (`CityTileMesher.gateOf`: `siteSlot ≥ 0`) reads
      the same fact. Placed one way and drawn the other, a building would be front-aligned and stripped of its car
      park against a legacy footprint that is not an envelope. The case is reachable: `kerbsideEnvelope` returns
      `SiteEnvelope.empty` without a frame, or where `largestFreeRect` finds nothing inside the 1.5 m side setbacks
      (a site frame narrower than 3 m), and `emitKerbOnly` publishes that plan with an interior-point door. The site
      keeps its row in the chunks — only the BUILDING reads legacy; a kerbside plan has no paving to draw.
      Pinned by `envelope_axes_test` over a fixture lot staked with a 2.5 m stored frontage.
- **`RoadSnapshot.kerbCuts`:** a `Float64List` of quintuples (below): the renderer's COPY of the canonical
  `KerbCuts` (§5.5), converted to the snapshot's own drawn arc.
  - Built in the road loop (world_snapshot.dart:2763-2786) from `siteAccess` cut joins.
  - Canonical index arc is scaled to drape arc per road, the rescale `TrafficGeometry` documents
    (city_traffic_frame.dart:67-71).
  - Flipped for reversed roads (`c → L − c`, `side → −side`, `σ → −σ`). Masks are evaluated per entry; only the
    drawn dropped-kerb ranges are merged per side, for meshing.
  - Cached per road on `(sitesRev, drape identity)`, and omitted when empty.
  - The cut half is `joinCutHalfM`: `throatW/2 + kCutFlareM` (1.0 m), and 4.0 m for `homeDriveway` (§3.3). The SAME
    value sizes the drawn dropped kerb and every kerb mask (§5.5).
  - Each entry is a quintuple `(side, c, h, σ, kind)`: centre, cut half, the travel sign of the lane beside that
    kerb (+1 toward larger arc), and `kind` 0 = the dropped kerb of a non-home cut, 1 = a home cut's lot-side kerb
    (dropped kerb and swing mask), 2 = a home cut's far-kerb swing mask (never drawn). Only kinds 0 and 1 are drawn.
  - The conversion (rescale + flip) is unit-tested against the canonical form within 0.5 m (§5.5).

**As built (R3, `city_site_frame.dart`, `kerb_cuts.dart`).** Small deviations, each local:
- **Frame fields.** `CitySiteFrame` also carries `datumRadiusM` and the colony's tangent frame (`up`, `east`, `north`),
  so a renderer places a point as `up·(datum + ptUp) + east·e + north·n` from the frame alone. `SiteChunkGeometry`
  holds `chunkIndex` and, in `i32`, `siteKey` and the book `siteSlot` per site (`CitySiteFrame.locate(slot)` finds a
  building's row). **`siteTile` is not stored:** the application does not know the renderer's tile grid, so the cut
  holds each geometry's cells in an `Expando` keyed by geometry identity and grid (O(1) per unchanged chunk).
- **Cache.** `SiteCapture` hangs off the colony in an `Expando` (as `TrafficCapture` does), not a
  `CitySim.siteGeometryCache` field: the domain holds no application type. Heights rebuild on a chunk identity change
  or a ground stamp change (`groundCacheShaped`, `groundCacheEditCount`, the edit store's identity,
  `drapeCacheRevision`); a rebuild whose keys and heights are unchanged keeps the old geometry. `geometryStamp` is a
  hash of every chunk's site keys and slots AND of the canonical kerb-cut table, so it moves when a cut moves too.
- **Book, additive API (recorded).** `SiteAccessBook.rowOfSlot(slot)`, `SiteAccessBook.graph` (the last synced
  graph: the capture reads road ids and lengths through it and never builds a graph) and `SiteAccessBook.repack(rows)`
  (`debugRepack` now delegates). No R2a-frozen file changed; the JSON and the tile columns read a chunk's typed lists
  through `debugRetained`, as the book's own re-publish does.
- **Kerb-cut cache.** The canonical table is built per (chunk set, book graph), not per `sitesRev` (a re-resolution
  re-publishes chunks without moving `sitesRev`); each road's drawn copy is held per (layout road index, drape points
  identity). A stale plan (§4.2 step 3) maps its `joinRoadNo` through the road ids of the graph it was resolved
  against (the last four graphs the capture saw) to the same road id now, so it keeps drawing its cuts on roads that
  stayed; a cut whose road is gone is left out (the edit re-cut that tile). Cut half widths are not rescaled.
- **Heights before R5.** A pad point stands on the lot's cached `groundFor('lot:<id>')` (cells: `cellGroundRadius`);
  a draped lot's pad point more than 24 m from the centroid takes `groundFor('site:<id>:<point>')` once per plan; a
  kerb point stands on its road's drape at `joinRoadS` rescaled to the drape's plan arc; `blend` is linear. The
  `padDatums` / `corridorDatums` reads arrive with R5. `stallUp` is interpolated along the stall's segment polyline;
  `siteMaxGrade` is the steepest rise over run between consecutive segment points.
- **Gates.** `gateXM = gateX − (envX0 + envX1)/2` (along the building's local X from the envelope centre), `gateWM =
  gateW`; both 0 when the plan has no gate.
- **Measured (`site_capture_test`, `flutter test` JIT).** The steady fixed part (a chunk identity compare per chunk,
  the held frame returned) median ≤ 0.001 ms on the site town (120 sites) and a 6-block generated town (574 sites);
  zero ground queries; no geometry or cut table rebuilt. Two parts scale with the colony and are reported, not
  inside the 0.02 ms: each road snapshot's cut lookup (a list index and an identity compare, ~0.02–0.04 µs a road
  on the generated town) and each building's slot lookup (one book map lookup, ~0.04–0.10 µs a building, against a
  whole steady capture of ~8–47 µs a building). On the 127k reference town that is a few milliseconds of lookups
  in a capture already far larger; not measured there (the R4 A/B owns it).
  - *R3 review:* measured again at 0.09–0.10 µs a building and 0.036 µs a road (JIT), about 12 ms on 127k
    buildings: 0.3–0.5 % of a steady capture of 21–37 µs a building, paid with the knob off too. The test now
    bounds the building lookup under 5 % of the steady capture a building. **R4 gate:** the A/B on
    `tool/measure_city_studio.ps1` confirms it on the reference town; if it shows, `SiteCapture` holds
    `(slot, gateXM, gateWM)` per site id, rebuilt only when the chunk set moves.
- **Held-frame gate (R3 review).** The steady-frame early return also compares the cut-table hash the held frame's
  `geometryStamp` was taken with: the book can swap its graph under unchanged chunks (a deferred budgeted sync after
  a one-way reversal or a road removal, once the capture has already seen the new roads revision), which re-cuts
  `RoadSnapshot.kerbCuts` without moving `sitesRev`, a chunk or the ground stamp.
- **Row check (R3 review).** `buildingSiteOf` serves a slot only when the chunk the capture holds names the same
  site at the book's row; a book that moved since `SiteCapture.begin` (a drop re-packed the chunk) reads legacy
  until the next begin. `sitesSignature` mixes `fnv1a32` of the colony and body ids, not `hashCode`.

**As built (R6): the lot ring and the pad, and which sites traffic manages.** Two additions, both local to the
application's own geometry — the domain chunk, the traffic contract and the JSON shape are untouched:

- **`SiteChunkGeometry` carries each site's REAL parcel polygon and its pad height.** §5.5's fence ring "walks the
  REAL parcel polygon", and nothing else on the wire holds it: `BuildingSnapshot` has the envelope (R4), the plan has
  its frame and its paving, and the renderer may derive no lot geometry of its own (§1.2). So the capture reads the
  polygon once per chunk build — `CityLayout.parcelById`, or `CitySim.parcelForCell` for a grid building — and packs
  it into the geometry's own lists: `f32` gains `[padUp × sites][ring (de, dn) × ring points]` (the ring as
  Float32 OFFSETS from the plan's frame origin, so a millimetre is held anywhere in a colony) and `i32` gains
  `[ringStart × (sites + 1)]`. The geometry still retains exactly two typed lists, `subset` copies the rows a tile
  needs row for row, the JSON round trip is unchanged in shape, and the site key now mixes the pad and the ring to
  the centimetre — so a lot re-platted under an unchanged plan re-keys its tile. No ground query is added: `padUp`
  is the pad datum the heights were already read for. The cost is **8 B a ring point plus 8 B a site** — 40 B on a
  four-cornered auto lot — against the §8.4 line of ≤ 120 B a home site of wire geometry.
- **`CitySiteFrame.agentManaged`** (§5.5 as built): one byte per site ROW of the frame, set by the tile cut from the
  road-side seam and null on a capture's own frame. `isAgentManaged(chunkPos, site)` is what the mesher asks.

### 5.3 Tile cut and keys

- **Gate:** `CityTileBucketer.sitesSignature(snap)` mixes `(sitesRev, geometryStamp)` per colony. It is appended to
  the cut-gate `sig` (city_nodes.dart:823-829), and the detail layer's `structureSig` inherits it.
- **Membership:** each site goes to `tileFor(envelope centre)`, which is its building's tile. Its structural
  surfaces and its building always re-key together, and a 900 m site draws at its owning tile's tier, as a road is
  owned by its middle point. A per-`SiteChunkGeometry` `Int32List` of tile cells keeps the cut O(1) per unchanged
  site.
- **Structure key** (`structureKeyOf`, city_tile_bucketing.dart:815-916): after buildings, each site's
  `siteKey` and flags are mixed in; after each road's `roadHash`, its `kerbCuts`. **Cuts are never in `roadHash`**,
  so placing a building never triggers the instant edited-road path (instant_road_nodes.dart:144-149). A tile with
  no sites and no cuts keys exactly as before. The library doc at :50-52 is updated: lots are still left out, but
  site access is in.
- **Re-cut scope of one plan change:** exactly {building tile, join road's tile}.
- **Tile columns** (city_tile_columns.dart):
  - per tile, a basis plus `sitePts` (e, n, up), `siteI`, `siteF`, and `roadCuts` with `roadCutStarts` beside
    `roadLifts` (:239-240);
  - `toSnapshots()` round-trips exactly;
  - detail jobs pack the sites of gathered buildings by `siteSlot >> 10` → chunk.

**As built (R3).** The knob is `CityNodes.siteAccess` (default off), carried to workers as
`CityMeshKnobs.siteAccess` (its `keyTerms` term appended only when on, as `agentSignals`'). Off, nothing below
happens: `sitesSignature` is not appended to the cut gate, `CityTileBucketer.bucket(siteAccess: false)` cuts no site,
and `structureKeyOf` mixes no site term, so every tile's membership, key and mesh digest are as before
(`city_tile_bucketing_test` "site access keys", `city_tile_mesher_test` pins with the wire fields present). On:
- a site's key term is its book slot, `siteKey` and flags; a building's slot and gate are mixed only when
  `siteSlot ≥ 0`; a road's drawn `kerbCuts` after its `roadHash`, only when non-empty. Until R4 places buildings on
  their envelopes, a site's tile (its envelope centre) can differ from its building's (the centroid).
- **Tile columns deviation:** instead of `sitePts` / `siteI` / `siteF`, a tile carries its sites as
  `CitySiteFrame`s of just its own sites (`CitySiteFrame.subset`: the rows re-packed by `SiteAccessBook.repack`, in
  chunks of ≤ 1024, with their heights, keys and slots copied row for row). A chunk is five typed lists, so it crosses
  to a worker as blocks, `toSnapshots()` returns the same objects (`CityTileMembers.sites`), and R4's mesher reads the
  frozen plan accessors rather than a second packing. `roadCuts` / `roadCutStarts` are as designed; `gateXM`, `gateWM`
  ride `buildingF` and `siteSlot` rides `buildingI`. Detail jobs pack the gathered buildings' sites
  (`CityTileBucketer.sitesOfBuildings` → `siteFramesOf`) while the knob is on.

### 5.4 `SiteAccessMesher` (new, `lib/infrastructure/flutter_scene/city/site_access_mesher.dart`)

A pure static class like `LotFeatures`. Each point goes to body-fixed as `up·(R + ptUp) + east·e + north·n` minus
the anchor. Output uses the existing builders: `featureApron` (road material), `featureSolid`/`featureGlow` and
`featureCars`. It adds no material and no draw.

**Lift stack** (one constants class, pinned so coplanar surfaces never overlap):

| Surface | Lift over its point height |
|---|---|
| Pave on pad; driveway/aisle/access-road ribbons (cut at pave rings) | 0.13 m (`kPaveLiftM`, over the lot patch 0.05+ and slab 0.08-0.10) |
| Stall lines, arrows, bay hatch | 0.13 + `RoadMesher.paintLiftM` |
| Throat over the pavement band | `walkTopLiftM` at the lot line easing to `ribbonLiftM + 0.02` at the kerb |
| Access-road edge kerb (near) | 0.13, with a 0.10 m face |

**Tiers.** A site is "big" when its pave area is ≥ 1500 m² or its access road is ≥ 40 m. A site is "mid-visible"
when it is big or its pave area is ≥ 150 m² (`kMidPaveAreaM2`). Homes (≈ 55–65 m² of drive and pad: 5.2 × 12.2 m
side by side, 3.2 × 17.4 m in tandem, on an auto lot) are not, so the 127k town's mostly-home tiles add nothing at
mid.

| Element | far | mid | near base | detail exterior | detail full |
|---|---|---|---|---|---|
| Access-road ribbons | big (bare) | big | ✓ + edge kerbs | – | – |
| Driveway/aisle/throat ribbons, turnaround pads | big | big | ✓ | – | – |
| Paves (fan-triangulated rings) | big | mid-visible (rings only, no ribbons) | ✓ | – | – |
| Installation gate posts | – | – | big | – | – |
| Stall paint, arrows, bay hatch | – | – | big | small | small + wheel stops |
| Baked lot cars (non-agent, `maxParkedCars > 0`) | – | – | big | small | – |
| Lot fences with gaps, signs | – | – | – | coarse | pickets |
| Footpaths, car-park lamps | – | – | big lamps | ✓ | ✓ |

- `CityTileMeshJob._plan()` (city_tile_mesher.dart:902-941) adds a `sites` step after patches at EVERY tier, not
  gated by `canDetail`/`detailLayer`. This lifts the 300 m gate for big sites.
- Detail columns go through `_addLotSteps` (:968-975) and `_planDetail` (:948-965). The structural half is
  identical with the layer on and off, which keeps `city_detail_layer_test.dart:506-548`.
- **Paves** are convex CCW rings (a generation contract), triangulated as fans.
- **Ribbons** use a local copy of `RoadMesher.ribbon`'s cross-section with point heights and never re-drape
  (D19/D20).

**As built (R4 track A, `site_access_mesher.dart`).** Small deviations, each local:
- **Tiers** are a `SiteDrawTier` (`far`, `mid`, `near`, `detail`) and `SiteDrawSize` (`sizeOf(plan)` measures the
  pave area and the access-road length once). `CityTileMeshJob._plan` adds one `CityMeshStepKind.sites` step at the
  tile's tier, after patches, gated only by `knobs.siteAccess` and a non-empty `CityTileMembers.sites`. The DETAIL
  half (stall paint on small sites) rides `_addLotSteps`, which both a near tile with the layer off and a detail job
  call, so the structural half is identical with the layer on and off, as designed.
- **The throat lift** eases in three parts, measured from the kerb node (`SiteAccessMesher.throatLiftAt`):
  `RoadMesher.cutTopLiftM + paintLiftM` at the kerb, up to `walkTopLiftM + paintLiftM` over the 3 m pavement band,
  then down to `kPaveLiftM` over the next 1.5 m. Holding the walk's top to the lot line and stepping to the pave lift
  there would leave a 14 cm step in the middle of the drive. **Deviation from the lift-stack table above**, which
  gives the ends as `walkTopLiftM` and `ribbonLiftM + 0.02`: the WALK ramps across the same 3 m band, from
  `cutTopLiftM` at the dropped kerb to `walkTopLiftM` at its back edge, so a throat drawn at exactly those heights is
  5 mm under the flags at the kerb and coplanar with them at the lot line — buried for its whole crossing. One
  paint's lift over the walk at every offset is what makes the crossing visible, which is what the row was for.
- **Throat stations.** The plan's own stations are its vias, tens of metres apart on an installation's spine, so the
  two knees of the ease (at `throatRampM` and `throatRampM + throatSettleM` from the kerb) are inserted as stations
  of their own, as `RoadMesher._withStations` does for a dropped kerb. Without them the ribbon is one long slope from
  the kerb and the crossing is drawn nowhere near the heights above.
- **The ribbons are cut at the pave rings**, as the lift-stack row says: a ribbon quad, a turnaround disc wedge or a
  hammerhead triangle whose CENTRE falls inside a ring and which is not lifted clear of it is left out — the ring
  carries that surface, and drawing it twice is a z-fight between two bands over the whole of a drive. The cut is by
  primitive centre, not a true boolean trim, so a primitive that straddles a ring's edge may still overlap it by a
  sliver. A throat's raised crossing is never cut: the exception is "at the pave lift", not "inside a ring".
- **Turnaround pads** come from `nodeTurnKind` / `nodeTurnR`: a circle is a 16-segment disc, a hammerhead a square
  apron of side `nodeTurnR` about the node, aligned to its arm (`nodeTurnHx/Hn`) where it has one.
- **Stall paint** is the line down each side of a bay. An `inline` stall takes none: it lies ON its pad segment (a
  home drive), and there is no bay to mark. Arrows, bay hatch and wheel stops stay with R6, as §9 lists them.
- **Gate posts** stand at `gateX ± gateW/2` about the plan's `kNodeGate` node, on the facade material.
- **Access-road edge kerbs** are a 10 cm face down each edge, on the road material (the road's own kerb is part of
  the sidewalk builder, which a site has none of).
- **The instant path** is a SITE path: `InstantSiteTracker` in the same file, the road tracker's twin, keyed on
  `(book slot, siteKey)`; `CityNodes._syncInstantRoads` draws its pending sites at the near tier into the same body
  node, and retires them on the same "the tile shows its current structure" test. §5.5's line — "instant_road_nodes
  passes the snapshot's `kerbCuts` to `sidewalks`" — is vacuous as the code stands: the instant road path draws the
  carriageway and its piers only, never a pavement, so it has no kerb to drop.

**As built (R6, `site_dressing_mesher.dart`, `site_dressing.dart`).** The tier table above holds, with the dressing
split the way the identity rule needs it and four deviations, each local:

- **A small site's dressing rides the LOT pass, not a site-level detail pass.** R4 put the detail half in
  `_addSiteStep(SiteDrawTier.detail)`, which drew every site of the tile whatever tier its building was at; R6 draws
  a plan-served building's dressing inside `_emitLotFeatures`, beside that building's own fence and sign, at the
  building's own tier. The set is then the same with the detail layer ON (the layer's job runs the lot pass over the
  buildings it gathered) and OFF (a near tile runs it over its own), which is what "detail on/off identity" means
  for dressing; and a block-tier lot gets no dressing, as it gets no furniture. `_addSiteStep(detail)` is gone.
  A BIG site keeps its dressing in the near TILE (§5.4's "near base" column), since no lot pass draws a 900 m site.
- **What each tier draws** (`SiteAccessMesher.emit` / `emitDressing`): near + big — the stall paint R4 drew, plus the
  arrows, the bay hatch, the car-park lamps and the cars in the stalls; detail + small — the same five; detail at the
  FULL tier — the wheel stops as well. Every plan-served lot, big or small, takes its fence ring, its sign and its
  footpaths from the lot pass. **Deviation:** §5.4's table gives wheel stops only in the "detail full" column, so a
  big site's stalls have none; recorded, not fixed — an installation's car park is drawn from further away than a
  0.12 m block reads at.
  **Second deviation, the cars' column:** the table gives baked lot cars as "detail exterior: small, detail full: –",
  but `emitDressing` calls `emit(tier: detail)` at BOTH detail tiers, so the FULL tier draws the stall cars too. The
  dash is not what the legacy `emitLot` did either — it parks cars on the closest lots of all — and a car park that
  empties as the camera walks up to it is the one thing the tier split must not do. Recorded, not fixed: the tier
  table's "detail full" cell for lot cars reads as "small" in the built code.
- **Arrows have no rule in §5.4, so here is the one built:** none on a `homeDriveway` (one car wide, and its car backs
  out, §7.4); one every 18 m along a segment whose lane mode is one-way, pointing along the travel; and on a
  two-way THROAT at least 5.5 m wide (two lanes) a pair just inside the lot line, one in and one out, a quarter of
  the width either side of the axis. `SiteDressingMesher.arrows` returns the poses, so a test counts them without
  re-deriving the rule.
- **The lot cars** (§5.5, §7.5): at the stall pose, one paving lift over `stallUp`, nosed along `stallDir`, the kind
  the seed picks among those that fit the stall length (+10 %), the palette column from the same seed. Occupancy is
  §5.5's `0.25 + (fnv1a32(siteId) % 1000)/1000 · 0.6` in integer per-mille, and WHICH stalls hold a car is seeded by
  `(siteId, stallKey)` — never by index — so a re-plan that keeps a stall keeps its car (`SiteDressing`). At most
  12 a site (the ceiling the legacy `emitLot` kept, carried over as `SiteDressing`'s own) and at most the tile's
  `maxParkedCars`, shared with the kerb cars as one budget. Home pads take them too, on their `inline` stalls: E36 is staged, and T4b turns
  them off (§5.5).


### 5.5 Lot features, kerb cuts and kerb-side dressing

- **`_emitLotFeatures`** (city_tile_mesher.dart:1327-1409) branches on `b.siteSlot`:
  - **`< 0`:** today's code, byte-identical. **(R7: the fence and the sign of it. The car park, its drive, its bays,
    its cars and its footpath are gone from this branch too — see "As built (R7)" below.)**
  - **Plan-served:** no `massing.parking` and no `emitLot`.
    - `LotFeatures.emitFenceRing` walks the REAL parcel polygon and leaves the plan's `fenceGap`s open (every drive
      and footpath crossing, plus the whole front edge for commercial lots). The domain decides what is open, so a
      fence never blocks a plan.
    - The sign stands beside the primary throat at the lot line, `segWidth/2 + 1.5` m to the building side.
- **Baked lot cars:** placed in stall-index order, nose along `stallDir`, with occupancy
  `0.25 + (fnv1a32(siteId) % 1000)/1000·0.6`. This replaces `b.id.hashCode` (:1383), which is not the web's value.
  They respect `maxParkedCars` and `_carBudget`, and skip any site traffic publishes as agent-managed: a per-site
  `agentManaged` bit in `CitySiteFrame`, set from the traffic-published set of agent-managed site ordinals and folded
  into the tile key. E36 is staged: T4a turns baked cars off only on agent-managed sites (destination lots with a
  live network); home pads and kerbs keep baked cars until T4b brings residents' cars, then E36 completes.
- **`RoadMesher.sidewalks`** (road_mesher.dart:861-908) gains `cuts` and `arcOffset`. With no cuts it is
  byte-identical. Otherwise, for each cut `[s0, s1]` on a side:
  - stations are inserted at `s0 − 1.0, s0, s1, s1 + 1.0`;
  - the kerb-edge lift eases from `walkTopLiftM` to `ribbonLiftM + 0.025` across the flare, holds, then ramps back;
  - the kerb face follows it (2.5 cm tall across the cut);
  - the walk band uses `CityTextureBakes.roadConcrete`.
- **`RoadMesher.verges`** (:761-815) drops grass over `[s0 − 0.5, s1 + 0.5]` and tree pits within 4 m of a cut. The
  yaw counter still advances, so every other tree is unchanged.
- **`StreetFurniture.emit`** (street_furniture.dart:116-173) and street trees: a slot where
  `KerbCuts.blocked(dropped, side, arc, upstreamM: 2.0, downstreamM: 2.0)` holds consumes the same random draws and
  skips placement. `placed` is not incremented, so every other prop is byte-identical. Furniture, verges and lamps
  read dropped kerbs only (kinds 0 and 1), never the swing masks: a swing is on the carriageway, not the pavement.
- **`curbParkingFor`** (city_tile_mesher.dart:2374-2407): a car is skipped when `KerbCuts.parkingBlocked(side, arc)`
  holds, the SAME asymmetric form traffic's kerb masks use (§7.5), so a baked kerb car never stands in a home
  back-out's swing path. The `placed.isEven` alternation still advances.
- **Lamps:** a station inside a cut moves to `KerbCuts.shiftOut` (the cut end + 1 m). `CityLighting.lamps`
  (city_lighting.dart:106-142) calls the same function.
- **Instant path:** `instant_road_nodes.dart` passes the snapshot's `kerbCuts` to `sidewalks`.
- **`KerbCuts`: one canonical form, per-caller conversions.**
  - **Canonical:** per road, entries `(side, c, h, σ, kind)` (§5.2) in the road's INDEX arc measured from its first
    control (the arc `joinS` uses). `side` is 1 for the kerb right of the first → last polyline; `c` is the join's
    `s`, `h` its `joinCutHalfM`; `σ` is the travel sign of the lane beside that kerb (on a two-way road +1 on side 1
    and −1 on side 0; on a one-way road the road's own direction on both kerbs). Built once per `sitesRev` from the
    book's cut joins:
    - every cut join adds its lot-side kerb (`side = joinRight`): kind 0, or kind 1 for `homeDriveway`;
    - a `homeDriveway` join whose `joinDirs` allow a far-direction back-out (a 1+1 street, §7.4) also adds the far
      kerb beside the reverse edge's lane: kind 2.
  - **The asymmetric form.** `KerbCuts.blocked(entries, side, s_i, {upstreamM, downstreamM})` is true when some
    entry on that side has `−(h + upstreamM) < σ·(s_i − c) < h + downstreamM`. Upstream and downstream are measured
    along the travel of the lane beside that kerb, so the upstream side flips with the served travel direction on
    that side. With equal extents it is today's symmetric `|s_i − c| < h + x`. `KerbCuts.shiftOut` moves a station to
    the cut end + 1 m.
  - **Kerb parking** (`KerbCuts.parkingBlocked(side, s_i)`) evaluates every entry with its program's extents:
    kinds 1 and 2 (`homeDriveway`) at `(upstreamM: 12, downstreamM: 3)` (`kHomeSwingUpM`, `kHomeSwingDownM`), the
    traffic session's swing mask `[T − 12, T + 3]` in travel terms on each served side; kind 0 (every other program)
    at the symmetric `(3.25, 3.25)` (`kKerbMaskM`). Because the cut half is added as it is today, a slot CENTRE near
    a home join is masked over `(T − 16, T + 7)` (h = 4.0), so no kerb-car body (half length ≤ 3.7 m) reaches
    `[T − 12, T + 3]`. A kerb car in the swing path would block every departure (§7.4).
  - **Traffic** kerb slots convert their edge travel arc `T` and "right of travel" to the canonical `(s, side)`
    per edge direction (`s = T` on a forward edge, `s = L − T` and the side flipped on a backward edge), then call
    `parkingBlocked`.
  - **Renderer** (`sidewalks`, `verges`, `StreetFurniture`, `curbParkingFor`, lamps) calls the same functions on
    `RoadSnapshot.kerbCuts`, its copy rescaled to drape arc and flipped for reversed roads (§5.2): `curbParkingFor`
    calls `parkingBlocked` (it no longer uses its own 3.7 m bay half), the others `blocked` over kinds 0 and 1.
  - **`CityLighting`** works on domain polylines, i.e. index arc: it uses the canonical form directly.
  - **Tests:** each caller's conversion is unit-tested, and A12 asserts that traffic's masked intervals and the
    renderer's skipped kerb cars agree within 0.5 m (the bounded index-vs-drape error, §10.1), not bit for bit, both
    through the same asymmetric `parkingBlocked`.

**As built (R4 track A).** Small deviations, each local:
- **The walk keeps its own texture across a cut.** `walkRibbon` is the sidewalk material, which has no
  `roadConcrete` band to take; the concrete over the pavement is the THROAT ribbon's, which rides one
  `RoadMesher.paintLiftM` over the walk at every offset across the band (§5.4's as-built throat lift), so it is the
  surface that is seen there. Only the kerb EDGE drops
  (`RoadMesher.kerbTopLiftAt`, `walkTopLiftM` → `ribbonLiftM + 0.025`, eased over the 1 m flare, `min` where two
  cuts overlap); the back of the walk keeps its height, so the flags ramp across their width, which is what a
  dropped kerb is. The kerb face follows the edge down and is 2.5 cm across the cut, as designed.
- **`RoadMesher` takes `cuts` and `arcOffset`** on `sidewalks`, `verges` and `lamps`, `StreetFurniture.emit` and
  `CityTileMesher.curbParkingFor` likewise. `arcOffset` is the arc of the span's first point along the whole drawn
  road (a road cut into graded spans by its decks dresses each span separately). With no cuts every one of them is
  byte-identical (`kerb_cut_test`).
- **`StreetFurniture.place` gains `dryRun`**: a blocked slot draws exactly the random values it would have drawn and
  stands nothing, which is what keeps the props after it byte-identical. `placed` is not incremented, as designed.
- **`curbParkingFor` counts a masked bay against `placed`** — the doc's "the `placed.isEven` alternation still
  advances" — so a masked bay costs its budget and the cars either side of it stay on the kerbs they were on.
- **A column shifted off the end of its span clamps to the end.** `RoadMesher.lamps` resamples the moved station on
  the span it is drawing; a cut near a span boundary (routine on a road the decks cut into graded spans) puts it past
  the span, and the old code left the column standing in the dropped kerb — the one case the shift is for.
- **`CityLighting.lamps` is untouched this slice.** It has no production caller (tests only), its car-park masts are
  track B's (§6.2), and the drawn street lamps are `RoadMesher.lamps`, which does take `shiftOut`. The domain-side
  `shiftOut` call stays available for whoever wires that function to a caller.
- **Knob discipline:** the tiles read `RoadSnapshot.kerbCuts` only when `CityMeshKnobs.siteAccess` is on, so a frame
  carrying cuts draws exactly as it did with the knob off (`city_tile_mesher_test`, all four tier digests).

**As built (R6): the plan-served branch, the fence gaps, the sign and the agent-managed seam.**

- **`_emitLotFeatures` branches as designed.** A building with `siteSlot ≥ 0` whose site the request CARRIES takes
  `SiteAccessMesher.emitDressing` — the fence ring on the real parcel polygon with the plan's gaps, the sign beside
  the throat, the footpaths, and (for a site its own tile does not dress) the paint, arrows, hatch, lamps, wheel
  stops and stall cars — and nothing of the legacy path: no `massing.parking`, no `emitLot`, no rectangle fence.
  A served building whose site the request does NOT carry (a hand-built fixture frame, a tile cut without sites)
  falls through to the legacy path, which is what it drew before, so no existing digest moves.
  **The branch is gated on `knobs.siteAccess` like `_addSiteStep`** (R6 repair, `_siteOf`): production never builds
  a knob-off request that carries sites — `CityTileBucketer.bucket(siteAccess: false)` buckets none and
  `CityDetailLayer.requestFor` passes `const []` with the knob off — but a hand-built one would otherwise draw the
  plan's dressing while the structural pass drew nothing, which is neither the legacy lot nor the plan's. The knob
  discipline is now one rule in both places, and a test builds exactly that request.
- **The fence gaps are DERIVED, not stored** (`SiteDressing.fenceGapsOf`, domain). §2.3 has the `fenceGapEdge/T0/T1`
  columns and the builder writes them, but NO generator emits any (R2 as built), and adding them now would move
  every plan's `rev` — its site key, the `site:<id>:<rev hex8>` corridor brushes §6.3 keys terrain edits by, and
  every digest downstream of them, which is R2's ground and C-14's pin policy. So where a plan carries no gap rows,
  its gaps are computed from the plan itself: wherever a segment or a footpath crosses an edge of the real parcel
  polygon, that stretch is open — the segment's half width plus 0.5 m either side, stretched by the crossing angle
  (a crossing flatter than ~11.5° opens no more than a hard angle would), merged per edge, carried onto the next
  edge when it overruns a corner. A plan that DOES carry rows wins, so the generators can take this over later with
  no renderer change. The rule is the domain's, which is what "the domain decides what is open" is for.
- **The ring stands 0.12 m inside its own lot line**, so two neighbours' fences are 0.24 m apart rather than in one
  plane; the winding is read off the ring's own signed area, so either winding gives the inward side.
- **The sign** stands where the primary throat crosses the lot line, `segWidth/2 + 1.5` m to the BUILDING side (the
  envelope centre's side) and 1 m inside the line, facing the street. A kerbside plan has no throat, so its sign
  stands beside its footpath at the same offsets. `LotFeatures.emitSign` is called with zero half extents, so it
  stands exactly there instead of at a rectangle's corner.
- **`LotFeatures.emitFenceRun`** is the legacy `emitFence`'s own run, lifted out: the fence ring walks the polygon
  with it, so the pickets, the rails and the chain-link panel are the same geometry a legacy lot has, and
  `emitFence` still draws its three edges with it, byte for byte.
- **The agent-managed skip is a ROAD-SIDE SEAM** (the traffic slice that publishes the bit is not on `dev`):
  - `CityNodes.agentManagedSites` is a nullable static hook,
    `Uint8List? Function(WorldSnapshot snapshot, CitySiteFrame sites)`, **null by default = nothing managed**. Its
    bytes are indexed by SiteAccessBook SLOT, nonzero where traffic manages the site, a slot past the end reading 0 —
    the traffic session's own convention for `CityTrafficFrame.agentManaged`.
  - It is read ONCE a frame on the UI thread (`CityNodes.agentManagedOf`, only while the `siteAccess` knob is on),
    handed to the cut (`CityTileBucketer.bucket(agentManaged:)`) and to the detail layer's want. A worker never
    reads a static: the bit rides `CityTileSite.managed` into the tile's key and `CitySiteFrame.agentManaged` on the
    subset frame the request carries.
  - **Keyed only when set** (`structureKeyOf` mixes a constant for a managed site), and the cut gate's signature
    gains a term only when some byte is set (`CityTileBucketer.agentManagedSignature`, hashed once per list
    identity). With no seam every tile keys exactly as it did; flipping one site's bit re-keys that site's tile
    alone, and nothing else. **"No byte set" means the list too, not only a null** (R6 repair): a list of zeros
    hashes to 0 and is skipped, so a seam installed while traffic manages nothing — the state the T4a merge lands in
    before its first managed site — adds no `|m<sig>` term and costs no whole-colony re-cut. Pinned by
    `site_detail_dressing_test`: the empty list, a null, a zero-length list and a 4096-zero list all sign 0, and a
    cut with the quiet seam matches the cut without it tile for tile.
  - A managed site bakes **no lot cars**; everything else it draws is unchanged. E36 stays staged: home pads and
    kerbs keep their baked cars until T4b (§5.5 above).

**As built (R8): the sealed world's tube crossings.**

A sealed road has no pavement — `city_tile_mesher.dart`'s `walked` is `paved && cls.hasPavement && !road.sealed` — so
on an airless world there is nothing for a dropped kerb to drop: the sidewalk, the verge and their dressing are all
off, and the only thing a kerb cut can break is the pedestrian tube. Until R8 the drive ran into the side of a glass
barrel and over its 20 cm curb at both ends.

- **`PedestrianTube.emit` takes `cuts` and `arcOffset`**, the same frame and the same pair of arguments
  `RoadMesher.sidewalks` reads, passed from the same call site four lines below the kerb parking's
  (`city_tile_mesher.dart`). **With no cut that reaches the span the output is byte-identical** to what it was, which
  is checked in `kerb_cut_test` on the positions of both builders.
- **Only the tube's OWN kerb counts.** The barrel runs down ONE verge — side 1, right of the first → last polyline —
  so a drive that breaks the far kerb crosses nothing, and a far-swing mask (`kindHomeFarSwing`) breaks no kerb at
  all. Both are ignored, as the pavement's own dressing ignores them.
- **The profile.** Each drawn cut on that kerb holds `[c − h − 1.0, c + h + 1.0]` level at `crossLiftM` (2.45 m), with
  a 1:12 approach either side (29.4 m). Two holds less than two ramps apart are MERGED, so the tube stays up between
  them rather than sagging (§10.2 Q8). The ramp corners are inserted as stations
  (`RoadMesher.withStations`, made public for this — it was `_withStations`), so the lift is piecewise linear in arc
  and the barrel bends where the ramp bends and nowhere else.
- **What carries it.** With cuts in reach the flat curb strip becomes a box beam 0.35 m deep — top, soffit and two
  faces — so the raised stretch has an underside and the touchdown is one surface rather than a step (at grade the
  beam's underside is simply in the ground, and its face is the curb face the tube never had). Pairs of legs hold it
  1.15 m either side of the barrel's axis, 0.15 m into the ground, wherever the deck stands at least `legMinLiftM`
  (0.8 m) over the CURB LINE — a deck top 1.0 m over the drape and a soffit 0.65 m over it — which is the hold plus
  `legRunM` (19.8 m) into each approach.
- **Where the posts go, and why they are not the road's vertices.** `PedestrianTube.legArcsOf` computes the arcs
  first and `emit` then inserts them as stations of its own, the way it inserts the ramp corners. A post may not
  stand in a drive, so `legClearM` (2 m) either side of every drawn cut is shut — with equal extents the mask is
  symmetric, so the lane's travel sign cancels and the shut stretch is exactly what `KerbCuts.blocked` reports. A
  pair stands at each EDGE of every shut stretch and the clear runs between them are divided EVENLY into steps of at
  most `legSpacingM` (7.5 m). So the longest unheld stretch of deck is one drive's opening and its clearance —
  12.0 m for a house's 8 m drive — and nothing else. **The first cut of this was wrong and is the R8 repair:** legs
  were placed only where the polyline already had a vertex, and skipped when that vertex fell in a drive, so a fused
  terrace drawn at ten-metre stations stood on four PAIRS of posts with 38 m of level deck on nothing, and a lone crossing on
  a road drawn at 25 m stations (the zoo's own sealed street is drawn at 100) got no post at all. Leg arcs are now
  measured, at five station densities, in `kerb_cut_test` and in the tile in `road_tool_mesh_test`.
- **What `legClearM` buys at the post, not at the station.** The post's CENTRE is held 2 m clear of the cut, and the
  post is `legHalfM` (0.16 m) thick along the road too, so its nearest corner stands **1.84 m** off the drive's edge.
  That is the figure §8.3's R8 test asserts.
- **Nothing else moved.** `RoadMesher.withStations` is a rename only. No pinned digest moved and there is no Appendix
  A row: the only cut-carrying fixture (`city_tile_mesher_test`) is not sealed, and the road zoo's sealed street
  carries no cut — which is exactly why R8 adds a fixture that carries both (§8.3 R8). That fixture's own pin was
  re-taken once inside R8, by the repair above (`0xa96767cb` → `0x3c455708`): the posts moved, and the pin is one
  slice old and has never been on `dev`, so it is a first pin and not an Appendix A re-pin.
- **What it costs, and where.** The beam runs the WHOLE span once any crossing reaches it, not only the raised
  stretch: that is what makes the touchdown one surface instead of a step, and at grade it also gives the tube the
  curb FACE it never had. Measured where anyone can re-run it — `kerb_cut_test`'s 'what a crossing costs' asserts
  these four numbers — `PedestrianTube.emit` ALONE over 400 m of street drawn at ten-metre stations, no cut against
  a terrace of three drives plus a lone fourth: **328 → 1606 vertices and 560 → 1680 triangles**, so **+1278 v and
  +1120 t** for two crossings: a fused terrace 98.8 m end to end (40 m of hold and two 29.4 m ramps), of which 79.6 m stands at least `legMinLiftM` up and is carried on twelve pairs of posts, and a lone 68.8 m bridge on eight. The whole TILE around that
  street — §8.2's zoo case, which also carries the carriageway, the kerbside and its parked rovers, and which clips
  the road to its own extent — goes **5294 → 6068 vertices and 3132 → 4000 triangles** over ALL groups. That second
  pair is the honest tile figure; the first pair is the tube's own, and the two are different measurements of
  different things. The §8.4 reference town is not a sealed world and carries no tube at all, so
  no budget line there moves; on a sealed colony the cost is four curb faces where there was one, plus a pair of
  posts at most every 7.5 m of raised deck.

**As built (R7): the legacy half is gone, and what an unserved lot keeps.**

`LotFeatures.emitLot` is deleted, with its call site, its bay/aisle/driveway/footpath constants and its quad helper;
`BuildingGenerator._parking` and the `ParkingLot` it drew are deleted, and with them `BuildingMassing.parking`,
`BuildingMassingRules._lotFor` / `_lampGrid` / `parkingSpaceM2`, `GeneratedBuilding.lampPosts`,
`BuildingGenerator.lampHeightM` and `ArchitectureStyle.parkingBehind` (a car park that does not exist cannot go in
front of or behind anything). `BuildingMassingRules.parkingSpaces` STAYS: it is the capacity target §3.3 packs a plan
for (C-13), and it is now the only thing in the massing that knows a building attracts cars.

Decided per case, since "the design says otherwise" only where it does:

| Lot | What it drew before | What it draws now | Why |
|---|---|---|---|
| Plan-served (`siteSlot ≥ 0`, the knob on — every built lot of a played colony) | nothing legacy since R6 | unchanged, to the byte (the R4 knob-ON pins did not move) | the plan already owned it |
| Unserved parcel building (`siteSlot < 0`: a site the book has no plan for, a request cut without sites) | fence, sign, and a massing car park with its drive, bays, cars and footpath | fence and sign | §9's R7 row: massing parking goes for parcel buildings AND cells. A lot with no plan has no drive the domain will vouch for, and the commonest reason a built lot has no plan is that it has no access — `kPlanAccessBlocked` (§3.3 row 0c) — where a drive drawn across the lot line leads nowhere. Pinned by `site_detail_dressing_test` ("an UNSERVED lot keeps its fence and its sign, and lays no paving") |
| Grid cell | the same | the same | as above; a cell that fronts a road gets a plan like any lot (§10.2 Q10) |
| The knob OFF | the whole legacy drawing | the legacy drawing less the car parks | the knob is the perf A/B (§8.4), not a shipping mode. It is no longer a picture of `dev`, and §8.4's R7 table says what that costs the comparison |
| Building studio preview | the massing's car park, and a "parking N spaces" readout off it | no car park; the readout is now `parkingSpaces(spec)`, the DEMAND its plan would pack for | the studio previews a massing, and the massing no longer lays one |

**What an unserved building also loses is depth of its own car park's strip — which it gains as building.** A legacy
massing gave up to 55 % of its buildable depth to `parkArea`, and `buildD` is now the whole strip. So an unserved
building is bigger and lower than it was (`building_generator_test`: a spec that attracts cars keeps its whole strip;
`city_nodes_test` and `building_generator_test` both had to be re-fixtured, because what separated their tiers was the
car park, not the building). This is the same change R4 made for plan-served buildings (§6.2), applied to the rest.

**And one thing nobody sees any more: the car-park lamp masts of an unplanned site.** `CityLighting.lamps` kept a
legacy derivation for a site without a plan (§6.2 as built, R4); it re-ran the massing to find `ParkingLot.lampPosts`,
which no longer exist. A site with a plan lights its plan's `lampPt`s, as it has since R4; a site without one has no
car park to light, so it takes no masts (`city_lighting_test`, both halves).

---

## 6. Massing coupling, terrain and heights

### 6.1 The domain envelope

`SiteEnvelope` is built by the generator in `SiteFrame`. Its axes are the frame's, and a plan-served building is
spun by `−SiteFrame.buildingHeading` (§3.1), so envelope x/y ARE the building's local X/Y:

1. `foot = buildingFootprint(parcel, spec)`: the unchanged rule, moved to `site_envelope.dart`.
2. `free` = the largest frame-aligned rectangle inside the `DepthProfile`, outside every pave, ribbon, gate lane
   and a clearance around them (1 m for lots, 3 m for installations). It is a maximal rectangle in a histogram of
   free depth, O(columns).
3. The envelope is `free` shrunk uniformly to hold `foot` where it fits, centred, with an `A_min` check (§3.3).
   `claimsOwnSite` installations use `min(spec site, free)` inside `y ≥ Df`.
4. `gateX/gateW` are where the primary drive crosses the envelope front edge, with width `segWidth + 2`. There is
   exactly ONE, deliberately, and a second gate on a second road is closed rather than deferred (§9's R8 row).
   Only an installation opens a gate at all: `kNodeGate` is set in exactly one place in `lib`
   (installation_access.dart:248), and `gateX/gateW` are carried only from there (:687 on the plan, :786-787 on the
   envelope). It lays that one gate off slot 0, like every other generator (installation_access.dart:199).
   Reaching §3.3 row 1 takes `spec.siteKind != building` or `claimsOwnSite && min(W, D) ≥ 150`
   (site_program.dart:172-183), and no `kZoneSpecs` entry does either — a zoned or grown building declares no site
   metres (`claimsOwnSite` is `siteWidthM > 0 || siteDepthM > 0`, city_building_spec.dart:135) and is a
   `SiteKind.building` — so a lot never GROWS into an installation. Every spec that can reach row 1 declares a site
   of its own, 300 m to 4200 m across (city_building_spec.dart:261-545), and the generator, the starter kit and the
   player's stake tool all stake those through `CityLayout.addManualParcel` (city_sim.dart:5218,
   city_starter_kit.dart:193-249), which sets neither `roadId` nor `sideStreet` — both of which
   `SiteJoinPlacer.sideStreetSlot` requires (site_join.dart:639; `addManualParcel` at city_layout.dart:1067-1078).
   A staked installation therefore has no side-street slot to hang a second gate on: slot 2 does not exist for it.

   **One route is NOT closed by geometry**, and it is written down rather than claimed away, because a "can never"
   that rests on a default is the reservation that gets reopened first. The city-edit utility tool drops the held
   spec straight onto an EXISTING parcel (`applyToParcel`, city_edit_overlay.dart:186-205 → `CitySim.placeOnParcel`,
   city_sim.dart:4544), and a subdivided plat lot DOES carry `roadId` and a `sideStreet` (city_layout.dart:1320).
   Such a lot must still clear row 1's fall-through, `W ≥ 60` and `D ≥ 120` (site_access_constants.dart:388-389),
   and the road tool's lot sliders run to 80 m of frontage and 120 m of depth at their maxima
   (road_tool_panel.dart:119-120 → `ParcelSettings` at road_tool_controller.dart:715-716 → city_layout.dart:1253-1254;
   the 24 × 32 m of city_layout.dart:48-49 is only the default). So a player who pushes both sliders to the top,
   cuts a corner lot on an open block, and hand-places a `field`/`pit`/`pad` util on it can in principle stand an
   installation on a lot that has a side street. Nothing the game GENERATES does, the gate would still be laid off
   slot 0, and a second gate would buy a second gate lane and a second fence gap in the massing for a case a player
   has to build on purpose. That is what the closure rests on — not impossibility.
5. **The door** is the midpoint of the envelope's street (front) edge, `y = envY0` (the chamfer corner nearer the
   side street on a corner lot); installations use the gate `G`, which lies on that edge (§3.7). Placing the building
   at the envelope centre is NOT enough on its own: today `_massIn` centres a footprint of depth
   `footD = coverD·buildD` (`coverD` 0.70–1.0 from `rnd`, building_massing.dart:462-469) at
   `buildCentreY = frontEdge + buildD/2` (:542-544), with the entrance at `buildCentreY − footD/2` (:707), i.e.
   `(1 − coverD)/2 · buildD` behind the front edge (≈ 2.7 m on an 18 m home envelope, tens of metres on
   installations). So plan-served massing is FRONT-ALIGNED (§6.2), which puts the entrance on the envelope's front
   edge exactly, with no style input (S2 holds).
6. **The footpath** runs from the door to `pavementPt` (its projection onto `y = 0`, or the gate), 1.5 m wide. It
   moves to the nearest gap between stall rows rather than crossing one, and never runs along a throat.

**As built (R2 core, `site_envelope.dart`, shared by every generator):**
- `SiteEnvelope` holds the `env*`, `envFrontInset`, `gateX` and `gateW` columns, in frame metres.
- `largestFreeRect(profile, W, blocked:, clearanceM:, yMin:, xMin:, xMax:)` is step 2. It is a histogram of free depth
  over the 0.5 m columns, one pass per candidate front (`yMin` and each blocked rectangle's far edge + the clearance).
  Ties go to the smaller front, then the smaller x.
- `fitFootprint(free, footW, footD, minArea:)` is step 3: centred across, FRONT-aligned (§6.2), and null under 8 m a
  side or `A_min`.
- `envelopeDoor(env)` is step 5. `lampsAlong(x0, x1, y)` is the §3.5 lamp rule. `depthOver(profile, x0, x1)` is the
  true depth §3.3/§3.4 measure.
- A kerbside plan's envelope is the free rectangle inside the 1.5 m side setbacks, fitted to `buildingFootprint`
  (the free rectangle itself when 8 × 8 m does not fit). Its door is that envelope's front midpoint (the polygon's
  interior point when there is none). Its pavement point is slot 0's kerb point moved `kPavementPointInsetM = 1.5`
  along the slot normal, which covers footprint sites too (V11's 3.5 m, pinned by `site_plan_generator_test`).

### 6.2 Massing inside the envelope (only for `siteSlot ≥ 0`, so the legacy path is untouched)

- **Domain massing.** `massFor(spec, parcel, {seed, SiteEnvelope? envelope})` (building_massing.dart:302): the
  extent is the envelope rectangle, `parkArea = 0` (:431-447, :538-547, :707-719), `_lotFor` returns null
  (:2248-2276), and `_installation`'s `parkW` is ignored (:2153-2155). **(R7: `parkArea`, `_lotFor` and `parkW` are
  deleted outright — no massing lays a surface car park, plan-served or not, so this row is now the only rule there
  is. See §5.5 as built, R7.)**
- **Front alignment (envelope != null, i.e. `surfaceParking: false`).** `buildCentreY = frontEdge + footD/2`
  replaces both branches at :542-544, so the entrance `buildCentreY − footD/2` (:707) equals `frontEdge`. In both
  the domain `massFor` and the renderer's `parcelOf`, the extent handed to the massing is the envelope inflated in
  depth by the style's `frontSetbackM + rearSetbackM` and re-centred (below), so `frontEdge` IS the envelope's front
  edge and the plan door needs no style input. Stepped,
  tower and podium volumes keep their offsets relative to `buildCentreY`. Installation massings set
  `entrance = (gateX, frontEdge)`. The legacy path (envelope == null) is byte-identical.
- **Renderer massing.** `BuildingMassingRules.surfaceParking` (default true).
  - `BuildingArchetype` (building_generator.dart:1487-1523) gains `surfaceParking` and `gateBucket` in `==`/key,
    read from the snapshot by `BuildingLibrary.get` (:1550-1568) and `archetypeOf/specOf/parcelOf`
    (city_tile_mesher.dart:2164-2235).
  - The digest test's key string (city_tile_mesher_test.dart:489-491) omits them, so legacy digests hold.
- **Min-fit bucketing** for plan-served buildings: `k = round(x/b); if k·b > x + 0.25: k = floor(x/b)` (≥ 1). Today's
  round-up can overshoot the lot by 3 m (building_generator.dart:1500-1501, :1527-1531).
- **Setback and bucket alignment:** `parcelOf` inflates depth by `front + rear` (:2203-2204), so the massing's
  `frontEdge` maps to the envelope's front edge only once the instance is shifted. For plan-served buildings
  `instanceTransform` (city_tile_mesher.dart:2243-2252) adds
  `offsetY = −(frontSetbackM − rearSetbackM)/2 − (envelopeDepth − bucketedDepth)/2`: the first term centres the
  buildable strip, the second keeps its FRONT on the envelope front edge when min-fit bucketing shrank the depth.
  The detail layer uses the same function. With front alignment above, the drawn entrance lands on the plan door.
- **Installation gates.**
  - A private `_fenceRun(x0, x1, y, gate)` replaces the front fence run of the solar farm (:814-823), aquifer
    (:1430-1444) and spaceport (:2032-2046), leaving `[gateX ± gateW/2]` open. For plan-served installations the
    front run stands on the envelope's front edge (local `y = −envelopeDepth/2`, not inset), which is the plan's
    fence line `y = Df` holding gate node `G` (§3.7 step 9).
  - Any volume in the gate lane (`gateW` wide, 12 m deep) is dropped, applied after `_clipToParcel`.
  - With no gate the volumes are byte-identical.
- **`CityLighting`** car-park masts come from the plan's `lampPt` (city_lighting.dart:145-165), no longer from
  re-running `massFor`. That removes the fifth lot line.

**As built (R4 track B).** The rules above all hold; five deviations, each local:

- **One switch, not two.** `massFor(spec, parcel, {int seed, SiteGate? gate})`: a non-null `SiteGate` IS
  "plan-served", and it carries the only number the massing cannot derive — where the drive crosses the front edge.
  There is no `BuildingMassingRules.surfaceParking` field and no `SiteEnvelope` parameter: the envelope already
  reaches the massing as the parcel `parcelOf` inflates by the style's setbacks, and two ways of saying the same
  thing can disagree. `BuildingGenerator.generate` and `BuildingLibrary.get` take the same `gate`;
  `BuildingArchetype` keys `surfaceParking` (`gate == null`) and `gateBucket` as designed, the gate quantised to the
  metre and packed under 2^21 (`gateBucketOf` / `gateOfBucket`), so a mesh is shared only by buildings whose gate is
  cut in the same place. `BuildingArchetype.bucketOf(x, b, minFit:)` is the min-fit rule, used by the key and by the
  instance shift alike.
- **The re-centre is done in the massing.** A plan-served `_massIn` puts its buildable strip at
  `[−envD/2, +envD/2]` instead of `[frontEdge, rearEdge]` — the same span, moved by `(front − rear)/2` — so the
  massing's own origin IS the envelope centre. It has to be: the centred massings (installations, fields, pits,
  aprons, the railway's two ends) sit at that origin and would otherwise draw `(front − rear)/2` off their gate and
  their fence line. `instanceTransform` therefore carries only the bucketing term,
  `offsetY = (bucketedDepth − envelopeDepth)/2` with both depths inflated, which is the designed formula with its
  first term already spent.
- **The gate lane is opened on the finished volumes**, not by a `_fenceRun` in each installation's own list: a
  volume standing in the lane is dropped, and a thin axis-aligned run ACROSS it is cut into the two pieces either
  side (`_openGateLane`). One pass opens every fence line there is — solar farm, aquifer, spaceport and anything
  later — and none of the eight nominal-coordinate lists has to learn about plans.
  - **The same pass stands that fence line on the envelope's front edge** (the rule above, and §3.7 step 9). Each
    installation lays its fence out in its OWN nominal metres, inset from the plot it fills and scaled with it, so
    the run the gate is cut in stood behind the plan's fence line `y = Df`: measured on `envelopeTown()`, solar farm
    2.00 m, aquifer 3.38 m, spaceport 7.49 m — the drive would have ended that far short of the gap it is drawn to
    pass through. `_frontFenceLine` finds the front-most thin run standing across the gate lane and `_onFrontEdge`
    moves that line out: the run along the frontage stands with its OUTER FACE on `y = −envelopeDepth/2` (it has to,
    or its own thickness would stand outside the envelope, so its centre is half its 0.12–0.15 m thickness inside),
    and the runs into the lot that met it are lengthened to reach it, which keeps the fence's front corners closed.
    A massing whose fence is already on the edge, and every massing with no fence across its gate (the starter
    farm), is returned untouched.
- **A plan-served massing is clipped to the envelope** (`_clipToEnvelope`, 0.05 m of floating-point tolerance) the
  way `_clipToParcel` clips to the lot line. The street massings fit by construction, but an installation lays its
  yard out in NOMINAL metres and overhangs its plot by a few (measured: one volume of 90 on the aquifer, none on the
  starter kit's four) — and for a plan-served building that overhang is its own driveway. With the min-fit bucket
  (never more than 0.25 m over) this is what makes `envelope_containment_test` hold at 0.30 m.
- **`CityLighting` switches on the PLAN, not the knob:** a site with a published plan takes its masts from
  `lampPt`, and a site without one keeps the legacy derivation. `CityLighting.lamps` has no renderer caller (the
  tiles light their own roads), so nothing drawn depends on the knob here, and the domain keeps no flag of the
  renderer's. **(R7: the legacy derivation is deleted — a site without a plan has no car park to light. The switch
  is the same one, with nothing on its other arm.)**

**As built (R7).** `BuildingArchetype.surfaceParking` KEEPS its name and its place in the key, and it keeps meaning
`gate == null`. It no longer says anything about a car park — no archetype has one — but it still separates a
legacy-massed building from a plan-served one, which are still two different shapes (front alignment, the min-fit
bucket, the gate lane, the envelope clip), and renaming a key term moves nothing but the diff.

### 6.3 Terrain

`CityTerrainShaper.pending` (city_terrain_shaper.dart:173-362) gains a third section after the road corridors, since
brushes compose in record order:

```
for each plan of a GRADED parcel (cells: never):
  for each throat/driveway/accessRoad segment i with a point off the pad (ptHRef != pad):
    key = 'site:<siteId>:<rev hex8>:<i>'; skip if shapedTerrain has it
    skip unless  (the segment has an off-parcel stretch longer than max(sidewalkM + 0.5, 3.0) m)   // manual and
                                                                  // installation access roads; §3.7's 3.5 m set-back rule
             or  |padDatum - kerbDatum| > 0.25 m                  // the ONLY clause an auto-lot throat can meet:
                                                                  // it crosses just the 3 m sidewalk off-parcel
    TerrainBrush.cutFill(start/end on the segment, radiusM = width/2 + 0.5,
                         datum start/end = SiteGrade.radiusAt(t, padDatum, kerbDatum),
                         falloffM = min(roadFalloffM, clearance), minVoxelM = colony voxel)
```

- **`padDatum`** comes from the pad brush. `markShaped` (:542-554) also records
  `city.padDatums['pad:<id>']` (transient, like `corridorDatums`, city_sim.dart:3312-3323). Before shaping it is
  `groundUnder(centroid)`, which is what the pad is cut to (:252).
- **`kerbDatum`** is the road corridor's datum at the join, interpolated from `corridorDatums['road:…']`, or
  `groundUnder(kerb)` for an ungraded road.
- **Ramp:** `ptHT = 1` at the kerb node, falling linearly to 0 at the first node at least
  `max(throat length, 6 m)` inside the lot line (auto lots). On a set-back lot (§3.2) the ramp is exactly the
  off-parcel stretch instead: `ptHT` falls from 1 at `K` to 0 at the frontage node `F` on the lot line, and every node
  from `F` inward is `pad`.
- **Keyed by `rev`:** a re-plan cuts a new corridor and leaves the old one, the same trade roads make (:297-301).
- **Scope:** sprawl lots are `graded: false` and add no brushes. Flat downtown graded lots cross only the sidewalk
  off-parcel (3 m < 3.5 m), stay under the 0.25 m tolerance and add none. The starter kit (manual parcels default
  `graded: true`, city_layout.dart:1063) adds four corridor runs: each site's `K→F` throat (56 m off-parcel); its
  on-parcel spine is all `pad`.
- **Ground-query discipline:** the shaper asks at most 2 `groundUnder` per new segment (deduplicated by `asked`).
  The capture makes no new queries in steady state (§6.4).

**As built (R5, `site_grade.dart`, `CityTerrainShaper._siteCorridors`).** The shape of §6.3 holds — a third section
after the road corridors, one `cutFill` per corridor segment, keyed by `rev`, graded parcels only, `padDatums`
recorded by `markShaped` — with these deviations, each measured, each recorded because a centimetre of it shows in
the §6.4 probe:

- **The ramp is DERIVED, not stored.** The generators emit no `ptHT` ramp: a throat's vias and its frontage node `F`
  are `pad` points, and only the kerb node and two pave-ring corners are `kerb`/`blend` (installation_access.dart:470,
  :483). Putting the ramp into the plan would move every plan's `rev`, every site key and every digest downstream of
  them, which is R2's ground and C-14's pin policy. So `SiteCorridorRun.of(plan)` derives it: the corridor segments
  are the drives and access roads with a point off the pad, walked from each CUT join's kerb node, and `t` falls
  linearly by arc from 1 at that node to 0 at the far end of the chain. On a set-back lot that chain IS the
  off-parcel throat `K → F` — §6.3's rule exactly. On an auto lot it is the drive, whose far end is a pad node, which
  is §6.3's "at least `max(throat length, 6 m)` inside the lot line" wherever the drive is that long and gentler
  where it is not.
- **`kerbDatum` is `groundUnder(K)`,** not the road's `corridorDatums` interpolated at the join. The ground at the
  kerb node IS the road's cut surface there, plus whatever else composes over it, and asking it makes the corridor
  tie into what is actually there with no model gap. One ground read a site — the whole site section's budget, and
  under §6.3's two a segment.
- **Anchored on the GRADE, not on the ground** (`dirOf(a) * d0`, the deck corridor's rule), with
  `maxCutM = max(40, |d1 − d0| + deckCutMarginM)`. A brush reads a point's place along its chord in three dimensions;
  anchored on ground metres off its datums the chord tilts and every point along it reads further on than it is. That
  alone was **0.82 m at 22 m along the spaceport's throat and 1.64 m at 52 m**.
- **The shoulder is 1.0 m, not 0.5** (`SiteGrade.corridorShoulderM`): the throat's pave ring runs `width/2 + 0.5`
  either side of the drive, so half a metre put its corners exactly ON the levelling edge, where a hair outside costs
  a centimetre of the ease — the whole probe budget.
- **`falloffM = min(roadFalloffM, halfM, clearance − halfM)`** — §6.3's `min(roadFalloffM, clearance)` with the
  `roadFalloffM` half tightened to the corridor's own levelled half width (`siteCorridorFalloffM`, the CAP) and the
  clearance measured per segment (`CityTerrainShaper.siteCorridorClearanceM`, the R5 review's round 2 — see below).
  Sites stand shoulder to shoulder and a six-metre ease reaches nine metres from the chord: a street car park's drive
  eased over the solar farm's throat 8.9 m away and pulled it **3.8 cm** off the grade it is drawn on. The capture
  reads back one corridor's own datums, not the whole composed field, so a neighbour reaching into a corridor is a
  drawing error, not a softer edge.
- **Meshed fine where it cuts** (`minVoxelM = _fineVoxelM(halfM)` past the new `siteCorridorReliefTolM`, default
  0.5 m), not §6.3's colony voxel. A mesh cannot hold an eight-metre cut at fifteen metres — the same finding, and
  the same rule, as a road cut through relief. Its own tolerance because it is judged differently: a road's corridor
  against the ground it was laid over, a site's against the two heights it grades between, which are known without
  asking the ground five times a segment. On the dev kit this takes the renderer's near view from **2 refinement
  targets and 0 boosted leaves to 10 and 10** (`road_corridor_mesh_test`); a generated 4-block town's set-back
  installations add 2, and a 2-block town none.
- **The pad is RE-cut after the roads** (`sitepad:<id>:<rev hex8>`, the same `padPoly`, the same datum), for a site
  whose corridor is cut. A road corridor eases `roadFalloffM` past its kerb, which on a slope is inside the lot
  line, and it is recorded after the pad: the platform edge the plan's paving is drawn on had been taken with it —
  **1.13 m on the dev kit's one street car park**, a figure R4 saw (−2.17 m at (−8, −288)) and attributed to the
  throat. Anchored on the platform, so it asks the ground nothing; a lot no road reaches is untouched, and on flat
  ground no site is cut at all, so a generated downtown block still adds none. **On FLAT ground.** A town founded on
  real relief is cut freely: at the dev colony's own site a 2-block generated town takes **32 corridor segments** and a
  4-block one **123**, because on a hillside a downtown drive meets the 0.25 m clause. The
  brush-count figures above and in §8.4 are the flat ones, and they say which sites are cut by GEOMETRY, never that a
  generated town's ground is the same with site shaping and without it. It is not, and the R5 review's round 2 is
  what that difference was hiding.
- **Settled apart from `shapedTerrain`** (`CitySim.shapedSites`, keyed `site:<id>:<rev hex8>`). A key in
  `shapedTerrain` stamps the ground cache (`groundCacheShaped`), and a downtown lot that needs no cut must not clear
  a colony's thousands of cached ground reads to say so. The walk itself is gated on the book's `sitesRev`
  (`CitySim.siteShapedRev`) and, inside it, on a parcel lookup before any key is built: a sprawl is tens of thousands
  of draped lots this walk passes over whenever the book moves.
- **The corridor count on real ground.** §6.3 says the starter kit adds four corridor runs, and on flat ground it
  does, exactly (`site_terrain_test`). On the dev colony's hillside it adds **five**: `lot-r0x0-r0`'s drive meets the
  0.25 m clause, which is what that clause is for. The pinned figure is the flat one — it is the geometry, not the
  relief, that the four are about.

**Repaired after the R5 review (the same files, the same slice).** Four findings, each measured:

- **The corridor is levelled IN PLAN, not by projecting onto its own chord** (`TerrainBrush.planLevel`, new, and
  used by nothing else). `cutFill` placed a sample along its run by a three-dimensional projection, which is right
  wherever the ground is near the grade — a road's corridor, whose datums ARE the ground at its knots. A site's
  corridor is the other case: it drops a whole platform cut over the length of a throat, and past about a metre of
  fall per metre along, a sample offset radially from that chord projects to a far-off place along it, where the
  lateral test rejects it. **The ends were cut and the middle was not.** The dev kit's throat falls 0.74 per metre
  and came out right either way, which is why one founding pinned nothing: founded in the Alps (46.5, 8.0) the same
  throat falls 1.61 and left 27 to 82 metres of hillside standing through the drive, drawn **77.7 m** buried at
  lot-m0's (52, 264); in the Andes (−13.2, −72.5), **156.3 m**. In plan the projection is the same for every sample
  on one radial, so the levelled surface is the grade however steep it is — and it is the fixed point of the 3-D
  rule, which is what lets the capture read the cut back arithmetically (§6.4 as built). After it, every plan point
  of the kit at those two foundings stands within **1.6 mm** of the ground the shaper cut under it
  (`site_ground_probe_test`, which now probes three foundings, not one).
- **The kerb datum is asked at the run's KERB end** (`SiteCorridorRun.kerbAt`: the endpoint at the top of the
  derived ramp), not at the first corridor segment's first point. Nothing in §2.3 fixes which way a plan stores a
  drive, and the ground under the wrong end would grade the whole corridor backwards, by the depth of the platform.
  The generators happen to store every drive kerb-first today, so this is a latent one, pinned by a fixture stored
  both ways.
- **§6.3's cut clause is per SEGMENT**, as it is written here ("the segment has an off-parcel stretch longer than
  …"), not summed over the run: a corridor that leaves its lot in several short stubs, none longer than the pavement
  it crosses, is one the design says to leave alone. The DECISION stays the whole run's, because the ramp is derived
  along the chain and half a cut run would draw the rest of itself on datums nothing cut. No site of the starter kit
  or of a 2- or 4-block generated town changes hands either way — it is the rule that was wrong, not the towns.
- **`padDatums` keeps the pad's own key only.** `markShaped` recorded every `padPoly`, which included the site
  section's own re-cut (`sitepad:<id>:<rev hex8>`); nothing reads those, and one accumulated per site per plan
  revision in a map that is never swept.

**Repaired after the R5 review, round 2 (`CityTerrainShaper._siteCorridors`): the clearance is a real clearance.**

One finding, blocking. The cap above is not a clearance, and the brush's ease is a full-weight edit at the levelled
edge falling to nothing `falloffM` further out: at a drive's 4.0–4.5 m half width the ease reached **8–9 m from the
chord**, well past the lot line of any generated town. What it moved out there is ground a NEIGHBOUR's paving is
still drawn on — its own pad datum, cut before this corridor and never put back, since the site section records each
lot's `sitepad:` re-cut ahead of the corridors. **R5 buried paving it did not cut.** Measured over towns generated at
the dev colony's founding (lat −45.03, lon 168.66, `CityGenSpec` seed 1, sprawl 2 mi), the same capture both sides,
paired point by point against the town's own shaping with only the `site:` brushes withheld from the ground:

| Town | Plan points worse | Worst |
|---|---|---|
| 2 blocks | 26 of 1,032 over 1 cm | **1.248 m** — `lot-r2x0-l3` pad pt 2 at (−70, −18), 0.000 m → 1.248 m under its own platform. `lot-r2x0-l4`'s corridor runs 5.28 m away at `halfM` 4.0 and eased to 8.0 |
| 4 blocks | 147 of 3,739 | **41.044 m** — `lot-m16` (the quarry) pad pts 31–32 at (1370–1381, 502): its own corridor's ease filled 41 m of the pit its plan is drawn in. Then 2.526 m at `lot-r1x1x0-r4` pad pt 9 and 2.241 m at `lot-r2x1x1x0-r5` pad pt 11 |

**§6.3's `clearance`, taken literally** (`siteCorridorClearanceM`, and the ONLY new geometry): per segment, the plan
distance from its chord to the nearest OTHER graded parcel's boundary, over `CityLayout.parcelsNear` in plat order
(no hashing, no iteration order, a box no wider than the ease can reach), and
`falloffM = max(0, min(cap, clearance − halfM))`. The ease now stops at the lot line and keeps the cap wherever there
is room. Two readings of "clearance" are recorded because both were measured:

- **A lot the chord runs THROUGH is not a clearance from it.** Measured from its boundary it reads as a hard zero,
  and a set-back throat crosses a row of unbuilt access easements ON PURPOSE (§3.7a) — it is the lots BESIDE them
  whose ground it must leave alone. Without this reading every starter-kit throat loses its verge and becomes a
  vertical-walled trench up to 40 m deep, and the four throats are exactly what the R4/R5 orbit screenshots frame.
  Sampled every 2 m along the chord, the same way `SiteCorridorRun` measures its off-parcel stretch.
- **A segment that runs ON the lot it serves has no clearance at all,** and its ease is 0. Every metre beside such a
  segment is this site's OWN platform, levelled to `padDatum` and re-cut under `sitepad:` just above — before this
  corridor. A house drive climbing its front garden pulled its own lot's paving **2.18 m** under the ground that way
  (`lot-r3x1x1x0-l4`, 4 blocks), and the quarry's own corridor is the 41 m row. Measured by the chord's ON-parcel
  length (`SiteCorridorRun.segOffParcelM`, already computed), not by a lateral distance to the lot line: a set-back
  throat ENDS on its own lot line, which laterally reads as a hard zero, and there — at the pad end of the ramp —
  the corridor's datum IS the pad's and its ease moves nothing.

**What it changes, brush by brush** (`site:` falloff, before → after). The starter kit's four utility throats keep
the full 4.5 m, flat and on the dev hillside alike — **nothing about the kit's four sites is redrawn**. The fifth
corridor the dev hillside adds (`lot-r0x0-r0`, the street car park's drive, the 0.25 m clause) goes 4.0 → 0, and so
does every downtown auto-lot drive of a generated town: 29 of a 2-block town's 32 corridors, with its three set-back
manual sites (`lot-m0`, `lot-m5`, `lot-m22`) keeping the cap. A drive that runs on its own lot is now cut with a
square edge where the lot's own platform meets it.

**What that costs, measured (round 2 review).** Stopping the ease at the lot line stops it papering over the step
between two lots' platforms, so a corner of a NEIGHBOUR's paving within a few centimetres of a shared lot line can
be left standing off the ground where a neighbour's ease used to cover it: on the 4-block town 11 plan points read
further off than before, worst `lot-r3x1x1x0-l4` pad point 10 at (144, −95), 0.156 m → 1.151 m, every one of them
within 0.2 m of a lot line and 14–25 m from its own corridor. Net the change is a large improvement — points over a
centimetre off the ground fall from 67 to 43 (2 blocks) and 572 to 437 (4 blocks), with 26 and 167 points better by
more than a centimetre — and no pad INTERIOR is buried (the reviewer's 472 and 2,019 sample probe: worst 3.4e-5 m).
The platform step at a lot line is a §6.4 item, not the corridor's: the remedies are to record the `sitepad:` re-cut
AFTER the corridors, or to compose platform edges where two lots meet.

After it, no plan point of any graded lot of either town stands further from the ground than it does with the site
corridors withheld: worst **+0.055 mm** (2 blocks) and **+0.068 mm** (4 blocks), against 1.248 m and 41.044 m before
(`site_neighbour_ground_test`, §8.3). The §6.4 probe is unmoved to the digit — 9.6 mm on the dev colony, 0.35 mm in
the Alps in the shaper's basis, 37.6 mm under the drawn point — because the kit's own corridors did not change.

### 6.4 Heights (ask 6)

| Point ref | Graded parcel | Draped parcel |
|---|---|---|
| `pad` | `padDatums['pad:<id>']` if shaped, else the cached `groundFor('lot:<id>')` (world_snapshot.dart:2900, :2923) | within 24 m of the centroid: cached `groundFor('lot:<id>')`; farther (big draped sites only): one cached `groundFor('site:<id>:<k>')` per point, paid once per `rev` |
| `kerb` | the join road's drape radius at `joinS` (`drapeCache[roadId]`), no lift (joins are never on decks, V1) | same |
| `blend t` | `SiteGrade.radiusAt(t, pad, kerb)`, read back from `corridorDatums['site:…']` where a corridor was cut: the drawn height equals the graded ground | linear blend |
| Via points off the pad on draped sites (long access roads) | – | one cached `groundFor('site:<id>:<k>')` per via point (vias ≤ 24 m apart), paid once per `rev`; house lots never have any |

- `ptUp = radius − datumRadiusM`, and `stallUp` is the pad under the stall.
- **Heights are render and pose only:** simulation lengths are 2-D (`segLenM`), as road `s` is index arc.
- The capture flags `siteMaxGrade` when `|pad − kerb|/length > 15%`. It is diagnostic only, and plans never
  change for slope (§10 Q7).

**Measured at R4, and why the starter kit's throats do not yet read as connected on a hillside.** With the knob on,
the city-game dev colony (lat −45.03, lon 168.66 — rolling forest) was probed for every plan point: the drawn height
against the ground under it. Inside each parcel the paving sits on the ground (the pad brush cut the platform, and
`pad` is that datum). The **off-parcel throats do not**, by −12.9 m to **+41.6 m**:

| Site | Worst point (colony-local) | Drawn − ground |
|---|---|---|
| lot-m0 (spaceport) | (28, 264) — the 56 m throat | **+41.57 m** |
| lot-m1 (solar) | (28, −276) | +21.42 m |
| lot-m2 (farm) | (−60, −295) | −12.91 m |
| lot-m3 (pump) | (−28, 144) | −7.58 m |
| lot-r0x0-r0 (a street lot's home drive) | (−8, −288) | −2.17 m |

This is the design working as written, not a drawing bug: a `blend` point is the straight line from the pad datum to
the kerb datum (the table above), the pad is a 900 m platform cut tens of metres into the hillside, and **nothing has
cut the ground under the 56 m between them yet**. §6.3 is exactly that cut, and it is R5's — "the starter kit adds
four corridor runs: each site's `K→F` throat (56 m off-parcel)". So at R4 the four utility sites draw their paving,
car parks, stalls, bays, gates and fence gaps on the ground, and their access roads and hammerheads are drawn in the
right place but stand off the unshaped easement; a street lot's home drive, whose throat crosses only the 3 m
pavement, is within about 2 m and reads as connected. **R5 acceptance gains this probe**: after the corridors are
cut, every plan point of the starter kit must be within 1 cm of the ground under it (the §8.3 R5 "drawn height =
datum ±1 cm" item, measured over the whole plan rather than the corridor alone). Until then the §9 R4 line "the
starter kit's four sites visibly connected" is met on the plan and in the mesh, and on screen only for the paving
inside the lots and for the driveways and dropped kerbs of a generated block.

**So the tick is held, not taken** (R4 review). Drawing the throat draped on today's ground instead would contradict
the height table above and disagree with the corridor R5 cuts to the blend datum, so there is nothing to fix here and
nothing to narrate around either: §9 records the criterion as HELD on the R4 rows and moves it into R5's acceptance,
where the probe and a re-shot orbit screenshot of the kit take it together.

**As built (R5, `SiteCapture._build`).** The table holds with one generalisation, and it is the one that makes the
drawn paving BE the graded ground:

- **A point the corridor levelled is read back from the corridor, whatever its `ptHRef`** — not only a `blend` one.
  The ramp is derived rather than stored (§6.3 as built), so a throat's vias and its frontage node are `pad` points
  that nonetheless stand on the ramp; reading them off the pad datum was the whole +41.6 m. `SiteCorridorRun.radiusAt`
  reproduces the brush's own rule: a point within a segment's levelled half width of its chord takes the datum
  interpolated by where it projects onto that chord, in plan — which is the fixed point of the brush's own
  three-dimensional projection, because a point at the interpolated radius lies ON the chord and a lateral offset is
  square to it. Later segments win, as later brushes do. A point no cut segment covers keeps the table's rule
  exactly.
- **A kerb point ON a cut corridor therefore reads the corridor's start datum, not the road drape.** The corridor was
  cut to the ground at that node, so the site still meets the road; and the drawn height then equals the graded
  ground to the millimetre instead of to the 4.3 cm the drape's 6 m chords and arc rescale leave. A kerb point off a
  cut corridor — a kerbside plan's pavement point, every plan on flat ground — is the drape, unchanged.
- **A pad point takes `padDatums['pad:<id>']` where the lot is shaped**, the table's own rule, and the cached
  `groundFor('lot:<id>')` until it is. Reading the pad back from the ground was itself worth a metre on a lot whose
  centroid a road's easing had since moved.
- **Zero new ground queries:** both reads are map lookups on the colony, and the corridor readback is arithmetic.
  The steady-frame early return is untouched.

**Measured at R5 (`site_ground_probe_test`, the same dev colony as the R4 table).** Every one of the 277 plan points
and stalls of the founded kit, drawn height (`ptUp` less the point's own lift `ptDz`) against the ground under it:

| Point kind | R4 worst | R5 worst |
|---|---|---|
| `pad` | **+41.57 m** | +0.0096 m |
| `blend` | +0.36 m | +0.0061 m |
| `kerb` | −0.043 m | +0.0062 m |
| stall | +0.008 m | +0.0083 m |

**Repaired after the R5 review.**

- **A corridor run is built only for a site the shaper CUT** (`CitySim.siteCutRev`, site id → the plan revision it
  was cut at, transient like `corridorDatums`). `SiteCorridorRun.of` was being built for every site of every rebuilt
  chunk, whether or not that site had a cut corridor: every house lot with a driveway has corridor segments, and the
  run walks the plan and allocates a list per column to discover that none of them was cut. Measured over a
  generated town's 1,420 plans that is **1.1 ms a full rebuild, 0.8 µs a site** (warm; 3.7–4.0 µs a site on the
  first, cold pass) — small, but paid for nothing. It is now a map lookup on the colony, and the run is built for
  the handful of sites whose datums there are to read.
- **The probe is pinned at three foundings, not one** (§6.3 as built): the dev colony under the drawn point, and two
  steep ones in the shaper's own basis, where the shaping is what is being measured.

**The residual is the frame's basis, not the shaping.** `CitySiteFrame.localToBodyFixed` places a point flat on the
tangent plane (`up·(datum + ptUp) + east·e + north·n`), so a point `s` metres from the colony origin is drawn
`s²/(2R)` above the radius the capture meant — 6 mm at 275 m, and 1 cm at **357 m**. Every offset in the table above
is that term. It is §5.2's convention, shared with `SurfacePlacement.place`, and correcting it would move every
site's heights (1.26 m at 4 km) and every key downstream: recorded here, not fixed in R5, and the probe is only
meaningful within a few hundred metres of a colony's origin — which is where the starter kit is.

---

## 7. The traffic contract

### 7.1 Split and seam (agreed with the Agent Traffic session)

- `LaneGraph` stays roads only. A separate per-site network and site mover belong to the traffic side. They are
  rebuilt on the site revision, never on `graphRev`.
- **Site entry and exit are ACCESS EVENTS**, the only exception to `lane_changes_only_at_nodes`.
- Traffic builds against the written contract, first with synthetic plans (`SyntheticSites`, R2a), then with real
  plans.
- The road side publishes §2.2–§2.5 and §5.2. The traffic side never generates, edits or re-derives site geometry.

### 7.2 The 14 required constraints, item by item

| # | Ask | How it is satisfied |
|---|---|---|
| 1 | `roadS` in `[edgeLaneS0+6, edgeLaneS1−6]`, never on deck/tunnel/bridge/taper | §3.2 reserve ≥ every `stopBackOf` any override can produce, plus the pavement pull-back (and the drawn cul-de-sac bulb at street dead ends), + 6 m, applied to the WHOLE cut `s ± cutHalf`; exclusions for bridges, off-ground/off-grade decks, tunnels, 90 m tapers and ineligible classes. V1. Test A2 builds lane graphs under every override kind. Kerbside/legacy joins draw nothing and may still clamp. A `homeDriveway` join also keeps 12 m of lane upstream of `T` per served direction (the swing margin, applied at classification, §3.3). |
| 2 | Several joins with roles; dirs ⊆ lotDirs; RoadGraph lot access FROM the primary join | Several joins, roles and dirs: satisfied. Up to 4 join slots per lot on `RoadGraph` (own road, far end, side street, alley reserved); a plan selects slots, with `joinRole` in/out/both and `joinDirs == _dirsFor(road, side)` (V2). **Amended (C-20, needs ack):** the dependency is inverted. `joins[0]` = slot 0 = `lotPiece/lotS/lotDirs` (V3), and slot 0 comes from `RoadGraph`, not from the plan, because zoning does not bump `layout.version` (city_layout.dart:1128), so a use-dependent join would go stale inside an unchanged graph. One function (`SiteJoinPlacer.primary`) is still the single source. C1 notice (§7.3) with the R1 commit. |
| 3 | Straight throat ≥ 7 m before any branch or stall | V5 (straight within 0.1 m, ≥ 7 m, no stall, bay or branch within 7 m of the kerb node along the path); every generator's first segment (home `k + yT ≥ 7 m`, car park `yT = 7 − k`, installation `max(12, k)`). Forward-out departures stop `kSiteThroatStopM = 1 m` inside the kerb line; a home car waits in its stall and backs out on a gap (§7.4 Home back-out), down a throat that is straight within 10° of the normal with a ≥ 4.0 m cut half (V5). |
| 4 | Explicit node list; shared ends are the same node | Node table with `nodePt`; segments hold node indices; polyline ends ARE node points (no duplicated coordinates); V6. |
| 5 | Directed and connected; flagged turnarounds; one-way loops ok, two-way default | §2.5 movement rule; V7 (one SCC containing every cut join's in and out lanes and every stall: stronger than asked); `hammerhead` ≥ 6 × 6 m clear or `circle` ≥ 6 m; a home pad end needs none, because its `inline` stalls link the pad's lanes and are left in reverse (V7, §2.5). |
| 6 | Width, oneWay + direction, speed, kind per segment; heights | `segWidthM`, `segLaneMode`, `segSpeedMps` (10/20 km/h defaults), `segKind`; per-point height refs resolved at capture into `ptUp`/`stallUp` above the body datum, linear between nodes on graded sites, which is exactly what the shaper grades (§6.3). |
| 7 | Stall pose, nose heading, size, aisle seg + s, side, index; forward-turn reachable; aisle widths; angled only on one-way | Stall columns; V9 (perpendicular and angled `stallInDirs` set only where the 5 m run-up exists, every stall has ≥ 1 in-dir, 6 m two-way for perpendicular, angled only on one-way ≥ 3.5 m). v1 emits perpendicular, plus `inline` stalls on home pads: entered forward (`stallInDirs = {fwd}`) and left by reversing out to the street (`stallOutDirs = {bwd}`), side by side where the lot allows, else tandem at most 2 deep, ordered from the street outward (§3.4, §7.4). |
| 8 | Index by (segment, s, side), stable; `rev` only on geometry change; follows renames | Ordering, `rev` and renames: satisfied by V10 ordering, V12 content-hash `rev` excluding site id, and `onLotsRenamed` re-keying with `rev` unchanged; position-free seed (C-5); vanished stalls are traffic's (§7.6). **Amended (C-19, needs ack):** "unchanged by edits that don't touch that aisle" is not met. Indices are stable per `rev` only, because whole-plan regeneration can move every aisle of a site; traffic remaps by `stallKey` (frame-lattice integers, V10). |
| 9 | Loading bays and truck flag reserved | Bay columns always present (filled for yards and installations); `kPlanAdmitsTrucks`, `truckTurnRadiusM`, `segMaxVehLenM`; V13. |
| 10 | Capacity = stall count; one pedestrian entrance per building | `capacity == stallCount` (replaces agent-traffic §7.1's formula, which becomes the generator's target); V11 door + `pavementPt` + `entranceNode`. |
| 11 | Deterministic generation (fnv1a32 seed, no hashCode, no map iteration) | §3.9; `site_access_source_hygiene_test`; generation only inside `advance` (C-8). **Amended (C-5, needs ack):** the seed is position-free `fnv1a32(program version, W and D at 0.5 m, road class, spec type)`, not of the site id. |
| 12 | Plans by reference per revision; traffic draws lot cars from stall indices; road side draws paint and curbs; E36 is traffic's | `CitySiteFrame`/`SiteChunkGeometry` by identity (§5.2), also as `CityTrafficFrame.sites`; lot-car rows `(site ordinal, stall index, kind, variant)` under `sitesRev` (§7.5); road side draws paves, paint, kerb cuts, fences; baked lot cars only when `maxParkedCars > 0` and the site is not agent-managed (per-site bit, staged E36, §5.5); E36 stays theirs. |
| 13 | D36 extension: a site change re-plans only site legs; road routes stay locked | Plans never move `roadsRevision` (S1); `changedSince(sitesRev)`; the §7.6 table. |
| 14 | Far-side left-in has no opposing-gap check | Traffic's fix at the arrival gate (G2, §7.4); the plan supplies `joinRight` and `joinDirs`; test A6. |

### 7.3 Access point relocation (C1)

`road_graph.dart` is on the traffic plan's "untouched on purpose" list (agent-traffic.md:245), so R1 is a C1
change. Road side commits R1 and posts this notice with the hash:

> **C1: lot access = join slot 0 (commit `<hash>`).**
> - `RoadGraph` publishes join slots (`lotJoinStart`, `joinPiece/S/Dirs/Right/Flags/RoomM/KerbE,N/NormE,N`,
>   `joinCrossStart/joinCrossLot`), and `lotPiece/lotS/lotDirs` are slot 0's. `attachFootprint` returns slot 0 of
>   `attachFootprintJoins`. (As built: a corner lot's side-street slot is `sideStreetJoinOf(lot)`, not packed.)
> - `joinFlags`: `kJoinCut`, `kJoinLegacy`, `kJoinSideStreet`, `kJoinClamped` (s moved > 0.25 m from its target),
>   `kJoinOffFrontage` (no span on this road; nearest window point), `kJoinEasement` (the corridor crosses auto
>   lots), `kJoinCorridorBlocked`, `kJoinAlley` (reserved).
> - Windows are `[S0 + reserve + 6, S1 − reserve − 6]` over the whole cut, with the exclusions in §3.2. A street
>   dead end reserves its 11 m cul-de-sac + 1 m.
> - Narrow lots join 4.5 m from the lot line away from the nearer node (ties to the larger `s`). Wide lots use the
>   clamped midpoint. `s` is quantised to 0.25 m. Manual lots use the road their frontage faces; set-back lots use
>   the §3.7a corridor position. A lot with no legal cut keeps today's point as a legacy slot.
> - Read the side from `joinRight`, not the centroid. `sOn` never clamps a cut join (A2).
>   `sharesStructureWith` is unchanged.
> - Re-pinned: `<list>` (§8.2).

**Traffic-side semantics** (their implementation):

- `AccessPoints.ofJoin(lg, joinNo)` takes the side from `joinRight`, and `ofLotIndex(i)` becomes
  `ofJoin(lotJoinStart[i])`. For a plan join, traffic reads the plan's copied join columns. Its identity is the
  plan's `joinRef` (§2.3 join handles): `≥ 0` is packed, `≤ −2` is a side street, `−1` is none. No
  `sideStreetJoinOf` call happens after sync.
- `BuildingTable` gets per-join access rows (edge, `T`, lane, left bit per direction, role, kind) in place of
  `accFwd/accBwd` (building_table.dart:92-97).
  - `addGoals` covers in-capable joins with D6 lane masks.
  - `addOrigins` covers out-capable joins from any lane.
  - `leftOf` resolves by `(edge, T)`.
- **Site-level reachability:** a site is reachable when it is served and it has an in-capable join with a serving
  edge in the main SCC and an out-capable join likewise. A kerbside plan reduces to today's rule.
- **Re-resolve** on a new site, a spec change, a regraph, or `sitesRev` for that site. A control `refresh` never
  changes access.
- Routed-model consumers (road_traffic_model.dart:855, 1576, 2024-2027) keep reading `lotPiece/lotS/lotDirs`.

### 7.4 Handover semantics

**Arrival (the gate)** runs where `_settle` detects arrival (vehicle_mover.dart:606-617), for a trip ending at site X
through in-capable join `j` whose `T` is `destS`:

1. A kerbside plan or an in-incapable join keeps today's behaviour: vanish before slice 4, D17 step 2 in slice 4.
2. **Reserve:** take the first free stall in `stallOrder[j]`, which is precomputed at site sync (by site-path
   length from j's in-lane, ties by index; on a tandem home pad, deepest first with LIFO assignment, §7.5). The
   reservation is BINDING (D17). With no stall the lot is full: go to
   D17 step 2 and never retry X on this arrival.
3. **Grant** when all of these hold:
   - **G1:** the throat in-lane has room for the car's length;
   - **G1b:** for a `sharedSingle` unit, no outbound claim is held;
   - **G2:** for a join left of travel, the opposing lanes are clear with no ETA < 4 s at the crossing, using
     `canJoin`'s `fromLeft` predicate (junction_arbiter.dart:788-795). This is ask 14.
   - **G3:** the car's speed is ≤ 3 m/s.
4. **Refused:** the car is held at `destS` by its virtual leader (vehicle_mover.dart:357-361). After 25 s the ETA
   part of G2 is waived (a forced grant, counted). After 30 s refused on G1 alone, the car releases the stall and
   goes to D17 step 2.
5. **Granted:** log `ENTER(v, edge, lane, site, join)`, unlink from the lane, place the car on the throat in-lane at
   `s = 0`, then drive the site leg under IDM. The final stall manoeuvre is a scripted curve that ends exactly on
   the stall pose, so "within 0.05 m and 2°" is a snap, not an IDM tolerance. The
   vehicle row is then freed and a `ParkedCarTable` row `(site, stallKey, kind, variant, owner)` created.

**Departure** (car parks, yards and installations leave forward through their throats; homes back out, below):

1. The road route is planned first, from every out-capable join's `(edge, T)` (V7: every stall reaches every
   out-join). The car stays parked during the search, and `noRoute` leaves it parked.
2. The join is the one whose `(edge, T)` matches the route origin (V4 makes it unique).
3. A vehicle row spawns on a reverse-out manoeuvre from the stall (parallel stalls pull forward; home `inline`
   stalls follow the Home back-out below instead of steps 3–6). The stall is released when the car's rear clears
   the mouth line.
4. The car drives to the join's throat out-lane and stops with its front 1 m inside the kerb line (`throatWait`).
5. Each sub-step it asks `arbiter.canJoin(route[0], at, len, kind, fromLeft)` (junction_arbiter.dart:777-797). On
   a grant it logs `EXIT`, unlinks from the site, and inserts into the lane at `v = 0`, as today's `_spawn` does
   (trip_planner.dart:291-330).
6. `throatWait` accrues stuck time only after 60 s (recommended). A graph rebuild while the car is in the site
   remaps its held route from the join's `(edge, T)` as `remapWaiting` does.

**Home back-out** (`homeDriveway` only, §10.2 Q3). Every number here lives in traffic's `AgentTuning` unless marked
**ROAD**, which the road side guarantees in generation (§3.3, §3.4, V1, V5, §5.5).

- **Manoeuvre.**
  - Arrive: forward up the throat and pad, nose-in to the reserved stall (tandem: the DEEPEST free stall first).
  - Depart, as one scripted motion with no stop to straighten: reverse down the pad and the throat (≤ 2 m/s); at
    the kerb line swing the tail UPSTREAM of the target lane on an arc (R ≈ 5 m), ending fully in the target lane,
    aligned with its travel, nose downstream; stop 0.5 s to shift; then drive forward under IDM along the locked
    route.
  - Departure steps 1–2 still choose the route and the join first, and the car stays parked until a gap is
    accepted. On a side-by-side pad the stall axes are 1.3 m either side of the join axis; the drive keeps its
    5.2 m width to the kerb (§3.4), so the reverse reaches the kerb line on the join axis and the footprint below is
    measured from `T` for both stalls.
- **Target lane `L`:** the lane the route's first edge starts in on the lot side.
  - Near-direction departure: the kerb lane of the edge that has the lot on its right (on a one-way street, the
    lot-side lane of its one edge).
  - Far-direction departure, only where `joinDirs` allow it (1+1 undivided streets): the reverse edge's lane, with
    the tail swung across the near lane.
- **Gap acceptance**, checked each sub-step before the reverse starts; the manoeuvre commits once the rear reaches
  the kerb line. The footprint on `L` is `[T − 10, T + 2]` (the upstream part is the tail swing), `T` being the
  join's `s` on that edge.
  - Near direction, clear when: (a) no vehicle body is inside the footprint; (b) no vehicle is stopped or queued in
    `L` within 15 m upstream of the footprint; (c) every approaching vehicle on `L` has an ETA to `T − 10` of ≥ 8 s,
    taking its speed as `max(v, 5 m/s)`.
  - Near direction on a 1+1 street: the arc overhangs the opposing lane, so also no vehicle body in the opposing
    lane within `[T − 6, T + 6]`.
  - Far direction: the near lane passes (a) and (c) as well, and the far lane is checked like `L` with a 10 s ETA.
  - Forced grant after 120 s refused: only the ETA terms waive (to a 6 s floor), never with a body in the
    footprint; counted. A parked car does not accrue stuck time.
  - Pedestrians (T4b): the back-out yields to pedestrians on the pavement crossing (`kSegCrossesPavement`).
  - Adjacent same-direction lane (acked by the traffic session 2026-09-15): on an avenue or a two-lane one-way
    street the arc overhangs the next same-direction lane, so that lane must also have no vehicle body within
    `[T − 6, T + 6]` AND every approaching vehicle in it must have an ETA to `T − 6` of ≥ 8 s, taking its speed as
    `max(v, 5 m/s)`, as for `L`. The 120 s forced grant waives only the ETA terms (6 s floor), never a body.
  - Home plans' connectivity exception (acked): the inline stall's fwd→bwd lane link is a reverse-only movement and the
    pad is a reverse-only exit path; the strongly-connected rule is relaxed for this exception only, scoped to
    `homeDriveway`.
- **EXIT logging** (`lane_changes_only_at_nodes`).
  - `EXIT` is logged when the rear crosses the kerb line. From that instant the car's element is `L`, inserted into
    `L`'s ordered list as a REVERSING vehicle (a flag): followers see its footprint as a stopped obstacle.
  - For a far-direction departure, the near-lane footprint is a claim for the manoeuvre's duration, not occupancy.
  - Property-test tolerance for a back-out `EXIT`: edge + `T ± 11 m`, lane == `L`. Nothing else changes lane until
    a connector.
- **Restrictions** (**ROAD** for eligibility, applied by §3.3; traffic for direction):
  - minor-tier roads ≤ 40 km/h (`street`, `streetOneWay`, `alley`, `path`): both directions where `joinDirs` allow;
  - `avenue` (50 km/h, 4 lanes): near direction only (the kerb lane), never across; the departure planner restricts
    origins to the near edge;
  - above 50 km/h, or divided or medianed: no `homeDriveway` (kerb parking), as §10.2 Q11 already has for
    boulevards and urban highways.
- **ROAD generation guarantees:**
  1. the swing margin: for each served direction, ≥ 12 m of lane upstream of `T` inside `[laneS0, laneS1]`, so a
     swing never enters a junction box or crosses a stop bar (V1, §3.3 rule 3);
  2. the throat is straight and within 10° of the normal, the cut half is ≥ 4.0 m for the tail swing, and the first
     7 m from the kerb carries no stall (V5, §3.4);
  3. kerb-parking masks of `[T − 12, T + 3]` in travel terms on each served side, in traffic's kerb masks AND the
     baked `curbParkingFor` (§5.5, §7.5): a kerb car in the swing path would block every departure;
  4. home stalls along the drive: side by side on a 5.2 m pad where the lot allows, else tandem at most 2 deep,
     ordered from the street outward (§3.4).
- **Deadlock and gridlock** (traffic):
  - Two neighbours: a granted back-out takes a claim on its footprint; overlapping claims are refused, ties by
    (sub-step, handle). Neighbouring back-outs are serialized, never simultaneous.
  - Behind a reversing car: followers stop at its footprint (≤ ~8 s); no gridlock.
  - Inbound vs outbound at the same driveway: if an inbound car is held at `destS` (it is IN the footprint) and the
    outbound car has not committed, the outbound yields its throat claim and waits in its stall until the inbound
    has parked. Once the outbound has committed, the inbound waits on the road. The `sharedSingle` claim unit
    stays as specified below.
  - Tandem blocking: §7.5 (LIFO assignment, the 120 s shuffle).

**Single-lane throats and driveways (`sharedSingle`).** The chain from the kerb node to the first two-way or
turnaround node (on a home, `K→H→P`) is one claim unit. Inbound claims it at the gate, and outbound claims it at the
unit's lot end. Opposite claims are refused, and ties go by (sub-step, handle). No deadlock can form: an inbound car
waits on the road, and an outbound car waits in the lot; on a home drive an uncommitted outbound car yields its claim
to an inbound car held at `destS` (Home back-out above).

**Access events in the property test** (`lane_changes_only_at_nodes`):

- A road↔site element change is legal only with a logged event whose `(edge, T ± 1.5 m)` is that join's, whose lane
  is `destLane` (ENTER) or inside `canJoin`'s target set (EXIT). A home back-out `EXIT` is legal at `(edge, T ± 11 m)`
  with lane == `L`, logged as the rear crosses the kerb line, the car then a REVERSING vehicle in `L`.
- Inside a site, lanes change only through §2.5 movements or stall manoeuvres.

### 7.5 Parking semantics

- **Capacity:** `lotCap = stallCount` for network plans and 0 for kerbside. `lotUsed` counts parked cars plus binding
  reservations. `stallCount == 0` with a network is a legal drop-off-only site.
- **agent-traffic §7.3 step 1, revised:** the destination's own stalls if it has a network plan, the arrival join is
  in-capable and a stall is free. The stall is reserved at the gate, and the car turns in from its locked lane, drives
  the site and parks forward-in.
- **Home pads (traffic):** home cars park nose-in and leave by backing out (§7.4 Home back-out).
  - **Tandem:** an arriving car takes the DEEPEST free stall first. Where departures are known, assignment is LIFO:
    the car due out first goes in the outer stall.
  - **Shuffle:** a deep car still blocked by a parked outer car after 120 s has the outer car moved to a free kerb
    slot (a counted "shuffle": a parked-car relocation, never a teleport onto the carriageway).
  - A parked car accrues no stuck time.
- **D17 order, revised:**
  1. destination stalls at the gate;
  2. kerb slots ahead on the arrival edge within 60 m, skipping masked slots;
  3. adjacent edges;
  4. circle (step 1 is retried only if the loop ends on an in-capable join's edge);
  5. give up and garage.

  Other sites' lots are not searched, and no plan sets `kPlanPublic` (the bullet below).
- **Public lots (`kPlanPublic`): deferred, with the design written down (R8 scoping).** A public lot is a site whose
  stalls serve trips that have no destination in the building beside them — a town-centre car park a driver walks
  away from — so it would enter D17 as a step between 1 and 2: the destination's own stalls, then a public lot
  within a walk of the destination, then the kerb. The flag exists (`kPlanPublic`, site_access_constants.dart:225,
  whose doc comment now reads "designed, not built" rather than "reserved for R8")
  and §3.3 says what would set it. It is NOT built, and the decision is that no code lands until the traffic search
  is scheduled, for two reasons.

  The first is that it cannot even be shipped as scenery in the meantime, which is the obvious cheap step and the
  one that does not work. `CityAgents._publishManaged` marks EVERY live site row with `lotCap > 0` agent-managed
  (city_agents.dart:950-955), the bits ride the frame as `CitySiteFrame.agentManaged`
  (city_site_frame.dart:207-216), and the mesher then bakes no lot cars on a managed site
  (site_access_mesher.dart:411, the `agentManaged` term). So with agents on, a public car park drawn today renders
  permanently and visibly EMPTY: the baked cars are suppressed because a live site's stalls are the agents' to
  fill, and no agent ever parks there because nothing searches it. A car park nobody parks in is worse than no car
  park.

  The second is what the traffic half needs. This half is a REQUEST to the Agent Traffic session, raised at the R8
  scoping and NOT yet acked — compare the dated acks this document uses where a thing IS agreed (§7.4's adjacent
  same-direction lane, "acked by the traffic session 2026-09-15"). `SiteTable` keeps a row per
  BUILDING SLOT whose plan it has synced (site_table.dart:10-16), and `rowOfBuilding` answering −1 is exactly how
  the arrival gate learns there are no stalls here — so a public lot needs a site row that hangs off a SITE ID
  rather than a `BuildingTable` slot, which no column in that table is shaped for today. It needs a rule for who
  may park there (any trip? only trips whose destination is within some walk? only trips the destination's own
  stalls turned away?). And it needs an answer for a trip's PURPOSE and its WALK LEG, because a public lot has no
  destination building: today a parked car's trip ends at a stall and §7.5's stall → door walk is the destination's
  own. The walk leg is T4b's (residents and pedestrians), so the road half's ASK is that a public lot be taken up no
  earlier than T4b — parking where nobody walks from is scenery with extra steps. WHEN it is taken up, and against
  what, is the Agent Traffic session's to sequence, not this document's. What this side commits to on its own
  authority is only that no road-side code lands until the traffic search is scheduled: no generator sets
  `kPlanPublic`, and §3.3 says what would.

  **Cross-session dependency, raised not resolved:** `docs/plans/agent-traffic.md`:1368 still reads "Other sites'
  lots are never searched (`kPlanPublic` is reserved)", which is the reservation this bullet re-characterises as
  deferred-with-a-design. That document is the Agent Traffic session's; the difference is theirs to settle and is
  reported to them rather than edited here.
- **Kerb masks:** a kerb slot at `s_i` is masked when `KerbCuts.parkingBlocked(side, s_i)` holds for a cut join of a
  live network plan, with the slot's travel arc and right-of-travel side first converted to the canonical index arc
  and side (§5.5). The form is asymmetric, in the travel terms of the lane beside that kerb:
  - `homeDriveway` joins: `blocked(…, upstreamM: 12, downstreamM: 3)`, i.e. the swing mask `[T − 12, T + 3]`, on
    EACH served side: the lot-side kerb, plus the far kerb where a far-direction back-out is allowed (1+1 streets);
  - every other program: the symmetric `(3.25, 3.25)` around its cut.

  The baked `curbParkingFor` uses the same form (A12). The owning kerb follows the D7 rules. Masks update on
  `sitesRev` too. A car on a newly masked slot relocates as a vanished stall does.
- **Lot cars on the wire:** `ParkedColumns` gains `sitesRev` and lot rows `(lotSite = ordinal in CitySiteFrame
  order, lotStall = stall index, lotKind, lotVariant)`. `lotKind` is the `AgentKind` index (always car in T4a), so
  yard and depot parking for vans and trucks in later traffic slices does not change the wire (D42). The renderer
  draws them at the stall pose and `stallUp` only when `sitesRev` matches its frame, and otherwise holds one publish.
  This replaces agent-traffic §7.4's "positions-only port of emitLot".
- **Persistence:** lot cars are saved as `[ownerIdx, where = lot, siteId, stallKey, kind, variant]`, never by stall
  index. `siteId` is the lot or site id string current at save (renames follow `_carryRenamedLots`). On
  load, `stallIndexOfKey`. If the key is gone, the nearest free stall by distance. If there is none, garaged.
  Reservations and in-site vehicles are not saved.

### 7.6 Revisions and the D36 extension

Site networks rebuild on a site re-sync, never on `graphRev` alone. `_buildingsMoved` (city_agents.dart:716-722)
gains `sitesRev != _syncSitesRev`. In-site vehicles never reference lane ids. How site elements are identified is traffic's choice: it publishes
separate site columns (site ordinal + site lane) in `AgentFrame`, with `AgentFrame.sitesRev`; no road-side impact.

| Case | Bound for X on the road | Moving inside X | Parked in X |
|---|---|---|---|
| `rev` changes, joins unchanged (growth) | nothing; the gate reads the new plan | **snap** to the nearest new site lane within 3 m and 60°, then re-plan the site leg. With no snap: inbound parks on its key if it survives, else the nearest free stall, else garaged; outbound goes to its out-join's throat | key kept, index remapped; if the key is gone, nearest free stall, else garaged (counted) |
| A join loses in/out capability, or the plan becomes kerbside | on arrival: D17 step 2 from there | as row 1, outbound re-targeted to a surviving out-join | as row 1 |
| Demolished or cleared | drives on; `arrivedGone` on arrival | the old plan is held in LIMBO while cars use it: inbound drops its reservation and exits, outbound carries on; no new entries | garaged at once |
| Lot renamed | handle kept | nothing | nothing |
| A network edit moves a join | the route remaps by lineage; `destS` = the new slot's `T` if the last edge serves the same slot number, else an appended fixed-start leg (`siteRetarget`) | as row 1 | as row 1 |

Limbo plans are freed at the end of the sub-step in which their last car leaves. No site change edits a road route in
flight, and `stats.replans` still counts only network re-plans.

**As built (R2 book):** the book keeps no limbo. A cleared or re-planned site's old row stays readable in the chunk
object traffic already holds (published chunks are never written), so traffic's limbo is a reference to that chunk
and site index; `changedSince(sitesRev)` names every site that appeared, went or changed `rev`. A re-resolution
against a new graph (same `rev`) and a rename move no `sitesRev`: traffic sees those through `isCurrentFor` and its
own `onLotsRenamed`.

### 7.7 Plan-doc and D-number impacts (agent-traffic.md; text is theirs to apply)

| Item | Change |
|---|---|
| §3.10 (705-726) | A site's access is its plan's joins; `joins[0]` = slot 0 = `lotPiece/lotS/lotDirs`; side from `joinRight`; goals from in-capable joins, origins from out-capable joins; reachability per role |
| D6 (88) | Unchanged, applied per join |
| D7 (89) | Unchanged: `joinDirs == _dirsFor(road, side)`; a role restricts in/out, never direction |
| §5.4 (1056-1060) | The far-side left-in takes the opposing gap at the arrival gate (ask 14) |
| §5.5 (1096-1102) | The two access-point exceptions become the ENTER/EXIT access events; site element rule added to the property test; a home back-out's EXIT is logged as the rear crosses the kerb line, at `(edge, T ± 11 m)` into lane `L` as a REVERSING vehicle (§7.4) |
| §7.1 (1288-1313) | `lotCap = stallCount`; the table becomes the generator's target (road side uses `parkingSpaces`) |
| §7.3 step 1 (1332), D17 (99) | §7.5 revised text and order |
| §7.4 (1350-1368) | Lot cars on plan stalls under `sitesRev`; delete the positions-only emitLot port |
| §13.1 | `CityTrafficFrame.sites`, `AgentFrame.sitesRev`, site elements |
| §14.1 (2122-2125) | Lot cars saved by `(siteId, stallKey)` with kind and variant, from T4a on |
| D19/D20 (101-102) | Unchanged for roads; site poses use `CitySiteFrame` heights (its own source, never a re-drape) |
| D27 (109) | Unchanged; site mover sub-step math follows it; generation uses no trig (C-11) |
| D36 (118) | Append: a site-plan change re-plans only site legs of cars in or bound for that site; road routes stay locked (§7.6) |
| D42 (124) | Unchanged: lot cars carry kind + variant; on the wire as `lotKind` (the `AgentKind` index, car in T4a) + `lotVariant` in the lot rows, and saved with both (§7.5) |
| C1 (249-256) | Lot access = join slot 0, rule in `site_access/site_join.dart` |
| New D49 "Site networks" | Separate from the lane graph; plans owned by the road side; rebuilt on `sitesRev`, never `graphRev`; handover only at joins; home driveways are left by backing out into the street (§7.4 Home back-out: manoeuvre, target lane, gap acceptance, footprint claims, REVERSING vehicles; numbers in `AgentTuning`), while car parks, yards and installations leave forward |
| Slice 4 (2768-2778) | Split into T4a and T4b (§9) |
| E36 (242) | Theirs, staged: in T4a baked cars go off only on agent-managed sites (per-site bit read by R6 baking, §5.5); in T4b `maxParkedCars = 0` and `onStreetParking = false` before the first tile request |

### 7.8 Checklist: the Agent Traffic session builds

1. **Access:** `AccessPoints.ofJoin`, per-join `BuildingTable` rows, `addGoals`/`addOrigins`/`leftOf`, and
   site-level reachability.
2. **Site sync:** plan reference and `rev` per building slot, `lotCap`, stall bitmaps, binding reservations,
   `stallOrder[j]`, next-hop tables and site elements, re-synced on `sitesRev`.
3. **Site mover:** IDM on site lanes, node movements, turnaround U-turns, stall in/out manoeuvres (home `inline`
   stalls: forward in, the scripted reverse down the drive and the tail swing into `L`), `sharedSingle` claims and
   speed caps.
4. **Arrival gate:** G1–G3, forced grant, give-up, and ask 14; on a home drive, the inbound-vs-outbound rule (an
   uncommitted outbound yields to an inbound car held at `destS`).
5. **Departure:**
   - car parks, yards and installations (forward out): route first, spawn on the stall, reverse out, `throatWait` +
     `canJoin`, EXIT, and route remap on rebuild;
   - homes (Home back-out, §7.4): route first; the car waits in its stall; gap acceptance on the target lane `L`
     (footprint `[T − 10, T + 2]`, stopped/queued and ETA terms, the opposing-lane and far-direction checks, the
     120 s forced grant that never waives a body in the footprint); a claim on the footprint; the reverse and swing;
     EXIT when the rear crosses the kerb line, with the car in `L` as a REVERSING vehicle; the 0.5 s shift stop; then
     IDM on the locked route. Tandem LIFO assignment and the 120 s shuffle to a kerb slot (§7.5).
6. **Access events** and the extended property test (a home back-out EXIT at `T ± 11 m`, lane == `L`).
7. **The D36 extension:** snap, relocate, garage, limbo, `siteRetarget`, with counters.
8. **D17 order**, kerb masks via `KerbCuts.parkingBlocked` (the asymmetric form: `(12, 3)` for home joins on each
   served side, `(3.25, 3.25)` otherwise, §5.5), and `lotCap` from stalls.
9. **Wire:** lot rows `(lotSite, lotStall, lotKind, lotVariant)` in `ParkedColumns`, site elements plus `sitesRev` in
   `AgentFrame`, `CityTrafficFrame.sites`, site manoeuvre geometry in `traffic_capture.dart`, drawing in
   `agent_nodes.dart`, and E36.
10. **Persistence** of lot cars by `stallKey`, with kind and variant (in T4a, so no save ever holds lot cars under
    another scheme; §9).
11. **Digest:** `CityAgents.digest` folds `plan.rev`, stall bitmaps and reservation owners. Also hygiene,
    zero steady-state allocation (`traffic_alloc_test`) and benches.
12. **The acks on C-5** (position-free seed), **C-19** (indices stable per `rev` only; remap by `stallKey`) and
    **C-20** (slot → plan dependency), and the plan-doc edits in §7.7.

Traffic runtime budgets (their targets):
- site mover ≤ 80 ns per site vehicle per sub-step;
- gate check ≤ 150 ns;
- site re-sync ≤ 0.5 ms per changed plan;
- site vehicles count against `maxVehicles`, and parked cars do not.

### 7.9 Shared headless acceptance tests

| # | Test | Owner | Asserts |
|---|---|---|---|
| A1 | `site_plan_contract_test` | road | V1–V13 on every plan of the starter kit, the small generated town and 500 seeded random parcels × road classes; fixtures pass the same validator |
| A2 | `join_window_covers_controls_test` | road (imports traffic read-only) | for every node × every override kind, `LaneGraphBuilder.build` puts every cut inside `[edgeLaneS0+6, edgeLaneS1−6]`; `sOn` never clamps a cut join; the reserve ≥ `stopBackOf` for all kinds |
| A3 | `lot_access_is_slot_zero_test` | road | `lotPiece/lotS/lotDirs == slot 0`; `accessOf` agrees; the §3.2 starter table exactly; `lotPiece < 0` count unchanged on the sprawl fixture; layouts byte-identical |
| A4 | `drive_in_and_park_test` | traffic | a forced starter colony trip (`forceTrip`, not CommuteSynth rates) → aquifer pump: one ENTER at `T ± 1 m`, drives the throat, parks on `stallOrder[j][0]` within 0.05 m/2°, `lotUsed == 1`, within 90 s |
| A5 | `pull_back_out_test` | traffic | car parks, yards and installations only (forward-out departures; homes are A9): reverse out of the stall, stall released at the mouth line, front never past kerb − 1 m before EXIT, EXIT only with a `canJoin` gap under a 60 s kerb-lane stream |
| A6 | `far_side_left_in_gap_test` | traffic | no ENTER with opposing ETA < 4 s (forced grants counted, none within 25 s); turns in on a gap |
| A7 | `lot_full_goes_to_kerb_test` | traffic | 2 stalls, 3 arrivals: 2 park, the third never ENTERs and reserves an unmasked kerb slot |
| A8 | `site_plan_change_mid_trip_test` | traffic (+ road fixture) | growth: `replans == 0`, keys kept, movers snap; stall removed → relocated; demolition → garaged / limbo / `arrivedGone` |
| A9 | `home_back_out_test` | traffic | HOME and HOME_TANDEM on a 1+1 street: 2 stalls, cars in forward and nose-in, out by backing out in both directions (near into the kerb lane, far across it) under a 60 s kerb-lane stream; the inbound/outbound conflict at one driveway; a tandem shuffle. No EXIT with a body in the footprint; every back-out EXIT at `T ± 11 m` in lane `L`; `sharedSingle` never double-occupied; no deadlock over 600 s at 10× rate |
| A10 | `renamed_lot_keeps_parked_cars_test` | both | a re-cut renames the pump lot: `rev` and keys unchanged, easement unchanged, cars stay, trips arrive; also a save/resume with lot cars parked (T4a) |
| A11 | twin-run / partition / frame-hold digests | traffic | identical with site movers active, a plan change mid-run, and capture calls interleaved (rendered vs headless) |
| A12 | `kerb_cut_masks_kerb_slots_test` | both | agent kerb-slot masks (canonical arc, converted from `T`) and baked `curbParkingFor` skips (drawn arc) agree within 0.5 m per cut, both checked against the same asymmetric `KerbCuts.parkingBlocked` form: a home join masks `[T − 12, T + 3]` in travel terms on each served side (both kerbs on a 1+1 street, the upstream side flipped per travel direction, on a forward and a reversed road), other programs `(3.25, 3.25)`; each conversion unit-tested; kerbside joins mask nothing |
| A13 | `site_alloc_test` | traffic | 1,000 sub-steps, 50 cars cycling lots: no buffer reallocated |
| A14 | `site_wire_test` | both | frame identity stable until `sitesRev`; kerb-node heights = road drape ±1 cm; lot-car rows map to stall poses ±1 cm; `sitesRev` mismatch holds lot cars one publish |
| A15 | `lane_changes_only_at_nodes` (extended) | traffic | §7.4 event rules, 500 agents, 2,000 sub-steps, STRIP and LOOP sites on the grid |
| A16 | slice-4 manual acceptance | traffic | screenshot: no baked parked car in the agent colony; cars entering and leaving the pump and pad lots |

**Synthetic fixtures** (`test/colony/site_access/site_plan_fixtures.dart`, road side, R2a) are placed on real slots
by `SyntheticSites.placeAt(graph, lotId, template)`:

| Template | Shape |
|---|---|
| HOME | on a 1+1 street slot: `sharedSingle` 5.2 m drive, 7 m throat `K→H` + 5.2 m pad `H→P` (collinear), cut half 4.0, 2 side-by-side `inline` stalls (`stallInDirs = {fwd}`, `stallOutDirs = {bwd}`), pad end `P` with no turnaround |
| HOME_TANDEM | as HOME with a 3.2 m drive and a 10.4 m pad: 2 `inline` stalls in tandem (outer `S0`, deep `S1`) |
| STRIP | 6 × 7 m two-way throat, 40 m aisle, 12 + 12 stalls, circle turnaround |
| LOOP | in-join and out-join, one-way loop, angled60 stalls |
| UTILITY | 56 m throat with vias to `F`, yard circle `Y`, gate `G` on the fence line (hammerhead (a)), connector to an aisle loop with 20 stalls, 2 bays |
| KERBSIDE | kerbside only |

**As built (R2a):** `SyntheticSites.draftAt/placeAt(graph, lotId, SyntheticTemplate)`. All fixtures stand on the
starter kit and pass V1–V13 on its graph under all five A2 override kinds. They differ from the table as follows:
- STRIP's throat is 11.5 m (the §3.5 F1-double shape) and its aisle is 42 m.
- LOOP is a corner lot's one-way through drive, in at slot 0 and out at the side-street slot 2 (`joinRef ≤ −2`), with
  3 `angled60` stalls. It is not a closed ring.
- UTILITY's 20 stalls sit inside a two-way aisle ring.
- Every segment over 24 m carries vias (V8).
- Two templates are added: YARD (a 7 m truck throat, an aisle, an apron with 2 bays and a 12.5 m circle) and
  FOOTPRINT (STRIP on `attachFootprintJoins` slot 0, `graphLot` −1, `joinRef` −1).

---

## 8. Pins, tests and performance budgets

### 8.1 Policy

- New render paths run only for data the fixtures do not carry: `siteSlot ≥ 0` or non-empty `kerbCuts`. So every
  existing tile, road and detail digest stays byte-identical through R6, and each slice's PR asserts that.
- **R7** deletes the legacy path and re-pins in ONE commit, listing every old → new value and its reason in
  Appendix A, with before/after studio screenshots attached to the review (not committed, per the workspace rule).
  **Done: nine pins moved, all of them legacy-massing ones, and no plan-served digest moved at all.**
- The only earlier re-pins are R1's lot-access pins, which are unavoidable (lot access moves) and ledgered the same
  way.

### 8.2 Pins that move

| Pin | Where | Moves in | Why |
|---|---|---|---|
| Lot `s` goldens, access and table tests | `road_graph_directed_test`, `road_traffic_model_test`, `access_points_test.dart:59-64` (green by construction), `building_table_test.dart:89-92`, `graph_derivation_test` if it hashes lot arrays | R1 | lot access = slot 0 (§3.2) |
| Parcel building quaternions | screenshots only | R0 | orientation fix |
| Tile digests near `0xf5d18ccb`, full `0x5b35df04`, mid `0x0759f3c8`, far `0x07d559a4` | city_tile_mesher_test.dart:505, :527, :551, :585-589 | R7 (**moved**, Appendix A) | the knob-OFF fixture's buildings lose their car parks and grow into the strip those took. The knob-ON pins did NOT move |
| Lot-features behaviour | test/colony/lot_features_test.dart | R7 (`emitLot`'s cases deleted, not rewritten: the plan-served drawing is `site_detail_dressing_test`'s and `site_access_mesher_test`'s, where it has been since R4/R6) | `emitLot` deleted |
| Installation parking | test/architecture/installation_parking_test.dart | R4 (plan cases added), R7 (legacy cases deleted) | plan-owned parking |
| Lighting masts | test/architecture/city_lighting_test.dart:145 | R4 | masts from `lampPt` |
| Shaper brush counts | city_terrain_shaping_test, shaper_ground_samples_test, starter `terrainEdits` | R5 | access corridors |
| Starter zoning | `city_starter_kit_test.dart:57-67` ('zoning the starter block grows buildings on it') | R2 (assertion added; existing expectations unchanged) | four starter lots become access easements (§3.7a): the loop's `setUse` returns false for them, and the test now asserts exactly `{lot-r0x1-l10, lot-r0x0-l0, lot-r0x0-r1, lot-r0x1-r5}` stay unzoned and unbuilt while `grownParcels` is non-empty |
| Degenerate lots, generator, style | degenerate_lots_test.dart:79-93, building_generator_test.dart:59-77, architecture_style_test.dart:60-72 | never (legacy default); R7 re-checks | **R7 re-checked them and three moved** (Appendix A): the style test's front/rear car-park case is deleted (there is no car park to place), the generator's two parking cases become one — a spec that attracts cars keeps its whole buildable strip — and the degenerate test drops an `isNull` guard that only ever guarded against a car park's lamps |
| The R3 fixture's tiers with the knob **ON** | city_tile_mesher_test.dart 'site access on the wire…' | R4 | R3 pinned the knob-on tiers EQUAL to the legacy ones, to prove the knob drew nothing yet; R4 draws the plan, so the three on-values move (and are asserted different from the off ones). The knob-OFF pins `0xf5d18ccb` / `0x0759f3c8` / `0x07d559a4` do not move. Ledgered in Appendix A; track A's mesher and kerb cuts move the on-values again at the R4 merge |

**Never move:**
- road tool `0x5e473abb`, `0x09731332`, `0x07d559a4` — **broken at R7, by this row's own logic** (Appendix A): all
  three are `road_tool_mesh_test`'s "the mesher fixture, its junctions aside" tile, which carries eleven BUILDINGS
  beside its roads, so a change to the legacy massing moves them. The roads themselves are untouched: the road ZOO
  digests below, which carry no building, are byte-identical, as are the ramp's;
- road zoo `0xfaae5bd2`, `0xa687274b`, `0xb8c5ea2d` (road_tool_mesh_test.dart:217-219, :293-295). A new zoo case with
  cuts gets its own pin — **R8 took it**: 'a sealed street with drives carries its tube over them' pins
  `0x3c455708` (near, sealed, `siteAccess` on) and the three zoo digests above are unmoved, since no zoo road
  carries a cut. That pin was taken twice inside R8 — `0xa96767cb`, then `0x3c455708` when the repair moved the
  posts — and neither value ever reached `dev`, so it is a first pin and not an Appendix A re-pin;
- detail layer on/off and mid/far identity (city_detail_layer_test.dart:506-548, extended to sites);
- `city_tile_bucketing_test` keys for tiles without sites;
- `traffic_fixture_test.dart:32-34` (4 roads, 5 nodes, 8 edges);
- `city_starter_kit_test`, except the zoning test's added easement assertion (table above);
- generated-town LAYOUT byte identity (easements are derived flags, never a re-plat);
- `relaid_road_drape_test` capture ground-query counts.

### 8.3 New tests by slice

- **R-F:** `site_frame_test` (both windings, reversed starter frontages, frontage-less manual lot, cell, concave
  interior point, `streetHeading == Parcel.heading` wherever `Parcel.facing == −v`, `buildableExtent` unchanged).
- **R0:** `site_orientation_test`, `building_front_test` (both fail before the fix and pass after; §5.1 stop rule).
- **R1:**
  - `kerb_windows_test`: reserve pin vs node_control; `kCulDeSacRadiusM` pinned against city_tile_mesher; **no cut
    within the drawn cul-de-sac** (a street dead end's window starts ≥ 12 m + 6 m from the end, and a lot beside a
    sprawl cul-de-sac gets no cut inside the bulb); deck/tunnel/bridge/taper exclusions; short piece; windows
    identical after `withOverrides`;
  - `site_join_placer_test`: the §3.2 starter table exactly (slots, `kJoinClamped`, `kJoinEasement`,
    `joinCrossLot`); narrow drive side; tie to the larger `s`; one-way and 2-lane `dirs`; side street only when
    needed; `kJoinClamped` vs `kJoinOffFrontage` (a lot past a dead end doglegs, a clamped installation does not);
    corridor candidates (centred single lot beats an off-centre single lot; shared side line only for narrow lots;
    a manual parcel or an at-grade road blocks; an elevated road, a raised deck stretch and a tunnel stretch do NOT
    block); quantisation;
  - `hash32_test`, A2, A3, sprawl audit counts (`kJoinLegacy`, `kJoinEasement`, programs later), bench R-B1.
- **R2a:** validator rejection cases, one per V; fixture validity; `site_access_source_hygiene_test`. V5 fixtures:
  ACCEPTED: a 56 m throat with vias at 24 and 48 m ending at a frontage node; the home `K→H→P` straight run (throat
  far node `H` of degree 2, pad end `P` with no turnaround). REJECTED: a via 0.2 m off the chord; vias 25 m apart; a
  6.9 m throat; a stall mouth or branch 6.9 m from the kerb node along the path; a home cut half of 3.9 m; a home pad
  whose end node lies 0.2 m off the throat's axis. V7: a dead end without a turnaround that is not a home pad end is
  rejected. V9 fixtures: an `inline` home stall with `stallInDirs ≠ {fwd}` or `stallOutDirs ≠ {bwd}` is rejected; a
  stall with no in-dir bit is rejected. V1: a home join with only 11.9 m of lane upstream of `T` in a served direction
  is rejected. V8: a `segLenM` off by 2e-6 is rejected.
- **R2:**
  - `home_driveway_test` (auto lot, k = 3, x_d = 4.5): W 16.5 → kerb, 16.6 → 2 in tandem, 17.5 → tandem, 17.6 → 2
    side by side; D 14.9 → kerb, 15 → home; a single stall only on a profile whose drive columns are < 14.9 m deep;
    r-med never. Back-out eligibility (§3.3): street, one-way street (40 km/h), alley and path → home; avenue →
    home (its `joinDirs` hold only the near direction); boulevard, urban highway, any medianed road or any road above
    50 km/h → kerb; slot room 3.9 → kerb; a swing margin 0.1 m short on one served side → kerb (a both-directions
    street join checks both sides, an avenue or one-way join only its upstream side); `v` 10.1° off the normal →
    kerb. Every home stall `inline`, `stallInDirs = {fwd}`, `stallOutDirs = {bwd}`, ordered from the street outward;
    the pad collinear with the throat; the cut half 4.0; no turnaround node;
  - `car_park_packer_test`: 20–120 m rectangles; the §3.5 worked example with its exact numbers (F1 double wins,
    10 stalls at the listed x-ranges, envelope `[1.5, 22.5] × [18.7, 31.7]`, scores 90.11 / 54.25, F2 254.8 m² and
    F3 7.8 m rejected); a `kJoinMinRoomM` slot (room 2.5 → a 3.0 m `sharedSingle` throat and ≤ 8 stalls, else null);
    SAT non-overlap; triangle/sliver/L; F2 bias;
  - `installation_access_test`: the four starter sites (56 m throat `K→F` with vias, `Y` at y = 15, 4 bays,
    `G = (x_G, Df)` on the fence line, car park x-range outside `x_G ± 15`, ≥ 12 stalls); **`D = 130`** (no
    `ArgumentError`, `Df = 40`, bays dropped, `kPlanAdmitsTrucks` clear, the plan validates); a spine near a lot side
    (no yard, branch `B`); a narrow slot (room 4.0) where a yard falls through to `carPark`;
  - `site_easement_test`: the starter easements exactly; `setUse` refuses them and `placeOnParcel` refuses them;
    growth skips them; a crossed lot that is already built blocks the site (`kPlanAccessBlocked`); clearing the site
    lifts the easement; `claimSite` over a live corridor is refused; the inspector string;
  - `site_plan_property_test` (500 seeded lots, shuffled site order);
  - `site_plan_revision_test`;
  - `site_access_persistence_test` (200 curved-road lots with identical keys, §4.4);
  - `site_access_sync_test`: a road edit queues only lots inside the dirty box; stale plans read as kerbside to
    traffic and keep drawing; easement-priority sites are checked first;
  - `site_access_tick_order_test`: `siteAccess.sync` runs inside `CitySim.advance` before `roadTraffic.advance` and
    `agents.advance`; a plan made this tick is visible to agents this tick; `isCurrentFor` flips false on a road edit
    and true after the re-check, identically in headless and rendered runs;
  - A1;
  - sprawl audit: program counts, and home demotions to `kerbOnly` counted by §3.3 back-out rule (road, room, swing
    margin, skew, geometry);
  - generation benches (program mix and Σ printed, §3.10) and the road-edit sync bench (≤ 2 ms worst tick, §4.2).
- **R3:**
  - `site_capture_test`: identity reuse, zero steady-state queries, kerb node = drape ±1 cm, pad node = lot pad,
    reversed-road cut flip, cut arc error ≤ 0.5 m;
  - `city_tile_columns_test`: sites and cuts round trip;
  - `city_tile_bucketing_test`: one plan change re-keys exactly {building tile, join road tile}, and
    `sitesSignature` moves the gate;
  - JSON round trip.
- **R4:**
  - `site_access_mesher_test`: per-tier digests for home + strip mall + starter aquifer; paves inside
    parcel ∪ corridor; ribbons meet paves within 1 cm; at mid, big sites draw fully, pave ≥ 150 m² sites draw
    rings only, homes draw nothing;
  - `envelope_axes_test`: for a frontage-less manual lot and a grid cell, the envelope's `u`/`v` equal
    `q.rotate(unitX)`/`q.rotate(unitY)` within 0.99, and the massing gate gap lies on the plan's gate edge;
  - `entrance_matches_door_test`: `instanceTransform(massing.entrance)` is within 0.5 m of the plan's `entrancePt`
    for each style × {r-low, c-low, i-med, aquifer}, including a min-fit bucketed depth;
  - `kerb_cut_test`: no cuts → identical sidewalk bytes; lift at the cut centre; props outside cuts unchanged; no
    kerb car within the mask (a home join's asymmetric swing mask on each served kerb included, a far-kerb swing mask
    never drawn and never moving a prop or tree); no cut in a pull-back, deck, taper or bridge;
  - `envelope_containment_test`: each style × {r-low, r-med, c-low, c-high, i-med, aquifer, spaceport, solar,
    farm}, every volume corner within envelope + 0.30 m and outside paves − 0.2 m;
  - installation gate tests: gap exactly at the gate, no volume in the gate lane;
  - body-fixed check that the gate gap matches the plan's gate node;
  - A12 (road half).

  **As built (R4 track A):** `site_access_mesher_test` (the fixture's mix — four big installations, 38 car parks at
  mid, 78 houses at neither; a house nothing at far or mid; a mid-visible site exactly its ring fans at mid; a big
  site at every tier; the detail pass small sites only, and only paint; every vertex inside the plan and its widest
  ribbon; the tile's `sites` step planned at every tier and only with the knob; the instant tracker's four cases; no
  triangle every corner of which lies on the surface of a ring it is a metre inside — the ribbons and the pads are
  cut, and the check bites: it is red without either cut; the throat one paint over the walk at 0, 1.5 and 3 m from
  the kerb, and a station at each knee of the ease, at the knee's own height),
  `kerb_cut_test` (eleven cases: no cuts and a far-swing mask are the road to the byte, the drop at the cut centre,
  the 2.5 cm face, `arcOffset` on a later span, the verge gap and its tree pits, the props' subsequence, the lamp
  shifted out, a lamp shifted off the end of its span clamped to the end),
  `kerb_cut_masks_baked_test` (A12's road half). The R3 case in `city_tile_mesher_test` now reads
  "off: every tier to the byte; on: only the near tier's kerbside moves", since drawing the cuts is what R4 is.

  - **As built (track B):** `envelope_axes_test`, `entrance_matches_door_test` and `envelope_containment_test` live in
    `test/flutter_scene/`, over one fixture (`site_envelope_fixture.dart`: the site town plus a frontage-less claimed
    plot and a grid-cell utility, the two §10.2 Q10 cases). The gate tests are inside `envelope_axes_test` — the
    drawn gate point against the plan's `gateX` on the envelope's front edge (0.05 m), the lane clear, a fence
    run ending exactly on the lane edge, and that run's OWN drawn y — its outer face — on the plan's `envY0` to the
    same 0.05 m, over at least three fenced sites (without the §6.2 move it stands 2.0–7.5 m inside) — since they
    share its scene. The fixture also stakes a lot with a 2.5 m stored frontage, whose plan is published with an
    EMPTY envelope: its building must read legacy on both sides of the knob (§5.2). `envelope_axes_test` also carries the knob-off
    identity check (position, spin and site size equal to `ofParcel`'s legacy values, building by building), and
    `city_lighting_test` gains the masts-from-`lampPt` case (§8.2). Containment is checked at the full and exterior
    tiers; the block tier draws from the coarse library, where half a bucket of silhouette is the point.
    **R4 review:** the three suites and the fixture now SAVE AND RESTORE `SiteCapture.envelopePlacement` rather than
    putting it back to a hard-coded off, which stopped being the default when the knob went on — a case running after
    one of them read the knob off while production read it on. `envelope_axes_test`'s last case is the guard, and it
    is red under either hard-coded restore. `installation_parking_test`'s lane half likewise runs over EVERY
    `claimsOwnSite` spec instead of only the ones that park: the specs that put a volume in the gate lane are exactly
    the ones the car-park filter skipped, so it could not fail. A counter of the specs the lane pass actually clears
    (9 today, asserted > 3, probed with a zero-width gate) keeps it from going vacuous again.
- **R5:** shaper corridor tests (emitted once, keyed, graded only, datums recorded, drawn height = datum ±1 cm, ≤ 2
  asks per new segment, sprawl adds 0, **a generated graded downtown block on flat ground adds 0 site brushes**,
  the starter kit adds exactly 4).
  - **As built:** `site_terrain_test` (the four runs by name and by `rev`-keyed key; emitted once, and still nothing
    with the `sitesRev` gate forced open and the settled set dropped; the pad and corridor datums recorded; at most
    two ground reads a new segment — 5 for the kit's 4; a draped lot and the sprawl add none; a generated 2-block
    town's downtown adds none and only its set-back manual sites are cut) and `site_ground_probe_test` (the §6.4
    probe, the whole plan, on the dev colony's hillside; red by 41.6 m without the cut).
    **Round 2 adds `site_neighbour_ground_test`** (test/application/, beside the §6.4 probe): over 2- and 4-block
    towns generated at the dev colony's own founding, no plan point of a GRADED lot may stand further from the ground
    than it does with the `site:` corridor brushes withheld from that same shaping — the town's own bookkeeping is
    the full one either way, so both sides draw identically and only the ground moves. A corridor may pull a point
    ONTO the ground; it may not push one off. Red at **1.248 m** and **41.044 m** before the clearance, green at
    0.055 mm and 0.068 mm after, against a 1 mm bound. `road_corridor_mesh_test`
    now tells a site corridor from a road corridor — it scanned every `cutFill` on the body and a site's is one —
    and names the leaves a fine site corridor refines instead of asserting there are none (Appendix A).
- **R6:** `site_detail_dressing_test` (cars ≤ stalls; `maxParkedCars = 0` → none; fences never cross a drive).
  - **As built:** `site_detail_dressing_test` (test/flutter_scene/, 22 cases over the R3 site town): the lot ring on
    the wire equals the layout's own polygon for every site; a fenced lot draws runs and every one of them opens
    somewhere (a way in); **no fence run crosses a segment or a footpath of its own plan**, over 200+ runs; the sign
    stands at the lot line clear of the throat; a footpath is a quad a path leg; a lamp is a column and a head at
    every `lampPt`; a wheel stop stands at the nose of every bay stall and none on a home drive; the hatch is a quad
    a loading bay; the arrows are a pair on a two-lane throat and none on a home drive; **a car stands at its
    stall's pose within a centimetre** (one paving lift over `stallUp`, nosed along `stallDir`, short enough for the
    stall); cars ≤ stalls and none with no budget; WHICH stalls hold cars is exactly what `(siteId, stallKey)`
    seeds, re-read in reverse and against another site's; the agent-managed skip with a FAKE source (a managed site
    bakes none, an unmanaged one does, only the managed site's tile re-keys, and the subset frame carries one bit);
    and **detail on/off identity** — a near tile with the layer off draws the same road-material and furniture
    triangles as the base tile plus the detail job with it on. `site_access_mesher_test`'s detail-pass case now
    counts the arrows and the hatch beside the paint.
  - **The repair round adds three checks** — two new cases and one inside the seed case, 24 in all: the seed's own
    mixing is pinned — two stalls of one site seed apart,
    and `('r6-seed-pin', 7)` → 3164117196 occupied at 549 per mille while `('r6-seed-pin', 4)` → 2904380927 is not,
    so a seed that drops the key is red rather than tautologically green; a seam that manages nothing signs 0 in
    every shape (absent, null, empty, all-zero) and buckets tile for tile like no seam at all; and a knob-OFF
    request that carries sites anyway draws the legacy lot, material for material, while the same request knob-ON
    does not.
- **R8 (sealed-world tube crossings):** a new `kerb_cut_test` group over `PedestrianTube.emit` — no cut on its own
  kerb moves it to the byte (an empty table, a far-kerb cut, a far-swing mask, a cut whose whole approach falls off
  the span); the floor rises to `curbLiftM + crossLiftM` over the drive, measures 1:12 on the approach and is the
  curb again a ramp clear of it; the soffit stands at `crossClearM`, which is over a rover's 1.95 m; every leg reaches
  the ground (its foot at `−legFootM`) and its head the soffit, and no post CORNER stands nearer than
  `legClearM − legHalfM` = **1.84 m** to the drive's edge (the post's centre is what is held the 2 m clear, and the
  post is 0.16 m thick along the road too);
  three drives 15 m apart make ONE crossing with no sag between them, while two 120 m apart make two; and a span
  reads its crossings through `arcOffset`. **The repair adds two cases.** 'the legs are the structure's, not the
  polyline's' meshes the fused terrace on the same street drawn at 1, 2, 10, 25 and 100 m stations and asserts the
  post arcs are the SAME list every time; that they run from a leg run into the first approach to a leg run out of
  the last; that every step between posts is either `legSpacingM` or exactly one drive being spanned; and that a
  post stands at each edge of every drive — then re-checks a LONE crossing on a road drawn at 25 and 100 m
  stations, which used to get no post at all. 'what a crossing costs' pins the four vertex/triangle numbers §5.5
  as built quotes, so the cost line is re-derivable from the suite rather than from an unpublished harness.
  `city_infrastructure_test` gains the winding case for the raised form —
  a reversed box beam is a box-shaped hole you can see the far city through, which a screenshot settles no better
  than the barrel's own winding. `road_tool_mesh_test` gains the zoo case with its own pin (§8.2): a sealed street
  carrying a terrace of three drives, a lone drive 200 m on, a far-kerb cut and a swing mask — with the knob off it
  is byte-identical to the same street with no cuts, with the knob on it is not, and at mid and far (no tube) it is
  identical either way; and, since the repair, the TILE's own posts are counted — twelve pairs down the terrace,
  none further apart than one drive's opening — though the street is drawn at ten-metre stations, not one of which
  may carry a post.
- **R3/R4:** A14 (road half).

### 8.4 Performance budgets (render side; generation in §3.10, traffic in §7.8)

Reference: the 127k-building generated town used by `tool/measure_city_studio.ps1`, A/B with a `siteAccess` knob.

| Work | Budget |
|---|---|
| Frame, static and warm orbit | unchanged within ±0.3 ms of the gate (static 13 / sweep 16 ms); draws unchanged |
| Capture, steady frame | ≤ 0.02 ms for sites + kerb cuts; zero ground queries (`groundQueries` delta 0) |
| Chunk heights rebuild | ≤ 1.5 µs per site, only on a stamp change |
| Tile cut (`city.bucket`) | ≤ +10% |
| Near tile build | **re-budgeted at R4 and CONFIRMED at R7: ≤ +30% time, ≤ +25% vertices, ≤ +25% bytes** (was ≤ +15% time, ≤ +20% vertices); mid ≤ +10% (vertex count measured on the reference town's mid tiles before the knob goes on, §5.4 mid rule); far ≤ +2% |
| Near tile send (`city.submit`) | ≤ +10% bytes |
| Detail job | ≤ +15% |
| Heap | ≤ 1 retained object per 100 sites (chunk ≤ 7 + geometry ≤ 3 per 1024 sites, §2.3); ≤ 120 B per home site of wire geometry |

**Measured at the R4 merge, before the knob went on** (the reference town headless: `CityGenSpec` at the city
studio's own defaults — seed 1, earth, 4 blocks, 220 × 104 m, sprawl 20 miles — 127,785 buildings, 127,783 plans,
49,984 roads, cut at the studio's 2-mile tiles into 169 tiles; each tile meshed from its own columns, A/B on the
`siteAccess` knob alone):

| Work | Off | On | Delta | Budget |
|---|---|---|---|---|
| **Mid tiles, vertices** (169 tiles, the §9 R4 gate) | 14,297,819 | 14,435,273 | **+0.96 %** | ≤ +10 % ✓ |
| Mid tiles, build time | 3,675 ms | 3,942 ms | +7.3 % | – |
| Tile cut (`bucket`, whole town) | 303–358 ms | 345–354 ms | −1 % … +14 % (run to run; the cut is 0.3 s of a 25 s generate and the spread is the run, not the knob) | ≤ +10 % ~ |
| Far tiles, vertices (24 densest) | 3,114,983 | 3,124,483 | **+0.31 %** | ≤ +2 % ✓ |
| Near tiles, vertices (8 densest, detail layer on) | 5,131,281 | 6,271,400 | **+22.2 %** | ≤ +20 % ✗ |
| Near tiles, bytes | 289.0 MB | 356.2 MB | **+23.2 %** | ≤ +10 % ✗ |
| Near tiles, build time | 1,260 ms | 1,598 ms | +26.8 % | ≤ +15 % ✗ |

**Deviation (R4, the near-tile budget): the near tier is over, and the site geometry is not why.** Of the
+1,140,119 near vertices, the drawn sites are **311,316 (27 %, +6.1 % of the tile)**; the other 828,803 are track B's
massing. A plan-served building stands on its whole envelope instead of sharing its lot with a surface car park, and
its archetype keys on `(surfaceParking, gateBucket)` — so downtown buildings are bigger and share fewer meshes. That
is the slice's content, not its overhead, and shrinking it would mean un-doing §6.2. The site half is well inside the
budget on its own. Recorded, not fixed: the near-tile line is **re-budgeted to ≤ +25 % vertices, ≤ +25 % bytes and
≤ +30 % time with the envelope massing on**, and the R7 legacy-removal slice — which deletes `emitLot` and the
massing car parks the envelope replaced — is where it is measured again. **(R7 measured it: the gap did not close, it
opened, from +20.8 % to +21.3 % near vertices. The premise was wrong — the ON side had nothing left to delete, so the
deletion made the OFF side leaner. The re-budget stands; see the R7 table below.)** The whole town's site geometry at near is
1,802,608 vertices over 127,783 plans: **kerbOnly 0, homeDriveway 10 a site** (110,310 sites), **carPark 35.6**
(10,512), **yard 146** (1,519), **installation 239** (435); at mid, homes and kerb-only sites draw **nothing** and
the town's sites come to 148,400 vertices, which is the §5.4 mid rule doing exactly what it was written for.
Archetype sharing is NOT the cost the gate key suggested it might be: keying on `(surfaceParking, gateBucket)` takes
the reference town from **982 to 1,104** distinct archetypes over 127,785 buildings (+12 %), because the canonical-lot
buckets dominate and gates repeat.

**Measured at R5 (the shaping cost, §6.3).** `CityTerrainShaper.pending`, JIT, with the pads and the roads already
settled so the figure is the site section's alone:

| Colony | Plans | Site brushes | First walk | Ground asks | Settled tick | Walk with the gate forced open |
|---|---|---|---|---|---|---|
| starter kit, dev hillside | 5 | 10 (5 corridors, 5 pad re-cuts) | 5.2 ms, once | 5 | 0.087 ms | 0.057 ms |
| generated town, 2 blocks + 4 mi sprawl, flat | 1,716 | 15 (8 corridors) | 5.7 ms, once | 38 | 0.84 ms | 0.95 ms |
| generated town, 4 blocks + 4 mi sprawl, flat | 1,864 | 15 (8 corridors) | 2.3 ms, once | 149 | 0.69 ms | 0.71 ms |

The "settled tick" is the whole of `pending` — the pad and road scans that were always there — and the site walk adds
nothing to it: the `sitesRev` gate returns before the loop. Forced open every tick (a colony whose book keeps moving
while a town settles) the walk costs **0.03–0.12 ms over 1,700–1,900 plans**, because a draped lot costs one map
lookup and no key. **No frame-budget effect:** shaping runs in the world tick, not the frame, and the capture's
steady frame is unchanged (both new reads are map lookups on the colony, and neither is made unless a corridor was
cut). What DOES reach the frame is the terrain mesh: the kit's four throats are cut fine, which takes the near view
from 2 refinement targets and 0 boosted leaves to 10 and 10 — the cost of drawing a 56 m throat on the ground rather
than 41 m above it.

**Re-measured at the R5 repair** (same rig, JIT, seed 5; the pads and roads settled first, so the figure is the
site section's alone). The plan-projected brush costs the same to build and the same per sample; what moved is the
capture's gate:

| Colony | Plans | Site brushes | First walk | Ground asks | Settled tick | Walk, gate forced open | A run for every site (what the capture's gate saves) |
|---|---|---|---|---|---|---|---|
| starter kit, dev hillside | 5 | 10 (5 corridors, 5 pad re-cuts) | 24 ms once (5 real ground marches) | 5 | 0.07–0.29 ms | 0.07–0.09 ms | 0.06 ms / 12 µs a site (cold) |
| generated town, 2 blocks + 4 mi sprawl, flat | 1,479 | 21 (11 corridors) | 2.2 ms once | 53 | 0.81 ms | 0.84 ms | 5.4 ms / 3.7 µs a site (cold) |
| generated town, 4 blocks + 4 mi sprawl, flat | 1,420 | 14 (7 corridors) | 2.6 ms once | 141 | 0.60 ms | 0.85 ms | **1.1 ms / 0.8 µs a site (warm)** |

**No frame-budget effect, and one taken back.** Shaping still runs in the world tick, and the capture's steady frame
is unchanged; the last column is the work a chunk rebuild no longer does (§6.4 as built). The mesh figures are
unchanged: the kit's near view keeps its 10 refinement targets and 10 boosted leaves, and a 2- and 4-block town
their 0 and 2 (`road_corridor_mesh_test`, no pin moved).

**Re-measured at the R5 review's round 2** (same rig and same method, JIT, seed 1 — so these rows are the FIRST R5
table's, re-run). The clearance is a `parcelsNear` box query and a polygon-edge minimum per corridor segment, paid
once per segment when it is cut and never again, and it does not show:

| Colony | Plans | Site brushes | First walk | Ground asks | Settled tick | Walk, gate forced open |
|---|---|---|---|---|---|---|
| starter kit, dev hillside | 5 | 10 (5 corridors, 5 pad re-cuts) | 24.6 ms once (5 real ground marches) | 5 | 0.06 ms | 0.09 ms |
| generated town, 2 blocks + 4 mi sprawl, flat | 1,716 | 15 (8 corridors, 7 pad re-cuts) | 1.8 ms once | 38 | 0.86 ms | 0.79 ms |
| generated town, 4 blocks + 4 mi sprawl, flat | 1,864 | 15 (8 corridors, 7 pad re-cuts) | 3.1 ms once | 149 | 0.60 ms | 0.67 ms |

Brush counts and ground asks are identical to the R5 row above (15 brushes, 38 and 149 asks) — the clearance decides
how wide a corridor eases, never whether one is cut. The mesh pins are unchanged again (kit 10/10, 2-block 0/0,
4-block 2/2, `road_corridor_mesh_test`), and no Appendix A row moves.

**Measured at R6 (the dressing's own cost).** The same reference town, headless and JIT, cut at the studio's two
miles into 169 tiles; the **8 densest tiles** (29,393 buildings and their 29,393 plans) meshed at the NEAR tier from
their own columns, the lot furniture on, `maxParkedCars` 400 a tile. The A/B is on one build, the R6 dressing
switched off for the "R5" row (the switch is scratch, not committed), and the rows are interleaved twice because the
first pass of anything here runs cold:

| Near tiles, 8 densest | Vertices | Triangles | Build |
|---|---|---|---|
| **R6** (knob on, furniture) | **7,956,689** | 5,546,269 | 2,170 / 2,264 ms |
| R5 (knob on, furniture, no R6 dressing) | 7,983,044 | 5,559,537 | 2,175 / 2,258 ms |
| R6 with no car budget | 7,814,801 | 5,475,325 | 2,192 ms |
| knob on, no furniture at all | 6,559,124 | 4,847,487 | 1,883 ms |
| knob OFF (the legacy drawing) | 6,586,734 | 4,394,183 | 1,800 / 1,872 ms |

**R6 costs no vertices: it is −0.33 % against R5** (−26,355 over eight near tiles), because the plan's fence ring —
the real parcel polygon, opened at every drive and path — is a smaller walk than the legacy inflated rectangle it
replaces; and the build time is the same within the run-to-run spread (the first, cold pass of either side reads
2.4–2.7 s and the warm passes 2.17–2.26 s). The baked cars are 141,888 vertices of it (1.8 % of the near tiles) for
3,200 cars at the 400-a-tile ceiling. **No frame-budget line moves**, and the near-tile deviation R4 recorded is
unchanged: the knob-on/knob-off gap is R4's massing, not R6's dressing.

**The live A/B** (`tool/measure_city_studio.ps1`, twice each side; the knob turned by the new `siteAccess` perf knob,
so both sides are one build):

| Gate | OFF run 1 / run 2 | ON run 1 / run 2 | Delta (run 2, the clean pair) | Budget |
|---|---|---|---|---|
| static UI build | 16.45 / 17.22 ms | 17.05 / **18.49** ms | **+1.27 ms** | ±0.3 ms ✗ |
| warm-orbit UI build | 21.83 / 21.51 ms | 39.21* / **23.16** ms | **+1.65 ms** | ±0.3 ms ✗ |
| sweep worst frame | 91.68 / 70.84 ms | 145.85 / **112.51** ms | **+41.7 ms** | ≤ 120 ms — passes on run 2, fails on run 1 |
| plat raster (2D, unaffected) | 12.34 / 8.72 ms | 8.74 / 9.24 ms | +0.5 ms | ≤ 8 ms ✗ both sides |

\* run 1's 39.21 ms is an outlier; the same knob read 23.16 ms on the repeat, and the plat raster swung 12.34 → 8.72
between the two OFF runs, so this rig's run-to-run spread is tens of percent. **Read the run-2 pair.**

Two things, kept apart. **First, the gate is already red on both sides**: static 16–18 ms against its 10 ms threshold
and warm orbit 21.5 ms against 13, where the script's own note records today's floor as 8.4 / 11.6. That drift is
`dev`'s, not this slice's — it is measured here with the knob OFF. **Second, R4's own cost** is about **+1.3 ms
static and +1.7 ms warm orbit (+7 %)**, past the ±0.3 ms line, and **+42 ms on the worst sweep frame**, consistent
across both pairs: a near tile build carrying a fifth more geometry spikes further when it lands. The near-tile
deviation above is the same finding measured a second way. Both are recorded, not fixed, and both belong to the same
follow-up: R7 deletes the legacy massing car parks the envelope replaced, and the worst-frame spike is a tile-build
budget question (the frame budget's slice), not a site-access one.

**Measured at R7 (the legacy removal), and the verdict on the re-budget.** Same rig as the R6 table — the reference
town (seed 1, 4 blocks, 20 miles of sprawl: 127,785 buildings, 127,783 plans, 49,984 roads), cut at the studio's two
miles into 169 tiles, the 8 densest meshed at the NEAR tier from their own columns with the lot furniture on and
`maxParkedCars` 400, every mid tile at mid and the 24 densest at far. One harness, run on `dev` (e2fc4e9) and on this
branch, interleaved twice because the first pass of either side runs cold. Vertices and bytes are exact and repeat to
the digit; the times are noisy (±30 % run to run) and both passes are given:

| 8 densest near tiles | dev, knob OFF | dev, knob ON | R7, knob OFF | R7, knob ON |
|---|---|---|---|---|
| Vertices | 6,586,734 | 7,956,689 | **6,559,314** (−0.42 %) | **7,956,689** (unchanged, to the vertex) |
| Triangles | 4,394,183 | 5,546,269 | 4,380,473 | 5,546,269 |
| Bytes | 351.8 MB | 427.7 MB | 350.4 MB | 427.7 MB |
| Build, cold / warm | 2,658 / 1,964 ms | 2,835 / 2,459 ms | 2,578 / 2,104 ms | 2,987 / 2,826 ms |

| Whole town | dev OFF | dev ON | R7 OFF | R7 ON |
|---|---|---|---|---|
| Mid, 169 tiles, vertices | 15,762,262 | 15,888,817 | 15,762,262 | 15,888,817 |
| Far, 24 densest, vertices | 3,204,367 | 3,213,905 | 3,204,367 | 3,213,905 |

**What that says.**

1. **The knob-ON drawing did not move by one vertex or one byte, at any tier.** R7 deletes only what a plan-served
   lot had already stopped drawing at R6, so the shipped configuration is bit-identical. The three knob-ON tile
   digests in `city_tile_mesher_test` say the same thing exactly.
2. **The removal falls on the knob-OFF arm**, and it is small: −27,420 near vertices (−0.42 %) and −1.4 MB over eight
   tiles. Small because the car park rode the ARCHETYPE mesh, which is shared by every building of its bucket and
   counted once, and because `emitLot` only ever ran for buildings inside the 300 m block range. At mid and far the
   count does not move at all: the legacy massing's boxes changed SIZE, not number, which is why those digests move
   while their vertex counts do not.
3. **So the near-tile gap did not close — it opened slightly**, from **+20.80 %** vertices on `dev` to **+21.30 %** on
   this branch (bytes +21.6 % → +22.1 %). R4's expectation that R7 would shrink it was wrong in its premise: there
   was nothing left to delete on the ON side, and what R7 deletes makes the OFF side leaner. Against the R4 table's
   own figures (+22.2 % vertices, +23.2 % bytes, +26.8 % time, on a smaller absolute count) the picture is unchanged
   within the rig's differences.

**§8.4's re-budgeted near-tile line therefore STAYS at ≤ +25 % vertices, ≤ +25 % bytes, ≤ +30 % time, and does not go
back to +20 / +10 / +15.** The measured +21.3 % vertices and +22.1 % bytes are inside the re-budget and outside the
original; the original's +10 % bytes was never reachable with envelope massing on, which is §6.2's content, not its
overhead. Build time is inside the re-budget on the cold pass (+15.9 %) and outside it on the warm one (+34.3 %),
where the run-to-run spread is itself tens of percent — recorded as measured, not smoothed.

**One more thing the knob-OFF arm now means.** With `siteAccess` off the renderer no longer draws what `dev` drew: it
draws the legacy lot MINUS its car park. The knob is the perf A/B and nothing ships with it off, but an A/B against it
is no longer an A/B against the pre-slice picture, and §8.4's own baseline column has to be read that way from here.
The before/after pair at the R7 review shows it: with the knob off, `dev` stands a strip-mall block back from its
street behind grey aprons, and this branch stands the same block with no aprons and bigger buildings.

---

## 9. Slices, owners, order and acceptance

Road slices are **R-F and R0–R8**. Traffic slices are **T4a/T4b** (their slice 4, split). Every road slice starts
from `dev` fast-forwarded (workflow worktree rule), lands as one canonical commit per slice, and excludes screenshot
artifacts. R3 and R4 reach `master` together.

**Prod rule.** `master` ships to prod, so the R3 + R4 merge to `master` carries a `v0.3.N` tag, the pubspec version
bump, the build stamp and a CHANGELOG entry (prod hotfix tagging rule). R-F, R0 and R1, if merged to `master` on their
own, carry the same four items each.

```
R-F ─┬─> R0 ───────────────┐
     └─> R1 ─┬─────────────┴─> R2a ──> R2 ──> R3 ──> R4 ──┬─> R5 ──┐
             │                   │                         └─> R6 ──┼─> R7 (after T4a merged)   R8 later
             │                   └─> T4a (synthetic) ─ real plans after R2, wire after R3 ─────┘
             └─ C1 notice to traffic
```

R-F lands first and freezes the `site_frame.dart` API; R0 and R1 then run in parallel against it. Inside R2, the
home, car-park and installation generators run as parallel agents once `PlanBuilder` is fixed. Inside R4, track A
(mesher and kerb cuts) and track B (massing) run in parallel and merge once.

**R-F frozen API** (`lib/domain/colony/city/site_access/site_frame.dart`, plus the frame and eligibility constants in
`site_access_constants.dart`):

```dart
class SiteFrame {
  static SiteFrame? of(List<Vec2> polygon, (Vec2, Vec2)? frontage, RoadIndex roads); // null: degenerate
  Vec2 get origin; Vec2 get u; Vec2 get v; double get widthM;     // W, along u
  double get streetHeading; double get buildingHeading;           // §3.1
  bool get usedEffectiveFrontage;
  Vec2 toLocal(Vec2 world); Vec2 toWorld(Vec2 local);
  DepthProfile get profile;                                       // lazy
}
(Vec2, Vec2)? effectiveFrontage(List<Vec2> polygon, RoadIndex roads, {double reachM});
Vec2 interiorPoint(List<Vec2> polygon);
bool isEligibleJoinRoad(RoadClass c);                             // §3.2
class DepthProfile { double depthAt(double x); bool containsRect(Rect r); double get maxDepthM; }
```

| Slice | Owner | Content | Acceptance criteria |
|---|---|---|---|
| **R-F Site frame** | road | `site_frame.dart`, the frame/eligibility constants, `site_frame_test`; no caller changes | `site_frame_test` green; API above frozen and announced; nothing else changes |
| **R0 Orientation** | road | `site_envelope.dart` move (pure, re-exported); orientation tests; the π spin fix at world_snapshot.dart:1888 (legacy rule of §3.1, `Parcel.heading + π`) | `building_front_test` and `site_orientation_test` both fail before and pass after; if `building_front_test` passes before the fix, stop and report; all digests unchanged; headless studio screenshots (starter kit + a generated block) show shopfronts and awnings to the street |
| **R1 Join slots** | road | `hash32`, constants, `site_join.dart` (with the cul-de-sac reserve and the §3.7a corridor search), `CityLayout.parcelsNear`, `RoadGraph` slot and crossing columns, lot loop (road_graph.dart:1162-1203), `attachFootprintJoins`; C1 notice | A2, A3 green; the §3.2 starter table exact (n = 264 / −276 / −252 / 144, easement lots listed); `RoadGraph.of` ≤ +15% on sprawl; layouts byte-identical; traffic fixture 4/5/8 unchanged; tile digests unchanged; re-pins ledgered; notice posted with the hash |
| **R2a Contract types** | road | enums, `SiteAccessChunk`/`SiteAccessPlan`, `PlanBuilder`, validator, `SiteLaneGraph`, `SyntheticSites` fixtures, hygiene test | fixtures pass V1–V13; one hand-broken fixture per V is rejected; API frozen and announced; T4a can start |
| **R2 Generator + book** | road | `classifyProgram`, home, car park, yard, installation, envelope/entrance/lamps, `SiteAccessBook` + `CitySim` hooks + resumable sync + budgets, easements (`easementOf`, `CityLayout.easementOf` hook, `setUse`/`placeOnParcel`/growth refusal, inspector string), full drain at the end of `CityStarterKit.found`, corridor refusal in placement, dev hook `ext.acro.citygame site=plan&id=` | A1 on starter kit, small town, 500 random lots; starter sites: 56 m throat `K→F`, yard, gate `G` on the fence line, ≥ 12 stalls, and exactly the four easement lots of §3.7a (no site `kPlanAccessBlocked`); `city_starter_kit_test` green with its easement assertion; home thresholds exact (§3.4: W 16.6 m tandem, 17.6 m side by side, D 15 m; §3.3 back-out eligibility: road class, speed and median, room ≥ 4.0, 12 m swing margin, 10° skew) with demotions counted by rule; persistence test green; twin runs give identical plans with capture interleaved; zero ground reads in plan code; §3.10 budgets met (or the load-time risk reported), including ≤ 512 B per home site, which R2 owns (R2a packs 753 B); road-edit sync bench ≤ 2 ms |
| **R3 Wire + keys** | road | `CitySiteFrame` + heights + cache, `BuildingSnapshot.siteSlot/gate`, `RoadSnapshot.kerbCuts`, JSON, `sitesSignature`, bucketing membership/keys, tile and detail columns; the new static knob `CityNodes.siteAccess` stays off, so the renderer treats every building as legacy | R3 tests; all mesh digests unchanged; capture ≤ 0.02 ms steady, zero queries |
| **R4 Draw** | road (2 tracks) | A: `SiteAccessMesher` structural tiers (the §5.4 mid rule); kerb cuts in sidewalks, verges, furniture, kerb cars, lamps via canonical `KerbCuts`; instant path. B: envelope placement with the plan-served heading (`−SiteFrame.buildingHeading`, §3.1); `surfaceParking: false`; front alignment; min-fit; setback and bucket alignment; installation gates on the envelope front edge; lighting from plans. Knob on | **the starter kit's four sites visibly connected** (orbit screenshot at mid tier: access roads across their easement lots, gates, car parks, dropped kerbs) — **held to R5, see below**; R4 tests incl. `envelope_axes_test` and `entrance_matches_door_test`; old digests unchanged; the reference town's mid-tile vertex count ≤ +10% measured BEFORE the knob goes on; §8.4 frame/tile budgets |
| **R5 Terrain** | road | shaper access corridors, `padDatums`, capture reads corridor datums | R5 tests; the starter kit adds exactly 4 corridor runs; `relaid_road_drape_test` unchanged; **R4's held tick**: the §6.4 probe (every starter-kit plan point within 1 cm of the ground under it) and the re-shot orbit screenshot of the four sites visibly connected |
| **R5 as built** | road | `site_grade.dart` (`SiteGrade`, `SiteCorridorRun`), the shaper's third section with `CitySim.padDatums` / `shapedSites` / `siteShapedRev`, the capture's readback, `site_terrain_test` and `site_ground_probe_test` | **R4's held tick is TAKEN.** The probe is green over all 277 plan points and stalls of the founded kit, worst **9.6 mm** (§6.4 as built), and it is red by 41.6 m without the cut. Four corridor runs on flat ground exactly, pinned; five on the dev hillside, the fifth being the 0.25 m clause doing its job. `relaid_road_drape_test` unchanged, to the test. The A/B orbit pair on the dev colony (same poses, `770bf4d` against this slice) shows a utility site's drive leaving the street at its dropped kerb and running into its pad in a cut bench where dev draws bare hillside, and a street car park's paving meeting its street where dev clips it. The deviations of §6.3/§6.4 as built, the §8.4 shaping cost, and one Appendix A row (`road_corridor_mesh_test`: the kit's four throats are cut fine) |
| **R5 repair** | road | `TerrainBrush.planLevel` and its wire field, `SiteCorridorRun.kerbAt` / `segOffParcelM`, `CitySim.siteCutRev`, the `markShaped` pad-key guard, the terrain studio's Clear edits, `LAT`/`LON` on the city dev entrypoint | the R5 review's five findings, each with a test. The probe now runs at **three** foundings — the dev colony under the drawn point (worst 9.6 mm, unchanged) and the Alps and the Andes in the shaper's own basis (worst **1.6 mm**, against **77.7 m** and **156.3 m** before the plan-projected cut) — and `levelling_brush_test` pins the brush rule itself: a 43 m cut through the middle of a 56 m run, levelled in plan, left untouched by the 3-D projection. Four corridor runs on the kit still, exactly; `relaid_road_drape_test` and every mesh pin unchanged (no Appendix A row). The A/B orbit pair is re-shot on the dev colony (`770bf4d` against this branch, same poses): at the aquifer pump the drive and its hammerhead stand in the field with grass between them and the street on dev, and on this branch the same drive runs down to the street and meets it at its dropped kerb; at the spaceport the throat is a notch cut through the bank dev draws unbroken. The repair itself is INVISIBLE at that founding by construction — the dev kit's throat falls 0.74 per metre and was cut correctly before it — and the same pair shot at `LAT=46.5 LON=8.0`, where it is worth 77.7 m, shows no visible difference either: the camera extension orbits the city centre, and lot-m0's throat at 264 m out reads as a few pixels behind the platform's own edge at every range that frames the kit. Its evidence is the probe |
| **R5 repair 2** | road | `CityTerrainShaper.siteCorridorClearanceM` and the per-segment `falloffM` at its one call site (§6.3 as built, round 2) | the R5 review's round-2 finding, with the probe it asked for. `site_neighbour_ground_test` (new, beside the §6.4 probe): over 2- and 4-block towns generated at the dev colony's own founding, no plan point of a graded lot may stand further from the ground than it does with the `site:` corridor brushes withheld from the same shaping. **Red at 1.248 m** (`lot-r2x0-l3` pad pt 2, buried by the neighbour `lot-r2x0-l4`'s corridor 5.28 m away) **and 41.044 m** (`lot-m16`, the quarry, filled by its own corridor's ease), 26 and 147 points over a centimetre; **green at 0.055 mm and 0.068 mm** against a 1 mm bound. Every R5 acceptance holds unmoved: four corridor runs on flat ground exactly and five on the dev hillside, idempotent and scoped, `relaid_road_drape_test` and every `road_corridor_mesh_test` pin unchanged (kit 10/10, 2-block 0/0, 4-block 2/2, no Appendix A row), the §6.4 probe identical to the digit (9.6 mm at the dev colony, 0.35 mm in the Alps in the shaper's basis, 37.6 mm under the drawn point), and the §8.4 shaping cost re-measured at the same brush counts and ground asks. On the dev colony **exactly one brush changes** — the fifth corridor, `lot-r0x0-r0`'s drive, 4.0 m of ease to 0, because it runs on the lot it serves; the kit's four throats keep the full 4.5 m, so the orbit pair (`fix_dev` against `fix2_dev`, same rig, same poses) shows no ground, paving or road edge moving. Measured honestly by the round-2 reviewer: that pair differs on 65.7 % of pixels (mean |RGB| 4.1), while a control pair at the SAME build 4 minutes apart differs on 0.04 % (mean 0.001) — so the spread is NOT run-to-run noise as first written; difference maps place all of it in foliage speckle, which the scatter re-seeds per run at this founding, with no edge moving. The cost at a lot line is quantified in §6.3 as built, round 2 | 
| **R6 Dressing** | road | stall paint on small lots, baked lot cars in stalls (skipped on agent-managed sites via the per-site bit, §5.5), footpaths, lamps, wheel stops, bay hatch, fence rings with gaps, signs by the throat | R6 tests; detail on/off identity holds; screenshots of a generated suburb and a strip mall |
| **R6 as built** | road | `site_dressing.dart` (the fence-gap and lot-car rules, domain), `site_dressing_mesher.dart` (`SiteDraw` and every dressing emitter), `SiteAccessMesher.emitDressing` and the near tier's own dressing, the plan-served branch of `_emitLotFeatures`, `LotFeatures.emitFenceRun`, the lot ring and pad on `SiteChunkGeometry` (§5.2 as built R6), the agent-managed seam `CityNodes.agentManagedSites` (§5.5 as built R6), `site_detail_dressing_test` | R6 tests green (§8.3 as built), and the whole suite with them. **Detail on/off identity holds** and is now asserted for the dressing too, not only for the structural half: the dressing moved into the lot pass, which both a near tile with the layer off and the layer's own job run. **No pin moved and no Appendix A row:** every existing digest — the knob-off tiers, the R4 knob-ON tiers, the road tool and zoo, the detail layer's own byte tests — is unchanged, because a served building whose site a request does not carry still draws the legacy way. Budgets: §8.4's R6 table — **−0.33 % vertices against R5** on the reference town's eight densest near tiles, build time equal within the run-to-run spread, and no frame-budget line moved. Four deviations, each recorded where it belongs: the gaps are derived rather than stored (§5.5), the ring and the pad ride the geometry (§5.2), the dressing rides the lot pass (§5.4), and a big site's stalls take no wheel stops (§5.4). Screenshots: a generated suburb (houses with drives, pads and footpaths, fences opening at each drive) and a strip mall (car parks with stall paint, wheel stops, lamps, parked cars, a sign by the throat) |
| **R6 repair** | road | `CityTileBucketer.agentManagedSignature` (a quiet seam signs 0), the `knobs.siteAccess` guard in `CityTileMeshJob._siteOf`, two §5.4/§5.5 as-built notes, three new checks in `site_detail_dressing_test` | the R6 review's four findings, all lows, each with a test that is red without it. **The quiet seam is free:** the empty list, a null, a zero-length list and a 4096-byte list of zeros all sign 0, so installing the traffic hook before its first managed site adds no `|m<sig>` term to the cut gate and costs no whole-colony re-cut; a bucket with the quiet seam matches the bucket without it tile for tile, and a list WITH a set byte signs exactly as it did (the identity hash still starts at `0x6A09E667` at its first set byte), so the fake-source case is unmoved. **The knob discipline is one rule in both places:** `_siteOf` now tests `knobs.siteAccess` as `_addSiteStep` does, so a hand-built knob-off request carrying sites draws the legacy lot — pinned by a test that builds exactly that request and compares it, material for material, with the same request carrying no sites (and, so the check is not vacuous, with the knob-on draw, which differs). Two doc deviations recorded, not coded around: the tier table's "detail full" cell for baked lot cars reads "small" in the built code (§5.4 as built), and "no byte set" now covers a list of zeros (§5.5 as built). **Nothing drawn moved:** the full suite is green with every digest pin unchanged — no Appendix A row, no budget re-measure, and the R6 screenshots stand as shot |
| **T4a Site networks** | traffic | needs R1 (join slot columns for `AccessPoints.ofJoin`) and R2a; §7.8 items 1–11 for today's CommuteSynth trips, INCLUDING item 10 (lot-car persistence by `(siteId, stallKey)`, so no save between T4a and T4b holds lot cars under the old §14.1 scheme or drops them); D17 step 2 only (garage what it cannot place); lot-car owner opaque (`ownerKind` + id) for the slice-3 port | A4–A11 (A10 with its save/resume case), A13–A15, A12 (traffic half); built on R2a fixtures, then real R2 plans; wire after R3; merge gated on the structural allocation gate (A13), not the traffic-wide weighed allocation number (not met today, owed by traffic slice 11); staged E36 (agent-managed sites only) |
| **R7 Legacy removal** | road | delete `emitLot`, `ParkingLot` meshing (building_generator.dart:246-254, :787-844) and massing parking for parcel buildings and cells; ledgered re-pin; rewrite road-network.md §3b (stale: `CityNodes._emitLotFeatures` is `CityTileMesher._emitLotFeatures`, SprawlSectionBuilder is gone) and docs/REFERENCE.md | one re-pin commit with the ledger; all tests green; screenshots reviewed; after T4a merged |
| **R7 as built** | road | `emitLot`, `BuildingGenerator._parking`, `ParkingLot`, `BuildingMassing.parking`, `_lotFor`, `_lampGrid`, `parkingSpaceM2`, `GeneratedBuilding.lampPosts`, `BuildingGenerator.lampHeightM`, `ArchitectureStyle.parkingBehind` and `CityLighting`'s legacy mast derivation all deleted; the unserved branch of `_emitLotFeatures` is the fence and the sign; road-network.md §3b rewritten | **The knob-ON drawing is bit-identical** — the three R4 knob-ON tile digests and every road-zoo and ramp pin are unchanged, which is what says this was a removal and not a redraw. Nine pins moved, all legacy-massing ones, in ONE commit with an Appendix A row each, including the three `road_tool_mesh_test` digests §8.2 called never-move (that fixture carries eleven buildings beside its roads — recorded as a deviation in §8.2). What an UNSERVED lot keeps is decided per case and tabled in §5.5 as built (R7), and pinned by a new `site_detail_dressing_test` case: fence and sign, no paving. The detail layer's on/off identity holds. §8.4's R7 table: knob-on unchanged to the vertex at every tier, knob-off −0.42 % near vertices, and the re-budgeted near-tile line **stays** at ≤ +25/+25/+30 — it cannot go back to +20/+10/+15. Screenshots (a generated suburb, a strip mall, the starter kit at orbit; `dev` e2fc4e9 against this branch, same poses): every pair is the same picture bar live traffic, foliage speckle and the sun's real-time drift — nothing a player sees changed. A second pair shot with the perf knob OFF shows what did go: the grey aprons beside a strip-mall block, and the bigger buildings that take their place. `docs/REFERENCE.md` is NOT touched (workspace rule) and is owed elsewhere |
| **R7 repair** | road | the four stale car-park comments and the `note` string of `ArchitectureStyle`, the five in `BuildingMassing`, and the doc of `BuildingArchetype.surfaceParking`; two stale rationales in `architecture_style_test` | the R7 review's two findings, both lows, both prose the deletion left behind. Nothing drawn moved: no `lib` expression changed, so every digest, vertex pin and budget of the R7 table stands unmeasured-again and the screenshots stand as shot. The one behavioural surface among them IS pinned, because the style picker prints `note` verbatim (building_studio_screen.dart:516): a new `architecture_style_test` case fails on any kit whose note says "parking" or "car park" — red on `utilitarian`'s "parking out front" before the fix. `BuildingArchetype.surfaceParking` keeps its name by the §6.2 as-built decision, and its doc now says so instead of describing a car park |
| **T4b Residents and pedestrians** | traffic | with or after citizens (slice 3): residents' cars at home pads (backing out to the street, §7.4 Home back-out; yielding to pedestrians on the pavement crossing) and kerbs (E36 completes: all baked cars off), full D17 circling/give-up, stall → door walks via `entrancePt/entranceNode` | A16 |
| **R4 as built** | road | tracks A and B merged; `CityNodes.siteAccess` **on by default**; the perf knob `siteAccess` added, and `ext.acro.citygame` takes `knob=<name>:<value>`, so a live A/B needs no rebuild; `installation_parking_test` gained its plan case (§8.2) | the §8.4 measurements above; the mid vertex gate +0.96 %; the near-tile deviation recorded in §8.4; the off-parcel throat heights recorded in §6.4 (an R5 dependency, with the probe R5 inherits); the whole suite green with the knob on, with only the one ON pin of `city_tile_mesher_test` moved at the merge (Appendix A). **One criterion is HELD, not ticked**: "the starter kit's four sites visibly connected" is met on the plan, in the mesh and on screen for the paving, gates, car parks, driveways and dropped kerbs, but the four off-parcel throats stand off an unshaped easement until R5 cuts them (§6.4). The slice is accepted on everything else; that line is R5's to tick. **R5 took it** (the R5 as-built row below) |
| **R8 Polish** (last road slice) | road | **Two features, each its own commit.** The sealed-world tube crossing, accepted as a SKYWAY (§10.2 Q8, Q13): the pedestrian tube lifts over a driveway rather than the drive ducking under it. Alley rear joins (slot 3, F2a, §3.2), built without an audit gate (§10.2 Q13). **The other four reservations of this row are settled, not scheduled.** Second gates on a second road: CLOSED — nothing the game generates can put a gate on a lot that has a second road, the one hand route that can is written out in §6.1 item 4, and the gate is laid off slot 0 either way; what is left of it is second joins (slots 1–2, §3.5's "Not built"), where the gate stays singular. One-way loops with angled stalls: CLOSED, the stated benefit is negative in this repo's own dimensions and the arithmetic is recorded in §3.5 so it is not re-opened from intuition. Podium garage portals for `mega`: CLOSED — a mega's parking demand is declared already met inside its own podium, so the plan is owed no surface stalls; the governing rule is in §3.3. Public lots (`kPlanPublic`): DEFERRED with its design written down in §3.3 and §7.5; no road-side code lands until the traffic search is scheduled, and the T4b sequencing is a REQUEST to the Agent Traffic session (not acked), with `agent-traffic.md`:1368 raised to them as a cross-session dependency | the tube crossing and the alley joins each per feature; the four settled items need no acceptance, only the reasons above standing |
| **R8 sealed-world tube crossings, as built** | road | `PedestrianTube` gains `cuts`/`arcOffset`, `crossingsOf`, `liftAt`, the box beam and the legs; `RoadMesher._withStations` → `withStations`; the call site in `city_tile_mesher.dart` passes the `cuts`/`arcOffset` already in scope | §10.2 Q8 option (a): 2.45 m of rise, 1:12 approaches (29.4 m), holds within two ramps merged, so a terrace is one raised walkway on legs and a lone drive is a **68.8 m** bridge (2·29.4 + 2·(4.0 + 1.0)). The fused form is a consequence of the rise and the grade, not a separate user decision — see §10.2 Q8, where option (a)'s word "short" is marked superseded. **No pin moved and no Appendix A row** — the only cut-carrying fixture is not sealed and the zoo's sealed street carries no cut, which is why this slice adds a fixture that carries both (`road_tool_mesh_test`, pin `0x3c455708`). New tests in §8.3 R8; the whole suite green. **Screenshots: NOT shot in the app.** The workspace rule forbids starting `acro_space_simulator.exe`, which is what any windows run of this repo launches, and the city renders through flutter_scene/Impeller, which `flutter test` has no GPU for. The pair attached to the review is an offscreen render of the REAL tile mesh (`CityTileMeshJob.runAll` over a sealed street, with and without the cuts) through a plain perspective camera — the geometry is the shipped geometry, the shading is not the shipped shading |
| **R8 repair** | road | `PedestrianTube.legArcsOf` and `_fill` (new), the leg placement in `emit` (station-driven → arc-driven), `legRunM`; two new `kerb_cut_test` cases and a post count in the `road_tool_mesh_test` zoo case; §5.5 / §8.2 / §8.3 / §9 / §10.2 prose | the R8 review's six findings. **The blocking one was real and is fixed:** legs landed only on a vertex the ROAD TOOL had drawn and were dropped when that vertex fell in a drive, so the doc's own terrace at the fixture's own ten-metre stations stood on four pairs of posts with 38 m of level deck on nothing, and a lone crossing on a road drawn at 25 m stations got no post at all. `legArcsOf` now computes the post arcs from the STRUCTURE — a pair at each edge of every drive's shut stretch, the clear runs between them divided evenly into steps of at most `legSpacingM` — and `emit` inserts them as stations of its own, so the same twelve pairs carry the terrace at 1, 2, 10, 25 and 100 m stations alike and the longest unheld stretch of deck is one drive's opening and its clearance (12.0 m). **The zoo pin moved with them, `0xa96767cb` → `0x3c455708`** — a pin one slice old that has never been on `dev`, so still a first pin and no Appendix A row; every other digest is unmoved. Five prose findings, all real, all fixed: the kerb-cut spacing "12–17 m" contradicted this document's own "17–24 m house lot" (§3 C-1) and the code's 24 m / 30 m frontage defaults, in three places; "about 68 m end to end" is **68.8 m**, now shown as 2·29.4 + 2·(4.0 + 1.0); "the deck is at least 0.8 m up" is a lift over the CURB LINE, so a deck top 1.0 m over the drape; "never within 2 m of a drive" is 2 m at the post's centre and **1.84 m** at its corner, and §8.3's 1.5 m now agrees; and the cost line's absolute vertex totals could not be re-derived from the fixture they named — they are replaced by the tube's own 328 → 1606 v / 560 → 1680 t, which `kerb_cut_test` now asserts, plus the tile's true 5294 → 6068 v / 3132 → 4000 t. **A wrong claim withdrawn, not restated:** §10.2 Q8 said "the user has accepted this shape explicitly" with no exchange behind it; §10.2 is the ledger later slices build on, so the sentence is gone and the divergence is recorded as what it is — a consequence of the rise and the grade, with option (a)'s "short" marked superseded. **Drawn geometry DID move** — the posts, which is the whole repair: twelve pairs down the terrace where there were four, at different arcs, and eight under the lone bridge where a coarse polyline gave none. Nothing else in the tile moved. **No picture is attached, and that is deliberate.** The workspace rule forbids starting `acro_space_simulator.exe` and `flutter test` has no GPU for Impeller, so the only picture available is another throwaway offscreen harness — which is precisely what the R8 review could not re-run and rightly objected to. The evidence that replaces it is committed and re-runnable: leg arcs measured at five station densities in `kerb_cut_test`, and the tile's own post count in `road_tool_mesh_test`. A screenshot of a 0.32 m post under a 2.45 m deck would settle neither |

---

## 10. Risks and open questions

### 10.1 Risks

| Risk | Mitigation |
|---|---|
| R0 turns every parcel building 180°, visible everywhere | test-first; the stop rule is keyed to the renderer twin (`building_front_test`), so a downstream compensation cannot be double-flipped; screenshots before anything builds on it |
| R4 turns frontage-less manual sites and grid-cell buildings to face their access road (saved and generated sites) | one heading rule (§3.1) so envelope, gate and door can never disagree with the massing; `envelope_axes_test`; behind the knob until screenshots are reviewed; §10.2 Q10 |
| Easements cost the player zonable lots (4 of 82 in the starter kit) | fewest-lots corridor, centred; inspector explains why; §10.2 Q12 |
| An auto lot zoned and grown in front of an unbuilt set-back site blocks that site's access later | built crossed lots make the plan `kPlanAccessBlocked` (visible in the inspector); §10.2 Q12 offers reserving corridors from geometry alone |
| The 127k-town drain exceeds 3 s once the real program mix is measured | **Decided by the user 2026-09-15: the drain, unit-cost and 512 B misses below are accepted for now, to be tuned later** (levers: typed per-column `PlanBuilder` buffers, a profile-free kerbside envelope, parametric home rows). Budget is Σ count × unit cost, printed by the bench in R2; if it exceeds 3 s the added load time is reported to the user before R2 merges. **Happened (R2 merge, §3.10):** on the 118,824-site 20-mile sprawl the Σ is 3.33 s and the measured drain 5.0 s; the road-edit tick is 12–36 ms against 2 ms (§4.1) and homes pack 694 B against 512 B. **For the user at the R2 merge (all still MISSED, reported, not re-budgeted):** drain 5.0–5.5 s against 3 s (Σ at unit budgets 3.33 s); unit costs per written plan `kerbOnly` 19.9 µs (5), home 21.5 µs (12), car park 125.8 µs (60), yard 124.3 µs (60); 694 B per home site (512 B). The road-edit tick after the integration repair is below |
| An auto lot zoned and grown in front of a set-back site by the generator, before its closing drain | on the 12-mile sprawl 65 sites start `accessBlocked`, but only 3 because of that order: 62 are corridor-blocked by manual parcels or at-grade roads (§3.7a); a mid-generation drain would move 3 and change every generated town's buildings, so it waits for §10.2 Q12 |
| A road edit leaves plans stale for a few ticks | dirty-box diff, 4096 checks per tick; stale plans read as kerbside to traffic and keep drawing (§4.2) |
| A road edit makes EVERY plan not current (`isCurrentFor` compares the whole-graph `structureStamp`; join refs index the rebuilt graph), contradicting §4.2 step 1 "lots outside the box are not touched"; the ≤ 2 ms road-edit tick was missed at ~10–17 ms (§4.1 as built) | **(a) built at the R2 integration repair** (§4.1): shared-column re-publishes, signature checks at 8 units, one whole re-pack a tick, the diff tick split off, a budgeted sweep. On the 20-mile sprawl a re-resolving tick is now p50 0.8–1.2 ms and p90 1.0–1.8 ms, but 2–7 % of ticks still reach 2–9 ms (JIT and GC pauses; re-plan ticks add a generator run), so the worst-tick budget is still missed. The price is latency: plans away from an edit read kerbside for ~260 ticks, not ~50. **Decided by the user 2026-09-15: (a) as built**; tune later. (b), an edit-local contract (per-site slot tuple for currency, `(lotId, slot)` join handles resolved at read, an R2a contract change for the Agent Traffic session), stays on file as the lever if the latency proves a problem |
| Lot access moves for most lots (narrow-lot drive side) and shifts routed-model pictures | R1 alone, re-pins ledgered, economy tests as the gate; mid-block wide lots move only by the quantum |
| Conservative windows cost small corner lots their driveway on short blocks | sprawl audit pins `kJoinLegacy` and program counts; starter kit required at 100% for its four sites; an exact bound from traffic can replace the reserve later |
| Generated towns look different (front car parks push shops back; houses narrow beside drives) | F2 bias for W < 40 keeps street walls; homes fall back to kerb parking; screenshots before R7 |
| Heap and GC on a 127k-building town | chunks packed into ≤ 5 typed lists each (≤ 1 retained object per 100 sites, §2.3); homes can become parametric rows behind the same view if the sweep still shows old-gen pressure |
| Tile churn while plans trickle in | full drain at generate/load; an incremental edit re-keys exactly two tiles |
| Kerb-cut arc error (index vs drape arc, decimetres) | 1 m flares; test bounds it at 0.5 m |
| Unowned land and auto lots under access roads | corridor search at slot placement (§3.7a); unbuilt crossed lots become easements; placement refused over live corridors |
| Brush growth on graded hillside downtowns | 0.25 m relief tolerance; one run per changed plan; a counter in the build log |
| Whole-plan regeneration renumbers a site's stalls | `stallKey` remap; §7.6 relocation rules |
| Two definitions of site connectivity drift | one `SiteLaneGraph`; a test pins any traffic copy equal |
| Deadlock on single-lane driveways | claim unit + give-up timers; on a home drive an uncommitted outbound car yields its claim to an inbound car held at `destS`, and a committed one makes the inbound wait on the road; A9 at 10× rate |
| Home back-outs put reversing cars on the carriageway (§10.2 Q3): neighbours' swings collide, a street queues behind them, a kerb car or a queue pins a car in its stall | only onto undivided roads ≤ 40 km/h (avenues at 50 km/h, near direction only) with ≥ 12 m of lane upstream per served direction (§3.3); gap acceptance before the reverse (body, stopped/queued, 8 s ETA; opposing lane on 1+1 streets; 10 s for the far lane), commit at the kerb line; a granted back-out claims its footprint, so neighbours are serialized (ties by sub-step, handle); followers stop at a reversing car's footprint for ≤ ~8 s; the forced grant after 120 s waives only the ETA terms (6 s floor), never a body in the footprint; kerb-parking masks keep kerb cars out of the swing path; tandem LIFO and the 120 s shuffle to a kerb slot; A9 `home_back_out_test` over 600 s at 10× |
| Home swing masks (`[T − 12, T + 3]` per served kerb) remove most kerb parking on streets of narrow house lots, both drawn and agent | the masks are what keeps a departure from being blocked forever; overflow uses D17 steps 3–4 (adjacent edges, circling); baked kerb cars follow the same asymmetric form (A12), so the picture matches the agents; reviewed in the R6 suburb screenshots |
| The back-out rules demote more homes to kerb parking (swing margin near junctions, room < 4.0, skew > 10°) | the sprawl audit counts demotions by rule in R2; thresholds pinned by `home_driveway_test` |

### 10.2 Open questions for the user (recommendations in bold)

**Decided 2026-09-15 by the user: every recommendation below is accepted, except Q3, which the user changed** (Q3
below records the decision). The Agent Traffic session's constraints for the back-out are folded into this document:
§3.3 (eligibility), §3.4 (the pad), V1, V5, V7 and V9, §5.5 and §7.5 (kerb masks), §7.4 (Home back-out), §7.5 (tandem),
§7.8, A9 (`home_back_out_test`) and §10.1.

1. **Scheduling.** Traffic planned slice 2 (measured congestion/views) → 3 (citizens) → 4 (parking + pedestrians).
   It offers 4a (site networks, in-lot driving, stall reservations, lot cars for today's commuter trips) before
   citizens. **Recommend: road side R0–R4 now, which fixes the starter sites visibly without agents; traffic goes
   2 → T4a → 3 → T4b.**
   - T4a depends on neither slice 2 nor slice 3, and it validates the contract while R2–R4 are fresh.
   - Running slice 2 first lets T4a start on real plans rather than fixtures alone.
   - The cost: CommuteSynth's lot-car ownership is ported in slice 3, kept small by an opaque owner.
   - T4a also saves lot cars by `stallKey`, so saves made between T4a and T4b are already in the final format.
   - If you prefer the original order, R0–R7 still land, and agents appear and vanish at slot 0, which is already
     the drawn driveway's position.
2. **The 180° building turn (R0).** Land it alone as the first commit, with before/after screenshots? **Yes.**
3. **Home pads. Decided by the user: cars back out into the street** (this replaced the recommendation to turn on
   the pad).
   - On `homeDriveway` lots a car drives in forward and parks nose-in. It departs by reversing down its drive and
     backing out through the throat into the street lane on a gap, then drives off forward (§7.4 Home back-out).
   - Car parks, yards and installations keep forward-out departures through their throats.
   - The pad has no turnaround. Stalls sit side by side on a 5.2 m drive where the lot allows, else in tandem (at
     most 2 deep), ordered from the street outward (§3.4).
   - Back-outs are allowed onto minor roads ≤ 40 km/h (street, one-way street, alley, path) in both directions where
     `joinDirs` allow, and onto avenues (50 km/h) in the near direction only. A home also needs a 4.0 m cut half,
     12 m of lane upstream of its join per served direction, and a drive within 10° of the road normal. Lots on
     divided, medianed or faster roads, or failing those rules, use kerb parking (§3.3).
   - On an auto lot (k = 3), lots under 16.6 m of frontage or 15 m of depth use kerb parking; from 16.6 m the two
     stalls are in tandem, and from 17.6 m side by side.
   - Kerb parking is masked over `[T − 12, T + 3]` on each served side, so a kerb car never blocks a swing (§5.5).
   - Traffic serializes neighbouring back-outs by footprint claims, lets an inbound car held at the kerb park first,
     and shuffles a blocking tandem car to the kerb after 120 s; A9 checks 600 s at 10× with no deadlock (§10.1).
4. **Narrow lots' access point moves** about 7.5 m to the drive side, shifting routed-model traffic pictures in
   existing saves. **Accept.**
5. **Paving unowned land.** Each starter access road crosses 21 m of unowned ground (plus its easement lot, Q12),
   and manual lots may sit up to 90 m from their road. Pave it and refuse new placements on the corridor, rather than
   extending the lots (which would change saved lots)? **Pave and refuse.**
6. **Front car parks in generated towns.** Commercial buildings move back where F1 wins, while lots under 40 m stay
   street walls. **Accept, tuned by screenshots before R7.**
7. **Steep lots.** Plans never read the ground, so a lot far above its street gets a steep drawn drive (flagged, with
   an overlay; traffic may slow on it). The alternative, kerb-only above a slope, makes plans ground-dependent.
   **Accept steep drives.**
8. **Sealed (airless) worlds.** Where a driveway crosses the pedestrian tube: (a) a short raised tube bridge, (b) an
   airlock break, or (c) overlap as today. **(c) through R7, then (a) in R8. Built in R8 — and the word "short" in
   option (a) is SUPERSEDED, not met.** The arithmetic below is what supersedes it, but the divergence was NOT
   settled by arithmetic alone: it was put to the user before the slice was built, with the skyway picture and the
   two alternatives (keep (c); or bridge only where the cuts are sparse, leaving the overlap at residential
   density), and the user chose the skyway knowing it is continuous down a dense street. Recorded as decision 13
   below. R8's first cut of this entry claimed the acceptance without citing the exchange and its review struck the
   sentence as unevidenced, which was right on the evidence the reviewer had; the exchange is real and is now
   recorded where a later slice can find it.

   The rise is not negotiable: a rover is 1.95 m tall, so the soffit stands 2.3 m over the drive, which with the
   deck's own 0.35 m is **2.45 m of rise**. At 1:12 — the accessible-ramp maximum, the steepest grade that is still a
   ramp and not a stair — each approach is **29.4 m**, so one isolated crossing is **68.8 m of structure end to
   end**: `2·rampM + 2·(kHomeCutHalfM + crossMarginM)` = 2·29.4 + 2·(4.0 + 1.0), re-derivable from the constants.
   A kerb cut's spacing IS its lot's frontage, and a house lot is **17–24 m** (§3 C-1; `ParcelSettings.frontageM`
   defaults to 24 m and `CitySpec.frontageM` to 30 m), so two adjacent holds leave **7–14 m** of clear between them
   against **58.8 m** of two ramps. Adjacent crossings therefore cannot touch down between them and their holds
   MERGE: down a dense street the result is one **continuous raised walkway on legs** for the whole terrace, with
   isolated bridges only where the cuts are sparse. That shape is a CONSEQUENCE of the rise and the grade, not a
   preference and not a user decision — the alternative, letting two near ramps overlap and taking the higher of
   them, sags a few centimetres over a few metres between the drives, which reads as a fault in the structure
   rather than as a ramp, so the merge is the rule and not a special case.

   What holds it up is not "a pair every 7.5 m" either, which is what R8's first cut claimed: a post may not stand
   in a drive, so a pair stands at each EDGE of every drive's 2 m clear and the clear runs between them are divided
   evenly into steps of at most 7.5 m. The longest unheld stretch of deck is one drive's opening and its clearance,
   **12.0 m** for a house's 8 m drive (§5.5 as built, R8 repair).

   Nothing at this seam knows what body it is on (`PedestrianTube.emit` is handed a polyline and a kerb-cut table
   and nothing else), so the grade is the Earth standard applied unchanged. A sixth of a gravity would carry a
   steeper one; making that read would mean threading the body through the renderer for one constant.

   Not done, and not needed for (a): no airlock, no door and no interior — the barrel is drawn geometry, and a
   colonist does not walk inside it yet. When one does, the ramp is already walkable at 8.33 %.
9. **Grid-cell colonies.** Generate plans from `parcelForCell` too, so R7 can delete the legacy path outright?
   **Yes.**
10. **Plan-served sites without a stored frontage turn to face their access road.** Player-claimed sites, generator
    installations and grid-cell buildings have no real frontage (or a fake north one), so their plan uses the edge
    facing their road. Their building, envelope, gate and door must share one frame, so from R4 (behind the knob)
    the building turns to face that road. This is a visible change for saved and generated sites. Accept?
    **Accept.** The alternative (keep `Parcel.facing` for these sites) rotates the envelope 90° or 180° against the
    building, which puts the gate fence gap on a different side from the access road and swaps the site's width and
    depth; "new placements only" cannot be expressed without saving a per-site flag, which contradicts "plans are
    derived, never saved".
11. **Defaults to confirm:**
    - demolition with cars parked: they vanish (garaged virtually) and moving cars drive out;
    - lots whose only road is an expressway, ramp or deck keep invisible kerbside access, with a "no driveway"
      warning in the lot inspector;
    - home driveways follow the back-out eligibility (§3.3, Q3): minor tiers ≤ 40 km/h keep them with back-outs in
      both directions where `joinDirs` allow (street, one-way street at 40 km/h, alley, path); avenues keep them with
      near-direction back-outs only; divided, medianed or > 50 km/h roads are `kerbOnly` (in the catalog: boulevards
      and urban highways);
    - alley access waits for R8, which builds it; public parking does NOT wait for R8, it is deferred with its
      design written down (§3.3, §7.5) and a request to the traffic session not to take it up before T4b; and
      second gates on a second road are not waiting for anything, because nothing the game generates can put a gate
      on a lot with a second road (§6.1 item 4, closed at the R8 scoping, with the one hand route recorded there).
    **Accept all.**
12. **Access easements over auto lots.** None of the four starter utilities (nor any set-back site behind a lot row)
    can reach its street without crossing a zonable auto lot: the lot rows cover every stretch of kerb where a
    driveway is legal, between the crossing's reserve and the street ends' turning circles. Options:
    - (a) the access road crosses the fewest unbuilt auto lots, centred on one; those lots become unzonable
      "access easements" while the site stands (the starter kit loses 4 of its 82 lots:
      lot-r0x1-l10, lot-r0x0-l0, lot-r0x0-r1, lot-r0x1-r5);
    - (b) re-plat a narrow easement strip out of the lot row: fewer lots lost, but it changes layouts, which decision
      1 locks;
    - (c) no easements: those sites stay kerb-only with no visible connection, so the motivating case fails for the
      pump, farm and solar farm;
    - (d) let the road cross the lot and leave the lot zonable: its building would overlap the paved road.

    **Recommend (a).** A second part: easements currently appear only once the set-back site is BUILT, so a lot
    zoned and grown in front of an empty manual site first will block that site later. Reserve corridors from slot
    geometry alone (every set-back manual lot, built or not, makes its crossed lots unzonable)? **Recommend no for
    now:** it would lock lots in front of every empty claimed parcel; the inspector shows the block, and demolishing
    the blocking building restores access.
13. **R8's scope. Decided by the user 2026-09-18**, after the scoping pass that closed three of the six R8
    reservations (§9's R8 row carries the settled list; §3.3, §3.5, §6.1 and §7.5 carry the reasons).
    - **The tube crossing of Q8 is accepted AS A SKYWAY.** Q8 offered a short raised tube BRIDGE for a sealed
      world; the built form is the pedestrian tube lifting over the driveway on a skyway, so the drive keeps the
      ground and its grade and the tube takes the climb. The alternative, ducking the drive under the tube, would
      make a plan read the ground, which §10.2 Q7 has already ruled out for steep lots, and would put a ramp in
      the one place §3.4 needs a straight run for a back-out.
    - **The alley slice is built without an audit gate.** Alley rear joins (slot 3, §3.2) land on their own
      acceptance — the slice's tests and screenshots — rather than behind a sprawl-audit count agreed in advance.
      Slot 3 is reserved and unbuilt today (§3.2), so a rear join can only be additive — it changes no program a
      plan already picked, and an audit gate would measure nothing but how many lots gained one, which the slice's
      own tests pin anyway.

---

## Appendix A: re-pin ledger

Filled by R1 (lot-access pins) and R7 (tile digests and lot-feature behaviour): test, line, old value, new value,
reason, commit.

| Slice | Test:line | Old | New | Reason | Commit |
|---|---|---|---|---|---|
| R1 | road_traffic_model_test.dart:87 (two-way loop service distance) | 192 | 177 | lot access = slot 0: station (276..300) joins at 280.5, house (84..108) at 103.5 | 5eb031b |
| R1 | road_traffic_model_test.dart:90 (one-way loop) | 808 | 823 | same: 119.5 + 100 + 400 + 100 + 103.5 | 5eb031b |
| R1 | road_traffic_model_test.dart:128 (avenue, same kerb) | 192 | 177 | same | 5eb031b |
| R1 | road_traffic_model_test.dart:131 (street, far kerb) | 192 | 177 | same | 5eb031b |
| R2 merge | site_program_sprawl_audit_test.dart `_audit` | 8 keys (planned 30,559, unplanned 2, homeDriveway 24,996, five home rules) | the full mix: those, plus none 0, kerbOnly 952, carPark 4,427, yard 40, installation 144, installationTooSmall 0, installationNoFit 3, yardNoFit 22, carParkNoFit 130, legacySlot 37, accessBlocked 65, mega 1, sliver 1, degenerate 0 | every generator landed; the core pins were unchanged by the merge | R2 merge |
| R2 merge | site_plan_generator_test.dart ("the built town grows home driveways", blocked sites) | `> 0` | `0` on `town()`, plus a new old-save case (a crossed lot built around the refusal) that blocks exactly `lot-m0` | the founded kit's book makes the four §3.7a lots easements before `town()` zones, so none is built; the stub installation made none | R2 merge |
| R2 merge | site_easement_refusal_test.dart (growth skip, built crossed lot, corridor refusal) | red once merged | green | the tests assumed the stub installation (no real easement or corridor on the founded kit); each now unhooks or fakes the real book where it stages "before" | R2 merge |
| R2 merge | traffic_fixture `town()` (no pin) | 82 built lots | 78 built lots | the four easement lots refuse zoning; no traffic test pin moved (full suite green) | R2 merge |
| R2 integration repair | site_access_persistence_test.dart ("200 curved-road lots", home fit flips) | `['lot-r2-r21']` | `isEmpty` | the §3.4 house containment is now tested with the rectangle grown by `kContainsInsetM` (stricter by 5 cm), so the load's millimetre re-sample no longer flips that lot (§4.4); the sprawl audit's demotions did not move | R2 integration repair |
| R1 | test/traffic/live_rebuild_test.dart (traffic-owned) | green | red, then green | cars stood inside the new crossing's stop line at the edit (moved 5.2 m) and trips ended on slots at 151.5 m, 1.5 m past the new street. A real traffic bug R1 exposed (RouteRemapper clamped into the lane, dragging cars onto the car behind). MERGE GATE CLEARED: fixed on the traffic side (cars in a new junction box carried onto their connector, an appended leg when a destination's access moved, a no-overlap guard, a stop at a lane's start counted 1 m in from a connector), merged with R1 in one window; no skip. The test's drive-on window grew 900 s → 1800 s: the new test street re-hangs hand-drawn lot-m0/lot-m3 onto other roads (their effective frontage, §3.1), so their trips detour | 14a7bef, 6f1784f, merge a309f85 |
| R4 track B | city_tile_mesher_test.dart ('site access on the wire…', the knob **ON** only) | near `0xf5d18ccb`, mid `0x0759f3c8`, far `0x07d559a4` (R3: the knob drew nothing) | near `0x856e8b38`, mid `0xcf757f38`, far `0xbf7c5994` | R4 draws the plan: a served building loses its own car park, is front-aligned on its envelope, takes the min-fit bucket and has its gate lane cut open. The knob-OFF pins are unchanged, and the test now also asserts on ≠ off at every tier. Track A's site mesher and kerb cuts move the ON values again at the R4 merge | R4 track B |
| R5 | road_corridor_mesh_test.dart ('a colony laid in one call…', the starter kit) | 2 refinement targets, 0 boosted leaves, and every leaf judged on the datum | 10 targets, 10 boosted leaves, 10 of them judged on the ground | the kit's four throats are cut fine (§6.3 as built): a mesh cannot hold an eight-metre cut at fifteen metres, which is why a road cut through relief is refined too. The test now separates a site corridor from a road corridor (it scanned every `cutFill` on the body) and asserts the leaves that differ are exactly the ones a fine SITE brush reaches — without them every leaf is judged on the datum as before. Its 'what makes it a test' case takes `siteCorridorReliefTolM: infinity` alongside the road tolerances, so dev-before-the-fix means before every fix | R5 |
| R4 merge | city_tile_mesher_test.dart ('site access on the wire…', the knob **ON**, near only) | `0x856e8b38` (track B alone) | `0x6a1f715e` | track A's kerb cuts land on the same tile: the fixture's road carries three cuts, so the near tier's kerbside lays the dropped kerbs and stands the masked kerb cars down on top of track B's envelope massing. Mid and far keep track B's values (`0xcf757f38`, `0xbf7c5994`): neither draws a kerbside, and the fixture carries no `CitySiteFrame`, so the site mesher emits nothing here. The knob-OFF pins never moved | R4 merge |
| R7 | city_tile_mesher_test.dart:505, :527, :648, :674 (near, knob OFF) | `0xf5d18ccb` | `0x8b0c9fe1` | the fixture's eleven buildings are unserved in the knob-OFF tile: each loses its massing car park (deck, lamp columns, lamp heads) and `emitLot`'s paving, drive, bays, cars and footpath, and grows into the depth the park strip took | R7 |
| R7 | city_tile_mesher_test.dart:551 (full, camera in the street) | `0x5b35df04` | `0xe7497c94` | same, at the full tier | R7 |
| R7 | city_tile_mesher_test.dart:569 (mid) | `0x0759f3c8` | `0xffd81c34` | same, at mid: no lot features there, so this is the massing alone | R7 |
| R7 | city_tile_mesher_test.dart:571, :650, :675 (far) | `0x07d559a4` | `0xb51e60e0` | same, at far | R7 |
| R7 | city_tile_mesher_test.dart (the knob **ON** tiers) | `0x6a1f715e` / `0xcf757f38` / `0xbf7c5994` | unchanged | the slice deletes nothing a plan-served building drew. This is the check that R7 is a REMOVAL and not a redraw | R7 |
| R7 | road_tool_mesh_test.dart:293-295 ('the mesher fixture, its junctions aside') | near `0x5e473abb`, mid `0x09731332`, far `0x07d559a4` | near `0x22bdc865`, mid `0x057be2b6`, far `0xb51e60e0` | §8.2 lists these as never-move, and they moved: the fixture carries eleven buildings beside its roads. Deviation recorded in §8.2. The road zoo (`0xfaae5bd2`, `0xa687274b`, `0xb8c5ea2d`) and the ramp (`0x0610818f`, `0xe4af1e87`) are byte-identical, which is what says the roads did not move | R7 |
| R7 | city_nodes_test.dart 'a distant colony drops to block silhouettes' | an r-med on a 24 m square, `block < full` | an r-high on a 12 m square | what made the two tiers differ for an r-med was the car park beside it: without one, an r-med on that lot is ONE box at every tier and `block == full`. Re-fixtured on a building that has a silhouette to collapse | R7 |
| R7 | building_generator_test.dart 'generated geometry has walls, glazing and an interior' | a c-high on a 60 m square; `block.foliage < shell.foliage` | a c-high on a 24 m square; `block.foliage == shell.foliage` | the 60 m square now stands one storey (it has the whole plot), so it had no interior to lose; and the foliage comparison was counting the car park's LAMP HEADS, which ride the glazing channel and which the block tier skipped — with the car park gone the two tiers glaze alike, and the case says so | R7 |
| R7 | building_generator_test.dart:59-77 (two parking cases) | 'parking is sized from demand and sits between building and street' + 'a building with no staff or visitors gets no car park' | one case: 'a demand for cars no longer takes a strip off the building' | there is no `ParkingLot` to size. What is worth pinning is the consequence: a spec that attracts cars keeps its whole buildable strip | R7 |
| R7 | architecture_style_test.dart:60-72 ('the car park moves behind the building, not in front of it'), :271 | the case, and a `parking, isNull` guard | deleted | `ArchitectureStyle.parkingBehind` is deleted with the car park it placed | R7 |
| R7 | degenerate_lots_test.dart:92 | `massing.parking, isNull` guard | deleted (the controlled spec stays) | the guard existed so the glazing channel held no lamp heads; no massing has any | R7 |
| R7 | megatower_test.dart:42 (the comment above it, :40-41) | `m.parking, isNull` | `parkingSpaces(kMegatowerSpec) == 0` | the mega's ~12 080 stalls of demand are declared already met in its own podium, which is now a statement about the SPEC rather than about a massed lot — the only place in the tests that fact still lives. R8 records the same reading in prose (§3.3's mega rule) | R7 |
| R7 | city_lighting_test.dart 'car parks get their own cold-light masts' | the legacy case (a util placed in a colony with no plans lights a re-massed car park) | deleted; the plan case gains its assertions (a mast throws wider than a street lamp; a site with no plan takes none) | §6.2 as built, R7: the legacy mast derivation is gone with the lot it read | R7 |
| R7 | test/colony/lot_features_test.dart | four `emitLot` cases (occupancy, front lot, rear lot, paint lift) | deleted | `emitLot` is deleted. The drawing they covered is the plan's, and `site_detail_dressing_test` covers it lot by lot; a new case there pins what an UNSERVED lot keeps | R7 |
| R7 | test/architecture/installation_parking_test.dart | 'every staked installation parks inside its own plot', and the parking half of the gate-lane case | deleted; the gate-lane half kept whole | the plan parks installations (§3.7). What the massing still owes a plan is the lane | R7 |
