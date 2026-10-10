# Terraforming: a planet's real atmosphere

Status: approved for phase 1, 2026-10-10 (decisions in §7). Baseline `dev` at `1246d8f`. Paths are relative to the repo root.

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
   switched to the derived air.
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
- **Not yet:** the Atmospheric Harvester still does not remove O2 from the inventory (its stock units have no
  mole conversion yet); the CitySim breathable/o2 getters still read the body (which now carries the derived air).
