# Acro Space Simulator — User Guide (v0.1.0)

A 1:1-scale space-flight + colony simulator built on a Domain-Driven /
CLEAN-architecture physics engine. Fly rockets and aircraft, run patched-conic
orbital mechanics, mine real elements, build cities, and manage crews through
radiation, reentry heat, and life support — across the real Solar System.

![Orbit overview](screenshots/01_orbit_overview.png)

---

## 1. Running

Requirements: Flutter 3.38+ / Dart 3.10+.

```bash
flutter pub get
flutter run -d windows      # or: -d chrome
```

The window opens onto a **top-down (XY) tactical view**. Z is "up"; the physics
is fully 3D, the render is top-down for this release.

---

## 2. The screen

- **Bright disc** — the body you're orbiting (centre of the view).
- **Faint rings** — predicted orbit paths for each vessel.
- **Triangles** — vessels. Green = on rails (analytic), orange = under physics.
- **Glowing ring around a body** — its atmosphere.
- **Top-left text** — the HUD: focus vessel body, mode, altitude, velocity,
  throttle, hull temperature, fuel, Δv, dynamic pressure (Q), science, and any
  colony's population / power / water.
- **Bottom-left text** — control mode (AUTO / MANUAL) and key hints.

---

## 3. Controls

| Key / gesture | Action |
|---|---|
| `M` | Toggle **manual flight** for the focus vessel (disables its autopilot) |
| `W` / `S` | Pitch nose down / up |
| `A` / `D` | Yaw left / right |
| `Q` / `E` | Roll |
| `Shift` | Full throttle |
| `[` / `]` | Zoom out / in |
| Pinch / scroll | Zoom |
| 💾 button | Save game (in-memory slot) |
| 📂 button | Load game |

In **AUTO** mode vessels follow their flight plans (autopilot flies maneuver
nodes, docks, runs cargo routes). Press `M` to take the stick.

---

## 4. Core systems

### Orbital mechanics
Patched conics: a vessel feels exactly one body's gravity (its sphere of
influence). Crossing an SOI boundary re-patches the orbit. High timewarp puts
distant/coasting craft on analytic Kepler rails; thrust, drag, or contact drops
them into numerical (RK4) physics. Bodies orbit on real eccentric/inclined
Keplerian paths, with J2 oblateness available.

### Vessels & parts
Craft are **assembled from a real-world-grounded parts catalog** (Merlin 1D,
RL10, turbojets, ramjets, wings, tanks, RCS, decouplers, heat shields…) and
**baked into a single rigid body** — combined mass, centre of mass, and inertia
tensor. Rockets *and* aircraft: jets breathe air (ram boost, flame-out in
vacuum), wings make lift (Cl-vs-AoA with stall).

### Thermal & reentry
Parts heat from sunlight, reentry stagnation (∝ ρ·v³), and convection (which
scales with airspeed), and cool by radiation. **Heat shields ablate** to soak
reentry heat. Heavy atmospheres (CO₂ on Mars/Venus) heat more than light ones.
Water landings quench heat and cushion impact.

### Survival & failure
- **Structural** — exceeding max dynamic pressure (max-Q) tears a ship apart.
- **Impact** — fast surface contact destroys; gentle touchdown lands; water
  splashdown tolerates higher speeds.
- **Life support** — crew consume food / oxygen / water; running out is fatal.
- **Radiation** — cosmic rays, Van Allen belts, and solar flares accumulate
  dose; ~1 Sv causes sickness, ~8 Sv is lethal. Shielding mass attenuates it.

### Mining, ISRU & the periodic table
The surface carries a **real element distribution** (45 elements, abundance-
weighted ore veins — Fe/Al/Si common, Au/Pt/U rare). Mine with a vessel rig, a
city-scale mining district, or convert in situ (**ISRU**: ore → fuel / water /
oxygen) aboard colony ships.

### Cities (Cities-Skylines-style)
Zone Residential / Commercial / Industrial; buildings grow to meet **RCI
demand**. Roads/utilities must connect buildings or they shut down. City
**services** (safety / health / leisure) drive **happiness**, which gates growth.
**Arriving flights create demand** at their destination, tying logistics to city
growth.

### Autonomy
Plan **Hohmann / circularization / plane-change** transfers (fuel-budget checked
before commit); the autopilot flies the nodes, points prograde, and gimbals
engines to steer. Autonomous **docking** and recurring **cargo schedules** run
unattended. **Comms** matter: line-of-sight to a ground station (or a relay
satellite) is required — a blackout pauses the autopilot.

### Multiplayer (deterministic core)
An authoritative simulation validates commands by ownership and advances
deterministically; clients predict locally and reconcile to authoritative
snapshots. (Transport is loopback in v0.1.0.)

### The Solar System
Sun + 8 planets + 5 dwarf planets (Ceres, Pluto, Eris, Haumea, Makemake) + ~20
moons, with real μ, radii, and orbital elements. Planets carry biome/ore maps,
atmospheric composition, axial tilt (seasons), jet-stream bands, and
magnetospheres.

---

## 5. Saving

The 💾 / 📂 buttons serialize the full world (vessel state, resources, thermal,
flight plans, crew, mining) to an in-memory slot and restore it bit-identically
— a resumed game continues exactly as if it had never been saved.

---

## 6. Where next

See **TUTORIAL.md** for a guided first flight, and **CHANGELOG.md** for what's in
v0.1.0. Known limits this release: top-down render only (no 3D scene), loopback
multiplayer only, in-memory saves (no file I/O yet).
