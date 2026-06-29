# Flight Model & Physics Core

This page explains how ACRO actually moves a vessel — the simulation loop, the forces,
and the integration. You do not need this to play, but it makes every number on the
HUD meaningful and tells you *why* the craft does what it does.

![Earth and a vessel from orbit](images/atmosphere_limb.png)

## The simulation loop

The game advances in fixed steps (the **tick**). Each tick, for every vessel, the
core use case decides **how** to move it and by how much:

1. **Pick a propagation mode** (see below) — analytic on-rails, or full physics.
2. **Gather the forces** acting on the vessel this step (gravity, thrust, drag, …).
3. **Integrate** the equations of motion to advance position, velocity, and attitude.
4. **Apply subsystem updates** — propellant drain, heating, structural checks.
5. **Raise domain events** — staging, destruction, SOI changes — for the UI to react.

Time-warp multiplies how much simulated time passes per real second. In an atmosphere
warp is forced to 1× so a single step can't leap kilometres through dense air.

## Two propagation modes

A vessel is moved in one of two ways, chosen per-vessel each tick:

| Mode | When | How |
|---|---|---|
| **On-rails** (analytic) | coasting, engine off, no significant drag | the orbit is a fixed Kepler ellipse; position is solved directly from the elapsed time. Exact and cheap — no drift. |
| **Physics** (numerical) | under thrust, in atmosphere, or otherwise perturbed | a **4th-order Runge–Kutta (RK4)** integrator steps the full force model forward. |

The handoff is seamless: light the engine and the craft switches to physics; cut it
and circularise and it goes back on rails as a clean ellipse. A **landed** vessel
skips motion entirely but co-rotates with the planet (it stays stuck to the ground as
the body spins).

## The forces

Under physics integration the net force is the sum of contributors, each a small,
testable model:

- **Gravity** — Newtonian, `F = -G·M·m / r² · r̂`, from the dominant body (and, near a
  boundary, the body you are transitioning into). This is what curves every
  trajectory. See [Orbital Mechanics](Orbits.md).
- **Thrust** — from active engines, along the (optionally gimballed) nozzle axis. Its
  magnitude and the propellant it burns follow the rocket model. See
  [Vehicles, Staging & Propulsion](Propulsion.md).
- **Aerodynamic drag & lift** — only inside an atmosphere; rises with air density and
  the square of airspeed, with a transonic drag rise near Mach 1. See
  [Atmosphere, Drag & Reentry](Atmosphere.md).
- **Wind** — the weather context can add a surface-relative wind so storms and jet
  streams actually push ships around.

## Mass properties

A vessel is not a point — it has **mass and inertia**, and both *change* as it flies:
propellant drains (lowering mass, raising acceleration for the same thrust), and
staging drops dry mass all at once. Thrust acts at the engine, so off-axis or
gimballed thrust also produces a **torque** that rotates the craft. Attitude is
tracked as a quaternion and integrated alongside position.

## Scale and precision

ACRO models the Solar System at **1 : 1**. Distances span from metres (a craft on the
pad) to hundreds of millions of kilometres (interplanetary). To keep floating-point
error small, physics runs in a **floating-origin** frame — coordinates are kept small
and local — while a precise integer-lattice vector type carries the absolute position.
The renderer projects from this same data, which is why you can zoom continuously from
the surface to interplanetary distance without the world tearing. See
[Rendering & Camera](Rendering.md).

## Reading the HUD

| HUD field | Meaning |
|---|---|
| `alt` | altitude above the body's surface |
| `vel` | speed relative to the body's centre (inertial) |
| `thr` | current throttle |
| `AP` / `PE` | apoapsis / periapsis — the high and low points of your orbit |
| `temp` | hottest part's temperature vs. its limit |
| `Q` | dynamic pressure — the aerodynamic load on the structure |
| `fuel` | remaining propellant |
| `dv` | Δv — remaining velocity budget (your "how far can I go" number) |

Each of these is explained in depth on the linked mechanics pages.
