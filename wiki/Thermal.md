# Thermal & Heating

Every part of your vehicle has a **temperature**, and if any part exceeds its limit it
fails. This page explains where heat comes from, how it leaves, and how to survive
reentry — the hottest thing you will do.

![A craft on the day-lit surface](images/surface_nadir.png)

## Each part has a heat budget

A part is modelled as a lump of material with a **heat capacity** (how much energy it
takes to warm it up), a **surface area**, an **emissivity**, and a **maximum
temperature**. Each tick the sim sums the heat flowing **in** and **out** and advances
the temperature accordingly. Cross the maximum and the part overheats and is lost.

## Heat sources and sinks

Four effects are modelled:

| Effect | Direction | Driven by |
|---|---|---|
| **Solar irradiance** | in | sunlight on the lit-facing area (zero in a planet's shadow / eclipse) |
| **Radiative cooling** | out | the part radiating to ~2.7 K space — grows as **T⁴**, so a hot part sheds heat fast |
| **Aerodynamic / reentry heating** | in | stagnation heating roughly **∝ ρ · v³** — density times airspeed *cubed* |
| **Convective exchange** | either | the part trading heat with the surrounding air toward the air's temperature |

The `v³` in reentry heating is the key number: heating climbs with the **cube** of
airspeed, so coming in even a little faster is dramatically hotter. (Heavier
atmospheric gases heat more — a composition factor scales it.)

## In space: hot side, cold side

With no air, your temperature is a tug-of-war between **absorbed sunlight** and
**radiation to space**. A part in direct sun heats up; the same part in a planet's
shadow (eclipse) cools as it radiates away its heat with nothing replacing it. Long
exposure on one side, or sitting in shadow, shifts the balance — relevant for long
coasts.

## Reentry: surviving the fire

Reentry heating is `≈ ρ · v³`, so it peaks where **density and speed are both high** —
the middle of the entry, after you have hit the thick air but before you have slowed
down. To survive:

- **Come in shallow.** A grazing entry stretches the deceleration over a longer, higher
  path, so peak `ρ·v³` — and therefore peak temperature — stays lower. A steep dive
  concentrates the heating into a short, brutal burst.
- **Watch `temp` on the HUD.** It shows the hottest part vs. its limit. If it climbs
  toward 100 %, you are too steep or too fast — and there is little you can do once
  committed, so plan the entry angle *before* you hit the air.
- **Let radiation help.** Because cooling scales as T⁴, a part dumps heat quickly once
  hot — the danger is the *rate* of input outrunning it, not the steady state.

> A landed craft co-rotating with the planet is **not** moving through the air, so it
> generates no reentry heat just by sitting there — an early bug that cooked stationary
> craft under time-warp was fixed by measuring airspeed relative to the *co-rotating*
> atmosphere. There is also a cheat toggle to disable overheating for practice.

## Practical limits

- **Ascent** is usually thermally easy — you are slow while the air is thick.
- **Reentry** is the test — orbital speed meeting thick air. This is what heat shields
  exist for.
- **Long sun exposure** matters on interplanetary coasts but rarely threatens a part on
  its own.
