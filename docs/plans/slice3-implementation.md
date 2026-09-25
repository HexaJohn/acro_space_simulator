# Slice 3 implementation seams: citizens

Working plan for traffic slice 3 (agent-traffic.md "Slice 3 — Citizens"; §2.5, §6, §7, §12, §14.1, §17). Made against `5f2fb42` on `feat/agent-traffic`. It fixes the file ownership and the public APIs so the packages below can run in parallel in one worktree, the same shape as `docs/plans/t4a-implementation.md`.

## 0. Settled (overrides anything below)

- **The save-format promise.** The two car row shapes T4a writes do NOT change: lot and garaged are `[ownerKind, ownerIdx, where, siteIdx, stallKey, kind, variant]` (7 numbers), kerb is `[ownerKind, ownerIdx, where, e, n, headingMilli, kind, variant]` (8). `AgentsCodec.version` stays **2**; `oldestVersion` stays 1. The road side pins those shapes, and `test/persistence/agents_v2_pre_citizens_fixture_test.dart` is the committed evidence. `CarOwnerKind` gains **`citizen` at index 3, appended**; `AgentsCodec._byteOf(raw[0], CarOwnerKind.values.length)` already clamps an out-of-range kind to `none`, so nothing older mis-reads.
- **How a pre-port v2 save is read.** `ownerKind` is the tag of a union and always was.
  - On read, `commuter` and `homePool` keep their **T4a meaning: `ownerIdx` is a BUILDING slot** — the home a car pools at, or the home a car left at work came from.
  - `citizen` means `ownerIdx` is the dense citizen index of the same block's `cit` table.
  - The restore order (`stallOfKey` → `nearestFreeStall` → `garage`, `holdForSite`, drop only when the building is gone) is untouched, so every assertion in the fixture test holds by construction.
  - A commuter car whose owner was a building handle is **adopted**, not re-owned blindly: `_wakeRestored` becomes `_adoptRestored` and hands the car to a carless citizen of building `ownerIdx`, placed `atWork` at the car's site with a wake in the return window. With no such citizen yet, the row keeps its legacy kind, stands where it is, is re-saved unchanged, and is offered again at every citizen sync. **A legacy car is never dropped and never owned twice.**
- **Reconciliation never mints a car.** §6.6 mints a car at *arrival*. A citizen realised out of the **external** budget (a load, a revolt, a test writing `population`) is not an arrival: it adopts a free legacy car at its home, or owns none. Only `migrationBudget` arrivals draw `carOwnership`. Without this the fixture's one `city.advance(0.5)` would invent cars and break `cars.count == saved.rows.length`.
- **`AgentTuning.commuteRatePerResident` survives CommuteSynth.** Thirty test files set it, the fixture test's `setUp` among them. It is redefined as the **demand scale** against §6.5's design rate: the activity loop multiplies its commute wake-up probability by `commuteRatePerResident / kDesignCommuteRate` (0.00042), so the default is unchanged behaviour and **0 means no citizen trips at all**.
- **The one-tick contract (§6.2, §12.1).** Within one `CitySim.advance`: mortality and migration write the *ledger*, not `population`; `agents.advance` realises them later in the same tick and writes `population = citizens.liveCount + ledger.pendingFraction` at its end. Everything `CitySim` reads *from* the agents is still the previous advance's. `ext = population − ledger.lastWritten`, taken at the top of `advance`, is the only way an outside write reaches the citizens.
- **House rules.** PolyForm header on every new file; `traffic_source_hygiene_test` (no `math.Random`, `.hashCode`, `Object.hash`, `DateTime`, `Stopwatch`, no Map/Set iteration outside `agents_codec.dart`); no 64-bit int literals; saturating clocks via `addClock`, never wrapping; **never promote a nullable through a bool local and then read it** (the AOT miscompile, e456be6); zero steady-state allocation, buffers sized by capacity and collected into `collectBuffers`.
- **Commits.** Each agent commits its own paths with `git commit -- <paths>`. No `git add -A`.

## 1. Data model

All new files in `lib/domain/colony/city/traffic/`.

### 1.1 `citizen_table.dart` (owner A) — §2.5, capacity 16,384, doubling

```dart
enum CitizenState { atHome, travelling, atWork, atErrand, outOfTown, movingIn, leaving, riding } // save index, append-only
abstract final class CitizenFlags { static const int sick = 1, lateToday = 2, hasLicence = 4; }

class CitizenTable {
  CitizenTable({int capacity = 16384});
  final SlotPool pool;
  late Int32List home, work, car, agent, sleepsNear;   // building slots / handles, −1; car: parked handle, −1 driving, −2 none
  late Uint8List state, flags;
  late Float64List wakeUs;                              // absolute agent µs: a double never wraps (the waitMs lesson)
  late Int32List itS1, itL1, itX1, itX2, itL2, itS2;    // slice 9's locked itinerary; −1 now
  late Int32List homeNext, homePrev, workNext, workPrev; // intrusive per-building lists, arrival order
  int get liveCount; int get highWater;
  void ensureBuildings(int capacity);
  int spawn({required int home, required int work, required int car,
             required CitizenState state, required double wakeUs, int flags = 0});
  void remove(int citizen);
  void grow(int newCapacity);
  void setHome(int citizen, int buildingSlot);  void setWork(int citizen, int buildingSlot);
  int residentsOf(int buildingSlot); int workersOf(int buildingSlot);
  int newestResident(int buildingSlot); int newestWorker(int buildingSlot); // eviction, lay-off
  // The activity wheel: 512 buckets x 0.5 s (256 s), intrusive Int32List links,
  // plus an overflow head rescanned when the wheel wraps.
  void schedule(int citizen, double atUs); void unschedule(int citizen);
  int takeDue(int nowUs, Int32List out, int cap);   // bucket order, then slot order
  void collectBuffers(Map<String, Object> into, String name);
  int digest(int hash);
}
```

### 1.2 `population_ledger.dart` (owner D) — §6.2

```dart
class PopulationLedger {
  double migration = 0, death = 0, external = 0, pendingFraction = 0, lastWritten = 0;
  void addMigration(double delta); void addDeath(double died);
  void syncExternal(double population);            // ext = population − lastWritten
  int takeArrivals(int cap); int takeDepartures(int cap); int takeDeaths(int cap);
  double writeBack(int liveCount);                 // liveCount + pendingFraction; sets lastWritten
  Map<String, Object?> toJson(); void restore(Object? json);
  int digest(int hash);
}
```

### 1.3 `citizen_match.dart` (owner B) — §6.3

```dart
abstract interface class TripSkims {              // T4b swaps in zone skims (§4.9)
  bool get ready;
  double carSkim(int fromBuildingSlot, int toBuildingSlot);
  double footSkim(int fromBuildingSlot, int toBuildingSlot);
}
final class StraightLineSkims implements TripSkims {   // §6.3 stand-in: d/12, 1.35·d/1.3
  StraightLineSkims(BuildingTable buildings);
}
class CitizenMatch {
  CitizenMatch(CitizenTable citizens, BuildingTable buildings, TrafficRng rng);
  TripSkims skims;
  int drawVacantHome();                            // vacancy-weighted, stable building order; −1
  int rehouse(int maxMoves);                       // §6.3, 64/sync, slot order
  int matchJobs(int maxMatches);                   // 64/sync; own mode's skim; 30 s tie band by rng
  int evictOverHoused();                           // Σ residents ≤ Σ housing, reverse arrival order
  int layOffOverStaffed();                         // Σ workers ≤ Σ jobs, last hired first out
  int pickEmigrant();                              // homeless, then unemployed, then rng
  int pickForDeath();                              // building order, weighted by residents
  int digest(int hash);
}
```

### 1.4 `citizen_population.dart` (owner D) — §6.2 realisation

```dart
abstract interface class CitizenWorld {            // implemented by _Core
  int adoptCarAt(int buildingSlot);                // a free legacy car at that home, re-owned; −1
  int mintCarAt(int citizen, int buildingSlot);    // §6.6 draw + park: lot, kerb ≤150 m, else garaged
  void releaseCar(int car);                        // emigrant or death: the row leaves the world
  void placeAtHome(int citizen, int home);         // interim: instant placement, stats.instantTrips++
  void leftTown(int citizen);
  void corpseAt(int buildingSlot);                 // BuildingTable.corpses += 1 (slice 5 serves it)
}
class CitizenPopulation {
  CitizenPopulation({required CitizenTable citizens, required BuildingTable buildings,
      required PopulationLedger ledger, required CitizenMatch match, required TrafficRng rng});
  int arrivals = 0, departures = 0, deaths = 0, adopted = 0, legacyCars = 0;
  void realise(int nowUs, CitizenWorld world, {required bool external});
  int digest(int hash);
}
```

`realise` caps spawns at `max(4, (0.02·liveCount).floor())` per sync; the rest stays in the budget.

### 1.5 `citizen_trips.dart` (owner C) — §6.4, §6.5; replaces `CommuteSynth`

It keeps CommuteSynth's whole public surface, so `traffic_fixture.dart`, `destination_demolished_test`, `rebuild_new_box_test` and `traffic_alloc_test` compile unchanged. A **trip row** is what the path queue's requester names, as a commuter row was, and a forced trip is a row with `citizen == -1`.

```dart
class CitizenTrips implements SpawnSink {
  CitizenTrips({required CitizenTable citizens, required BuildingTable buildings,
      required TripPlanner planner, required PathQueue queue, required VehicleTable table,
      required TrafficStats stats, required TrafficRng rng, int capacity = 8192});
  ParkedCarTable? cars;  TripSkims skims;  int nowUs = 0;  int sent = 0;
  final SlotPool pool;
  int get liveCount; int get atWork;
  int destOf(int trip); int destOfVehicle(int v); int originOf(int trip);
  int vehicleOf(int trip); bool isLive(int trip); int carOf(int trip); int homeOf(int trip);
  int citizenOf(int trip); int tripOf(int citizen);
  void setCar(int trip, int car);
  int force(int from, int to, {AgentKind kind = AgentKind.car,
      TripPurpose purpose = TripPurpose.commute, int car = -1});
  void wake(int nowUs);                            // due citizens off the wheel, in wheel order
  void onPath(PathRequest r, PathOutcome o, PlannedRoute p, int nowUs);
  void spawned(int owner, int handle); void replanWaiting(int owner);
  void replanFromSite(int owner, int tag);
  int arrived(int v, int nowUs); void despawned(int v, int nowUs); void vanished(int v);
  int digest(int hash);
  static double rush(double dayPhase);             // 1 + 0.6·(bump(φ;0.30,0.05)+bump(φ;0.72,0.05))
}
```

`rush` reads a `static final Float64List _bump` of 64 literal entries — **no `exp` anywhere**, in the tick or at init.

## 2. Edits to existing files

| File | Edit | Why |
|---|---|---|
| `traffic_tuning.dart` (P0) | One frozen block: `citizensOwnPopulation = true`, `carOwnership = 0.75`, `carOwnershipSealed = 0.6`, `rehousePerSync = 64`, `jobMatchPerSync = 64`, `arrivalsMin = 4`, `arrivalsShare = 0.02`, `errandFromHome = 0.15`, `errandFromWork = 0.2`, the §6.4 dwell bounds, `rushAmp = 0.6`, `homeCarRadiusM = 150`; `commuteRatePerResident` re-documented as the demand scale | §0; keeps 30 test files compiling |
| `parked_cars.dart` (P0) | `CarOwnerKind.citizen` appended; `int ownerOf(int car)`, `int ownerKindOf(int car)`, `void reown(int car, CarOwnerKind kind, int owner)` (rewrites the two columns in place, bumps `parkedRev`, keeps the row, its pool link and its stall) | the port; adoption must not move a row |
| `trip_planner.dart` (P0) | `CommuteSynth` deleted whole. `TripPlanner` untouched except a guard in `_spawn`: when the car is on a lot or garaged and `_outJoinOf` finds no join, **refuse the spawn** (`SlotPool.none`) instead of removing the parked row and spawning at the route origin | the latent teleport behind bug 1 |
| `building_table.dart` (B) | `late Int32List residents, workers` and `late Float32List corpses`; `int housingVacancy(int sl)`, `int jobVacancy(int sl)`, `int drawVacantHome(TrafficRng)`; `commuteOwed` retired | §6.2 invariants, §6.3, deaths |
| `agents_codec.dart` (D) | `cit` (`home`, `work`, `state`, `wakeInUs`, `flags` — site-indexed, dense, slot order) and `ledger` blocks; `SavedCitizens`, `CitizenSaveSource`, `CitizenRestoreSink`; `restoreCitizens`. **The `cars` writer and reader are not touched**; `version` stays 2 | §14.1 |
| `city_agents.dart` (E) | below | wiring |
| `city_sim.dart` (E) | **E8** at mortality: `if (agents.ownsPopulation) agents.ledger.addDeath(died); else` today's scalar path; `corpses += died` unchanged. **E9** at migration: compute the same target and rate, add the **delta** to `agents.ledger.addMigration` instead of writing `population`. Nothing else | §12.1 steps 12 and 15 |

The `city_agents.dart` wiring (E):
- **`_Core`** builds `citizens`, `ledger`, `match`, `population`, and `commutes` as `CitizenTrips`; implements `CitizenWorld`, `CitizenSaveSource`, `CitizenRestoreSink`.
- **`_subStep`:** after `planner.beginStep`, `population.realise(now, this, external: ...)` on a whole second; `commutes.wake(now)` then drains the wheel; the rest of §5.2's order is unchanged.
- **`prime`/`_syncBuildings`:** after a building sync, `citizens.ensureBuildings`, `match.evictOverHoused`, `match.layOffOverStaffed`, `match.rehouse`, `match.matchJobs`, then the **adoption sweep** over legacy-owned cars.
- **`_park`:** `carOwner` becomes the citizen handle and `kind` becomes `CarOwnerKind.citizen` for a citizen trip; a forced trip with no citizen keeps `commuter`/`homePool` exactly as today, so `drive_in_and_park_test` and the A9 shuffle are unmoved.
- **`_carOrigin`:** the fix, §3.
- **`_wakeRestored` → `_adoptRestored`** (§0).
- **New getters:** `citizens`, `ledger`, `ownsPopulation`, `populationStats`; `commutes` now returns `CitizenTrips?`. `digest` folds citizens, the ledger and the match.

## 3. Bug 1: a departing car's origin is where the car stands

`_carOrigin` answers only for `CarWhere.kerb`; `resolve` then falls back to `buildings.addOrigins(request.origin, ends)`, so a car on a **stall** is assumed to be at its trip's origin building. That holds only because every car today parks at a site it belongs to. With citizens — a car left at work, a car adopted at another home, an errand chain — it stops holding, and `TripPlanner._spawn` then finds no out-join, removes the parked row and spawns the vehicle **at the trip's origin access point**: the car teleports across town and its stall silently frees.

```dart
/// True when [trip]'s own car said where the search starts. A car at a KERB
/// leaves from its slot's (edge, T) in that slot's lane; a car on a STALL
/// leaves by ITS OWN site's out-joins; a GARAGED car from the building it is
/// garaged at — never from the trip's origin, which is only where the person
/// is. False only for a trip with no live car.
bool _carOrigin(int trip, LaneGraph g, PathEnds ends);
```

Lot and garaged both resolve through `buildings.addOrigins(buildings.handleOf(b), ends)`, where `b` is `sites.building[parked.row[i]]` for a lot car and `parked.building[i]` for a garaged one. `_spawn`'s new refusal closes the other half: a route whose first edge is nowhere near the car's site is never spawned by teleport, it is re-requested.

**Test (owner E), `car_departs_from_where_it_stands_test.dart`:** on the `site_drive_fixture` grid, a citizen of home A drives to job B and parks on B's stall; then force a trip whose origin building is A while the car still stands at B. Assert the search origin is one of B's out-join `(edge, T)` rows, exactly one EXIT access event is logged on B's row, B's stall is released by the site mover (not by `parked.remove`), and no vehicle ever appears at A's access `T`. The pre-fix build fails on the first and third.

## 4. Work breakdown

**P0 runs alone and first**, as T4a's did; the tree must compile after every save, and P0's bodies throw `UnimplementedError` until their owners land. Then A–E run concurrently on disjoint files, E wiring against the frozen stubs.

- **P0: seams and the port.** Owns every §1 signature as a stub, the `AgentTuning` block, `CarOwnerKind.citizen` + `reown`/`ownerOf`, the deletion of `CommuteSynth`, the `CityAgents` getters, and `test/traffic/citizen_fixture.dart`.
  - **Accept:** `fvm flutter test test/traffic test/persistence`, analyze clean.
- **A: the citizen table and the wheel.** Owns `citizen_table.dart` and its tests. Doubling past 16,384 keeps handles; `takeDue` is bucket-then-slot order and O(due); the overflow list is rescanned on a wrap and never loses a citizen; the intrusive home/work lists give arrival order; `digest` is order-independent of insertion; nothing is reallocated after warm-up.
- **B: housing, jobs and occupancy.** Owns `citizen_match.dart` and `building_table.dart`. `Σ residents ≤ Σ housing` and `Σ workers ≤ Σ jobs` after every sync; eviction is reverse arrival order and lay-off last hired first out; the stand-in skim divides by 12 for a car owner and by 1.3/1.35 otherwise; ties within 30 s are broken by `TrafficRng` and nothing else; a citizen with no car is never given a job only a car could reach.
- **C: the activity loop.** Owns `citizen_trips.dart` and its tests. Each §6.4 row's dwell falls in its interval; `rush` peaks at φ 0.30 and 0.72 and integrates over a day to the flat rate; `commuteRatePerResident = 0` emits nothing; wake-ups over `maxSpawnsPerStep` roll to the next sub-step in wheel order and are counted in `deferred`; a car trip is chosen only when the car is where the citizen is; forced trips stay one-way.
- **D: population, ledger and persistence.** Owns `population_ledger.dart`, `citizen_population.dart`, `agents_codec.dart` and the save tests. §17.3 #20 parity within ±5% over 10 agent-minutes; the arrival cap; emigration order; a death lands on a home and on `BuildingTable.corpses`; citizens, ledger and RNG equal across a round trip; a legacy block adopts once and only once; **`test/persistence/agents_v2_pre_citizens_fixture_test.dart` passes unchanged** — this package owns keeping it so.
- **E: integration and the origin fix.** Owns `city_agents.dart`, the two `city_sim.dart` hooks, `traffic_fixture.dart`, `car_departs_from_where_it_stands_test.dart`, `citizen_save_resume_test.dart`, and the additions to the determinism and allocation tests.
  - **Accept (merge gate):** `test/traffic` and `test/persistence` green, hygiene green, and the allocation gate showing no new buffer after 1,000 warm sub-steps.

## 5. Decisions where the docs conflict or are silent

- **Q1, `commuteRatePerResident` after CommuteSynth.** Silent. **Default: keep the static**, redefined as the demand scale (§0).
- **Q2, does a reconciled citizen get a car?** §6.6 and §14.4 disagree by omission. **Default: no** — external-budget citizens adopt or go without; only migration arrivals draw `carOwnership`.
- **Q3, an unadopted legacy car.** Silent. **Default:** it stands, keeps its legacy `ownerKind`/`ownerIdx`, is re-saved byte-identically, and is re-offered at every sync. Counted in `CitizenPopulation.legacyCars`.
- **Q4, what `cit.car` points at.** §14.1 lists a `car` column, but cars have no stable save id. **Default: do not write `cit.car`.** The CAR row's `ownerIdx` is the dense citizen index, and the load rebuilds `citizens.car` from it — one direction, one source of truth.
- **Q5, `ownsPopulation` default.** §6.2 says it switches on with slice 3. **Default: on**, behind `AgentTuning.citizensOwnPopulation`, gated by the parity test, so a bisect can put the scalar path back without a revert.
- **Q6, `movingIn` and `leaving` in the interim.** **Default:** `movingIn` resolves in the same sub-step (`stats.instantTrips++`), and an emigrant leaves instantly with their car removed; the stub drive-out is slice 8's.
- **Q7, errand destinations before slice 8.** **Default:** any reachable built building that is neither the citizen's home nor their work, weighted `1/(1 + skim/180)` on the stand-in skim; goods-aware commercial arrives with slice 8.
