# Tutorial: From Pad to Orbit

This walkthrough takes a multi-stage rocket from a standing start on Earth's surface
to a stable circular orbit. It assumes you have read the [Quickstart](Quickstart.md)
and know the controls. The goal is to teach the **gravity turn** — the ascent profile
every real rocket flies — and to make apoapsis/periapsis intuitive.

> **Why you can't just go straight up.** Orbit is not about altitude; it is about
> *sideways speed*. A circular orbit just above Earth's atmosphere needs ~7.7 km/s
> horizontal velocity. If you only go up, you fall straight back down. The whole art
> of launch is trading vertical climb for horizontal speed at the right rate.

## 0. On the pad

![A craft on the surface, horizon curving away](images/surface_horizon.png)

You begin landed, nose pointed straight up (radially out from the planet centre),
throttle at zero. The HUD shows `alt 0 m`, `vel ~465 m/s` (that is Earth's surface
rotation carrying you eastward — free speed you keep), and a negative periapsis
(your "orbit" currently passes through the planet).

Check before launch:
- **Δv** (bottom of the HUD) — your total velocity budget. Reaching low orbit from
  Earth costs roughly **9–9.5 km/s** once you include gravity and drag losses, so you
  want comfortably more than 7.7 km/s of raw Δv.
- **Stages** — the active (lowest) stage is your booster; it fires first.

## 1. Lift off — go vertical (0 → ~1 km)

Take **manual control** (M), throttle to **100 %** (`Shift`), and **STAGE** to ignite
the booster. Hold the nose vertical for the first few seconds to clear the pad and
build a little altitude. Watch your vertical speed climb and your apoapsis (`AP`) lift
off the surface for the first time.

## 2. Start the gravity turn (~1 → ~45 km)

As soon as you have vertical speed, **pitch over a few degrees east** (toward your
orbital direction, the way the surface is already carrying you) with `W`/`S`. Then let
gravity do the rest: keep the nose just above the prograde (velocity) direction and
let the turn deepen naturally as you climb. The aim is to be pitched ~45° by ~10 km
and nearly **horizontal by the time you leave the thick atmosphere** (~45 km).

Things to watch on the way up:
- **Q (dynamic pressure)** rises, peaks around 10–12 km ("max-Q"), then falls as the
  air thins. If Q climbs toward the structural limit, **ease the throttle back** until
  it passes — see [Atmosphere, Drag & Reentry](Atmosphere.md).
- **Temperature** rises with air friction; it should stay well under the limit on the
  way up (reentry is the hot part — see [Thermal & Heating](Thermal.md)).
- **AP (apoapsis)** climbing toward your target altitude (say 1 000 km).

When the booster runs dry, **STAGE** to drop it and light the upper stage.

## 3. Coast to apoapsis

Once **AP reaches your target altitude**, cut the throttle to 0. You are now on a
ballistic arc — a real Kepler ellipse — coasting up to apoapsis. Your `PE`
(periapsis) is still inside the planet, so without a second burn you would fall back.

This coast takes minutes, so **time-warp** (`.`) to speed through it — warp will hold
because you are above the atmosphere. Watch the altitude rise and your speed bleed off
as you trade kinetic energy for height.

## 4. Circularize at apoapsis

As you approach apoapsis (altitude near AP, vertical speed near zero), point the nose
**prograde** (along your velocity, now nearly horizontal) and **burn**. This raises the
*opposite* side of the orbit — your periapsis. Keep burning until **PE rises out of the
atmosphere** and meets your apoapsis: the ellipse has become a circle.

The instant `PE` is positive and close to `AP`, **you are in orbit.** Cut the engine.

![Earth and the orbiter from space](images/orbiter_over_earth.png)

## 5. You're in space

You are now coasting on rails as a closed orbit. From here you can:
- Zoom out to the **MAP** view to see your full orbit as a conic section.
- Plan a transfer to the Moon or another planet — see [Orbital Mechanics](Orbits.md).
- Deorbit and attempt a landing — point retrograde, burn to drop your periapsis into
  the atmosphere, then survive the heat ([Thermal & Heating](Thermal.md)).

### Common mistakes
- **Turning too late / staying vertical too long** — you gain altitude but no
  sideways speed, your apoapsis shoots up but you can't circularize. Pitch over early.
- **Turning too aggressively** — you dive back into thick air, drag and heating spike.
- **Forgetting to circularize** — reaching apoapsis is half the job; without the
  second burn your periapsis stays underground and you reenter.
- **High warp in atmosphere** — the sim auto-drops warp to 1× in air for exactly this
  reason; let it.
