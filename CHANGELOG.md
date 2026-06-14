# Changelog

All notable changes to Acro Space Simulator.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

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
