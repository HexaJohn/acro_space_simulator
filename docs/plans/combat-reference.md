<!--
Provisional reference behind docs/plans/combat.md (condensed 2026-10-10, baseline dev at 085c72a).
- This is the full plan as written on 2026-10-10, unchanged below the line. It is kept for its reasoning, its
  numbers and its code anchors (checked at 9eccb7d and 085c72a).
- docs/plans/combat.md is the working plan: a short core plus a detailed spec for phase 1 only.
- Detail here for every phase after phase 1 is provisional. It will be re-checked against the code and
  re-specified in combat.md just before each phase is built.
- Where this file and combat.md differ, combat.md wins.
- Question numbers (Q1-Q36) and section numbers (§1-§19) here are the ones combat.md cites.
-->

> **Provisional reference.** The working plan is [`combat.md`](combat.md); it wins where the two differ. Detail
> for phases after phase 1 will be re-checked and re-specified there before each phase is built.

---

# Combat: taking colonies back by force

Status: draft for review, 2026-10-10. Baseline `dev` at `9eccb7d`. Paths are relative to the repo root.
Planning only: nothing here is built. Every line anchor below was checked at `9eccb7d`.
Revised after review: the occupation entry, the operation clock, the lifecycle of garrisons, staffing, the
calibration, budgets and the phase split were all reworked against the code (§5.3, §7, §16).
Revised again on 2026-10-10 for the **Halo Wars layer**: in-battle base building, an economy inside the
operation, commander powers including orbital strikes from a real armed vessel overhead, a counter table,
Halo Wars selection on keyboard and mouse, fog of war, and an optional gamepad (§10A, with edits through every
section). The Operations Ledger core is unchanged. Anchors added in this revision were checked at `085c72a`
(a docs-only commit after `9eccb7d`, so the code is the same).
Reviewed again on 2026-10-10 against the code. Fortification is now side-relative, and the warp ceiling has two
levels, because nothing flies under power above 4×. The ceiling is applied at one choke point. Supply runs and
hot-drops are abstract arrivals fixed on the operation clock. The uplink lives in the core. Base damage, the
calibration pin, the preview budget, persistence, the UI's home and the phase split were all corrected
(§5.3, §6.2, §6.3, §10A, §16).

## 1. Intent

The user, 2026-10-10, on reclaiming a seceded colony by force:

> "would basically turn this into an RTS then, no?" … "RTS mode would be pretty cool tho" … "RTS or even
> allowing the player to engage in the battle themselves as a soldier or pilot or something" … "Just plan it
> for now"

The precedent the user responded to is *Battlezone* (1998). It is an RTS played from inside a hover tank on the
Moon, Mars and Venus, and the pilot can eject and fight on foot.

Then, on the shape of the RTS side:

> "I imagine the RTS side would be like Halo Wars, does that fit the plan?" … (after a forward base, commander
> powers including orbital strikes, a counter triangle and Halo Wars selection were proposed) "Yeah, that would
> be freaking awesome. Battles should include base building."

*Halo Wars* (Ensemble, 2009) and *Halo Wars 2* (2017) are console RTS games. Bases go on fixed sites with 3, then
5, then 7 build sockets and 4 turret sockets. There is one spendable resource that arrives without gatherers.
Leader powers come from the ship in orbit (the MAC Blast). Units follow a counter triangle, and selection is a
handful of verbs designed for a gamepad. §10A maps each of those onto this game.

`colony-secession.md` §6.3 left **Force** as the last way back. It sketched garrison strength against resistance
= population × (1 − happiness), with a win making the colony `occupied`. Phases 1–3 of that plan are built. This
plan replaces its phase 4 and grows it into a pillar of the game the size of the city builder. It has four
layers:

- **A force operation** the simulation resolves on its own, Total War style. Every battle gets a result whether
  or not the player watches it.
- **Fight it yourself.** Drop into the battle as a soldier, and later as a driver or pilot, using seats the game
  already has: the walker, the EVA pack, the rover and flight.
- **Command it.** Give orders from first person with Battlezone's number keys, and later from a top-down
  command view on the city camera, with Halo Wars' selection verbs on keyboard and mouse.
- **Build and support it (Halo Wars).** Every operation lands a forward base. The force's lead lander deploys
  into a base core with a ring of build sockets, fed by the ore, kit and people your colonies shipped.
  Commander powers come from real assets, including an orbital strike that needs one of your own armed vessels
  above the battle (§10A). The base and the counter triangle earn their keep against large colonies. A rebel
  starter town fields only militia, so its fight is infantry against infantry, often over in under a minute, and
  the counters do nothing there. They start to matter once a target is big enough to have Gun Emplacements
  (400 colonists) or when rivals arrive (§10A.6, §10A.9).

Five rules shape everything below:

1. **One battle state; everything else is a way of looking at it.** An operation is a set of *formations*
   (squads kept as counts) fighting over *objectives* that already exist as colony state: the pads, the seat,
   life support, power. The auto-resolver advances those pools. When the player joins, a live fight takes over
   one objective and writes its results back into the same pools. Leaving folds it back. Because there is only
   one model, a fought battle and an auto-resolved one cannot drift apart. That drift is Total War's chronic
   failure. **The forward base is operation state too**: modules are rows on the `Operation` that change resolver
   terms, and when nobody is watching a fixed doctrine builds the base inside the same step. It is never a
   colony building (§10A.1).
2. **Combat follows from governance, and force costs the prize.** Troopers are colonists, so the dead are
   people. Force wins no loyalty. Negotiating, winning hearts and waiting out a dependency petition stay cheaper.
   **The base creates nothing from nothing**: it spends shipped stock, or converts it (the munitions workshop
   turns shipped steel into ammo). It never creates a person (§10A.6).
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
| Commands | sealed `SimCommand` `command.dart:15`; `Session.validate` `session.dart:35`; switch `apply_commands.dart:39`; wire switch `FlatBufferCodec._envelope` `flatbuffer_codec.dart:394` (exhaustive, no default) | five cases, none for units; the live game calls `AdvanceSimulationTick` directly and bypasses the authoritative path. One of the five is `PlaceBuildingCommand` (`command.dart:54-68`): cell-grid, colony-targeted, and a no-op on every apply path (`apply_commands.dart:61-63`). The base does not reuse it (§10A.1) |
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
| Build over time | placed utilities run at utilisation 1.0 from the tick they are placed ("no construction model for them", `city_sim.dart:2131-2138`); megastructure phases fill from on-site buffers with milestone events (`megastructure/megastructure_construction.dart:8-53`) | the only build-timer precedent; base timers are new state (§10A.5) |
| Build currency | ore. `placeOnParcel`'s caller debits it (`city_edit_overlay.dart:316-325`), but `claimSite` debits it itself (`city_sim.dart:5823`); `refundFraction` 0.5 (`city_sim.dart:358`) | the base's Materiel is ore (§10A.6) |
| Power aggregation | `powerOut += s.powerOutput * powerFactor(s.type)` in both loops, never scaled by `uf` (`city_sim.dart:1374`, `:1399`); the parcel loop skips a lot when `uf <= 0` (`:1397`); one pooled `powerRatio` (`:1409`), with life support taking first claim (`:1453-1469`) | a site factor does not cut a plant's output on its own (§10A.7) |
| Stock cap | `baseStockCap` 200 (`city_sim.dart:367`), plus `storageBonus` (`city_building_spec.dart:83`; Warehouse +500, Silo Cluster +1,500, Freight Yard +800) summed in `stockCap` (`city_sim.dart:1273-1285`); stock is clamped to it every tick | sizes what a source can muster (§4.1, §12) |
| Catalogs and saves | placed buildings save by label and resolve through `_specByLabel` over `kUtilCatalog` then `kZoneSpecs`, dropping unknown labels (`city_sim.dart:4992-5002`); the generator stakes one of every own-site `kUtilCatalog` spec in every city (`city_generator.dart:2166-2181`) | base modules must stay out of both catalogs (§10A.1) |
| Craft weapons | `PartCategory` has no weapon, payload or ordnance case (`part_def.dart:16-31`); `separateStage` only drops the last stage (`vessel.dart:228-233`) | an armed vessel needs new parts or a combat-owned loadout (§10A.12) |
| Line of sight and passes | `CommsService.isOccluded` (`comms_service.dart:29`); RelayNetwork's default ground station is `Vector3(body.radius, 0, 0)` in the inertial frame (`relay_network.dart:31`), so it never turns with the planet; no pass predictor, but `EncounterPlannerService._closestApproach` samples 256 points then refines (`encounter_planner.dart:280`, `:307`) | the overhead test is new; never `hasCommLink` (§10A.12) |
| Body frame | `orientationAt(epoch)` is pure spin plus tilt and must match the render snapshot (`celestial_body.dart:206-214`); `localToBodyFixed` (`city_sim.dart:5514`) | the strike target's frame |
| Crater law | `craterForImpact`: D = 0.5·(E/ρg)^¼, ρ 1,500 (`impact_scaling.dart:56-79`) | a 250 kg round at 3 km/s digs about 13 m on the Moon |
| Terrain edits | `TerrainEditsRepository` is append-only (`world_repositories.dart:107-117`) and the codec saves none; in-session brushes survive a load (`game_state_codec.dart:279-284`) | strike craters must be operation-owned and keyed (§10A.12) |
| Warp ladder | `_warpLevels` `[0, 1, 5, 10, 50, 100, 1000, …]` (`simulation_view.dart:1473`); `_stepWarp` (`:1480`); `SimHost` steps at `fixedStep: 1.0` (`sim_host.dart:109`) | the largest rung with a tick of 0.5 s or less is 10×. SimHost already exceeds the 0.5 s cap, but it wires no CitySim colonies (`SimHost.sample` passes no `cities`, `sim_host.dart:77-113`; default `NullCityRepository`, `advance_simulation_tick.dart:190`), so no operation can launch there (§5.3) |
| Rails above 4× | `railsWarpThreshold = 4.0`, `forcesRails => warpFactor > 4` (`simulation_clock.dart:42-43`); a vessel not landed is on rails when `forceRails \|\| (!underThrust && !inAtmosphere)` (`advance_simulation_tick.dart:305-307`); `_onRails` propagates the conic with no thrust term (`:1133-1159`) | **above 4× nothing flies under power**: `LandingGuidance`'s throttle is ignored at 5× and 10×. A coasting vessel in vacuum is on rails at 1× too. Shuttle dispatch is tested only at 1× (`shuttle_dispatch_test.dart:58`) |
| Warp writers | `_stepWarp` (`simulation_view.dart:1487`); warp-to-apsis cancel (`:1521`) and its per-frame fit `_clock.warpFactor = (remaining / 1.5).clamp(1.0, 1e6)` (`:1958-1969`), before the tick loop (`:1976-1992`); the atmosphere 1× lock, a per-frame check outside `_stepWarp` (`:1884-1889`); `:2574`; a load restores the saved warp (`game_state_codec.dart:249`) | a ceiling hooked in `_stepWarp` alone cannot hold (§5.3) |
| Input | raw `LogicalKeyboardKey` checks in 5 files (69 lines in `simulation_view.dart`); no Shortcuts, Intents or Actions; `_simKeys` (`simulation_view.dart:1217-1250`) does not hold Y, U, L or F1–F8 | an input action layer comes first (§10.4) |
| Gamepad | none. The pinned framework (commit `84af28a`) has no gamepad API, only `KeyEventDeviceType.gamepad` from Android key data; the "touch joystick" is a panel of self-centring PITCH, YAW and ROLL slider rows (`simulation_view.dart:3718-3720`); `ffi ^2.2.0` is already a direct dependency (`pubspec.yaml:55`) for the Windows pointer lock (`pointer_lock_native.dart:45-95`) | optional Phase G (§10.4) |

**Does not exist anywhere:** a strength or garrison model, unit entities, weapons, health, hit detection,
line of sight, off-road navigation, unit AI, selection or orders, unit rendering, a combat HUD, audio, any
humanoid or vehicle art beyond engine primitives, construction timers for placed buildings, fog of war or
detection, and gamepad input.

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
- **Building the base through CitySim gives it to the rebels.** Every placement mutator writes into one colony's
  own maps (`placeOnParcel` `city_sim.dart:5004-5010`), so a module placed in the target joins *their* jobs,
  safety and stock. §10A.1 lists the six routes and why each fails.
- **Above 25× warp, orbits and landers outrun battle time.** `opDt = min(tickDt, 0.5)`, while world dt is
  0.02 s × warp. At 1,000× a vessel moves 40 times faster in operation time than at 1×, and a 197 s pass window
  is shorter than one tick from 10,000× up. Phase 3's real landers fly in world time too, so their touchdown in
  operation time already depends on warp. Worse, above 4× every vessel not landed is on rails, so a lander at
  5× or 10× ignores its guidance and coasts into the ground. §5.3 holds a two-level warp ceiling: 1× while a
  real lander descends, 10× while only orbital support is assigned.
- **A strike round flown as a Vessel is three traps at once.** It would land at a warp-dependent point (contact error
  about 0.8 km at 25×), settle as a landed vessel under the default `disableCraftDestruction` cheat
  (`flight_session.dart:44-46`), and leave an unsaved crater. §10A.12 resolves strikes abstractly.

## 3. How this plan was chosen

The plan was chosen in two rounds: the core model below, then the Halo Wars layer on top of it (§3.1).

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

### 3.1 The Halo Wars layer (revision of 2026-10-10)

After "Battles should include base building", three designs for a Halo Wars layer were written on top of the
Operations Ledger. None competes with the Ledger; each extends it. Two judges scored them, one against the code
and the Ledger's rules, one for play.

| Design | Core idea | Code and rules | Play | Sum |
|---|---|---|---|---|
| **Beachhead** | the lead lander deploys into the base core (Battlezone's recycler); a fixed socket ring; Materiel, Power and Personnel all shipped from home; strike rounds are real vessel parts | 8 | 8.2 | **16.2** |
| Fire Support | one Supply number unpacked from shipped pallets; outposts as new graph nodes; reactor tech tiers inside the battle; a missile-loaded loadout instead of parts | 6.5 | 7.6 | 14.1 |
| Military Plat | real `CityBuildingSpec`s on a temporary military plat, checked in the editor's order; a mixed-goods economy; strike flight time and scatter grow with range | 7 | 7 | 14.0 |

**Beachhead wins on the sum** and on both judges. It is the only design that caught two clock problems in the
code: `SimHost` steps at 1.0 s (`sim_host.dart:109`), over the 0.5 s operation cap, and phase 3's real landers
fly in world time, so they drift from the operation clock above 25× warp just as an orbit does. It read the warp
ladder correctly (10× is the largest rung with a tick of 0.5 s or less). It pins "troopers are colonists" as a
per-step invariant, and it phases into slices that each ship (1b, 3b, G).

Why the layer fits the Ledger at all:
- **The base lives on the `Operation`.** Every route through CitySim breaks pools-are-truth, the frozen map,
  attention or saves (§10A.1).
- **The economy stays outside the battle.** Halo Wars treats income as background so the fighting stays in front
  (Ensemble cut to one resource "to enable quick cycling"), and Halo Wars 2's Strongholds mode gave unlimited
  resources under a hard population cap. Here the colonies are the economy, so the base spends shipped stock and
  the population cap is the people you sent.
- **The counter table is built for unequal sides.** Rebel towns field infantry and emplacements only until rival
  factions exist, so the first triangle is infantry, emplacements and charges.
- **Keyboard and mouse come first.** Every PC port of Halo Wars was criticised for tacked-on mouse controls,
  radial menus and fixed bindings.
- **Halo Wars' shallowness is answered outside the fight**: what you ship, which orbit your vessel flies, and
  whether to fight at all.

**Grafted from the losing designs** (each is credited in §15):
- the warp ceiling held only while it matters (orbital support assigned, from both losing designs; or a real
  lander in flight, Beachhead's own catch), not for every operation;
- the overhead gate defined at step-boundary epochs, with the resolver handed only a boolean (Fire Support);
- socket footprints blocked from the first bake, so a finished module never changes passability, and pad datums
  taken from the raster instead of field samples (Military Plat);
- strike flight time and scatter that grow with range, so the choice of orbit is a trade (Military Plat);
- command families, so each exhaustive switch changes once per family (Military Plat);
- the missile-loaded vessel loadout as the fallback if the parts lane declines a new part category (Fire
  Support);
- one spendable Materiel number, unpacked from shipped pallets by the core and supply pads, with 25% arriving
  ready to spend (Fire Support);
- the `supplyDays` → `kitDays` rename, so "supply" means only supply runs (Fire Support);
- outposts at held objectives, the Halo Wars expansion loop (Fire Support), attached to existing objective nodes
  instead of new ones;
- the garrison post's once-a-day footprint check, instead of a predicate in CitySim's lot growth (Fire Support);
- a `structure` target class and a share of defender fire on modules, so a base can be worn down in
  auto-resolve (Military Plat);
- the defender's Dig in, and a light operation with no base for small targets (Military Plat);
- a catalog-isolation test and a no-terrain-edit assertion (Fire Support).

**Two claims were checked and not carried over.** Military Plat said §2 "miscounts" the command cases;
`command.dart` has exactly five (`SetThrottle`, `SeparateStage`, `SetAttitude`, `PlaceBuilding`,
`ReportTerrainHeight`), so §2 was right. Fire Support held warp "at 25×"; the ladder has no 25× rung, so the real ceiling is 10× unless one is
added (Q22).

**A code fact all three missed**, found in review: above 4× warp every vessel that is not landed is on Kepler
rails, thrust or not (`simulation_clock.dart:42-43`), so a lander held at 10× would coast into the ground. The
ceiling therefore has a 1× level while a real lander descends (§5.3), and supply runs and hot-drops are abstract
arrivals rather than landers (§9.3).

**A gap all three missed**, raised by the play judge: a fair fight takes about 174 s (§6.3) and a base takes about
200 s to build. Against an 8-militia starter town the fight is over in about 45 s, before the base is up. §10A.2
and §10A.6 answer part of it with a landing turret, pallets ready on landing, up to two modules landed ready, and
a light operation offered as an explicit trade. The rest is stated plainly: the base matters against large
colonies, and a starter-town retake is mostly a short infantry fight.

## 4. Who fights

### 4.1 The player's side: the expeditionary force

- **Sources.** Squads come from staffed military buildings in any colony the player controls (colonial or
  occupied), on the same body or another. The planner lists each source and what it can field.
- **Manpower.** A building's deployable people = `floor(jobs × restThrottle)`. At most half of them, `floor(jobs ×
  restThrottle × 0.5)`, may be troopers: a barracks (30 jobs) gives up to 15 and a Military Base (80) up to 40.
  The rest are support staff, who stay home unless shipped as base crew (below). `restThrottle` is the strike
  throttle, so a Defiant colony (×0.7) fields fewer of both. The trooper cap is per source building for the whole
  operation, and a support member converted into a trooper at the front counts against it (§10A.4).
- **Readiness.** A building counts only while it is *ready*, meaning its inputs (rations, guns, ammo) are in
  stock. That is the test the production loop already applies (`city_sim.dart:1528-1535`). Readiness gates who
  may deploy; it does not change how the safety service is computed today.
- **Squads.** Troopers group into `infantry` formations of up to 8.
- **Kit.** It follows the source building's own input table, so tuning lives in one place. Per trooper-day it is
  the building's inputs × `daySec` / jobs. For a barracks that is 2 rations, 0.2 guns and 1.2 ammo.
  - At launch: 1 gun per trooper (no gun, no trooper), plus the chosen days of kit (default 3 operation days).
  - **Moved, not added.** While troopers are away, their building's own input draw at home falls by the
    deployed share. A deployed trooper therefore costs the colony what the same trooper costs idling in the
    barracks. The earlier flat rate (0.3 ammo and 0.1 rations a trooper-day) was 4× (ammo) to 20× (rations)
    below the barracks's own burn per job, and is dropped.
- **The per-site operational factor (new CitySim concept).** Staffing today is one colony-wide ratio (§2), so
  there is no per-building staff to take away. `city_war.dart` adds `siteFactor(siteId) ∈ [0, 1]`:
  `(1 − deployedShare) × damageFactor × cutFactor`, three terms saved separately (`cutFactor` is the power cut,
  §10A.7). It multiplies `uf` for that site in **both** aggregation loops: the cell
  loop (`city_sim.dart:1376-1381`) and the parcel loop (`:1389-1407`, which must carry the site id beside
  `(spec, uf)`). Jobs, services (safety included) and power draw scale with it. Power **output** does not scale
  with `uf` today (`:1374`, `:1399`), so `siteFactor` multiplies `powerOutput` explicitly in both loops; otherwise
  a damaged or cut plant would keep producing. The production loop
  (`:1520-1540`) multiplies that site's run, so its inputs and outputs scale too. Deployed troopers also leave
  the `workforce` count (`:1412`), so while away they are neither employed nor unemployed. This is a real change
  to CitySim's hot loop, budgeted in §18, with a test that a factor of 1 everywhere leaves every aggregate
  bit-identical.
- **Troopers are colonists** (Q6). So are base crews. No base module, power or supply run creates a person:
  reinforcements are more colonists, mustered from a source and debited through its inbox. An invariant test
  checks every step that everyone mustered is in exactly one place: in a formation (live rows included), crew,
  the LZ reserve, wounded, in flight, in a garrison, dead, returned or deserted (§12 states it in full).
  - They stay residents of their home colony and keep their homes.
  - Their site's factor drops by the deployed share, so its jobs, safety and output fall while they are gone.
  - **They still commute in Agent Traffic's table.** Traffic has no "away" concept, and C1–C5 ask for none. This
    is accepted as a visual oddity through phase 5, and contract request C6 (§18) asks for an away flag.
  - A trooper killed is a death charged to the home colony through CitySim's own death write. No corpse is
    added there: the dead are buried at the landing zone.
  - Survivors come home at the end. Wounded come home too but cannot redeploy for 2 colony days, a timer saved
    on the home colony (§13).
- **Later kinds:**
  - armour from the Military Base: 2 vehicles + 3 crew each (phase 6), mustered at home or assembled at the
    base's vehicle bay from shipped kits (§10A.4), at most 2 per ready Military Base source;
  - gunships from the Airfield (phase 7).
- **Base crew: support staff (from phase 1b; Q28).** The planner may also ship **support staff**: the "other half"
  of a building's deployable people that the manpower rule keeps home. They crew the base's modules (§10A.4).
  They are formed into squads only by the player's `formSquad` order at a barracks pod, and only within their
  source's trooper cap; the doctrine never converts them (§10A.8). They leave their site exactly as troopers do,
  through `siteFactor` and the `workforce` count, so shipping them drains the home site further. Example: a
  barracks that ships 15 troopers and 10 support staff runs at a `siteFactor` of 1 − 25/30 ≈ 0.17 while they are
  away. The default ships only the crew the chosen doctrine's first modules need.
- **Materiel (from phase 1b).** The muster also ships ore from source colonies: the base's one spendable number
  (§10A.6). It is debited at `LaunchOperation` with the troopers and kit, moved, not added. At most half of any
  one source's ore may go. The default is the lesser of 300 and what that rule allows across the sources. A
  colony with no warehouse holds at most 200 ore (`baseStockCap`, `city_sim.dart:367`), so it can ship at most
  100: a big base needs warehouses at home.
- **Base supplies.** The manifest also ships fuel and medicine for the doctrine's first modules: by default 2
  operation days of generator fuel (24) and 10 medicine (the field hospital, or one Medevac). Both are
  deliverable colony goods, debited like the kit.
- **One base stock.** Mustered kit, Materiel and later supply runs pool in the operation's base stock. Formations
  at a held base site, or one hop from it (§6.2), refill their `kitDays` from it (§10A.6). Formations further out
  run down as before.
- **What launch reads from each source: the `SourceSnapshot`.** Taken when `LaunchOperation` applies, with the
  target's `LaunchSnapshot` (§4.2): per source building, ready troopers and deployable support staff; the
  source's ore, rations, ammo, guns, fuel, medicine, steel, electronics and missiles, and its stock cap; and the presence of
  each home-gate building (Spaceport, Arms Factory, Barracks, Hospital, Military Base, Airfield, Missile Silo,
  §10A.4). Nothing else about a source is read after launch except its outbox (§5.3).
- **Personnel cap.** Personnel = troopers + support staff shipped + reinforcements landed − dead − sent home −
  deserted. The HUD shows it as Halo Wars shows population. Nothing else raises it.
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
  - **The guns used are debited from the snapshot.** The `LaunchSnapshot` holds the target's gun stock as a pool.
    Arming militia moves guns from that pool into the defender formations' hands, and each gun is released when its
    holder dies or surrenders. Salvage (§10A.7) draws only on what is left in the pool. The winner's half (§7.4)
    is of the guns released by the dead and surrendered. So a gun is counted once: armed, salvaged or captured,
    never two of these.
  - The rest are improvised, at quality 0.3.
- **Regulars.** A colony that kept staffed barracks or bases from before it seceded fields troopers from them
  exactly as the player does (quality 1.0). The independent governor never builds military, so this only
  happens to colonies that had it.
- **Emplacements.** Each staffed Gun Emplacement is a static `emplacement` formation at its nearest objective.
- **Port holders** (standoff colony): `ceil(spaceportJobs × 0.5 + population × 0.03 × r)` at quality 0.5, starting
  morale 0.4. They are the opening garrison only. While the port is contested, sympathisers join from the town in
  waves, up to the militia formula, so a large standoff colony is a real fight.
- **All of these are sized once, at launch,** from a `LaunchSnapshot` of the target. Waves draw on that
  snapshot's pool, not on the live colony (§5.3). The snapshot is the whole list of what the operation knows about
  the target:
  - population, mood, hunger, severity, wish, spaceport jobs, staffed military sites;
  - stocks: ore, steel, rations, ammo, guns (the pool above) and missiles, plus its stock cap and each storage
    site's `storageBonus` share (for salvage, §10A.7);
  - a staffed Missile Silo, if any (§10A.11);
  - power: total output, the life-support draw, and each plant's output (for "Cut the town's power", §7.5);
  - the frozen battle map's inputs (§8.2), including the **launch footprint set**: 2D footprints of every hull,
    pad, road ribbon, parcel and plat lot, and the positions of emplacements, life-support sites and terraforming
    towers. It is taken from phase 1b-ii, because the base layout, the post and the strike rules all need it
    (§10A.3, §16).
- **The defender does not build in v1** (Q30). The town is its base, frozen at launch. Its counterpart to the
  player's base is **Dig in** (from phase 1b-ii): a defender formation that stays at one objective for 30 s adds +0.1 to that
  objective's `F_def`, up to +0.3, within the 2.2 cap, and loses it when it moves (§6.2).
- **A defender power (phase 7, Q36).** A target whose `LaunchSnapshot` shows a staffed Missile Silo and missiles
  in stock may strike the player's base every 2 operation days. The missiles come from the snapshot's pool, which
  the operation debits itself; each debit is posted to the target's inbox as a write, with no confirmation to wait
  for. Each AA turret has a 50% chance to intercept, rolled with `combat_rng(seed, 'intercept', strikeSeq,
  turretId)` (§10A.11).

**Worked scale:**
- A starter town under its governor: about 64 settlers, mood 0.2, severity 0.5, so r ≈ 0.45. It fields about 8
  militia, 2 of them armed, and nothing else: Barracks unlock at 300 and Gun Emplacements at 400
  (`city_building_spec.dart:448-460`), and the governor never builds military. Stepping the resolver, 15 troopers
  break them in about 45 s.
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
planned → mustering (0.25 day) → transit (0.5 day same body, 1.5 days other body) → landing → core deploys
        → engaged (+ base step) → resolved { won | lost | withdrawn | ceasefire | rejoined | overtaken }
        → aftermath (the base becomes a garrison post, is struck, or is abandoned, §10A.15)
```

- **Days** are operation days: 120 s on the operation clock (§5.3), the length of `CityLoyaltyTuning.daySec`.
- **Transit** is fixed. It is not real flight time (§2).
- **Mustering** debits troopers and kit immediately, so the decision costs something. A save taken before launch
  does undo it; what a reload cannot do is reroll the same launch (§6.5).
- **Landing** is abstract in phases 1–2 and always succeeds. From phase 3 a real force lander flies on airless
  bodies (§9.3).
- **Core deploys** (from phase 1b, unless the player shipped a light operation). The lead lander unfolds into
  the base core in 30 s, with its landing turret, at the planned LZ point (§10A.2). In phases 1b–2 this always
  succeeds. From phase 3 the core is the real lead lander: a crash loses it and everyone aboard, and an intact
  landing away from the point adds 1 s per 10 m while the crew haul the kit over. Without a core, the operation
  fights base-less, as phase 1 does, until a spare core kit is deployed.
- **Engaged** is fought objective by objective (§6), abstractly unless the player has joined one objective live
  (§8). The base step (build lines, production, upkeep, resupply, powers) runs beside the resolver in every 1 s
  step (§10A.8).
- **Supply runs** during an operation reuse §7.1's garrison-run handshake: every 3 operation days by default,
  less with supply pads, a source ships Materiel and kit to the base (§10A.6). They are abstract arrivals in every
  phase, timed on the operation clock from the moment the request is posted, and drawn from phase 3 as a descent
  effect, never as a Vessel (§9.3).
- **Overrun and re-establish.** If the defender holds the LZ at control ≤ −0.9 for 60 s, or the core's hit points
  reach 0, the base is overrun (§10A.2). Supply runs and resupply stop. A spare core kit can then be deployed at
  any objective the attacker holds at control ≥ 0.9, which becomes the new LZ, outpost-sized (§10A.2); until one
  is, §5.4's kit rule runs.

### 5.3 Where it steps

**One owner, one clock.** The whole operation, abstract objectives and the live bubble alike, steps in one
world-level `_combatPhase`. Colonies never step it.

- **Ownership.** Operations live in a world-level `OperationRegistry`. It and the `CommandInbox` are injected
  through `AdvanceSimulationTick`'s constructor, so every host gets them: `FlightSession` (which keeps the
  registry across `rebuildTick`, `flight_session.dart:141-161`), `SimHost` (`sim_host.dart:83-117`), and tests.
  `SimHost` wires no CitySim colonies today (§2), so no operation can launch there; it gets the registry only so
  the constructor stays uniform.
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
- **Inside step 3, per 1 s operation step,** in this order: arrivals due (supply runs, reinforcements, salvage,
  strikes in flight); the base step (unpacking, power, build lines, production, upkeep, resupply); the doctrine
  fills idle build lines; the overhead gate for assigned vessels; powers (queued, then the auto policy); the
  resolver (strike impacts due first, then losses with the counter table); spotting; end checks (§10A.8).
  Commands drained in step 1 are validated and applied before the tick's operation step.
- **The battle warp ceiling (§10A.12), two levels.** Above 25×, operation time runs slower than world time by
  design. That is harmless while the operation is abstract, but not while world-time physics feeds it. And above
  `railsWarpThreshold` (4×) every vessel that is not landed goes onto Kepler rails, thrust or not
  (`simulation_clock.dart:42-43`, `advance_simulation_tick.dart:305-307`), so a lander's guidance does nothing.
  - **Lander level.** While any operation has **a real lander between spawn and touchdown** (the force landers,
    the core, reinforcement landers; §9.3), warp is held at or below the largest rung with `warpFactor` ≤
    `railsWarpThreshold`. On today's ladder that is **1×**. This is the honest cost of real landers: every descent
    is watched at 1×.
  - **Orbital level.** While an operation has **an orbital vessel assigned** and no lander is descending, warp is
    held at or below the largest rung with `tickDt` ≤ 0.5 s: **10×** on today's ladder (Q22 asks for a 25× rung).
    The vessel coasts on rails at 1× and at 10× alike, so 10× costs it nothing.
  - **One choke point.** Seven sites write `_clock.warpFactor` (§2), and warp-to-apsis rewrites it every frame
    with continuous values up to 1e6. So the ceiling is not a hook in `_stepWarp`. It is one clamp,
    `_applyBattleWarpCeiling()`, called every frame immediately before the tick loop (after the warp-to-apsis
    re-fit and the atmosphere lock), and once after a load. Under the ceiling it snaps any factor down to the
    largest ladder rung at or below both the requested factor and the ceiling, so every tick (0.02, 0.1 or
    0.2 s) divides 1 s and every 1 s step boundary is a tick end.
  - Under the ceiling, operation time equals world time. Warp is one global clock, so the ceiling binds the whole
    game while any operation holds it; with none holding it, warp is free.
- **`SimHost` substeps are deferred.** The bridge host steps at `fixedStep: 1.0` (`sim_host.dart:109`), over the
  0.5 s cap, but it has no CitySim colonies, so no operation can run there. When a host with colonies exists it
  must subdivide its step to the ceiling's tick; until then the work would be dead code.
- **What it reads from colonies.**
  - At launch only: a `LaunchSnapshot` of the target (§4.2) and a `SourceSnapshot` of each source (§4.1), taken
    when `LaunchOperation` applies.
  - After launch: nothing but outbox events. A colony posts them from its own tick, in `_cityPhase`, when its
    allegiance or stage changes (seceded, standoff over, rejoined, occupied colony re-seceded), when a site an
    operation depends on is removed (`clearParcel`, a disaster), when a garrison's upkeep goes unpaid, and when
    a source ships a garrison supply run (§7.1). Events are rare and discrete, and §7.6 says what each one does.
  - **Quantity confirmations** ride the same outbox: supply-run and reinforcement amounts, salvage from the target
    (§10A.7), and the stock debited for `ArmVessel` rounds (§10A.12). **None of them sets a time.** Every arrival is
    fixed on the operation clock when `_combatPhase` posts the request: arrival = post µs + a fixed transit. Every
    transit is at least 60 s, longer than the worst hold lag (15 colony seconds is at most 37.5 s of operation time
    under the slowest time dilation, ×0.4). The confirmed amount fills the arrival when it lands. The doctrine
    plans from the posted manifest, never from a confirmation. A confirmation still missing at the arrival step is
    a bug: it is asserted in tests, and the arrival waits for it rather than landing empty.
  - Rebel missiles are not confirmed at all: they come from the `LaunchSnapshot`'s pool (§4.2).
  - This is the full list. Garrison upkeep is paid in the garrisoned colony's own tick from the garrison stock,
    because a garrison is colony state once the operation ends (§7.1, §7.2).
- **What it reads from the world (new, from phase 3).** The authoritative tick-end state of vessels **assigned to
  an operation** by id. That is world state, not colony state, and two adapters read it:
  - `lib/domain/combat/landers/lander_watch.dart` (phase 3): the operation's own force, core and reinforcement
    landers: touchdown, crash or `unrecoverable`, and the landing offset from the planned point (§9.3);
  - `lib/domain/combat/powers/overhead.dart` (phase 3b): orbital support, one boolean per vessel per 1 s step
    (§10A.12).
  The resolver never imports vessel or orbit code.
- **What it writes to the world** (both inside step 3, in this order, and both listed in the hygiene rule, §12):
  - `Vessel.releaseOrdnance` when a strike fires (real-parts route only, §10A.12). `_combatPhase` runs after the
    vessel loop, so the lighter vessel moves on the next tick;
  - a crater `TerrainBrush`, appended at the impact step through `powers/crater.dart`, only for craters clear of
    parcels and plat lots (§10A.12). The city loop runs after, in the same tick.
- **Writes into colonies** (attacker deaths at home, returning troopers, `siteFactor` changes, war weariness,
  defender and civilian dead) go into that colony's `ColonyCombatInbox`. It is drained at the start of
  `_cityPhase` (`:511-525`), before `city.advance`, so the E8 ledger receives deaths before `agents.advance` takes
  them. A frame-held colony drains its inbox when its held tick replays, in order.
- **The documented lag.** A held colony's outbox events reach the operation up to `maxHeldCityS` (15 colony
  seconds) later than they would inline. Two kinds ride on them:
  - discrete exits (§7.6), whose kind is the same either way;
  - quantity confirmations, which set no time and always arrive before the fixed arrival they fill (above).
  The frame-hold test pins exactly that: the same ledgers and band on a fixture with no lifecycle event, **including
  one with a supply run in flight from a held source**, and the same exit kind on one with an event. "Hold lag ≤
  `maxHeldCityS`" is added to the Agent Traffic contract as a published semantic (§18).
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
- **Lost:** every attacking formation is broken or dead, or kit has been at zero for 2 operation days. An overrun
  base stops supply runs and resupply until a core is re-established (§10A.2), so a base that stays lost reaches
  the kit rule.
- **Withdrawn:** the player orders it. Survivors return, and a fighting withdrawal costs 10% of what is left.
- **Ceasefire:** no decision after 10 operation days (20 minutes at 1×). Troops come home and nothing changes hands.
- **Overtaken:** the target's allegiance or stage changes under it (§7.6).

Outcome bands, in Total War: Warhammer II's wording:
- Decisive, Close or Pyrrhic victory. Pyrrhic means attacker losses ≥ 50%.
- Valiant, Close or Decisive defeat.

Every exit also decides what happens to the base: it becomes a garrison post, is struck and shipped home, or is
abandoned to the winner (§10A.15).

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
| `kitDays` | ammo and rations carried. Renamed from `supplyDays` so that "supply" means only supply runs (§10A.6) |
| `at` | objective id, `transit`, `lz` or `reserve`. An attacker `reserve` formation has not landed yet: it waits aboard the transport in orbit until a reinforcement lander or a hot-drop brings it down. A defender `reserve` formation is in the town, uncommitted. Neither is the LZ reserve personnel pool (§10A.6) |
| `homeColonyId`, `homeSiteId` | where the members live, and where their deaths are charged |
| `counterClass` | `INF` (infantry, regular, militia), `EMP` with a specialisation (HMG, AT, AA), `ARM` (phase 6), `AIR` (phase 7); read by the counter table (§10A.9). Base modules are the target-only class `STR` |
| `abilityUntilUs`, `cooldownUntilUs` | the active ability's end and its cooldown, integer µs on the operation clock (§10A.10) |
| `moduleRef` | for a base turret: the socket it mans (§10A.4) |

Strength: `S_f = count × P × quality × M(morale) × Sup × Env`
- `P`: infantry, regular and militia 1.0; emplacement 3.0 (static, defence only); armour 6.0; gunship 8.0.
- `M(m) = 0.25 + 0.75 m`.
- `Sup` is 1 with ammo and 0.35 without. Running out of rations drains morale instead. A base turret's `Sup` is
  also multiplied by the base's power ratio (§10A.6), floored at 0.35.
- `Env`: armour ×0.7 above roughness 0.6 (`TerrainControl.roughnessAt`).
- **Base turrets are attacker `emplacement` formations**: count = crew (2), P 3.0, quality 1, static, defence
  only. A turret whose crew are all dead or wounded is destroyed. Their fortification goes to the attacker's side
  (`F_att`, §6.2).
- **Resupply.** Formations at a held base site, or one hop from it (§6.2), refill `kitDays` toward 3 at 1 day per
  30 s from the base stock (§10A.6).
- **Formations from the base.** A barracks pod forms new `infantry` formations from the LZ reserve (§10A.4), at
  its site, and sends them to the rally point by the usual march rules. Each member keeps the `homeColonyId` and
  `homeSiteId` from its muster, so a death is still charged home. From phase 6 the vehicle bay forms `armour`
  formations the same way.

### 6.2 Objectives

A combat-owned `ObjectiveGraph` is built at plan time from colony state:

| Objective | From | Notes |
|---|---|---|
| Port | `landingPads()` parcels, **excluding airfields** | the phase 1 goal. `landingPads()` yields every `SiteKind.pad` (`city_sim.dart:5505-5509`), and the Airfield is one (300 × 3,200 m, `city_building_spec.dart:464-469`), so the graph filters by type |
| Airfield | an Airfield site | its own objective from phase 7 (gunships), never the Port |
| Seat | the seat of government | no such building exists (Q8); until answered, the largest civic building near the centre |
| Life support | the `isLifeSupport` cluster | taking it pushes an independent colony below self-sufficiency, toward the dependency petition: a siege route to surrender |
| Power | the largest generator | while held: +40 kW to the base, defender emplacements' `Sup` × 0.5, and the "Cut the town's power" order (§10A.7) |
| Depot (new, phase 2) | the target's storage sites (Warehouse, Silo Cluster, Freight Yard) | taking it posts a salvage requisition to the target (§10A.7) |
| LZ | the attacker's landing zone, where the base core stands (§10A.2) | losing it overruns the base and cuts supply runs and resupply. Value = 1 + 0.15 per module + 0.25 per tier, so the defender AI's `value × threat` allocation counterattacks a growing base |

The graph stays at 8 nodes or fewer: Port, Airfield, Seat, Life support, Power, Depot and LZ. Outposts (§10A.3)
attach to the objective they stand beside and add no node.

Each objective also carries:
- `value`; an outpost adds +0.25 per module to its objective's value;
- **fortification, one value per side, each in [1, 2.2].** The resolver applies each against the side that
  attacks into it (§6.3), so a side's own works only ever protect that side:
  - `F_def` protects the defender: +0.25 per defender emplacement, +0.3 for a bunker, +0.2 on rough ground at a town
    objective, +0.3 if a town building stands on it, and +0.1 per 30 s a defender formation has dug in there, up
    to +0.3 (§4.2). It divides the attacker's damage to defenders and the attacker's control push.
  - `F_att` protects the attacker: +0.25 per base turret, +0.3 for the base core or an outpost's first module, +0.3
    at the LZ once the base is a Fortress, and +0.2 on rough ground at the LZ. It divides the defender's damage to
    attackers and the defender's control push. It is 1 wherever no base stands, so phase 1 is unchanged.
  - An earlier draft summed both into one `F` that only ever divided the attacker's damage, so every base turret
    protected the rebels raiding it. The calibration table pins a "defender raid on a Fortress LZ" row (§6.3).
- width `W = min(24, 6 + 4·sqrt(footprint m² / 10,000))` in power units. Every real Port caps at 24: the smallest
  is one 900 × 900 m Spaceport (81 ha, `city_building_spec.dart:533-542`), which gives 42 uncapped. The LZ's
  footprint is the turret ring's disk (radius 75 m, about 1.8 ha), so W ≈ 11. Uncapped, an Airfield would be about
  45 and a Military Base (1,600 × 1,600 m, `city_building_spec.dart:452-456`) about 70;
- **clipping:** an objective larger than the battle square (§8.3) is clipped to the sub-area nearest the LZ that
  fits, and its footprint for `W` is the clipped area;
- control `c ∈ [−1, 1]` (defender −1, attacker +1).

March times between nodes come from straight-line distance and `GroundVehicleMovement.speedOnTerrain`
(`ground_vehicle.dart:47`), with a combat-owned Dijkstra on at most 8 nodes.
- **Edges.** Each node is joined to its 2 nearest nodes (the union of both directions, ties by id), and the LZ to
  the nearest goal objective. It is not a complete graph.
- **One hop** means an adjacent node whose march time is at most 120 s. Resupply (§6.1), spotting (§10A.13) and the
  defender's threat (§6.4) all use this, so on a small town they reach a neighbour, not the whole map.

### 6.3 The resolver

The resolver works in fixed 1 s steps of operation time (§5.3), taken from an integer-µs accumulator so any
partition of dt runs the same steps (the `traffic_time.dart` pattern, copied):

```
for each objective o with both sides present, in id order:
  E_A = min(Σ S_f attackers at o, W_o)          // width cap: no zerg rush
  E_D = min(Σ S_f defenders at o, W_o)
  fuzz = 1 + 0.15·u,   u = rng(seed, o, floor(t / 30 s)) ∈ [−1, 1]
  strike impacts due at this step land first (§10A.12)
  pairwise loss sharing with the counter table M (§10A.9); unit: MEMBERS removed (killed or wounded):
    e_i = S_i · E_A / ΣS_A               // attacker i's width-capped share, Σ e_i = E_A
    e_j = S_j · E_D / ΣS_D               // defender j's share
    loss_j = α · fuzz / F_def · dt · Σ_i e_i · (S_j / ΣS_D) · M[c_i][c_j]          defender formation j
    X_k    = α · (2 − fuzz) / F_att · dt · Σ_j e_j · (S_k / ΣS_A) · M[c_j][c_k]   fire aimed at attacker k
    m_s    = σ_o · Σ_j (e_j / E_D) · M[c_j][STR]       // share of that fire the base soaks
    loss_k = X_k · (1 − m_s)                                                         attacker formation k
    hp_target −= m_s · Σ_k X_k                          // member-equivalents, one module at a time (below)
    σ_o = structureShare = 0.25 · H_o / (H_o + N_o)     H_o: module hp at o; N_o: attacker members at o
    α = 1/185 per s
    fire is redistributed, never reduced: the base takes exactly what the attackers are spared
    with M ≡ 1, σ = 0 and F_att = 1, Σ_j loss_j = α · E_A · fuzz / F_def · dt and
    Σ_k loss_k = α · E_D · (2 − fuzz) · dt: the rule is unchanged where there is no base
  per formation:
    fractional casualties accumulate; whole members are removed, remainder carried
    half of those removed are wounded, half dead
    morale −= 1.5 × (removed this step / members at engagement)
  control:  a = E_A/F_def, d = E_D/F_att;  dc/dt = κ · (a − d) / max(a, d, ε)   κ = 1/120 per s
  collateral_o += γ_ROE · (0.1·E_small + 1.0·E_heavy) · dt              (§7.5)
every formation:
  morale +0.002/s out of contact, +0.0005/s while its side holds the objective, −0.0005/s with rations out
  below 0.35 pinned (holds, will not advance); below 0.2 broken; rallies at 0.45
  broken: an attacker formation falls back to the LZ (at = lz) and rallies there, 2× with a barracks pod; one
    left with fewer than 4 members disbands into the LZ reserve pool (§10A.6). A defender formation falls back
    to its town reserve (at = reserve)
side morale = strength-weighted mean; defender below 0.15 surrenders (captured, returned alive)
```

- **Calibration, computed by stepping these rules at 1 s.** Take two equal 16-strong trooper formations at a real
  Port: quality 1, morale 0.8, `F_def` = `F_att` = 1, fuzz 1, W = 24 (§6.2), so the width cap does not bind (each side starts at
  S = 13.6). With whole-member removal, each side's morale falls below 0.2, broken, at its 7th member removed (44%),
  at **174 s** (about 1.5 operation days, 3 minutes at 1×). A fair fight therefore ends by breaking there. An
  earlier pin of 182 s assumed a "1 ha port" with W = 10, which no real Port is. The earlier draft's α = 1/450
  gave about 443 s. Read as strength rather than members, it gave about 264 s, which is why the unit is now
  stated. A full control swing at total dominance takes 240 s (κ, unchanged).
  - Sized from this: the 60 s hold is about a third of a fair fight; the 10-day ceasefire is about 7 fair fights;
    reinforcement waves (45 s, §10.2) arrive about a quarter of the way through one.
  - **Base rows** (phase 1b): "defender raid on a Fortress LZ" (the raid costs the defender more than the same raid
    on open ground, because `F_att` is 2.2 there); "a full-width raid on a Station LZ knocks its first module
    offline in 1–3 fair fights"; and "one cheap module lowers attacker losses by no more than its own hp".
- **How the base soaks fire.** σ grows with the base's share of what stands at the objective, so one cheap
  Stores module (2 hp) beside 16 troopers takes under 3% of the fire, not 25%. The share falls on one module at a
  time: the front socket first (nearest the enemy heading; the lowest socket index while sockets have no
  positions), and the core last. Turrets are formations and take their own share of the rest. Hit points are in
  member-equivalents: 1 is one trooper, 100 live hp (§8.4). At a Station LZ (the core and 5 modules, 16 hp) held by
  10 attackers, a full-width militia raid (E_D = 10, M[INF][STR] = 0.5) puts about 0.7 member-equivalents a fair
  fight into the front module before `F_att`, so a 2-hp module goes offline (below 50%) in about 1.5 fair fights,
  and turrets slow that further. The core (6 hp) is last in line, so in practice
  the control hold overruns a base long before the core's hp reaches 0. The hp trigger matters for live fights
  and for rebel silo strikes.
- **Tuning.** Every constant lives in a const `ResolverTuning`, including the `CounterTuning` table (§10A.9),
  `structureShare` and the strike constants (§10A.12). A calibration table test pins outcome bands for
  "squads × town size × resolve", and its first row pins the 174 s figure above.
- **Counters do not move the pin.** Phase 1 builds the resolver in the pairwise form from the start, with M ≡ 1
  everywhere, so its 174 s row is the figure above. A unit test checks the pairwise sums against the closed form
  (`α·E_A·fuzz/F·dt` shared by S) to 1e-12 on random pools. When phase 1b-ii gives the infantry and emplacement rows
  real values, the rows that contain emplacements are re-pinned deliberately in the same commit; the
  trooper-against-trooper row is unchanged because M[INF][INF] = 1.
- **What M never touches:** strength `S_f`, the width cap `W`, and control. Applied to `S_f`, the width cap would
  cancel a strong matchup.
- **Abilities and strikes** enter as timed multipliers on M rows and as impacts at their step (§10A.10, §10A.12),
  so the calibration harness covers them.
- **Randomness: stateless seeded rolls only.** The fuzz is a pure function of `(seed, objective, round)` through
  `lib/domain/combat/combat_rng.dart`, a copy of traffic's xoshiro128\*\* and FNV-1a pinned bit-equal by a test,
  following the `hash32.dart` precedent. The Halo Wars layer adds two more rolls of the same kind, each keyed:
  the strike kill `(seed, 'strike', seq)` and the AA intercept `(seed, 'intercept', strikeSeq, turretId)`. Nothing
  keeps RNG state.
  - The seed is `fnv1a32(targetColonyId, opId)`. `opId` comes from the saved `nextOperationId` counter, so the
    tick the player launches on does not change it. Saving, launching, reloading and relaunching a tick later
    gives the same seed. (The earlier `launchTick` term let that reroll it.)
  - The round index counts from the operation's own clock, so the launch tick does not shift it either.
  - Never `math.Random`. Never `damageBuildings`, `flattenOne` or the fire spread.

### 6.4 Abstract AI

- **Defender:**
  - every 30 s of operation time, allocates formations to objectives by `value × threat`, where threat is attacker
    strength within one hop (§6.2);
  - keeps one formation in reserve;
  - counterattacks when local `E_D/F_att > 1.5·E_A/F_def`, so a fortified LZ draws fewer raids, not more;
  - feeds contested objectives in waves from the militia pool sized at launch (§4.2);
  - digs in wherever it holds (§4.2), and uses Rally by fixed rules (§10A.10);
  - builds nothing in v1. The LZ's value grows with the base (§6.2), so the allocation raids a growing base on its
    own.
- **Attacker formations without orders** advance along the graph to the nearest goal objective. They stop and
  hold when `E_A/F_def < 0.8·E_D/F_att` and wait for the reserve, which the powers policy hot-drops (§10A.8). They use their ability by fixed rules: charges when
  engaged against an emplacement with ammo in stock, jump jets on assault moves.
- **The base doctrine** (Balanced, Hold, Push or Manual, picked in the planner) fills idle build lines, trains
  squads, and casts powers under the powers policy (§10A.8). It runs in every operation, attended or not, so an
  auto-resolved operation builds the same base a watched one does.
- **Player orders override** all of these (§10.1). A player build order goes ahead of the doctrine's next pick.

### 6.5 Preview

- When the planner opens, it runs the same resolver headless from now to resolution, for 32 seeds, **at the real
  1 s step**. An earlier draft used 5 s steps on the grounds that the resolver is linear inside a round. It is
  not: the width cap, whole-member removal, per-step morale and the 0.35 / 0.2 / 0.15 thresholds all depend on
  step size, worst near surrender.
- **One budget.** A 10-day ceiling is 1,200 steps × 32 seeds = 38,400 steps. It runs as counted steps spread over
  frames, at most 2 ms a frame and done within about a second: about 120 ms of CPU in all. That leaves **about
  3 µs per step** for the resolver, the base step and the doctrine together, which a handful of objectives and
  formations should allow; phase 1 measures it. If a base or orbital support pushes a step past that, the preview
  drops to 16 seeds, then 8, and says so. The histogram fills in as seeds finish. It never touches sim state.
  (§11.5 carries the same row; an earlier "≤ 20 ms once" contradicted this.)
- **It runs the base too.** The chosen doctrine and powers policy are part of the preview, so the histogram
  includes the base. It assumes every supply run ships its full manifest, because what a source will have later
  is unknown. An orbital strike counts only if "Orbital weapons free" is ticked and a vessel is assigned. The
  preview then evaluates the same overhead gate the real run uses (§10A.12), at each 1 s step, on the vessel's
  current conic propagated in closed form. It never uses the UI's window predictor. Under the warp ceiling,
  operation time equals world time, so this matches the real run as long as the vessel does not burn.
- It shows:
  - the distribution of outcome bands;
  - the likely duration;
  - p10–p90 ranges for own, rebel and civilian casualties.
  - When the median duration is under 1.5 operation days (one fair fight), the planner shows a **light
    operation** with no base beside the base option, each with its own histogram: "This fight will likely be
    over before a base is up. Ship light, or bring a base to hold the port afterwards?" It is a trade, not the
    default: the base still becomes the garrison's post after a win (§10A.6, §10A.15).
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
    the amount to its outbox, and the amount lands in the garrison stock through the target's inbox at the
    arrival time fixed when the debit was posted (post time + transit, §5.3). Unpaid, 10% of the garrison a day goes home alive (§7.6).
  - Withdraw it and the old rule applies again.
  - **The base becomes the garrison's post** (from phase 1b-ii; §10A.15). The player picks which modules stay,
    with `BaseOrder(setPost)` at any time before the end (default: every core-ring module). They
    are stored in the garrison block, never as CitySim buildings, so they add no jobs, power or safety to the
    rebels. What is left of the base stock becomes the garrison stock. A kept supply pad shortens garrison runs
    from 3 days to 2 and is where they land. A kept field hospital heals garrison wounded on site. Kept turrets
    burn 10% of their engaged ammo rate from garrison stock, and an unpaid post goes offline before any trooper
    goes home.
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
- **The garrison post** (§7.1, §10A.15) carries over: each kept turret adds its emplacement strength (3.0) to
  `garrisonStrength`. That raises suppression, which needs the secession lane's sign-off (§18). A kept barracks
  pod lets the garrison rotate its wounded home without shrinking.
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
- **Either way,** survivors return home, and war weariness does the rest. The base is abandoned: the target takes
  half of the base stock and half of the modules' Materiel as captured goods through its inbox, and the rest is
  lost (§10A.15).

### 7.4 Casualties, materiel, war weariness

- **Attacker dead:** charged to the home colony through the inbox and a `recordWarDead(n)` helper that writes the
  way `city_sim.dart:1804-1810` does: the E8 ledger when citizens own the population, otherwise the scalar.
- **Defender and civilian dead:** charged to the target the same way, plus corpses, because they die in town. The
  disease cascade that follows is real, and its tuning is watched (§17).
- **Surrendered defenders** come back as living population.
- **Base crews** are colonists: a crew member killed is a death charged home exactly like a trooper.
- **Materiel:**
  - ammo and rations are spent from carried kit each day of fighting;
  - a dead trooper's gun is lost;
  - the winner takes half of the guns released by the loser's dead and surrendered (§4.2). It never takes guns
    still in the snapshot pool; those are salvage.
  - **The materiel ledger** (from phase 1b) records, per source and per commodity: mustered and shipped on runs;
    in flight; spent (builds, upkeep, abilities); converted in and out by the workshop; refunded when the base is
    struck; captured by the target when it is abandoned or overrun; lost; and salvaged or captured from the
    target. A target-side ledger records the snapshot's guns armed, salvaged and captured. Both conservation
    equations are in §12.
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
  - [0.5, 1.0): the site is non-operational (its `siteFactor` damage term is 0, §4.1) until repaired with ore
    from its site sheet;
  - 1.0: destroyed (phase 6+, Standard or Heavy ROE only), through `clearParcel`-level cleanup, which handles
    deliveries, craft, the lander pad, agents and site access. Before phase 6, and under Restrained always, any
    severity of 1.0 or more is clamped to just under 1.0, so it is non-operational.
- **Never the cell-grid helpers** or fire spread.
- **Rejoining terms.** While terms ban demolition (`city_term_guard.dart`), the planner refuses Standard and
  Heavy ROE and says why. Restrained never destroys.
- **Never targeted:** life-support sites under Restrained and Standard, and terraforming towers always. Destroying
  shared air is an act against every colony on the body (Q17).
- **The new verbs obey the same rules** (Q24, Q31):
  - **Orbital strikes** (§10A.12). The aim point is a defender emplacement's site (from the launch footprint set,
    §4.2) or an objective's centroid. Under **Restrained**, a strike may aim only at a military site (a Gun
    Emplacement, Barracks or Military Base), and only if no *civilian* hull lies within 3·D + CEP of it; military
    hulls are not protected by the buffer. Under **Standard**, it may also aim at the Port, Power, Airfield and
    Depot objectives. Under **Heavy** (phase 6), also the Seat. Never within 3·D + CEP of a life-support site or a
    terraforming tower. Refused outright while rejoining terms ban demolition (`city_term_guard.dart`). Abstract
    formations have no positions, so "militia in the open" is not a target; an area strike always aims at an
    objective.
  - **AT turrets** at an outpost inside the town count as heavy weapons for collateral, and are refused under
    Restrained ("small arms only inside the town").
  - **Salvage requisitions** from a rebel Depot objective cost the town mood; under Restrained they take only ore and
    military goods.
  - **"Cut the town's power"** is Standard ROE only. Power is pooled colony-wide, so "depends on that plant" is
    tested as a number: it is refused if, at launch, the colony's power output minus that plant's output would be
    below its life-support draw (life support would fall under full power, `city_sim.dart:1453-1469`).
  - Every refusal says why, in the planner and on the command card.
- **Craters: from phase 3b, strike craters only** (moved up from phase 6 for the orbital strike, §10A.12). They
  are owned by the operation, quantised (each new one swallows the last at that site, the drill rule), capped at
  16 per battle, keyed by content (§10A.12), saved with the operation and re-applied idempotently on load. **A
  crater that would touch a parcel or plat lot emits no world brush**: it exists only on the battle raster and as
  a render-side scorch for the operation's life. So the colony's terrain shaper never levels a new pad into a
  crater, standing buildings never sit in one, and the colony ground raster is not dropped. Phase 6 adds craters
  from heavy weapons under the same rules.

### 7.6 Lifecycle: garrisons and deployed formations

Every allegiance or stage change of the target or a source, and every loss of a home building, has a defined
exit. The colony posts the event from its own tick (§5.3, outbox); the operation or the garrison acts on it.
Nobody is ever silently lost.

| Event | Deployed formations (operation running) | Port garrison | Occupation garrison |
|---|---|---|---|
| Target's standoff ends by recovery (`_release` path, `city_loyalty.dart:574`) | operation ends **Overtaken: the rebels stood down**; all come home | its job is done; comes home; upkeep stops | n/a |
| Target secedes (standoff → independent) | operation ends **Overtaken: independence**; all come home alive, kit lost; the base is **abandoned** as on a loss (§10A.15); the target becomes a phase 2 Force target | **expelled**: comes home alive, its carried stock is lost; the port closes as the independent colony's | n/a |
| Target rejoins (petition or negotiation accepted) | operation ends **Rejoined**; all come home | n/a | n/a |
| Occupied target meets the secession condition (level ≤ 0 or 3 revolts) | n/a | n/a | **expelled**: comes home alive; next tick the colony takes the plain colonial rules (secede or standoff) |
| Player withdraws the garrison | n/a | comes home; seizure rule applies again | early withdrawal (§7.2) |
| Garrison upkeep unpaid | n/a | 10% a day goes home alive | 10% a day goes home alive |
| Source colony secedes | its formations **desert**: removed from the operation as living people of the now-independent colony, kit lost; notice "Troopers from X have gone home to an independent colony" | the same, for garrison members from X | the same |
| Source colony enters standoff | no change to deployed troopers; no new musters or reinforcements from X | no change | no change |
| Source home site removed (`clearParcel` `city_sim.dart:5834`, demolition, disaster) | stay in the fight; `homeSiteId` cleared; they return as plain residents; the colony drops the site's `siteFactor` entry | the same | the same |
| Target site an objective stands on removed by a disaster | the objective keeps its graph node (the ground is still there), loses its building fortification (+0.3) | n/a | n/a |
| Base overrun (defender holds the LZ at c ≤ −0.9 for 60 s, or the core reaches 0 hp) | every module is lost. Crews and the LZ reserve: half dead, the rest wounded. Wounded already at the base: half dead, the rest stay wounded. Survivors fall back with the nearest attacker formation, counted as its wounded or in flight to a new LZ, and cannot crew or form squads until a core is re-established. Half the base stock, unopened pallets included, is captured by the target through its inbox, half lost. Supply runs and resupply stop until a spare core kit is deployed (§10A.2) | n/a | n/a |
| Core lander crashes or is `unrecoverable` (phase 3+) | the core and everyone aboard are lost; the operation fights base-less until a spare core kit is deployed | n/a | n/a |
| Outpost razed (c ≤ −0.9 for 60 s at its objective) | its modules are lost; crews take losses | n/a | n/a |
| Source colony secedes (base rows) | that source's crews desert like its troopers, so their modules go offline until re-crewed; its queued supply runs are cancelled; Materiel already landed stays, because it was moved; home gates are recomputed, so new builds it alone unlocked lock (built ones keep running) | the same for post crew from X | the same |
| Assigned orbital vessel destroyed, landed, or out of the target body's SOI | orbital support is unassigned from the next step; notice "Orbital support lost: <vessel> has left the battle"; the warp ceiling lifts if nothing else holds it | n/a | n/a |
| Strike in flight when the operation ends | discarded; the round is lost | n/a | n/a |
| Reinforcement lander crashes (phase 3+) | the troopers aboard are lost (dead, charged home); its kit is lost; the source is not refunded | n/a | n/a |
| Source has seceded when struck goods go home | that source's share goes to "lost" in the materiel ledger; its people desert as above | n/a | n/a |
| The colony builds over a post module | n/a | checked once per colony day: the module packs up with a 50% refund to garrison stock, notice "The garrison moved its post to make room" (§10A.15) | the same |

- **Upkeep while deployed** stays "moved, not added" (§4.1): if the home site is gone, nothing moves back.
- **Captured** applies only to defenders who surrender (§6.3). The player's troopers are never captured in v1. A
  rout always reaches the LZ or dies trying.
- Each row here, and each exit row of §10A.15, is a test in the phase that introduces it (1, 1b-i, 1b-ii, 2, 3
  or 3b), on the fixtures in §12.

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
    as live units from the formations there. Turret crews are formation members, so they count against
    `liveCap`; module rows are structures, not members, and do not (at most 20, §8.4).
  - **While joined, the live rows own the objective's state.** Module hp, online state and turret crew are read
    from the live table by the base step (power demand, the doctrine's "socket free" and repair picks,
    resupply), never from a stale copy on the `Operation`. At each 1 s step boundary the bubble writes its
    changes back: module hp and online flags, turret crew counts, and the members killed or wounded since the
    last boundary. Those deaths enter the casualty ledger and are posted to the home colony's inbox in that same
    tick's step 5, so the personnel invariant (§12) holds at every step with live rows counted as formation
    members.
  - The rest wait as reserve waves. When a live unit dies, a reserve member spawns at the edge, outnumbered side
    first (Mount & Blade's battle-size rule).
- **Leaving:** the battle menu's Leave, focusing elsewhere, or a save (§13) collapse the fight back into pools.
  - Live counts become formation counts, and units under 50 hp become wounded (the per-step write-back above has
    already charged every death).
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

**Additions owned by the battle (new with the base).** The battle may add to its own copy of the map, and only
these things:
- **Base sockets** (§10A.3), laid out at launch from this map's 2D footprints (the launch footprint set, taken from
  phase 1b-ii, §4.2) and saved with it. **Every socket's
  footprint is blocked in the foot and wheeled layers from the first bake, built or not**: a fenced, sandbagged
  pad. So a module finishing never changes passability, and the cached flow fields (LRU 24) and the resumable path
  queue never need invalidating for a build.
- **Module hulls** on those sockets: `BuildingMassing.massFor` of the module's borrowed shell spec on a synthetic
  socket parcel (the `Parcel(id: 'archetype')` precedent), seeded `fnv1a32(opId, socketId)`, so it is pure and
  replays identically. Each stands on a flat pad datum equal to the mean raster height of the cells under the
  socket. A finished module changes only the cover bitmasks of adjacent cells (at most 16) and flushes the
  cached line-of-sight pairs whose segment crosses its box. A destroyed module leaves a 1 m rubble prism, still
  cover and still blocked.
- **Strike craters** (from phase 3b): analytic overlays from the operation's crater records, at most 16 (§10A.12).
- **Wrecks** (phase 6).

No addition emits a terrain brush into the battle's copy, and none takes a field sample. A test on the §12
fixture (where no colony builds during the run) asserts that `TerrainEditsRepository` changes during an operation
only by that operation's own keyed strike craters.

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
- **When it bakes.** From launch through transit: at least 0.75 operation days, about 90 s at 1×. The LZ, its
  socket cells, and the objectives go first. The bake is render-side work (it fills a cache, it changes no sim
  state), so frame time may schedule it.
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
- **Where the square sits.** One square per operation must hold the LZ's whole turret ring (75 m plus a 12 m
  socket, so 87 m from the LZ centre) and part of the goal. The goal is clipped to the sub-area nearest the LZ
  (§6.2), so the rule is: the LZ picker keeps only candidates whose ring fits and from which at least 100 m of the
  goal falls inside the square, and the square is centred between the LZ and the goal's nearest edge. A Port is
  at least 900 m across, so it is always clipped. Spike S item 6 checks that such a candidate exists at 1.2 km
  and at 800 m. The 600 m web square would usually fail it, but web has no live fighting in v1 (§9.1), so only
  the abstract base runs there.
- **Saved.** Once baked, the raster is saved quantised (u16, about 45 KB) with the operation. A reload then fights
  on exactly the ground it was baked on and skips the re-bake. The codec saves no terrain edits, so this matters.
- **No precision tile.** An earlier draft filled a 2 m tile around the player at up to 64 samples a tick. At
  0.5–0.7 ms a sample that is 32–44 ms in a 20 ms tick, before the 25-step catch-up loop
  (`simulation_view.dart:1976-1992`) multiplies it: 2–3 orders of magnitude over the ≤ 0.1 ms movement budget.
  Kerbs and grading steps come analytically instead, from the frozen map's road lift (R1) and the pad datums,
  added to the bilinear raster height. No field sample is taken during a fight.
- **Craters are never re-baked.** A strike crater (phase 3b) or a heavy-weapon crater (phase 6) is added on top of
  the raster as its analytic shape, permanently. At most 16 per battle, so this is cheap, and a cell's value never
  depends on when it was baked. The cover and passability of the nav cells under the crater's box are updated
  locally, and any cached flow field whose sectors include them is dropped and re-planned at replan priority, all
  inside §8.7's counted expansions. Craters are the only addition that can change passability (sockets are
  blocked from the first bake, §8.2).
- **Pad datums cost nothing extra.** Module plinths take the mean of the raster cells under each socket, so the
  base adds no field samples to the bake.
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
- **Kinds** (append-only): trooper, militia, regular, emplacement, **module** (a base structure: hp, hull ids,
  crew, offline flag; static, never moves). Later: buggy, APC, hover tank, lander proxy.
- **Base turrets** are one `emplacement` row each, HMG by default (AT launcher from phase 6, AA from phase 7).
  The row's hp is its crew × 100: damage past each 100 kills or wounds one crew member, and at 0 the turret is
  destroyed. So 4a needs no seat primitive; seats arrive with vehicles in phase 6. A turret row counts its crew
  against `liveCap` (§8.1).
- **Module rows** (the core included) are static: hp, hull ids, crew count, offline flag. They never move, scan
  or fire, so they cost only hit tests. They sit outside `liveCap`, at most 20 per base. hp is member-equivalents
  × 100 (§6.3).
- A module below 50% hp is damaged and offline until repaired (§10A.5); at 0 it is destroyed. The bubble writes
  module state back to the `Operation` at every 1 s boundary (§8.1), not only at collapse.

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

- **Damage** is `damage × armour factor`. There are no hit locations. **The armour factor is the counter
  table** (`CounterTuning`, §10A.9), read by weapon class against target class: the same const the resolver
  uses, so live and abstract cannot drift apart.
- **Strike blasts** (abstract from phase 3b; live once both 3b and 4a exist): units within the crater diameter D
  of the impact point die; within 3·D they take falloff damage and suppression +0.6. Hulls within D take
  `warDamageSite` severity 1.0, subject to ROE (§7.5) and clamped to non-operational before phase 6. Hits apply
  in the two-phase order below.
- **Abilities live** (phase 4a): the trooper's charge is the slow-round charge in the weapon table; jump jets
  are the EVA pack (§9.1).
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
  - the player's hitscan is outside the budget;
  - while a bubble is open, a defender squad in line of sight of an attacker squad is Known for fog of war
    (§10A.13).
- **Base modules need no path work.** Socket footprints are blocked from the first bake (§8.2), so a finished
  module flushes only the line-of-sight pairs that cross it and its adjacent cover bits. Craters are the one
  addition that invalidates flow fields (§8.3).

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
- **The base is in the harness** (from phase 4c). Each of the 3 reference scenarios gains a base variant running
  the Balanced doctrine, plus one with no base, one where an outpost opens, and (once phase 7 exists) one against
  a rebel silo with AA turrets. Abstract and live run the same build timeline, because builds are
  operation-level and the live layer only draws modules and fights over them. Abilities, counters and
  `structureShare` are in both layers. Fog never enters the harness: the resolver and both AIs ignore it
  (§10A.13).
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
| X | call reinforcements: the hot-drop power (§10.2) |
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
  - **The LZ centre is at least 400 m from every closed pad's point**, the point the 60 m impound radius is
    measured from (`_shuttlePadBF(city, pad.centroid, …)`, `advance_simulation_tick.dart:695`;
    `shuttle_cargo.dart:60`). Its turret ring must also lie off every parcel and plat lot, so the base never
    stands on the rebels' land (a 900 m Spaceport parcel reaches 450 m from its centre), and must fit the battle
    square with the goal (§8.3).
  - Lander ids are `force-<opId>-<n>`, from the operation's saved counter, never `_shuttleSeq`.
  - Outcomes are honest: a crash or `unrecoverable` loses the troops aboard, in both abstract and live modes.
  - Airless bodies come first. Landing stays abstract on bodies with air until the aero fix (§17).
  - **The lead lander, `force-<opId>-0`, is the base core** (§10A.2), Battlezone's recycler. A crash loses the core;
    an intact landing deploys it at the planned LZ point, 30 s plus 1 s per 10 m it landed away. The socket ring
    is laid out from the planned point, never the actual one, so landing scatter cannot move sim geometry.
  - **Reinforcement landers** (`BaseOrder reinforce`) come from the same factory: troopers and their kit,
    mustered at a source, landing at the LZ.
  - **Supply runs and hot-drops are not Vessels.** An earlier draft flew every supply run as a real lander. With
    a run every 1.5–3 operation days, that would hold warp at 1× for much of every operation, and its touchdown
    time would depend on the flight rather than on the fixed arrival the frame-hold rule needs (§5.3). So both
    are abstract arrivals in every phase, at a time fixed on the operation clock, and from phase 3 they are drawn
    as a render-only descent and touchdown at the supply pad or LZ (§11.3). Nothing is impounded, because nothing
    lands at a colony pad.
  - **While any real lander is between spawn and touchdown, warp is held at 1×** (the lander level of the battle
    warp ceiling, §5.3): above 4× it would be on rails, and its guidance would do nothing. On today's figures that
    means the opening landing and each reinforcement descent are watched at 1×.
- **Flying it yourself (phase 7):**
  - `PilotInputCommand` per tick replaces the per-frame `_pilot.apply` (`simulation_view.dart:1877`).
  - The player can fly the lander in, with an auto-land assist through `landingTarget`. Touchdown turns the pilot
    into a trooper.
  - Gunship passes from an Airfield, and missile strikes from a silo colony (missiles finally get a use), are
    commander powers; §10A.11 defines their effects. The orbital strike is one too, and arrives earlier, in phase
    3b (§10A.12).
  - **Strikes are never flown Vessels** (§2 traps): the round's flight and impact are resolved in `_combatPhase`.
  - A landed lander is a *lander proxy* row: a respawn point the enemy can destroy, like Battlezone's recycler.
- **Combat damage is separate from `FlightCheats`.** Destruction cheats default on (`flight_session.dart:44-46`).
  If combat rode them, units would be unkillable or the cheats would mean two things.

### 9.4 Death and redeploy

1. A 3 s death camera on the third-person boom.
2. A **REDEPLOY (n troopers left)** modal, following the VESSEL LOST precedent
   (`simulation_view_debug_panel.dart:22-78`).
3. After 10 s, the player respawns at the base core, an outpost, or a lander proxy as the next member of an
   attacking formation. That costs a colonist.

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
  - use an ability (`UnitAbilityCommand`, §10A.10).
- **Base and power commands** (from phase 1b, §10A, §12): `BaseOrderCommand` (build, cancel, demolish, upgrade,
  specialise, repair, open outpost, set doctrine, auto-build, assign crew, form squad, set rally, set manifest,
  reinforce, redeploy core, set post), `CommanderPowerCommand` (supply drop, Medevac, hot-drop, orbital strike,
  and the phase 7 call-ins; it replaces the earlier "call a strike" verb), and `AssignOrbitalSupportCommand`
  (phase 3b). Recon is not cast: it is passive while an assigned vessel is overhead (§10A.11).
- **Where:** from the operations drawer, and by clicking objective markers under the **battle camera** (phase 3).
  They mean something with zero units drawn, because the pools are real. The withdraw verb ships in phase 1, and
  the drawer's Base tab in phase 1b. From phase 3, sockets on the battle camera are clickable and open the Base
  tab's module list for that socket. The command card's build page replaces it in phase 5.
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
- `X` calls a reinforcement wave from the reserve: the **hot-drop** power (§10A.11). It lands at the LZ after 45 s
  (30 s with a supply pad), with a 90 s cooldown. It is an abstract arrival at a fixed time, drawn as a drop pod,
  never a Vessel (§9.3). It may instead target any
  objective the attacker holds; away from the base core it lands with **deployment fatigue** (morale starts at
  0.5, and its M row is ×0.75 for 10 s), Halo Wars 2's Blitz rule.
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
- **Halo Wars verbs on keyboard and mouse** (phase 5). Halo Wars' controller verbs, mapped to keys that are free in
  `_simKeys` today and in this plan's bindings (§2). Ctrl+1–9 groups already fill Halo Wars 1's missing control
  groups. All of these are defaults in the rebind table (§10.4, Q33):

  | Halo Wars verb (pad) | Command view default |
  |---|---|
  | All squads on screen (RB) | **Y** |
  | Whole force (LB, or RB hold) | **Y Y** (double-tap within 300 ms) or **Shift+Y** |
  | Cycle the sub-selected kind (RT) | **U**; the card highlights the kind whose ability fires |
  | Ability of the current kind (Y) | **R**, then LMB on a target if it needs one. R is reload only in first person, a separate context |
  | Jump to base, then cycle sites (D-pad left) | **F1**: the base core, then outposts; selects the base |
  | Cycle squads, idle first (D-pad down) | **F2** |
  | Last alert (D-pad right) | **F3**; the alert ring holds 8 |
  | Rally point (Halo Wars 2, D-pad up) | **L**, then LMB on ground or an objective; or RMB with the base selected |
  | Powers (D-pad up, LT wheel) | **F5** orbital strike, **F6** hot-drop (X still works), **F7** supply drop, **F8** Medevac; Esc cancels targeting |
  | Build menu (radial on the base) | select the base or a socket (LMB or F1); the command card's 3 × 3 build grid is bound to **Q W E / A S D / Z X C**, in the base-selected context only. The camera pans on the arrows and screen edge there, and X is a grid cell; hot-drop stays on F6 |
  | Double-tap a control group digit | the camera jumps to the group |

  - **The mouse uses the command card, never radial menus.** Every Halo Wars PC port was criticised for radials and
    fixed bindings.
  - **Paint-select exists only on the pad** (§10.4): a stick cannot drag a box, a mouse can.
  - **Command camera keys** (WASD pan, Q/E rotate, wheel zoom, MMB orbit) apply in the command context only, so
    flight's roll and lift meanings are untouched.
  - **The blob is stopped by the model, not the controls**: the width cap, fortification, suppression and
    counters. The HUD makes waste visible: "10 of 26 power can fight at the Port; the rest wait."
  - Selection stays UI state. Orders, builds and powers are SimCommands.

### 10.4 Input action layer and gamepad (action layer in phase 4a; gamepad optional, Phase G)

- **The action layer comes first** (`lib/infrastructure/flutter/input/input_actions.dart`, phase 4a, when the first
  battle keys arrive, or phase 3 if 4a comes later, Q35).
  - It maps **(context, chord) → action** for the contexts flight, walk, battle first person, command, and
    command with the base selected.
  - Handlers build SimCommands (`AvatarInput`, `SquadOrder`, `OperationOrder`, `BaseOrder`,
    `CommanderPower`, `UnitAbility`) or change UI selection. They never mutate sim state. The X key builds
    `CommanderPower(hotDrop)`; there is no separate reinforcement command.
  - A **rebind table** is saved as a user setting, not in the world save. A test asserts that no chord is bound
    twice within one context, and every bound key joins `_simKeys` (the macOS beep rule).
  - `_onKey` calls the router first only while a battle context is active. Today's flight and walk keys migrate
    opportunistically, and their tests stay green.
  - Tests drive it with synthetic held keys, following the city studio's headless driver
    (`city_studio_screen.dart:1595-1604`).
- **Gamepad: optional, Phase G, after the action layer** (Q32). The game has no gamepad support today (§2).
  - **`GamepadSource`** is polled once per frame in the widget. It feeds actions and quantised axes into the same
    SimCommands and UI selection as the keyboard, and never mutates widgets or sim state.
  - **G1, Windows, no new dependency:** XInput (`xinput1_4.dll` `XInputGetState`, one function and one struct)
    through the existing `ffi`, behind the same `if (dart.library.ffi)` conditional import and foreground-window
    guard as the pointer lock (`pointer_lock_native.dart:45-95`). It sees XInput-class pads only.
  - **G2, web, macOS and Linux:** the `gamepads` package (flame-engine.org, verified publisher, MIT; GameInput on
    Windows, the W3C Gamepad API on web), only after a build spike against framework commit `84af28a`. The SDK's
    version labels disagree (3.49 in the cache, 3.47 in `.fvm/version`), so compatibility cites the commit. It
    would be the repo's first native Windows plugin and its first `js_interop`, so Windows stays on G1. Not
    `win32_gamepad` (adds `win32` ^6), and not `xinput_gamepad` or `win_gamepad` (inactive or discontinued).
  - **Mapping, command view (Halo Wars):** left stick cursor (hold LT for speed); right stick camera; A tap
    selects, double-tap selects the kind on screen, hold paints; RB all on screen, hold for the whole force; X
    context order; Y ability; B cancel; RT cycles the kind; LT the power wheel (a radial is fine on a pad); RT +
    D-pad for 4 control groups; D-pad left bases, down squads, right alert, up rally; View the drawer; Menu the
    battle menu.
  - **Mapping, first person:** sticks move and look through the device-neutral `AvatarInputCommand`; RT fire; LT
    aim; A jump or jets; B crouch; X use or reload; Y charge; LB run; RB the orders menu. A right-stick look
    also gives macOS and Linux live fighting without pointer lock (Q12).
  - **Flight:** the sticks add into `PilotInput` at `_readPilotInput`, beside the touch sliders.
  - **Tests:** a stub source drives the action layer headlessly.

## 10A. The Halo Wars layer: forward base, economy, powers, counters

The user, 2026-10-10: "I imagine the RTS side would be like Halo Wars" and "Battles should include base
building." This section is the Beachhead design (§3.1), with the grafts listed there. It extends the Operations
Ledger and changes none of its rules. Everything here is more state on the `Operation`, stepped in the
resolver's 1 s steps in `_combatPhase` on the operation clock. Every input is a `SimCommand`, and live layers
draw and fight the same state.

Five rules are added to §1's five:
- **The base is operation state first.** A module is a row on the `Operation` that changes resolver terms.
  Drawing it (phase 3) and colliding with it (phase 4a) come later and read the same row.
- **The base spends what you shipped.** No socket, power or run creates goods or people from nothing (Q6). The
  workshop converts shipped steel and electronics into ammo and guns, and the ledger records both sides.
- **The doctrine is the truth when you are away.** A const, deterministic doctrine builds an unwatched base inside
  the resolver step. A player order goes ahead of it.
- **Powers come from real assets.** An asset that is gone, out of position or out of stock means no power, and the
  UI says why.
- **Halo Wars simplicity inside the fight, depth outside it**: which colonies arm, what you ship, which orbit your
  vessel flies, and whether to fight at all.

### 10A.1 Where the base lives: on the Operation, never in a CitySim

The forward base is a `ForwardBase` value owned by the `Operation` (`lib/domain/combat/base/**`), standing at the
LZ objective, saved in the codec v3 `operations` block (§13) and stepped in `_combatPhase`. It is **not** a CitySim
building, plat lot, cell utility or colony. Every route through CitySim breaks an invariant this plan relies on:

| Route | What breaks | Evidence |
|---|---|---|
| Placing modules in the target colony (`placeOnParcel`, `placeUtil`, `claimSite`) | the module joins *that* colony's aggregation, jobs, safety and stock, so the rebels own it. `claimSite` refuses sites with no road within 90 m (`siteAccessReachM`) and re-plats the colony mid-operation | `city_sim.dart:5004-5010`, `:1361-1407`, `:5710`, `:5797-5821` |
| The colony editor | the gate refuses acts on independent targets, and every placement calls `city.attend()`; §5.1 says force never stamps attention | `city_control.dart:47-57`; `city_edit_overlay.dart:285`, `:326`, `:387` |
| Colony terrain shaping | each new parcel becomes a keyed `TerrainBrush` in every `_cityPhase`, editing the field under the frozen battle raster | `city_terrain_shaper.dart:47-59` |
| Saving by label | `_specByLabel` drops unknown labels on load; joining `kUtilCatalog` would stake one module in every generated city and offer modules to the governor and both palettes | `city_sim.dart:4992-5002`; `city_generator.dart:2166-2181` |
| Founding the base as its own colony | founding near an existing colony opens that colony instead (about 1.5 km on the Moon); a base colony would also run loyalty and could secede | `simulation_view_colony.dart:43-56` |
| `PlaceBuildingCommand` | cell-grid, colony-targeted, and a no-op on every apply path | `command.dart:54-68`; `apply_commands.dart:61-63` |

- **A combat-owned catalog.** Modules come from `kBaseModules` in `lib/domain/combat/base/base_modules.dart`, saved
  by kind name (append-only). It is never added to `kUtilCatalog` or `kZoneSpecs`, and the generator, the
  governor and the palettes never read it. A **catalog-isolation test** asserts it.
- **Borrowed numbers, new fields.** Upkeep and power come from the colony specs (Gun Emplacement: 6 kW and 0.5
  ammo/s; the barracks' per-job kit). Build time, crew, hit points and "produces" are combat fields, because
  `CityBuildingSpec` has none (`city_building_spec.dart:50-122`).
- **The scale exception, stated (Q27).** The catalog builds at real scale (`city_building_spec.dart:11-17`). A
  Military Base (1,600 m), an Airfield (3,200 m) or any power plant (420 m or more) does not fit a 1.2 km battle
  square, and a Spaceport would cover 56% of it. Modules are **prefab deployables carried in landers**, like the
  LEM kitbash parts, with 12 to 24 m footprints. The cell-sized military specs (Barracks, Gun Emplacement,
  Warehouse, Bunker, all 24 m) lend their massing art by type.

### 10A.2 The base core: the lead lander is the recycler

- **The core is the operation's lead lander, deployed** (Battlezone's recycler). It gives:
  - command and **one build line**;
  - 20 kW of power (a fuel cell);
  - the pallet unpacker, 0.5 Materiel/s (§10A.6);
  - +0.3 to `F_att` at the LZ, as a building standing on it (§6.2);
  - 6 hit points (member-equivalents, §6.3: 600 live hp);
  - **a landing turret**: an HMG turret kit that rides in the core and is online in turret socket 1 the moment
    the core deploys, crewed by 2 support staff. Without it a base would do nothing for its first minutes;
  - **the uplink mast** (Battlezone's recycler holds command, so the uplink rides in the core rather than taking a
    socket). It targets commander powers and gives fog's 600 m sensor radius (§10A.11, §10A.13). It is online
    while the core stands and the mast is crewed (2 support staff) and powered (8 kW). It draws its crew and power
    only while orbital support is assigned or a silo or gunship power is available, so a base without them pays
    nothing for it. An earlier draft made the uplink an eighth-pick module, which in practice needed a Fortress's
    sixth socket before any strike could fire.
- **Phases 1b–2 (landing abstract):** the core deploys 30 s after the operation enters `landing`, and always does.
- **Phase 3 and later (real landers, airless bodies first):** the core is lander `force-<opId>-0`.
  - An intact landing deploys it at the **planned** LZ point in 30 s plus 1 s per 10 m it landed away (the crew
    haul the kit over). Guidance holds 8 m (`landing_guidance.dart:71-80`), so this is normally 30 s.
  - A crash or `unrecoverable` loses the core and everyone aboard (honest outcomes, §9.3).
  - The socket ring is always laid out from the planned point, so landing scatter cannot move sim geometry.
- **Spare core kit.** The planner offers one for 100 Materiel. It waits aboard the transport with the attacker's
  reserve formations, not in the base stock, so an overrun cannot take it; the materiel ledger carries it as its
  own line. It can be deployed at any objective the attacker holds at control ≥ 0.9, which becomes the new LZ
  (60 s). **A re-established base is outpost-sized**: it uses that objective's outpost sockets, laid out at launch
  (2 module, 1 turret, §10A.3), and cannot be upgraded. So no socket ring is ever laid out mid-operation, and the
  "blocked from the first bake" rule holds. If an outpost already stands there, the core joins it.
- **Landed ready.** The planner may pre-pay up to 2 Firebase modules (from the 1b-i set) from the mustered
  Materiel. They are assembled in transit, ride down in the core lander with their crew, and are online the
  moment the core deploys, like the landing turret. That gives a short fight a base from its first second. It is
  not free: their Materiel is spent at launch, before the preview knows whether they will matter.
- **Light operation (no base).** The planner can ship no core and no Materiel. The operation then fights exactly
  as phase 1 does. The planner shows it beside the base option for short fights, as a trade (§6.5, §10A.6).
- **Overrun.**
  - While the defender holds the LZ (control < 0), every module there is offline: no production, no turret fire,
    builds paused. Defender fire at the LZ wears modules down through `structureShare` (§6.3).
  - If the defender holds the LZ at control ≤ −0.9 for 60 s (the win rule's hold), or the core reaches 0 hp, the
    base is **overrun**: every module is lost, the people at the base take the losses in §7.6's overrun row, half
    the base stock (unopened pallets included) is captured by the target through its inbox, extending "the winner
    takes half" (§7.4), and the other half is lost. In auto-resolve the control hold is what normally fires; the
    core is last in line for fire (§6.3).
  - Supply runs and resupply stop until a spare core kit is deployed (Halo Wars' rebuild clock, scaled to
    operation days). Until then §5.4's kit rule runs.

### 10A.3 Sockets, tiers, outposts and layout

**Tiers**, named as in Halo Wars (the 3/5/7 layout both games used):

| Tier | Module sockets | Turret sockets | Build lines | Cost and time | Gate |
|---|---|---|---|---|---|
| Firebase (the core, on landing) | 3 | 2 (one holds the landing turret) | 1 | free, on deploy | |
| Station | 5 | 4 | 2 | 100 Materiel, 50 s (Halo Wars 2 paces upgrades at 50 s) | |
| Fortress | 7 | 4 | 3 | 160 Materiel + 20 steel, 60 s; LZ `F_att` +0.3 | a source colony with a Military Base (§10A.6) |

**Outposts (Halo Wars 2's minibases: the expansion loop).**
- Once the attacker has held an objective at control ≥ 0.9 for 60 s, an outpost can open beside it: 120 Materiel,
  40 s, **2 module sockets and 1 turret socket**. At most 3, so at most 4 base sites in all.
- Outposts stand on free ground within 150 m of the objective, laid out by the same launch-time function as the
  core's ring, **never on a parcel or plat lot**. So Restrained ROE's "never destroyed" rule (§4.3) and the term
  guard (§7.5) are untouched, and the colony gate is never consulted.
- An outpost **attaches to its objective's graph node**, so the graph stays at 8 nodes or fewer. Its modules add
  to that objective's `F_att` (+0.3 for the first module, +0.25 for its turret) and value (+0.25 per module), so
  the defender AI raids grown outposts, and those raids cost it more.
- Its modules are offline while the objective's control is ≤ 0. It is **razed** after control ≤ −0.9 for 60 s:
  modules lost, crews take losses.
- If the objective has no free ground in the launch layout, the drawer says "No room for an outpost here".

**Layout.**
- **Phase 1b-i:** sockets are indices with no positions.
- **From phase 1b-ii, a pure function computed once at launch** (`lib/domain/combat/launch/base_layout.dart`, part
  of the `LaunchSnapshot`). It is headless, so it does not wait for phase 3, and it gives the garrison post its
  footprint (§10A.15), phase 2's outposts their ground, and phase 3b's strike rules their hulls. Phase 3 only
  draws it. Inputs: the planned LZ point, the heading to the nearest goal objective, and the launch footprint set
  (§4.2: hull prisms, road ribbons including elevated decks, pads, parcels and plat lots, and `ScatterColliders`
  built with the renderer's `ScatterMask`, §8.2). It lays out the core ring, every objective's outpost sockets
  (used by an outpost or a re-established core, §10A.2), and nothing else, ever.
  - Module ring: radius 45 m, 7 slots spaced evenly, starting behind the LZ (away from the enemy).
  - Turret ring: radius 75 m, 4 slots at ±20° and ±60° of the enemy heading.
  - A slot whose box (24 m, or 12 m for a turret) overlaps anything steps around its ring in 5° increments, up to
    ±25°. Past that it is **blocked**, and the drawer says "No room for this socket".
  - Integer-degree steps. `launch/` may use trig; the no-trig rule covers `resolver/**` and `base/**`.
- **The LZ picker** scores candidates by free sockets: automatic from phase 1b-ii, a draggable pin from phase 3.
  It keeps the existing rules: centre at least 400 m from every closed pad's point, ring off every parcel and plat
  lot (§9.3), clear of elevated decks, and fitting the battle square with the goal (§8.3).
- **Footprints are blocked from the first bake, and datums come from the raster** (§8.2, §8.3). Every socket, built
  or not, is a blocked pad in the foot and wheeled layers, and each plinth's height is the mean of the raster cells
  under it. No module ever emits a terrain brush, and the base takes no field sample.
- **Spike S item 6** (§16) measures how many sockets a real LZ has free, and whether the LZ and goal fit one
  square.

### 10A.4 The module catalog (`kBaseModules`)

| Module | Footprint | Materiel | Build | Crew | Power | Running cost | Effect on the pools | Home gate | HP | Phase |
|---|---|---|---|---|---|---|---|---|---|---|
| Supply pad | 24 m pad | 30 | 25 s | 1 | 2 kW | none | unpacks pallets at +1.0 Materiel/s; supply-run interval ÷ (1 + 0.5 × pads), at most 2 pads (3 days → 1.5); hot-drop lands in 30 s instead of 45 s; drawn supply drops touch down here from phase 3 | a source with a Spaceport | 2 | 1b-i |
| Turret | 12 m | 60 | 30 s | 2 | 6 kW | 0.5 ammo/s while its objective is engaged (60 a day, the Gun Emplacement's rate), 10% of that otherwise | an attacker `emplacement` formation (count = crew 2, P 3.0) plus `F_att` +0.25 at its objective. Specialisation: HMG by default, AT from phase 6, AA from phase 7; 30 Materiel and 20 s to change, one at a time (the UNSC rule in Halo Wars 2) | a source with an Arms Factory | its crew | 1b-i |
| Barracks pod | 24 m (barracks art) | 50 | 40 s | 2 | 6 kW | none | forms one formation of up to 8 every 30 s from the LZ reserve: recovered wounded, members of disbanded broken formations, and landed reinforcements. On the player's `formSquad` it also converts support staff, at 1 gun each from stock and quality 0.7, within each one's source trooper cap (§4.1). Broken formations at its site rally at 2×. Without a pod, the core re-forms at half speed | a source with a Barracks | 2 | 1b-i |
| Stores | 24 m (warehouse art) | 20 | 20 s | 0 | 0 | none | unpacked-stock cap +300 per commodity (a prefab echo of the warehouse's +500); pallets past the cap wait unopened. Named Stores so it is never confused with the Depot objective (§6.2) | none | 2 | 1b-ii |
| Field hospital | 24 m | 40 | 40 s | 2 | 4 kW | medicine 0.2 a patient-day | wounded at its site return to the LZ reserve after 0.5 operation day, instead of going home; enables Medevac | a source served by a Hospital | 2 | 1b-ii |
| Generator | 12 m | 40 | 30 s | 1 | +30 kW | fuel 0.1/s (12 a day) | power | none | 1.5 | 1b-ii |
| Munitions workshop | 24 m | 60 + 10 steel | 50 s | 3 | 12 kW | steel 15 + electronics 3 a day | converts them into +30 ammo and +9 guns a day: the Arms Factory's ratios (60 steel + 12 electronics → 120 ammo + 36 guns a day, `city_building_spec.dart:433-437`) at quarter scale. The only way to make military goods at the front without making them deliverable; the ledger records it as converted out and converted in | a source with an Arms Factory | 2 | 1b-ii |
| Vehicle bay | 24 m | 100 + 20 steel | 60 s | 3 | 20 kW | fuel for armour (the kit rule, §4.1) | assembles shipped vehicle kits into `armour` formations (2 vehicles + 3 crew from the LZ reserve) at 60 s each, at most 2 per ready Military Base source; Fortress tier only | a source with a Military Base | 4 | 6 |
| Airpad | 24 m | 80 | 40 s | 2 | 6 kW | fuel | gunship-pass cooldown × 0.5 | a source with an Airfield | 2.5 | 7 |

HP is in member-equivalents (§6.3): 1 is one trooper, 100 live hp. The uplink is no longer a module: it rides in
the core (§10A.2).

Reference numbers:
- A full Fortress costs about 710 Materiel and 30 steel: seven modules (two supply pads, pod, Stores, hospital,
  generator, workshop), three bought turrets, and both upgrades.
- The default 300 Materiel buys the pad, the pod, the Station upgrade, the Stores, the hospital and a generator
  (§10A.6).
- A working base is up about 3 minutes after the core deploys. A fair fight is about 174 s (§6.3).

### 10A.5 Construction

- **Build lines:** 1 at Firebase, 2 at Station, 3 at Fortress; each outpost has its own single line. Each line
  holds one socket build, an upgrade, a specialisation, a repair or the outpost's opening.
- **Payment up front**, Halo Wars style, from unpacked Materiel when the build starts. A queued build costs nothing
  until it starts. Cancelling a started build refunds 50% (CitySim's `refundFraction`, `city_sim.dart:358`).
- **Timers** are integer µs on the operation clock, advanced in the resolver's fixed 1 s steps, and saved exactly.
  There is no CitySim precedent: placed utilities run at full output from the tick they are placed
  (`city_sim.dart:2131-2138`).
- **Completion** raises a `ModuleBuilt(opId, socket, kind)` domain event, the milestone shape of the megastructure
  phases (`megastructure/megastructure_construction.dart:8-53`), owned here. The module runs from the next step.
- **Construction needs no power; running modules do.** Under a brownout every module runs at
  r = min(1, supply ÷ demand), quantised to 1/64: production × r, turret `Sup` × r (floored at 0.35), and the
  barracks pod's interval ÷ r.
- **Crew** are personnel assigned from the LZ reserve. A module without its full crew is offline, with the reason
  "No crew: ship more support staff, or reassign".
- **Demolish** returns 50% of the Materiel. **Repair** after damage (from the live layer, `structureShare`, or a
  rebel silo strike) costs 25% of the Materiel and 20 s.

### 10A.6 The economy inside the operation

Halo Wars 2's three numbers become **Materiel**, **Power** and **Personnel**, plus the plan's **kit**. All of it is
real colony stock, **moved, not added** (§4.1). The HUD reads:
"Materiel 240 (+1.5/s) · Power 18/20 kW · Personnel 25/25 · Kit 2.6 days". The drawer shows every stock line.

**Stocks** (integer centi-units on the base):

| Stock | Comes from | Spent on | Cap |
|---|---|---|---|
| **Materiel = ore**, the one big number | mustered from sources' ore at launch (default 300, §4.1); supply runs (default +100 a run); Depot salvage (§10A.7) | builds, upgrades, specialisations, repairs, outposts, a spare core kit, modules landed ready | unpacked: 400 + 300 per Stores |
| Rations, ammo, guns (the kit) | §4.1's kit (default 3 days for everyone shipped); supply runs; the munitions workshop; salvage; §7.4's captured guns | personnel upkeep at the barracks' per-job rates (2 rations, 1.2 ammo and 0.2 guns a person-day, `city_building_spec.dart:448-451`); turret ammo; 1 gun per support member converted to a trooper; charges | 400 + 300 per Stores |
| Fuel | mustered (default 24, §4.1) and runs | generator, armour, jump jets | the same |
| Medicine | mustered (default 10, §4.1) and runs (deliverable, `city_sim.dart:6195`) | field hospital, Medevac | the same |
| Steel, electronics | mustered and runs; salvage | workshop, the Fortress upgrade, vehicle bay | the same |

- **Ore is the right currency** because it is the city's build currency (`buildCost`). It is not the only good that
  travels every channel: water, food, oxygen, fuel and oxidizer are also deliverable (`city_sim.dart:6187-6198`)
  and vessel `ResourceType`s (`resource_container.dart:8-17`). But it is the one the player already reads as "what
  building costs", and a mixed recipe would be blocked by its scarcest input (Q34).
- **Pallets.** Mustered and shipped Materiel lands as pallets. **25% of the mustered pallets arrive unpacked**, so
  the first build starts on landing. The core unpacks 0.5/s and each online supply pad +1.0/s. This is Halo Wars'
  supply income, made of goods that were shipped.
- **Resupply.** Formations at a held base site, or one hop from it (§6.2), refill `kitDays` toward 3 at 1 day per
  30 s from the base stock. Formations further out run down, and `Sup` falls to 0.35 without ammo (§6.1).
- **Supply runs during an operation** reuse §7.1's handshake. Every interval (default 3 operation days, cut by
  pads), `_combatPhase` posts a debit for the run's manifest (Materiel, kit for everyone ashore, and fuel and
  medicine as set) into a source's `ColonyCombatInbox`, and fixes the run's arrival on the operation clock: post
  time + transit (0.5 operation day on the same body, 1.5 from another). The source ships what it has and posts
  the amount to its outbox; that confirmation fills the arrival when it lands (§5.3). A shortfall shows on the
  drawer as "Supply run 2 landed 60 of 100 Materiel: Colony A was short".
  - **Never the abstract deliveries** (`kDeliveryPeople` and the rest): they create goods and people from nothing
    and land only at colony pads (`city_sim.dart:5926-6074`).
  - Runs are abstract in every phase, drawn from phase 3 as a descent onto the supply pad, never a Vessel (§9.3).
- **Emergency supply drop** (a power, §10A.11): one extra run lands 0.5 day (60 s) after the cast. That is the
  shortest transit the plan allows, because it must outlast the worst hold lag (§5.3); an earlier 0.25 day did
  not.

**Power** (Halo Wars 2's Power, as a rate cap rather than a currency):
- Supply: core 20 kW, each generator +30 kW, and +40 kW while the Power objective is held (§10A.7).
- Demand: the modules' draws in §10A.4. The drawer shows a supply and demand bar.

**Personnel: the population cap is the people you shipped.**
- Troopers form squads; support staff crew modules (§4.1, Q28). Reinforcement musters (`BaseOrderCommand`
  `reinforce`) debit ready troopers at a source through its inbox and raise the cap when they land.
- The **LZ reserve** is personnel ashore at the base in no formation and no crew: recovered wounded, members of
  broken formations that disbanded (§6.3), landed reinforcements and unassigned support staff. It is not the same
  as formations whose `at` is `reserve` (§6.1), which have not landed yet. Squads and crews come only from it.
- The HUD reads "Personnel 25/25 · 13 in squads · 10 crew · 0 spare · 2 wounded".
- `liveCap` (24 a side) stays the bubble's render and sim cap, separate from this one (§11.5).

**Worked example** (the §12 `portSeizedPair` fixture, Balanced doctrine):
- *Shipped:* 15 troopers (two squads), 10 support staff, 300 Materiel (75 unpacked on landing), 3 days of kit
  for 25 people (150 rations, 90 ammo, 15 guns), 15 guns for the troopers, 24 fuel (2 days of generator) and 10
  medicine. The source can give this because the fixture gives it a Warehouse and 700 ore (§12).
- *Timeline, from the core deploying* (the landing turret is online at once):
  - supply pad 0–25 s; barracks pod 25–65 s;
  - the Station upgrade 87–137 s (it waits for Materiel: 75 ready, then 0.5/s, then 1.5/s once the pad is
    up);
  - Stores 137–157 s and field hospital 137–177 s on the two lines;
  - the second turret would push the draw to 24 kW against the core's 20, so the doctrine builds a generator
    first, 157–187 s;
  - the second turret waits for the first supply run (100 Materiel, at about 240 s with one pad) and is up at
    about 300 s.
- *Crew:* landing turret 2, pad 1, pod 2, hospital 2, generator 1, turret 2: 10 of 10. At 65 s, 5 of them are
  still in the LZ reserve waiting for the hospital, generator and second turret. The doctrine holds them for those
  modules and never converts support staff into troopers (§10A.8).
- *With orbital support assigned,* the core's uplink mast needs 8 kW and 2 more crew from the start: 6 + 8 = 14 kW
  before the pad, so the generator jumps ahead of the pod, and the default manifest ships 12 support staff.
- *Power:* the landing turret, pad, pod and hospital draw 18 kW of the core's 20; with the generator, 24 of 50.
- *The turrets' ammo* (60 a day each) is burned at the full rate only while the LZ is engaged.

**Small targets, and the light operation.**
- Against a starter town (about 8 militia, 2 armed, §4.2), 15 troopers break the rebels in about 45 s, before
  any module is built. The town has no Barracks or Gun Emplacements, so the counter triangle does nothing either
  (§10A.9). The landing turret, the ready pallets and up to 2 modules landed ready (§10A.2) give the base a role
  from the first second, and the base becomes the garrison's post afterwards (§10A.15). That post, not the fight,
  is what a base is for at this scale. Most of the Halo Wars layer is honestly idle here.
- So when the preview's median duration is under 1.5 operation days, the planner shows the **light operation**
  beside the base option, each with its own histogram (§6.5): a trade, not the default. A light operation ships
  no core and no Materiel and fights exactly as phase 1 does, and it leaves no post.
- **The base earns its keep against large colonies.** A 1,000-colonist colony fields about 160 militia in waves
  (§4.2), which stretches an operation over several fair fights, up to the 10-day ceasefire. That is where
  supply pads, a hospital, a barracks pod and outposts pay back.

**Home "tech"** (Halo Wars' tech level, in colony terms):
- Module and tier gates are evaluated once, at launch, on the sources' `SourceSnapshot` (§4.1): the home-gate column in
  §10A.4. The planner's "why not" copy names the missing building: "A Fortress needs a Military Base in a source
  colony."
- A source that secedes mid-operation keeps the modules already built, but its crews desert (§7.6), so those
  modules go offline until re-crewed, its runs stop, and builds that only it unlocked lock.

### 10A.7 Objectives that pay out (Halo Wars' neutral structures, from colony state)

| Objective | Built from | While the attacker holds it |
|---|---|---|
| **Depot** (new, phase 2) | the target's storage sites (Warehouse, Silo Cluster, Freight Yard; `storageBonus`, `city_building_spec.dart:83`, summed in `stockCap`, `city_sim.dart:1273-1285`) | **salvage**: on capture, one requisition is posted to the target's inbox for half of this Depot's share (its `storageBonus` ÷ the colony's stock cap, both from the `LaunchSnapshot`) of the target's ore, steel, rations and ammo as recorded at launch, plus the same share of the guns still in the snapshot's pool (never guns in militia hands, §4.2), ore capped at 150. Its arrival is fixed when the requisition is posted: post time + 0.5 operation day (§5.3). The target ships what it actually has and posts the amount to its outbox (the supply-run handshake reversed), and that amount lands as pallets and kit. It costs the target mood, like §7.2's requisitions. Restrained ROE takes only ore and military goods |
| Power | the largest generator | +40 kW to the base; defender `emplacement` formations' `Sup` × 0.5 (a Gun Emplacement draws 6 kW). The **"Cut the town's power"** order posts a `cutFactor = 0` for that plant into the target through its inbox. `cutFactor` is its own term in `siteFactor` (§4.1), saved separately from deployed share and damage, and `siteFactor` scales `powerOutput` explicitly in both loops, because today nothing scales a plant's output (§2). Standard ROE only, and refused if the colony's output without the plant would fall below its life-support draw (§7.5, Q31), with a planner warning. Restoring sets `cutFactor` back to 1, which leaves real damage in place; it happens when the objective is lost or the operation ends |
| Life support | the `isLifeSupport` cluster | wounded at the LZ recover 2× faster; suit-breach bleeds stop (phase 4a); the siege route toward the dependency petition (§6.2) |
| Port | `landingPads()` minus airfields | supply-run interval × 0.75; an outpost can open beside it (§10A.3) |
| LZ | the base | value = 1 + 0.15 per module + 0.25 per tier (§6.2); its turrets defend it |

### 10A.8 Auto-resolve: the base step and the build doctrine

- **The base steps inside `_combatPhase` step 3 for every operation, attended or not,** in fixed 1 s operation
  steps, in the order of §5.3: arrivals; the base step (unpack, power balance, build lines, production, upkeep,
  resupply); the doctrine; the overhead gate; powers; the resolver; spotting; end checks. Iteration is by sorted
  id, there are only stateless seeded rolls (§6.3), and budgets are counted.
- **Doctrine** (`lib/domain/combat/base/doctrine.dart`, pure), picked in the planner and changed later with
  `BaseOrderCommand(setDoctrine)`. Phase 1b-i ships Balanced only; 1b-ii adds the rest.
  - **Balanced** (default): supply pad, barracks pod, Station, Stores, field hospital, turret (HMG; AT once
    armour has been seen, phase 6), workshop (if steel ≥ 10), an outpost at the first objective that becomes
    eligible (phase 2), Fortress, then the vehicle bay (phase 6) and the airpad (phase 7) if their home gates
    hold, then the remaining turrets.
  - **Hold:** turret, turret, field hospital, Station, turret, Stores, supply pad, then as Balanced.
  - **Push:** supply pad, barracks pod, Station, a second barracks pod, Stores, field hospital, an outpost at the
    first eligible objective, then as Balanced.
  - **Every doctrine:** the first turret is specialised AA (phase 7) once the `LaunchSnapshot` shows a staffed
    rebel silo with missiles.
  - **Manual:** the doctrine builds nothing.
- **How it picks.** On each idle line it takes the first list item whose gates hold (home gate, socket free, crew
  available).
  - A generator jumps the list whenever the next item would push power demand over supply.
  - An item short of Materiel waits, unless the next two scheduled runs' **posted manifests** cannot cover it;
    then it is skipped. It never reasons from a confirmation (§5.3).
  - **Crew are reserved ahead.** Before it assigns crew to the current pick, it holds back the crew of every
    module still ahead of it on its list, up to the support staff shipped. So "crew available" means available
    after that reservation.
  - It trains squads only from the LZ reserve's recovered wounded, disbanded members and landed reinforcements,
    whenever at least 4 of them wait and a pod is idle. **It never converts support staff**; only the player's
    `formSquad` does (§10A.4).
  - Player orders go ahead of the doctrine's next pick. Each site has an **Auto-build** toggle (default on);
    Manual turns them all off.
- **Powers policy** (planner toggle, default Auto):
  - supply drop when any stock is under 1 day;
  - **hot-drop** whenever an attacker reserve formation waits aboard the transport and a goal objective is
    contested; to the LZ, or to a held objective nearer the goal if fatigue still leaves it the stronger side;
  - Medevac when the wounded at an engaged objective reach 25% of the members there (the front, not a hospital's
    own site, where wounded already recover), choosing the objective with the most wounded;
  - orbital strikes **only if "Orbital weapons free" is ticked**: at the first overhead step, on the engaged goal
    objective with the highest `F_def` that has a defender emplacement the ROE allows as an aim point (§7.5),
    preferring one with no attacker formation present. Under Restrained, if no emplacement is clear of civilian
    hulls, the policy holds fire and the HUD says why ("Restrained: no strike clear of homes"). The policy never
    fires danger close.
- **The base takes damage in the abstract** (§6.3). At a contested LZ or outpost, the base soaks a share of the
  defender's fire that grows with its hit points against the attackers there (`σ_o`), one module at a time, front
  socket first and the core last. Fire is redistributed, never reduced. A module below 50% hp is damaged and
  offline until repaired; at 0 it is destroyed, and its crew take losses (half dead, half wounded). Turrets are
  formations and take their own share of the rest.
- **The preview (§6.5) runs the doctrine and the powers policy**, so the histogram includes the base.
- **The calibration harness (§8.9) gains base scenarios**: Balanced, no base, an outpost variant, and (phase 7) an
  AA variant on each of the 3 references. Builds are operation-level, so abstract and live run the same build
  timeline.
- **The defender does not build** in v1 (Q30); it digs in (§4.2) and, from phase 7, may strike the base with its
  own silo (§10A.11). Rival factions (phase 8) would use these same base rules and doctrine.

### 10A.9 Counters (Halo Wars' triangle, built for unequal sides)

Each formation has a `counterClass` (§6.1). The multiplier M[dealer][target] lives in a const `CounterTuning` table
inside `ResolverTuning`:

| dealer → target | INF | EMP | ARM | AIR | STR (modules) |
|---|---|---|---|---|---|
| INF | 1.0 | 0.75 (1.25 with charges) | 0.5 (1.0 with charges) | 1.5 | 0.5 (1.0 with charges) |
| EMP-HMG (every defender emplacement; the default turret) | 1.0 | 0.5 | 0.35 | 0.5 | 0.5 |
| EMP-AT (phase 6) | 0.6 | 1.0 | 1.5 | 0.35 | 1.0 |
| EMP-AA (phase 7) | 0.35 | 0.35 | 0.35 | 2.0 | 0.35 |
| ARM (phase 6) | 1.5 | 1.5 | 1.0 | 0.35 | 1.5 |
| AIR (phase 7) | 0.75 | 1.5 | 1.5 | 1.0 | 1.5 |

- **Halo's triangle survives verbatim:** ARM beats INF, INF beats AIR, AIR beats ARM. Each turret specialisation
  counters one corner.
- **Before phase 6 only INF and EMP exist,** because rebel towns field infantry and Gun Emplacements. So the story
  is simple: emplacements (P 3.0, `F_def` +0.25) stop infantry, and charges, orbital strikes or, later, armour
  break them.
- **Inert at militia scale.** Gun Emplacements unlock at 400 colonists and the governor never builds military, so
  a starter town fields INF only, and M[INF][INF] = 1. The triangle starts to matter against a colony that had
  400+ colonists and emplacements when it seceded, and with rivals (phase 8).
- **Where it applies:** where §6.3 shares losses out, pair by pair. Never to strength, the width cap or control.
- **Phase 1 ships M ≡ 1** in the pairwise form, so its 174 s pin is unchanged (§6.3). Phase 1b-ii sets the INF, EMP
  and STR values and re-pins the emplacement rows deliberately.
- **One table for both layers:** the live layer's armour factor (§8.5) reads it, by weapon class against target
  class.
- Planner rows and squad cards show strong-against and weak-against icons, as Halo Wars labels its roles.

### 10A.10 Abilities (one per kind; the player is the hero)

| Kind | Ability | Cost and cooldown | Resolver term | Live | Phase |
|---|---|---|---|---|---|
| Trooper | **Charge assault** (mining charges) | 5 ammo; 90 s | for 30 s that formation's row reads INF→EMP 1.25, INF→ARM 1.0, INF→STR 1.0 | a thrown charge, a slow round (§8.5) | 1b-ii abstract, 4a live |
| Trooper, where the EVA pack lifts (Moon, asteroids: 3.2 against 1.62 m/s²) | **Jump jets** | 2 fuel; 120 s | next march time × 0.6; ignores the objective's rough-ground `F_def` +0.2 for 30 s | the EVA pack (§9.1) | 1b-ii, 4a |
| Defender formations (passive) | **Dig in** | none | +0.1 `F_def` per 30 s stationary at an objective, up to +0.3 (§4.2) | seek cover (§8.8) | 1b-ii, 4b |
| Regular (defender) | **Rally** | none; 180 s | morale +0.15 | | 2 |
| Turret | its **specialisation** | §10A.4 | §10A.9 | | 1b-ii |
| Buggy, APC, hover tank | **Ram**, **Unload** (a carried squad deploys with no march), **Boost** | fuel | ARM→INF 2.0 for 10 s; skip the march; march × 0.5 | Warthog-style run-overs by collision | 6 |
| Gunship | **Strafing run** | ammo | AIR→EMP 2.0 for 15 s | | 7 |
| The player's avatar | **The hero** (the Spartan) | | §8.6's +0.15 morale floor within 150 m is the hero aura; REDEPLOY is the respawn (§9.4) | Battlezone's eject-and-board on abandoned vehicles stands in for the Spartan hijack | 4a, 6 |

- Cooldowns count integer operation µs, saved on the formation (`abilityUntilUs`, `cooldownUntilUs`).
- The AI and the doctrine use abilities by fixed rules (§6.4). The player uses them with `UnitAbilityCommand`: from
  the drawer in the abstract, R in the command view (§10.3), and Y on a pad.

### 10A.11 Commander powers: paid for by real assets

Powers are cast with `CommanderPowerCommand(opId, power, target, vesselId?)`. They cost base stock or real parts,
and have operation-time cooldowns. Choosing which assets back an operation (sources, vessels, doctrine) is the
"leader" pick, so there are no leader points.

| Power (Halo Wars analog) | Real asset it comes from | Cost | Cooldown | Needs | Effect | Phase |
|---|---|---|---|---|---|---|
| Emergency supply drop (Pelican Transport) | a source's spaceport; drawn as a descent from phase 3, never a Vessel | the run's goods, plus its fuel × 2, debited from the source | 2 days | a supply pad | an extra run lands in 0.5 day (60 s, the shortest transit, §5.3) | 1b-ii |
| Medevac (Heal and Repair) | the field hospital | 10 medicine | 3 days | a hospital | half the wounded at the target objective move to the LZ reserve and recover there; damaged modules at that site are repaired | 1b-ii |
| Hot-drop (ODST Drop; the X key, §10.2) | the attacker's reserve formations aboard the transport; an abstract drop at a fixed time, drawn as drop pods | none | 90 s | (a pad: 30 s instead of 45 s) | lands at the LZ or any held objective; away from the core it lands with **deployment fatigue** (morale starts at 0.5, M × 0.75 for 10 s; Halo Wars 2 Blitz) | 3 abstract, 4b X key |
| **Orbital strike** (MAC Blast) | a player vessel assigned to the operation, overhead, carrying rounds (§10A.12) | 1 round | 60 s per vessel | the core's uplink online | §10A.12 | 3b |
| Orbital recon (passive, never cast) | a vessel **assigned** to the operation, armed or not, ≥ 10° above the battle. An unarmed vessel can be assigned for recon only, and it holds the 10× ceiling like any assignment (§5.3) | none | none | the core's uplink online | every defender formation in the square is Known (§10A.13) | 3b |
| Silo strike | a source's staffed Missile Silo on the same body; missiles from its `SourceSnapshot` pool, each debit posted to its inbox | 4 missiles | 2 days | the core's uplink online | like an orbital strike, with a fixed 60 s flight and a 30 m CEP | 7 |
| Gunship pass (Carpet Bomb) | a source's Airfield | 60 fuel + 60 ammo | 2 days (× 0.5 with an airpad) | the core's uplink online | for 30 s, a temporary attacker formation of class AIR (count 1, P 8.0, quality 1) fights at the target objective, with the strafing run (AIR→EMP 2.0) for its first 15 s. Only EMP-AA fire can remove it; if it is removed, the pass ends | 7 |
| *Rebel silo strike on the base* (a defender power, §4.2) | the target's staffed silo and missiles in its `LaunchSnapshot`, debited through its inbox | 4 missiles | 2 days | | hits one module or turret at the LZ; each AA turret has a 50% chance to intercept, a reason to build AA | 7 |

- A rebel silo strike that hits the core knocks its uplink offline until repaired, and an overrun removes it with the core: Halo Wars' Disruption Bomb.
- Single-source Halo Wars figures (the MAC Blast's cooldown, Blitz energy rates) are pacing references only. Every
  number above is a tuning constant pinned by calibration.

### 10A.12 The orbital strike

**What "armed" means.** No weapon or payload part exists (`part_def.dart:16-31`), and a vessel cannot release
anything (`separateStage` only drops the last stage, `vessel.dart:228-233`). Two routes, one chosen in Q23:
- **Real parts (proposed; parts lane, cross-lane).** Two tier-0 parts: an **Ordnance Rack** (300 kg) holding 4
  **Kinetic Penetrators** (250 kg each: a rod with a solid kick motor). They need a new `PartCategory.ordnance`,
  which touches the exhaustive switches at `craft_catalog_pane.dart:56` and `:75`. `part_primitives_category.dart`
  is not a switch: it is a map with a deliberate cuboid fallback (`:132-136`), so a new category compiles there and
  fails only `test/flutter_scene/part_bake_cache_test.dart:158-163` until it gets a silhouette.
  Firing removes one round through a new `Vessel.releaseOrdnance(partId)`, so the vessel's mass falls honestly.
  **The rack is built empty in the craft editor; rounds cost real stock.** No craft part or launch debits any colony
  stock today (the only spend checks are `PlanValidator.canAfford` for flight-plan fuel and the Treasury), so a
  free round would break "powers come from real assets". Rounds are filled with `ArmVessel` (below) in both
  routes. No `ResourceType` is added.
- **A combat-owned loadout (the fallback, so phase 3b need not wait for the parts lane).** A world-level, saved
  `VesselLoadoutRegistry` (vessel id → rounds). `ArmVesselCommand(vesselId, colonyId, rounds)` applies while the
  vessel is landed within 60 m of a served pad of a colonial or occupied colony (`ShuttleCargoService`'s pad
  radius). Rounds are massless in v1. The registry drops ids whose vessel is gone each tick, in id order.
- **`ArmVessel(vesselId, colonyId, rounds)`, the cost of a round, in either route.** It applies while the vessel is
  landed within 60 m of a served pad of a colonial or occupied colony. It posts a debit into that colony's inbox,
  and the rounds become available at a time fixed when it is posted (post time + 60 s of loading, §5.3), filled
  with what the colony confirms it had. **Proposed cost: 25 steel and 5 electronics a round** (a Kinetic
  Penetrator is a steel rod), which an early colony can pay. The alternative, 2 missiles a round, gives missiles
  a use but needs a Missile Plant (800 colonists, `city_building_spec.dart:438-443`), which would put the headline
  twist late in progression (Q23).

**What "overhead" means** (`lib/domain/combat/powers/overhead.dart`):

```
p = body.orientationAt(e).rotate(targetBF)   // targetBF: the objective point in the LaunchSnapshot
                                             //   (CitySim.localToBodyFixed at launch)
v = vessel.state.position                    // body-centred inertial; an ASSIGNED vessel in the target body's
                                             //   SOI, not landed (unassigned vessels are never read)
d = v − p
overheadStrike = dot(d, p̂) ≥ 0.5·|d|  and  |d| ≤ 2,500 km     // 30° elevation; sin 30° as a constant
overheadRecon  = dot(d, p̂) ≥ 0.1736·|d|                        // 10° elevation
```

- **At or above a positive elevation, a sphere cannot occlude** the line, and terrain occlusion is negligible from
  10° up, so `CommsService.isOccluded` is not needed. **Never `hasCommLink`**: its ground station is fixed in the
  inertial frame (`relay_network.dart:31`). Eclipse is not a gate.
- **Evaluated at each 1 s step boundary**, at the epoch `e = tickStartEpoch + (boundaryOpUs − tickStartOpUs)`. The
  single ceiling clamp (§5.3) snaps every factor under the ceiling to a ladder rung, so every allowed tick (0.02,
  0.1 or 0.2 s; 0.5 s at a 25× rung) divides 1 s, the boundary is a tick end, and the gate reads that tick's
  authoritative tick-end state. Warp-to-apsis cannot produce a 0.146 s tick under the ceiling, because the clamp
  runs after its re-fit. A future rung whose tick did not divide 1 s would propagate the vessel's rails conic to
  the boundary in closed form instead.
- **The last step's booleans are saved** with the operation (§13), so a load does not need vessel state from a
  boundary that has passed.
- **The resolver receives one boolean per vessel per step.** `resolver/**` imports no vessel or orbit code.

**The warp ceiling makes "real" coherent** (§5.3).
- World dt is 0.02 s × warp, and operation dt is min(tickDt, 0.5). Above 25×, a vessel orbits W/25 times too fast
  in battle time (40× at 1,000×), and from 10,000× up a 197 s window is shorter than one tick and is skipped.
- **Two levels, one clamp** (§5.3). While a real lander descends, warp is held at 1× (the largest rung at or below
  `railsWarpThreshold`), because above 4× it would be on rails and its guidance would do nothing. While only
  orbital support (armed or recon) is assigned, warp is held at 10× (the largest rung with `tickDt` ≤ 0.5 s on
  `simulation_view.dart:1473`'s ladder; Q22 asks about a 25× rung). The clamp runs every frame immediately
  before the tick loop and after a load, not in `_stepWarp`, because warp-to-apsis, the atmosphere lock and
  loading all write the factor directly (§2).
- Under the ceiling, operation time equals world time. Orbital passes, real landers and the battle all agree.
- Pressing `.` past it shows "Battle in progress: warp held at 10× (orbital support assigned to Retake the port)",
  or "held at 1× while the landers come down".
- **The real cost.** An operation lasts at most 10 operation days (1,200 s): about 2 real minutes at 10× while
  only support holds the ceiling. Every real descent (the opening landing, each reinforcement lander) is watched
  at 1× for its whole length; phase 3 measures how long a `LandingGuidance` descent from 16 km takes on the Moon,
  and §17 carries it as a risk. Unassigning support lifts the 10× level once no lander is in flight.
- `SimHost` has no colonies, so no operation runs there; its substeps are deferred (§5.3).

**Pass geometry the player plans around** (from the code's own μ, R and rotation periods):
- **100 km lunar orbit:** period 7,067 s. Above 30° for about 197 s on its best pass. The ground track drifts about
  1.08° per orbit, which gives bursts of about 9 passes, then about 13.7 Earth days (about 9,800 operation days)
  with none. A battle sees at most one pass per vessel.
- **1,000 km lunar orbit:** above 30° for about 32 minutes, but slow, scattered rounds (below).
- **No lunar-stationary orbit:** the synchronous radius of 88,452 km is beyond the Moon's 66,100 km SOI
  (`real_solar_system.dart:260`).
- **Earth GEO and Mars areostationary orbits** exist, but are beyond the 2,500 km strike range: **recon only**.
- So the strategy is real: two or three armed vessels in staggered low orbits, or a launch timed so the landing
  meets a pass.

**The window predictor.** Its math is pure domain code, `lib/domain/combat/powers/strike_window.dart`, so the
domain never depends on the UI; `screens/combat/strike_window_view.dart` only throttles and draws it. Its result
is UI state like the encounter planner's overlay, never sim state, and nothing gates on it (the preview runs the
overhead gate itself, §6.5).
- It works in **body-centred frames**: the vessel's conic about the target body against
  `orientationAt(t).rotate(targetBF)`. It does not reuse `_closestApproach` (`encounter_planner.dart:280`), which is
  private, works in root-frame positions (`:289-305`) and scans one period for a global minimum distance, where
  this needs the first epoch at which elevation reaches 30°, possibly many periods away.
- **An analytic pre-filter first.** Per orbit, the ground track's node drift against the target's longitude gives
  which orbits can bring the target within the 30° cone at all. Only those candidate orbits get a per-period
  scan (64 samples, then a bisection on the elevation crossing).
- **A capped horizon:** 30 Earth days ahead, enough to span the 13.7-day gap. Past it the HUD says "no pass in
  30 days".
- **Spread over frames** as a counted job (≤ 1 ms a frame), cached until the orbit changes; the 1 Hz refresh only
  counts the cached window down. Worst case, a 100 km lunar orbit over 30 days: about 370 orbits through the
  pre-filter and about 20 candidate orbits scanned (an estimate; phase 3b measures it).
- It drives "Lunar Rod 2 · 4 rounds · next pass in 1 h 12 min · 3 min above 30°".

**Time the launch** is a pre-launch warp-to-window action (the warp-to-apsis pattern, snapped to ladder rungs by
the clamp). It targets the epoch the core's uplink comes online, because a strike needs it: landing epoch =
launch epoch + (mustering + transit) × 120 s, plus the core's 30 s deploy. That is exact because the ceiling holds
from launch once support is assigned, and the uplink rides in the core, so no build order delays it (§10A.2).

**Firing.**
- `CommanderPowerCommand(opId, orbitalStrike, target: objectiveId, vesselId, priority: emplacements | largest)` may
  be queued before a window ("Fire at next pass").
- It fires at the first step where the vessel is overhead, the core's uplink is online, a round is aboard,
  the vessel's cooldown is done, and ROE allows the aim point. A queued strike is saved with its priority (§13).
- On fire, one round leaves the vessel (a part, or a loadout round), and a
  `StrikeInFlight(seq, impactAtUs, targetBF, slantM)` record is created, with `seq` from the operation's saved
  counter.

**Flight and scatter grow with range**, so the orbit is a trade:

```
tof = 10 s + slant / 3 km/s                    // integer µs on the operation clock
CEP = 5 m + 5e-5 · slant                       // circular error probable
D   = crater diameter, craterForImpact for 250 kg at 3 km/s (1.1 GJ): ≈ 13 m Moon, ≈ 10.6 m Mars
```

| Orbit | Window above 30° | Slant | Flight | CEP | Emplacement kill (Moon) | Area factor, 8-member formation (r ≈ 11 m) |
|---|---|---|---|---|---|---|
| 100 km lunar | about 197 s a pass | 100–186 km | 43–72 s | 10–14.3 m | 0.66–0.8 | 0.62–1 |
| 1,000 km lunar | about 32 min | 1,000–1,418 km | 5.7–8 min | 55–76 m | 0.02–0.05 | 0.02–0.04 |
| at the 2,500 km cap | | 2,500 km | 14 min | 130 m | under 0.01 | under 0.01 |
| Earth GEO, Mars areostationary | continuous | beyond the cap | | | recon only | recon only |

- Low orbit is rare but surgical: it kills the nest. High orbit is often available, slow, and mostly suppresses
  (the morale hit and the 20 s pin land whatever the scatter).
- The cap keeps the longest flight (843 s, 7 operation days) inside the 10-day ceasefire.

**Impact in the pools** (resolver, at the start of the step that holds `impactAtUs`; no trig):
- The struck formation is the defender's emplacement at that objective (by priority) or its largest formation, ties
  by id.
- An emplacement struck is destroyed with p = 0.8 · min(1, (D/CEP)²), rolled with `combat_rng(seed, 'strike', seq)`.
- Area casualties = min(0.4 × count, (π·D² / 50 m²) × cover) × min(1, (r_f/CEP)²): members spread at 50 m² each;
  cover 0.6 at an objective with buildings, 1.0 in the open; **r_f = √(count × 50 m² / π), the struck formation's
  own spread**, not the objective's footprint. (An earlier draft used the objective: every real Port is at least
  81 ha, so the factor was 1 from any orbit and the orbit trade vanished.) The 0.4 × count cap keeps one strike
  from wiping a small pool. Removed members are half dead, half wounded.
- Morale −0.15 for every defender formation there, and the defender there is **pinned for 20 s**.
- Attackers present take the same area rule × 0.5. The UI asks first: "Danger close: 2 squads at the Port".
- Collateral at that objective += γ_ROE × 30 (§7.5). Site damage goes through `warDamageSite`: severity in
  [0.5, 1.0), non-operational, before phase 6 (a 1.0 is clamped); destruction under Standard and Heavy from phase 6.

**ROE** (§7.5, Q24): under Restrained, only at a military site (Gun Emplacement, Barracks, Military Base) with no
civilian hull within 3·D + CEP; under Standard, also the Port, Power, Airfield and Depot; under Heavy, also the
Seat. Never within 3·D + CEP of life support or a terraforming tower. Refused while rejoining terms ban
demolition. Hull positions come from the launch footprint set (§4.2), which exists from phase 1b-ii, so this works
even if 3b ships before phase 3.

**Craters** (moved up from phase 6 to phase 3b):
- Owned by the operation, quantised by the drill rule, at most 16 per battle, saved in the operations block.
- **Keyed by content:** (opId, seq, quantised aim point, quantised D). `opId` and `seq` come from saved counters,
  which a load restores, so after loading an earlier save a different strike can reuse (opId, seq); the aim point
  and size tell them apart, so a new crater is never skipped as "already recorded".
- One world `TerrainBrush` per crater draws it, **only if the crater touches no parcel or plat lot** (§7.5);
  otherwise it lives on the battle raster and as a render-side scorch only. On load a brush is re-applied only if
  its key is not already recorded: the same in-session guard the deposit pits use (`game_state_codec.dart:279-284`).
  So a crater dug after a save neither doubles after an in-session load nor vanishes after a restart.
- **Documented, as for deposit pits:** brushes survive an in-session load, so a crater dug in an abandoned timeline
  persists in that session. A fingerprint taken after an in-session load of an earlier save can therefore differ
  from a fresh-session load of the same save. The save-resume tests load in a fresh session.
- The battle raster is never re-baked for craters; the analytic shape is added on top (§8.3).

**Effects:** a velocity-stretched streak from the vessel's sky direction and a blast, through `combat_fx_pool` (cap
16 blasts). Not `Impact` events, which need a `VesselId` and share the 64-per-frame channel.

**Lifecycle:** an assigned vessel destroyed, landed or out of the SOI unassigns, with a notice. A strike in flight
when the operation ends is discarded and the round is lost (§7.6).

**Earth and Mars.** Strikes are abstract and unaffected by aero, so they work on bodies with air before the aero
fix; whether to allow that is in Q25.

### 10A.13 Fog of war: yes, for enemy units, and for what you can see and target only

- **Decision.** The map and the town stay visible: the control gate restricts acting, never seeing
  (`city_control.dart`). Enemy **formations** are Known or Unknown.
- **Spotting** is recomputed in `_combatPhase` each 1 s step, as a pure function of saved operation state. A
  defender formation is Known if any of these holds:
  - it is engaged at an objective where an attacker formation is present;
  - its objective lies within 300 m of the base core, or 600 m while the core's uplink is online;
  - it is one hop (§6.2) from an objective the attacker holds at control ≥ 0.9;
  - a vessel **assigned to this operation** is overhead under the recon predicate (§10A.12). Unassigned vessels
    are never read, so a reveal that changes which commands are accepted is always evaluated under the warp
    ceiling that the assignment holds (§5.3);
  - while a bubble is open, it is in §8.7's squad-pair line of sight.
- **Emplacements are always Known**: their Gun Emplacements are buildings on the visible map.
- **What it changes:**
  - drawer and battle-camera markers: an Unknown formation is a hatched "?" at its last-seen objective, with the
    preview's p10–p90 band instead of a count ("? 6–14 defenders"); last-seen ghosts are UI-only;
  - the unit renderer culls unseen enemies (render only);
  - **order validation:** commands may always target objectives, but only Known formations. A refusal comes back
    with a reason.
- **What it does not change:** the resolver, both AIs and the doctrine stay omniscient or target only objectives
  and emplacements, so fog cannot shift the live-against-abstract agreement that phase 4c gates, and unattended
  operations are unaffected.
- **Save-resume holds because the Known set is saved.** Spotting reads the overhead booleans of the last 1 s
  boundary, which were computed from vessel state that the save does not hold at that instant, and commands drained
  at the start of a tick are validated before that tick's step recomputes spotting. So the operation saves the last
  completed step's Known set (a bitset over defender formations) and its overhead booleans, and commands are
  validated against that saved set. A pending formation-targeted order is then accepted or refused the same way
  after a load as without one (§13).
- **Fallback (Q29):** presenter-only intel, never consulted by order validation, if validation through spotting
  proves fragile. **Gameplay fog** (AI limited by what it sees, ambush bonuses) is a later decision, before 4c.
- It lands in phase 3, the first phase where enemy positions are drawn.

### 10A.14 Selection and controls

- **Keyboard and mouse are the primary scheme**, designed first and rebindable from the first battle key (§10.4).
  Every Halo Wars PC port was criticised for tacked-on mouse controls, radial menus and fixed bindings, and
  Halo Wars' controller scheme took Ensemble 12 to 18 months.
- **The Halo Wars verbs** (all on screen, the whole force, cycle the kind, the kind's ability, jump to base or alert,
  rally, powers, build) are first-class bindings in the command view (§10.3).
- **The mouse uses the command card, never radials.** Paint-select is a pad verb; the mouse keeps the marquee.
- **A gamepad is optional** (Phase G, §10.4): XInput on Windows over the existing `ffi` first, with no new
  dependency (Q32).
- **The blob is stopped by the model**: the width cap, fortification, suppression and counters (§10.3).

### 10A.15 After the battle: what the base becomes

| Exit | The base |
|---|---|
| Won, port retaken, garrison left (§7.1) | the player's `setPost` choice (default every core-ring module, §7.1) says which modules stay as the **port garrison post**, stored in the garrison block on the target CitySim: still not buildings, so no parcels, no aggregation, no brushes. Base stock becomes garrison stock. A kept supply pad is where garrison runs land, and shortens them from 3 days to 2. Kept turrets burn 10% of their engaged ammo rate from garrison stock; an unpaid post goes offline before any trooper goes home. Unkept modules are struck (50% of their Materiel home). Outposts are always struck. Crew not kept go home |
| Won, occupied (§7.2) | **occupation garrison post**, as above. Kept turrets add 3.0 each to `garrisonStrength`, raising suppression s (secession-lane sign-off). A kept hospital heals garrison wounded on site; a kept barracks pod lets the garrison rotate its wounded home without shrinking |
| Won with no garrison left; Ceasefire; Rejoined; Overtaken (the rebels stood down); Withdrawn | **struck**: dismantled over 0.25 day; 50% of the modules' Materiel and all remaining stock go home through the sources' inboxes, pro rata to what each shipped. A share owed to a source that has seceded goes to "lost" in the materiel ledger (§7.6). A fighting withdrawal (the LZ engaged) abandons 10% of modules and stock, matching §5.4's 10% |
| Overtaken (independence) | **abandoned**, as on a loss: the people come home alive and their carried kit is lost (§7.6), and the base stock and modules fall to the new independent government |
| Lost | **abandoned**: the target takes half the stock and half the modules' Materiel as captured goods through its inbox (§7.4); the rest is lost |
| Garrison withdrawn, Restore charter | post struck: 50% of its Materiel and its stock go home. Optional **Hand over the post** (Q26): on Restore charter or rejoining, modules with a colony equivalent become real colony buildings through the colony's own `claimSite`, after the operation has ended and the gate allows it. `claimSite` debits the ore itself (`city_sim.dart:5823`), so "materials on site" are credited to the colony's ore first, then debited by `claimSite` as usual. Needs the secession and colony lanes' sign-off; off until they agree |
| Garrison expelled (§7.6) | post and stock lost, as §7.6 already says for carried stock |
| Uprising (phase 8) | the post is the player's base in the defend-the-colony battle |

- **The colony keeps growing around a post.** Once per colony day, the garrison upkeep step tests each post module's
  footprint against parcel occupancy. A module the colony has built over packs up with a 50% refund to garrison
  stock: "The garrison moved its post to make room." This needs no hook in CitySim's lot growth.
- A post is drawn as instant module nodes from the garrison block (§11.3).
- **Its positions exist from the start.** The post ships with phase 1b-ii, and so does the launch-time layout
  (§10A.3), so a post always has body-fixed footprints for the daily check, its drawing, and §7.6's "the colony
  builds over a post" row. A phase 1b-i base has no positions and leaves no post: its modules are struck at the end.

### 10A.16 Where the rest is specified

- Frozen-map additions: §8.2. Raster and craters: §8.3. Unit rows: §8.4. Hits and strike blasts: §8.5. Calibration:
  §8.9.
- Commands, validation and tests: §12. Saves: §13. Player-facing wording: §14. Rendering and budgets: §11.
- Phasing: §16 (phase 1 plumbing, 1b-i and 1b-ii the base, 3b orbital support, G gamepad). Risks: §17.
  Ownership: §18.
  Questions: Q22–Q36.

## 11. Rendering, effects and performance

### 11.1 Combat channel

- **`CombatFrame`** (`lib/application/snapshot/combat_frame.dart`): typed columns passed by reference,
  double-buffered and stamped with the tick. It copies the `CityTrafficFrame` pattern rather than importing it.
  - units: handle, kind, faction, flags, previous and current pose, heading, health bucket, pose code;
  - shots this tick, blasts, objectives (control, owner), and site damage;
  - base sites (ring, owner), modules (kind, state, progress bucket, hp bucket), strikes in flight (release
    point, target, `impactAtUs`), and the Known flag per defender formation (§10A.13).
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
  - objective rings and front arrows sit in the combat overlay;
  - **the base**: socket rings in `CombatOverlayState`, clickable, opening the Base tab's module list for that
    socket (the command card replaces it in phase 5); module hulls as instant nodes (below), with scaffolding that
    rises with build progress (render-only);
  - **supply drops and hot-drops**: a render-only descent and touchdown at the pad or LZ, timed to the abstract
    arrival (§9.3). They are effects in the pool, never Vessels, so they hold no warp and take no ground sample
    (the touchdown height is the module plinth or the drawn mesh, as for module nodes).
- **Module nodes** follow the `BuildingPreviewNodes` pattern (`building_preview_nodes.dart:203`) and
  `instant_road_nodes`: `BuildingMassing.massFor` of the module's borrowed shell spec ('barracks',
  'gunemplacement', 'warehouse') on a synthetic socket parcel, which is pure and builds in milliseconds. Never the
  city tile worker pool. At most 20 nodes per base (11 at the core, 3 at each outpost). In phase 3, before the
  raster exists, each node takes its height once from the drawn terrain mesh, the render-side query §8.3 already
  uses, and caches it; from phase 4a it sits on the sim's raster datum. A garrison post (§10A.15) draws the same
  way from the garrison block.
- **Strike effects** (phase 3b): a velocity-stretched streak interpolated from the vessel's sky direction to the
  target over the flight time, and a blast scaled to the crater, from the pool's caps. Never `Impact` events.

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
| Abstract resolver | ≤ 0.05 ms per operation per colony tick as a hard ceiling; ≤ 4 concurrent operations. The expected cost of one 1 s step is a few µs, and the preview needs it (§6.5) |
| Preview | ≤ 2 ms a frame, done within about a second: about 120 ms of CPU for 32 seeds × 1,200 steps, so about 3 µs per step including the base; 16 then 8 seeds if the base or support pushes past it (§6.5) |
| Raster bake | worker pool during transit; on web, counted ≤ 1 ms per frame on a 600 m square; never at join unless a replayed `JoinBattle` forces it (§8.1) |
| Phase 3 FX | ≤ 0.4 ms, ≤ 8 translucent draws |
| Live sim, 48 units | per tick: movement ≤ 0.1, fire ≤ 0.15, LOS ≤ 0.25, paths ≤ 0.45, AI ≤ 0.1 ms. Turret rows are among the 48 (their crews count against `liveCap`, §8.1): they fire and need LOS but never move or path |
| Live module rows (≤ 20, outside `liveCap`) | hit tests only, no scan, fire, LOS or path: ≤ 0.02 ms per tick |
| Live unit draws | ≤ 24 colour + ≤ 48 shadow draws ≈ 0.6 ms |
| Live FX | ≤ 0.5 ms, ≤ 6 translucent draws |
| Combat HUD | ≤ 0.3 ms |
| Base step (≤ 4 sites, ≤ 20 module and turret sockets) | ≤ 2 µs per 1 s operation step including the doctrine, so resolver plus base fit the preview's 3 µs a step; allocation-free. Measured in phase 1b-i; if it misses, the preview drops seeds (§6.5) |
| Overhead gate | one rotate and two dot products per assigned vessel per step, ≤ 0.001 ms |
| Strike-window predictor (domain math, UI-only result) | a counted job, ≤ 1 ms a frame, spread over frames on planner open and on an orbit change, cached; the 1 Hz refresh only counts down (§10A.12) |
| Base nodes | ≤ 20 nodes, instanced by kind into ≤ 12 draws, ≤ 0.15 ms; rebuilt only when a module changes |
| Module completion (live) | ≤ 16 cover cells and one line-of-sight flush, counted; no flow-field work |
| Strike FX | inside the 16-blast cap |
| **Total live add** | **≤ 2.5 ms average, ≤ 4 ms worst, or less if the measured flight-view baseline requires it (above)** |

**How the total adds up.** The sim rows are per 50 Hz tick, the render rows per frame. At 60 fps a frame averages
50/60 of a tick, so the sim's 1.05 + 0.02 = 1.07 ms per tick costs about 0.89 ms a frame. With draws 0.6, FX 0.5,
HUD 0.3 and base nodes 0.15, the average is about 2.44 ms, inside 2.5. A frame that runs two ticks costs about
2.14 + 1.55 = 3.69 ms, inside the 4 ms worst. The margin is under 0.1 ms on average, so Spike S item 4 and the
phase 4a bench must confirm the rows, and any overrun is taken from the render rows (the shed ladder), never from
the sim's counted budgets.

**Hard rules:**
- no per-unit field query;
- no ground sample in the renderer;
- no O(N) `siteAt` per unit;
- no field sample for the base: plinths use the raster mean (§8.2).

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
  - phase 4: `JoinBattle` (carries `liveCap`), `LeaveBattle`, `AvatarInput`, `SquadOrder`. The X call-in is
    `CommanderPower(hotDrop)`, so there is no `CallReinforcements` command;
  - phase 5: `Possess`;
  - phase 7: `PilotInput`.
  - **The Halo Wars layer adds four families**, grouped so that each exhaustive switch changes once per family:
    - phase 1b: `BaseOrder(opId, verb, siteId?, socket?, kind?, arg?)`, with verbs build, cancel, demolish,
      upgrade, specialise, repair, openOutpost, setDoctrine, autoBuild, assignCrew, formSquad, setRally,
      setManifest, reinforce, redeployCore and setPost (the modules kept as the garrison post, rule 3); and
      `UnitAbility(opId, formationId | squadHandle, ability, target)` (abstract; live from 4a). §10.1 lists the
      same verbs;
    - phase 1b: `CommanderPower(opId, power, target, vesselId?)` with supply drop and Medevac; hot-drop from phase 3,
      the orbital strike from 3b, silo and gunship from 7. Recon is passive, never cast;
    - phase 3b: `AssignOrbitalSupport(opId, vesselId?)`, which accepts unarmed vessels as recon-only assignments,
      and `ArmVessel(vesselId, colonyId, rounds)`, which fills rounds at a real cost in either route (Q23).
  - **`PlaceBuildingCommand` is not reused**: it is cell-grid, colony-targeted and inert (§2).
  - **Validation** runs in `_combatPhase` and refuses with a reason, changing no state: socket blocked, home gate
    missing, short of Materiel, no crew, target Unknown in the last completed step's saved Known set (§10A.13), ROE
    forbids, not overhead (queued instead), conversion over the source's trooper cap (§4.1).
  - These are combat commands, not colony acts: no gate check and no `attend()`. The Command and base posture is
    `acts: false`, with a documented exemption in the gate sweep test.
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
- **Every live colony read the operation makes:** at launch, the target's `LaunchSnapshot` (§4.2, §8.2) and each
  source's `SourceSnapshot` (§4.1); per tick, only outbox events (§5.3). Nothing else. The hygiene test (below)
  enforces it by banning any `CitySim` import under `lib/domain/combat/resolver/**`, `live/**` and `base/**`; only
  `launch/` (which builds both snapshots) and the outbox adapter may read a colony.
- **The world reads** (from phase 3): the authoritative tick-end state of vessels assigned to an operation, by id
  (§5.3). Only `landers/lander_watch.dart` (phase 3: touchdown, crash, landing offset) and `powers/overhead.dart`
  (phase 3b: a boolean per step) read it. The hygiene scan bans vessel and orbit imports under `resolver/**` and
  `base/**`.
- **The world writes:** `Vessel.releaseOrdnance` (real-parts route) and crater brushes clear of parcels and plat
  lots, both from step 3 of `_combatPhase` (§5.3). The hygiene scan allows each in its one file.
- **The determinism fixture.** `CombatFixtures` (`test/combat/fixtures.dart`, shared with the calibration tool and
  the dev hook):
  - `portSeizedPair()`: a source colony of about 400 with an Arms Factory, a Rations Plant, a ready Barracks, a
    Warehouse (stock cap 700), a Hospital and a Spaceport (the home gates for the pad and the field hospital), and
    stock: 700 ore (so 300 Materiel is half of it), steel, electronics, fuel, medicine and the kit; a target colony
    in standoff with `portSeized` (desperation > 0.4, `city_loyalty.dart:621-624`), on the same body. Without the
    Warehouse a source holds at most 200 ore (`city_sim.dart:367`, clamped every tick) and could ship only 100;
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
  - an allocation-free steady state;
  - for the base: integer centi-unit stocks, integer-µs build and cooldown timers, the power ratio in 1/64ths, and
    ids from saved counters (`nextModuleId`, `nextStrikeSeq`, the lander sequence).
  - No trig under `lib/domain/combat/resolver/**` or `base/**`. The socket layout lives in `launch/`, and the
    overhead test uses dot products only. Live locomotion may use trig, with the same-platform caveat documented.
- **`combat_source_hygiene_test.dart`** (template: the traffic hygiene test) bans `Random`, `hashCode`,
  `Object.hash`, `DateTime`, `Stopwatch`, map/set iteration, and any import from `traffic/`. For the base it also
  bans, anywhere under `lib/domain/combat/**`: any reference to `kUtilCatalog`, `placeOnParcel`, `placeUtil`,
  `claimSite` or `PlaceBuildingCommand`, any `kDeliveryPeople` or relief-drop path, and any `TerrainBrush`
  construction outside `powers/crater.dart`.
- **Fingerprint.** A `%` block appended only while operations exist (the atmosphere precedent). It is an FNV
  digest over quantised operation state and, while live, the unit columns. With the base it also covers tier,
  sockets, module states and progress µs, stocks and pallets, crew, cooldowns, assigned vessels, strikes in flight,
  craters, and the loadout registry if used.
- **Tests** (all on `CombatFixtures`, so colony state is part of what is compared; the existing
  `save_resume_determinism_test.dart` fingerprints vessels only):
  - twin-run;
  - save-resume, mid-operation, including a save on the exact tick a source-colony write is queued;
  - warp equivalence (25 × 0.02 s against 1 × 0.5 s), on a fixture with no vessel assigned and no lander in flight;
  - frame-hold equivalence (held against inline colony), in phase 1 on abstract objectives, **in phase 1b-i with a
    supply run in flight from a held source** (its arrival step and ledgers must match), and **again in phase 4a on
    a joined operation, with the target colony held and a time-dilation event set on it directly**. The run ends
    before the event does, so no chained pick draws `math.Random()`. The event must not change the operation's
    ledgers;
  - the lifecycle rows of §7.6 and the exit rows of §10A.15;
  - join/leave conservation;
  - the calibration harness;
  - **for the base** (phase 1b-i on): twin-run with the doctrine on; save-resume mid-build at an exact µs and with a
    supply run in flight; warp equivalence with a queued build; doctrine determinism, including that it reserves
    crew for modules still on its list and never converts support staff; **the preview equal to the real run on
    a fixture where every run ships in full and no orbital vessel burns**; the pairwise resolver with M ≡ 1
    against the closed form (the 174 s pin); the `F_att` / `F_def` rows ("defender raid on a Fortress LZ" costs
    the defender more than open ground) and the structure rows ("first module offline in 1–3 fair fights"; "one
    cheap module lowers attacker losses by no more than its own hp"); catalog isolation (`kBaseModules` absent
    from `kUtilCatalog` and `kZoneSpecs`); `TerrainEditsRepository` unchanged across an operation except by its
    own keyed craters (on the fixture, where no colony builds);
  - **the personnel invariant**, every step: everyone mustered (troopers and support staff at launch, plus every
    reinforcement mustered) = in formations (live rows and turret crews included) + crew + LZ reserve + wounded +
    in flight (aboard a lander, or in an attacker reserve formation not yet landed) + in a garrison + dead +
    returned + deserted. A conversion moves a person between terms and changes no total;
  - **materiel conservation**, per commodity: source debits (launch, runs, reinforcement kit) + salvage landed +
    captured guns + converted in (workshop output) = base stock + unopened pallets + in flight (runs and salvage
    not landed) + the spare core kit + spent (builds, upkeep, abilities, rounds) + converted out (workshop inputs)
    + refunded + captured by the target + lost. On the target side: guns armed + salvaged + captured ≤ the
    `LaunchSnapshot`'s gun stock;
  - **phase 1b-ii:** the socket layout is a pure function (the same launch footprint set gives the same sockets,
    bit for bit, and no socket overlaps a hull, pad, road, parcel or plat lot); the post's daily footprint check;
    the re-established core uses its objective's outpost sockets;
  - **phase 3:** spotting determinism (the same Known set in twin runs and after save-resume); the lander warp
    level (a 1,000× request while a force lander descends yields 1×, and the lander touches down within 8 m of
    the planned point on the Moon fixture); the landing-offset deploy delay; a reinforcement lander crash charges
    its dead home;
  - **the warp ceiling** (phase 3 for landers, 3b for support): a 1,000× request yields 1× while a lander descends
    and 10× while only support is assigned; **warp-to-apsis with support assigned stays at or below 10× and only on
    rungs whose ticks divide 1 s**; **a load of a save taken at 1,000× with an operation holding the ceiling comes
    back at the ceiling**; touchdown or release lifts it; operation µs equals world µs throughout;
  - **for orbital support** (phase 3b on): tick-size equivalence with an orbital vessel whose windows open and
    close at least 2 steps from a step boundary. A coasting vessel in vacuum is on rails at 1× and at 10× alike
    (`advance_simulation_tick.dart:305-307`), so this compares rails at 0.02 s ticks against rails at 0.2 s ticks,
    whose per-tick re-fit rounding differs; plus one case with a station-keeping burn (physics) at 1× inside a
    window. Also: the overhead predicate against hand geometry (GEO at latitude 45° is about 38° up); recon only
    from assigned vessels; the predictor against a brute-force sampler; flight time, CEP and crater against
    `impact_scaling`; a Restrained strike allowed at an emplacement with no civilian hull in range and refused
    with one; a Standard strike at the Port emitting no world brush (it touches a parcel); save-resume between a
    strike's release and impact; crater re-apply idempotence after an in-session load, and a different strike
    with the same (opId, seq) after loading an earlier save still digging its crater;
  - **save-resume with Halo Wars state:** a save with a queued "Fire at next pass" strike, a dug-in defender, a
    pinned formation, a hot-drop under deployment fatigue, a 60 s hold timer running, and a pending
    formation-targeted order, resumed in a fresh session, matches the uninterrupted run;
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
  - counters (`nextOperationId`, `nextFormationId`, lander sequence, `nextModuleId`, `nextStrikeSeq`);
  - the quantised raster, once baked;
  - **the base** (from phase 1b): tier; the socket layout (or "abstract") and, per socket, kind, state, progress
    µs, hp, specialisation and crew; outposts; build lines and queues; Auto-build flags; stocks, pallets, the
    power and personnel ledgers and the LZ reserve; doctrine and powers policy; rally; the post choice
    (`setPost`); ability and power cooldowns; the spare-core-kit flag; supply runs, reinforcements and salvage
    requisitions in flight, each with its fixed arrival µs, posted manifest and confirmed amount (or "awaiting");
  - **timed and queued state** (from phase 1b): queued powers and "Fire at next pass" strikes with their priority;
    Dig in accumulators per defender formation; the 20 s pin after a strike; deployment-fatigue timers; every 60 s
    hold timer (the win hold, overrun, outpost eligibility, razing); the target-side gun pool and the guns in
    militia hands (§4.2);
  - **fog** (from phase 3): the last completed step's Known set, a bitset over defender formations (§10A.13);
  - **orbital support** (from phase 3b): the assigned vessel ids (armed or recon-only); the last step's overhead
    booleans per vessel; `StrikeInFlight` records; craters keyed (opId, seq, quantised aim point, quantised D),
    with their quantised shape and whether each emitted a world brush.
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
    the UI, so a command enqueued and not yet drained would otherwise be lost;
  - the `VesselLoadoutRegistry` (vessel id → rounds), only if the loadout fallback is chosen (Q23). With real
    ordnance parts, rounds persist with the vessel and need no ledger. In either route, each `ArmVessel` still
    loading is saved with its ready µs and confirmed rounds (§10A.12);
  - **not saved:** the warp ceiling, which is derived on load from the operations and applied by the clamp right
    after the load (§5.3); and the strike-window predictor, which is UI state. Spotting is recomputed each step,
    but the last step's Known set and overhead booleans are saved with the operation (above), because commands
    are validated against them.
- **CitySim additions,** additive and omitted at defaults:
  - the `siteFactor` entries, with deployed share, damage and the power cut saved as three separate terms (§4.1),
    the port garrison and its carried stock, the occupation block and `forceUsed`;
  - wounded troopers' redeploy timers (2 days, §4.1);
  - `Grievance.warDead`;
  - the **garrison post** in the garrison block: module kinds by name from `kBaseModules` (never through
    `_specByLabel`), hp, and anchors body-fixed (§10A.15).
- **Quiesce first:** `flushHeld` before encoding, as `_save` already does (`simulation_view.dart:2699-2701`).
  Replaying the held ticks drains those colonies' `ColonyCombatInbox`; every other colony drained its inbox in
  this tick's `_cityPhase`, because `_combatPhase` writes before the city loop (§5.3). The encoder then asserts
  every inbox and outbox is empty. If one is not (a bug, or a future write path), it is encoded as a `pending`
  list on that colony rather than dropped.
- **Craters (from phase 3b for strikes, phase 6 for heavy weapons)** are saved in the operation and their brushes
  re-applied on load, keyed by content (opId, seq, quantised aim point and size), only when that key is not
  already recorded in the session (§10A.12). Craters that touch a parcel or plat lot have no brush and are only
  redrawn on the battle raster. An abandoned timeline's craters persist within a session, as deposit pits do.
  General terrain-edit persistence would replace this and fix impact craters too (Q13).
- **Mid-operation saves stay valid with the base**, because it is abstract state. A live fight is still left
  before saving (Q10); live module rows collapse back into their hp.
- **Not fixed here:** the world save is still one in-memory string. Combat makes a durable slot more urgent.

## 14. UI

All wording is player-facing, because master ships to prod.

**Where the combat UI lives.** Force is a flight-world feature (Q20), and the strike countdown matters most while
the player flies the armed vessel. `CityGameHud` is shown only `if (widget.cityMode && _editingCity != null)`
(`simulation_view.dart:3460-3464`) and drains one colony's `city.loyalty.notices` (`city_game_hud.dart:95-99`), so
it cannot host operation UI. The HUD chip, the operations drawer and its Base tab, the powers row, the orbital chip
and countdown, the warp-ceiling notice and operation notices therefore live in the combat lane's
`simulation_view_combat.dart` and `screens/combat/**`, visible in city mode and flight mode alike. The command card
is `screens/combat/command_card.dart` (combat lane, phase 5). Only colony-state notices (`portRetaken`,
`occupied`, `garrisonExpelled`, `troopersDeserted`) stay in that colony's loyalty queue.

- **Planner sheet** (`screens/combat/operation_planner_sheet.dart`). It opens from the port's site-sheet row
  (phase 1) and the Reclaim Force row (phase 2), and shows:
  - each source, its ready troopers, and why others are not ready ("Barracks short of ammo");
  - trooper sliders and days of kit;
  - from phase 1b, a **Forward base** section: "Ore for the base: 300" (the default is what the sources can give,
    with "Build warehouses at home to ship more" when a source is near its cap); "Base crew: 10 support staff from
    Barracks A"; fuel and medicine for the base; up to 2 modules **landed ready**; a spare core kit; the doctrine
    (Balanced, Hold, Push, Manual); the powers policy; and **Ship light (no base)**, shown beside the base option
    with its own histogram when the preview says the fight will be short, as a trade, not a default (§6.5);
  - from phase 3b, **Orbital support**: the player's vessels around the target body, armed or not, with their
    rounds ("recon only" for an unarmed one) and next windows ("Lunar Rod 2 · 4 rounds · next pass in 1 h 12 min ·
    3 min overhead"), **Time the launch**, the "Orbital weapons free" tick, and the warp-ceiling lines ("While
    support is assigned, warp is held at 10×"; "While landers come down, warp is held at 1×");
  - "why not" lines for gates ("A Fortress needs a Military Base in a source colony", "Kestrel has no rounds");
  - ROE;
  - the goal: retake the port, or occupy with a garrison size;
  - the LZ (automatic; a draggable pin from phase 3);
  - the outcome-band histogram and casualty ranges;
  - the costs in plain words ("Troopers are your colonists", "Force wins no loyalty", and for a standoff
    colony "Retaking the port reopens it: settlers who cannot be fed will leave", §7.1).
  - Then **Launch**, and from phase 4 **Launch and join**.
- **HUD chip.** "Retaking the spaceport · day 1.4 · ▰▰▰▱▱ · Base 4/5". From phase 1b a second line reads
  "Materiel 240 (+1.5/s) · Power 18/20 kW · Personnel 25/25 · Kit 2.6 days", with a powers row (cooldowns and
  reasons), an orbital chip ("OVERHEAD 2:41" or "next pass 18:20"), and the warp-ceiling notice when it holds. It
  opens the **operations drawer**:
  - objectives with control bars; Unknown defenders as "? 6–14" (§10A.13);
  - formations with morale and kit;
  - orders (phase 3), Withdraw, and Join (phase 4);
  - a **Base tab** (phase 1b): the socket grid with progress bars and "+" on empty sockets (opening the module list
    with costs, gates and reasons), build lines and queue, stocks and pallets, the power bar, crew, rally, the
    Auto-build toggle, the post choice, and outposts. From phase 3, clicking a socket on the battle camera opens
    this list; the command card's build page replaces it in phase 5.
- **Notices.** Operation notices go through a world-level `OperationNoticeQueue` (combat lane), drained by the
  combat HUD in both modes, with a toast in the flight view: landed, objective taken, squad broken, kit out, won,
  lost, `operationOvertaken`. Colony-state kinds stay in `LoyaltyNoticeKind` (`city_loyalty.dart:251-269`), in the
  colony's own queue, and are listed in the secession lane's sign-off (§18): `portRetaken` ("Your troopers have
  retaken the spaceport"), `occupied`, `garrisonExpelled`, `troopersDeserted`, `postMoved`. None reuses
  `portReleased`. The base adds, all in the operation queue, `coreDeployed` ("Base core deployed at the landing zone"), `moduleBuilt`
  ("Turret online at the base"), `moduleLost`, `baseOverrun` ("The base has been overrun: supply runs have
  stopped"), `suppliesLanded`, `suppliesCaptured`, `outpostOpened`, `outpostLost`, `autoBuildOff` ("Auto-build off
  at the base"), `orbitalOverhead` ("Lunar Rod 2 is overhead for 3 minutes"), `orbitalLost` ("Orbital support
  lost: Lunar Rod 2 has left the battle"), and `strikeAway` ("Strike away: impact in 0:43"). `postMoved` ("The
  garrison moved its post to make room") is a colony notice, because the post is garrison state.
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
  - what the player personally did ("You took Pad 2");
  - the base: what was built, Materiel spent, salvaged and returned, strikes fired and what they hit, and the
    base's fate (garrison post, struck, or abandoned).
- **Battle camera (phase 3):** socket rings, module nodes with scaffolding, clickable sockets that open the Base
  tab's module list (§10.1), drawn supply drops, outposts, and Unknown markers.
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
- **Dev hook:** `ext.acro.combat` (plan, launch, join, order, build, power, fire, possess, status JSON with the base
  and the overhead state), driven by
  `tool/drive_city_game.dart --script`. `main_city_game_dev.dart` founds one colony (`id: 'city-dev'`, `:109`),
  so `ext.acro.combat?fixture=portSeizedPair` loads the §12 fixture world, and `?step=<s>` runs world ticks
  (the existing `_step` advances only the colony, `:447-461`, which steps no operation).

## 15. Alternatives considered

The first three entries lost to the Operations Ledger (§3); the next two lost the Halo Wars round to Beachhead
(§3.1).

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

**The Halo Wars layer: Fire Support (14.1).**
- *Why it lost:*
  - It held warp "at 25×" while support was assigned; the ladder has no 25× rung, so the real cap is 10×, and its
    cost estimate rested on the wrong figure. It missed `SimHost`'s 1.0 s step and the phase 3 lander drift.
  - Its outposts stood on unbuilt colony lots and parcels: colony land the town can grow onto after launch, which
    brings ROE and the term guard back into play.
  - Reactor pods and four tech tiers inside the battle are an in-battle tech tree, the scope creep it listed as
    its own risk. Its outposts were new graph nodes, raising the Dijkstra cap from 8 to 12.
  - The orbital strike defaulted to phase 7, the user's headline twist last.
- *What this plan took from it:*
  - one spendable Materiel number, unpacked from shipped pallets by the core and supply pads, with 25% ready on
    landing;
  - the `supplyDays` → `kitDays` rename;
  - outposts at held objectives as the expansion loop (here attached to existing nodes, off colony land);
  - holding the warp ceiling only while orbital support is assigned (extended here to landers in flight);
  - the missile-loaded vessel loadout as the fallback for "armed";
  - the overhead gate defined at step-boundary epochs, with the resolver given only a boolean;
  - the garrison post's once-a-day footprint check;
  - the catalog-isolation and no-terrain-edit tests;
  - presenter-only fog as the fallback in Q29.

**The Halo Wars layer: Military Plat (14.0).**
- *Why it lost:*
  - Its phase 3 recon pass used the overhead predicate, and fog gated targeting, but its warp cap arrived only in
    phase 7, so a reveal that affects commands was evaluated at uncapped warp in phases 3–6.
  - It claimed §2 miscounts the command cases; `command.dart` has exactly five.
  - It missed `SimHost`'s step and the lander drift. Its "high orbit always available" pitch contradicted its own
    2,000 km range cap.
  - Real `CityBuildingSpec`s and `Parcel`s on a military plat, checked in the editor's order, bring colony-shaped
    types into combat for little gain, and a mixed-goods economy shows four numbers where Halo Wars shows one.
  - The orbital strike defaulted to phase 7, with massless rounds.
- *What this plan took from it:*
  - socket footprints blocked from the first bake, so modules never invalidate paths, and pad datums from the
    raster mean;
  - strike flight time and scatter that grow with range (with the range cap set so the trade holds);
  - command families;
  - the `structure` target class and `structureShare`;
  - the defender's Dig in;
  - the option to ship light, with no base;
  - optional Hand over the post, as Q26.

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
- **Base modules as CitySim buildings, or a base colony:** the rebels would own them, the target would be
  re-platted and brushed mid-fight, attention would be stamped, and saves would drop them (§10A.1).
- **Reusing `PlaceBuildingCommand`:** cell-grid, colony-targeted, and inert on every path.
- **Strike rounds flown as Vessels:** warp-dependent impact points, the destruction cheat, unsaved craters, a
  ground sample per tick, and unsaved spawn ids (§2).
- **Strikes gated on instantaneous line of sight at any warp:** outcomes would change with warp. The warp ceiling
  is the fix, and launch-time coverage charges (decide coverage from the orbit at launch, then spend charges on
  an operation cooldown) were considered and kept only as a fallback if the ceiling feels bad (Q22).
- **A warp ceiling for every operation:** a large change to how the game feels, for a twist many operations do not
  use. It holds only while orbital support is assigned or a lander is in flight.
- **Supply runs and hot-drops as real landers:** a run every 1.5–3 operation days would hold warp at 1× for much
  of every operation, and a flown touchdown cannot meet the fixed arrival time the frame-hold rule needs (§5.3).
  They are abstract arrivals drawn as descents.
- **A ceiling hook in `_stepWarp`:** warp-to-apsis, the atmosphere lock and loading all write the factor directly,
  so it could not hold. One clamp before the tick loop replaces it.
- **One fortification value for both sides:** it divided only the attacker's damage, so base turrets protected the
  rebels raiding them (§6.2).
- **Gameplay fog before phase 4c:** fog that limits the AI would shift the agreement 4c gates.
- **Radial menus on the mouse:** the standard complaint about Halo Wars on PC.
- **A pub gamepad plugin first:** it would be the first native Windows plugin against a pinned master engine.
  XInput over the existing `ffi` comes first.

## 16. Phases

Each phase is approved separately. Each one is useful if it is the last. A phase's **gate** is a named local
command that must pass before approval (`fvm flutter test test/combat`, plus the tools named below), because the
repo has no test CI (§8.9).

**Rough sizes.** No phase has been estimated from measured work; these are guesses from the scope lists, given
only so each approval can be weighed against phase 1. Each is re-sized when its phase is planned in detail.

| Phase | Size, phase 1 = 1 | Where most of it goes |
|---|---|---|
| 1 | 1 | the resolver and preview, `siteFactor` in CitySim's hot loop, the inbox and outbox, codec v3, the planner |
| 1b-i | about 0.6 | `ForwardBase`, the core with its landing turret, three modules, Materiel and pallets, one build line, Balanced, abstract overrun |
| 1b-ii | about 0.9 | tiers, four more modules, power, three doctrines, two powers, counters and abilities, the launch footprint set and layout, the garrison post |
| 2 | about 1 | occupation and the secession-lane changes, three objectives, ROE, salvage and outposts |
| 3 | about 1.2 | real landers and the warp clamp, the battle plumbing and camera, fog, module nodes |
| 3b | about 0.7 | the overhead gate, strikes, the predictor, craters, `ArmVessel` (plus the parts lane's work if real parts are chosen) |
| 4a | about 2 | the worker-pool bake (about a week on its own, §8.3), the unit table, the avatar and collision, the unit renderer, the input action layer |
| 4b | about 1.5 | navigation, line of sight, squad and side AI |
| 4c | about 0.5 | tuning against the harness; open-ended by nature |
| 5 | about 1 | the command camera and posture, selection, the command card |
| G | about 0.3 for G1 | XInput over `ffi`; G2 is a separate spike |
| 6, 7, 8 | about 1.5 each, or more | vehicles; flying and call-ins; rivals and networking |

**Spike S: measurements, no gameplay.** It runs alongside phases 1–2, all headless except items 4 and 5, and its
results are written into this plan before phase 4a is approved (item 6, added with the base, before phase 1b-ii's
layout). Each item has a pass line. A miss stops the phase it gates for a decision; it does not quietly
lower the bar.

| # | Measures | Pass line | If it misses |
|---|---|---|---|
| 1 | Ground sample cost: `surfaceRadiusAt`, `baseGroundRadiusAt`, `groundRadiusAt` per sample on a settled starter town and the reference colony, plus the share of a 1.2 km square under any brush | the worker pool bakes 1.2 km at 8 m within 90 s (0.75 operation days at 1×), with ≤ 1 ms a frame on the main thread | shrink to 800 m; if 800 m misses too, phase 4a waits for a cheaper field query |
| 2 | Navigation: 4 squads, 3 objectives, flow fields through hull prisms on a real graded town, 20 scripted seeds | at most 1 stuck squad (no progress for 30 s) in 20 runs; ≤ 3,000 expansions a tick held | phase 4b is re-planned before approval (4a needs no navigation) |
| 3 | Drawn vs simulated: `massFor` hulls against drawn buildings on 50 samples; terrain mesh against field at the reference colony on 200 points inside a battle square | hull error ≤ 0.5 m at p95; terrain mesh error ≤ 0.3 m at p95 | hulls: a conservative inflation and a contract with the archetype owner; terrain: the decision in §8.3 |
| 4 | Render increment: 48 instanced primitive soldiers and 500 tracers in the flight view at the reference colony | within the §11.5 rows (draws ≤ 0.6 ms, FX ≤ 0.5 ms); confirms the 110 ns and 16 ns estimates within 2× | fewer pose batches; a lower `tracerCap` |
| 5 | Flight-view baseline: static, walking and orbit, in city mode and flight mode, at the reference colony | sets the battle gate and the live add (§11.5); passes if it leaves ≥ 1.5 ms of headroom under 16.7 ms p75 | phase 4a starts by moving the flight-view walker onto the raster |
| 6 | Socket room and fit (headless, the base layout function of §10A.3, on the launch footprint set): free sockets at the best LZ candidate, free outpost ground beside each goal objective, and whether the LZ's whole turret ring and at least 100 m of the clipped goal fit one square (§8.3), at the reference colony and three starter towns, in 1.2 km and 800 m squares (600 m reported only, for web) | at the best LZ, ≥ 5 of 7 module sockets and 4 of 4 turret sockets free, and the fit holds at 1.2 km and 800 m; outpost ground at ≥ 2 goal objectives | widen the ±25° step range or the ring radii; cap the base at Station size; outposts are offered only where room exists. If the fit fails, a second baked square for the LZ is planned before 4a. **Gates phase 1b-ii's layout**, not 4a |

**Phase 1: Retake the port (auto-resolve, no units on screen).**
- *Prerequisites:* none.
- *Domain:* `lib/domain/combat/`: `FactionId`, `combat_rng` with its pin test, the operation clock,
  `Operation`, `OperationRegistry` and `LaunchSnapshot`, `Formation`, `ObjectiveGraph` (Port and LZ), the
  resolver, the preview, the abstract AI, the lifecycle rules of §7.6 that apply to a port.
- *Plumbing for the Halo Wars layer, with no visible change:* the resolver is built in the pairwise form with
  `counterClass` on every formation and `CounterTuning` as M ≡ 1, so phase 1's 174 s pin is the §6.3 figure; the
  field is named `kitDays` from the start; the LZ objective carries an empty module list, so phase 1b adds rows
  without migrating saves.
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
  and frame-hold equivalence, the calibration table (its first row pins §6.3's 174 s), the re-seizure guard, the
  no-secede-on-win pin (§7.1), the `portRetaken` notice text, the §7.6 port rows, `siteFactor = 1` leaving every
  aggregate bit-identical, the hygiene scan, AOT smoke, the gate sweep for the new row, and a headless
  **reachability scenario**: a starter colony played by script to 300 population with an Arms Factory, a Rations
  Plant and a ready Barracks.

*Ships:* a colony whose rebels seized its spaceport can be retaken with troopers from another colony's barracks.
The outcome is previewed and seeded, with real deaths, spent supplies, a loyalty cost, and a garrison that stops
the rebels taking it straight back. The planner says plainly that the standoff continues, and that settlers
who cannot be fed will leave. It saves and loads mid-operation.

**Phase 1b is split in two,** because as one approval it was larger than phase 1.

**Phase 1b-i: The base core (new).**
- *Prerequisites:* phase 1. Independent of phase 2, and may follow it instead (Q35).
- *Domain (`lib/domain/combat/base/**`):* `ForwardBase` on the `Operation`; the abstract core deploy with its
  landing turret; the Firebase tier only (3 module and 2 turret sockets, one build line), socket indices only;
  `kBaseModules` with the supply pad, HMG turret and barracks pod; up to 2 modules landed ready; µs timers,
  pay-up-front and refunds; Materiel, pallets, unpacking and stocks in centi-units; support-staff crews, the LZ
  reserve and the personnel cap; resupply within one hop; abstract operation supply runs at fixed arrivals
  (§5.3); `F_att`; `structureShare` with hp-weighted soaking; abstract overrun; the Balanced doctrine; the light
  operation.
- *Aftermath:* the base is struck or abandoned (§10A.15); there is no post yet.
- *Commands:* `BaseOrder` (build, cancel, demolish, repair, assignCrew, formSquad, setRally, setManifest,
  reinforce), all `UnsupportedError` on the wire.
- *Saves and digest:* the base in the codec v3 `operations` block and in the fingerprint.
- *UI:* the planner's Forward base section, the combat HUD's second line and the drawer's Base tab (both in
  `simulation_view_combat.dart`, §14), the operation notices, the after-action base lines.
- *Tests:* twin-run, save-resume mid-build, warp equivalence with a queue, frame-hold with a supply run in flight
  from a held source, doctrine determinism and crew reservation, preview equals the real run (full manifests),
  the personnel invariant, materiel conservation, catalog isolation, no terrain edit, the `F_att` and structure
  calibration rows, the hygiene bans, the gate-sweep exemption, AOT smoke over the base step.

*Ships:* "Your operation lands a base. Build turrets, a supply pad and a barracks pod from the operations drawer, or
let it build itself." The base changes the fight with no units on screen, and an operation nobody watches builds
the same base.

**Phase 1b-ii: The full base and the post (new).**
- *Prerequisites:* phase 1b-i; Spike S item 6 passed.
- *Domain:* the Station and Fortress tiers (Fortress behind a source Military Base); Stores, field hospital,
  generator and munitions workshop; power and brownout; the Hold, Push and Manual doctrines and the powers policy;
  the **launch footprint set** (§4.2) and the pure `base_layout.dart` (§10A.3) with the automatic LZ picker, so
  sockets and outposts have positions from here on; the spare core kit, re-established outpost-sized.
- *Combat:* real INF, EMP and STR values in `CounterTuning` (the emplacement calibration rows re-pinned
  deliberately); the abstract abilities (charge assault, jump jets on airless bodies) and the defender's Dig in;
  the powers emergency supply drop and Medevac.
- *Aftermath:* the port garrison post (§7.1, §10A.15) with its daily footprint check.
- *Commands:* the rest of `BaseOrder` (upgrade, specialise, setDoctrine, autoBuild, redeployCore, setPost),
  `UnitAbility`, `CommanderPower` (supply drop and Medevac), all `UnsupportedError` on the wire.
- *Saves:* the timed and queued state of §13; the post in the garrison block.
- *Tests:* layout purity, the post's footprint check, the re-established core, the §10A.15 exit rows, save-resume
  with a dug-in defender and a pinned formation, and the 1b-i set re-run.

*Ships:* "Upgrade the base, power it, heal your wounded at the front. Leave a garrison and the base stays as its
post."

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
- *With phase 1b-ii:* the Depot objective and salvage (net of guns in militia hands); the Power, Life support and
  Port payouts, including "Cut the town's power" through `cutFactor`; outposts at held objectives, on the ground
  the launch layout set aside; the defender's Rally; the occupation garrison post, with its turrets in suppression
  (secession-lane sign-off).

*Ships:* the third way back works. Conquer a seceded colony, hold it by governing it well under guard, and either
restore its charter or watch it throw the garrison out.

**Phase 3: Watch it: force landers and a visible battle.**
- *Prerequisites:* phase 1 (not phase 2).
- *Battle plumbing (shared with phase 4a, which takes it if phase 3 has not been built):* `CombatFrame`,
  `combat_fx_pool`, the `combat` SceneSync stage, FrameTiming parity in the flight view, the render shed ladder,
  PerfKnobs, prewarm, and the `_battleCamera` over any colony (§10.1).
- *Landers:* `ForceRunFactory`; real force and reinforcement landers on airless bodies to an LZ at least 400 m
  from closed pads' points, with honest losses and the landing target re-armed on load; `lander_watch.dart` as
  the first world read (§5.3). Landing stays abstract elsewhere. **The battle warp ceiling's lander level (1×)**
  through the single clamp before the tick loop and after a load (§5.3): above 4× a lander is on rails and its
  guidance does nothing. `SimHost`'s substeps stay deferred (it has no colonies).
- *Battle on screen:* blasts, burning sites, control; objective markers and front arrows in `CombatOverlayState`.
- *Orders:* operational orders from the drawer and the markers; reinforcement waves on extra landers.
- *With phase 1b:* the layout drawn (computed since 1b-ii) and the LZ picker as a draggable pin; module instant
  nodes, scaffolds and socket rings, with sockets that open the Base tab's module list; the core as the real lead
  lander; supply runs and hot-drops drawn as descents (never Vessels); the hot-drop power, abstract, with
  deployment fatigue; **fog of war** (§10A.13) with order validation against the saved Known set.
- *Tests:* spotting determinism (twin-run and save-resume give the same Known sets), the lander warp level (1,000×
  requested gives 1× while a lander descends; touchdown within 8 m on the Moon fixture), the landing-offset delay,
  a reinforcement lander crash, warp-to-apsis and load cases for the clamp, the §7.6 lander rows.
- *Gate:* `fvm flutter test test/combat` with the above, plus the AOT smoke.

*Ships:* troop landers come down on the Moon. The fight is visible from the battle camera, with explosions,
fires and moving front lines, and squads can be redirected between objectives. Still no individual soldiers.
With the base: the core lands and unfolds, modules rise on their sockets, supply drops touch down on the pad,
and the rebels' positions are hidden until scouted.

**Phase 3b: Orbital support (new).**
- *Prerequisites:* phase 1b-ii (the launch footprint set the strike rules need, and the core's crew and power),
  and either the parts lane's ordnance parts or the loadout fallback (Q23). Movable to straight after 1b-ii.
  Without phase 3 the strike shows as notices and after-action lines, with no streak, and recon has no fog to
  lift.
- *Adds:* the core's uplink mast; `AssignOrbitalSupport` (armed or recon-only) and `ArmVessel` (rounds at a real
  cost, in either route); the overhead predicate; the warp ceiling's 10× level through the single clamp (and the
  clamp itself if phase 3 has not shipped it); the strike-window predictor in the domain, "Time the launch" and
  the HUD countdown; `CommanderPower` orbital strike and passive recon, with `StrikeInFlight`, flight time and
  scatter, the formation-spread area rule, emplacement kills, pinning, danger close and the ROE rules;
  operation-owned, content-keyed, saved craters, with world brushes only off parcels and plat lots (moved up from
  phase 6); the streak and blast if the phase 3 plumbing exists.
- *Tests:* the orbital set in §12.

*Ships:* "Park an armed ship over the battle and call down a strike when it passes." Low orbits are rare and
precise, high orbits are slow and scattered, and any ship you assign to the battle reveals the rebels when it is
overhead. Under the default Restrained rules a strike can still take out a Gun Emplacement that stands clear of
homes; Standard opens the Port and the other town objectives.

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
- *Input:* the input action layer with its contexts and rebind table (§10.4), carrying the first battle keys.
- *With phase 1b:* sockets blocked in the first bake and module hulls as battle-owned additions (§8.2), with
  `pushOut` collision against them; plinths on raster datums; each turret as one live emplacement row whose hp is
  its crew × 100 (no seat primitive needed), and modules as `module` rows outside `liveCap`; the live rows owning
  module state while joined, with write-back at every 1 s boundary (§8.1); live charges and jump jets. *With phase 3b:* live strike
  blasts and analytic crater overlays on the raster.
- *Gate:* the frame-hold test on a joined operation (§12), join/leave conservation, the collision tests.

*Ships:* "Launch and join". Step out at the LZ (or down the ramp, if phase 3's landers exist), fight for the pads
against dug-in rebels, die and redeploy, or leave and let the fight auto-resolve.

**Phase 4b: Squads that move.**
- *Prerequisites:* phase 4a; Spike S item 2 passed.
- *Adds:* navigation grid, sector A\* and flow fields; line of sight; squad and side AI; first-person orders and
  the X call-in.
- *With the base:* the X key as the hot-drop power, to the LZ or a held objective, with deployment fatigue;
  squads formed by the barracks pod spawn live at its socket and march to the rally point; line of sight feeds
  spotting; the AI uses abilities and digs in live; the line-of-sight flush on module completion.
- *Gate:* headless scenario tests; the calibration harness **reported**, not gated.

*Ships:* fight beside a squad, give orders with the number keys, call in reinforcements.

**Phase 4c: Calibrated.**
- *Prerequisites:* phase 4b stable (no AI changes for one review cycle).
- *Adds:* tuning until live and abstract agree, including the base variants (Balanced and no base), counters,
  abilities and `structureShare`.
- *Gate:* `bin/combat_calibrate.dart --gate` at ±10% on the three reference scenarios and their base variants.

*Ships:* leaving a fight to auto-resolve no longer changes the expected outcome.

**Phase 5: Command view and possession.**
- *Prerequisites:* phase 4b (there must be live squads to select and possess) and the `_battleCamera`.
- *Command view:* the command camera and posture; select, marquee, right-click orders, waypoints, control groups,
  pause-and-order, the command card.
- *Supporting pieces:* the raster ground pick, the 2D minimap, and possession by controller swap.
- *Halo Wars verbs (§10.3):* Y and Y Y, U, R, F1–F3, L rally, F5–F8 powers, the base-selected build grid, the alert
  ring, command-context camera keys, and the command card's build, train, power and ability pages; live outposts.
- *Tests:* widget tests for button filtering, stack order and the existing orbit habits; the rebind table's
  no-duplicate-chord test across the new context.

*Ships:* Tab between first person and a top-down view. Box-select squads, right-click orders, and jump into any
friendly trooper. This is the Battlezone II loop, infantry only, with Halo Wars' select-all, cycle, ability,
jump-to-base, rally and power keys, and the base built from the command card.

**Phase G: Gamepad (new, optional).**
- *Prerequisites:* phase 4a's input action layer. Full value after phase 5. It blocks nothing and nothing waits
  for it.
- *G1:* Windows XInput through `ffi`, no new dependency, behind the pointer lock's guard (§10.4).
- *G2 (if wanted):* web through the W3C Gamepad API, and macOS and Linux through `gamepads`, after a build spike on
  framework commit `84af28a`.
- *Tests:* a stub source drives the action layer headlessly.

*Ships:* play the command view and the soldier with an Xbox-style pad on Windows, using Halo Wars' layout. Keyboard
and mouse stay primary.

**Phase 6: Driver, heavy weapons, destruction.**
- *Prerequisites:* phase 4b.
- *Vehicles:* the shared vehicle controller extracted; wheeled, tracked and hover locomotion; seats, boarding and
  eject; vehicle meshes and wrecks; armour formations.
- *Weapons:* rockets and cannon as projectiles.
- *Destruction:* destructive war damage and rubble; Heavy ROE; heavy-weapon craters under phase 3b's crater rules
  (quantised, keyed, saved, analytic on the raster), or the whole crater machinery here if 3b has not shipped;
  optionally a structure layer for bridges and tunnels (§8.2).
- *With the base:* the vehicle bay (Fortress tier) assembling armour from shipped kits; the AT turret
  specialisation; the ARM row and column of `CounterTuning`; Ram, Unload and Boost; modules destroyed by heavy
  weapons; wrecks as battle-owned additions.
- *Traffic:* adopt contracts C1–C3 and C6 if delivered.

*Ships:* drive a buggy or APC into the fight, gun from the second seat, and bail out when it burns. Buildings fall
and the ground scars, with a visible civilian cost under heavier rules.

**Phase 7: Pilot and strikes.**
- *Prerequisites:* phase 3 (landers) and phase 4a.
- *Flying:* `PilotInputCommand` per tick; fly the lander in yourself with auto-land assist; the lander as a
  respawn point.
- *Call-ins:* gunship passes from Airfields (their own objective, §6.2), and silo strikes, as commander powers
  (§10A.11). The orbital strike has moved to phase 3b.
- *With the base:* the airpad; the AA turret specialisation; the AIR row of `CounterTuning`; the gunship's
  strafing run; the rebel silo strike on the base, with AA interception (§4.2).
- *Prerequisite for Earth and Mars:* air-relative aero (cross-lane).

*Ships:* fly the dropship in, strafe defences, call a strike, then step out as a trooper. Earth and Mars battles
open once the aero fix lands.

**Phase 8: Uprisings, rivals, multiplayer groundwork.**
- *Prerequisites:* phase 2 (uprisings need garrisons); phase 4b for live rival raids.
- *Uprisings:* defensive battles in place of the flat revolt where a garrison exists. The garrison post is the
  player's base in that battle.
- *Rivals:* rival factions with an owner on CitySim, building bases under the same rules and doctrine.
- *Network:* faction authority in `Session`; regenerated wire bindings plus a combat table; the `_envelope` cases
  made real, including the base, power and ability families; server snapshots with own-unit prediction over a
  non-loopback transport.

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
- **The Halo Wars pieces move freely too** (Q35):
  - Phase 1b-i needs only phase 1, and 1b-ii only 1b-i. Either may follow phase 2 instead. Folding 1b into phase
    1 is possible but makes the first approval more than twice as large.
  - Phase 3b needs phase 1b-ii and a definition of "armed" (Q23). It may come straight after 1b-ii, before the
    visible battle.
  - Soldier first (4a straight after 1) still works: 1b and 3b do not depend on the live layer, and the socket
    layout already exists from 1b-ii. If 4a comes before phase 3, 4a also takes the module nodes, along with the
    battle plumbing.
  - If phase 3 comes well before 4a, the input action layer can move up to phase 3 with the first new keys.
  - Phase G can follow any phase from 4a on.

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

**Risks added by the Halo Wars layer:**
- **A city builder inside the battle.** The base, powers, counters, the selection grammar and the gamepad are each
  a slice. A base that grew gathering or its own tech tree would duplicate the city builder and contradict "the
  colony still builds the army". Mitigations: the base only spends shipped stock, home buildings stand in for
  tech, at most 7 + 4 sockets at the core, and the work is split into 1b, 3b and G.
- **A base that does not matter.** Against a starter town the fight is over in about 45 s, before any module is
  built, and the town fields militia only, so the counters do nothing either (§10A.6, §10A.9). Many early
  battles will therefore use little of the Halo Wars layer. Mitigations: the landing turret, 25% of pallets ready,
  up to 2 modules landed ready, the base becoming the garrison's post, and the light operation shown as a trade.
  The layer is honestly sized for large colonies.
- **Routing any base piece through CitySim** breaks several invariants at once (§10A.1). Mitigations: the
  combat-owned catalog, the catalog-isolation test, the hygiene bans, and the no-terrain-edit assertion.
- **Q6 leaks.** Any path that turns stock into people (reusing `kDeliveryPeople` or relief drops, or a "recruit"
  module) would quietly break "troopers are colonists". Mitigation: the personnel invariant every step.
- **Draining the source.** Shipping support staff as crew lowers the home site's `siteFactor` further (a barracks
  at about 0.17 in the worked example). Mitigation: the default ships only the crew the doctrine needs, and Q28
  asks whether troopers should crew instead.
- **The warp ceiling's feel.** While a real lander descends, warp is held at **1×**, because above 4× it would be
  on rails and could not land; every opening landing and reinforcement descent is watched in real time, and its
  length is unmeasured until phase 3. While orbital support is assigned, warp is held at 10×; the longest
  operation is about 2 real minutes at 10×. Warp is one global clock, so either level binds the whole game. If it
  feels bad, the fallbacks are abstract landings above 4× for reinforcements (the opening landing stays real), and
  launch-time coverage charges for support, which weakens the "really overhead" twist (Q22).
- **Strike availability may read as broken.** A low lunar orbit gives about 3 minutes above 30° every 2 hours, in
  bursts with gaps of about 13.7 Earth days (about 9,800 operation days), and there is no lunar-stationary orbit. The window predictor, the HUD
  countdown, Time the launch, and staggered vessels are required, not polish.
- **The overhead test is a float threshold** on vessel state. A coasting vessel is on rails at 1× and at 10×
  alike, but `_onRails` re-fits and propagates every tick, so 0.02 s and 0.2 s ticks round differently, and a
  burn switches it to physics; either, or another platform, can flip the test at a window edge. Mitigations: one
  evaluation per 1 s step on tick-end state, fixtures with windows at least 2 steps from a boundary, a burn case in
  the test, and §12's per-platform caveat.
- **Calibration churn.** Real counter values re-pin every row with emplacements, and base scenarios add rows. If
  the layers used different build timelines or tables, Total War's drift would return. Mitigations: one doctrine
  and one `CounterTuning`, read by both layers, and the M ≡ 1 identity test.
- **Cross-lane dependencies.** `PartCategory.ordnance` touches the craft lane's exhaustive switches, and
  `Vessel.releaseOrdnance` the vessel lane (the loadout fallback avoids both). Post turrets in suppression need
  the secession lane. The warp clamp sits in the shared `simulation_view` hub. `SimHost` must substep once a host
  with colonies exists.
- **Fortification signs.** One side-blind `F` made every base turret protect the rebels raiding it. The split into
  `F_def` and `F_att` is pinned by a "defender raid on a Fortress LZ" calibration row (§6.3); any new
  fortification term must say which side it protects.
- **Strikes, salvage and power cuts damage the prize**, raising Grievance, collateral and war weariness.
  Mitigations: the ROE rules, the Q17 exclusions and the term guard cover every new verb (§7.5), and every
  refusal says why.
- **The input action layer** is a refactor across 5 files (69 key-check lines in `simulation_view.dart` alone)
  that touches today's flight and walk bindings. Halo Wars took Ensemble 12 to 18 months of controls iteration,
  and every PC port was still criticised. Mitigations: battle contexts first, flight and walk migrated only
  opportunistically with their tests green, and a rebind table from the first key.
- **Gamepad build risk.** XInput sees XInput-class pads only; web needs the repo's first `js_interop`; the
  `gamepads` plugin would be the first native Windows plugin against a pinned master engine. Mitigation: it is an
  optional phase that nothing waits for.
- **Socket room.** Graded towns, elevated decks and the 400 m rule may leave few LZs with every socket free.
  Spike S item 6 measures it, and blocked sockets say why.
- **Single-source Halo Wars numbers** (the MAC Blast's cooldown, Blitz rates) are pacing references only, never
  precedent for a tuning value.

## 18. Ownership seams

| Area | Owner | How combat touches it |
|---|---|---|
| `lib/domain/combat/**`, `city_war.dart`, `city_occupation.dart`, `combat_frame.dart`, `lib/infrastructure/flutter_scene/combat/**`, `simulation_view_combat.dart` (a new `part` file, state in an Expando), `screens/combat/**`, `bin/combat_calibrate.dart`, `tool/aot_combat_smoke.dart` | **combat lane (new)** | owns them, including the Halo Wars layer: `combat/base/**` (`kBaseModules`, the doctrine), `combat/powers/**` (the overhead gate, `crater.dart`, `strike_window.dart`'s math, the loadout registry if chosen), `combat/landers/lander_watch.dart`, `combat/launch/**` (both snapshots, the launch footprint set, `base_layout.dart`), and in `screens/combat/**` the planner, `strike_window_view.dart`, `command_card.dart` (phase 5) and the operation HUD, drawer and Base tab, hosted from `simulation_view_combat.dart` in both modes, with the world-level `OperationNoticeQueue` (§14); and the garrison post and its daily footprint check in `city_war.dart` and `city_occupation.dart` |
| `lib/domain/parts/**`, `vessel.dart`, `craft_catalog_pane.dart`, `part_primitives_category.dart` | parts and craft lane | **request P1** (only if Q23 picks real parts): `PartCategory.ordnance`, the Ordnance Rack (built empty, filled by `ArmVessel`) and Kinetic Penetrator parts, and `Vessel.releaseOrdnance(partId)`; the exhaustive switches at `craft_catalog_pane.dart:56` and `:75`, and a silhouette entry in `part_primitives_category.dart`'s map (not a switch: it falls back to a cuboid, so only `part_bake_cache_test.dart:158-163` would catch a missing entry). The loadout fallback needs nothing from this lane |
| `lib/infrastructure/flutter/input/**` | shared hub (combat lane builds it) | the input action layer, contexts and rebind table (§10.4); flight and walk keys migrate only with their owners' tests green. Phase G's `pad_input_native.dart` (XInput over `ffi`) sits beside `pointer_lock_native.dart`; any `gamepads` dependency is a shared pubspec change |
| `lib/domain/colony/city/traffic/**` and the traffic renderer files | **Agent Traffic** | contract only, never edited (see below) |
| `site_access/**`, `RoadGraph`, `CityLayout.roadIndex`, `road_elevation.dart` | Road Placement | read-only: `entrancePt`, deck heights. **Request R1:** move the road and pavement lifts (`ribbonLiftM` 0.12, pavement 0.27) from `road_mesher.dart:195` and `road_overlay_state.dart:57` into the domain, with a pin test that the renderer reads the same values. Phase 4a needs it; until it lands, combat keeps a copy of the two numbers with a pin test against the renderer constants (the `hash32.dart` precedent) |
| `city_loyalty.dart`, `city_reclaim.dart`, `city_control.dart`, `city_reclaim_ui.dart` | secession lane | `releaseByForce` with its own notice; the garrison block; `occupy()` and an **occupied branch in `_stageStep`** (secession test replaced by expulsion, `selfGoverning` false); suppression of rebellion and misrule; `Grievance.warDead`; the Force row's `onTap`; `acceptPetition` / `acceptNegotiation` routed through commands; outbox posts on stage changes. **Design changes needing sign-off:** Restore charter as a player act instead of `colony-secession.md:269`'s automatic return; neglect left unsuppressed under occupation; no desperation bump on a retake; garrison-post turrets counted in `garrisonStrength` (§7.2); optional Hand over the post through `claimSite` after an operation (Q26, with the colony lane). **Also for sign-off:** the post's fields in the garrison block (module kinds by name, hp, body-fixed anchors, kept-turret ammo draw, the `setPost` choice); the colony-state notice kinds added to `LoyaltyNoticeKind` (`city_loyalty.dart:251-269`): `portRetaken`, `occupied`, `garrisonExpelled`, `troopersDeserted`, `postMoved`. Operation notices do not go into this enum; they use the combat lane's world queue (§14). Pinned tests updated deliberately |
| `city_sim.dart` | colony | **not a few hook lines**: `siteFactor` (deployed share × damage × power cut) in both aggregation loops (`:1376-1381`, `:1389-1407`, with the site id carried in `parcelActive`), scaling `powerOutput` explicitly as well as `uf` (`:1374`, `:1399`), the moved input draw for deployed troopers, the inbox drain and outbox posts, the `socialTick` suppression term, garrison upkeep, the wounded timers, save keys. Estimated at a few hundred lines in `city_war.dart` plus about 30 in `city_sim.dart`, with a bench row. The Halo Wars layer adds only inbox traffic (Materiel and kit debits, salvage requisitions, missile debits, a power-cut `siteFactor` entry) and the garrison post block; no hook in lot growth, because the post's footprint check runs in the garrison upkeep step |
| `advance_simulation_tick.dart` | shared | `_combatPhase` and its call site, constructor injection of the registry and `CommandInbox`, the inbox drain in `_cityPhase` |
| `sim_host.dart`, `flight_session.dart` | shared | pass the registry and `CommandInbox` into their `AdvanceSimulationTick`; `FlightSession` keeps the registry across `rebuildTick`. `SimHost` wires no CitySim colonies, so its substeps are deferred until a host with colonies exists (§5.3) |
| `flatbuffer_codec.dart`, `apply_commands.dart`, client and bridge switches | wire / multiplayer | the new command cases (`UnsupportedError` until phase 8), grouped into families so each switch changes once per family (§12) |
| `simulation_view*.dart` | shared hub | the part file plus hook lines: `tickAlpha`, `_simKeys` (plus Y, U, L, F1–F3, F5–F8), the Ctrl exception, outer-Listener fire, the battle and command cameras, the action router call in `_onKey`, and the battle warp clamp `_applyBattleWarpCeiling()`: one call every frame immediately before the tick loop (after warp-to-apsis's re-fit at `:1958-1969` and the atmosphere lock at `:1884-1889`) and one after a load, never a hook in `_stepWarp` alone, with an optional 25× rung in `_warpLevels` (Q22) |
| `screens/city_game_hud.dart`, `screens/city_control_ui.dart`, `screens/city_panels.dart` | city game UI (shared) | the occupied state and its notices (§14) only. `CityGameHud` shows only in city mode for one colony, so the operation chip, drawer, Base tab, powers, orbital chip and warp notice live in the combat lane's files instead |
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
  first pulls the battle plumbing into 4a; RTS first pulls the whole live layer into phase 5. The base adds
  phase 1b, which ships before any unit is drawn, and the orbital strike adds phase 3b (Q35).
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
  Linux and no live fighting on web or touch? A gamepad's right-stick look (Phase G2) would also give macOS and
  Linux live fighting without pointer lock (Q32).
- **Q13 Assets and engine gaps.** Add an audio dependency for gunfire and explosions, and in which phase? Are
  primitive rigid-part soldiers and box vehicles acceptable through phase 6? Should terrain edits be persisted in
  the codec generally (it would fix impact craters too) before phase 3b, where strike craters first appear?
- **Q14 Battle scale.** Are 24 live units per side, a 1.2 km battle square (800 m if Spike S says so, 600 m on web)
  and a 10-day ceasefire cap (about 7 fair fights at the recomputed calibration, §6.3) the right defaults? The base
  adds at most 7 module and 4 turret sockets at the core and 3 outposts of 2 + 1; Spike S item 6 checks they fit.
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
  proposed, since destroying them damages every colony's sky on that body? The same question now covers orbital
  strikes and AT turrets (Q24).
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

**The Halo Wars layer (2026-10-10).** Locked by the user: in-battle base building, commander powers including
orbital strikes from a real armed vessel overhead, a counter triangle, and Halo Wars selection on keyboard and
mouse. Still open:

- **Q22 Warp ceiling.** Two levels are proposed. While a real lander descends, warp is held at **1×**, because above
  4× every vessel is on rails and a lander cannot land; every opening landing and reinforcement descent is watched
  in real time. While only orbital support is assigned, warp is held at **10×**, the largest rung with ticks of
  0.5 s or less. Warp is global, so either binds the whole game. Is that acceptable? Should a **25× rung** be added,
  so the 10× level costs less? Should reinforcements land abstractly above 4× instead of holding 1× (the opening
  landing stays real)? Or should support use launch-time coverage charges instead, which weakens "really
  overhead"?
- **Q23 What "armed" means.** Real **Ordnance Rack and Kinetic Penetrator parts** (proposed: honest mass, built in
  the craft editor; needs the parts lane's `PartCategory.ordnance` and `Vessel.releaseOrdnance`), or a
  **combat-owned loadout** (no part change; massless in v1)? Either way rounds must cost real stock, because no
  part costs anything today: they are filled at a colony pad with `ArmVessel`. Proposed: **25 steel and 5
  electronics a round**, which an early colony can pay. Or 2 missiles a round, which gives missiles a use but
  needs an 800-colonist Missile Plant, putting the orbital strike late in progression?
- **Q24 Strike rules.** Under Restrained (the default), strikes only at a military site (a Gun Emplacement, Barracks
  or Military Base) with no civilian building within 3 crater diameters plus the scatter; military buildings get
  no buffer. Without that exemption every emplacement is a building, so Restrained could never hit one and the
  auto policy would never fire. Under Standard, also the Port, Power, Airfield and Depot; under Heavy, also the
  Seat; never life support or terraforming towers; refused while rejoining terms ban demolition. Craters that
  touch a parcel or plat lot leave no lasting terrain edit. Is that right? Should the auto
  policy fire strikes only when "Orbital weapons free" is ticked (proposed), and should friendly fire inside the
  blast be real, with a danger-close prompt (proposed)?
- **Q25 Strike range and pace.** A 2,500 km slant cap (Earth GEO and Mars areostationary give recon only), flight
  10 s + slant ÷ 3 km/s, scatter 5 m + 5e-5 × slant: low orbits rare but surgical, high orbits slow and scattered.
  Acceptable, or should strikes be faster and longer-ranged, like Halo Wars? And are strikes on Earth and Mars,
  which are abstract and unaffected by aero, allowed before the aero fix?
- **Q26 The base after a win.** Keep it as the garrison's post (proposed: kept turrets raise suppression, a kept pad
  shortens garrison runs, a kept hospital heals on site), or always strike it for 50% of its Materiel? Should
  **Hand over the post** be offered on Restore charter or rejoining, turning modules into real colony buildings
  through `claimSite` once the operation is over (needs the secession and colony lanes)?
- **Q27 Prefab scale.** Modules are 12 to 24 m deployables carried in landers, an explicit exception to the
  catalog's build-at-real-scale doctrine. OK?
- **Q28 Who crews the base.** Support staff, the half of each building's deployable people that stays home today
  (proposed; it lowers the home site's output further), or troopers taken out of squads (a harsher Halo Wars
  population trade)? Support staff become troopers only by the player's `formSquad`, within the source's trooper
  cap, so the base cannot double a barracks's fighters. Is that the right limit?
- **Q29 Fog of war.** Enemy formations only; the map and town stay visible; the player can target only Known
  formations, while the resolver, the AIs and the doctrine ignore fog (proposed, keeping 4c's calibration valid).
  Or presenter-only intel that never refuses an order? Should real gameplay fog (the AI limited by what it sees,
  ambush bonuses) come after phase 4c?
- **Q30 Defender building.** Dig in only (+0.1 F per 30 s, up to +0.3), as proposed, or barricades and improvised
  emplacements during a fight?
- **Q31 Salvage and power cuts.** May the attacker requisition from rebel depots (it costs the town mood) and cut
  the town's power under Standard ROE (it costs services, never life support)? Both hurt the colony being won back.
- **Q32 Gamepad.** Build it at all? If so, Windows XInput over the existing `ffi` first (proposed, no new
  dependency), then the web Gamepad API, and the `gamepads` plugin for macOS and Linux only after a build spike on
  framework commit `84af28a`? Or drop it until after phase 5?
- **Q33 Default keys.** Y and Y Y (all on screen, the whole force), U (cycle kind), R (ability), F1, F2, F3 (bases,
  squads, last alert), L (rally), F5–F8 (powers), and a Q W E / A S D / Z X C build grid only while the base is
  selected. All rebindable; any preferences before they are pinned?
- **Q34 The resource model.** Materiel as ore only, one number (proposed: it is already the city's build currency,
  and it travels colony stock, deliveries and vessel cargo like several other goods), with kit, fuel, medicine, steel and electronics as stock lines in the drawer? Or a
  mixed build bundle, more "military" but blocked by its scarcest input? And is 25% of pallets ready on landing
  right?
- **Q35 Where base building lands.** Phases 1b-i and 1b-ii straight after phase 1 (proposed), or after phase 2?
  Folding them into phase 1 would more than double the first approval. Should the orbital strike come as phase 3b
  right after 1b-ii, or after the visible battle (phase 3)? Should the light operation be the default for small
  targets, or shown beside the base as a trade (proposed)?
- **Q36 Rebel powers.** Should a rebel colony that kept a staffed Missile Silo and missiles strike the player's base
  (proposed for phase 7, countered by AA turrets), or should the rebels have no powers?
