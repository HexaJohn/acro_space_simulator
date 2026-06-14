# ACRO SPACE SIMULATOR

### Build it. Fly it. Mine it. Colonize it. — at 1:1 scale.

![Acro Space Simulator](screenshots/01_orbit_overview.png)

---

## A real physics engine, not a fly-by

Patched-conic orbital mechanics at **true 1:1 scale** — metres and kilograms,
no fudged units — with a custom precision lattice that kills the floating-point
jitter that breaks naive solar-system sims. Coast on analytic Kepler rails;
thrust, dragand reentry drop you into full RK4 6-DOF physics.

## Two ways to fly

🚀 **Rockets** — stage, gimbal, and burn Hohmann transfers the autopilot can fly
for you (Δv-budget checked before it commits).
✈️ **Aircraft** — air-breathing jets with ram boost and flame-out, wings with
real lift curves and stall. Assembled craft **bake into a single rigid body**.

## The whole Solar System

☀️ Sun + 8 planets + **5 dwarf planets** + ~20 moons, real masses, radii, and
eccentric/inclined orbits. Biomes, ore maps, atmospheric chemistry, axial-tilt
**seasons**, jet streams, and **magnetospheres**.

## Survive everything space throws at you

🔥 Reentry heat (heavier atmospheres burn hotter) — ablate it with a heat shield.
☢️ **Radiation** — cosmic rays, Van Allen belts, solar flares. Shield your crew
or watch them sicken.
💨 Max-Q overstress, splashdowns, life-support, structural failure.

## Dig the periodic table

⛏️ **45 real elements** distributed as abundance-weighted ore veins — common iron,
rare platinum. Mine with a rig, a city-scale district, or convert in situ
(**ISRU**: ore → fuel) aboard a colony ship.

## Grow a civilization

🏙️ A full **Cities-Skylines-style** layer: RCI zone demand, road/utility networks,
city services, happiness — and **arriving cargo flights drive demand**, wiring
your logistics empire straight into urban growth.

## Built right

🧱 Domain-Driven + CLEAN architecture across **23 bounded contexts**, a pure
physics core with zero UI coupling, and a Rust-FFI performance seam ready for the
heavy loops. **335 tests, all green.**

---

> *Acro Space Simulator v0.1.0 — Flutter / Dart. Top-down tactical view this
> release; the physics underneath is fully 3D.*
