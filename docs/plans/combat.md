# Combat: taking colonies back by force

Status: draft, condensed 2026-10-10 from the full plan, now `docs/plans/combat-reference.md` (ref). Baseline `dev`
at `085c72a`. Planning only: nothing is built. This file wins where the two differ; "ref §n" points into the ref.

## 1. Intent

The user, 2026-10-10, on reclaiming a seceded colony by force:

> "would basically turn this into an RTS then, no?" … "RTS or even allowing the player to engage in the battle
> themselves as a soldier or pilot or something" … "Just plan it for now"

The precedent is *Battlezone* (1998): an RTS played from inside a hover tank on the Moon, Mars and Venus, where the
pilot can eject and fight on foot. Then, on the RTS side:

> "I imagine the RTS side would be like Halo Wars, does that fit the plan?" … "Yeah, that would be freaking
> awesome. Battles should include base building."

`colony-secession.md` §6.3 left **Force** as the last way back. This plan replaces that plan's phase 4 and grows it
into a pillar the size of the city builder.

## 2. The model in one page

**The Operations Ledger.** One battle state per operation; everything else is a way of looking at it.
- An `Operation` is a set of **formations** (squads kept as counts: kind, count, wounded, quality, morale, kit,
  where it is) fighting over **objectives** that already exist as colony state: Port, Seat, Life support, Power,
  Depot, Airfield, and the attacker's LZ. At most 8 nodes, each joined to its 2 nearest.
- **Auto-resolve is the truth.** A resolver steps the pools in fixed 1 s steps of one operation clock: width-capped
  strength, pairwise loss sharing, morale breaks and surrender, a control value per objective. Every battle gets a
  result whether or not anyone watches.
- **Live layers zoom in.** Joining takes one objective live as a "bubble" (24 a side, the rest arrive as reserve
  waves); it writes back into the same pools at every 1 s boundary and folds back on leave. One model, so a fought
  and an auto-resolved battle cannot drift apart (Total War's chronic failure).
- Lifecycle: planned → mustering (0.25 day) → transit (0.5 day same body, 1.5 other) → landing → engaged → won |
  lost | withdrawn | ceasefire (10 days) | rejoined | overtaken → aftermath. An operation day is 120 s.
- The planner previews 32 seeded runs of the same resolver: outcome bands and casualty ranges, never exact numbers.
  The real run has a fixed seed, so reloading cannot reroll a launch.
- Seats added later on the same state: soldier (walker, EVA pack), driver (rover), pilot (landers), commander
  (number keys in first person, then a top-down command view). Possession is a controller swap.

**The Halo Wars layer, "Beachhead".** More state on the same `Operation`, stepped in the same 1 s steps.
- **Forward base at the LZ.** The lead lander deploys into a base core (Battlezone's recycler) with a landing
  turret and an uplink mast. Fixed sockets: Firebase 3 module + 2 turret, Station 5 + 4, Fortress 7 + 4; up to 3
  outposts (2 + 1) at held objectives. Modules: supply pad, turret, barracks pod, Stores, field hospital,
  generator, munitions workshop; later vehicle bay and airpad. A module is a row on the `Operation` that changes
  resolver terms, never a CitySim building. A light operation ships no base.
- **One Materiel economy.** Materiel is ore shipped from your colonies as pallets (25% ready on landing, the rest
  unpacked by the core and pads), plus Power (a kW cap), Personnel (the people you shipped are the cap) and kit.
  The base spends or converts shipped stock; it never creates goods or people. Supply runs are abstract arrivals.
- **A build doctrine** (Balanced, Hold, Push, Manual) builds the base deterministically when nobody watches, so an
  unwatched operation builds the same base a watched one does. Player orders go first.
- **Commander powers from real assets:** supply drop, Medevac, hot-drop, and an **orbital strike from a real armed
  vessel of yours overhead** (≥ 30° up, ≤ 2,500 km slant; flight time and scatter grow with range, so the orbit is
  a trade). Later silo strikes and gunship passes. No asset, no power, and the UI says why.
- **Counters:** a const table M[dealer][target] applied to loss sharing only (INF, EMP-HMG/AT/AA, ARM, AIR,
  structures); Halo's ARM > INF > AIR > ARM. Inert at militia scale; M ≡ 1 in phase 1.
- **Abilities**, one per kind: charge assault, jump jets, dig in, rally, ram/unload/boost, strafing run; the
  player's avatar is the hero (morale aura, respawn).
- **Fog of war** for enemy formations only: map and town stay visible; orders may target only Known formations;
  the resolver, AIs and doctrine ignore fog.
- **Halo Wars selection on keyboard and mouse first:** Y all on screen, Y Y whole force, U cycle kind, R ability,
  F1–F3 base/squads/alert, L rally, F5–F8 powers, a Q W E / A S D / Z X C build grid, a command card, no radials.
  Gamepad optional (Phase G).

## 3. Rules

1. **Pools are truth.** Auto-resolve, the base and every live layer read and write the same pools and base rows.
2. **Every input is a `SimCommand`** applied at the tick, from phase 1, single-player included. The UI enqueues and
   never mutates sim state. Frame time changes only what is drawn.
3. **Deterministic.** One owner and one clock (`_combatPhase`, integer µs); stateless seeded rolls only; sorted
   iteration; counted budgets. Colonies are read once at launch, then only through events they post.
4. **Troopers are colonists**, and so are base crews. The dead are people charged home. Force wins no loyalty.
   Everything is moved, not added.
5. **Every phase ships on its own** and could be the last. Phase 1 has no units on screen. Battles stay small and
   capped (24 live per side).
6. **Spike S gates the live layer.** Measurements pass before phase 4a (and item 6 before 1b-ii's layout). A miss
   stops the phase for a decision; it never quietly lowers the bar.

## 4. Decisions so far

**Made by the user (2026-10-10):**
- Plan force as an RTS *and* as fighting in the battle yourself, as a soldier or pilot. Plan only for now.
- The RTS side is like Halo Wars. Battles include base building.
- Locked with the Halo Wars layer: in-battle base building; commander powers including orbital strikes from a real
  armed vessel overhead; a counter triangle; Halo Wars selection on keyboard and mouse.
- After the size pushback: a short core plan, a detailed spec for the next phase only, the rest re-specified just
  before each phase is built (this file plus the ref).
- Q20: force is a flight-world feature first; the city builder host gains a multi-colony world later ("both need to
  happen eventually").

**Proposed defaults** (the plan is written on them; each is open in §8):
- Design: Operations Ledger (22.5 against 21.2, 20.8, 19.9; ref §3), Beachhead for the Halo Wars layer (16.2
  against 14.1, 14.0; ref §3.1).
- Troopers are colonists (Q6). Single-player first, deterministic, server snapshots later, no lockstep (Q3).
- Restrained tone: Restrained ROE by default, surrender the usual end (Q5); civilians never targetable (Q2).
- Force allowed on a still-colonial standoff colony: no loyalty gain, loyalty −0.05, no desperation bump; a win
  reopens the port and the exodus with it (Q7).
- Resolve r replaces `colony-secession.md` §6.3's `pop × (1 − happiness)`.
- Order: soldier (4a–4c) before the command view (5) (Q1); base 1b-i/1b-ii right after phase 1, orbital strike
  as 3b after 1b-ii, light operation shown as a trade, not the default (Q35).
- Base: Materiel = ore, one number, 25% ready (Q34); support staff crew (Q28); 12–24 m prefab modules (Q27); the
  base becomes the garrison's post (Q26); the defender only digs in (Q30); fog on enemy formations only (Q29).
- Orbital: two-level warp ceiling, 1× while a lander descends, 10× while support is assigned (Q22); real ordnance
  parts with a loadout fallback, 25 steel + 5 electronics a round (Q23); strike ROE (Q24); range and pace (Q25).
- Seat = largest civic building near the centre (Q8); real landers on airless bodies only (Q9); leave a live fight
  before saving (Q10); respawn costs a colonist (Q11); Windows-only mouse capture for live fighting (Q12).
- 24 live per side, 1.2 km square, 10-day ceasefire (Q14); Restore charter as a player act (Q15); local gates, no
  CI (Q21); gamepad optional, XInput first (Q32); default keys (Q33); rebel silo strikes in phase 7 (Q36).

## 5. Traps found in the code

- Re-seizure: a released port is seized again next step while standoff desperation > 0.4 (`city_loyalty.dart:621-629`, `:93`).
- Retaking a standoff port restarts the exodus (`city_loyalty.dart:433-434`; `city_sim.dart:1928-1935`).
- Desperation keeps rising in standoff unless attended (`city_loyalty.dart:537-550`); a win's bump could secede it (`:401-402`, `:562-565`).
- Setting `occupied` alone re-secedes: `_stageStep` short-circuits only for independent (`city_loyalty.dart:558`); revolts kept (`:562-565`).
- Occupation erodes in ~850 s through stale-`attendedAtS` neglect (`city_loyalty.dart:195-196`), not 240 s misrule (`city_sim.dart:2237-2238`).
- `colony-secession.md` §6.3's garrison formula is mis-scaled (safety counts people served: a barracks beats every town).
- CitySim draws unseeded `math.Random()` on disaster paths (`city_sim.dart:2636`, `:2654`, `:3078`, `:2804`); fixtures use hostility 0.
- Colony clock ≠ world clock: `eventSimWarp` 0.4–2.2 (`city_sim.dart:1352`, `:2805-2807`); frame hold lags ≤ 15 colony s (`traffic_tuning.dart:316`).
- No per-building staff: one colony-wide ratio (`city_sim.dart:1412-1473`); `parcelActive` has no site id (`:1389-1407`).
- Power output is never scaled by `uf` (`city_sim.dart:1374`, `:1399`): a site factor must scale `powerOutput` explicitly.
- Guns, ammo and rations are not deliverable (`city_sim.dart:6187-6198`): sources need their own chain; garrisons need runs.
- Stock cap 200 without a warehouse, clamped every tick (`city_sim.dart:367`, `:1273-1285`): a source ships ≤ 100 ore.
- Real transfer time cannot set battle timing (colony time is capped per frame): transit is fixed operation days.
- Earth and Mars landings are likely broken by inertial-frame aero (read, not run): real landers on airless bodies first.
- Building the base through CitySim gives it to the rebels (`placeOnParcel` `city_sim.dart:5004-5010`; six routes, ref §10A.1).
- `_specByLabel` drops unknown labels (`city_sim.dart:4992-5002`); the generator stakes every `kUtilCatalog` spec (`city_generator.dart:2166-2181`).
- `PlaceBuildingCommand` is cell-grid, colony-targeted and a no-op on every apply path (`apply_commands.dart:61-63`).
- Above 4× every non-landed vessel is on rails, guidance ignored (`simulation_clock.dart:42-43`; `advance_simulation_tick.dart:305-307`).
- Above 25× orbits outrun battle time; 10× is the largest rung with tick ≤ 0.5 s (`simulation_view.dart:1473`).
- Seven sites write warp; warp-to-apsis re-fits every frame (`simulation_view.dart:1958-1969`); a load restores warp (`game_state_codec.dart:249`).
- A strike round flown as a Vessel: warp-dependent impact, destruction cheats default on (`flight_session.dart:44-46`), unsaved crater.
- `landingPads()` includes the Airfield (`city_sim.dart:5505-5509`): the Port objective filters by type.
- Anything landed within 60 m of a closed pad is impounded (`shuttle_cargo.dart:60-62`, `:126`): LZ ≥ 400 m from pad points.
- `_shuttleSeq` is not saved and resets on a cheat toggle (`advance_simulation_tick.dart:668`): ids come from saved counters.
- `FlightSession.rebuildTick` builds a new tick on every cheat toggle (`flight_session.dart:141-161`): state lives in the registry.
- Direct `CitySim.advance` callers step no operation (`main_city_game_dev.dart:447-461`; `advance_simulation_tick.dart:500-504`).
- `SimHost` steps 1.0 s (`sim_host.dart:109`) but wires no colonies (`:77-113`): no operation runs there; substeps deferred.
- `FlatBufferCodec._envelope` is exhaustive with no default (`flatbuffer_codec.dart:394`): every new command needs a case.
- The live game calls `AdvanceSimulationTick` directly, bypassing the authoritative path: a local `CommandInbox` is needed.
- `acceptPetition` / `acceptNegotiation` are widget calls (`city_reclaim_ui.dart:157`, `:161`): commands from phase 2.
- `CityGameHud` shows only in city mode for one colony (`simulation_view.dart:3460-3464`): operation UI needs its own home.
- The codec saves no terrain edits; in-session brushes survive a load (`game_state_codec.dart:279-284`): craters keyed by content.
- RelayNetwork's ground station is fixed in the inertial frame (`relay_network.dart:31`): never `hasCommLink` for "overhead".
- No weapon part category (`part_def.dart:16-31`); `part_primitives_category.dart` silently falls back to a cuboid (`:132-136`).
- Events are String-typed, 64 a frame (`simulation_view.dart:1785`); the `runtimeType` fallback minifies on web (`world_snapshot.dart:2265`).
- `ImpactFxNodes` allocates per event, merges same-tick hits (`impact_fx_nodes.dart:121`), plain sprites not depth-safe (`:254-260`).
- `RoadOverlayState` is wiped on every road-tool change (`road_overlay_state.dart:104`): combat gets its own overlay.
- Ground-sample cost is unsettled: 8–16 ms (`colony_ground.dart:11-12`) against 0.69 ms (7d325cf); the bake goes off-thread.
- Freecam orbit moves the walking avatar ~7 m (`simulation_view.dart:2415-2424`); walking from a body lock can start at the pole.
- The walker has no lateral collision (`first_person_walker.dart:96-126`); its landing speed is thrown away (`:122-124`).
- The captured-cursor `MouseRegion` swallows clicks (`simulation_view.dart:3477-3480`); keys missing from `_simKeys` (`:1217`) beep on macOS.
- Raw key checks in 5 files, no Shortcuts or Actions; the pinned framework has no gamepad API.
- One side-blind fortification value lets base turrets protect the rebels raiding them: split into `F_def` / `F_att`.
- Preview at 5 s steps is wrong: width cap, whole-member removal and morale thresholds depend on step size.
- Shedding `liveCap` on frame time would change the fight by frame rate: it is set once per join.
- The pinned AOT miscompiles a nullable promoted through a bool local (native only): AOT smoke, not JIT tests alone.
- The flight view's frame baseline is unmeasured; the city studio's figures do not transfer. No test CI exists.
- Deployed troopers keep commuting in Agent Traffic's table (no "away" concept): accepted oddity, request C6.

## 6. Phases

Each phase is approved separately and is useful if it is the last. Sizes are guesses relative to phase 1 (ref §16).
**Everything after phase 1 is provisional — specified before it is built.**

- **Spike S** (alongside phases 1–2, no gameplay). Six measured items with pass lines: ground-sample cost and the
  1.2 km bake within 90 s, navigation stuck rate, drawn-vs-simulated error, render increment, flight-view baseline,
  socket room and LZ/goal fit. Gates 4a (items 1, 3, 4, 5), 4b (item 2) and 1b-ii's layout (item 6).
- **Phase 1: Retake the port** (size 1). Auto-resolve with no units on screen; §7.
- **Phase 1b-i: The base core** (~0.6; provisional). The core and landing turret, Firebase sockets as indices,
  supply pad, HMG turret, barracks pod, Materiel and pallets, crews and the LZ reserve, abstract supply runs,
  `F_att`, structure soaking, overrun, Balanced, the light operation. Ships: "Your operation lands a base."
- **Phase 1b-ii: The full base and the post** (~0.9; provisional). Station and Fortress, four more modules, power,
  the other doctrines, real INF/EMP/STR counters, abstract abilities and Dig in, supply drop and Medevac, the
  launch footprint set and `base_layout.dart`, the spare core, the garrison post. Needs Spike S item 6.
- **Phase 2: Force and occupation** (~1; provisional). The Reclaim Force row goes live on independent colonies;
  `occupy()` and an occupied branch in `_stageStep`; Seat, Life support, Power, Depot; resolve, regulars,
  emplacements, waves; surrender and petitions through commands; Restrained and Standard ROE; salvage, outposts,
  power cuts. Needs secession-lane sign-off.
- **Phase 3: Watch it** (~1.2; provisional). Real force landers on airless bodies with honest losses, the 1× warp
  level through one clamp, `CombatFrame`, effects, the `_battleCamera`, operational orders, module nodes, drawn
  supply drops, hot-drop, fog of war. Still no individual soldiers.
- **Phase 3b: Orbital support** (~0.7; provisional). The uplink, `AssignOrbitalSupport`, `ArmVessel`, the overhead
  gate, the 10× level, the window predictor and "Time the launch", strikes, recon, keyed craters. Needs 1b-ii and
  Q23. "Park an armed ship over the battle and call down a strike when it passes."
- **Phase 4a: The soldier** (~2; provisional). Worker-pool raster bake, unit table, walker and EVA pack in the
  domain with collision, hitscan against static defenders, the bubble, REDEPLOY, unit renderer, battle HUD, the
  input action layer. "Launch and join."
- **Phase 4b: Squads that move** (~1.5; provisional). Navigation, line of sight, squad and side AI, number-key
  orders, the X hot-drop live; calibration reported, not gated.
- **Phase 4c: Calibrated** (~0.5; provisional). Tune until live and abstract agree within ±10%, base variants
  included; `bin/combat_calibrate.dart --gate`.
- **Phase 5: Command view and possession** (~1; provisional). Command camera and posture, select, marquee, orders,
  control groups, the command card, the Halo Wars verbs, possession by controller swap.
- **Phase G: Gamepad** (~0.3 for G1; optional, provisional). XInput over the existing `ffi` on Windows; G2 (web,
  macOS, Linux via `gamepads`) only after a build spike. Nothing waits for it.
- **Phase 6: Driver, heavy weapons, destruction** (~1.5+; provisional). Shared vehicle controller, buggy, APC,
  hover tank, seats and eject, rockets and cannon, destructive damage and Heavy ROE, vehicle bay, AT turrets.
- **Phase 7: Pilot and strikes** (~1.5+; provisional). Fly the lander in, gunship passes, silo strikes, airpad, AA
  turrets, the rebel silo strike; Earth and Mars after the aero fix.
- **Phase 8: Uprisings, rivals, multiplayer groundwork** (~1.5+; provisional). Defend-the-colony battles, rival
  factions under the same base rules, faction authority, the wire cases made real.
- **Reordering (Q1, Q35):** 4a can follow phase 1 directly (it then builds the battle plumbing); 4 and 5 can swap
  (the whole live layer moves into 5); 1b may follow phase 2; 3b may come before phase 3; G follows any phase
  from 4a.

## 7. Phase 1 spec: Retake the port

**Ships:** a colony whose rebels seized its spaceport can be retaken with troopers from another colony's barracks.
The outcome is previewed and seeded, with real deaths, spent supplies, a loyalty cost, and a garrison that stops
the rebels taking it straight back. The planner says plainly that the standoff continues and that settlers who
cannot be fed will leave. It saves and loads mid-operation. No units on screen.

### 7.1 Scope
- **Target:** a still-colonial colony in standoff with `portSeized`. **Sources:** any colonial or occupied colony
  with a ready military building, on the same body or another. **Goal:** the Port. Landing is abstract and always
  succeeds. No base (a light operation in later terms), no live layer, no orders but withdraw.
- **Halo Wars plumbing, invisible:** the resolver is pairwise from the start with `counterClass` on every
  formation and `CounterTuning` M ≡ 1; the field is `kitDays`; the LZ objective carries an empty module list, so
  1b adds rows with no save migration. `FactionId` (`player`, `colony:<cityId>`, reserved `rival:<id>`) on every
  side and formation, with a helper reconciling `Vessel.ownerId`'s `'player'` / `'player-1'`.

### 7.2 Where the code lives
- `lib/domain/combat/` (combat lane, new): `combat_rng.dart` (a copy of traffic's xoshiro128\*\* and FNV-1a,
  pinned bit-equal, the `hash32.dart:6-18` precedent), the operation clock, `Operation`, `OperationRegistry`,
  `Formation`, `ObjectiveGraph`, `resolver/**`, the preview, the abstract AI, the port lifecycle rules;
  `launch/**` builds the `LaunchSnapshot` and `SourceSnapshot`. No `CitySim` import under `resolver/**`.
- `city_war.dart` (a CitySim extension in its own file): readiness, `siteFactor`, port-holder sizing,
  non-destructive port damage (`warDamageSite` severity < 1), `recordWarDead`, the inbox drain and outbox posts.
- Secession lane (sign-off needed): `CityLoyalty.releaseByForce()`, the port garrison guard, `forceUsed`, the
  `portRetaken` notice kind, no desperation bump on a retake.
- `advance_simulation_tick.dart`: `_combatPhase`, constructor injection; `FlightSession` (keeps them across
  `rebuildTick`) and `SimHost` pass the registry and inbox. UI: `simulation_view_combat.dart` (a `part` file,
  Expando state), `screens/combat/**`. Tests: `test/combat/**`, `tool/aot_combat_smoke.dart`. PolyForm headers.

### 7.3 Data
- **`Formation`:** `id` (saved `nextFormationId`), `side`, `faction`, `kind` (`infantry`, `regular`, `militia`,
  `emplacement`; append-only, saved by name), `count`, `wounded`, `quality` (1.0 / 0.5 / 0.3), `morale` (trooper
  0.8, port holders 0.4), `kitDays`, `at` (objective id, `transit`, `lz`, `reserve`), `homeColonyId`,
  `homeSiteId`, `counterClass`.
- **`ObjectiveGraph`:** Port (`landingPads()` minus airfields) and LZ. Each has `value`, `F_def` and `F_att` in
  [1, 2.2] (`F_att` = 1 in phase 1), width `W = min(24, 6 + 4·sqrt(m²/10,000))` (every real Port caps at 24),
  control `c ∈ [−1, 1]`. March times from straight-line distance and `speedOnTerrain` (`ground_vehicle.dart:47`).
- **`LaunchSnapshot`** (target, taken when `LaunchOperation` applies): population, mood, hunger, severity (live
  loyalty state for a standoff colony), wish (0 in standoff), spaceport jobs, staffed military sites, stocks with
  the gun stock as a pool. **`SourceSnapshot`** (each source): per building, ready troopers; ore, rations, ammo,
  guns, stock cap. Nothing else is read after launch except outbox events.
- **Attacker:** troopers per source building ≤ `floor(jobs × restThrottle × 0.5)` (barracks 15, Military Base
  40), only while *ready* (inputs in stock, `city_sim.dart:1528-1535`); squads of ≤ 8. Kit per trooper-day =
  the building's inputs × `daySec` / jobs (barracks: 2 rations, 0.2 guns, 1.2 ammo); 1 gun each plus 3 days by
  default; moved, not added (the home building's draw falls by the deployed share).
- **Defender:** resolve `r = clamp(0.2 + 0.5·severity + 0.3·mood − 0.6·wish − 0.3·hunger, 0.05, 0.95)`. Port
  holders `ceil(spaceportJobs × 0.5 + population × 0.03 × r)` at quality 0.5; sympathisers join in waves up to
  militia `floor(population × (0.04 + 0.20·r))`, armed `min(militia, guns + floor(0.3 × militia))` from the pool.
- **`siteFactor(siteId)`** = `(1 − deployedShare) × damageFactor × cutFactor`, three terms saved separately. It
  multiplies `uf` in the cell loop (`city_sim.dart:1376-1381`) and the parcel loop (`:1389-1407`, which must carry
  the site id), multiplies `powerOutput` explicitly (`:1374`, `:1399`) and the production run (`:1520-1540`).
  Deployed troopers leave `workforce` (`:1412`).
- World level: `OperationRegistry`, `CommandInbox`, `WarLedger` (player dead by operation day for 10 days; each
  source's mood debt). Per colony: `ColonyCombatInbox`, `ColonyCombatOutbox`.

### 7.4 The clock and the tick seam
- `_combatPhase` runs after the vessel loop, beside `handOutReputation` (`advance_simulation_tick.dart:389`),
  before the city loop (`:390-395`). In order: (1) drain the `CommandInbox`, validating with reasons; (2) drain
  each colony's outbox; (3) step every operation; (4) war weariness; (5) post into each colony's inbox.
- Inboxes drain at the start of `_cityPhase` (`:511-525`), before `city.advance`, so E8 sees deaths before agents
  do. A frame-held colony drains when its held tick replays; the documented lag is ≤ `maxHeldCityS`.
- **Operation clock:** `opDt = min(tickDt, 0.5)` in integer µs, `tickDt` being what the city loop gets, without
  `eventSimWarp`. Fixed 1 s steps from an accumulator, so any partition of dt runs the same steps.
- **Outbox events:** stage or allegiance changes, a depended-on site removed, upkeep unpaid, a garrison run
  shipped. Confirmations never set a time: arrival = post µs + fixed transit (≥ 60 s), asserted in tests.

### 7.5 The resolver, AI and endings
```
per 1 s step, per objective with both sides, in id order:
  S_f = count × P × quality × (0.25 + 0.75·morale) × Sup        P = 1, emplacement 3; Sup 1 with ammo, 0.35 without
  E_A = min(ΣS_att, W);  E_D = min(ΣS_def, W);  e_i = S_i·E_A/ΣS_A;  e_j = S_j·E_D/ΣS_D
  fuzz = 1 + 0.15·u,  u = combat_rng(seed, o, floor(t / 30 s)) ∈ [−1, 1]
  loss_j = α·fuzz/F_def·dt·Σ_i e_i·(S_j/ΣS_D)·M[c_i][c_j];  loss_k = α·(2−fuzz)/F_att·dt·Σ_j e_j·(S_k/ΣS_A)·M[c_j][c_k]
  α = 1/185 per s; unit is MEMBERS removed, half wounded, half dead; fractions carried
  morale −= 1.5 × removed / members at engagement; pinned < 0.35, broken < 0.2, rallies at 0.45
  dc/dt = κ·(a − d)/max(a, d, ε),  a = E_A/F_def,  d = E_D/F_att,  κ = 1/120 per s
morale +0.002/s out of contact, +0.0005/s holding, −0.0005/s without rations; defender side < 0.15 surrenders
```
- **Calibration pin:** two 16-trooper formations at a Port (W 24, fuzz 1) each break at the 7th member removed,
  at **174 s**. A unit test checks the pairwise sums against the closed form to 1e-12 on random pools.
- Seed `fnv1a32(targetColonyId, opId)`; never `math.Random`, `damageBuildings`, `flattenOne` or fire spread.
  **Defender AI:** every 30 s allocate by `value × threat` (attacker strength one hop away), keep one in reserve,
  counterattack when `E_D/F_att > 1.5·E_A/F_def`, feed waves from the launch pool. **Attackers** advance to the
  goal and hold when `E_A/F_def < 0.8·E_D/F_att`. All constants in a const `ResolverTuning`.
- **Ends:** won (Port at c ≥ 0.9 for 60 s, or surrender); lost (every attacker broken or dead, or kit at 0 for 2
  days); withdrawn (survivors home, 10% lost if engaged); ceasefire (10 days); overtaken (§7.6 below). Bands:
  Decisive / Close / Pyrrhic victory (losses ≥ 50%), Valiant / Close / Decisive defeat.
- **Preview:** 32 seeds at the real 1 s step, counted, ≤ 2 ms a frame, done in about a second (~120 ms, ~3 µs a
  step; phase 1 measures it). Shows bands, duration, p10–p90 casualties; never touches sim state.

### 7.6 Outcomes and lifecycle
- **Win:** `releaseByForce()` clears `portSeized` and `impoundPending` with its own notice, `portRetaken`: "Your
  troopers have retaken the spaceport." (never `portReleased`'s text). Loyalty −0.05, no attention stamp, no
  desperation bump; `forceUsed` recorded for any later Grievance. Pinned: a win at the worst allowed desperation
  does not secede the colony on the next step.
- **Port garrison:** default `max(2, 1% of population)` troopers. While it holds, the seizure rule
  (`city_loyalty.dart:621-629`) is blocked. Upkeep is its home-building input share, paid in the target's tick
  from a carried garrison stock, refilled by a garrison supply run every 3 days (debit posted to a source's inbox,
  amount confirmed via its outbox, landing at the fixed arrival). Unpaid: 10% a day go home alive.
- **Loss:** port stays seized; loyalty −0.1; desperation +0.05. **Casualties:** `recordWarDead(n)` writes as
  `city_sim.dart:1804-1810` does (E8 or scalar); wounded cannot redeploy for 2 colony days; a dead trooper's gun
  is lost.
- **War weariness:** every colonial colony −0.01 loyalty per 10 player dead in the last 10 days; each source −0.02
  mood per 10% of its deployed troopers killed, decaying over 5 days.
- **Lifecycle rows (ref §7.6):** standoff ends by recovery → Overtaken, all home, garrison's job done; target
  secedes → Overtaken (independence), all home alive, kit lost, garrison expelled; source secedes → its troopers
  desert; source enters standoff → no new musters from it; home site removed → `homeSiteId` cleared, they return
  as residents; port site removed by disaster → the node stays, loses its building fortification.

### 7.7 Commands
- `LaunchOperation` (target, goal, sources and counts, days of kit, garrison size), `OperationOrder(withdraw)`,
  `WithdrawGarrison`. Validated in `_combatPhase`; a refusal has a reason and changes nothing. Launch never stamps
  attention. Cases added to `ApplyCommands`, `ClientSimulation._applyLocally`, `MultiplayerScreen._cmdName`,
  and in `FlatBufferCodec._envelope` and `SimulationView._applyBridgeCommands` as `UnsupportedError`, tested.

### 7.8 Saves
- Codec v3 (v2 today, `game_state_codec.dart:41`): an `operations` block, additive and omitted at defaults, holding
  sides, sources, goal, ROE, seed, phase, clock, graph, formations, ledgers, `LaunchSnapshot`, garrisons and
  counters (`nextOperationId`, `nextFormationId`). World: `WarLedger`, garrison runs in flight, pending commands
  with their target tick. CitySim: `siteFactor` terms, the garrison and its stock, `forceUsed`, wounded timers.
- `flushHeld` before encoding (`simulation_view.dart:2699-2701`), then assert every inbox and outbox is empty
  (else encode a `pending` list). No RNG state. A `%` fingerprint digest only while operations exist (the
  atmosphere precedent, `world_snapshot.dart:3350-3357`).

### 7.9 UI entry
- A "Retake the port by force" row on the spaceport site sheet via `CitySiteHooks.extra`
  (`city_site_actions.dart:54`), also offered from the seized-port notice and loyalty explainer.
- Planner (`screens/combat/operation_planner_sheet.dart`): sources with ready troopers and why others are not
  ("No Arms Factory: guns and ammo cannot be shipped in"), trooper sliders, days of kit, garrison size, the
  histogram and casualty ranges, and the costs ("Troopers are your colonists", "Force wins no loyalty",
  "Retaking the port reopens it: settlers who cannot be fed will leave. Only governing the colony ends the
  standoff."). Then **Launch**.
- HUD chip "Retaking the spaceport · day 1.4 · ▰▰▰▱▱" opening a drawer (objective control bars, formations with
  morale and kit, Withdraw), in `simulation_view_combat.dart`, both modes. Operation notices in a world-level
  `OperationNoticeQueue`; an after-action report. Dev hook `ext.acro.combat` with `?fixture=` and `?step=`.

### 7.10 Tests and gate
- Fixture `portSeizedPair()`: a ~400 source with Arms Factory, Rations Plant, ready Barracks, Warehouse,
  Hospital, Spaceport and stock; a standoff target with `portSeized`; same body; built by state assembly with
  `hostility = 0` and no disaster.
- Twin-run; save-resume mid-operation (incl. the tick a source write is queued); warp equivalence (25 × 0.02 s
  against 1 × 0.5 s); frame-hold equivalence (held against inline); the calibration table (first row 174 s); the
  re-seizure guard; the no-secede-on-win pin; the `portRetaken` text; the port lifecycle rows; `siteFactor = 1`
  leaves every aggregate bit-identical (plus a bench row); the hygiene scan (no `Random`, `hashCode`, `DateTime`,
  `Stopwatch`, map/set iteration, `traffic/` imports); the gate sweep for the new row; a headless reachability
  script (a starter colony to 300 with Arms Factory, Rations Plant and a ready Barracks).
- **Gate:** `fvm flutter test test/combat` plus `tool/aot_combat_smoke.dart`.

**Out of scope:** the base, independent targets and occupation, Standard/Heavy ROE and civilian deaths, other
objectives, landers and the warp ceiling, units and the live and input layers, combat on the wire, `SimHost`
substeps, and anything on `CityGameHud` beyond the colony notice.

**Built** 4b07554 → 9071eb3 (2026-10-10/11), verified live on the Moon.

## 7A. Phase 2 spec: Take the colony, hold it

Specified 2026-10-11, the night the user said "run through phase 2 and phase 3 and we'll review tomorrow": every
choice below marked *(default)* was taken on the proposed default without asking, for review.

**Ships:** an independent colony can be taken by force. The Force row on its panel opens the same planner; a win
occupies it, a garrison holds it, and the player either governs it back to a restored charter or watches it throw
the garrison out.

**Objectives** (from the target's buildings at launch, `buildingParcels()` centroids, at most 5):
- **Seat** — the goal. The biggest civic building by jobs (police, emergency, hospital, school, clinic), nearest
  the colony centre on a tie; else the biggest non-home building; else the Port *(default, Q8: no Council Hall)*.
- **Port** (a spaceport, airfields excluded), **Life support** (the biggest `isLifeSupport` site), **Power** (the
  biggest plant by output), each only when it is a different site from those before it; the **LZ** 450 m out from
  the Port (else from the Seat), away from the colony centre.
- Links: each node to its two nearest; march = distance / 1.4 m/s, at least 60 s.
- Holding Life support or Power changes nothing in the colony yet (payouts are 1b-ii's).

**Defenders** (resolve `r` as in phase 1, with the grievance and the colony's wish to rejoin):
- the Port's holders, as in phase 1, at the Port;
- **regulars** from its own barracks and bases (half their staff, at its throttle; quality 0.8, morale 0.5 + 0.3r)
  at the Seat;
- **emplacements**: each Gun Emplacement is 4 crew of strength 3 (quality 0.8, morale 0.6) at its nearest
  objective, and never moves;
- militia waves, as in phase 1, sent to whichever objective is threatened.
- A defeat raises the target's resolve by 0.2 for 10 days.

**AI.** The attacker takes the objectives on the shortest path from the LZ to the Seat in order, advancing from the
objectives it holds with the phase 1 strength test. The defender sends waves and rallied squads to the most
valuable threatened objective. On the phase 1 graph (LZ and Port) both reduce exactly to phase 1's rules, so its
pins hold unchanged.

**ROE** *(default Q5: Restrained)*. Restrained is phase 1's baseline, so its pins hold: small arms, no civilian
harm. Standard: attacker fire ×1.2, and a quarter of the defender dead again as civilians, less the share
sheltered (Fallout Shelters and Bunkers), charged to the target with corpses and into its grievance. Heavy is
phase 6.

**Built:** the battle core at 7bc293c. Found while building it: the advance test compared width-capped strengths
and never went in behind fortification (now whole strengths); an assault needs 20 days before a ceasefire and
about 6 days of kit (two fights, where a port retake is one).

**Occupation** (`city_occupation.dart`, the reference's §7.2 nearly as written):
- `occupy()`: allegiance occupied, loyalty 0.2 (Defiant), revolts, independence, council log, petition and terms
  cleared; the grievance kept, plus its war dead; `attend()`; notice "Your troopers hold the colony. It takes your
  orders under guard."
- An occupied branch in `_stageStep`: no standoff and no secession while the garrison holds; the stage follows
  the loyalty bands; never self-governing. Level ≤ 0 or three revolts **expels** the garrison (home alive) and the
  colony takes the plain colonial rules from the next tick.
- Suppression `s = min(0.8, troopers / (0.05·population))` scales rebellion growth and misrule by (1 − s) and costs
  mood 0.1·s. Neglect is not suppressed: occupation is ruling, not a timer.
- Upkeep from the garrison's stock, then requisitioned from the colony's own (mood −0.05 while it is); unpaid, a
  tenth a day goes home. Supply runs as for a port garrison.
- **Restore charter** *(default Q15: a player act)*: offered once loyalty has stayed ≥ 0.6 for 10 days; the colony
  becomes colonial and the garrison comes home. **Withdraw** early: loyalty −0.2, then the plain colonial rules.
- The HUD reads "Occupied"; the control gate already allows orders; reputation already excludes occupied colonies.

**Commands:** `LaunchOperationCommand` gains the ROE; `RestoreCharterCommand`; `WithdrawGarrisonCommand` also ends
an occupation. Petition answers stay widget calls for now (trap list) *(deferred)*.

**Out of scope:** salvage, outposts, power cuts and the base (1b), landers and the battle on screen (phase 3).

**Tests:** the multi-objective AI on hand-built graphs; the phase 1 pins unchanged; `planColonyAssault` from a
fixture; `occupy()` on a colony that left by three revolts stays occupied after a step and reads "Occupied";
suppression; expulsion; Restore charter; early withdrawal; the Force row live (the pin updated deliberately); a
launch-to-occupation world run; save/resume with an occupation garrison.

## 7B. Phase 3 spec: Watch it

Specified 2026-10-11, same night as §7A, on the same footing: *(default)* marks a choice taken without asking.

**Ships:** troop landers come down on the Moon as real vessels; the fight is drawn over the colony — objectives
coloured by who holds them, squads moving between them, blasts and smoke where they meet — and the player can
redirect the force or send more. Still no individual soldiers.

**On the operation** (saved): each objective's colony-local position, the LZ's included; each march's origin and
start step (for drawing a squad between two objectives); the standing order; the landers.

**Orders** (`OrderOperationCommand`): *auto* (the phase 2 plan), *attack* an objective now whatever the odds (back
to auto once held), *hold*, *fall back* to the LZ (then hold). **Reinforcements** (`ReinforceOperationCommand`):
fresh squads from the same planner rules, landing at the LZ a mustering and a crossing after the order.

**Landers** (`ForceLanders`, the tick's first world read for combat):
- Only where the target's body has no atmosphere *(default Q9)*; elsewhere landing stays abstract.
- One lander per 16 troopers, flown by the shuttles' `LandingGuidance` from 16 km up onto a ring of points 40 m
  round the LZ (450 m from any pad, so nothing is impounded). The transit ends when every lander is down; a squad
  lands with its lander; a lander lost before touchdown loses everyone aboard, dead and charged home. With craft
  destruction off (the default cheat) nothing is lost, as for any craft.
- Lander records live on the operation (saved) and re-arm their guidance every tick, so a load resumes a descent.
- **Warp ceiling:** while a lander descends, warp is held at 1× — above 4× a craft is on rails and its guidance
  does nothing. One clamp in the tick (every host) and one in the view (its ladder and a notice).
- Landed, they wait at the LZ; when the operation ends they lift off and are recovered past 4 km.

**On screen** (the in-world view):
- `CombatFrame`, a pure read of an operation: objectives with control, squads with interpolated positions, and the
  contact intensity at each objective.
- A projected 2D overlay (`_camera.projectPx`): objective rings coloured by control, front arrows for marches,
  squad pips sized by count, flashes where they fight. Not depth-tested: it is a command overlay.
- Smoke and muzzle flashes in 3D: a `combat` SceneSync stage with two persistent particle systems per battle,
  driven by `CombatOverlayState` (its own state; the road overlay's is wiped by every tool change).
- **Watch** in the drawer frames the camera on the battle; the drawer gives the orders and Reinforce.

**Out of scope:** fog of war, module nodes and drawn supply drops (need the base, 1b), hot-drop, the orbital layer
(3b), and soldiers (4a).

**Tests:** orders and reinforcements on hand-built operations; positions saved; the frame's interpolation; landers
through the real tick on the Moon fixture — touchdown, transit gated on them, a lost lander's dead, the warp clamp
(1,000× asked, 1× while descending), save and resume mid-descent.

**Built** 2026-10-11: a6fe58d (positions, orders, reinforcements), 6ab6b47 (landers, each down within 30 m of its
point), c89415e (frame, overlay, drawer orders, Watch), 7030dfc (smoke and flashes). Verified live on the Moon: two
landers down, warp held at 1×, the march and the fight drawn, a decisive victory, the landers recovered. Not built:
petition answers as commands (still widget calls), and a depth-tested 3D marker layer (the overlay is 2D).

## 7C. Phase 1b-i spec: The base core

Specified 2026-10-11 after "All of them need to get done, keep going until I return": built after phases 2 and 3,
so it rides on their objectives, landers and overlay. *(default)* as before.

**Ships:** an operation can land a forward base at its LZ. Its core deploys, a landing turret comes online, and
the base builds a supply pad, a barracks pod and a second turret from shipped Materiel — by itself (the Balanced
doctrine) or by the player's orders from the drawer. It changes the fight with no units on screen, and an
unwatched operation builds the same base.

**State** (`lib/domain/combat/base/`, on the `Operation`, saved with it; never a CitySim building):
- `kBaseModules`: the **supply pad** (30 Materiel, 25 s, 1 crew, 2 kW, unpacks +1/s, runs come 1.5× as often,
  needs a source Spaceport), **turret** (60, 30 s, 2 crew, 6 kW, an attacker emplacement formation of its crew at
  strength 3, +0.25 `F_att` at the LZ, 0.5 ammo/s engaged, needs a source Arms Factory) and **barracks pod** (50,
  40 s, 2 crew, 6 kW, broken squads at the LZ rally twice as fast, lets support staff be formed into a squad,
  needs a source Barracks). Catalog-isolated: never in `kUtilCatalog`.
- The **core**: 20 kW, one build line, unpacks 0.5 Materiel/s, +0.3 `F_att` at the LZ, and the landing turret
  (online at deploy, crew 2). Firebase tier: 3 module and 2 turret sockets, indices only *(positions are 1b-ii's)*.
- **Materiel** is ore, mustered from the lead source (default 300); 25% lands unpacked, the rest as pallets.
  **Support staff** (default 10) are colonists of the lead source, away like troopers, crewing modules; the
  unassigned are the LZ reserve. Kit for them is shipped as for troopers. Stocks in centi-units.
- Builds pay up front from unpacked Materiel; cancelling refunds half, demolishing half. Timers in whole steps.

**Deploy:** 30 s after the transit ends (abstract), or after the first lander touches down (it carries the core).
Lost with that lander, the operation fights base-less.

**The step** (every operation step once deployed): unpack; power balance (modules run at
min(1, supply ÷ demand)); build lines; turret ammo; resupply — formations at the LZ or one link from it refill kit
toward 3 days at a day per 30 s from the base's stock; supply runs every 3 days ÷ (1 + 0.5 × pads), each a debit
posted to the lead source and landing half a day after it ships what it had *(the preview assumes full runs)*.

**Fire:** the base raises the LZ's `F_att`; turrets fight as emplacements; a base makes the LZ worth raiding — the
defender sends waves there when nothing else is threatened *(the defender's LZ counterattack, omitted until now,
arrives with the base and only with it, so the phase 1–3 pins hold)*. **Overrun:** the defender holding the LZ at
control ≤ −0.9 for 60 s loses every module; crews and reserve take half dead, half wounded; half the stock is
captured by the target, half lost.

**Doctrine** (Balanced, 1b-i's only one): supply pad, barracks pod, turret, a second pad — each when its home gate,
a socket, crew and power allow; waiting for Materiel. Player orders go first. **Light operation**: no base.

**End:** on a win, withdrawal or ceasefire the base is struck and what is left goes home to the lead source; on a
loss it is abandoned (half to the target, half lost). Support staff go home like troopers.

**Commands:** the launch's base manifest; `BaseOrderCommand` (build, cancel, demolish, formSquad).

**UI:** the planner's Forward base section (on/off, Materiel, support staff); the drawer's Base section (stocks,
power, personnel, sockets with build buttons, the line, Form squad); the overlay draws the modules round the LZ.

**Out of scope (1b-ii):** Station and Fortress, Stores, hospital, generator, workshop, the other doctrines, layout
positions and the LZ picker, the spare core, outposts, counters, abilities, powers, the garrison post.

**Built** ba83db0, 564eb1b; verified live on the Moon (core, pad, pod, pad; runs landed; struck and home).

## 7D. Phase 1b-ii spec: The full base and the post

Specified the same day as §7C, on the same footing.

**Stocks** gain fuel, medicine, steel and electronics, shipped from the lead source and by runs; every stock and the
unpacked Materiel are capped at 400 + 300 per Stores (pallets past the cap wait).

**Tiers** (an upgrade takes a line): Station — 5 module and 4 turret sockets, 2 lines, 100 Materiel, 50 s;
Fortress — 7 and 4, 3 lines, 160 Materiel + 20 steel, 60 s, +0.3 at the LZ, needs a source Military Base.

**Modules:** Stores (20, 20 s, no crew or power; +300 caps); field hospital (40, 40 s, 2 crew, 4 kW, medicine 0.2 a
patient-day, needs a source Hospital: every half day the wounded recover into the LZ reserve instead of going home);
generator (40, 30 s, 1 crew, +30 kW, fuel 0.1/s); munitions workshop (60 + 10 steel, 50 s, 3 crew, 12 kW, needs an
Arms Factory: 15 steel and 3 electronics a day into 30 ammo and 9 guns). The barracks pod forms recovered wounded
into squads (4 or more waiting, every 30 s).

**Doctrines:** Balanced (pad, pod, Station, Stores, hospital, turret, workshop, outpost, Fortress, then turrets),
Hold (turret, turret, hospital, Station, turret, Stores, pad), Push (pad, pod, Station, a second pod, Stores,
hospital, outpost), Manual (nothing). A generator jumps the list when power would run short.

**Outposts:** at an objective the attacker has held at ≥ 0.9 for 60 s: 120 Materiel, 40 s, 2 module and 1 turret
sockets, its own line; +0.3 and +0.25 a turret to that objective's `F_att`; offline while its control ≤ 0; razed at
≤ −0.9 for 60 s. **Spare core:** shipped for 100 Materiel; after the core is lost or overrun, deployed in 60 s at a
held objective as an outpost-sized base.

**Layout:** sockets get positions — modules on a 45 m ring, turrets on a 75 m ring facing the enemy — and a socket on
a building is blocked *(Spike S item 6, how many are free on real ground, is measured, not gated: the LZ is 450 m
out from the town)*. The LZ picker tries eight bearings 450 m from the anchor and takes the one with the most free
sockets, at least 400 m from every pad.

**Counters** (`kCounters`): HMG emplacements ×1.25 against infantry, infantry ×0.8 against emplacements; the rest 1.
**Abilities:** charge (an order: squads at an objective fight ×1.5 for 30 s, then lose 0.1 morale), jump jets
(regulars march 40% faster on airless bodies), dig in (defenders unthreatened for 120 s at an objective fight from
+0.3 there until it is taken). **Powers** (`CommanderPowerCommand`): emergency supply drop (a run landing in half a
day, every 2 days), Medevac (the wounded at one objective to the hospital now, every day; needs one).

**The post:** a won operation with a standing base leaves the base's kit to the garrison, which holds longer; a won
assault's crewed turrets stay with their crews (who join the garrison) and each counts two troopers more toward
suppression while two of the garrison can crew it *(default)*.

**Out of scope:** the vehicle bay and airpad (phases 6–7), AT/AA turrets, orbital and silo powers (3b, 7), fog (with
the battle view), the depth-tested 3D base (4a's renderer).

**Built** ae4f96e, 9fafb97, 748853c, 67304d2, ad4ed50; verified live on the Moon (Station, Stores, charge, supply
drop, the post kept one turret and its crew). Found live: lot-sized obstacles blocked every socket (now building
footprints), and a spaceport's apron reaches past 450 m (the LZ now tries 600, 800 and 1,000 m too).

## 7E. Phase 3b spec: Orbital support

Specified 2026-10-11, on the ref's §10A.12 with these defaults *(default)* for review.

**Ships:** park an armed ship of yours over the battle, assign it, and call down a strike when it passes.

**Arming (Q23, the loadout route):** a world-level `VesselLoadout` (vessel id → rounds, saved with the operations).
`ArmVesselCommand(vessel, colony, rounds)` applies while the vessel is landed within 60 m of a pad of a colonial or
occupied colony; it posts a debit of 25 steel + 5 electronics a round, and what the colony could pay arrives aboard
60 s later. Rounds are massless. No parts lane.

**Assigning:** `AssignOrbitalSupportCommand(op, vessel, on)`: a player vessel, not landed, in the target body's SOI,
not a troop lander. Lost (gone, landed, out of the SOI) → unassigned with a notice. While any is assigned and the
operation runs, warp is held at 10× (1× still wins while landers descend).

**Overhead** (`powers/overhead.dart`): at each tick end, per assigned vessel, `d = v − p` from the objective's
inertial point; strike if `dot(d, p̂) ≥ 0.5|d|` and `|d| ≤ 2,500 km`; recon at 10°. The booleans and slant are saved.

**The uplink** rides in the core: online while the base stands with 8 kW to spare and 2 support staff in reserve.
No base, no strikes.

**Firing:** `CommanderPowerCommand(op, orbitalStrike, target)` queues one strike; it fires at the first step with an
assigned vessel overhead (strike), a round aboard, its 60 s cooldown done and the uplink online, lowest vessel id
first. Flight `10 s + slant / 3 km/s`, CEP `5 m + 5e-5·slant`, D from `craterForImpact` (250 kg at 3 km/s).
**Impact** per §10A.12: the emplacement there by priority (else the largest formation) destroyed with
`p = 0.8·min(1, (D/CEP)²)`; area casualties `min(0.4n, (πD²/50)·cover)·min(1, (r_f/CEP)²)`, half dead; morale −0.15
and defender fire ×0.5 for 20 s there; attackers present take half the area rule. **ROE:** Restrained strikes only
where an emplacement stands; Standard also the Port, Power and Depot; never the Seat or Life support.

**Craters:** at most 16 per operation, keyed (op, seq, aim, D), saved; a world brush only where the scattered impact
is clear of every building footprint and the body has terrain; re-brushed once per session from the saved records.

**UI:** the drawer's Orbital support section (assignable vessels, assign/unassign, rounds, overhead now, next pass
from `powers/strike_window.dart`, Strike buttons per objective, Arm at a pad); the overlay draws the streak, the
blast and the scorch.

**Cut *(default)*:** Time the launch, the auto policy and "Orbital weapons free", recon's fog reveal (no fog yet),
the danger-close prompt (the drawer says it instead), real ordnance parts. Overhead is judged at the battle's centre,
not per objective (under 1 km apart, against 100 km and more of slant).

**Built** d5b0bc2; verified live on the Moon: a 100 km orbit assigned at launch rose overhead by contact (124 km
slant), the strike fired at once, flew 50 s, spent its round, rested 60 s and cratered the power plant (Standard ROE;
no defenders there).

## 8. Open questions

Numbers match the ref (§19), where each has its full wording and proposed answer.

**Needed before phase 1:**
- Q3 Single-player first, deterministic and command-driven, no lockstep?
- Q5 Tone: restrained by default (routs and surrender, low collateral), ROE as the lever?
- Q6 Are troopers your colonists, or an abstract force bought with ore?
- Q7 Force on a still-colonial standoff colony, and does a win only reopen the port, or also stop the exodus?
- Q21 Keep local gates, or add a test CI workflow pinned to `.fvmrc`?

**Before phases 1b–3:**
- Q1 Soldier before command view? Soldier straight after phase 1?
- Q2 Who fights for the colony, and can civilians be harmed?
- Q8 Add a Council Hall as the Seat, or use the largest civic building?
- Q9 Real landers on airless bodies only until the aero fix?
- Q15 Occupation: recovery pace, Restore charter as a player act, restricted orders?
- Q17 May strikes hit populated objectives; are terraforming towers off-limits?
- Q22 Warp ceiling at 1× / 10×; add a 25× rung; abstract reinforcements; launch-time charges?
- Q23 What "armed" means: real ordnance parts or a loadout; 25 steel + 5 electronics or 2 missiles a round?
- Q24 Strike ROE, "Orbital weapons free" for the auto policy, real friendly fire with a danger-close prompt?
- Q25 Strike range and pace; strikes on Earth and Mars before the aero fix?
- Q26 Keep the base as the garrison post, or always strike it; offer Hand over the post?
- Q27 12–24 m prefab modules as an exception to real scale?
- Q28 Support staff or troopers crew the base; is the `formSquad` cap the right limit?
- Q29 Fog on enemy formations with order validation, or presenter-only intel; gameplay fog after 4c?
- Q30 Defender digs in only, or builds barricades and improvised emplacements?
- Q31 Salvage from rebel depots and power cuts under Standard ROE?
- Q34 Materiel as ore only, or a mixed bundle; is 25% ready on landing right?
- Q35 1b straight after phase 1 or after phase 2; 3b before or after phase 3; light operation as default?

**Later:**
- Q4 Rebels only, or rival factions; real rival AI, scripted strikes, or neither?
- Q10 Leave a live fight to save, or save live state?
- Q11 Respawn as the next trooper, or permadeath?
- Q12 Windows-only mouse capture for live fighting; none on web and touch in v1?
- Q13 Audio, primitive art through phase 6, general terrain-edit persistence (before 3b)?
- Q14 24 live per side, 1.2 km square, 10-day ceasefire?
- Q16 A defend-the-colony battle in place of the flat −30% revolt?
- Q18 Will Agent Traffic take C1–C6, and C1 before phase 6?
- Q19 Will Road Placement take R1; bridges and tunnels as blocked ground until phase 6?
- Q32 Gamepad at all; XInput first, then web, then `gamepads`?
- Q33 Default command-view keys before they are pinned?
- Q36 Rebel silo strikes on the player's base, or no rebel powers?

## 9. Reference

`docs/plans/combat-reference.md` holds the full plan this was condensed from: the code inventory (§2), design
scoring (§3, §15), every rule and number behind §2 here (§4–§10A), rendering budgets (§11), determinism and tests
(§12), persistence (§13), UI wording (§14), Spike S and per-phase scope (§16), risks (§17), ownership seams and
cross-lane requests P1, R1, C1–C6 (§18), and the full questions (§19). Its detail for phases after 1 is
provisional and is re-checked against the code and re-specified here before each phase is built.
