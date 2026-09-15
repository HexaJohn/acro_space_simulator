# T4a implementation seams: site networks and lot parking

Working plan for traffic slice T4a (agent-traffic.md "Slice T4a", including the "Agreed with the road side" block; site-access.md §7). It fixes the file ownership and the public APIs so that the work packages below can run in parallel in one worktree. The plan was made against `758b018`.

## 0. Settled with the road side (overrides anything below)

- **Kerb masks (Q1):** no interim adapter and no local copy of the formula. `KerbMask` stays an interface; its only implementation wraps the road side's `KerbCuts.parkingBlocked(entries, side, s_i)`, which lands right after R3. Until then, D's kerb slots are masked by a test double, and A12 waits.
- **Wire ordinal (Q4):** `siteOrd` is the book's `slotOf(siteId)`. E36 stage 1 publishes `CityAgents.agentManaged` (a `Uint8List` by slot) and `agentManagedRev`.
- **Stale plans (Q5):** a not-current plan reads kerbside for new arrivals only. Cars already inside, and cars parked there, keep the old immutable chunk.
- **Heights (A14):** from R3's `SiteChunkGeometry.ptUp` and `stallUp`, by reference.
- **Home back-out and A9** are in T4a.
- **Commits:** each agent commits its own paths with `git commit -- <paths>`. No `git add -A`.

## Code facts at the start

- R2 has landed: `CitySim.siteAccess` is a `SiteAccessBook`, synced before `agents.advance`. R3 and R4 have not landed: no `CitySiteFrame`, no `KerbCuts`.
- Traffic has no parking yet (`VehicleState.parkingSearch` is unused).
- `_remapAll` and `VehicleTable.relinkAll`/`link` index `elemTail[elem]`, so a vehicle with `elem == -1` would crash them. P0 guards that.
- House rules: the PolyForm header, `traffic_source_hygiene_test`, no wide int literals (reuse `_wide`), and no nullable promoted through a bool local and then read (the AOT miscompile, e456be6).

## 1. Data model

All new files live in `lib/domain/colony/city/traffic/`.

### 1.1 Plan source (`site_plan_source.dart`)

It is a test seam: synthetic chunks and the real book look the same to traffic.

```dart
abstract interface class SitePlanSource {
  int get sitesRev;
  List<SiteAccessChunk> get chunks;              // identity-compared in prime()
  SiteAccessPlan? planOf(String siteId);         // sync only (allocates a view)
  int slotOf(String siteId);                     // the wire ordinal (settled)
  bool isCurrentFor(String siteId, RoadGraph g);
}
final class BookPlanSource implements SitePlanSource { BookPlanSource(SiteAccessBook book); }
```

The test double lives in `test/traffic/site_fixture.dart`: `FixturePlanSource(RoadGraph g, Map<String, SyntheticTemplate> byLot)`, on `SyntheticSites.chunkOf`. Its `replace(lotId, SyntheticTemplate?)` bumps `sitesRev`.

### 1.2 Site elements: a separate id space (D49)

- **Numbering:** a global site element is `SiteTable.elemBase[row] + planLocalLane`, renumbered on every site sync, followed by `SiteMover.relink()`.
- **Vehicle rows:** no site id ever enters `VehicleTable.elem`. A vehicle inside a site has `elem == -1` and `state == onSite`. Its position is `(SiteVehicles.row, SiteVehicles.lane, VehicleTable.s)`.
- **Wire:** only `(siteOrd, siteLane)` goes on the wire.

### 1.3 Site table (`site_table.dart`, owner B)

```dart
class SiteTable {
  SiteTable({int capacity = 256});
  final SlotPool rows;
  late List<SiteAccessPlan?> plan; late List<SiteLaneGraph?> lanes;   // sync-time objects
  late Int32List building, rev, bookSlot, lotCap, lotUsed, elemBase, laneCount,
      stallBase, orderBase, hopBase, targetCount, inside;
  late Uint8List rowFlags;                               // kRowLive|kRowLimbo|kRowNotCurrent
  late Int32List stallRes, stallCar;                     // per stall: vehicle handle / parked car, −1
  late Uint32List stallBits;                             // car OR binding reservation
  late Int32List stallOrder;                             // per in-join: by site path length, ties by index; home tandem deepest-first
  late Float32List elemLen, elemVmax; late Int32List elemRow, elemHead, elemTail, elemCount, elemUnit;
  late Int32List hop, targetLane;                        // hop[hopBase+t*laneCount+lane] → next lane, −1
  late Int32List unitClaimH; late Uint8List unitClaimDir; late Int16List unitClaimers;  // sharedSingle
  int get syncedSitesRev;
  int rowOfBuilding(int buildingSlot);
  bool needsSync(SitePlanSource src, LaneGraph? lg);
  void sync(SitePlanSource src, BuildingTable b, LaneGraph? lg, SiteChangeSink sink);
  int firstFreeStall(int row, int join);                 // −1: full, kerbside or not current
  bool reserve(int row, int stall, int vehicle); void unreserve(int row, int stall);
  void occupy(int row, int stall, int car);   void vacate(int row, int stall);
  int stallTarget(int row, int stall); int joinTarget(int row, int join);
  int nextLane(int row, int lane, int target);          // hot path, allocation-free
  int stallIndexOfKey(int row, int key);
  void endStep();                                        // frees limbo rows with inside == 0
  void collectBuffers(Map<String, Object> into, String name);
  int digest(int hash);
}
abstract interface class SiteChangeSink {                // implemented by _Core (E)
  void siteRevChanged(int oldRow, int newRow);           // §7.6 row 1: snap movers, remap parked by key
  void siteLostRole(int oldRow, int newRow);             // row 2 (newRow may be none: kerbside)
  void siteGone(int oldRow);                             // row 3: limbo movers, garage parked
}
```

`lotCap` and `lotUsed` live on the site row rather than on `BuildingTable` (§2.6). That only moves a column.

### 1.4 Vehicle rows (P0: edits to `vehicle_table.dart`, new `site_vehicles.dart`)

```dart
enum VehicleState { driving, holdAtEdgeEnd, dwelling, parkingSearch, leaving,
                    onSite /*5*/, manoeuvre /*6: stationary road obstacle, site mover owns pose*/ }
const int kReversing = 16;                               // VehicleTable.flags
// VehicleTable additions
void detach(int slot);                                   // unlink, elem = −1 (ENTER)
void attach(int slot, int lane, double laneS, {double speed = 0, required int nowUs}); // link (EXIT)
int spawnDetached({required AgentKind kind, required Int32List route, required int routeLength,
    required double originT, required double destT, required int nowUs, TripPurpose purpose,
    int variant, int owner, double speedFactor, double freeFlowS});
// relinkAll/link skip elem < 0; nextElemOf returns −1 for elem < 0

enum SitePhase { none, gateHeld, kerbBound, inbound, stallIn, stallOut, toThroat,
                 throatWait, backOutWait, backOut, shift }            // append-only
class SiteVehicles {
  SiteVehicles(int capacity);
  late Int32List row, lane, target, join, sPrev, sNext, owner, waitUs, claim;
  late Uint8List phase, ownerKind; late Float32List manU;
  void ensure(int capacity); void clear(int slot);
  void collectBuffers(Map<String, Object> into, String name);
  int digest(int hash, VehicleTable t);
}
```

### 1.5 Access events (`access_events.dart`, P0, frozen)

```dart
enum AccessEventKind { enter, exit, backOutExit }
class AccessEventLog {
  AccessEventLog({int capacity = 1024});
  int count = 0, enters = 0, exits = 0;
  Int32List handle, edge, lane, row, join; Float32List t; Uint8List kind;
  void ensure(int vehicleCapacity); void beginStep();
  void log(AccessEventKind k, int handle, int edge, double t, int lane, int row, int join);
  int digest(int hash);
}
```

### 1.6 Site mover (`site_mover.dart`, `site_manoeuvre.dart`, `access_gaps.dart`, owner C)

```dart
abstract interface class SiteSink {
  void parkedInStall(int handle, int row, int stall);
  void gateGaveUp(int handle);                           // lot full / 30 s throat → D17 step 2
  void exited(int handle);
}
class SiteMover {
  SiteMover(VehicleTable t, SiteVehicles c, SiteTable sites, JunctionArbiter arb,
            AccessEventLog ev, SiteStats stats);
  void bind(LaneGraph lg);
  void holdAtGate(int handle, int row, int join, int stall);
  int spawnFromStall({required int row, required int stall, required int join, required AgentKind kind,
      required int variant, required int ownerKind, required int owner, required Int32List route,
      required int n, required double originT, required double destT, required int nowUs,
      required double speedFactor, required double freeFlowS});
  void step(int nowUs, SiteSink s, VehicleSink v);
  void relink();
  void snap(int oldRow, int newRow); void evacuate(int oldRow);
  int remapHeld(RouteRemapper rm, SpawnSink sink);
  bool obstacleAhead(int lane, double laneS, Float64List out);  // implements LaneObstacles
  void collectBuffers(Map<String, Object> into, String name); int digest(int hash);
}
abstract final class SiteManoeuvre {   // no trig (D27): cubic Béziers and sqrt only; shared with capture
  static void stallPose(SiteAccessPlan p, int stall, int dir, double u, Float64List out, int o);
  static void backOutPose(SiteAccessPlan p, int join, int stall, int lane, LaneGraph lg,
                          double u, Float64List out, int o);
}
```

### 1.7 Parking (`parked_cars.dart`, `kerb_slots.dart`, owner D)

```dart
enum CarWhere { lot, kerb, garaged }                   // save index, append-only (§14.1)
enum CarOwnerKind { none, commuter, homePool }         // append-only; slice 3 appends citizen
class ParkedCarTable {
  ParkedCarTable({int capacity = 16384});
  final SlotPool pool;
  late Uint8List where, ownerKind, kind, variant, side;
  late Int32List owner, building, row, stall, stallKey, edge, slot, claim, poolNext;
  int parkedRev = 0;
  int parkLot({required int building, required int row, required int stall, required int stallKey,
      required CarOwnerKind ownerKind, required int owner, required int kind, required int variant});
  int parkKerb({required int building, required int edge, required int slot, required int side,
      required CarOwnerKind ownerKind, required int owner, required int kind, required int variant});
  int garage({required int building, required CarOwnerKind ownerKind, required int owner,
      required int kind, required int variant});
  void remove(int car);
  int takePooled(int buildingSlot);                     // LIFO; an unblocked tandem stall first; −1
  void collectBuffers(Map<String, Object> into, String name); int digest(int hash);
}
abstract interface class KerbMask {                     // wraps KerbCuts.parkingBlocked once it lands
  bool parkingBlocked(int edge, double travelT, bool rightOfTravel);
}
class KerbTable {
  void bind(LaneGraph lg);                              // §7.1 caps, right kerb; one-way: both kerbs
  void applyMasks(SiteTable sites, LaneGraph lg, KerbMask mask);
  int reserveAhead(int lane, double fromT, int vehicle);   // D17 step 2: ≤ 60 m on this edge, else −1
  int nearestFree(int edge, double t, int side);           // tandem shuffle
  int slotEdge(int s); double slotT(int s); int slotLane(int s);
  void occupy(int s, int car); void release(int s);
  void collectBuffers(Map<String, Object> into, String name); int digest(int hash);
}
```

A car on a slot that becomes masked is relocated, the same as a car on a stall that vanished.

### 1.8 Counters and tuning (P0)

```dart
class SiteStats { int enters = 0, exits = 0, gateForced = 0, gateGiveUps = 0, parkedLot = 0,
  parkedKerb = 0, garaged = 0, snaps = 0, relocates = 0, siteGarages = 0, limboRows = 0,
  siteRetargets = 0, backOutForced = 0, shuffles = 0; int digest(int h); }
```

`AgentTuning` statics are added once in P0 and then frozen:

| Group | Statics |
|---|---|
| Gate | `gateMaxMps = 3`, `gateForcedS = 25`, `gateGiveUpS = 30` |
| Throat | `throatStopM = 1`, `throatStuckAfterS = 60` |
| Back-out timing | `backOutEtaS = 8`, `backOutFarEtaS = 10`, `backOutEtaFloorS = 6`, `backOutForcedS = 120` |
| Back-out geometry | `backOutUpM = 10`, `backOutDownM = 2`, `backOutQueueM = 15`, `backOutSideM = 6`, `backOutMaxMps = 2` |
| Shift and shuffle | `shiftStopS = 0.5`, `tandemShuffleS = 120` |
| Kerb and snapping | `kerbAheadM = 60`, `siteSnapM = 3`, `siteSnapCos = 0.5` |

## 2. Edits to existing files

| File | Edit | Why |
|---|---|---|
| `vehicle_table.dart` (P0) | §1.4 enum values, flag, `detach`/`attach`/`spawnDetached`, `elem < 0` guards | ENTER and EXIT; rebuilds must not crash |
| `vehicle_mover.dart` (P0) | `_move`: `manoeuvre` treated like `dwelling`; an optional `LaneObstacles? obstacles` consulted as a virtual leader | A back-out's footprint, and the far-direction claim on the near lane, stop followers |
| `junction_arbiter.dart` (P0) | The `fromLeft` loop of `canJoin` pulled out into public `bool opposingClear(int lane, double at, double len)` | G2 and the far-side left-in (A6) |
| `agent_frame.dart` (P0) | `publish(..., {SiteVehicles? site, int sitesRev = 0})`, ignored until F | E can wire it now |
| `building_table.dart` (A) | Per-join rows, stride `kAccRows = 8`: `accEdge`, `accT`, `accLane`, `accBits` (`kAccIn`/`kAccOut`/`kAccLeft`/`kAccCut`), `accJoin`, `accCount`. Also `sync(city, lg, SitePlanSource? plans)`; `addGoals` over in-capable rows (D6 mask each); `addOrigins(h, ends, {int nearEdge = -1})` over out-capable rows; `leftOfAt(h, edge, t)`; `joinAt(h, edge, t, tol)`; reachability per role; a not-current plan reads kerbside at slot 0 | §3.10, §7.3 |
| `access_points.dart` (A) | `ofJoin(lg, joinNo)`, `ofPlanJoin(lg, plan, j)`; the side from `joinRight` | C1 |
| `trip_planner.dart` (E) | `deliver(..., {int car = -1})`, a waiting `_car` column, `_spawn` sending lot cars to `SiteMover.spawnFromStall`; CommuteSynth gains a `car` column (a pooled home car taken in `_request`, the owner captured before `arrived`) and `restoreAtWork(home, job, car)` | Departures start from the parked car |
| `city_agents.dart` (E) | Detailed below | Wiring |
| `agents_codec.dart` (D) | `v: 2` (v1 still readable), with a `sites` table of sorted ids and a `cars` table (Q2) | §14.1, item 10 |

The `city_agents.dart` wiring (E):
- **`prime()`:** building sync, then a site sync when `sites.needsSync(plans, lg)`, then saved cars placed after the first site sync. `_buildingsMoved` also fires on `sitesRev` or chunk identity.
- **`_subStep()`:** `events.beginStep()` first; `siteMover.step(now, this, this)` after `mover.step`; `sites.endStep()` last.
- **`arrived`:** after the `_accessMoved` check, `commutes.arrived` then `_park`. That is D17 step 1 (reserve, `holdAtGate`, state `parkingSearch`), else step 2 (`reserveAhead`, a one-element leg with `destS = slotT`, phase `kerbBound`), else garage.
- **`_remapAll`:** skips `onSite` slots, then calls `siteMover.remapHeld`.
- **Replans and origins:** `resolve`/`onPath` gain a new `kSiteReplanTag` (origins are the site's out-joins) and car origins (a kerb slot's `(edge, T, lane)`).
- **`despawned`:** releases stalls, kerb slots and claims.
- **`digest`:** folds sites, parked, kerbs, site columns, events and site stats.
- **Persistence:** `toJson` and `restore` use the v2 codec.
- **New getters:** `sites`, `parkedCars`, `accessEvents`, `siteVehicles`, `siteStats`, `agentManaged`, `agentManagedRev`, plus a `debugPlans` setter and `debugDepart(car)`.

## 3. Work breakdown

P0 comes first and runs alone. After it, A, B, C and D run concurrently, and E wires against the stubs. F waits for R3 and the KerbCuts commit. The tree must compile after every save; P0 stubs throw `UnimplementedError` until E enables the paths.

- **P0: seams.**
  - **Owns:** every §1 signature as a stub; `site_plan_source.dart`, `site_vehicles.dart`, `access_events.dart`, `site_stats.dart`, `test/traffic/site_fixture.dart`; the P0 edits in §2 and the `AgentTuning` statics.
  - **Accept:** `fvm flutter test test/traffic` plus analyze.
- **A: access rows (item 1).**
  - **Owns:** `access_points.dart`, `building_table.dart`, and their tests plus `access_join_test.dart`.
  - **Tests:**
    - `ofPlanJoin` equals `ofJoin`;
    - the side comes from `joinRight`;
    - goals come only from in-capable joins, with D6 masks;
    - LOOP enters at slot 0 and leaves at slot 2;
    - `leftOfAt` works by `(edge, T)`;
    - reachability is per role;
    - a not-current plan reads kerbside at slot 0.
- **B: site sync (items 2 and 7, sync side).**
  - **Owns:** `site_table.dart`, `site_plan_source.dart` (`BookPlanSource`), `site_geometry.dart`, `site_fixture.dart` (after P0), `site_table_test.dart`, `site_hops_test.dart`.
  - **First milestone, needed early by C:** rows, `stallOrder` and hops on STRIP and HOME.
  - **Tests:**
    - `lotCap == stallCount` (0 for KERBSIDE);
    - hops agree with a BFS without road links;
    - tandem order is deepest first;
    - `sharedSingle` units;
    - a changed rev keeps keys;
    - a limbo row is freed when empty;
    - a re-resolution with the same rev moves nothing.
- **C: site mover, gate, departures, back-out (items 3–6).**
  - **Owns:** `site_mover.dart`, `site_manoeuvre.dart`, `access_gaps.dart`, `site_drive_fixture.dart`, and the A5, A6, A9 and `site_manoeuvre_test` files.
  - **Tests:**
    - G1–G3; a forced grant at 25 s, give-up at 30 s;
    - stall pose within 0.05 m and 2°;
    - the front never passes kerb − 1 m before EXIT;
    - no EXIT with a body in the footprint;
    - a back-out EXIT at `T ± 11` in lane `L`;
    - `sharedSingle` is never used both ways at once;
    - an outbound car yields to an inbound one;
    - 600 s at 10× with no deadlock.
- **D: parking and persistence (item 8, item 10's codec, A7, the traffic half of A12).**
  - **Owns:** `parked_cars.dart`, `kerb_slots.dart`, `kerb_mask.dart` (interface only, test double until KerbCuts), `agents_codec.dart` and the matching tests.
  - **Tests:**
    - §7.1 caps;
    - masks against the double, re-pinned against KerbCuts once it lands;
    - reservations are binding;
    - LIFO pool;
    - codec round trip by `(siteId, stallKey)`: missing key → nearest free stall → garaged; an unknown site drops its cars; v1 still loads.
- **E: integration (items 6, 7 vehicle side, 11; A4, A8, A10 traffic half, A11, A13, A15).**
  - **Owns:** `city_agents.dart`, `trip_planner.dart`, and the tests: A4 `drive_in_and_park_test` (a forced trip to the aquifer pump on real R2 plans), A8 `site_plan_change_mid_trip_test`, A10 `renamed_lot_keeps_parked_cars_test` (with save/resume), A11 determinism additions, A13 `site_alloc_test`, A15 `site_access_events_property_test`, and the `traffic_alloc_test` additions. Also the city_sim hooks, if any are needed.
- **F: wire (item 9, E36 stage 1; after R3).**
  - **Owns:** `agent_frame.dart` (site columns), `city_traffic_frame.dart` (`sites`, `ParkedColumns` lot rows), `traffic_capture.dart` (manoeuvre geometry from `SiteManoeuvre`), `agent_nodes.dart`, publishing `agentManaged`, A14 `site_wire_test`, and the A12 traffic half against KerbCuts.

## 4. Decisions where the docs conflict or are silent

- **Q2, the saved lot-car row.** The two docs disagree: agent-traffic §14.1 has no `kind`, site-access §7.5 does. Follow site-access (its §7 is binding, D49): `[ownerKind, ownerIdx, where, siteIdx, stallKey | e,n,headingMilli, kind, variant]`, where `siteIdx` indexes the sorted `sites` table; `agents.v = 2`.
- **Q3, who owns a lot car under CommuteSynth.**
  - Cars at homes are `homePool`, and an outbound commute takes one, last in first out.
  - Cars at work are `commuter`-owned. On load, a commuter car gets `restoreAtWork(home, job, car)` with a wake time in the return window.
  - Tandem stalls are filled deepest first, and the unblocked car leaves first. A9 forces its shuffle through `debugDepart`.
- **Q6, D17 step 2 needs no path search in T4a.** The kerb slot is ahead on the same edge and lane, so step 2 is a one-element leg with a new `destS`, counted in `appendedLegs`.
- **Risks.**
  - **Allocation:** it is sync-time only; A13 is the structural gate, and the weighed gate is still owed by slice 11.
  - **Memory:** 8 access rows per building cost about 88 B per building (CSR later, slice 11).
