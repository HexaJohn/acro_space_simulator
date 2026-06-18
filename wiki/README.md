# ACRO Space Simulator — Game Guide

This folder is the complete game guide and wiki. Start at **[Home](Home.md)** or the
**[promo overview](Promo.md)**.

## Pages

**Getting started**
- [Home](Home.md) — what the game is, and the full index
- [Promo overview](Promo.md) — the pitch, with screenshots
- [Quickstart](Quickstart.md) — install, controls, first flight
- [Tutorial: From Pad to Orbit](Tutorial.md) — a guided launch to orbit

**Mechanics reference**
- [Flight Model & Physics Core](Physics.md) — the loop, forces, integration, the HUD
- [Orbital Mechanics](Orbits.md) — elements, rails vs. physics, transfers, SOI
- [Atmosphere, Drag & Reentry](Atmosphere.md) — density, Mach, dynamic pressure, max-Q
- [Thermal & Heating](Thermal.md) — heat budget, reentry flux, overheating
- [Vehicles, Staging & Propulsion](Propulsion.md) — engines, Isp, the rocket equation
- [Colonies & Economy](Colonies.md) — cities, mining, resources, population
- [Rendering & Camera](Rendering.md) — the camera, planet renderer, atmosphere shader

Every page carries at least one in-game screenshot of the system it describes.
Images live in [images/](images/) and the shared gallery in
[../release/screenshots/](../release/screenshots/).

## API documentation

Code-level API docs (dartdoc) are generated into [../doc/api/](../doc/api/). Regenerate
with `dart doc`.
