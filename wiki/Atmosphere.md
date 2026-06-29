# Atmosphere, Drag & Reentry

An atmosphere is both your friend and your enemy: it lets you aerobrake and land, but
it can tear a craft apart on the way up and cook it on the way down. This page covers
air density, drag, Mach effects, and the structural limit (max-Q).

![Atmosphere limb glow above the surface](images/atmosphere_limb.png)

## Air density falls off with altitude

A body's atmosphere has a **density** that is highest at the surface and thins
exponentially with altitude until it fades to vacuum at the top of the atmosphere.
Above that height there is no drag and no aero heating — you are effectively in space.
Different bodies have very different atmospheres: Earth's is thick and blue, Mars'
is thin and dusty, Venus' is a crushing sulphuric haze, Titan's is dense orange organic
smog. The atmosphere tint you see on a body's limb reflects this.

## Drag

Moving through air costs you speed. The drag force is

```
F_drag = ½ · ρ · v² · Cd · A
```

where `ρ` is the local air density, `v` is your **airspeed** (speed relative to the
air, which co-rotates with the planet and can be blown by wind), `Cd` is the drag
coefficient, and `A` is the reference cross-section. Two things to notice:

- Drag grows with the **square** of speed — going twice as fast is four times the drag.
- Drag grows with **density** — the same speed is far more punishing low down.

So the danger zone is **fast *and* low**. A good ascent keeps speed modest while the
air is thick and saves the big acceleration for the thin upper atmosphere.

### Mach effects

As you approach the speed of sound, the drag coefficient **rises sharply** (the
transonic "drag divergence" around Mach 1) before easing supersonically. Punching
through the sound barrier in thick air is one of the most stressful parts of a launch.

## Dynamic pressure (Q) and max-Q

**Dynamic pressure** is the aerodynamic load on your structure:

```
q = ½ · ρ · v²
```

It is shown on the HUD as `Q`. On a launch, `q` climbs as you speed up, peaks somewhere
in the lower-middle atmosphere — the famous **"max-Q"** — then falls as the air thins
even though you keep accelerating. Every vehicle has a **maximum dynamic pressure** it
can withstand; exceed it and the craft **breaks apart** (a `StructuralFailure`). The
fix is exactly what real rockets do: **throttle down through max-Q** to keep `q` under
the limit, then throttle back up once you are higher and the air is thinner.

> The structural check is `q = ½·ρ·v²`; if it exceeds the vehicle's limit the vessel is
> destroyed and a structural-failure event is raised. There is a cheat toggle to
> disable aero load for practice.

## Reentry

Coming back down, the same physics works in reverse and gets *hotter*. You hit the top
of the atmosphere at orbital speed (several km/s). Air resistance bleeds that speed off
as **heat** — the faster and steeper you come in, the more violent it is. Manage reentry
by:

- **Entering shallow.** A grazing entry spreads the deceleration over a long path and
  keeps peak heating and `q` lower. A steep dive concentrates both and can destroy the
  craft.
- **Pointing the right way.** Keep your heat-tolerant end into the airflow.
- **Watching `temp` and `Q`.** Both spike during entry; if either nears its limit, you
  came in too steep or too fast.

The heating itself — how the hull's temperature actually rises and whether it
overheats — is covered in [Thermal & Heating](Thermal.md).

## Using the atmosphere on purpose

- **Aerobraking:** dip your periapsis into the upper atmosphere on each pass to shed
  speed for free instead of spending fuel — cheaper, but slower and riskier.
- **Landing:** the atmosphere does most of your braking; you only need engines (or
  chutes) for the final touchdown.
