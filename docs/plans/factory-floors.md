# Factory floors

Status: draft, 2026-10-12. Short on purpose: vision, model, phases, decisions.
Only the next phase gets a detailed spec, just before it is built.

## 1. Vision

Every big industrial building is a small Factorio world. Open one and you see a grid floor:
a **receiving dock** on one wall, a **shipping dock** on another, and between them machines
joined by belts and arms. Raw material comes in from the colony (ore, water, steel),
is processed, assembled and packaged, and leaves as goods. Some stations are automated
and draw power. Others are manned and need workers from the colony's labour pool.
The layout is the player's, and a good layout is measurably faster than a bad one.

The colony map stays a city builder. The floor is a zoom-in you can ignore: every factory
ships with a working default layout, so nobody *has* to design one.

## 2. Today (from the code)

- **No per-building state.** A building is a site id (`lot-…` / `cell-<k>`) mapped to a
  const `CityBuildingSpec` (`city_building_spec.dart:50`). `CitySim.parcelBuildings`
  (`city_sim.dart` ~3792), `grownParcels` (~3945) and `utils` (~393) hold no instance records.
- **Production is a flat recipe per spec.** The spec's `inputs`/`outputs` rates run against
  one global `stock` map in `CitySim.advance` (run loops ~1566-1620). They are scaled by
  `throttleFor(spec)` × utilisation × biome/bounty/event multipliers, and drop to 0 when
  stock can't cover the inputs.
- **Staffing is global.** Jobs are summed colony-wide, and workforce is split into
  life-support and everything else (~1448-1508). No building is ever "understaffed" on
  its own. Per-building job slots exist only in the agent layer (`BuildingTable.jobs`), and
  drive commute trips only.
- **Goods teleport.** No freight moves yet. Trucks, `TripPurpose.freight` and the reserved
  `goods` commodity are agent-traffic slice 8 (`docs/plans/agent-traffic.md`).
- **Automation** = the `infiniteRobotics` endgame bool + `Law.robotTax`. `TechTree` in
  `lib/domain/science/` is not wired to the city.
- **Candidates:** zoned `i-low/med/high` (ore → steel), and utility refinery, steelmill,
  electronics, rocketfactory, VAB, gun/missile/rations factories, greenhousefactory
  (`kUtilCatalog` ~386-488).
- **Reusable pieces:** `forward_base.dart` / `base_modules.dart` (modules with crew,
  power share and work queue, toJson per module). `site_access` `SiteProgram.yard` already
  places a truck apron and loading bays on industrial lots, which tells us which wall the
  docks face. Inspector entry: `showCitySiteMenu` (`city_site_actions.dart:309`).

## 3. Core model

New package `lib/domain/colony/city/factory/`. It is pure Dart with no Flutter and no RNG,
and is deterministic.

**`FactoryFloor`**, one per site id, created when the floor is first opened or by template.
- Grid of `w × h` tiles. Size is set by tier, not metres *(default)*: workshop 16×12,
  factory 32×24, heavy / utility plant 48×36.
- Dock edges: receiving and shipping strips on the walls, oriented from the site's yard.
- Entities on the grid:
  - **Machine**: footprint, rotation, recipe, crafting timer, input and output buffers,
    power draw, mode (below).
  - **Belt**: direction, with a short item queue per tile (2 lanes later, 1 lane first).
  - **Arm**: moves one item per swing from tile A to tile B.
  - **Buffer**: chest, plus splitter/merger later.
  - **Dock port**: receiving ports emit items, shipping ports consume them.

**Recipes** (`FactoryRecipe`): inputs → outputs + time + station kind (smelter,
press, assembler, chem, packer). The chain is raw → intermediate → product → **packaged
crate**. Only crates leave through shipping.

**Intermediates stay inside the floor** *(default)*: plates, wire, circuits, frames and so
on are factory-only item ids, not `Commodity`. The colony stock stays clean. The only new
colony-facing items are the products already in `commodity.dart` (steel, electronics,
rocketParts, guns, ammo, rations, missiles) plus the reserved `goods`.

**Stations: manned vs automated.** Each machine has a mode:
- *Manual*: needs N workers, no extra power, slow.
- *Assisted*: 1 worker, some power, medium speed.
- *Automated*: 0 workers, high power, needs **maintenance** (a technician slot per K
  machines, or a slow decay of uptime), and costs electronics to build.

Arms and belts are always automated, cheap and low power. A floor's **job demand** is the
sum of its stations' workers, and that replaces the spec's flat `jobs`.

**Tick.** Fixed sub-step (0.25 s sim time *(default)*). Order: receiving emits → arms
pick/drop → belts advance → machines craft → shipping consumes. Items are discrete
counts on belt tiles. 48×36 = 1.7k tiles at 4 Hz is trivial for one floor.

**Coupling to the colony (the only seam into `CitySim`).**
- A site **with** a floor ignores its spec's flat inputs/outputs. Each colony tick the
  floor pulls raw items from `stock` at the receiving docks' throughput (clipped to what
  stock holds), and pushes shipped products to `stock` (clipped to `stockCap`, reporting what
  landed: see the ore-cap invariant in city-builder notes).
- A site **without** a floor keeps today's flat rate, so there is no regression and old
  saves load unchanged.
- Floor power draw and job demand feed the colony's existing power and staffing sums, and
  the colony throttle scales the floor's sub-step speed (brownout = slow factory).

**Off-screen = measured steady state** *(default)*. Running every floor at full fidelity
forever doesn't scale with dozens of factories. When the floor editor is closed, the floor
switches to **aggregate mode**: per-second in/out rates measured over the last N simulated
minutes of detailed running, and re-measured after any edit (run ~5 min of sim headless
on a worker isolate). That is the same answer Factorio's production stats would show, and
it costs nothing per frame.

**Templates.** Every factory spec ships a default layout whose measured rate equals the
spec's current flat rate (±5%). That's the regression test, and it gives new players a
floor that already works. "Reset to template" is always available.

**Persistence.** `'factories': ?factoryFloors.toJson()` on `CitySim`, keyed by site id.
It is omitted when empty, following the `war` / `trails` pattern. Lot rename and drop go
through the existing `_carryRenamedLots` / `_dropLostLots` / `clearParcel`.

## 4. UI

- `showCitySiteMenu` gets a **"Factory floor"** action, shown when the spec is industrial
  (`TrafficRole.isIndustry` or a utility factory).
- `FactoryFloorScreen` is a 2D top-down grid editor (CustomPainter): a palette (machines,
  belts, arms, chests), place / rotate (R) / delete, drag-to-lay belts, and recipe pick on a
  machine.
- Overlays: power, staffing (red = unstaffed station), **bottleneck** (starved / blocked
  machines tinted), and a throughput readout ("1.8 steel/s in, 0.4 crates/s out").
- Live animation while open: items visibly ride belts. That's the fun.
- 3D interior / walking in with the first-person walker: **not planned**, a possible later phase.

## 5. Phases

1. **Floor core (headless).** Grid, belts, arms, machines, docks, recipes, tick,
   toJson. One template (`i-low` workshop: ore → steel crates). Tests: belt
   transport, arm handoff, machine starve/block, template throughput = spec rate,
   determinism, save round-trip. **Zero edits to existing files.**
2. **Editor screen.** `FactoryFloorScreen` + site-menu entry + overlays. A sandbox floor fed
   by an infinite receiving dock, so it is playable before integration. Real-input playtest.
3. **Colony integration.** One small commit into `city_sim.dart`: field, rename/drop/clear
   hooks, save key, one call in `advance`, flat-rate bypass. Coordinate timing with
   whoever is in `city_sim.dart` that day.
4. **Workers + automation tiers.** Station modes, maintenance, job demand into staffing,
   brownout slowdown, automation unlocked by milestone or research.
5. **Aggregate mode + templates for every factory spec.** Off-screen steady-state rates,
   worker-isolate re-measure, perf check with ~30 factories.
6. **Freight docks** *(after agent-traffic slice 8)*. Receiving only gets what trucks
   deliver, and shipping loads trucks. Dock count then becomes a real design limit.

## 6. Working in parallel

Phases 1-2 live entirely in new files (`factory/`, `FactoryFloorScreen`) plus one action
in `city_site_actions.dart`, so they can run alongside the traffic-laws / desire-paths
work without conflicts. Phase 3 is the only one that touches `city_sim.dart`, and it is
kept to one reviewable commit. Phase 6 waits on agent traffic and is owned jointly.

## 7. Decisions for the user

Defaults are marked *(default)* above. Each of these changes what gets built:

1. **Which buildings get floors?** *Rec:* all `ind` zoned tiers + utility factories
   (refinery, steelmill, electronics, rocket/gun/missile/rations factories). The VAB and
   greenhouse come later.
2. **Discrete items on belts vs flow rates?** *Rec:* discrete. It is the Factorio feel,
   and it's cheap at this grid size.
3. **Off-screen fidelity:** measured steady state (rec) vs always-full sim.
4. **Workers:** abstract slots per station (rec for now) vs visible little workers walking
   the floor (pretty, phase 4+ polish).
5. **Grid size:** fixed per tier (rec) vs scaled to real site metres (a 900 m refinery would
   be enormous).
6. **Is design ever required?** *Rec:* never. A templated floor matches today's output, and
   a designed one can beat it (and the upside is the reason to bother).
7. **Intermediates internal-only** (rec) vs new colony commodities you can stockpile/trade.

## 8. Phase 1 spec

Files (all new, license header on each):
- `factory/factory_grid.dart`: `TilePos`, `Dir4`, occupancy map, footprint place/remove
  with collision.
- `factory/factory_item.dart`: item ids (internal intermediates + crate kinds), map
  to `Commodity` for dock in/out.
- `factory/factory_recipe.dart`: `FactoryRecipe`, `StationKind`, const recipe table
  (ore→iron plate, plate→steel, steel→crate).
- `factory/factory_entities.dart`: `Machine`, `Belt`, `Arm`, `Chest`, `DockPort`.
- `factory/factory_floor.dart`: `FactoryFloor` (grid + entities + `step(dt)` +
  counters `inPerS` / `outPerS`), and `toJson` / `fromJson`.
- `factory/factory_templates.dart`: `templateFor(CityBuildingSpec)`, workshop only.
- `test/colony/factory/`: one test file per behaviour listed in phase 1.

Exit criteria: `flutter test test/colony/factory` is green; the workshop template's measured
rate is within 5% of `i-low`'s 0.3 ore → 0.2 steel/s; and no existing file is modified.
