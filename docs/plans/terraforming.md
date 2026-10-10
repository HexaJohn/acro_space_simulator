# Terraforming: a planet's real atmosphere

Status: approved for phase 1, 2026-10-10 (decisions in §7); phase 1 built (§8), phase 2 built (§9), phase 3 built (§10). Baseline `dev` at `1246d8f`. Paths are relative to the repo root.

## 1. Intent

The user, 2026-10-10: terraforming towers should **directly change the atmosphere's composition**, not
move a "terraforming %" slider.

So a body's air becomes mutable **world state**: an inventory of each gas. Towers and industry add and
remove gases. Pressure, temperature, breathability and density then **follow from that inventory** through
the same physics the flight sim already uses. Everything that reads the air sees the change: colonies,
drag and reentry, the sky shader.

## 2. What exists today

| Piece | Where | State |
|---|---|---|
| `CitySim.terraform` 0..1 | `city_sim.dart:491`; `+0.05 × towers` per s (`:2672`) | a per-colony slider. At 1.0 on a barren/desert/volcanic biome it flips the biome to grassland and resets to 0 |
| What the slider moves | `SurfaceConditions.of(terraform:)` (`surface_conditions.dart:103-147`) | fakes pressure, temperature, humidity, O2 and toxicity toward Earth's. **Only** the colony's `surface` getter sees it |
| What ignores it | `CitySim.breathable` / `o2Fraction` / `co2Fraction` / `windFactor` / `hasWeatherAir` (`city_sim.dart:597-624, 2093-2114`) | read the raw body. So life support (`o2Managed`), sealed tubes and disasters never see terraforming |
| Tower spec | `terraformer` (`city_building_spec.dart:478`): 30 jobs, 60 power, `oxygen: 0.5` into the colony's **stock**, `pollution: -2` | changes no gas on the planet |
| **Per-body gas ledger** | `AtmospherePollution` + its service (`domain/planetary/atmosphere_pollution.dart`) | built and tested: CO2/O2 moles against the body's total moles, `applyTo(base)`, aerosols that settle out. **Dead:** `AtmosphereRepository` is only ever the Null implementation (`world_repositories.dart:47`); `sim_host.dart:82` and `flight_session.dart:135` never pass one. Fractions only: the total is fixed, so pressure cannot change |
| Body reference data | `CelestialBody.atmosphere` (`AtmosphereModel`, const) + `.composition` (`AtmosphericComposition`) | immutable; built by `RealSolarSystem`. Swapping a body is possible (`StaticUniverseRepository.replaceBody`, `CelestialBody.copyWith`), and debug terraform/nuke already do that (`simulation_view.dart:2642-2675`) |
| Stale body references | `CitySim.body` is captured at founding (`city_sim.dart:394`) | nothing re-points it after `replaceBody`, so colonies would miss any change |
| Persistence | `GameStateCodec` saves no body or atmosphere state (`game_state_codec.dart:26-33`) | the universe is rebuilt from definitions on load |
| Atmosphere consumers | flight tick `sampleAt` → drag/lift (`aero_force.dart`), engine pressure, jets, reentry heating (`thermal_model.dart` + `reentryHeatingFactor`), the science situation, the warp limiter, ascent screen, top-down presenter, the render descriptor → atmosphere shader (sticky, ~1 Hz), the wire codec | all read the body's `atmosphere` / `composition`, so they follow automatically **if the body they are handed is the current one** |

## 3. The model

### 3.1 State: `PlanetAtmosphere` (per body, mutable, saved)

```
bodyId
moles[gas]          // inventory per AtmosphereGas: N2, O2, CO2, CH4, H2O, Ar, H2, ...
greenhouse          // super-greenhouse agent inventory (PFCs / SF6), as forcing, kept apart from the 8-gas enum
reservoirs          // volatiles the planet holds back: CO2 in polar caps / regolith, H2O ice (body-specific)
aerosol             // existing: settles out
```

- It is seeded from the body's reference data at world creation:
  `moles = composition × totalMoles(seaLevelPressure, g, R)`.
- It **generalises `AtmospherePollution`**: the fixed `totalMoles` becomes the sum of an inventory per gas. The
  existing exponential aerosol relaxation and the "work in moles, then renormalise" rule carry over.

### 3.2 Derived air (recomputed when the inventory moves)

The planet's air follows from mass, gravity and temperature. These are the identities the existing
`AtmosphereModel` is already built around:

```
mass         = Σ moles_i × M_i
P_surface    = mass × g / (4πR²)
x_i          = moles_i / Σ moles                       // composition
μ            = Σ x_i M_i                               // mean molar mass (meanMolecularWeight exists)
T_surface    = T_eq(solarFlux, albedo) + greenhouse(pCO2, pCH4, pH2O, forcing) − aerosol cooling
ρ_surface    = P μ / (R T)
H            = R T / (μ g)                             // AtmosphereModel.withMeanMolarMass already rescales these
```

The result is an `AtmosphereModel` plus `AtmosphericComposition` for the body.

### 3.3 Feedbacks (what makes it a planet, not a slider)

- **Volatile release:** above a body's release temperature, its `reservoirs` outgas. The Martian polar caps
  and regolith hold CO2, so warming Mars releases CO2, which warms it further: the runaway that real Mars
  proposals rely on. Ice melts to H2O vapour, which is itself a greenhouse gas.
- **Escape:** a small, warm body **loses** gas, at a rate set by escape velocity vs thermal velocity (a
  Jeans-type rate per gas, light gases first). The Moon cannot hold an atmosphere. Towers there are fighting
  a leak, so lunar colonies stay domed unless the player keeps pumping. Mars leaks slowly. Earth and Venus
  effectively not at all.
- **Chemistry, kept simple:** CO2 → O2 conversion is what oxygenators do (§4). Combustion and industry do the
  reverse (the existing pollution coupling). Methane decays slowly to CO2 + H2O.

### 3.4 Breathability: one definition

`SurfaceConditions` already has the right test: o2 ≥ 0.15, p ≥ 0.5 atm, toxicity < 0.2. It goes on being the
single source of truth, but fed by the **derived** air. Every `CitySim` getter that reads the raw body today
reads it instead:
- `breathable` and `o2Fraction`, which drive life support (`o2Managed`), sealed tubes, agents and disasters;
- `co2Fraction`, `windFactor` and `hasWeatherAir`.

Partial cover for life support and for independence (`colony-secession.md` §3.4): the sky supplies the share
of a person's oxygen its partial pressure provides, when the total pressure is above the Armstrong limit
(about 0.06 atm) and the air is not toxic:

```
airO2 = clamp(pO2 / 0.16 atm, 0, 1)   if P ≥ 0.063 atm and toxicity < 0.2,   else 0
```

The colony's O2 need is then `population × (1 − airO2) × rate`, and that same `airO2` is the local O2 cover in
the self-sufficiency measure.

## 4. Towers and industry change gases, not a meter

The single `terraformer` becomes a family. Each has a gas flow in moles/s, scaled by its throttle (staffing,
power, compute; the life-support priority does not apply):

| Building | Does | Notes |
|---|---|---|
| Greenhouse Factory | emits super-greenhouse agent (PFCs) | warms the planet → triggers volatile release; the cheap start on Mars |
| Regolith Baker | releases CO2 (and N2 where the body has it) from `reservoirs` | thickens the air; limited by the reservoir |
| Oxygenator | CO2 → O2 (photolytic / algae) | the existing tower's role. Keeps the spec id `terraformer` for save compatibility |
| Carbon Sequestrator | removes CO2 into rock | Venus; also any world a colony has over-warmed |
| Atmospheric Harvester | (exists) takes O2 out of the air into the colony stock | now **removes** what it takes from the inventory |
| Industry (existing pollution) | emits CO2 + aerosol | the dead `_polluteAtmosphere` hook, wired for real |

Later, not in v1: **imports from space**, such as comet or ammonia redirection for nitrogen. That would come
through the space logistics this sim already has, which makes it a natural late-game route.

**Rates and time (Q1):** real terraforming takes centuries. Earth's atmosphere is about 1.8e20 mol and Mars's
about 5.7e17. Towers get honest *per-unit* physics, a gas flow on the real inventory, but sized by one documented
`terraformRateScale`. That way a serious tower programme does Mars in a number of colony-years the player can
reach under warp. Proposed target: about 50 towers and about 30 Mars years to breathable, which is about 24 h of
play at 1×, but hours under warp. Earth stays effectively immovable at the same scale, because its inventory is
300× larger. That is the honest result, and it means one Earth colony cannot wreck Earth's climate.

## 5. Wiring

1. `PlanetAtmosphere` + repository: a real in-memory store. `FlightSession` and `SimHost` pass it to
   `AdvanceSimulationTick`, replacing the Null default.
2. A **planetary atmosphere phase** in the tick, after the city phase:
   - collect every colony's gas flows on each body (colonies on one body **share** its air);
   - integrate the inventory, feedbacks and escape (exponential/implicit forms, so warp steps stay stable,
     as the aerosol code already does);
   - when the derived air has moved past a small tolerance, publish
     `body.copyWith(atmosphere:, composition:)` via `replaceBody`.
3. **Fix the stale references:** `CitySim.body` re-resolves from the current system each tick (the tick
   already resolves `system.body(city.body.id)` for terrain at `advance_simulation_tick.dart:512`). That way
   colonies, flight, renderer and snapshots all read the same air. The render descriptor is already sticky
   at about 1 Hz, which is fine for something that changes over colony-years.
4. **Save** the `atmospheres` block in `GameStateCodec` (version bump). On load: rebuild the universe from
   reference data, then apply the saved inventories (the same `replaceBody`). A save from before this has no
   block, and gets the reference air.
5. **Retire the slider:**
   - `CitySim.terraform` stops being state. It becomes a readout ("progress to breathable": the derived
     `SurfaceConditions` distance to breathable), so the Terraforming meter in `city_panels.dart:175` keeps
     meaning something.
   - `SurfaceConditions.of(terraform:)` loses the fake blend.
   - The biome flip becomes **climate-driven**: biome is re-derived when temperature and humidity cross the
     bands already in `habitability` and `floraDensity`.
   - An old save's `terraform` value is read and ignored.
6. **Determinism / multiplayer:** the inventory is world state, so it goes into the `WorldSnapshot`
   fingerprint. The wire's gas enum is unchanged; descriptors already carry the gas fractions.

## 6. Phases

1. **Inventory + derived air + wiring** (§3.1, §3.2, §5.1–5.4): the existing tower vents O2 into the planet as
   well as the stock; industry CO2; save/load; stale-reference fix.
   - Tests: Earth is immovable, Mars moves, conservation of moles, warp-step stability, save round-trip, and
     flight drag on Mars rising with pressure.
2. **Feedbacks + breathability** (§3.3, §3.4): volatile reservoirs (Mars caps), escape (the Moon leaks),
   greenhouse temperature; `airO2` into life support and into the secession measure; the CitySim getters
   switched to the derived air. **Methane decay moved to phase 3** (review, 2026-10-10): nothing in phase 2
   puts CH4 into any sky, so a sink would be dead code with an arbitrary lifetime; it lands with the phase-3
   buildings that can emit methane, anchored so a reference Titan rests.
3. **The tower family + retiring the slider** (§4, §5.5): new specs, climate-driven biome, the
   progress-to-breathable readout, an atmosphere panel (pressure, gas mix, temperature trend, and which
   colony is doing what to it).
4. **Imports from space:** later.

## 7. Decisions (user, 2026-10-10)

- **Q1 Timescale:** yes, as proposed, and **tunable**. `terraformRateScale` lives in a tuning object with the
  ~50 towers / ~30 Mars years target as its default.
- **Q2 Escape:** yes. Small bodies leak. Add a **late-game Atmospheric Retention Array**: a magnetosphere
  generator plus upper-atmosphere containment that suppresses escape on its body, scaled by the number of
  arrays, power-hungry, unlocked late. It lets the Moon keep air the player pays to hold. Phase 2 (escape)
  and phase 3 (the building).
- **Q3 Industry on the planetary ledger:** yes.
- **Q4 Flight effects:** yes. Flight reads the republished body.
- **Q5 Shared air:** yes. Colonies on one body share one atmosphere.

## 8. Phase 1 as built (2026-10-10)

- **State:** `PlanetAtmosphere` (`lib/domain/planetary/planet_atmosphere.dart`) replaces `AtmospherePollution`. It is
  seeded eagerly per body from the reference air (`InMemoryAtmosphereRepository.seeded`), so a body that was
  re-skinned before first use cannot seed a false reference. Airless bodies get no inventory until escape exists
  (phase 2): without it, gas vented onto the Moon would stay forever.
- **Derived air:** ratios against the reference model (pressure ∝ column mass; ρ ∝ P·μ; H and R_specific ∝ 1/μ; the top
  of the atmosphere moves to stay at the reference's absolute pressure). An untouched inventory hands back the
  reference objects identically. **Temperature stays at reference** until the greenhouse model (phase 2).
- **Flows:** `PlanetAtmosphereService` + `TerraformTuning` (`planet_atmosphere_service.dart`). The tower vents
  `1000 mol/s × terraformRateScale (2.2e5)` per unit throttle (`CitySim.oxygenatorRun`), which takes Mars to
  pO2 = 0.16 atm in ~30 Mars years with 50 towers. **The vent stops at `oxygenTargetPa` (0.16 atm, full §3.4 cover)**:
  that is what makes Earth immovable by towers (it starts at 0.21 atm) and bounds the inventory. Industry CO2 is
  not scaled. Every term is exact for constant flows, so warp steps are stable.
- **Timescale note:** 30 Mars years is 1.78e9 s of sim time — about 30 min at 1,000,000× warp, 5 h at 100,000×.
  The "about a day of play at 1×" estimate in §4 does not hold for a real-time 1× clock.
- **Tick:** colonies record flow AMOUNTS per body in their city phase; the planetary phase after the city loop
  integrates them and republishes via `UniverseRepository.replaceBody` (now on the port) past a 1e-6 tolerance,
  re-pointing the body's colonies. `StarSystem.withBody` now keeps the body's slot. Each colony also re-resolves
  `CitySim.body` at the start of its phase.
- **Save:** `GameStateCodec` v2 `atmospheres` block; load resets every inventory to reference, applies the saved
  ones, republishes every body and re-points the loaded colonies. **Fingerprint:** `WorldSnapshot.atmospheres`
  (relative 10-significant-figure hashing), captured by `AuthoritativeSimulation`.
- **Waiting flows live on the inventory** (`PlanetAtmosphere.pendingFlows`, `atmosphere_flows.dart`), not on the tick.
  A frame-budgeted colony (every player colony) replays its ticks after the host loop, so its last frame of flows
  always waits for the next tick. On the tick they were dropped by every `rebuildTick` (cheat toggles), left out of
  a save taken after the replays `flushHeld` forces, and poured into a freshly loaded sky. They are now saved in the
  `atmospheres` block (`pending`), reset on load, and carry the seconds each colony's steps cover, so the haze source
  is read as a rate over the span the flows were produced in rather than over the one tick that integrates them.
- **Open for the user:** (a) the `oxygenTargetPa` vent cap is not in §4/§7; it is what keeps 50 towers from adding
  ~11% to Earth's air at the tuned scale, and the phase-3 towers (greenhouse factory, regolith baker) will need their
  own limits on Earth either way. (b) RESOLVED at integration: `CitySim.breathable` now also needs ≥ 0.5 atm (the `SurfaceConditions` floor), so a
  Mars at the cap (~0.16-0.2 atm of mostly O2) is not breathable. Phase 2 still replaces the getter with the full
  §3.4 definition and partial `airO2`.
- **Not yet (both done in phase 2, §9):** the Atmospheric Harvester still does not remove O2 from the inventory (its stock units have no
  mole conversion yet); the CitySim breathable/o2 getters still read the body (which now carries the derived air).

## 9. Phase 2 as built (2026-10-10)

Feedbacks, breathability and the harvester, on branch `feat/terraforming-p2` from `60a4efd`. The `oxygenTargetPa`
vent cap is kept as it was.

- **Greenhouse temperature** (`lib/domain/planetary/planet_climate.dart`): `T_eq = (S(1−A)/4σ)^¼` from the body's
  sunlight and a Bond albedo table, then an Eddington grey atmosphere `T = T_eq (1 + ¾τ)^¼`. The depth τ is
  `Σ a_i (p_i/P0)^α_i (P/P0)^0.45` for CO2, H2O and CH4, plus a super-greenhouse agent term. Three coefficients do it:
  CO2 against Earth and Venus, H2O against Earth, CH4 against Titan. The pressure exponent makes present Mars come
  out a few K warm. On the physics alone the reference skies land within 2.3 K (Earth −0.03, Mars −2.3, Venus −2.2,
  Titan 0). `PlanetAtmosphere` keeps that residual as a per-body calibration, so an untouched world reads back its
  reference temperature exactly and still hands back the identical reference objects. Temperature feeds the derived
  model: ρ ∝ 1/T, H ∝ T, and `seaLevelTemperature` is published, which `SurfaceConditions` reads.
  - **Agent:** `PlanetAtmosphere.greenhouseAgentMoles` is a trace forcing (C3F8, 0.188 kg/mol). It is not in the
    pressure or the gas mix. 1 Pa gives about +25 K on Mars. Nothing fills it until the phase-3 Greenhouse Factory.
  - **Pressure broadening:** this is why venting O2 into Mars warms it (~+12 K at the cap) with no greenhouse gas
    added.
- **Volatile reservoirs** (`volatile_reservoir.dart`). Only Mars has them; each is sourced in its doc comment.
  - **Stores:** south polar CO2 ice, 6.0e17 mol (Phillips 2011 / Bierson 2016). Regolith-adsorbed CO2, 3.5e18 mol,
    which is 40 mbar, the Jakosky & Edwards 2018 upper bound. Polar water ice, 1.4e20 mol.
  - **Equilibrium:** ice follows Clausius-Clapeyron at a cold trap (the CO2 cap sits 62 K under the mean, at its
    frost point). The soil follows the Fanale/Zent-Quinn isotherm. Each is anchored to the reference, so an
    untouched Mars is at rest. Release is tapered as a store empties, and frost forms at the vapour pressure whether
    or not ice remains. Between the two lines nothing flows, so there is no threshold to oscillate across.
  - **Lags:** the cap and the ice relax over one Mars year. The soil relaxes over 20 years, a deliberate compression
    of a centuries-long thermal soak.
- **Escape** (`atmospheric_escape.dart`): a Jeans rate per gas, `v₀/(2√π·min(H, R))(1+λ)e^−λ`, at an exobase
  temperature. The column is capped at the radius because the Jeans form assumes H ≪ R and otherwise goes to zero as
  λ does (see the review fixes below). The temperature is the skin temperature plus EUV heating, which scales with
  √flux and is cooled by CO2 in proportion to `x_CO2 · min(1, P / 300 Pa)` (the thermostat needs a collisional
  thermosphere). It comes
  out at Earth ~910 K, Mars ~240 K, Venus ~320 K and Titan ~145 K, close to the measured values. The Moon's vented O2
  has an e-fold of ~80 days and Mercury's ~8 years. Mars keeps everything but H2/He. Earth and Venus lose
  < 1e-12 per millennium.
  - **Not compressed:** escape runs at real rates (`EscapeTuning.escapeRateScale = 1`), not `terraformRateScale`.
    Even so, 50 towers hold the Moon at only ~110 Pa, so lunar colonies stay domed.
  - **Phase-3 hook:** `PlanetAtmosphere.escapeSuppression` (0..1, saved) scales every rate. It is what the Retention
    Array will drive.
  - **Airless worlds:** every airless rocky body now gets an inventory, seeded empty, and the giants and the Sun get
    none. Such a world publishes a sky only from 1 Pa (`skyThresholdPa`), so one heavy lunar colony's industry (~0.15
    Pa held against the leak) does not put an atmosphere shell 100 km up and clamp warp for low orbits, and only for
    a bound column (scale height ≤ R/3, `maxScaleHeightPerRadius`), so a small body never publishes one. A leaked-out
    world is pruned back to its exact empty reference and rests. `CelestialBody.copyWith` gained `clearAtmosphere` /
    `clearComposition`.
- **Integration** (`PlanetAtmosphereService`):
  - **Flows and escape:** colony flows are rates over the step. Each gas is solved in closed form for source plus
    leak (`n = S/k + (n₀ − S/k)e^−kh`). The vent cap clamps venting only.
  - **Exchange:** reservoir exchange is sub-stepped at τ_min/64 (capped at 4096), each sub-step with midpoint targets.
    The midpoint lends the climate, while store holdings stay at the start: a cap the half-step emptied otherwise read
    as having nothing to give.
  - **Warp:** one 40-Mars-year step of a warming, venting, polluted Mars matches 4000 short steps to a part in a
    thousand (in practice ~1e-5). The Moon's tower-versus-leak case is exact.
  - **Ledger mode:** `PlanetAtmosphereService.ledgerOnly()` turns the feedbacks off. The phase-1 ledger tests use it.
- **Breathability, one definition** (§3.4).
  - **`CitySim.sky`:** this is `SurfaceConditions` of the body's derived air. Through it, `breathable`, `airO2`,
    `o2Fraction`, `o2Harvestable`, `windFactor` and `hasWeatherAir` all read the planet's air. `isHot` is now by
    temperature (> 330 K with weather), where it used to be "mostly CO2 with weather", which a CO2-thickened 230 K
    Mars passed.
  - **Terraform slider:** `SurfaceConditions.of` no longer lets `terraform` fake pressure, temperature, humidity, O2
    or toxicity. The parameter is accepted and ignored until phase 3; the slider and its biome flip remain.
  - **Double-counted greenhouse:** a `+co2 × p × 120` term on top of the body's temperature read Venus at 11,000 K.
    It is gone.
  - **Partial cover:** `SurfaceConditions.oxygenCover` is `clamp(pO2 / 0.16 atm)` at P ≥ 0.063 atm with toxicity
    < 0.2, else 0. `CitySim.airO2` is that value, or 1 where the air is breathable.
  - **Switched together:** life support now charges `population × (1 − airO2) × rate` and counts the same unmet
    share in `supportablePop`. The secession measures (`localSufficiency`, `localSupportablePop`) were already written
    against `airO2`, so `city_loyalty.dart` needed no edit. The complexity ≥ 0.3 rule for whether O2 is managed is
    unchanged.
- **Atmospheric Harvester** (user request): `CitySim.o2HarvestRate` records the harvesters' bare throttle output
  (before bounty and events) for the share of their yield the colony's oxygen store KEPT. It goes through
  `AtmosphereFlows.o2Harvested` and comes out of the planet's O2 at `TerraformTuning.harvesterMolesPerStockUnit =
  4.4e8`, chosen for symmetry with the tower: the tower vents 2.2e8 mol/s for its 0.5 stock/s. A full harvester
  therefore draws 8.8e8 mol/s, undoing four towers. It cannot take more than is there: the sink stops at zero, and a
  harvester only runs while `o2Harvestable` (≥ 2% O2 in weather-bearing air), so a sky thinned below that stops
  yielding. A full tank, or a world whose oxygen is not managed (breathable, or COMPLEXITY < 0.3), draws nothing.
- **Save and fingerprint:** the `atmospheres` block gains `reservoirs`, `agent` and `suppression`, plus `harvest` in
  the pending flows. The keys are additive, so the version is unbumped, and a phase-1 save loads with reference
  stores. `AtmosphereSnapshot.held` hashes reservoirs, agent and (when set) suppression into the fingerprint.
- **Tick:** a body is skipped only while `isAtRest` (reference air, haze and stores, nothing pending). A perturbed
  body goes on integrating, because its gas leaks and its caps answer the warmth.

**Deviations, and why:**
- **Aerosol cooling is in the model at an effective ~0** (`aerosolAlbedo = 3e-6`). The burden is one colony's
  regional haze. At a veil-strength 0.03, one smoky Mars town cooled the whole planet half a kelvin and froze a tenth
  of its air onto the cap. The term is there for a global aerosol source to drive later.
- **Escape uses the exposed-column upper bound,** with no collisional saturation. Saturated, the Moon would hold a
  vented sky for millions of years (Needham & Kring 2017, ~10 kg/s), and §7 Q2 wants small worlds to leak. Mars's
  heavy gases do not escape at all: only Jeans escape is modelled, not sputtering or photochemistry.
- **No self-sustaining runaway at the default Mars magnitudes.** The release is amplified and bounded: 1 Pa of agent
  gives +27 K, 4× the pressure and the cap gone. When the agent goes, the CO2 recondenses. A runaway that persists
  with the forcing removed needs about 2 bar of CO2 in the soil (`marsDefaults(regolithCo2Moles: 1.76e20)`, the
  optimistic McKay-era inventories). It then settles near 1.8 bar and 336 K and is bounded by the store. A one-bar
  soil collapses back. Jakosky & Edwards magnitudes were kept as the default because the request asked for sourced,
  plausible numbers.
- **Mars's water** is anchored as the EXCESS over the reference cold-trap vapour pressure, because the hand-tuned
  Mars mix carries no water.
- **Life support reads `sky`, not `surface`.** `surface` adds the colony's own smog to the toxicity. On `surface`, an
  Earth town at pollution ~180 flapped between free air and suffocation every few ticks, which broke the secession
  standoff test. Smog stays a health matter on `surface` (disease, flora, open/domed style).
- **Industry CO2 on Mars now mostly freezes onto the cap** within a few years (pressure pinned at the frost point).
  The phase-1 industry tests pin the ledger alone, and a new test pins the buffering.

**Review fixes (2026-10-10, three reviewers):**
- **Harvester draw on what was kept.** It drew from the sky by what it produced, so a full tank (step 6 clips to
  `stockCap`) or a free-O2 world (the store is pinned to the cap) kept thinning the shared sky at four to eight
  towers' worth for oxygen that then existed nowhere. The cap now clips the harvesters first; the draw is their bare
  throttle times the kept share, which also restores the documented four-tower symmetry at any bounty.
- **CO2 thermostat needs a thermosphere.** It read the CO2 mole fraction of any sky, so a Moon whose only air was
  industry CO2 had an exobase near 315 K, a CO2 leak of 4e-22/s and a pressure that climbed without limit. That CO2
  also locked in vented O2 after the towers stopped. The cooling now scales with `min(1, P / 300 Pa)`. Pollution 100
  settles at ~0.39 Pa, and vented O2 leaks away under running industry. The bistability that remains is described in
  the open items.
- **Small bodies.** On Phobos, Eros or Ryugu (λ ≪ 1) the Jeans rate underrated the loss by 10⁵-10⁹, and an ordinary
  colony published a sky whose top lay past Phobos's orbit of Mars. The column is now capped at the radius, so gas
  leaves in about `R/v₀`, and a from-scratch sky with H > R/3 is never published (`air` and `needsPublish` agree).
- **Reservoir taper** clamped to ≤ 1, so a cap grown past its reference no longer releases above the frost line.
- **Fingerprint** now includes `escapeSuppression`.
- **City panel** oxygen figures read `CitySim.o2NeedPerSec`, the same per-second need the tick charges
  (`population × rate × (1 − airO2)`, only where O2 is managed). Harvesters under a sky that cannot feed them show no
  output.

**Cross-lane review fixes (integ/phase2, 2026-10-10):**
- **World drawer oxygen line** (`city_panels.dart`). It was still all-or-nothing on `breathable`, so a Mars
  vented to 0.17 atm (`airO2 = 1`, no oxygen drawn) showed a mask in warning colour and said "harvest or
  split water". It now has three cases on `airO2`. Breathable: oxygen free. Partial: "the sky supplies N% of
  each breath (pO₂ x atm); make the rest", with N rounded down so a near-full sky never reads 100%. Full but
  thin: "compressors draw every breath; no oxygen plant needed", not in warning colour. The resource
  detail's oxygen hint follows the same cases, and offers a harvester only where `o2Harvestable`.
  It keys off `airO2` rather than `o2NeedPerSec > 0`, because an empty colony, or one under COMPLEXITY 0.3,
  has no need on any sky, and the hint would then call raw Mars free.
- **Harvester placement, one rule** (`city_site_rules.dart`, `CitySiteRules.placementRefusal`). The in-world
  editor (`applyToParcel`, `claimOwnSite` and the cell path) placed a harvester on reference Mars and charged
  its ore, and it then made nothing. The editor, the flat builder and the governor now all ask the same
  helper, which also carries the flat builder's no-mine-off-the-ground rule. The editor refuses before
  spending ore. `CitySiteRules.idleForSky` gives the site sheet an "Idle — no oxygen to draw" status, ranked
  above power, staffing and mood. The detail modal shows +0.0 for an idle harvester instead of its nameplate.
  The panels' net rates use the same predicate.
- **Terraform meter renamed "Biome reclamation"** (with an explainer). Since this phase it moves no air and
  only drives the biome flip at 100%. Under the old name it climbed while Temp, Press and Water stood still.

**Open items:**
- **The flat sandbox has no planet.** `CityBuilderScreen` with `driveLocally` (its only production use)
  calls `CitySim.advance` alone. There is no `PlanetAtmosphereService`, so its towers and harvesters move no
  air, and every readout that now reads the derived sky (Temp, Press, Water, Habitability, breathability)
  stays at the reference. The meter is relabelled so it no longer promises otherwise. Giving the sandbox a
  local `PlanetAtmosphere` is the real fix, left for phase 3 with the slider's retirement.
- **Rayleigh brightening:** the grey model omits it, so bar-level CO2 skies run warm (the 2-bar runaway's 336 K).
  The next physics to add is a pressure-dependent albedo term relative to reference.
- **No thermal inertia:** temperature responds instantly, and only the reservoir lags delay the response.
- **Unbuilt §3.3 pieces:** other bodies' reservoirs (Titan's lakes, Earth's ocean water vapour feedback) and
  non-thermal escape. Methane decay is moved to phase 3 (§6).
- **Harvester on Earth:** RESOLVED in review. It was the same defect as the full-tank draw: the store is pinned full
  where O2 is free, so the harvester now draws nothing there. It still builds and runs; it is simply pointless.
- **The CO2 thermostat is bistable on small worlds,** and that is kept. More CO2 cools the exobase and slows the
  leak, so past ~3.5 Pa of lunar CO2 (pollution ~450, about eleven heavy industrial colonies held for centuries) the
  sky crosses onto the held branch and keeps growing while the source runs. Ten heavy colonies settle at ~3 Pa.
- **Two breathability readings remain:** `CitySim.breathable` (planet air) drives life support, agents' sealed
  transport and disasters. `surface.breathable` (with smog) still decides the open/domed style and road sealing at
  build. They were mixed the same way before phase 2. Unify them in phase 3 if wanted.
- **Lunar flight under towers:** a towered Moon (~110 Pa O2, ~43 km scale height) gets a top near 400 km, so low lunar
  orbits feel drag and the warp limiter's in-atmosphere rules. ONE tower already holds ~2 Pa with a top near 250 km,
  and that was decided in review to stand: at 100 km a circular orbit meets ~4 Pa of dynamic pressure (Earth's at
  ~110 km), and the top sits where it has fallen to Earth's at its own top. Pinned by a test. Not playtested.
- **Phase 3:** methane decay (§6); Retention Array → `escapeSuppression`; Greenhouse Factory → `greenhouseAgentMoles`; retire the slider;
  climate-driven biome; atmosphere panel.

## 10. Phase 3 as built (2026-10-10)

The tower family, the slider's retirement, the climate-driven biome and the atmosphere panel, on branch
`feat/terraforming-p3` from `34979ea`. Every tower's flow is `physical rate × throttle × terraformRateScale (2.2e5)`,
recorded per colony and integrated in the planetary phase like the oxygenator's.

| Tower (spec id) | Does | Physical rate at full throttle | Stops at (the Earth limit) |
|---|---|---|---|
| Terraforming Tower (`terraformer`, the Oxygenator) | splits the sky's CO2 into O2, a mole for a mole; past the sky's CO2, splits the crust | 1000 mol/s O2 (unchanged) | `oxygenTargetPa` 0.16 atm (unchanged) |
| Greenhouse Factory (`greenhousefactory`) | emits C3F8 agent into `greenhouseAgentMoles` | 0.5 mol/s (~3,000 t/yr) | `warmingTargetK` 288 K, in closed form |
| Regolith Baker (`regolithbaker`) | bakes CO2 and N2 out of the soil's carbonates and nitrates | turnover 1e-16 of each store per second | `warmingTargetK`, and the stores themselves |
| Carbon Sequestrator (`sequestrator`) | takes CO2 into rock | 1000 mol/s | `co2FloorPa`: 42 Pa of CO2 column (Earth's 280 ppm) |
| Atmospheric Retention Array (`retentionarray`) | suppresses escape on its world: `1 − 0.5^arrays` | — | — (600 power, 20 compute, unlockPop 1000, the top tier) |

- **Oxygenator mass balance.** Phase 1 vented oxygen from nothing. It now takes a mole of the sky's CO2 for each mole of O2 it
  vents, while there is CO2 above the floor, with the carbon going into the ground. Past the floor it splits the crust: lunar
  regolith is ~45% oxygen by mass, and molten-regolith electrolysis is the real route. So the Moon still gets its oxygen and
  the "~30 Mars years" calibration holds (pinned, 28-32). The O2 cap is solved jointly with the split
  (`PlanetAtmosphereService.oxygenCapMoles`). Splitting keeps the mole count and lightens the column, so solving against the
  plain mix let the CO2 the vent then took pull the sky back under the target. On Mars the split lightens the column: a
  year of 50 towers turns the mix over (O2 > 50%) while the pressure barely moves, and the cap frees CO2 as the sky's falls
  under its frost point.
- **Greenhouse Factory.** The agent rises toward 288 K. The target is closed form, because the agent's depth is additive and
  not pressure-broadened (`PlanetAtmosphere.agentMolesForTemperature`). It breaks down over 2,600 years, C3F8's real lifetime,
  not compressed. Ten factories put the ~1 Pa that warms Mars ~25 K into its sky in about three Mars years. Earth already
  stands at 288.15 K, so factories never run there. Placement is refused under no sky.
- **Regolith Baker** (`ReservoirKind.bound`, `volatile_reservoir.dart`). Mars gains two stores that no climate reaches:
  - carbonates, 1.0e18 mol CO2 (~11 mbar, the order Jakosky & Edwards 2018 allow);
  - nitrates, 8.7e15 mol N2 (Stern et al. 2015's Gale Crater nitrate at ~500 ppm through the top 10 m).

  A bake is a turnover: every store gives up `1 − e^(−k·run·t)` of what it holds, exact over any step and bounded by the
  store. Fifty bakers work through an e-fold in ~15 Mars years. The baker stops at the first sub-step that finds the world at
  288 K. Placement is refused off the ground and where `VolatileReservoir.hasBakeableStore` is false, which today is
  everywhere but Mars.
- **Carbon Sequestrator.** It takes CO2 down to the floor and no further. On Earth that takes industrial CO2 back to ~280 ppm
  and costs about a kelvin. Placement is refused where the CO2 column is at the floor.
- **Retention Array.** Each colony's array count (throttle-weighted, over its own span) is kept on the world
  (`PlanetAtmosphere.arraysByColony`, saved as `arrays`) until that colony reports again, and `escapeSuppression` is set from
  their sum. Read off whichever flows landed in a step, a held colony's arrays were zeroed on every tick after a frame's first
  wherever an inline colony shared the world, and a multi-tick replay diluted a neighbour's. The tick drops a deleted colony's
  count after its last flows land, so its arrays stop holding the sky. Six arrays cut the lunar leak to 1/64 exactly, and 50
  towers then hold several times the sky.
- **Methane decay** (moved from phase 2). Methane beyond the reference oxidises over 12 years (Earth's perturbation
  lifetime): `CH4 + 2 O2 → CO2 + 2 H2O`, exact per sub-step, charging the sky only the O2 it has. A reference Titan has no
  excess, so it rests.
- **Planetary ledger** (`atmosphere_ledger.dart`, `PlanetAtmosphere.ledger`). Each integration leaves mol/s per gas, per
  process (industry, towers, harvesters, escape, caps and soil, chemistry) and per colony. A world whose last ledger carried
  colony flows holds it through integrations no colony reports on, and the next report publishes the whole window
  (`AtmosphereLedgerWindow`), colony processes over the span their flows were produced in. Published per integration, a held
  colony's lines alternated between twice the real rate and nothing on multi-tick frames, and the repaint saw the empty tick.
  At the O2 cap, the escape row is the leak, not the vent the cap clipped (which had read as several times the real leak). A colony's share of a tower process
  is its share of the run, applied to what the planet ACTUALLY took after caps, floors and empty stores. Industry is credited
  at each colony's nominal CO2. It is a readout: not saved, and not fingerprinted. `AtmosphereFlows` now keeps a per-colony
  breakdown, with names, which is saved additively (`colonies`, plus the new tower keys). A pre-phase-3 save's pending flows
  integrate unattributed.
- **Slider retired** (§5.5).
  - `CitySim.terraform` is a getter: `sky.breathableProgress`, which is 1 only when breathable. Otherwise it is the geometric
    mean of the oxygen (toward 15%), pressure (toward 0.5 atm) and toxicity tests, capped at 0.99.
  - `SurfaceConditions.of` lost its `terraform` parameter.
  - The save no longer writes `terraform`. An old save's value is read past.
  - The nuclear-winter clearing by towers is kept.
- **Climate-driven biome** (`climate_biome.dart`, `CitySim.climate`, saved as `climate`).
  - **Bands.** Five bands from the derived sky: airless (< Armstrong), frozen (< 268 K, the liquid band), temperate
    dry/wet (humidity 0.05), and scorching (> 330 K).
  - **Hysteresis.** The margins are ±5 K, ×(1 ± 0.25) on the pressure line and ±0.01 humidity. Inside the frost margin a
    temperate world keeps its wetness, because humidity reads 0 below the liquid line. Without that, a cooling grassland baked
    to desert on its way to freezing.
  - **When it moves.** Only a CHANGE of band moves the biome. The first judgement on a world records it and never judges it,
    and that includes a re-site, which resets the band. An untouched world never changes band (pinned for every biome on
    Earth).
  - **Transitions.** The old slider's barren/desert/volcanic → grassland now needs warm, wet air. Mountains and lava lakes
    never change.
- **Atmosphere panel** (`city_atmosphere_panel.dart`). It is the World drawer's ATMOSPHERE section and replaces the "Biome
  reclamation" meter. It shows:
  - pressure, temperature and its trend in K/yr, and the progress meter with the tests still failed;
  - the gas mix with partial pressures, the agent, the loss to space and the share the arrays hold, and the stores;
  - every process and every colony's flows, in Pa of column per year.

  It reads `CitySim.planetAir`, a transient handle the tick, the sandbox or a load sets. Without one it says nothing
  integrates the air.
- **Sandbox air** (`application/usecases/local_colony_atmosphere.dart`). The flat builder with `driveLocally` now runs the same
  service on one inventory after every advance, records against the step's dt as the tick does, and republishes the body to
  the colony. Re-siting seeds the new world. Picking the same world again is no change. The republished body is not in
  `CitySim.bodies`, so the planet picker matches it by id (matched by identity, its assert took the whole side pane down).
- **Shared hot files, kept small:**
  - `city_sim.dart`: fields, two production lines, the env-tick block and two save keys;
  - `city_building_spec.dart`: four specs;
  - `advance_simulation_tick.dart`: three lines, and the deleted-colony array drop;
  - `city_panels.dart`: the meter swapped for the panel, and the picker matched by id;
  - `game_state_codec.dart`: the loaded colonies' `planetAir` handle.

  Not touched: `city_loyalty.dart`, `city_control.dart`, `simulation_view.dart`, the HUD.

**Deviations, and why:**
- **The Oxygenator keeps its label** "Terraforming Tower". A placed building is saved by label (`_specByLabel`), and §4's
  rename would have dropped every one built. The panel names it as the CO2 → O2 process.
- **Crust oxygen past the sky's CO2.** "Consume CO2, never create O2" would strip Mars's whole CO2 system (~4.6e18 mol) and
  stop short of the 1.94e19 mol the 30-year calibration needs, and would leave a lunar tower doing nothing. Splitting the
  crust is the honest second feedstock.
- **The CO2 floor is a column weight, not a partial pressure.** A partial pressure's moles move with the rest of the sky: the
  same 28 Pa is fifteen times the CO2 on an oxygenated Mars. A floor judged once in a long warp step and step by step then left
  skies 1e-4 apart. A column is a fixed mole count per world.
- **The bake draws on new bound stores, not the climate's soil.** The regolith-adsorbed CO2 re-adsorbs toward its isotherm, so
  baking it would be undone over the 20-year soil lag on any cold Mars.
- **The new towers sit on the cell grid** (2×2, the array 3×3) rather than claiming their own plots. The generator stakes one of
  every own-site installation at a colony's edge, so a site of their own would have changed every generated colony.
- **No building emits methane yet.** The decay exists for any excess (a cheat, a later importer) and is pinned. Nothing in the
  family vents CH4, so in normal play it does not run.
- **The baker's warming stop is per sub-step,** not closed form. Its stores exist only on Mars, which is always sub-stepped
  (lag/64), so an overshoot is bounded by about ten days of baking.

**Open items:**
- **Mars cannot become breathable** under these magnitudes. It needs 0.5 atm with under 20% CO2, and its whole nitrogen
  supply (sky plus nitrates) is ~2.4e16 mol. At the O2 cap it is a mask world (full `airO2`, about 0.7 progress). A buffer
  gas has to come from space (phase 4, comet or ammonia imports).
- **The Oxygenator eats the CO2 the warming towers free.** That is the trade-off the family is built around. It is
  unplaytested.
- **The ledger is not saved,** so after a load the panel's flow lines are empty until the first integration. A window
  held for a colony that is gone publishes after 64 integrations.
- **The independent governor builds no towers.** Its options filter on life-support outputs.
- **The new towers use the generic massing,** not bespoke ones like the Oxygenator's stack and tank.
- **Unchanged from phase 2:** Rayleigh brightening, thermal inertia, other bodies' reservoirs, and the two breathability
  readings.

### 10.1 Integrated with colony secession phase 3 (2026-10-10)

Merged with the secession lane's phase 3 without a textual conflict. The seams were checked by hand:

- **The governor and the towers.** The independent governor builds by what a building makes or takes (life
  support, watts, garbage, the dead). Every tower is `group: 'env'`, which `CitySim.isLifeSupport` excludes, and none
  generates power, takes garbage or buries the dead, so an independent council never raises one, a Retention Array
  or a Greenhouse Factory included. `test/colony/phase3_cross_lane_seams_test.dart` pins the catalogue's shape and runs
  an ore-rich, desperate council on Mars for 30 sittings.
- **No demolitions and the towers.** Placing a tower never clears anything: `footprintFree` refuses a cell with a road,
  zone, rubble or building on it, so a multi-cell tower can't tear anything down under the ban. Tearing a tower
  down goes through the same refused demolition paths as any other building.
- **The climate biome.** A biome turn changes only `biome`. The governor (`_lifePlant`) and the starter kit read
  `biomeMult` live. The kit books its freight once, at founding, when the first climate check only records the band,
  so nothing it sized has already shifted.
- **Tick order.** Reputation is handed out before the city phase and reads only loyalty and mood, and the atmosphere
  phase runs after the city phase. Air reaches reputation one tick later, through mood. The two phases share no
  state and cannot reorder each other.
