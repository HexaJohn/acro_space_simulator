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
  kerb_cuts.dart               KerbCut, KerbCuts.blocked/shiftOut: shared by renderer, lighting, traffic kerb masks
  site_access_book.dart        SiteAccessBook: slots, chunks, sync, budget, renames, clears (§4)
```

`site_access/` is outside `traffic/` because massing, terrain, lighting and the renderer read it. It follows the
traffic hygiene rules all the same, and a new `site_access_source_hygiene_test` runs the
`traffic_source_hygiene_test.dart:131-157` scan over it.

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
  final Float64List frameE, frameN; final Float32List frameUE, frameUN;          // SiteFrame origin + unit u
  final Float32List envX0, envX1, envY0, envY1, envFrontInset, gateX, gateW;    // frame metres
  // points: every position that carries a height (node, via, pave vertex, lamp, entrance, path)
  final Float64List ptE, ptN; final Uint8List ptHRef, ptHJoin; final Float32List ptHT, ptDz;
  // joins (joins[0] = slot 0)
  final Uint8List joinSlot, joinRight, joinDirs, joinRole, joinKind;
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

Kerbside plans carry exactly one join (slot 0, `kerbside`) and no nodes, segments or stalls. They are stored
as a single site row with empty ranges, so a kerb-only town costs almost nothing. A chunk retains ≤ 7 objects
(itself, five typed lists, the `siteId` list) and its `SiteChunkGeometry` (§5.2) ≤ 3 (itself, one Float32List, one
Int32List), so the heap cost is ≤ 10 objects per 1024 sites, i.e. ≤ 1 retained object per 100 sites (§3.10, §8.4).

**Immutable after publish.** A published chunk is never mutated. A changed site publishes a NEW chunk object
(copy-on-write, §4.1) and the book swaps its reference; the old chunk stays valid for as long as anything references
it. Limbo plans (§7.6) and cars mid-manoeuvre hold the old chunk and keep reading it unchanged.

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
  columns bit for bit in the graph the plan was synced against.
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
- **`DepthProfile`** has one column every 0.5 m across `P` in the frame. Each column keeps the single inside
  interval nearest the frontage, less a 0.3 m margin. Search uses the profile. Every emitted rectangle must also
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
- Slot 3 is reserved for a rear alley (R8).
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
| 2 | `spec.type == 'mega'` (`parkingSpaces` = 0) | `kerbOnly` (podium garage: R8) |
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

### 3.6 Yard (industrial)

A yard is a car-park candidate plus an 18 × 24 m truck apron beside the envelope's side or rear face.

- A 7 m driveway (`throatW` 7.0, so the slot needs room ≥ 4.5, §3.3) leads to the apron. Its first ≥ 7 m is the
  throat.
- The apron has a `circle` turnaround node of radius 12.5 m and two 3.5 × 15 m loading bays facing the envelope.
- `admitsTrucks` is set and `truckTurnRadiusM` is 12.5.
- If the apron does not fit, the car park is emitted alone, with trucks not admitted and no bays.

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

**Starter kit result (pinned by `site_easement_test`):** easements are exactly `{lot-r0x1-l10, lot-r0x0-l0,
lot-r0x0-r1, lot-r0x1-r5}` (spaceport, solar farm, farm, pump), and 78 of the 82 auto lots stay zonable.

### 3.8 Odd polygons

| Case | Detection | Result |
|---|---|---|
| < 3 vertices, area < 30 m², zero frontage | frame | `none` / `kerbOnly`, legacy slot |
| Sliver (inscribed depth < 8 m or W < 6 m) | profile | `kerbOnly` |
| Triangle | profile tapers | generators run; usually `kerbOnly` below ~400 m² |
| Concave L/U, self-touching | profile + exact `containsRect` | stalls never outside; pockets unused; never crashes |
| Frontage < 2(m + 0.5) | spans empty on that road | side street, other road, then legacy |
| Skewed lot or curved road | frame | throat along the road normal, bend node after ≥ 7 m; a home more than 10° off the normal is `kerbOnly` (§3.3 rule 4) |
| House lot whose slot 0 fails the back-out rules (road, room < 4.0, swing margin) | §3.3 | `kerbOnly` (kerb parking) |
| Piece shorter than `reserves + 12 + 2m` | no window | other road or legacy (counted by the sprawl audit) |
| Join road without pavement (path, alley) | class | kerb = carriageway edge; no kerb-cut mesh; throat still ≥ 7 m |
| Sealed (airless) road | flag | same geometry (rovers); tube crossing is §10 Q8 |
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
  - every slot of the lot (piece's road id, `s`, right, room, flags, and the crossed lots' ids);
  - the BUILT bit of each crossed lot, in `joinCrossLot` order (§3.7a: the one cross-site input);
  - the spec (`type`, `housing`, `jobs`, `siteWidthM`, `siteDepthM`, `siteKind`, group);
  - whether an alley candidate exists.

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

### 5.5 Lot features, kerb cuts and kerb-side dressing

- **`_emitLotFeatures`** (city_tile_mesher.dart:1327-1409) branches on `b.siteSlot`:
  - **`< 0`:** today's code, byte-identical.
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
4. `gateX/gateW` are where the primary drive crosses the envelope front edge, with width `segWidth + 2`.
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

### 6.2 Massing inside the envelope (only for `siteSlot ≥ 0`, so the legacy path is untouched)

- **Domain massing.** `massFor(spec, parcel, {seed, SiteEnvelope? envelope})` (building_massing.dart:302): the
  extent is the envelope rectangle, `parkArea = 0` (:431-447, :538-547, :707-719), `_lotFor` returns null
  (:2248-2276), and `_installation`'s `parkW` is ignored (:2153-2155).
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
>   `attachFootprintJoins`.
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
  `ofJoin(lotJoinStart[i])`.
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

  Other sites' lots are not searched; `kPlanPublic` is reserved.
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

---

## 8. Pins, tests and performance budgets

### 8.1 Policy

- New render paths run only for data the fixtures do not carry: `siteSlot ≥ 0` or non-empty `kerbCuts`. So every
  existing tile, road and detail digest stays byte-identical through R6, and each slice's PR asserts that.
- **R7** deletes the legacy path and re-pins in ONE commit, listing every old → new value and its reason in
  Appendix A, with before/after studio screenshots attached to the review (not committed, per the workspace rule).
- The only earlier re-pins are R1's lot-access pins, which are unavoidable (lot access moves) and ledgered the same
  way.

### 8.2 Pins that move

| Pin | Where | Moves in | Why |
|---|---|---|---|
| Lot `s` goldens, access and table tests | `road_graph_directed_test`, `road_traffic_model_test`, `access_points_test.dart:59-64` (green by construction), `building_table_test.dart:89-92`, `graph_derivation_test` if it hashes lot arrays | R1 | lot access = slot 0 (§3.2) |
| Parcel building quaternions | screenshots only | R0 | orientation fix |
| Tile digests near `0xf5d18ccb`, full `0x5b35df04`, mid `0x0759f3c8`, far `0x07d559a4` | city_tile_mesher_test.dart:505, :527, :551, :585-589 | R7 | fixture gains sites/slots; legacy lot features deleted |
| Lot-features behaviour | test/colony/lot_features_test.dart | R7 (rewritten against plans) | `emitLot` deleted |
| Installation parking | test/architecture/installation_parking_test.dart | R4 (plan cases added), R7 (legacy cases deleted) | plan-owned parking |
| Lighting masts | test/architecture/city_lighting_test.dart:145 | R4 | masts from `lampPt` |
| Shaper brush counts | city_terrain_shaping_test, shaper_ground_samples_test, starter `terrainEdits` | R5 | access corridors |
| Starter zoning | `city_starter_kit_test.dart:57-67` ('zoning the starter block grows buildings on it') | R2 (assertion added; existing expectations unchanged) | four starter lots become access easements (§3.7a): the loop's `setUse` returns false for them, and the test now asserts exactly `{lot-r0x1-l10, lot-r0x0-l0, lot-r0x0-r1, lot-r0x1-r5}` stay unzoned and unbuilt while `grownParcels` is non-empty |
| Degenerate lots, generator, style | degenerate_lots_test.dart:79-93, building_generator_test.dart:59-77, architecture_style_test.dart:60-72 | never (legacy default); R7 re-checks | – |

**Never move:**
- road tool `0x5e473abb`, `0x09731332`, `0x07d559a4`;
- road zoo `0xfaae5bd2`, `0xa687274b`, `0xb8c5ea2d` (road_tool_mesh_test.dart:217-219, :293-295). A new zoo case with
  cuts gets its own pin;
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
- **R5:** shaper corridor tests (emitted once, keyed, graded only, datums recorded, drawn height = datum ±1 cm, ≤ 2
  asks per new segment, sprawl adds 0, **a generated graded downtown block on flat ground adds 0 site brushes**,
  the starter kit adds exactly 4).
- **R6:** `site_detail_dressing_test` (cars ≤ stalls; `maxParkedCars = 0` → none; fences never cross a drive).
- **R3/R4:** A14 (road half).

### 8.4 Performance budgets (render side; generation in §3.10, traffic in §7.8)

Reference: the 127k-building generated town used by `tool/measure_city_studio.ps1`, A/B with a `siteAccess` knob.

| Work | Budget |
|---|---|
| Frame, static and warm orbit | unchanged within ±0.3 ms of the gate (static 13 / sweep 16 ms); draws unchanged |
| Capture, steady frame | ≤ 0.02 ms for sites + kerb cuts; zero ground queries (`groundQueries` delta 0) |
| Chunk heights rebuild | ≤ 1.5 µs per site, only on a stamp change |
| Tile cut (`city.bucket`) | ≤ +10% |
| Near tile build | ≤ +15% time, ≤ +20% vertices; mid ≤ +10% (vertex count measured on the reference town's mid tiles before the knob goes on, §5.4 mid rule); far ≤ +2% |
| Near tile send (`city.submit`) | ≤ +10% bytes |
| Detail job | ≤ +15% |
| Heap | ≤ 1 retained object per 100 sites (chunk ≤ 7 + geometry ≤ 3 per 1024 sites, §2.3); ≤ 120 B per home site of wire geometry |

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
| **R2 Generator + book** | road | `classifyProgram`, home, car park, yard, installation, envelope/entrance/lamps, `SiteAccessBook` + `CitySim` hooks + resumable sync + budgets, easements (`easementOf`, `CityLayout.easementOf` hook, `setUse`/`placeOnParcel`/growth refusal, inspector string), full drain at the end of `CityStarterKit.found`, corridor refusal in placement, dev hook `ext.acro.citygame site=plan&id=` | A1 on starter kit, small town, 500 random lots; starter sites: 56 m throat `K→F`, yard, gate `G` on the fence line, ≥ 12 stalls, and exactly the four easement lots of §3.7a (no site `kPlanAccessBlocked`); `city_starter_kit_test` green with its easement assertion; home thresholds exact (§3.4: W 16.6 m tandem, 17.6 m side by side, D 15 m; §3.3 back-out eligibility: road class, speed and median, room ≥ 4.0, 12 m swing margin, 10° skew) with demotions counted by rule; persistence test green; twin runs give identical plans with capture interleaved; zero ground reads in plan code; §3.10 budgets met (or the load-time risk reported); road-edit sync bench ≤ 2 ms |
| **R3 Wire + keys** | road | `CitySiteFrame` + heights + cache, `BuildingSnapshot.siteSlot/gate`, `RoadSnapshot.kerbCuts`, JSON, `sitesSignature`, bucketing membership/keys, tile and detail columns; the new static knob `CityNodes.siteAccess` stays off, so the renderer treats every building as legacy | R3 tests; all mesh digests unchanged; capture ≤ 0.02 ms steady, zero queries |
| **R4 Draw** | road (2 tracks) | A: `SiteAccessMesher` structural tiers (the §5.4 mid rule); kerb cuts in sidewalks, verges, furniture, kerb cars, lamps via canonical `KerbCuts`; instant path. B: envelope placement with the plan-served heading (`−SiteFrame.buildingHeading`, §3.1); `surfaceParking: false`; front alignment; min-fit; setback and bucket alignment; installation gates on the envelope front edge; lighting from plans. Knob on | **the starter kit's four sites visibly connected** (orbit screenshot at mid tier: access roads across their easement lots, gates, car parks, dropped kerbs); R4 tests incl. `envelope_axes_test` and `entrance_matches_door_test`; old digests unchanged; the reference town's mid-tile vertex count ≤ +10% measured BEFORE the knob goes on; §8.4 frame/tile budgets |
| **R5 Terrain** | road | shaper access corridors, `padDatums`, capture reads corridor datums | R5 tests; the starter kit adds exactly 4 corridor runs; `relaid_road_drape_test` unchanged |
| **R6 Dressing** | road | stall paint on small lots, baked lot cars in stalls (skipped on agent-managed sites via the per-site bit, §5.5), footpaths, lamps, wheel stops, bay hatch, fence rings with gaps, signs by the throat | R6 tests; detail on/off identity holds; screenshots of a generated suburb and a strip mall |
| **T4a Site networks** | traffic | needs R1 (join slot columns for `AccessPoints.ofJoin`) and R2a; §7.8 items 1–11 for today's CommuteSynth trips, INCLUDING item 10 (lot-car persistence by `(siteId, stallKey)`, so no save between T4a and T4b holds lot cars under the old §14.1 scheme or drops them); D17 step 2 only (garage what it cannot place); lot-car owner opaque (`ownerKind` + id) for the slice-3 port | A4–A11 (A10 with its save/resume case), A13–A15, A12 (traffic half); built on R2a fixtures, then real R2 plans; wire after R3; merge gated on the structural allocation gate (A13), not the traffic-wide weighed allocation number (not met today, owed by traffic slice 11); staged E36 (agent-managed sites only) |
| **R7 Legacy removal** | road | delete `emitLot`, `ParkingLot` meshing (building_generator.dart:246-254, :787-844) and massing parking for parcel buildings and cells; ledgered re-pin; rewrite road-network.md §3b (stale: `CityNodes._emitLotFeatures` is `CityTileMesher._emitLotFeatures`, SprawlSectionBuilder is gone) and docs/REFERENCE.md | one re-pin commit with the ledger; all tests green; screenshots reviewed; after T4a merged |
| **T4b Residents and pedestrians** | traffic | with or after citizens (slice 3): residents' cars at home pads (backing out to the street, §7.4 Home back-out; yielding to pedestrians on the pavement crossing) and kerbs (E36 completes: all baked cars off), full D17 circling/give-up, stall → door walks via `entrancePt/entranceNode` | A16 |
| **R8 Polish** (later) | road | alley rear joins (slot 3, F2a), second gates on a second road, one-way loops with angled stalls, podium garage portals for `mega`, sealed-world tube crossings, public lots (`kPlanPublic`) | per feature |

---

## 10. Risks and open questions

### 10.1 Risks

| Risk | Mitigation |
|---|---|
| R0 turns every parcel building 180°, visible everywhere | test-first; the stop rule is keyed to the renderer twin (`building_front_test`), so a downstream compensation cannot be double-flipped; screenshots before anything builds on it |
| R4 turns frontage-less manual sites and grid-cell buildings to face their access road (saved and generated sites) | one heading rule (§3.1) so envelope, gate and door can never disagree with the massing; `envelope_axes_test`; behind the knob until screenshots are reviewed; §10.2 Q10 |
| Easements cost the player zonable lots (4 of 82 in the starter kit) | fewest-lots corridor, centred; inspector explains why; §10.2 Q12 |
| An auto lot zoned and grown in front of an unbuilt set-back site blocks that site's access later | built crossed lots make the plan `kPlanAccessBlocked` (visible in the inspector); §10.2 Q12 offers reserving corridors from geometry alone |
| The 127k-town drain exceeds 3 s once the real program mix is measured | budget is Σ count × unit cost, printed by the bench in R2; if it exceeds 3 s the added load time is reported to the user before R2 merges |
| A road edit leaves plans stale for a few ticks | dirty-box diff, 4096 checks per tick; stale plans read as kerbside to traffic and keep drawing (§4.2) |
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
   airlock break, or (c) overlap as today. **(c) through R7, then (a) in R8.**
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
    - public parking, alley access and second gates wait for R8.
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

---

## Appendix A: re-pin ledger

Filled by R1 (lot-access pins) and R7 (tile digests and lot-feature behaviour): test, line, old value, new value,
reason, commit.

| Slice | Test:line | Old | New | Reason | Commit |
|---|---|---|---|---|---|
| – | – | – | – | – | – |
