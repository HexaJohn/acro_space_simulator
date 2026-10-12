# Desire paths and traffic laws

Status: draft, 2026-10-12. Short on purpose: vision, model, phases, decisions.
Only the next phase gets a detailed spec, just before it is built.

## 1. Vision

A colony doesn't need roads to work. Before any road is laid, people cross open ground
between home, work and the spaceport, choosing the easiest line: short, and not too steep.
Their tracks wear in, and a worn track is quicker, so later trips follow it. A handful of
trails emerge that follow the terrain rather than a grid. Roads are something the colony
grows into, and **traffic laws** are what end off-road driving.

What prompted this: the moon starter base is a ruled ±300 m crossroads lined with parked
cars (decoration baked into the road tiles, one every 7.4 m), for a colony of six people.

## 2. Today (from the code)

- `CityStarterKit.found` commits two streets through the origin and ignores grade.
  The four utility sites count as served because a road comes within 90 m
  (`ParcelNetwork.manualServeM`).
- A lot no rooted road reaches does nothing: no power, jobs, housing or growth
  (`city_sim.dart` ~1406, ~4884).
- Agent trips need both ends `reachable` on the `LaneGraph`. Otherwise the trip is an
  instant "walk" (`CitizenTrips._place`), with no travel time.
- Route cost has no grade term. Grade limits apply only when building (`RoadClass.maxGradePct`).
- The kerb cars come from `CityTileMesher.curbParkingFor`, which has nothing to do with sim
  state. The agents' own kerb rows (`ParkedCarTable.kerbCars`) are never drawn.
- There are nine laws (`enum Law`, `city_sim.dart:240`). Each effect is a hard-coded
  `has(Law.x)` check, and auto-voting uses hysteresis bands.

## 3. Core model

**Trail field** (`lib/domain/colony/city/trails/`, new). This is a coarse grid over the
colony plat, 10 m cells *(default)*, so 2 km across is 40k cells. Each cell holds:
- ground height, sampled once from the DEM by the host; a flat grid in headless tests;
- `wear`;
- a blocked bit, set for building footprints (except the door cell) and for slopes too steep.

Wear decays with a half-life of about 3 game days *(default)*, so an unused trail fades.

**Router.** 8-connected A* over the field. The cost of a step is
`length · (1 + (grade/g0)²) · (1 − 0.6·wear)`. A cell is impassable above the vehicle's
maximum grade: 45% for a rover *(default)*, about 24°, close to the 25° the Apollo rover was rated for. The wear discount is the active-walker effect
that makes trips converge onto shared trails. Routes are cached per (from, to) door pair
and dropped when the wear has shifted enough to matter.

**Trips.** If a road route exists, the trip goes by road as today. If none does and
off-road travel is allowed, the citizen goes off-road. On an airless body that means
everyone in a pressurised rover; where the air is breathable, people walk under 400 m and
take a rover beyond *(default)*. Travel time is the trail length divided by a speed that
depends on grade and wear, so off-road trips count toward `tripRatio` and `commuteEff`
and slow the colony honestly. Each finished trip lays wear along its route.

**Service.** `lotServed` gains an off-road tier: a lot the trail router can reach from the
colony root counts as served while off-road travel is allowed. A roadless colony therefore
works, only more slowly.

**Rendering.**
- Worn cells show as trails on the plat map.
- In 3D they darken the regolith as tyre tracks.
- Off-road vehicles are drawn moving along their trail.
- Kerb cars are drawn only where a car really is parked *(default)*.

## 4. Traffic laws

All new `Law` entries (saved by name, so appending is safe), enacted and repealed like the
others, with auto-vote bands:

- **Off-Road Ban.** The switch for desire paths. Off-road trips stop and trails fade.
  Lots no road reaches lose vehicle service, and the panel warns about this and names those
  lots before the ban is enacted. The colony votes it in by itself once roads reach ≥ 90%
  of lots.
- **Traffic Code.** Right-of-way: junction penalties drop and crashes are cut hard.
  Crashes are new: without the code, collisions occur at a small rate per vehicle-km, and
  their injuries load the hospital and lower the mood.
- **Speed Limits.** Slower roads, fewer and milder crashes.
- **Parking Ordinance.** No kerb parking; cars park in lots and garages only.
- **Pedestrian Priority.** Walkers have right-of-way: safer junctions, slower ones, and
  walking becomes more attractive.
- **Vehicle Licensing.** Fewer crashes, a fee per car, lower car ownership.

## 5. Phases

1. **Trails, headless and on the map** (spec in §7).
2. **Trail to dirt road.** Trails worn past a threshold become `RoadClass.path` roads by
   themselves: simplified polylines committed with `groundAt`. Lots get platted along them,
   so zoning follows the desire lines.
3. **Seen in 3D.**
   - Off-road vehicles on the wire, drawn moving.
   - Worn regolith darkens.
   - Kerb cars drawn only where a car really parks.
4. **Traffic laws** as in §4, with crashes.

## 6. Decisions (user, 2026-10-12)

- A busy trail becomes a **dirt road on its own**.
- The starter kit has **no roads**.
- **All four** laws are added. When off-roading is legal is its own law, the **Off-Road Ban**.
- **This session** builds it all, and leaves notes in agent-traffic.md for the Agent Traffic
  session.

## 7. Phase 1 spec

**`lib/domain/colony/city/trails/`**
- `TrailField`: 10 m cells over the parcels' bounding box plus 400 m, at most 480 cells
  across.
  - Heights come from `city.body.terrainField`, or are flat when it has none.
  - `wear` is a Float32 per cell. Cells inside a footprint are blocked, except the door cell.
  - The field grows (keeping its wear) when the plat outgrows it.
- `TrailRouter`: A* over 8 neighbours. The cost is time: `step / v`, with
  `v = (vRaw + (vWorn − vRaw)·wear) · (1 − 0.6·grade/gMax)`, using
  `vRaw 5 m/s, vWorn 9 m/s, gMax 45%`.
  - Above gMax a cell cannot be crossed.
  - A cell under a road runs at 12 m/s, so a route uses roads where they help.
  - The heuristic is `distance / 12`.
- Door: the midpoint of the parcel's frontage edge (or of its edge nearest the root),
  stepped one cell outward.
- Wear: each finished leg adds `+0.2·(1 − wear)` to its cells. Wear decays with a
  half-life of 3 days of colony time.

**Service.** With the field on and no Off-Road Ban, a lot is served if a cell next to it is
in the root's flood component (the root is the colony origin). This is folded into
`CitySim.parcelNetwork()`, so everything that already reads `lotServed` sees it.

**Trips** (`CitizenTrips._go`). If either end has no road access, an off-road leg is tried
before the instant walk.
- It takes the route's time, which is added to the dwell at the far end (phase 3 makes the
  leg visible).
- It lays wear.
- A commute reports `stats.tripDone(t, length/vWorn)`.

**On/off and saves.**
- `CitySim.trails` is null by default, so every existing colony and test is unchanged.
- `CityStarterKit.found(roads: false)` turns trails on. The two play surfaces use it.
  `roads: true` remains the default for the 28 test files that need the crossroads.
- Saves keep the wear as a sparse list of cells; heights are re-sampled on load.

**Plat.** Wear is drawn as brown cells under the roads.

**Gates.**
1. A hill between two buildings: the trail goes around it.
2. 300 commutes among 4 buildings converge: the cells with wear above 0.5 are a small
   fraction of those ever worn.
3. Decay: an unused trail fades to below 0.1 in about 10 days.
4. A roadless starter kit stays fed and staffed: 10 days, population ≥ 6.
5. A save round-trips the wear.
6. Trails off: the colony and traffic digests are unchanged.

**Built** (2026-10-12): `lib/domain/colony/city/trails/` holds trail_field, trail_router and
trail_network; the gates are in `test/colony/trails/desire_paths_test.dart`. Changes from
the spec above:
- **The rover's limit is 45%.** The moon's test terrain has 31% of its 10 m steps over 25%,
  which cut the spaceport off.
- **A leg lays +0.2.** At +0.08 a fresh track was never worth a detour, so two homes 100 m
  apart never merged their routes. One pass now counts.
- **Heights are sampled on a 40 m lattice** and filled bilinearly: 76 ms, against 975 ms
  for every cell (each relief sample costs about 17 µs).
- **The lander crew are housed at the first spaceport.** This applies in BuildingTable and
  only with trails on. The colony houses the crew in no building, so without it nobody had
  a home to leave from and no trip was ever taken.


**Phase 2 built with it.** `trail_promotion.dart` provides `beatenRuns`, which reads the
runs off the routes taken lately rather than off the raw cells.
- A run qualifies at wear ≥ 0.8 and ≥ 80 m long; it is cut where the route climbs past 20%.
- It is simplified to within 4 m before being committed as `RoadClass.path`.
- One run is promoted per 120 s look.
- The roadless starter colony grades its first dirt road within the gate's 8 hours.

## 8. Phase 4 spec: traffic laws

**One policy object per colony.** `TrafficPolicy.of(laws)` is pure. The agents' core
re-reads it on every sub-step and hands each consumer its own field; no global
`AgentTuning` knob is touched.

| Law | Agents | Colony |
|---|---|---|
| Traffic Code | junction penalties ×0.7 (right-of-way) | crashes ×0.35; upkeep §0.5/wk per 100 people (policing) |
| Speed Limits | mover lane speed ×0.8; free-flow times stay unscaled | crash rate ×0.6, injuries per crash ×0.6 |
| Parking Ordinance | no kerb parking; arrivals use a stall, else the garage | kerb cars are not drawn (phase 3) |
| Pedestrian Priority | junction penalties ×1.25 | crashes ×0.8; walking happiness +2% |
| Vehicle Licensing | car ownership ×0.75 at move-in | crashes ×0.7; fee §0.2/wk per car |
| Off-Road Ban | no off-road legs | trails fade; lots off the roads lose service |

**Crashes.** These are aggregate, not per vehicle.
- The rate is `vehicle-km · 0.004/km · Π(law factors)`. Vehicle-km counts both the
  agents' road driving and the off-road legs; an off-road km counts ×1.5, since it is
  unmarked and steep.
- Each crash injures 1 person: added to the colony's patients, a hospital load, and a
  mood dip proportional to `crashes/day` over the population.
- 5% of crashes are fatal: the death joins the colony's corpses.
- Readout: `crashesPerDay`, shown on the Traffic and Politics panels.

**Auto-vote bands** (for auto-voting governments only):
- Traffic Code at ≥ 2 crashes a day; off below 0.5.
- Speed Limits at ≥ 4 crashes a day.
- Parking Ordinance once kerb occupancy is ≥ 90%.
- Pedestrian Priority once the population is ≥ 300.
- Vehicle Licensing once there are ≥ 400 cars.

**Gates.**
- Each law's effect moves its own number in a twin run, with everything else equal.
- With no law enacted, the digests are unchanged.
- Laws round-trip a save by name.
