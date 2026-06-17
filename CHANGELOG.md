# Changelog

All notable changes to Acro Space Simulator.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [0.2.0] — 2026-06-17

A large feature pass turning the engine into a playable game: a full
Cities-Skylines-style **colony builder**, end-to-end **flight integration**
(design → launch → orbit → land), and several new domains. **408 tests passing,
`dart analyze` clean, web build compiles.**

### Colony / city builder
- Full city-builder screen: paint **zones** (RCI demand + building growth),
  **roads**, **utilities**, **power grid**, **water table** + aquifer pumps,
  bulldoze, retrofit, and support tools.
- **Physical biomes** derived from surface scalars (temperature, humidity,
  atmosphere, composition): habitability + flora density gate what grows.
  Earth-like worlds grow trees/grass; new **coastal / ocean / wetland / volcano**
  biomes.
- **`LiquidMix`** oceans/lava as a molecular mixture — colour + properties
  (molten / potable / combustible) derive from the blend; pollutable; tints
  water/lava tiles (methane Titan, sulphuric Venus, lava Io).
- **Per-tile elevation** (opt-in *Relief* toggle): rolling-hills heightfield,
  terrain-following scatter/decals, building footprints level to their tile,
  one-edge flat coastlines, fully-flooded oceans.
- **Per-building colony styles** (open / domed / orbital) captured at build
  time; **Retrofit** tool converts in place; open buildings decompress in
  vacuum/anoxia. Stations get truss **grid floors** + pressurised **transport
  tubes**; domed worlds get **pentagon-sphere** habs; spaceports render as
  **L-shaped pad + tower** with one launch tower per footprint tile.
- **Disasters**: per-tile spreading **fire** (blocked by roads, fought by
  emergency services), slow drifting **tornado** + sweeping fronts that end when
  they leave the map, mortality/health, pollution with an **ocean sink** so a
  watery world stays clean unless map-filling industry. Screen effects fade
  in/out.
- **Spaceport logistics**: multiple ordered **delivery schedules** per pad,
  per-pad assignment, **spare-fuel** option (self-fuel vs colony-fuel-or-
  grounded), and **autonomous round-trip delivery flights** that fly a real
  ascent → orbit-coast → descent. **Request-assistance** relief craft (anti-
  soft-lock). Stacked **status notification** list (starving / no-spaceport /
  fire / pollution / disease / power).

### Flight ↔ simulation integration
- **`FlightWorld`** + `FlightTraffic` provider — a shared, transport-agnostic
  flight state (network seam via the existing snapshot/channel) for in-flight
  craft, supply traffic, and collisions.
- Dual-mode **ascent/descent flight screen**: flown trajectory trail +
  **predicted ballistic rail**, nav-ball **zenith/nadir** up/down markers,
  time-warp, per-tower **pads** across the bottom, traffic blips, and a 3D
  N/E/S/W scene.
- **Reuse the real 3D solar-system sim for ascent**: a **multi-stage** launch
  vehicle spawns on the host body's **surface at the colony's lat/long**;
  **STAGE / decouple** in flight; live **staging info** + **Found colony**
  button when landed; bridged colony **traffic** (cargo shuttles + rival
  players) as named orbiters; docked control panel; **atmospheric warp clamp**
  (real-time near the ground so launches don't tear apart at max-Q); liftoff
  un-lands a thrusting craft.
- The **VAB** launches the actual designed craft into the 3D sim; the **lander**
  launch routes there too.

### New domains
- **Megastructures**, **agriculture** (farms), **power plants**, **ground
  vehicles** (assembler + catalog + parts).

### Render & camera
- **Perspective camera** alongside the ortho map cam; **sphere textures** for
  bodies; lower zoom floor (0.5 m/px) so the surface/craft are reachable; sphere
  render isolated behind a disc fallback.

### Fixes / balance
- Pollution no longer flips build style or demolishes buildings except at
  extreme levels; abandoned buildings render as full-height grey ruins (no
  shrinking); ascent has no "fail" outcome (orbit or destroyed-on-impact);
  thunderstorm strike rate reduced.

## [0.1.0] — 2026-06-14

First tagged release. A complete DDD/CLEAN space-flight + colony simulation
engine with a top-down tactical demo. **335 tests passing, `dart analyze`
clean, web build compiles.** 23 domain contexts, 127 library files.

### Flight & physics
- 1:1-scale patched-conic orbital mechanics; `PreciseVector3` precision lattice.
- On-rails (analytic Kepler) ↔ physics (RK4 6-DOF) mode switching per vessel.
- Real eccentric/inclined body ephemeris; SOI transitions with frame-shift.
- J2 gravity oblateness; trajectory prediction + render trails.

### Vessels, parts & aircraft
- Real-world parts catalog (rockets + aircraft); `VesselAssembler` bakes placed
  parts into one rigid body (mass, CoM, parallel-axis inertia).
- Air-breathing jet engines (ram boost, vacuum flame-out); wing lift + stall.
- Engine gimbal thrust-vectoring; RCS/reaction-wheel attitude control; staging.

### Thermal & survival
- Thermal model: solar, reentry (∝ρv³), velocity-dependent convection, radiation.
- Ablative heat shields; composition-aware reentry heating (CO₂ vs H₂).
- Ocean thermal mass / climate moderation + freeze; water splashdown quench.
- Structural max-Q failure; surface impact/landing; life support (crew O₂/food/water).
- **Radiation**: cosmic + Van Allen belts + solar flares, dose accumulation,
  sickness/lethal thresholds, shielding attenuation.

### Resources, mining & ISRU
- **Periodic table**: 45 real elements with density/category/crustal abundance;
  abundance-weighted ore distribution across planet surfaces.
- Vessel mining rigs, city-scale mining districts, and in-situ ISRU converters.

### Cities (Cities-Skylines-style)
- RCI zone demand + building growth; road/utility connectivity gating.
- City services + happiness (gates growth); flight arrivals create demand.
- Power grid, supply chains, population, cargo delivery into stockpiles.

### Autonomy & logistics
- Autopilot (maneuver-node execution); Hohmann/circularize/plane-change planning
  with fuel-budget abort; autonomous docking; recurring cargo schedules.
- Rendezvous targeting; comms (light-time, occlusion, relay network) gating autopilot.

### Multiplayer
- Deterministic authoritative simulation; ownership-validated commands.
- Loopback transport + client prediction/reconciliation; world snapshots.

### Campaign
- Science + tech tree + situation classifier; contracts/missions; economy (Treasury).
- Full save/load (state, resources, thermal, plans, crew, mining) + resume-determinism.

### Universe
- Real Solar System: Sun + 8 planets + 5 dwarf planets + ~20 moons, real params.
- Per-body planetary science: biomes, atmospheric composition, seasons (axial
  tilt), jet streams, magnetospheres.

### Render & controls
- Top-down XY painter with ultra-basic lit-disc shading + atmosphere halos.
- Manual 3D piloting (keyboard) + orbit camera; save/load UI; live HUD.

### Known limitations
- Top-down render only (no 3D scene); loopback multiplayer only (no network
  transport); in-memory saves (no file I/O); periodic table covers 45 of 118
  elements (architecture supports all 118).
