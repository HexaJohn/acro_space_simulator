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
