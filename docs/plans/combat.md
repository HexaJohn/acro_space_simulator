# Combat: taking colonies back by force

Status: draft for review, 2026-10-10. Baseline `dev` at `9eccb7d`. Paths are relative to the repo root.
Planning only: nothing here is built. Every line anchor below was checked at `9eccb7d`.
Revised after review: the occupation entry, the operation clock, the lifecycle of garrisons, staffing, the
calibration, budgets and the phase split were all reworked against the code (§5.3, §7, §16).

## 1. Intent

The user, 2026-10-10, on reclaiming a seceded colony by force:

> "would basically turn this into an RTS then, no?" … "RTS mode would be pretty cool tho" … "RTS or even
> allowing the player to engage in the battle themselves as a soldier or pilot or something" … "Just plan it
> for now"

The precedent the user responded to is *Battlezone* (1998). It is an RTS played from inside a hover tank on the
Moon, Mars and Venus, and the pilot can eject and fight on foot.

`colony-secession.md` §6.3 left **Force** as the last way back. It sketched garrison strength against resistance
= population × (1 − happiness), with a win making the colony `occupied`. Phases 1–3 of that plan are built. This
plan replaces its phase 4 and grows it into a pillar of the game the size of the city builder. It has three
layers:

- **A force operation** the simulation resolves on its own, Total War style. Every battle gets a result whether
  or not the player watches it.
- **Fight it yourself.** Drop into the battle as a soldier, and later as a driver or pilot, using seats the game
  already has: the walker, the EVA pack, the rover and flight.
- **Command it.** Give orders from first person with Battlezone's number keys, and later from a top-down
  command view on the city camera.

Five rules shape everything below:

1. **One battle state; everything else is a way of looking at it.** An operation is a set of *formations*
   (squads kept as counts) fighting over *objectives* that already exist as colony state: the pads, the seat,
   life support, power. The auto-resolver advances those pools. When the player joins, a live fight takes over
   one objective and writes its results back into the same pools. Leaving folds it back. Because there is only
   one model, a fought battle and an auto-resolved one cannot drift apart. That drift is Total War's chronic
   failure.
2. **Combat follows from governance, and force costs the prize.** Troopers are colonists, so the dead are
   people. Force wins no loyalty. Negotiating, winning hearts and waiting out a dependency petition stay cheaper.
3. **Deterministic and command-driven from the first phase**, single-player included. Every player input that an
   operation depends on is a `SimCommand` applied at the tick, never a widget mutation. Frame time may change
   only what is drawn, never sim state. The operation reads colony state once, at launch, and after that hears
   from colonies only through events they post from their own tick (§5.3). That keeps the door open to replay,
   mid-battle saves and networking. Retrofitting it later is the expensive mistake.
4. **Every phase ships on its own and could be the last.** Phase 1 has no units on screen at all.
5. **Small, capped battles.** A rebel starter town fields about 8 militia. A large seceded colony fields over a
   hundred. Live fighting is capped (24 per side by default), and the rest wait as reserves that arrive in
   waves.

## 2. What exists today

| Piece | Where | State / gap |
|---|---|---|
| Allegiance with a reserved `occupied` | `city_loyalty.dart:31-41` | saved and loaded by name, never entered |
| Port seizure and release | seizure `city_loyalty.dart:621-629`; `_release()` `:637-643`; `admitCraft` `:451-458` | released only by loyalty recovery, secession or rejoining. **Re-seized on the next step** while the colony is in standoff with desperation > 0.4 (`seizeDesperation`, `:93`) |
| Reclaim: grievance, petitions, reputation | severity `city_reclaim.dart:150-160`; `acceptPetition` `:652`; `reputationOf` `:805`; `blockadeNote` `:771` | the Force row is a placeholder (`city_reclaim_ui.dart:109-112`), pinned disabled (`test/colony/city_control_gate_test.dart:802-805`) |
| Control gate | `city_control.dart:58-62` | colonial and occupied are allowed (pinned `city_control_gate_test.dart:139-143`); independent is refused |
| Military buildings | `city_building_spec.dart:433-469`: arms factory, missile plant, rations plant, barracks, base, gun emplacement, silo, airfield | feed `safety` only, aggregated by utilisation without checking staff or inputs (`city_sim.dart:1366-1381`). Standing-army attrition (`:1789-1794`) walks the legacy cell grid only. Barracks inputs are per second: 0.5 rations, 0.05 guns, 0.3 ammo (`city_building_spec.dart:448-451`) |
| Staffing | `city_sim.dart:1412-1473` | **one colony-wide ratio**: `workforce = min(population, jobs)`, then `lifeThrottle` and `restThrottle`. No building has its own staff; `parcelActive` holds only `(spec, uf)` pairs with no site id (`:1389-1407`) |
| Military goods | `commodity.dart:29-33`: guns, ammo, rations, missiles | pure sinks; not deliverable (`city_sim.dart:6187-6198`); no vessel `ResourceType` |
| Production rule | `city_sim.dart:1528-1535`: a building runs only if every input is in stock | the readiness test this plan reuses |
| Deaths | CitySim's death write `city_sim.dart:1804-1810`, which feeds `PopulationLedger.addDeath` (E8, `traffic/population_ledger.dart:79`) when citizens own the population | the only casualty path combat needs; no new traffic hook |
| Revolt | `city_sim.dart:2239-2247`: −30% population, funds ×0.6 | candidate for a defend-the-colony battle later |
| Building removal | `clearParcel` `city_sim.dart:5834-5845`; lot fires `:4923` | every disaster damage helper is cell-grid only and uses unseeded `math.Random()` (20 call sites) |
| Pads, life support, frames | `landingPads()` `city_sim.dart:5505-5509`; `isLifeSupport` `:3219`; `localToBodyFixed` `:5514` | objective sources |
| Tick seams | reputation pre-pass `advance_simulation_tick.dart:389`; city loop with frame hold `:390-395`; `_cityPhase` `:511-525` | `_combatPhase` goes beside the pre-pass, before the city loop (§5.3); the inbox drains at the start of `_cityPhase` |
| Supply shuttles | `ShuttleRun` `shuttle_run.dart:50`; `ColonyShuttleFactory` `:88` (ownerId `'logistics'` `:174`); dispatch `advance_simulation_tick.dart:694` | ids come from `_shuttleSeq` (`:668`, `:697`), which is not saved and resets when a cheat toggle rebuilds the tick. Runs are not saved |
| Pad cargo seam | `ShuttleCargoService`, 60 m pad radius (`shuttle_cargo.dart:60-62`), impound (`:126`) | anything landed near a closed pad is impounded, so force must land off-pad |
| Landing guidance | `landing_guidance.dart:119` (`unrecoverable` `:150`); `LandingTarget` `landing_target.dart:20-38` | flies to any body-fixed point; tested end to end on the Moon (`test/colony/shuttle_dispatch_test.dart`) |
| Walker and EVA pack | `stepFirstPersonWalk` `first_person_walker.dart:75-127` (landing speed thrown away at `:122-124`); `stepEvaPack` `eva_pack.dart:74-156` (`hardContact` `:144`, unused) | pure, doubles only, body-fixed. Stepped per frame by the widget, never on the tick |
| Rover | `stepRover` `rover_buggy.dart:229-260` | pure, but wired only into the two studios, in a tangent plane |
| Suit hazards | `SurfaceConditions` `surface_conditions.dart:212-230` (`armstrongAtm`, `oxygenCover`, `vacuumHostile`) | ready for suit breach; terraforming changes the answer |
| Terrain queries | `baseGroundRadiusAt` `terrain_field.dart:177`; `surfaceRadiusAt` `:229`; `groundRadiusAt` `:297` | **cost not settled**: `colony_ground.dart:11-12` says 8–16 ms per edited sample; commit 7d325cf (later) measured `groundRadiusAt` at ~0.69 ms in a settled starter town headless; `surfaceRadiusAt` is unmeasured |
| Colony ground raster | `ColonyGroundSampler` `colony_ground.dart:26` | 8 m lazy raster for the road tool; any brush drops the whole raster |
| Building and prop volumes | `BuildingMassing.massFor` `building_massing.dart:307`; `ScatterColliders` `scatter_collision.dart:259` | pure domain volumes; not the drawn archetype |
| Determinism kit | `traffic/traffic_rng.dart`, `slot_pool.dart`, `traffic_time.dart` (Agent Traffic's) | copy, don't import: `hash32.dart:6-18` is the copy-with-pin-test precedent |
| Commands | sealed `SimCommand` `command.dart:15`; `Session.validate` `session.dart:35`; switch `apply_commands.dart:39`; wire switch `FlatBufferCodec._envelope` `flatbuffer_codec.dart:394` (exhaustive, no default) | five cases, none for units; the live game calls `AdvanceSimulationTick` directly and bypasses the authoritative path |
| Tick hosts | `FlightSession.rebuildTick` `flight_session.dart:141-161` (a new tick on every cheat toggle); `SimHost` `sim_host.dart:83-117` (its own tick, no FlightSession, fixedStep 1.0) | `CitySim.advance` is also called outside the world tick: the dev hook's `_step` (`main_city_game_dev.dart:447-461`), `CityBuilderScreen` (`city_builder_screen.dart:223`) and `advanceCity` with no clock (`advance_simulation_tick.dart:500-504`) |
| Colony clock | `city_sim.dart:1352`: `dt = (simDt × eventSimWarp).clamp(0, 0.5)` | `Disaster.timeDilation` sets `eventSimWarp` to 0.4–2.2 (`:2805-2807`); disasters are picked with unseeded `math.Random()` (`:2636`, `:2654`) when `hostility > 0.02` (`:2646`; default 0.4, `:413`) |
| Fingerprint | `WorldSnapshot.fingerprint` `world_snapshot.dart:3284`; atmosphere block appended only when present `:3350-3357` | the pattern for a combat digest |
| Save | `GameStateCodec.schemaVersion = 2` `game_state_codec.dart:41`; `_save` `simulation_view.dart:2695` (flushes held agent ticks `:2700`); slot is one in-memory string `:1169` | no terrain edits, no `landingTarget`, no shuttle runs |
| Event channel | `simulation_view.dart:1785` | capped at 64 events per frame, String-typed |
| 1× warp precedent | `simulation_view.dart:1878-1889` (hand-flying in atmosphere) | battles reuse it |
| Host loop | `simulation_view.dart:1976-1992`: 50 Hz, at most 25 steps per frame | no tick interpolation exists |
| City camera and picking | `_cityCamera` `simulation_view_colony.dart:206`; `_cityPickLayer` `:1034`; `_PickGate` `:1415`; `_PickClaim` `:1449`; `projectPx` `perspective_camera.dart:140`; `CraftEditorPick` (22 px grab) `craft_editor_pick.dart:44-49` | an RTS camera already, but city mode only; the ground pick is a sphere at the colony-centre radius |
| Effects | `ImpactFxNodes` (dedup key `subject:tick` `impact_fx_nodes.dart:121`, plain `SpriteMaterial` `:254-260`); `DepthSafeSpriteMaterial` `depth_materials.dart:108`; `BillboardFacing.velocityStretched` (`third_party/flutter_scene/.../billboard_geometry.dart:26`) | allocates per event; not depth-safe |
| Moving-crowd render precedent | `agent_nodes.dart`; `AgentRenderClock` `agent_traffic_pass.dart:90`; `CityTrafficFrame` `city_traffic_frame.dart:33` | Agent Traffic's code: a template to copy, never shared |
| World overlay | `RoadOverlayState` `road_overlay_state.dart:104` | a singleton the road tool wipes on every tool change |
| Perf control | `FrameBudget` `frame_budget.dart:34`; `perf_knobs.dart`; `CityFrameGovernor` `city_studio_screen.dart:186` | the governor runs in the city studio only |
| HUD and hooks | notice queue `city_game_hud.dart:95-129`; `CitySiteHooks.extra` `city_site_actions.dart:54`; `ext.acro.*` in `main_city_game_dev.dart:114-258`; `tool/drive_city_game.dart` | entry rows, news and the headless driver |
| Pilot input | `PilotInput.action` "stage / fire. Carried, not interpreted." `pilot_input.dart:33` | applied per frame (`simulation_view.dart:1877`), outside the command stream |
| Destruction cheats | `FlightCheats` default `disableOverheat` and `disableCraftDestruction` to **true** (`flight_session.dart:44-46`) | combat damage must not ride these |
| Test templates | `test/persistence/save_resume_determinism_test.dart`, `test/multiplayer/authoritative_sim_test.dart`, `test/traffic/colony_hooks_test.dart`, `test/traffic/traffic_source_hygiene_test.dart`, `tool/aot_traffic_smoke.dart` | twin-run, save-resume, frame-hold, hygiene, AOT smoke |

**Does not exist anywhere:** a strength or garrison model, unit entities, weapons, health, hit detection,
line of sight, off-road navigation, unit AI, selection or orders, unit rendering, a combat HUD, audio, and any
humanoid or vehicle art beyond engine primitives.

**Traps found while reading, which this plan works around:**
- **Re-seizure.** A port released by force would be seized again on the next loyalty step (`city_loyalty.dart:621-629`). §7.1 adds a port garrison.
- **Retaking a standoff port starts an exodus.** With the port open and the colony still in standoff,
  `standoffEmigration` holds (`city_loyalty.dart:433-434`), `loyaltyPopCap` caps the target at `localCapacity`
  (`:851-855`, applied at `city_sim.dart:1903`) and settlers leave at 1 + 1.5·(1−h) + 2·shortfall a colony second
  (`city_sim.dart:1928-1935`). Desperation keeps rising in standoff unless the colony is attended
  (`city_loyalty.dart:537-550`), and the standoff branch secedes the colony the moment it clears the falling bar
  (`:401-402`, `:562-565`). §7.1 states both and stops adding desperation on a win.
- **Setting `occupied` alone re-secedes on the next tick.** `_stageStep` short-circuits only for `independent`
  (`city_loyalty.dart:558`). An occupied colony takes the colonial branch with `stage` still `seceded`, which no
  colonial rule leaves (`:582-597`), so the HUD would read "Independent" (`:55`). Its revolts are kept, so a
  colony that seceded by three revolts in 15 days meets `revolts.length >= 3` and secedes again
  (`:562-565`). `_rejoin` clears revolts for exactly this reason (`city_reclaim.dart:712-714`). §7.2 adds an
  `occupy()` transition modelled on `_rejoin`.
- **Occupation erodes in about 850 s, not 240.** Misrule takes 240 s only if rebellion holds at 0.8, and it does not:
  rebellion relaxes toward `unrest − 0.4` with a 7 s time constant (`city_sim.dart:2237-2238`). The binding term is
  neglect. `attendedAtS` is stale from before secession, so erosion runs at full ramp: 1/3,600 per s
  (`city_loyalty.dart:195-196`) × (1 − 0.75·content). At content 0.2 that takes loyalty 0.2 to 0 in about 850 s
  (7 colony days). §7.2 handles it.
- **§6.3's formula is mis-scaled.** Garrison = safety counts people served (barracks 150), so one barracks beats every town. `pop × (1 − happiness)` also reads unhappiness under the rebels' own council as hostility to the player, which contradicts the hearts route. §4.2 replaces it.
- **CitySim is not deterministic** (unseeded `math.Random()`). Every call in its tick is on a disaster path: the
  auto-disaster timer and pick (`city_sim.dart:2636`, `:2654`), chained disasters (`:3078`), fire and flattening
  (`:2804`, `:2907-3208`, `:4925-4968`). With `hostility ≤ 0.02` and no disaster running, the tick draws none.
  Combat reads colony state only at launch (§5.3), never reuses the damage or fire helpers, and its determinism
  tests run on that disaster-free fixture (§12).
- **The colony clock is not the world clock.** Colony dt includes `eventSimWarp` (0.4–2.2 under a time-dilation
  event), and a frame-budgeted colony replays its ticks after the frame, up to `maxHeldCityS` = 15 colony seconds
  late (`traffic_tuning.dart:316`; `advance_simulation_tick.dart:390-393`). An operation stepped partly inside
  colonies and partly in the world would mix states from different times. §5.3 gives it one owner and one clock.
- **No building has its own staff** (table above). "Its readiness and output fall while troopers are away" needs a
  new per-site factor (§4.1).
- **Real transfer time cannot set battle timing.** Colony time is capped per frame, so an Earth→Moon transfer costs anywhere from ~0.5 to ~2,000 colony days depending on warp. Transit is a fixed number of operation days (§5.3), as the supply shuttles already use fixed colony days.
- **Earth and Mars landings are likely broken** by the inertial-frame aero: a phantom headwind near equatorial colonies, found by code-reading and not verified by a run. Real landers fly on airless bodies first.

## 3. How this plan was chosen

Four competing designs were written and judged on three lenses:
- codebase fit and feasibility;
- player experience;
- scope and phasing.

| Design | Primary seat | Feasibility | Experience | Phasing | Sum |
|---|---|---|---|---|---|
| **Operations Ledger** | auto-resolve first; later layers zoom into the same battle | 8 | 6 | 8.5 | **22.5** |
| Ground Operations | RTS command first, avatar later | 7 | 7 | 7.2 | 21.2 |
| Drop Zone | avatar first, command thin | 6.5 | 8 | 6.3 | 20.8 |
| Warfront | one unit table for player and AI (Battlezone hybrid) | 6 | 8.5 | 5.4 | 19.9 |

**Operations Ledger wins on the sum.** It was top on two of the three lenses. Its first three phases are pure
domain code plus thin UI on seams that exist (`_cityPhase`, `_release()`, the E8 death write, the codec's
omit-at-default style). It needs no ground raster, navigation, unit renderer or walker re-homing until those
costs are measured. Every live design made unmeasured or wrong claims about exactly those costs.

It lost the player-experience lens because its first slice is a progress bar and a report, with both seats the
user is excited about (soldier and commander) behind it. This plan answers that in two ways:
- It grafts in the Battlezone pieces the experience judges valued most from Warfront and Drop Zone (§8–§10).
- It makes the live layer movable: phase 4 (the soldier) can come straight after phase 1 if the user wants to
  fight sooner, and phases 4 and 5 can swap. Each move carries named pieces with it (§16, "Prerequisites and
  reordering"; Q1).

§15 records what each losing design contributed and why it lost.

## 4. Who fights

### 4.1 The player's side: the expeditionary force

- **Sources.** Squads come from staffed military buildings in any colony the player controls (colonial or
  occupied), on the same body or another. The planner lists each source and what it can field.
- **Manpower.** Troopers per building = `floor(jobs × restThrottle × 0.5)`. A barracks (30 jobs) gives up to 15
  and a Military Base (80) up to 40. The other half are support staff who stay home. `restThrottle` is the strike
  throttle, so a Defiant colony (×0.7) fields fewer.
- **Readiness.** A building counts only while it is *ready*, meaning its inputs (rations, guns, ammo) are in
  stock. That is the test the production loop already applies (`city_sim.dart:1528-1535`). Readiness gates who
  may deploy; it does not change how the safety service is computed today.
- **Squads.** Troopers group into `infantry` formations of up to 8.
- **Kit.** It follows the source building's own input table, so tuning lives in one place. Per trooper-day it is
  the building's inputs × `daySec` / jobs. For a barracks that is 2 rations, 0.2 guns and 1.2 ammo.
  - At launch: 1 gun per trooper (no gun, no trooper), plus the chosen days of supply (default 3 operation days).
  - **Moved, not added.** While troopers are away, their building's own input draw at home falls by the
    deployed share. A deployed trooper therefore costs the colony what the same trooper costs idling in the
    barracks. The earlier flat rate (0.3 ammo and 0.1 rations a trooper-day) was 4× (ammo) to 20× (rations)
    below the barracks's own burn per job, and is dropped.
- **The per-site operational factor (new CitySim concept).** Staffing today is one colony-wide ratio (§2), so
  there is no per-building staff to take away. `city_war.dart` adds `siteFactor(siteId) ∈ [0, 1]`:
  `(1 − deployedShare) × damageFactor`. It multiplies `uf` for that site in **both** aggregation loops: the cell
  loop (`city_sim.dart:1376-1381`) and the parcel loop (`:1389-1407`, which must carry the site id beside
  `(spec, uf)`). Jobs, services (safety included) and power draw scale with it, and the production loop
  (`:1520-1540`) multiplies that site's run, so its inputs and outputs scale too. Deployed troopers also leave
  the `workforce` count (`:1412`), so while away they are neither employed nor unemployed. This is a real change
  to CitySim's hot loop, budgeted in §18, with a test that a factor of 1 everywhere leaves every aggregate
  bit-identical.
- **Troopers are colonists** (Q6).
  - They stay residents of their home colony and keep their homes.
  - Their site's factor drops by the deployed share, so its jobs, safety and output fall while they are gone.
  - **They still commute in Agent Traffic's table.** Traffic has no "away" concept, and C1–C5 ask for none. This
    is accepted as a visual oddity through phase 5, and contract request C6 (§18) asks for an away flag.
  - A trooper killed is a death charged to the home colony through CitySim's own death write. No corpse is
    added there: the dead are buried at the landing zone.
  - Survivors come home at the end. Wounded come home too but cannot redeploy for 2 colony days, a timer saved
    on the home colony (§13).
- **Later kinds:**
  - armour from the Military Base: 2 vehicles + 3 crew each (phase 6);
  - gunships from the Airfield (phase 7).
- **Prerequisite: a whole supply chain.** Guns, ammo and rations cannot be delivered (`city_sim.dart:6187-6198`).
  A source colony must therefore run its own chain:
  - an Arms Factory (unlocks at 300; steel and electronics in, guns and ammo out);
  - a Rations Plant (200; food in);
  - a Barracks (300) or Military Base (600).
  The planner's "why not ready" copy names the missing link ("No Arms Factory: guns and ammo cannot be shipped
  in"). Force also needs a second colony to fight over (Q20). A headless reachability test (§16, phase 1) proves
  a starter colony can reach this chain.

### 4.2 The colony's side

**Resolve** r ∈ [0.05, 0.95] replaces §6.3's `pop × (1 − happiness)`:

```
r = clamp(0.2 + 0.5·severity + 0.3·mood − 0.6·wish − 0.3·hunger, 0.05, 0.95)
  severity: Grievance severity (city_reclaim.dart:150-160), recorded at secession; for a standoff colony
            (no grievance yet) the same formula on its live loyalty state
  mood:     the colony's happiness
  wish:     hearts pressure (CityReclaim.pressure), 0 for a standoff colony
  hunger:   1 − foodSecurity
```

How the terms read:
- A content colony with a real grievance fights hardest.
- A colony that wants to come home fights badly, so force and the hearts route point the same way.
- A starving colony folds.

**Who turns out:**
- **Militia** = `floor(population × (0.04 + 0.20·r))`.
  - Armed = `min(militia, guns in stock + floor(0.3 × militia))`, at quality 0.5. The 30% bring hunting rifles,
    mining charges and tools. (An earlier draft added "impounded guns". Impounded cargo is already in the stock
    (`shuttle_cargo.dart:118-126`), and guns cannot be delivered, so that term counted twice and was always zero.)
  - The rest are improvised, at quality 0.3.
- **Regulars.** A colony that kept staffed barracks or bases from before it seceded fields troopers from them
  exactly as the player does (quality 1.0). The independent governor never builds military, so this only
  happens to colonies that had it.
- **Emplacements.** Each staffed Gun Emplacement is a static `emplacement` formation at its nearest objective.
- **Port holders** (standoff colony): `ceil(spaceportJobs × 0.5 + population × 0.03 × r)` at quality 0.5, starting
  morale 0.4. They are the opening garrison only. While the port is contested, sympathisers join from the town in
  waves, up to the militia formula, so a large standoff colony is a real fight.
- **All of these are sized once, at launch,** from a `LaunchSnapshot` of the target (population, mood, hunger,
  severity, wish, guns, staffed military, spaceport jobs). Waves draw on that snapshot's pool, not on the live
  colony (§5.3).

**Worked scale:**
- A starter town under its governor: about 64 settlers, mood 0.2, severity 0.5, so r ≈ 0.45. It fields about 8
  militia, 2 of them armed.
- A 1,000-colonist colony that seceded with one barracks, at r = 0.6: about 160 militia (about 48 armed), 15
  regulars and any emplacements.

Live caps (§8.1) handle the large end.

### 4.3 Civilians (proposed policy, Q2 and Q5)

- **Civilians are never units and never targetable.** Harm is abstract, decided by the rules of engagement (ROE)
  the player picks in the planner:
  - **Restrained** (default): small arms only inside the town. Buildings can be damaged but never destroyed. No
    civilian deaths. Attacker strength ×0.85.
  - **Standard**: collateral at full weight. Civilian deaths are possible, and buildings can be destroyed from
    phase 6.
  - **Heavy** (phase 6, needs heavy weapons): collateral ×2, attacker strength ×1.25.
- **Civilian deaths** = `collateral × density × (1 − shelter)`.
  - `shelter = min(0.95, 0.5 + 0.5 × (bunker + fallout-shelter capacity) / population)`: people at home count half
    sheltered, and bunkers (50) and shelters (30) finally have a use.
  - Deaths go through E8 in the target colony and add to its `Grievance.warDead`. They lower the player's
    reputation through war weariness (§7.4).
- **Agent Traffic's cars and citizens keep moving through a battle and do not interact with it.** They have no
  domain pose, and that code is not ours. Contract requests C1–C3 (§18) would let them shelter or stop. Until then
  this is an accepted visual oddity, and battles are set at the port and the perimeter, where traffic is light.

### 4.4 Factions

- A minimal `FactionId` value type sits on every operation side, formation and live unit from the first phase:
  - `player`;
  - `colony:<cityId>`;
  - `rival:<id>` (reserved).
- A small helper reconciles the free-form `Vessel.ownerId` strings (`'player'` and `'player-1'` are both in use).
- Rival factions are phase 8 at the earliest (Q4).

## 5. Triggers and lifecycle

### 5.1 Triggers, in build order

1. **Retake the port (phase 1).** The target is a still-colonial colony in standoff with `portSeized`. A "Retake
   the port by force" row appears on its spaceport site sheet (`CitySiteHooks.extra`) and in the seized-port
   notice and loyalty explainer. The gate already allows acts there.
   - Launching is a gated act that deliberately **does not stamp attention**: force is coercion, and like hunger in
     `blockadeNote`, it wins no loyalty.
2. **Force (phase 2).** The Reclaim Force row (`city_reclaim_ui.dart:109-112`) on an independent colony. It is a
   Reclaim answer, live under the gate exactly like Negotiate.
3. **Uprising defence (phase 8).** At rebellion 1.0, or a cult uprising, in a colony with a garrison, the colony
   gets a battle with sides swapped instead of the flat −30% revolt. This needs the secession lane's sign-off
   (Q16).
4. **Rival raids (phase 8+).**

### 5.2 The operation

```
planned → mustering (0.25 day) → transit (0.5 day same body, 1.5 days other body) → landing → engaged
        → resolved { won | lost | withdrawn | ceasefire | rejoined | overtaken } → aftermath
```

- **Days** are operation days: 120 s on the operation clock (§5.3), the length of `CityLoyaltyTuning.daySec`.
- **Transit** is fixed. It is not real flight time (§2).
- **Mustering** debits troopers and kit immediately, so the decision costs something. A save taken before launch
  does undo it; what a reload cannot do is reroll the same launch (§6.5).
- **Landing** is abstract in phases 1–2 and always succeeds. From phase 3 a real force lander flies on airless
  bodies (§9.3).
- **Engaged** is fought objective by objective (§6), abstractly unless the player has joined one objective live
  (§8).

### 5.3 Where it steps

**One owner, one clock.** The whole operation, abstract objectives and the live bubble alike, steps in one
world-level `_combatPhase`. Colonies never step it.

- **Ownership.** Operations live in a world-level `OperationRegistry`. It and the `CommandInbox` are injected
  through `AdvanceSimulationTick`'s constructor, so every host gets them: `FlightSession` (which keeps the
  registry across `rebuildTick`, `flight_session.dart:141-161`), `SimHost` (`sim_host.dart:83-117`), and tests.
  The live bubble's state (unit table, flow-field cache, path queue, raster) lives on the `Operation`, never on
  the tick object, so a cheat toggle that rebuilds the tick loses nothing.
- **Where.** `_combatPhase` runs after the vessel loop and before the city loop, beside `handOutReputation`
  (`advance_simulation_tick.dart:389`). In order it:
  1. drains the `CommandInbox`;
  2. drains each colony's `ColonyCombatOutbox` of events it posted from its own last tick (below);
  3. steps every operation, abstract and live;
  4. runs war weariness;
  5. posts writes into each colony's `ColonyCombatInbox`.
- **The operation clock.** It counts `opDt = min(tickDt, 0.5)` in integer µs, where `tickDt` is the dt the city
  loop receives. That is the colony clamp (`city_sim.dart:1352`) without `eventSimWarp`. A time-dilation event
  in the target therefore does not speed up or slow down the battle, and frame holding cannot reorder it.
  Every timer in §5.4, §6 and §7 counts **operation days** of 120 s on this clock. A live bubble forces warp to
  1×, so `opDt` is the 0.02 s fixed step and the live and abstract objectives share it.
- **What it reads from colonies.**
  - At launch only: a `LaunchSnapshot` of the target (§4.2) and each source's ready troopers and kit (§4.1),
    taken when `LaunchOperation` applies.
  - After launch: nothing but outbox events. A colony posts them from its own tick, in `_cityPhase`, when its
    allegiance or stage changes (seceded, standoff over, rejoined, occupied colony re-seceded), when a site an
    operation depends on is removed (`clearParcel`, a disaster), when a garrison's upkeep goes unpaid, and when
    a source ships a garrison supply run (§7.1). Events are rare and discrete, and §7.6 says what each one does.
  - This is the full list. Garrison upkeep is paid in the garrisoned colony's own tick from the garrison stock,
    because a garrison is colony state once the operation ends (§7.1, §7.2).
- **Writes into colonies** (attacker deaths at home, returning troopers, `siteFactor` changes, war weariness,
  defender and civilian dead) go into that colony's `ColonyCombatInbox`. It is drained at the start of
  `_cityPhase` (`:511-525`), before `city.advance`, so the E8 ledger receives deaths before `agents.advance` takes
  them. A frame-held colony drains its inbox when its held tick replays, in order.
- **The documented lag.** A held colony's outbox events reach the operation up to `maxHeldCityS` (15 colony
  seconds) later than they would inline. Only discrete exits ride on them (§7.6), and every exit's kind is the
  same either way. The frame-hold test pins exactly that: the same ledgers and band on a fixture with no
  lifecycle event, and the same exit kind on one with an event. "Hold lag ≤ `maxHeldCityS`" is added to the
  Agent Traffic contract as a published semantic (§18).
- **Hosts that call `CitySim.advance` directly** (the dev hook's `_step`, `CityBuilderScreen`, and
  `advanceCity` with no clock) step no operation, because nothing in `CitySim.advance` does. Their colony
  inboxes still drain at the next `_cityPhase`. The dev hook gets its own `ext.acro.combat?step=` that runs
  world ticks (§14).

### 5.4 How it ends (the same rules, abstract or live)

All times here are on the operation clock (§5.3).

- **Won:** the attacker holds every goal objective at control ≥ 0.9 for 60 s, or the defender surrenders.
  Surrender happens when side morale falls below 0.15.
- **Rejoined:** the colony sends a petition mid-operation and the player accepts it. Today `acceptPetition` and
  `acceptNegotiation` are called straight from widget handlers (`city_reclaim_ui.dart:157`, `:161`). From phase 2
  they go through `AcceptPetitionCommand` and `AcceptNegotiationCommand` on the `CommandInbox`. `_combatPhase`
  forwards each into the colony's `ColonyCombatInbox`, so it applies in that colony's own tick order even when
  the colony is frame-held. The colony then posts `rejoined` to its outbox, and the operation ends with that
  exit, within the documented hold lag (§5.3). This needs the secession lane's sign-off (§18).
- **Lost:** every attacking formation is broken or dead, or supply has been at zero for 2 operation days.
- **Withdrawn:** the player orders it. Survivors return, and a fighting withdrawal costs 10% of what is left.
- **Ceasefire:** no decision after 10 operation days (20 minutes at 1×). Troops come home and nothing changes hands.
- **Overtaken:** the target's allegiance or stage changes under it (§7.6).

Outcome bands, in Total War: Warhammer II's wording:
- Decisive, Close or Pyrrhic victory. Pyrrhic means attacker losses ≥ 50%.
- Valiant, Close or Decisive defeat.

## 6. The battle model and auto-resolve

### 6.1 Formations

A formation is combat-owned, a plain value plus rules, with an integer handle from a persisted counter:

| Field | Meaning |
|---|---|
| `id`, `side`, `faction` | handle; attacker/defender; §4.4 |
| `kind` | `infantry`, `regular`, `militia`, `emplacement`; later `armour`, `gunship` (append-only, saved by name) |
| `count`, `wounded` | members alive and fit; members wounded |
| `quality` | 1.0 trained, 0.5 armed militia, 0.3 improvised |
| `morale` | 0..1. Start: trooper 0.8, regular 0.7, militia 0.45 + 0.35·r, port holders 0.4 |
| `supplyDays` | ammo and rations carried |
| `at` | objective id, `transit`, `lz` or `reserve` |
| `homeColonyId`, `homeSiteId` | where the members live, and where their deaths are charged |

Strength: `S_f = count × P × quality × M(morale) × Sup × Env`
- `P`: infantry, regular and militia 1.0; emplacement 3.0 (static, defence only); armour 6.0; gunship 8.0.
- `M(m) = 0.25 + 0.75 m`.
- `Sup` is 1 with ammo and 0.35 without. Running out of rations drains morale instead.
- `Env`: armour ×0.7 above roughness 0.6 (`TerrainControl.roughnessAt`).

### 6.2 Objectives

A combat-owned `ObjectiveGraph` is built at plan time from colony state:

| Objective | From | Notes |
|---|---|---|
| Port | `landingPads()` parcels, **excluding airfields** | the phase 1 goal. `landingPads()` yields every `SiteKind.pad` (`city_sim.dart:5505-5509`), and the Airfield is one (300 × 3,200 m, `city_building_spec.dart:464-469`), so the graph filters by type |
| Airfield | an Airfield site | its own objective from phase 7 (gunships), never the Port |
| Seat | the seat of government | no such building exists (Q8); until answered, the largest civic building near the centre |
| Life support | the `isLifeSupport` cluster | taking it pushes an independent colony below self-sufficiency, toward the dependency petition: a siege route to surrender |
| Power | the largest generator | |
| LZ | the attacker's landing zone | losing it cuts the attacker's supply |

Each objective also carries:
- `value`;
- fortification `F ∈ [1, 2.2]`: +0.25 per emplacement, +0.3 for a bunker, +0.2 on rough ground, +0.3 if a
  building stands on it;
- width `W = min(24, 6 + 4·sqrt(footprint m² / 10,000))` in power units (a 1 ha port is about 10). Uncapped, an
  Airfield would be about 45 and a Military Base (1,600 × 1,600 m, `city_building_spec.dart:452-456`) about 70;
- **clipping:** an objective larger than the battle square (§8.3) is clipped to the sub-area nearest the LZ that
  fits, and its footprint for `W` is the clipped area;
- control `c ∈ [−1, 1]` (defender −1, attacker +1).

March times between nodes come from straight-line distance and `GroundVehicleMovement.speedOnTerrain`
(`ground_vehicle.dart:47`), with a combat-owned Dijkstra on at most 8 nodes.

### 6.3 The resolver

The resolver works in fixed 1 s steps of operation time (§5.3), taken from an integer-µs accumulator so any
partition of dt runs the same steps (the `traffic_time.dart` pattern, copied):

```
for each objective o with both sides present, in id order:
  E_A = min(Σ S_f attackers at o, W_o)          // width cap: no zerg rush
  E_D = min(Σ S_f defenders at o, W_o)
  fuzz = 1 + 0.15·u,   u = rng(seed, o, floor(t / 30 s)) ∈ [−1, 1]
  lossPow_D = α · E_A · fuzz / F_o · dt         // unit: MEMBERS removed (killed or wounded)
  lossPow_A = α · E_D · (2 − fuzz) · dt         α = 1/185 per s
  share each side's loss across its engaged formations in proportion to S; per formation:
    fractional casualties accumulate; whole members are removed, remainder carried
    half of those removed are wounded, half dead
    morale −= 1.5 × (removed this step / members at engagement)
  control:  dc/dt = κ · (E_A/F_o − E_D) / max(E_A/F_o, E_D, ε)          κ = 1/120 per s
  collateral_o += γ_ROE · (0.1·E_small + 1.0·E_heavy) · dt              (§7.5)
every formation:
  morale +0.002/s out of contact, +0.0005/s while its side holds the objective, −0.0005/s with rations out
  below 0.35 pinned (holds, will not advance); below 0.2 broken (moves to reserve); rallies at 0.45
side morale = strength-weighted mean; defender below 0.15 surrenders (captured, returned alive)
```

- **Calibration, computed by stepping these rules at 1 s.** Take two equal 16-strong trooper formations: quality 1,
  morale 0.8, F = 1, fuzz 1, the port's W = 10 with the cap applied. Each side removes 40% in about 182 s
  (1.5 operation days, 3 minutes at 1×). Morale reaches 0.2, broken, at that same 40%, so a fair fight ends by
  breaking there. The earlier draft's α = 1/450 gave about 443 s, not 3 minutes. Read as strength rather than
  members it gave about 264 s, which is why the unit is now stated. A full control swing at total dominance
  takes 240 s (κ, unchanged).
  - Sized from this: the 60 s hold is a third of a fair fight; the 10-day ceasefire is about 6 fair fights;
    reinforcement waves (45 s, §10.2) arrive about a quarter of the way through one.
- **Tuning.** Every constant lives in a const `ResolverTuning`. A calibration table test pins outcome bands for
  "squads × town size × resolve", and its first row pins the 182 s figure above.
- **Randomness.** The fuzz is the only randomness, and it is stateless. It is a pure function of
  `(seed, objective, round)` through `lib/domain/combat/combat_rng.dart`, a copy of traffic's xoshiro128\*\* and
  FNV-1a pinned bit-equal by a test, following the `hash32.dart` precedent.
  - The seed is `fnv1a32(targetColonyId, opId)`. `opId` comes from the saved `nextOperationId` counter, so the
    tick the player launches on does not change it. Saving, launching, reloading and relaunching a tick later
    gives the same seed. (The earlier `launchTick` term let that reroll it.)
  - The round index counts from the operation's own clock, so the launch tick does not shift it either.
  - Never `math.Random`. Never `damageBuildings`, `flattenOne` or the fire spread.

### 6.4 Abstract AI

- **Defender:**
  - every 30 s of operation time, allocates formations to objectives by `value × threat`, where threat is attacker
    strength within one march hop;
  - keeps one formation in reserve;
  - counterattacks when local `E_D > 1.5·E_A/F`;
  - feeds contested objectives in waves from the militia pool sized at launch (§4.2).
- **Attacker formations without orders** advance along the graph to the nearest goal objective. They stop and
  hold when `E_A/F < 0.8·E_D` and wait for the reserve.
- **Player orders override** both (§10.1).

### 6.5 Preview

- When the planner opens, it runs the same resolver headless from now to resolution, for 32 seeds, **at the real
  1 s step**. An earlier draft used 5 s steps on the grounds that the resolver is linear inside a round. It is
  not: the width cap, whole-member removal, per-step morale and the 0.35 / 0.2 / 0.15 thresholds all depend on
  step size, worst near surrender.
- Budget: a 10-day ceiling is 1,200 steps × a few objectives × 32 seeds. It runs as counted steps spread over
  frames (≤ 2 ms a frame, done within about a second), and the histogram fills in as seeds finish. It is
  measured in phase 1, with a fallback to 16 seeds. It never touches sim state.
- It shows:
  - the distribution of outcome bands;
  - the likely duration;
  - p10–p90 ranges for own, rebel and civilian casualties.
- It never shows exact numbers, which would turn the decision into paperwork (Warhammer II patch 1.12).
- The real operation uses its fixed seed (§6.3). Reloading cannot reroll the same launch, whether the save was
  taken before or after it. A different force, ROE or LZ is a different decision and may do better; that is the
  point of the preview. This extends the anti-save-scum rule in `colony-secession.md:65-67`.

## 7. Outcomes and aftermath

### 7.1 Port retaken, and held

- **Release.** `CityLoyalty.releaseByForce()` clears `portSeized` and `impoundPending` as `_release()` does, but
  posts its own notice kind, `LoyaltyNoticeKind.portRetaken`: "Your troopers have retaken the spaceport." It does
  not reuse `_release()`'s `portReleased` text, "The rebels have given the spaceport back"
  (`city_loyalty.dart:637-643`), which would tell the player the wrong story. The phase 1 HUD test pins the text.
  Deliveries and migration reopen, and held craft are released, because they read `portClosedToPlayer`.
- **Port garrison (new; without it the win is undone next tick).**
  - The player picks how many troopers stay. The default is `max(2, 1% of population)`.
  - While they hold, the seizure rule at `city_loyalty.dart:621-629` is blocked.
  - Their upkeep is their share of their home building's inputs (§4.1), paid in the **target** colony's tick from
    a garrison stock carried in with them. Ordinary deliveries cannot top it up, because guns, ammo and rations
    are not deliverable (`city_sim.dart:6187-6198`). Instead a **garrison supply run** goes out every 3 days by
    default: `_combatPhase` posts a debit into a source colony's inbox, the source ships what it has and posts
    the amount to its outbox, and after the transit time the amount lands in the garrison stock through the
    target's inbox. Unpaid, 10% of the garrison a day goes home alive (§7.6).
  - Withdraw it and the old rule applies again.
- **No loyalty gain, and no desperation bump.** No attention stamp, and loyalty −0.05. An earlier draft also added
  desperation +0.1. That lowers the independence bar of a colony still in standoff by about 0.09
  (`city_loyalty.dart:401-402`), and the standoff branch re-tests secession every step (`:562-565`), so the win
  could itself make the colony secede. The bump is dropped. The secession plan's "a seized port being retaken"
  pressure (`colony-secession.md:140-145`) is met by the loyalty cost instead.
- **Retaking the port does not end the standoff. Only governance does.** The code says what follows a win:
  - **An exodus.** With the port open in standoff, `standoffEmigration` holds and the population heads down to
    what the colony's own life support feeds (§2). Settlers leave at 1 + 1.5·(1−h) + 2·shortfall a second. Seizing
    the port had stopped this, because it shut migration both ways. Retaking it restarts it.
  - **Desperation keeps climbing** at (1 − happiness)/15 a day. Only attending the colony offsets it, by
    content/10 a day (`:537-550`). Meanwhile the exodus raises self-sufficiency as the population falls. A standoff the player does not govern still
    ends in secession; the garrison only delays it.
  - The planner states both before launch ("Retaking the port reopens it: settlers who cannot be fed will leave.
    Only governing the colony ends the standoff.").
  - Whether a held garrison should also suppress standoff emigration is Q7. The default leaves it running,
    because that is how a standoff with an open port resolves today.
- **A memory of it.** A `forceUsed` record on `CityLoyalty` raises the Grievance if the colony later secedes.
- **Pinned in phase 1:** a win on a standoff colony at the worst allowed desperation does not secede it on the next
  step.

### 7.2 Colony taken: occupation (phase 2)

- **The win: `CityReclaimSim.occupy(garrison)`, a transition modelled on `_rejoin`** (`city_reclaim.dart:699-727`).
  Setting `allegiance = occupied` alone fails twice over (§2): the stage stays `seceded`, and kept revolts secede the
  colony again on the next tick. `occupy()`:
  - sets `allegiance = occupied` and `level = 0.2`, and sets `stage` from the landing band as `_rejoin` does (0.2 is
    below the Defiant line, so Defiant);
  - clears `revolts`, `independentAtS`, `independenceCauses` and `governorLog`;
  - clears the petition, `pressure` and `dependentS`;
  - **keeps the Grievance**, with `warDead` added, because it is what the colony states if it breaks away again;
  - drops any rejoining terms (`terms`, `termsUntilS`). Terms are a negotiated settlement, and occupation is not one;
  - calls `attend()`. Taking the colony is an act of governance, so the neglect clock restarts;
  - posts `LoyaltyNoticeKind.occupied`: "Your troopers hold the colony. It takes your orders under guard."
  The player picks the garrison from the surviving formations.
- **An occupied branch in `_stageStep`** (secession lane, §18). Occupied colonies take the colonial rules, with two
  changes while a garrison holds:
  - the secession test (`level <= 0 || revolts >= 3`, then `selfSufficient`) is replaced by "the garrison is
    expelled" (§7.6). An occupied colony cannot simply declare independence past troops in its streets;
  - `selfGoverning` is false whatever the stage, so the colony stops auto-voting laws and running the tax revolt.
  The HUD reads "Occupied", never `stage.label` (§14).
- **Suppression.** `s = min(0.8, garrisonStrength / (0.05 × population))`.
  - Rebellion growth in `socialTick` is multiplied by (1 − s).
  - Misrule drift is multiplied by (1 − s).
  - **Neglect erosion is not suppressed.** That is the binding term (§2). After `attend()`, the grace period is 10
    days. Past it, the player must govern the colony like any other to hold it. Occupation is ruling, not a
    timer.
  - Mood takes a `−0.1·s` term, which is the cost of occupation.
- **Upkeep.** The garrison's share of its home building's inputs (§4.1), paid in the occupied colony's own tick:
  first from the garrison stock (resupplied by supply runs, as in §7.1), then requisitioned from the colony's own
  rations, guns and ammo, which costs mood. Unpaid, 10% of the garrison a day goes home alive (§7.6).
- **The climb back, computed.** Recovery is `recoverRate × content` while attended: 0.2/600 per s × content
  (`city_loyalty.dart:203`, `:530`). At s = 0.8, mood takes −0.08. A colony at mood 0.2 and full coverage
  sits at content 0.12, so climbing from 0.2 to 0.6 takes about 10,000 s, **about 83 days**, before any hold
  starts. At content 0.5 it takes about 2,400 s (20 days). Restoring a charter is therefore a long campaign of
  good government. That is the intent, and Q15 asks whether it is too slow.
- **Back to colonial.** Once loyalty has stayed ≥ 0.6 for 10 days with the garrison present, a notice offers
  "Restore charter". That player act sets the colony colonial and brings the garrison home.
  - **This departs from `colony-secession.md:269`**, where the return to colonial is automatic after M days. It is
    listed in §18 for the secession lane's sign-off, and in Q15.
- **Early withdrawal.** Loyalty −0.2, and the garrison comes home. The colony then takes the plain colonial rules.
  It secedes if it can feed itself, or enters standoff and seizes the port if it cannot. The new Grievance
  records `warDead`.
- **Control and reputation.**
  - The gate allows control (pinned). Governing it earns attention normally.
  - Whether occupation should restrict what the player may order is Q15.
  - Reputation keeps excluding occupied colonies (pinned at `city_reclaim_test.dart:244-250`).

### 7.3 Defeat

- **Port operation lost.** The port stays seized; loyalty −0.1; desperation +0.05.
- **Independent operation lost.** The target's resolve rises by 0.2 for 10 days.
- **Either way,** survivors return home, and war weariness does the rest.

### 7.4 Casualties, materiel, war weariness

- **Attacker dead:** charged to the home colony through the inbox and a `recordWarDead(n)` helper that writes the
  way `city_sim.dart:1804-1810` does: the E8 ledger when citizens own the population, otherwise the scalar.
- **Defender and civilian dead:** charged to the target the same way, plus corpses, because they die in town. The
  disease cascade that follows is real, and its tuning is watched (§17).
- **Surrendered defenders** come back as living population.
- **Materiel:**
  - ammo and rations are spent from carried supply each day of fighting;
  - a dead trooper's gun is lost;
  - the winner takes half the loser's guns.
- **War weariness** is step 4 of `_combatPhase` (§5.3):
  - every colonial colony loses 0.01 loyalty per 10 of the player's dead in the last 10 days;
  - each source colony also loses 0.02 mood per 10% of its deployed troopers killed, decaying over 5 days.
  - Both windows outlive any one operation, so they live in a world-level `WarLedger` (dead by operation day, and
    each source colony's mood debt), saved in codec v3 (§13), not on the operation record.
  - Force therefore lowers the reputation that wins hearts back.
- **Grievance** gains an additive `warDead` term, which raises severity.

### 7.5 Damage to the colony

- **The primitive.** `city_war.dart` (a CitySim extension in its own file) adds `warDamageSite(siteId, severity)`.
  It is seeded and deterministic, and picks sites weighted by distance to the contested objective. Severity bands:
  - below 0.5: cosmetic smoke (phase 3+);
  - 0.5 to 1.0: the site is non-operational (its `siteFactor` damage term is 0, §4.1) until repaired with ore
    from its site sheet;
  - 1.0: destroyed (phase 6+, Standard or Heavy ROE only), through `clearParcel`-level cleanup, which handles
    deliveries, craft, the lander pad, agents and site access.
- **Never the cell-grid helpers** or fire spread.
- **Rejoining terms.** While terms ban demolition (`city_term_guard.dart`), the planner refuses Standard and
  Heavy ROE and says why. Restrained never destroys.
- **Never targeted:** life-support sites under Restrained and Standard, and terraforming towers always. Destroying
  shared air is an act against every colony on the body (Q17).
- **Craters:** none until phase 6. Then they are quantised (each new one swallows the last at that site, the drill
  rule), capped at 16 per battle, and saved with the operation.

### 7.6 Lifecycle: garrisons and deployed formations

Every allegiance or stage change of the target or a source, and every loss of a home building, has a defined
exit. The colony posts the event from its own tick (§5.3, outbox); the operation or the garrison acts on it.
Nobody is ever silently lost.

| Event | Deployed formations (operation running) | Port garrison | Occupation garrison |
|---|---|---|---|
| Target's standoff ends by recovery (`_release` path, `city_loyalty.dart:574`) | operation ends **Overtaken: the rebels stood down**; all come home | its job is done; comes home; upkeep stops | n/a |
| Target secedes (standoff → independent) | operation ends **Overtaken: independence**; all come home alive, kit lost; the target becomes a phase 2 Force target | **expelled**: comes home alive, its carried stock is lost; the port closes as the independent colony's | n/a |
| Target rejoins (petition or negotiation accepted) | operation ends **Rejoined**; all come home | n/a | n/a |
| Occupied target meets the secession condition (level ≤ 0 or 3 revolts) | n/a | n/a | **expelled**: comes home alive; next tick the colony takes the plain colonial rules (secede or standoff) |
| Player withdraws the garrison | n/a | comes home; seizure rule applies again | early withdrawal (§7.2) |
| Garrison upkeep unpaid | n/a | 10% a day goes home alive | 10% a day goes home alive |
| Source colony secedes | its formations **desert**: removed from the operation as living people of the now-independent colony, kit lost; notice "Troopers from X have gone home to an independent colony" | the same, for garrison members from X | the same |
| Source colony enters standoff | no change to deployed troopers; no new musters or reinforcements from X | no change | no change |
| Source home site removed (`clearParcel` `city_sim.dart:5834`, demolition, disaster) | stay in the fight; `homeSiteId` cleared; they return as plain residents; the colony drops the site's `siteFactor` entry | the same | the same |
| Target site an objective stands on removed by a disaster | the objective keeps its graph node (the ground is still there), loses its building fortification (+0.3) | n/a | n/a |

- **Upkeep while deployed** stays "moved, not added" (§4.1): if the home site is gone, nothing moves back.
- **Captured** applies only to defenders who surrender (§6.3). The player's troopers are never captured in v1. A
  rout always reaches the LZ or dies trying.
- Each row is a phase 1 or phase 2 test, on the fixtures in §12.

## 8. The live layer: the engagement bubble

### 8.1 Joining and leaving

- **Joining is explicit.** `JoinBattleCommand(opId, objectiveId)` comes from the HUD chip, the operations drawer,
  or a prompt when the player's walker or craft is within 600 m of an engaged objective. Proximity alone never
  clamps warp.
- **On join:**
  - Warp is forced to 1× (the atmosphere precedent). Pause is still allowed.
  - The objective's abstract step is suspended.
  - The frozen battle map, taken at launch (§8.2), is loaded.
  - Up to `liveCap` members per side (default 24, set once per join and recorded in `JoinBattle`, §11.5) spawn
    as live units from the formations there.
  - The rest wait as reserve waves. When a live unit dies, a reserve member spawns at the edge, outnumbered side
    first (Mount & Blade's battle-size rule).
- **Leaving:** the battle menu's Leave, focusing elsewhere, or a save (§13) collapse the fight back into pools.
  - Live counts become formation counts, and units under 50 hp become wounded.
  - Control and morale carry over.
  - The collapse is deterministic.
- **One bubble at a time** in single-player.
- **Join waits for the ground, in the UI only.** The button is greyed "Preparing the battlefield" until the
  raster is baked (§8.3), and the landing copy says "Join opens when the battlefield is ready: it can lag the
  landing". The command does not depend on it: a recorded `JoinBattle` that applies before the bake is done
  finishes the bake synchronously in that tick (a stall, logged). Each cell is a pure function of the frozen
  field and the cell, so a replay that bakes on a different schedule fights on the same ground.
- **Reserves spawn from the operation's own pools,** which only `_combatPhase` moves (§5.3), so the abstract
  defender AI and a live spawn can never act on the same pool out of order.

### 8.2 The frozen battle map

At launch, a deterministic snapshot is taken of what the fight needs from the colony. It is part of the
`LaunchSnapshot` (§5.3), together with the terrain-edit set the raster will be baked against, so construction
during transit cannot change the battlefield.
- building hulls, as `BuildingMassing.massFor` mass boxes;
- pads and objective sites;
- spawn and rally points (site access `entrancePt`, read-only);
- road and pavement lift. Today +0.12 m (`ribbonLiftM`, `road_mesher.dart:195`) and +0.27 m (pavement,
  `road_overlay_state.dart:57`) are renderer constants, which a domain map cannot import, and
  `CityLayout.roadIndex` does not supply them. Contract request R1 (§18) moves them into the domain under Road
  Placement's ownership, with a pin test that the renderer still reads the same numbers;
- **elevated and sunk roads.** Decks can stand 60 m up on piers or bridges and sink 36 m into tunnels
  (`road_elevation.dart:40`, `:43`, `:55`; `RoadStretch.structure` and `tunnel`, `:92-101`). One radius per cell
  cannot hold a deck and the ground under it. v1's rule: a deck more than `structureClearM` (2.5 m) above
  ground is a blocked prism for navigation, LOS and hits, and is not walkable; tunnels and cuttings are left out,
  their portals blocked. The LZ and objective placement avoid squares where such roads would be on the main
  axis. A structure layer is phase 6 work, if wanted;
- props (`ScatterColliders`), built with **the same `ScatterMask` inputs the renderer uses** (the frame's roads
  and sites, `scatter_nodes.dart:113-130`; `scatter_placement.dart:144`), so no solid collider sits in a street
  where nothing is drawn. `ScatterColliders` has no runtime consumer today; only
  `test/scatter/scatter_collision_test.dart` imports it.

During the fight the bubble never reads live CitySim state. Damage done in the bubble edits the battle's own copy,
and the colony hears about it through the inbox.

### 8.3 Battle ground

- **Cost is the unknown.** Spike S (§16) measures it before phase 4 is approved. At the 0.69 ms a sample measured
  in commit 7d325cf, 22,500 cells under brushes is about 15.5 s of CPU, so the bake can never happen at join
  time. A battle at a graded port is under brushes almost everywhere, so plan on that worst case.
- **The raster.** An 8 m height raster over the battle square: default 1.2 km a side (22,500 cells), at most 2 km.
  Each cell holds the body-fixed radius along its own radial.
- **What fills each cell:**
  - under no brush's bounding box: `baseGroundRadiusAt` (one fBm);
  - under brushes: `surfaceRadiusAt` (bracketed bisection);
  - never the outermost march `groundRadiusAt`.
  - Each cell is a pure function of field and cell, so fill order changes cost, not results.
- **When it bakes.** From launch through transit: at least 0.75 operation days, about 90 s at 1×. The LZ and the
  objectives go first. The bake is render-side work (it fills a cache, it changes no sim state), so frame time
  may schedule it.
  - **The main-thread budget cannot finish it.** At ≤ 1 ms a frame and 60 fps, 90 s buys about 5.4 s of CPU,
    about a third of the 15.5 s worst case. The rest would take about 3 more minutes at 60 fps.
  - **So a worker-pool point-sample API is an explicit phase 4a deliverable**, estimated at about a week. The
    pools that exist (`mesh_scheduler_isolate.dart`, `scatter_scheduler_isolate.dart`,
    `city_tile_scheduler_isolate.dart`) are meshers with no point-sample request. The new pool is persistent and
    holds the field once, by the project's rule: never `Isolate.run` with a DEM field.
  - **The web build** has no isolates. It gets the counted main-thread budget and a 600 m square (5,600 cells,
    about 3.9 s worst case), which fits transit.
  - Under heavy warp the bake falls behind operation time, and the Join button waits.
- **Size of the square.** Default 1.2 km; it shrinks to 800 m (10,000 cells) if Spike S's pool cannot bake 1.2 km
  in 90 s.
- **Saved.** Once baked, the raster is saved quantised (u16, about 45 KB) with the operation. A reload then fights
  on exactly the ground it was baked on and skips the re-bake. The codec saves no terrain edits, so this matters.
- **No precision tile.** An earlier draft filled a 2 m tile around the player at up to 64 samples a tick. At
  0.5–0.7 ms a sample that is 32–44 ms in a 20 ms tick, before the 25-step catch-up loop
  (`simulation_view.dart:1976-1992`) multiplies it: 2–3 orders of magnitude over the ≤ 0.1 ms movement budget.
  Kerbs and grading steps come analytically instead, from the frozen map's road lift (R1) and the pad datums,
  added to the bilinear raster height. No field sample is taken during a fight.
- **Invalidation is local:** only the cells under a new brush's box (phase 6 craters), never the whole raster.
  Those cells re-bake on the pool, and a crater's own shape is added analytically until they land.
- **Drawn vs simulated.** The drawn terrain mesh differs from the field, and the rover precedent collides with the
  drawn mesh (`TerrainNodes.drawnGroundRadiusAt`) because wheels on the analytic field float or sink by the mesh
  error. Spike S item 3 sizes that error at the reference colony. The player's eye is reconciled in the
  renderer: the camera adds a smoothed offset of (drawn − raster) at the avatar, read from the drawn mesh,
  which is a render-side query. The sim keeps the raster. The same cosmetic offset is applied to the nearest 8
  units. If the error is over the Spike S pass line, phase 4a stops for a decision. Baking from the drawn mesh
  instead would make sim state depend on the renderer, which rule 3 forbids.

### 8.4 The unit table

The unit table follows Warfront: one table for player and AI.

- **Rows.** Structure-of-arrays with generational handles (`gen<<20|slot`, the `slot_pool.dart` pattern, copied).
  One row is one formation member.
- **Columns:**
  - kind, faction, formation, squad;
  - **controller**: 0 = AI, otherwise a player index;
  - pose in body-fixed doubles, previous and current;
  - heading as a unit vector, velocity, vertical velocity, grounded, stance;
  - hp, armour class, weapon, magazine, cooldown, reload, suppression;
  - target, next-scan tick, flags.
- **The player is a row,** drawn from an attacker formation. Possessing another unit is a controller swap
  (phase 5). Vehicles are rows with seats (phase 6).
- **Kinds** (append-only): trooper, militia, regular, emplacement. Later: buggy, APC, hover tank, lander proxy.

### 8.5 Weapons and hits

- **AI small-arms fire is aimed fire resolved at 10 Hz,** staggered by `handle mod 5`, when the target is in range,
  in line of sight and off cooldown:
  - `pHit = accuracy × rangeFalloff × coverMul × (1 − 0.6·suppression) × (moving ? 0.6 : 1)`;
  - the roll is `rng(seed, step, handle)`, so evaluation order cannot change it;
  - each shot publishes a `ShotRecord` (origin, target point, weapon, hit) for tracers.
- **The player's shots are hitscan rays** at the tick, along the aim in the `AvatarInputCommand`. They test against
  unit capsules (r 0.35 m, h 1.8 m standing), hull prisms and the raster. The aim converts the camera's forward
  vector into the body-fixed frame, the same way the hand drill aims (`simulation_view.dart:1010-1040`). The player
  really aims; AI fire is a fair roll.
- **Slow rounds** (thrown charges in phase 4; rockets and cannon in phase 6) are ballistic projectile rows under the
  local μ/r², swept per tick. Low-gravity arcs come for free.
- **Weapons** (a const table, not saved):

  | Weapon | Damage | Range | Notes |
  |---|---|---|---|
  | rifle | 25 | 600 m | 30-round magazine, 2.5 s reload |
  | improvised | 18 | 300 m | |
  | emplacement HMG | 30 | 800 m | heavy suppression |
  | charge | | | 3 s fuse, 6 m lethal, 12 m suppress |

- **Damage** is `damage × armour factor`. There are no hit locations.
- **Suit breach.** Where `SurfaceConditions.vacuumHostile` holds, a hit that takes an infantry unit below 40 hp
  starts a 60 s oxygen bleed. Holding E for 3 s patches it. A terraformed sky that clears `vacuumHostile` has no
  breach, which ties combat to terraforming.
- **Fall damage:** 10 hp per m/s above 4 m/s, using the walker's landing speed (`first_person_walker.dart:122-124`,
  thrown away today) and the EVA pack's `hardContact`.
- **Order of each pass:** gather intents in handle order, resolve hits, apply damage, remove the dead (two-phase).

### 8.6 Morale, suppression and endings

- **Morale** loses the same β as the resolver: −1.5 × casualties / squad size.
- **Suppression.** A near miss within 2 m adds 0.08, which decays at 0.25/s after 1.5 s quiet. Above 0.6 the unit
  goes prone and moves and aims at half rate.
- **States:** pinned below 0.35, routs to the rally point below 0.2, and surrenders at 0 with no path to rally.
  Routs and surrenders are the usual way a fight ends. It is a colony sim.
- **The player's presence** gives squads within 150 m a morale floor of +0.15. This is the bounded presence
  multiplier.
- **Control** comes from presence within the capture radius, using the resolver's κ formula on live power.
- **Ending rules** are §5.4.

### 8.7 Navigation and line of sight (phase 4b)

- **Grid.** A 4 m passability grid (300² cells at 1.2 km), with slope taken from the 8 m raster.
  - Foot layer: slope ≤ 40°, hull footprints blocked, water below `seaRadius` blocked.
  - Wheeled layer (phase 6): slope ≤ 25°, gaps ≥ 6 m, roads at ×0.5 cost.
- **Cover** per cell: an 8-direction bitmask of adjacent hulls or props at least 1.2 m tall.
- **Paths.** Sector A\* over 32 × 32-cell sectors, then one flow field per (goal, layer) shared by the whole squad,
  the Planetary Annihilation / Supreme Commander 2 shape.
  - Fields are cached least-recently-used, at most 24.
  - A resumable queue runs at 3,000 counted expansions per tick. Priority: replans first, then player orders,
    then AI orders.
- **No frozen squads.**
  - Before its field is ready, a squad moves straight along the cost-weighted direction.
  - A squad that cannot path says why ("No path: blocked by buildings").
  - Units are never despawned when stuck, unlike traffic's 120 s rule.
- **Steering:** formation slots plus separation on a 4 m hash, with a soft push.
- **Line of sight:**
  - checked squad pair to squad pair, from leaders with a 2 m eye, cached 0.5 s with staggered refresh;
  - a march over raster heights and hull tops that includes curvature: the sight line drops by d²/2R, and a
    standing eye's horizon on the Moon is about 2.4 km;
  - at most 200 counted rays per tick;
  - the player's hitscan is outside the budget.

### 8.8 AI (phase 4b; 4a has only static defenders)

- **Squad state machine:** Idle, Moving, Engaging, Holding, Capturing, Pinned, Routing, Rallying, Surrendered.
- **Side commander** at 1 Hz, using the allocation rules of §6.4.
- **Unit brain:**
  - scans for targets every 0.4 s, staggered by handle;
  - reaction delay 0.3 s for troopers and 0.6–0.8 s for militia, a seeded draw;
  - seeks a cover cell within 12 m when suppressed.
- **Determinism:** the AI reads only the previous tick's state, iterates sorted handles, and breaks ties by handle.

### 8.9 Calibration: the anti-Total-War rule

- **The harness.** `bin/combat_calibrate.dart` runs live fights with no player and no renderer, AI against AI, on
  3 reference scenarios built by `CombatFixtures` (§12). It compares them with the abstract resolver on the same
  inputs and tunes α and the fortification posture.
  - **A reported metric first, a gate later.** In phase 4b it prints the gap in win rate and loss distribution
    and fails nothing. Agreeing live AI with a Lanchester-style resolver is an open tuning loop, and gating on
    it early could block a phase indefinitely. Phase 4c turns it into a gate at ±10%, once 4b's AI is stable.
  - **There is no test CI.** The only workflow is `.github/workflows/release.yml`, which builds and deploys on
    `v*` tags. "Gate" here means a named local command that must pass before a phase is approved:
    `fvm flutter test test/combat` plus `fvm dart run bin/combat_calibrate.dart --gate`. Bench rows use
    `--dart-define=ACRO_BENCH=true` (`test/traffic/bench/bench_support.dart`). A test workflow pinned to
    `.fvmrc` the way `release.yml` pins Flutter is optional, and is Q21.
- **Conservation test.** Join → leave → join keeps each side's power within rounding.
- **Tuning target.** Attending improves a competent player's expected outcome by about one band. It is never
  required, and auto-resolve stays fair.

### 8.10 Smooth rendering of a 50 Hz unit

- Units step at 50 Hz in the tick. The host loop exposes `tickAlpha = accumulator / fixedStep`, two lines at
  `simulation_view.dart:1976-1992`, and every unit is drawn at `lerp(prev, cur, tickAlpha)`.
- Look (yaw and pitch) is applied to the camera every frame and sampled into the next input command, so the view
  never judders.
- Movement lags by at most one tick (20 ms).
- Client prediction is kept for networking (§12).

## 9. Avatar seats

### 9.1 Soldier (phase 4a)

- **Movement moves into the domain.**
  - `stepFirstPersonWalk` and `stepEvaPack` move to `lib/domain/combat/locomotion/foot.dart`. The presenters
    re-export them, so their 15 unit tests (9 in `first_person_walker_test.dart`, 6 in `eva_pack_test.dart`) stay
    put.
  - The same function drives today's per-frame walking and the battle avatar, so the two cannot diverge, and the
    7 walk widget tests (`test/widgets/walk_mode_test.dart`) stay green.
  - Ground comes from the raster plus the analytic road and pad lifts (§8.3).
- **Collision (new).** Today's walker is a radial clamp with no lateral collision
  (`first_person_walker.dart:96-126`; the flight view samples only the terrain field, `simulation_view.dart:790-794`),
  so a soldier would walk through the walls that stop bullets and paths. `foot.dart` gains an optional
  `pushOut` step: a 0.35 m capsule slid against the frozen map's hull prisms and prop colliders, after the
  horizontal move and before the ground clamp. AI steering uses the same step.
  - It is a parameter that defaults to none, so today's free-roam walk is unchanged and its tests stay as they
    are. Only the battle avatar and AI pass the battle map.
  - Tests: no penetration into a hull after N steps at full run from any heading; slide along a wall; no tunnelling
    at 0.02 s steps; a doorway-width gap is passable.
- **Jump jets.** The EVA pack beats lunar gravity (3.2 m/s² against 1.62) and works as jump jets on the Moon and
  asteroids. It cannot lift a soldier on Mars or Earth, by design.
- **Input:** `AvatarInputCommand(tick, move, yaw, pitch, buttons: fire | aim | reload | use | jump | run | crouch)`.
- **Battle input context.** Walking is forced on, and these are switched off:
  - the pace wheel (×0.01–×100,000, a speed cheat);
  - M (manual flight), G (exit walk) and the drill.
  - Esc opens the battle menu (§14).

| Input | Action |
|---|---|
| LMB | fire. Caught on the outer `Listener` (`simulation_view.dart:3066-3125`), because the captured-cursor `MouseRegion` (`:3477-3480`) swallows clicks |
| RMB | aim (FOV 75° → 45°) |
| R | reload |
| E | use, patch suit, board (phase 6) |
| Space / C | jump or jets / crouch or descend |
| Shift | run |
| F | lamp |
| 1–5 | orders (§10.2) |
| X | call reinforcements |
| Tab | battle status; command view from phase 5 |

Every new key goes into `_simKeys` (`simulation_view.dart:1217`), or macOS beeps.

- **Two fixes come first** (both found by reading the code, not by running it):
  - **Orbiting moves the avatar.** The freecam look holds the eye and moves `_freecamRelLocal`, which on foot is the
    head (`simulation_view.dart:2415-2424`). With the 3.5 m third-person boom, a half turn moves the avatar about
    7 m.
  - **Walking from a body lock** can start at the north pole. Deploy at the battle's spawn point, never from the
    camera eye.
- **Platforms.** Mouse capture is Windows-only (`pointer_lock.dart`).
  - macOS and Linux: hold-RMB look, wheel aim, LMB fire.
  - Web and touch: no live fighting in v1. They keep the operation, orders and auto-resolve (Q12).

### 9.2 Driver (phase 6)

- **One controller first.** Extract the shared ground-vehicle controller from its two studio copies, so no third
  copy appears.
- **Locomotion.** `stepRover` moves to `locomotion/wheeled.dart`, in the battle's tangent frame, using raster
  heights plus road lift, one sample per wheel per tick.
- **Vehicles:**
  - combat buggy;
  - APC, which carries a squad;
  - a tracked pivot-turn mode, because the bicycle model cannot pivot;
  - a hover tank, from the EVA integrator plus ride springs.
- **Seats.** Driver and gunner (the rover model already draws two seats). E boards within 3 m, generalising the
  studios' G/R hand-off. A destroyed vehicle ejects its crew where it stands, the Battlezone loop.

### 9.3 Pilot (phase 3 landers, phase 7 flying)

- **Force landers (phase 3)** are real Vessels from a `ForceRunFactory` cloned from `ColonyShuttleFactory`:
  - The owner is the faction id.
  - A lander spawns 16 km above the LZ and is flown in by `LandingGuidance`.
  - **The LZ is at least 400 m from every closed pad**, to stay clear of the 60 m impound seam.
  - Lander ids are `force-<opId>-<n>`, from the operation's saved counter, never `_shuttleSeq`.
  - Outcomes are honest: a crash or `unrecoverable` loses the troops aboard, in both abstract and live modes.
  - Airless bodies come first. Landing stays abstract on bodies with air until the aero fix (§17).
- **Flying it yourself (phase 7):**
  - `PilotInputCommand` per tick replaces the per-frame `_pilot.apply` (`simulation_view.dart:1877`).
  - The player can fly the lander in, with an auto-land assist through `landingTarget`. Touchdown turns the pilot
    into a trooper.
  - Gunship passes from an Airfield, and missile strikes from a silo colony (missiles finally get a use), are
    call-in powers.
  - A landed lander is a *lander proxy* row: a respawn point the enemy can destroy, like Battlezone's recycler.
- **Combat damage is separate from `FlightCheats`.** Destruction cheats default on (`flight_session.dart:44-46`).
  If combat rode them, units would be unkillable or the cheats would mean two things.

### 9.4 Death and redeploy

1. A 3 s death camera on the third-person boom.
2. A **REDEPLOY (n troopers left)** modal, following the VESSEL LOST precedent
   (`simulation_view_debug_panel.dart:22-78`).
3. After 10 s, the player respawns at the LZ or a lander proxy as the next member of an attacking formation. That
   costs a colonist.

With no reserve left, the player can command (phase 5), watch, or leave and let it auto-resolve. Permadeath is the
alternative (Q11).

## 10. Command

### 10.1 Operational orders (phase 3, no units on screen)

- **Command:** `OperationOrderCommand(opId, verb, formationIds, target)`.
- **Verbs:**
  - assign a formation to an objective;
  - hold;
  - assault;
  - withdraw (the whole operation);
  - set ROE;
  - call a strike (phase 7).
- **Where:** from the operations drawer, and by clicking objective markers under the **battle camera** (phase 3).
  They mean something with zero units drawn, because the pools are real. The withdraw verb ships in phase 1.
- **The battle camera (phase 3).** `_cityCamera` needs `widget.cityMode` and works on `_editingCity`
  (`simulation_view_colony.dart:178-206`), and the CITY BUILDER host opens SimulationView on one injected colony
  (`city_game_screen.dart:91-97`). The target is a different colony. Phase 3 adds a read-only `_battleCamera`
  that parks the freecam turntable over any colony's anchor, in city mode or flight mode, with no edit tools. Its
  only picks are objective markers. Phase 5 grows it into the command camera.

### 10.2 From first person (phase 4b, Battlezone style)

Number keys work with the mouse captured, because the menu is painted, not clicked.
- `1`–`3` select a squad; `4` selects all.
- The second press is the verb:
  - `1` follow me;
  - `2` hold there (the camera-forward ray against the raster);
  - `3` take objective (the one under the crosshair, else the nearest);
  - `4` fall back to the LZ;
  - `5` hold fire.
- `X` calls a reinforcement wave from the reserve. It lands at the LZ after 45 s (a real lander on airless
  bodies), with a 90 s cooldown.
- Each order is a `SquadOrderCommand(squadHandle, verb, targetBF | objectiveId)`.

### 10.3 Command view (phase 5)

- **Camera.** Phase 3's `_battleCamera` (§10.1) grown into a `_commandCamera` over the battle anchor. It pans on
  the battle raster instead of sampling the field every frame.
- **Posture.** A **Command** tool on the edit strip with `acts: false`, plus a documented exemption in the gate
  sweep test. The gate refuses acting tools on independent colonies, which are the ones being fought over.
- **Input:**
  - LMB click selects a squad: markers projected with `projectPx` and ranked like `CraftEditorPick` (22 px grab).
    Shift adds; a double click selects every squad of that kind.
  - LMB drag past 6 px is a **marquee**, only inside the command posture, so the city builder's left-drag orbit
    and its tests stay as they are.
  - RMB is the context order: enemy → attack, objective or site → capture, ground → move. Shift queues up to 4
    waypoints.
  - H holds, B falls back, Backspace stops, X calls reinforcements.
  - Ctrl+1–9 assigns a control group, a scoped exception to the Ctrl-to-platform rule
    (`simulation_view.dart:1263-1269`); 1–9 recalls it.
  - Space pauses (warp 0 already skips the tick but keeps input and rendering). Tab goes back to first person.
  - A **command card** mirrors every key, so touch and web get a usable reduced scheme.
- **Feedback:**
  - a dedicated `CombatOverlayState`, never `RoadOverlayState`;
  - resident instanced ring batches (adding and removing nodes per frame dirties the engine's BVH);
  - constant-pixel squad icons, because a 1.8 m soldier is about 0.7 px at the 1,800 m opening range;
  - a 2D minimap on the plat mapping (`CityPlatCamera`), never a second scene render.
- **Ground picks** ray-march the battle raster (about 40 samples plus bisection). The sphere pick at the
  colony-centre radius errs by about 70 m per 100 m of relief at the opening tilt.
- **Possession.** Enter or G on a selected friendly unit swaps the controller and runs the walk hand-off at that
  unit, with the walk-mode traps kept: read `_cityCamera` before flipping walk, and reset the gravity frame after
  a teleport. Tab or G returns to the turntable pose.

## 11. Rendering, effects and performance

### 11.1 Combat channel

- **`CombatFrame`** (`lib/application/snapshot/combat_frame.dart`): typed columns passed by reference,
  double-buffered and stamped with the tick. It copies the `CityTrafficFrame` pattern rather than importing it.
  - units: handle, kind, faction, flags, previous and current pose, heading, health bucket, pose code;
  - shots this tick, blasts, objectives (control, owner), and site damage.
- It rides `WorldSnapshot` as a transient field, and its digest goes into the fingerprint.
- **Not `_frameEvents`**, which is String-typed and capped at 64 per frame.
- **Operation news** (launched, landed, port retaken) uses ordinary domain events, each with an explicit
  `EventSnapshot` case. The `runtimeType` fallback at `world_snapshot.dart:2265` can be minified on web.

### 11.2 Units

- **`unit_pose_pass.dart`** is pure and testable. It applies `tickAlpha` and fills nearest-first rings at 300 and
  900 m, with icons beyond.
- **`unit_nodes.dart`:**
  - one opaque `InstancedMesh` per (kind × pose × team × shadow band), under a per-body root anchored body-fixed
    the way the city's nodes are;
  - slots grow in steps of 64, and only moved batches upload;
  - shadows are cast within 300 m only.
- **`unit_meshes.dart`:** rigid-part MeshBuilder soldiers in 4 poses (stand, run, prone, down), built like
  `vehicle_meshes.dart`. No skinning: a skinned mesh costs one draw per instance plus a per-frame joints upload.
- **Team colour** comes from separate material batches, so no engine patch is needed.
- **Cost:** pose plus pack is estimated at about 110 ns per unit per frame. It is not measured in this repo; Spike S
  item 4 confirms it.

### 11.3 Effects

- **`combat_fx_pool.dart`** keeps the `ImpactFxNodes` recipe (body-fixed anchor, crater-scaled debris and dust) and
  drops its per-event allocation and scene add/remove:
  - Emitters are pooled: mounted, then reset or paused.
  - Dedup uses a per-hit id, not `subject:tick`, which merges same-tick hits.
  - Every sprite uses `DepthSafeSpriteMaterial`. By reading the code, a plain sprite batch can inherit the
    lens-flare ghosts' "always" depth state and show through hills.
  - A render clock stops only at warp 0. Today's FX pause on any frame whose epoch did not move, which reads as
    slow motion on high-refresh displays.
  - The ground tint comes from a site material table (concrete, regolith) rather than `CpuAlbedo`, which is about
    78 km per texel on Earth.
- **Tracers:** one `velocityStretched` additive billboard batch, integrated on the render side from shot records.
  Estimated at 16 ns per tracer, not measured here; Spike S item 4 confirms it.
- **Muzzle flashes:** additive flipbooks held for at least 2 frames.
- **Caps:** 2,048 tracers, 16 concurrent blasts, 64 hit puffs.
- **The phase 3 visible battle, with no units:**
  - the resolver emits seeded cosmetic blasts at engaged objectives, at a rate proportional to `E_A + E_D`;
  - damaged sites smoke and burn;
  - objective rings and front arrows sit in the combat overlay.

### 11.4 Buildings, light, sound

- **Buildings:**
  - fire and smoke at once;
  - a destroyed site gets an instant rubble overlay (the `instant_road_nodes` pattern) and a dust burst to cover
    the seconds before its tile re-meshes;
  - its shadow lingers until then, which is accepted. No discard masks.
- **Light:** there are no point lights; the engine has one directional light. Glow sprites stand in.
- **Prewarm:** unit and FX pipelines are prewarmed when an operation enters transit.
- **Sound:** the project has no audio dependency (Q13).

### 11.5 Budgets

**The baseline is not measured yet.** The 8.0 / 12.0 / 13.6 ms figures (static, walking, driving) and the static
≤ 10 / sweep ≤ 13 ms gates are the **city studio's**, on its 127k-building reference colony
(`tool/measure_city_studio.ps1`). Battles run in the flight view (`SimulationView`), which has no governor and no
FrameTiming parity, and whose walker samples `groundRadiusAt` every frame (`simulation_view.dart:790-794`). The
rover work recorded that query at 16 ms a sample in a graded town (about 80 ms walk frames), and commit 7d325cf
later measured 0.69 ms in a settled starter town; which holds in the flight view at the reference colony is
unknown. Borrowed, the numbers do not even add
up: 12.0 ms walking + 2.5 ms live = 14.5 ms, over the 13 ms sweep gate and the governor's 14 ms shed line
(`city_studio_screen.dart:186-188`).

So Spike S item 5 measures the flight view itself (static, walking, orbit; city mode and flight mode) at the
reference colony. Then:
- **The battle gate** is the flight view's walking p75 with no battle, plus the live add, and must stay ≤ 16.7 ms
  p75 (60 fps) with the render shed ladder applied. It is not the studio's 13 ms sweep gate; a battle is allowed
  past it, by at most the live add below.
- **The live add** is re-derived from that headroom: `liveAdd = 16.7 − baselineWalkP75 − 1 ms margin`, capped at
  the table's 2.5 ms average. If the baseline leaves less than 1.5 ms, phase 4a starts with the flight-view
  walker moved onto the battle raster (no per-frame field query), which is in scope anyway.

| Item | Budget |
|---|---|
| Abstract resolver | ≤ 0.05 ms per operation per colony tick; ≤ 4 concurrent operations |
| Preview | ≤ 20 ms once, on planner open |
| Raster bake | worker pool during transit; on web, counted ≤ 1 ms per frame on a 600 m square; never at join unless a replayed `JoinBattle` forces it (§8.1) |
| Phase 3 FX | ≤ 0.4 ms, ≤ 8 translucent draws |
| Live sim, 48 units | per tick: movement ≤ 0.1, fire ≤ 0.15, LOS ≤ 0.25, paths ≤ 0.45, AI ≤ 0.1 ms |
| Live unit draws | ≤ 24 colour + ≤ 48 shadow draws ≈ 0.6 ms |
| Live FX | ≤ 0.5 ms, ≤ 6 translucent draws |
| Combat HUD | ≤ 0.3 ms |
| **Total live add** | **≤ 2.5 ms average, ≤ 4 ms worst, or less if the measured flight-view baseline requires it (above)** |

**Hard rules:**
- no per-unit field query;
- no ground sample in the renderer;
- no O(N) `siteAt` per unit.

**Accounting and shedding:**
- Combat ticks are charged to `SceneSync.tickCostMs`.
- The flight view gets FrameTiming parity with the studio (phase 3), and a **render-only** shed ladder: combat FX
  ×0.5, then unit shadows off, then far-ring units drawn as icons, then city shadow range ×0.6. Every rung
  changes only what is drawn.
- **`liveCap` is not on the ladder.** An earlier draft dropped it from 24 to 12 on frame time, which would move
  units to the reserve and change the fight by frame rate. `liveCap` is set once per join (a PerfKnob or the
  settings screen) and recorded in the `JoinBattle` command.
- PerfKnob rows: `liveCap` (read at join), `tracerCap`, `blastCap` (render); `losRays`, `navExpansions` (sim
  counts, fixed per build, never shed).
- Never measure while other agents run tests.

## 12. Determinism and multiplayer stance

- **Every input is a `SimCommand` from phase 1:**
  - phase 1: `LaunchOperation`, `OperationOrder`, `WithdrawGarrison`;
  - phase 2: `AcceptPetition`, `AcceptNegotiation` (today widget calls, §5.4);
  - phase 4: `JoinBattle` (carries `liveCap`), `LeaveBattle`, `AvatarInput`, `SquadOrder`, `CallReinforcements`;
  - phase 5: `Possess`;
  - phase 7: `PilotInput`.
- **What is not a command, and why that is safe.** Editor actions in a source or target colony (building,
  demolishing) stay widget mutations, as the whole city builder is today. The operation never reads them after
  launch: a removed home site reaches it only as an outbox event from the colony's own tick (§7.6).
- **A local command queue.** The live game bypasses `AuthoritativeSimulation`, so a `CommandInbox` is drained at
  the start of `_combatPhase` (§5.3). It is injected through `AdvanceSimulationTick`'s constructor, so
  `FlightSession`, `SimHost` and tests all have one. The UI enqueues and never mutates, the opposite of the drill
  today.
- **Exhaustive switches.** New cases touch `ApplyCommands`, `ClientSimulation._applyLocally`,
  `SimulationView._applyBridgeCommands`, `MultiplayerScreen._cmdName` and **`FlatBufferCodec._envelope`**
  (`flatbuffer_codec.dart:394-439`, a switch expression with no default, so phase 1 would not compile without
  it). Until phase 8 puts combat on the wire, every combat case in `_envelope` and `_applyBridgeCommands` throws
  `UnsupportedError('combat commands are local-only')`, with a test that a combat command never reaches the
  codec in the live path.
- **Every live colony read the operation makes:** at launch, the `LaunchSnapshot` (§4.2, §8.2) and each source's
  ready troopers and kit; per tick, only outbox events (§5.3). Nothing else. The hygiene test (below) enforces it
  by banning any `CitySim` import under `lib/domain/combat/resolver/**` and `live/**`; only `launch/` and the
  outbox adapter may read a colony.
- **The determinism fixture.** `CombatFixtures` (`test/combat/fixtures.dart`, shared with the calibration tool and
  the dev hook):
  - `portSeizedPair()`: a source colony of about 400 with an Arms Factory, a Rations Plant, a ready Barracks and
    stock; a target colony in standoff with `portSeized` (desperation > 0.4, `city_loyalty.dart:621-624`), on the
    same body;
  - `secededPair()`: the same with an independent target (phase 2);
  - both built by direct state assembly, not by play, with `hostility = 0` and no disaster, so CitySim's tick draws
    no `math.Random()` (§2). Barracks unlock at 300 (`city_building_spec.dart:448-451`), so reaching this by play
    is slow; the reachability test (§16) covers play separately.
- **The kit:**
  - `combat_rng.dart` (a pinned copy);
  - an integer-µs clock;
  - generational handles;
  - sorted iteration;
  - two-phase gather-then-resolve;
  - counted budgets, never timed ones;
  - an allocation-free steady state.
  - No trig under `lib/domain/combat/resolver/**`. Live locomotion may use trig, with the same-platform caveat
    documented.
- **`combat_source_hygiene_test.dart`** (template: the traffic hygiene test) bans `Random`, `hashCode`,
  `Object.hash`, `DateTime`, `Stopwatch`, map/set iteration, and any import from `traffic/`.
- **Fingerprint.** A `%` block appended only while operations exist (the atmosphere precedent). It is an FNV
  digest over quantised operation state and, while live, the unit columns.
- **Tests** (all on `CombatFixtures`, so colony state is part of what is compared; the existing
  `save_resume_determinism_test.dart` fingerprints vessels only):
  - twin-run;
  - save-resume, mid-operation, including a save on the exact tick a source-colony write is queued;
  - warp equivalence (25 × 0.02 s against 1 × 0.5 s);
  - frame-hold equivalence (held against inline colony), in phase 1 on abstract objectives and **again in phase
    4a on a joined operation, with the target colony held and a time-dilation event set on it directly**. The run
    ends before the event does, so no chained pick draws `math.Random()`. The event must not change the
    operation's ledgers;
  - the lifecycle rows of §7.6;
  - join/leave conservation;
  - the calibration harness;
  - an AOT smoke run, `tool/aot_combat_smoke.dart`. The pinned SDK miscompiles a nullable promoted through a bool
    local in loops, natively only, so JIT tests alone are not trusted.
- **Authority by faction.** `Player.ownedAssetIds` is fixed when the session is built and cannot own units spawned
  mid-battle. `Session.validate` gains a faction resolver.
- **Multiplayer, chosen now and built in phase 8:**
  - server-authoritative snapshots;
  - client prediction of the player's own unit with the same step functions;
  - interpolation of everyone else.
  - **No lockstep:** CitySim is unseeded, and floats are deterministic per platform only.
  - Wire work starts by regenerating the stale flatc bindings.
  - Single-player ships first, and every seat can be filled by AI (Q3).

## 13. Persistence

- **Codec v3** (`GameStateCodec` is v2 today) adds an `operations` block. It is additive and omitted at its
  defaults, so a v2 save loads with no operations.
- **Saved per operation:**
  - sides, sources, goal, ROE, seed, phase, clock;
  - the objective graph (re-derivable, but saved for stability);
  - formations;
  - casualty, collateral and materiel ledgers;
  - the `LaunchSnapshot` and the frozen battle map's inputs (§8.2);
  - the LZ and lander vessel ids;
  - garrisons;
  - counters (`nextOperationId`, `nextFormationId`, lander sequence);
  - the quantised raster, once baked.
- **No RNG state** to save, because the fuzz is stateless.
- **Mid-battle saves work at every phase**, because the operation is abstract state.
  - **A live fight is not saved** (Q10). Save during a live fight asks to leave the fight first. Leaving hands it to
    auto-resolve, then the save is taken. Total War and Mount & Blade do not save inside battles either.
  - The leave is a recorded `LeaveBattle` command, so save-resume equivalence holds.
  - Saving the live table was considered; it would also need the path queue's partial searches restored exactly
    (§15).
- **Landers mid-descent.** The codec drops `landingTarget`, so the operation re-arms it from its own LZ on load. A
  lander missing on load has its landing resolved abstractly.
- **World-level additions,** additive and omitted at defaults:
  - the `WarLedger` (§7.4): the player's dead by operation day over the last 10 days, and each source colony's
    mood debt;
  - garrison supply runs in flight (source, amounts, arrival time);
  - **pending commands** in the `CommandInbox`, each with its target tick. A save is taken between ticks, from
    the UI, so a command enqueued and not yet drained would otherwise be lost.
- **CitySim additions,** additive and omitted at defaults:
  - the `siteFactor` entries (deployed share and damage, §4.1), the port garrison and its carried stock, the
    occupation block and `forceUsed`;
  - wounded troopers' redeploy timers (2 days, §4.1);
  - `Grievance.warDead`.
- **Quiesce first:** `flushHeld` before encoding, as `_save` already does (`simulation_view.dart:2699-2701`).
  Replaying the held ticks drains those colonies' `ColonyCombatInbox`; every other colony drained its inbox in
  this tick's `_cityPhase`, because `_combatPhase` writes before the city loop (§5.3). The encoder then asserts
  every inbox and outbox is empty. If one is not (a bug, or a future write path), it is encoded as a `pending`
  list on that colony rather than dropped.
- **Craters (phase 6)** are saved in the operation and re-applied on load, keyed by (opId, seq). General
  terrain-edit persistence would replace this and fix impact craters too (Q13).
- **Not fixed here:** the world save is still one in-memory string. Combat makes a durable slot more urgent.

## 14. UI

All wording is player-facing, because master ships to prod.

- **Planner sheet** (`screens/combat/operation_planner_sheet.dart`). It opens from the port's site-sheet row
  (phase 1) and the Reclaim Force row (phase 2), and shows:
  - each source, its ready troopers, and why others are not ready ("Barracks short of ammo");
  - trooper sliders and days of supply;
  - ROE;
  - the goal: retake the port, or occupy with a garrison size;
  - the LZ (automatic; a draggable pin from phase 3);
  - the outcome-band histogram and casualty ranges;
  - the costs in plain words ("Troopers are your colonists", "Force wins no loyalty", and for a standoff
    colony "Retaking the port reopens it: settlers who cannot be fed will leave", §7.1).
  - Then **Launch**, and from phase 4 **Launch and join**.
- **HUD chip.** "Retaking the spaceport · day 1.4 · ▰▰▰▱▱". It opens the **operations drawer**:
  - objectives with control bars;
  - formations with morale and supply;
  - orders (phase 3), Withdraw, and Join (phase 4).
- **Notices** go through the loyalty notice queue (landed, objective taken, squad broken, supplies out, won, lost),
  and a toast in the flight view. New kinds have their own text: `portRetaken` ("Your troopers have retaken the
  spaceport"), `occupied`, `garrisonExpelled`, `troopersDeserted`, `operationOvertaken`. None reuses
  `portReleased`.
- **The occupied colony (phase 2).** Every HUD branch tests only `Allegiance.independent` today
  (`city_control_ui.dart:82`; `city_game_hud.dart:157`, `:748`, `:762`; `city_panels.dart:307`, `:336`), and the
  chip prints `stage.label` (`city_game_hud.dart:762-764`). Occupied gets its own state:
  - chip: "Occupied · 34% · garrison 18";
  - explainer: the garrison and its upkeep, suppression s, the mood cost, and the neglect rule ("Occupation is
    ruling: neglect it and the garrison will be thrown out");
  - Restore charter progress: loyalty against 0.6, then the 10-day hold, with the expected time at today's mood;
  - Withdraw garrison, with its cost stated.
- **After-action report:**
  - outcome band;
  - dead on each side, civilians, buildings lost, stock spent;
  - loyalty and grievance effects, and what happens next;
  - what the player personally did ("You took Pad 2").
- **Battle HUD (phase 4):**
  - crosshair, hit markers and damage-direction arcs;
  - HP, suit oxygen, ammo and jet fuel;
  - objective markers;
  - a balance-of-power bar and squad cards;
  - a five-line event feed and the order menu.
  - One painter, inside `ExcludeSemantics`.
- **Battle menu (Esc):** Leave the fight (it continues on auto-resolve), Withdraw, Resume.
- **The first join** shows short hints that teach one verb at a time: move and shoot, then orders, then
  reinforcements, then the command view. No scripted-mission system exists, so this is hints, not a scripted
  mission.
- **Dev hook:** `ext.acro.combat` (plan, launch, join, order, fire, possess, status JSON), driven by
  `tool/drive_city_game.dart --script`. `main_city_game_dev.dart` founds one colony (`id: 'city-dev'`, `:109`),
  so `ext.acro.combat?fixture=portSeizedPair` loads the §12 fixture world, and `?step=<s>` runs world ticks
  (the existing `_step` advances only the colony, `:447-461`, which steps no operation).

## 15. Alternatives considered

**Ground Operations (RTS first, 21.2).**
- *Why it lost:*
  - Commander-first is the seat the user was less drawn to.
  - Against militia-scale rebel towns, a top-down RTS is thin.
  - Its first live phase bundled navigation, AI, a full command UI, the unit renderer and the minimap before
    anything was playable.
  - Its bake budget had an arithmetic error: 600 samples at 0.69 ms is about 414 ms per tick, not 0.4 ms.
- *What this plan took from it:*
  - saving the raster with the battle;
  - squad-pair line of sight and 10 Hz aimed fire;
  - deterministic, term-guarded site destruction (here `warDamageSite`);
  - a dedicated combat overlay, and the marquee only in a command posture;
  - routs and surrender as the usual endings;
  - ROE, the command card and stall reasons;
  - the live/abstract conservation test.

**Drop Zone (avatar first, 20.8).**
- *Why it lost:*
  - Its foundation phase already flew real shuttles.
  - Its first live phase moved the walker into the tick and landed hitscan, ground, hulls, navigation, AI,
    rendering and HUD all at once.
  - Its ground fill (2,000 cells a frame plus an exact sample for the avatar every tick) is unaffordable on today's
    numbers.
  - RTS was pushed to an optional last phase.
  - A first draft of this plan repeated the bundling in its own phase 4. Review caught it, and §16 now splits
    phase 4 into 4a (avatar against static defenders), 4b (navigation and AI) and 4c (calibration).
- *What this plan took from it:*
  - the frozen battle map and the colony inbox;
  - the `wish` term in resolve;
  - the X reinforcement call-in, the battle menu, the death camera and REDEPLOY;
  - after-action credit;
  - one step function for walking and the avatar;
  - the number-key orders.

**Warfront (one unit model, 19.9; the player-experience lens's pick).**
- *Why it lost:*
  - The largest scope: projectiles for every shot, 3D occupancy, three locomotion layers and a precision tile all in
    its first playable slice.
  - Real landers on its foundation phase's critical path.
  - A worker-isolate bake against the project's rule.
  - Auto-joining at 2 km would clamp warp by surprise.
- *What this plan took from it:*
  - the unit table with a controller slot (possession is a swap);
  - the calibration harness (reported in phase 4b, gated in 4c);
  - `tickAlpha` interpolation;
  - baking from base relief outside brushes;
  - the 400 m LZ rule, lander ids from the operation counter, and re-arming the landing target on load;
  - `FactionId` everywhere;
  - low-g ballistics for slow rounds, jump jets, suit breach tied to terraforming;
  - the lander as a respawn point, and ejecting from wrecks.

**Smaller choices, rejected:**
- **§6.3 as written:** mis-scaled, and it contradicts the hearts route (§2).
- **Units as Vessels:** every moving vessel gets a 256-point trajectory and patched-conic prediction on each
  capture, plus per-vessel tick work. Vessels are kept for landers and craft the player flies.
- **Combat vehicles in traffic's lanes:**
  - routes locked at spawn, no overtaking, and a 120 s stuck despawn;
  - another session's hottest loops.
- **Reusing `damageBuildings`, `flattenOne`, fire spread or the nuke:**
  - the damage and fire helpers are cell-grid only and unseeded;
  - the nuke kills about 91% in 120 s with no shelter.
- **Hitscan everywhere** wastes low-gravity ballistics. **Projectiles everywhere** costs too much. The plan uses
  rolls for AI small arms, hitscan for the player, and projectiles for slow rounds.
- **Saving the live table:** possible, but partial path searches would have to be saved or replayed exactly. Leaving
  the fight before saving is simpler and has precedent.
- **Lockstep netcode:** unseeded CitySim, and floats deterministic per platform only.
- **Joining by proximity:** clamps warp without asking.

## 16. Phases

Each phase is approved separately. Each one is useful if it is the last. A phase's **gate** is a named local
command that must pass before approval (`fvm flutter test test/combat`, plus the tools named below), because the
repo has no test CI (§8.9).

**Spike S: measurements, no gameplay.** It runs alongside phases 1–2, all headless except items 4 and 5, and its
results are written into this plan before phase 4a is approved. Each item has a pass line. A miss stops phase 4a
for a decision; it does not quietly lower the bar.

| # | Measures | Pass line | If it misses |
|---|---|---|---|
| 1 | Ground sample cost: `surfaceRadiusAt`, `baseGroundRadiusAt`, `groundRadiusAt` per sample on a settled starter town and the reference colony, plus the share of a 1.2 km square under any brush | the worker pool bakes 1.2 km at 8 m within 90 s (0.75 operation days at 1×), with ≤ 1 ms a frame on the main thread | shrink to 800 m; if 800 m misses too, phase 4a waits for a cheaper field query |
| 2 | Navigation: 4 squads, 3 objectives, flow fields through hull prisms on a real graded town, 20 scripted seeds | at most 1 stuck squad (no progress for 30 s) in 20 runs; ≤ 3,000 expansions a tick held | phase 4b is re-planned before approval (4a needs no navigation) |
| 3 | Drawn vs simulated: `massFor` hulls against drawn buildings on 50 samples; terrain mesh against field at the reference colony on 200 points inside a battle square | hull error ≤ 0.5 m at p95; terrain mesh error ≤ 0.3 m at p95 | hulls: a conservative inflation and a contract with the archetype owner; terrain: the decision in §8.3 |
| 4 | Render increment: 48 instanced primitive soldiers and 500 tracers in the flight view at the reference colony | within the §11.5 rows (draws ≤ 0.6 ms, FX ≤ 0.5 ms); confirms the 110 ns and 16 ns estimates within 2× | fewer pose batches; a lower `tracerCap` |
| 5 | Flight-view baseline: static, walking and orbit, in city mode and flight mode, at the reference colony | sets the battle gate and the live add (§11.5); passes if it leaves ≥ 1.5 ms of headroom under 16.7 ms p75 | phase 4a starts by moving the flight-view walker onto the raster |

**Phase 1: Retake the port (auto-resolve, no units on screen).**
- *Prerequisites:* none.
- *Domain:* `lib/domain/combat/`: `FactionId`, `combat_rng` with its pin test, the operation clock,
  `Operation`, `OperationRegistry` and `LaunchSnapshot`, `Formation`, `ObjectiveGraph` (Port and LZ), the
  resolver, the preview, the abstract AI, the lifecycle rules of §7.6 that apply to a port.
- *Colony:*
  - `city_war.dart`: readiness, `siteFactor` in both aggregation loops (§4.1), port-holder sizing,
    non-destructive port damage, `recordWarDead`;
  - `releaseByForce` with its own notice, and the port garrison guard;
  - `ColonyCombatInbox` and `ColonyCombatOutbox`;
- *World:* `_combatPhase` with the registry and `CommandInbox` injected through `AdvanceSimulationTick`'s
  constructor (§5.3), the `WarLedger`.
- *Commands:* `LaunchOperation`, `OperationOrder(withdraw)`, `WithdrawGarrison`; the `_envelope` and bridge
  cases throwing `UnsupportedError`.
- *Saves:* codec v3 `operations` block, `WarLedger`, pending commands; the `%` fingerprint digest.
- *UI:* the site-sheet row, planner, HUD chip, notices, after-action report, `ext.acro.combat` with
  `?fixture=` and `?step=`.
- *Tests (on `CombatFixtures`, §12):* twin-run, save-resume mid-operation (including the queued-write tick), warp
  and frame-hold equivalence, the calibration table (its first row pins §6.3's 182 s), the re-seizure guard, the
  no-secede-on-win pin (§7.1), the `portRetaken` notice text, the §7.6 port rows, `siteFactor = 1` leaving every
  aggregate bit-identical, the hygiene scan, AOT smoke, the gate sweep for the new row, and a headless
  **reachability scenario**: a starter colony played by script to 300 population with an Arms Factory, a Rations
  Plant and a ready Barracks.

*Ships:* a colony whose rebels seized its spaceport can be retaken with troopers from another colony's barracks.
The outcome is previewed and seeded, with real deaths, spent supplies, a loyalty cost, and a garrison that stops
the rebels taking it straight back. The planner says plainly that the standoff continues, and that settlers
who cannot be fed will leave. It saves and loads mid-operation.

**Phase 2: Force on an independent colony, and occupation.**
- *Prerequisites:* phase 1. Secession-lane sign-off on `occupy()`, the occupied branch in `_stageStep`, the
  petition commands and Restore charter (§18).
- *Trigger:* the Force row goes live (the pin at `city_control_gate_test.dart:802-805` is updated deliberately).
- *Objectives:* Seat, Life support and Power.
- *Defenders:* the resolve formula, regulars, emplacements and defender waves.
- *Exits:* surrender, and the dependency petition through `AcceptPetitionCommand`.
- *`city_occupation.dart`:* `occupy()`, garrison, suppression of rebellion and misrule, the mood cost, upkeep,
  Restore charter, early withdrawal, expulsion; the occupied HUD state (§14).
- *Politics:* `Grievance.warDead`, war weariness, Restrained and Standard ROE with shelter-mitigated civilian
  deaths.
- *Tests:* the occupied-semantics pins updated deliberately; occupy a colony that seceded by 3 revolts, step once,
  assert it is still occupied and reads "Occupied"; the remaining §7.6 rows.

*Ships:* the third way back works. Conquer a seceded colony, hold it by governing it well under guard, and either
restore its charter or watch it throw the garrison out.

**Phase 3: Watch it: force landers and a visible battle.**
- *Prerequisites:* phase 1 (not phase 2).
- *Battle plumbing (shared with phase 4a, which takes it if phase 3 has not been built):* `CombatFrame`,
  `combat_fx_pool`, the `combat` SceneSync stage, FrameTiming parity in the flight view, the render shed ladder,
  PerfKnobs, prewarm, and the `_battleCamera` over any colony (§10.1).
- *Landers:* `ForceRunFactory`; real landers on airless bodies to an LZ at least 400 m from closed pads, with
  honest losses and the landing target re-armed on load. Landing stays abstract elsewhere.
- *Battle on screen:* blasts, burning sites, control; objective markers and front arrows in `CombatOverlayState`.
- *Orders:* operational orders from the drawer and the markers; reinforcement waves on extra landers.

*Ships:* troop landers come down on the Moon. The fight is visible from the battle camera, with explosions,
fires and moving front lines, and squads can be redirected between objectives. Still no individual soldiers.

**Phase 4 is split in three,** because as one approval it bundled exactly what §15 rejected Drop Zone for.

**Phase 4a: The soldier, against a static defence.**
- *Prerequisites:* phase 1; Spike S items 1, 3, 4 and 5 passed; the battle plumbing (from phase 3, or built
  here).
- *The fight:* the frozen battle map and its raster (worker-pool bake, save); the unit table; the walker and EVA
  pack moved into the domain and stepped from `AvatarInputCommand`, with `tickAlpha` and the `pushOut`
  collision step; player hitscan and 10 Hz aimed fire **from emplacements and militia that hold their positions**;
  HP, suit breach and fall damage; morale and suppression; no navigation.
- *The bubble:* join (with the synchronous-bake rule), leave and write-back; the warp lock; leave-before-save.
- *Player tools:* death camera and REDEPLOY; the battle menu.
- *Presentation:* the unit renderer, tracers and FX, the battle HUD, first-join hints.
- *Fixes:* the third-person orbit and spawn fixes.
- *Gate:* the frame-hold test on a joined operation (§12), join/leave conservation, the collision tests.

*Ships:* "Launch and join". Step out at the LZ (or down the ramp, if phase 3's landers exist), fight for the pads
against dug-in rebels, die and redeploy, or leave and let the fight auto-resolve.

**Phase 4b: Squads that move.**
- *Prerequisites:* phase 4a; Spike S item 2 passed.
- *Adds:* navigation grid, sector A\* and flow fields; line of sight; squad and side AI; first-person orders and
  the X call-in.
- *Gate:* headless scenario tests; the calibration harness **reported**, not gated.

*Ships:* fight beside a squad, give orders with the number keys, call in reinforcements.

**Phase 4c: Calibrated.**
- *Prerequisites:* phase 4b stable (no AI changes for one review cycle).
- *Adds:* tuning until live and abstract agree.
- *Gate:* `bin/combat_calibrate.dart --gate` at ±10% on the three reference scenarios.

*Ships:* leaving a fight to auto-resolve no longer changes the expected outcome.

**Phase 5: Command view and possession.**
- *Prerequisites:* phase 4b (there must be live squads to select and possess) and the `_battleCamera`.
- *Command view:* the command camera and posture; select, marquee, right-click orders, waypoints, control groups,
  pause-and-order, the command card.
- *Supporting pieces:* the raster ground pick, the 2D minimap, and possession by controller swap.
- *Tests:* widget tests for button filtering, stack order and the existing orbit habits.

*Ships:* Tab between first person and a top-down view. Box-select squads, right-click orders, and jump into any
friendly trooper. This is the Battlezone II loop, infantry only.

**Phase 6: Driver, heavy weapons, destruction.**
- *Prerequisites:* phase 4b.
- *Vehicles:* the shared vehicle controller extracted; wheeled, tracked and hover locomotion; seats, boarding and
  eject; vehicle meshes and wrecks; armour formations.
- *Weapons:* rockets and cannon as projectiles.
- *Destruction:* destructive war damage and rubble; Heavy ROE; quantised, saved craters; local raster
  invalidation; optionally a structure layer for bridges and tunnels (§8.2).
- *Traffic:* adopt contracts C1–C3 and C6 if delivered.

*Ships:* drive a buggy or APC into the fight, gun from the second seat, and bail out when it burns. Buildings fall
and the ground scars, with a visible civilian cost under heavier rules.

**Phase 7: Pilot and strikes.**
- *Prerequisites:* phase 3 (landers) and phase 4a.
- *Flying:* `PilotInputCommand` per tick; fly the lander in yourself with auto-land assist; the lander as a
  respawn point.
- *Call-ins:* gunship passes from Airfields (their own objective, §6.2), and silo strikes.
- *Prerequisite for Earth and Mars:* air-relative aero (cross-lane).

*Ships:* fly the dropship in, strafe defences, call a strike, then step out as a trooper. Earth and Mars battles
open once the aero fix lands.

**Phase 8: Uprisings, rivals, multiplayer groundwork.**
- *Prerequisites:* phase 2 (uprisings need garrisons); phase 4b for live rival raids.
- *Uprisings:* defensive battles in place of the flat revolt where a garrison exists.
- *Rivals:* rival factions with an owner on CitySim.
- *Network:* faction authority in `Session`; regenerated wire bindings plus a combat table; the `_envelope` cases
  made real; server snapshots with own-unit prediction over a non-loopback transport.

*Ships:* defend your own colonies and face rivals. A headless server can host a battle a remote client watches.

**Prerequisites and reordering (Q1).**
- **Phase 4a straight after phase 1** (soldier first). Phase 4a then also builds the battle plumbing (CombatFrame,
  `combat_fx_pool`, the SceneSync stage, FrameTiming parity, the render shed ladder, PerfKnobs, prewarm, the
  `_battleCamera`). Landing is abstract: the player steps out at the LZ, not down a ramp, and the X call-in in 4b
  lands abstractly. Phase 3 later adds only landers, the no-units battle view and operational orders.
- **Phases 4 and 5 swapped** (RTS first). Phase 5 can then only follow phase 4b's live layer minus the avatar: the
  bake, unit table, navigation, LOS, AI, unit renderer and the plumbing all move into the RTS phase, and possession
  waits for 4a. That is a bigger first live phase, which is why soldier-first is proposed.
- The pools-as-truth model allows either without redesign, but neither is free.

## 17. Risks

- **Hybrid audience.** Players who came for the city builder may not want a shooter, and the reverse. Auto-resolve
  is complete and fair, and both seats are optional. Force is presented as a deliberate, previewed choice.
- **Unit AI and pathfinding on graded towns** is the most common failure in these hybrids (Battlezone II, Carrier
  Command 2012, Kenshi).
  - Mitigations: Spike S's scenario, stall reasons, and headless scenario tests before content.
- **Drawn and simulated disagree.** Massing boxes are not the drawn archetypes, and the field differs from the mesh.
  Shots may stop in mid-air or pass through walls, and units may float or sink.
  - Mitigations: conservative hulls, a cosmetic lift for near units, and Spike S to size the error.
  - A pure archetype function shared with the renderer would need a contract with its owner.
- **Ground sampling cost** is unmeasured (§2): Spike S, a bake during transit, base relief outside brushes, and a
  saved raster.
- **Live and abstract drifting apart:** the calibration harness, reported in phase 4b and a local gate in 4c.
- **Occupation balance** depends on the suppression term and on the player governing the colony (neglect is not
  suppressed, §7.2), whose tuning crosses into the secession lane and its pinned tests. The 83-day climb at low
  mood may feel endless (Q15).
- **Re-seizure loop:** the port garrison guard, with a test.
- **A win that feels like a loss.** Retaking a standoff port restarts the exodus and does not end the standoff
  (§7.1). Mitigations: the planner says so before launch, and Q7 offers suppressing emigration while a garrison
  holds.
- **Frame budget.** The flight view's baseline is unmeasured, and the studio's walking figure (12 ms) already
  leaves under 2 ms to its own gate. Mitigations: Spike S item 5, hard caps, the render-only shed ladder, and
  FrameTiming parity in the flight view.
- **Re-homing the walker** could regress today's walk: one shared step function, the 22 existing tests (15 unit,
  7 widget), collision off by default, and `tickAlpha`.
- **A new term in CitySim's hot loop.** `siteFactor` touches both aggregation loops. Mitigation: a bit-identical
  test at factor 1, and a bench row.
- **Determinism leaks:** the frozen battle map, the hygiene test, digests and AOT smoke.
- **Tone:** killing colonists in a colony sim. Restrained ROE is the default and surrender is the usual end (Q5).
- **Merge pressure** in `simulation_view.dart`, `advance_simulation_tick.dart`, `city_sim.dart` and
  `city_loyalty.dart`: a part file with Expando state, extension files, and single call sites.
- **Earth and Mars landings:** airless bodies first; abstract landing elsewhere.
- **Fragile saves:** the slot is in memory and terrain edits are not saved. Mitigations: leave-before-save, craters
  saved with the operation, and the durable slot flagged.
- **Agent Traffic's schedule:** every request is non-blocking through phase 5.
- **No art and no audio.** Primitive soldiers and silent guns may read as unfinished (Q13).
- **Force as a fix-it-with-troops exploit** on standoff colonies: no loyalty gain, a loyalty cost, the standoff
  continuing, the costs, and a grievance that remembers.
- **Scope.** This is a pillar the size of the city builder. It is approved phase by phase, and phase 1 is useful on
  its own.

## 18. Ownership seams

| Area | Owner | How combat touches it |
|---|---|---|
| `lib/domain/combat/**`, `city_war.dart`, `city_occupation.dart`, `combat_frame.dart`, `lib/infrastructure/flutter_scene/combat/**`, `simulation_view_combat.dart` (a new `part` file, state in an Expando), `screens/combat/**`, `bin/combat_calibrate.dart`, `tool/aot_combat_smoke.dart` | **combat lane (new)** | owns them |
| `lib/domain/colony/city/traffic/**` and the traffic renderer files | **Agent Traffic** | contract only, never edited (see below) |
| `site_access/**`, `RoadGraph`, `CityLayout.roadIndex`, `road_elevation.dart` | Road Placement | read-only: `entrancePt`, deck heights. **Request R1:** move the road and pavement lifts (`ribbonLiftM` 0.12, pavement 0.27) from `road_mesher.dart:195` and `road_overlay_state.dart:57` into the domain, with a pin test that the renderer reads the same values. Phase 4a needs it; until it lands, combat keeps a copy of the two numbers with a pin test against the renderer constants (the `hash32.dart` precedent) |
| `city_loyalty.dart`, `city_reclaim.dart`, `city_control.dart`, `city_reclaim_ui.dart` | secession lane | `releaseByForce` with its own notice; the garrison block; `occupy()` and an **occupied branch in `_stageStep`** (secession test replaced by expulsion, `selfGoverning` false); suppression of rebellion and misrule; `Grievance.warDead`; the Force row's `onTap`; `acceptPetition` / `acceptNegotiation` routed through commands; outbox posts on stage changes. **Design changes needing sign-off:** Restore charter as a player act instead of `colony-secession.md:269`'s automatic return; neglect left unsuppressed under occupation; no desperation bump on a retake. Pinned tests updated deliberately |
| `city_sim.dart` | colony | **not a few hook lines**: `siteFactor` in both aggregation loops (`:1376-1381`, `:1389-1407`, with the site id carried in `parcelActive`), the moved input draw for deployed troopers, the inbox drain and outbox posts, the `socialTick` suppression term, garrison upkeep, the wounded timers, save keys. Estimated at a few hundred lines in `city_war.dart` plus about 30 in `city_sim.dart`, with a bench row |
| `advance_simulation_tick.dart` | shared | `_combatPhase` and its call site, constructor injection of the registry and `CommandInbox`, the inbox drain in `_cityPhase` |
| `sim_host.dart`, `flight_session.dart` | shared | pass the registry and `CommandInbox` into their `AdvanceSimulationTick`; `FlightSession` keeps the registry across `rebuildTick` |
| `flatbuffer_codec.dart`, `apply_commands.dart`, client and bridge switches | wire / multiplayer | the new command cases (`UnsupportedError` until phase 8) |
| `simulation_view*.dart` | shared hub | the part file plus hook lines: `tickAlpha`, `_simKeys`, the Ctrl exception, outer-Listener fire, the battle and command cameras |
| `screens/city_game_hud.dart`, `screens/city_control_ui.dart`, `screens/city_panels.dart` | city game UI (shared) | the HUD chip, operations drawer, notice kinds, the occupied state (§14) |
| `screens/city_site_actions.dart` | city game UI (shared) | the spaceport's "Retake by force" row on `CitySiteHooks.extra` (`:54`) |
| `screens/city_edit_overlay.dart` | city game UI (shared) | the Command tool in `CityEditTool` (`:40`), phase 5 |
| `main_city_game_dev.dart` | dev tooling | `ext.acro.combat`, `?fixture=`, `?step=` |
| `SurfaceConditions`, planetary air | terraforming lane | read-only |
| `third_party/flutter_scene` | fork | no patch planned; any patch is logged in `FORK.md` |

**The Agent Traffic contract:**
- *Uses only what is already published:*
  - E8 deaths, through CitySim's own death write;
  - `CityTrafficReadout`, read-only;
  - the frame-hold semantics (`holdTick`, `endFrame`, `flushHeld`), **including that a held colony trails the
    world by at most `maxHeldCityS`** (15 colony seconds, `traffic_tuning.dart:316`). §5.3's documented lag
    depends on that bound, so the request is that it be stated as published, not private tuning.
- *Requests,* none of which blocks phases 1–5:
  - **C1** a per-colony shelter-in-place or curfew (`commuteRatePerResident` is process-global);
  - **C2** a second `LaneObstacles` source (its one slot is taken by the site mover), for wrecks and roadblocks;
  - **C3** a disabled-vehicle flag;
  - **C4** moving `slot_pool`, `traffic_rng` and `traffic_time` to a shared folder (until then, copies with pin
    tests);
  - **C5** a battle-zone render cap;
  - **C6** an "away" flag on citizens, so deployed troopers stop commuting to the barracks they left (§4.1). Until
    then they keep commuting, an accepted oddity.

Every new file carries the PolyForm header.

## 19. Open questions for the user

The proposed answers are the defaults this plan is written on. Every number is in a tuning object.

- **Q1 Order.** Should fighting in person (phase 4a–4c) come before the top-down command view (phase 5), as
  proposed, or should RTS come first? Should the soldier move up to straight after phase 1, ahead of the visible
  battle and occupation, if being on the ground matters most? §16 lists what each move carries with it: soldier
  first pulls the battle plumbing into 4a; RTS first pulls the whole live layer into phase 5.
- **Q2 Who fights for the colony, and can civilians be harmed?** Proposed:
  - militia raised from the population by resolve, plus regulars from any military the colony kept;
  - civilians never targetable;
  - civilian deaths only from collateral under Standard or Heavy rules, reduced by shelters.

  The alternatives are rebels holding buildings only, or no civilian harm ever.
- **Q3 Single-player or multiplayer from the start?** Proposed: single-player first, but command-driven and
  deterministic from phase 1, with server snapshots and own-unit prediction later, and no lockstep.
- **Q4 Rebels only, or rival factions too?** Proposed: rebels (and later uprisings) first, with a `rival` owner
  reserved. Should phase 8 build a real rival AI that raids, scripted rival strikes, or neither?
- **Q5 Tone.** Grim (colonists die often, civilians at risk, as in Frostpunk) or restrained (routs and surrender as
  the usual end, low collateral, force a costly last resort)? Proposed: restrained by default, with the ROE setting
  as the lever.
- **Q6 Are troopers your colonists** (proposed: deaths cost the home colony), or an abstract professional force
  bought with ore?
- **Q7 Force against a still-colonial standoff colony.** Allowed, as proposed, with no loyalty gain and loyalty
  −0.05 (the desperation bump is dropped, §7.1)? Or only once a colony has seceded? And what should a win mean:
  - **as proposed:** the port reopens, and so does the exodus the code already runs for a standoff with an open
    port. Settlers who cannot be fed leave, desperation keeps climbing unless you govern, and an ungoverned
    standoff still ends in secession. The garrison only stops re-seizure;
  - **or:** a held garrison also suppresses standoff emigration and holds desperation, so a retake really
    stabilises the colony. That changes the secession lane's standoff design.
- **Q8 Seat of government.** Add a Council Hall as the occupation objective, or use the largest civic building?
- **Q9 Real landers on airless bodies only** until the aero fix, with abstract landing on Earth and Mars: acceptable?
- **Q10 Saving inside a live fight.** Leave the fight, then save (proposed, the Total War and Mount & Blade rule),
  or save the live state?
- **Q11 Death.** Respawn as the next trooper, costing a colonist (proposed), or permadeath with a switch to command
  or auto-resolve?
- **Q12 Platforms.** Is mouse-captured fighting on Windows only acceptable for v1, with hold-RMB look on macOS and
  Linux and no live fighting on web or touch?
- **Q13 Assets and engine gaps.** Add an audio dependency for gunfire and explosions, and in which phase? Are
  primitive rigid-part soldiers and box vehicles acceptable through phase 6? Should terrain edits be persisted in
  the codec generally (it would fix impact craters too) before phase 6?
- **Q14 Battle scale.** Are 24 live units per side, a 1.2 km battle square (800 m if Spike S says so, 600 m on web)
  and a 10-day ceasefire cap (about 6 fair fights at the recomputed calibration, §6.3) the right defaults?
- **Q15 Occupation.** Three parts:
  - **Pace.** At the real recovery rate, climbing from 0.2 to 0.6 takes about 83 days at mood 0.2 and about 20 at
    mood 0.5, before the 10-day hold (§7.2). Is a long campaign of good government right, or should occupation
    speed recovery (for example, a recovery multiplier while the garrison holds)?
  - **Restore charter.** A player act behind a notice, as proposed, or automatic after the hold, as
    `colony-secession.md:269` has it? The proposal changes the secession plan.
  - **Orders.** Should an occupied colony's orders be restricted while the garrison holds?
- **Q16 Uprisings.** Should a defend-the-colony battle replace the flat −30% revolt where a garrison exists? That
  changes secession behaviour.
- **Q17 Strikes.** May silo strikes hit populated objectives? Should terraforming towers be off-limits, as
  proposed, since destroying them damages every colony's sky on that body?
- **Q18 Agent Traffic.** Will that session take requests C1–C6 (C6: an "away" flag for deployed troopers), and is
  C1 (shelter-in-place) wanted before phase 6?
- **Q19 Road Placement.** Will that lane take R1 (the road and pavement lifts moved into the domain)? Are bridges
  and tunnels acceptable as blocked ground in battles until phase 6 (§8.2)?
- **Q20 Where force is planned from.** The CITY BUILDER host opens SimulationView on one injected colony
  (`city_game_screen.dart:91-97`). A second colony is founded from a landed craft in the flight world
  (`simulation_view_colony.dart:44-57`). Is force a flight-world feature, as proposed,
  or should the city builder host gain a multi-colony world first?
- **Q21 Test CI.** Phase gates are local commands, because the repo has no test workflow. Add one, pinned to
  `.fvmrc` as `release.yml` pins Flutter, or keep local gates?
