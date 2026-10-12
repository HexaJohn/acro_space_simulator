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
ships with a working default layout, so nobody *has* to design one. **Players who do engage
are rewarded**: a designed floor can beat the template on output, jobs or power (§3 Reward).

**Only player-placed buildings get floors** (user decision, 2026-10-12). Zoned industry
grows, levels up and is torn down without the player's say, so a hand-built floor there
could vanish under them. Placed plants are permanent, deliberate and have a clear job
("make steel"), so they're worth designing.

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
- **Candidates:** placed utility plants only: refinery, steelmill, electronics,
  rocketfactory, gun/missile/rations factories (`kUtilCatalog` ~386-446), later VAB and
  greenhousefactory. Zoned `i-low/med/high` are out (user decision). Mine/Quarry are pits
  with no processing, so they're out too. Placed buildings live in `parcelBuildings`
  (`placeOnParcel` ~5136) or `utils` (grid), and only the player removes them.
- **Reusable pieces:** `forward_base.dart` / `base_modules.dart` (modules with crew,
  power share and work queue, toJson per module). `site_access` `SiteProgram.yard` already
  places a truck apron and loading bays on industrial lots, which tells us which wall the
  docks face. Inspector entry: `showCitySiteMenu` (`city_site_actions.dart:309`).

## 3. Core model

New package `lib/domain/colony/city/factory/`. It is pure Dart with no Flutter and no RNG,
and is deterministic.

**`FactoryFloor`**, one per site id, created when the floor is first opened or by template.
- Grid of `w × h` tiles, set per spec, not by metres *(default)*: small plants
  (rations, electronics) 24×18, mid (steelmill, refinery, arms) 36×27, big
  (rocket parts, missiles) 48×36.
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
sum of its station workers and its material handlers (below), and that replaces the spec's
flat `jobs`.

**Material handling: people and vehicles move freight** (user decision, 2026-10-12).
Belts and arms cover the short fixed runs, but most freight is moved by **handlers**, as in
real plants: unloading trucks, staging, feeding machines, clearing output, palletising and
loading. A fully lights-out plant is possible but rare and expensive.
- **Load classes.** Each item has one: *hand* (boxes, parts), *pallet* (ore sacks, crates,
  coils of wire) or *heavy* (steel billets, rocket sections). The class decides which
  handlers can move the item.
- **Handlers.** Each is a worker, either on foot or operating equipment:

  | Handler | Moves | Speed | Needs |
  |---|---|---|---|
  | Worker on foot | hand, 1 unit | slow | any walkable tile |
  | Pallet jack | ≤ pallet, 1 pallet | slow | 1-tile aisle |
  | Forklift | ≤ pallet, 1 pallet, can stack racks | fast | 2-tile aisle, charging bay |
  | Overhead crane | any incl. heavy | medium | a fixed rail bay (rectangle); ignores floor traffic |
  | AGV / robot carrier *(late tech)* | ≤ pallet | medium | no operator, marked lanes, power, maintenance |

- **Jobs, not routes.** Machines, docks and chests post **move requests** ("3 ore to
  smelter #2 input", "clear 1 crate from packer"). A deterministic dispatcher assigns each
  request to the nearest free capable handler, with ties broken by id. Handlers path on the
  grid (A* on ≤48×36, cached per target).
- **Space is the cost.** Belts and machines block walking unless a crossing is placed.
  Forklift aisles eat floor. Crane bays fix where heavy stations go. So a layout trades
  floor area for handling capacity, which is exactly the kind of puzzle we want.
- **Docks are manual by default.** Trucks are unloaded by workers, jacks or forklifts into
  a staging area. Dock conveyors and AGVs are the expensive automated upgrade.
- **Template plants** use workers and forklifts at the docks, belts through the core, and a
  crane over the heavy line. They're a realistic mix, and the design levers in Reward
  apply to handling too (fewer trips, shorter aisles, a crane instead of two forklifts).

**Tick.** Fixed sub-step (0.25 s sim time *(default)*). Order: receiving emits → requests
posted → dispatcher assigns → handlers move/pick/drop → arms pick/drop → belts advance →
machines craft → shipping consumes. Items are discrete counts on belt tiles and in handler
loads. 1.7k tiles plus ≤ ~40 handlers at 4 Hz is trivial for one floor.

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

**Reward (why engage).** The template is deliberately "fine, not great". Levers a
designer can pull, all bounded:
- *Throughput*: better ratios and fewer starved machines raise output above the template,
  up to the receiving docks' throughput and the plant's power budget.
- *Labour*: automating stations, or handling smarter (cranes, short aisles, belts where
  trips are frequent), frees workers for the rest of the colony.
- *Efficiency*: byproduct loops (slag → tubes and the like) mean less raw input per product.
Target: a good design gets ~1.5× template output, or the same output at half the jobs.
The cap stops one perfect floor from breaking the colony economy.

**Templates.** Every factory spec ships a default layout whose measured rate equals the
spec's current flat rate (±5%). That's the regression test, and it gives new players a
floor that already works. "Reset to template" is always available.

**Persistence.** `'factories': ?factoryFloors.toJson()` on `CitySim`, keyed by site id.
It is omitted when empty, following the `war` / `trails` pattern. Lot rename and drop go
through the existing `_carryRenamedLots` / `_dropLostLots` / `clearParcel`.
Demolishing a plant that has a designed floor asks for confirmation first, since the floor is
lost. Because only the player demolishes placed plants, that's the only path that loses a floor.

## 4. UI

- `showCitySiteMenu` gets a **"Factory floor"** action, shown only for a placed plant
  whose spec has a factory template (`factoryTemplateFor(spec) != null`, so zoned lots never
  qualify).
- `FactoryFloorScreen` is a 2D top-down grid editor (CustomPainter): a palette (machines,
  belts, arms, chests, aisles, crossings, crane bays, racks), place / rotate (R) / delete,
  drag-to-lay belts and aisles, recipe pick on a machine, and a handler roster (hire a
  worker, buy a jack, forklift or AGV).
- Overlays: power, staffing (red = unstaffed station), **bottleneck** (starved / blocked
  machines tinted), and a throughput readout ("1.8 steel/s in, 0.4 crates/s out").
- Overlay for handling: a heat map of handler traffic, plus the queue of move requests
  waiting (a long queue = hire or automate).
- Live animation while open: items ride belts, and workers and forklifts run their trips.
  That's the fun.
- 3D interior / walking in with the first-person walker: **not planned**, a possible later phase.

## 5. Phases

1. **Floor core (headless).** Grid, belts, arms, machines, docks, recipes, tick,
   toJson, plus **workers on foot**: move requests, dispatcher, grid pathing. (Without
   them the docks can't unload.) One template (Steel Mill: ore → steel + tubes crates). Tests: belt
   transport, arm handoff, machine starve/block, template throughput = spec rate,
   determinism, save round-trip. **Zero edits to existing files.**
2. **Editor screen.** `FactoryFloorScreen` + site-menu entry + overlays. A sandbox floor fed
   by an infinite receiving dock, so it is playable before integration. Real-input playtest.
3. **Colony integration.** One small commit into `city_sim.dart`: field, rename/drop/clear
   hooks, save key, one call in `advance`, flat-rate bypass. Coordinate timing with
   whoever is in `city_sim.dart` that day.
4. **Vehicles + automation tiers.** Load classes, pallet jacks, forklifts (aisles,
   charging), overhead crane bays, AGVs; station modes and maintenance; job demand into
   staffing; brownout slowdown; automation unlocked by milestone or research.
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

1. ~~Which buildings get floors?~~ **Decided:** player-placed plants only, never zoned.
   Engagement is optional and rewarded.
2. **Discrete items on belts vs flow rates?** *Rec:* discrete. It is the Factorio feel,
   and it's cheap at this grid size.
3. **Off-screen fidelity:** measured steady state (rec) vs always-full sim.
4. ~~Workers: abstract slots vs visible?~~ **Decided:** workers are simulated handlers who
   move freight on foot or with jacks, forklifts and cranes. Full automation is a rare,
   expensive upgrade.
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
  (ore→iron, iron→steel, iron + slag→tubes, product→crate).
- `factory/factory_entities.dart`: `Machine`, `Belt`, `Arm`, `Chest`, `DockPort`.
- `factory/factory_handling.dart`: `MoveRequest`, `Handler` (on-foot kind only in phase 1,
  but the kind enum is shaped for jack/forklift/crane/AGV), `Dispatcher`, and grid A*.
- `factory/factory_floor.dart`: `FactoryFloor` (grid + entities + `step(dt)` +
  counters `inPerS` / `outPerS`), and `toJson` / `fromJson`.
- `factory/factory_templates.dart`: `factoryTemplateFor(CityBuildingSpec)`, Steel Mill
  only; null for everything else, including all zoned specs.
- `test/colony/factory/`: one test file per behaviour listed in phase 1, plus: a truck
  load is unloaded by workers into staging, belts block pathing except at crossings, and
  dispatch is deterministic.

Exit criteria: `flutter test test/colony/factory` is green; the Steel Mill template's measured
rate is within 5% of the Steel Mill's 2 ore → 1.5 steel + 0.4 tubes/s; a hand-tuned test
layout beats the template (proving there's a reward to chase) but stays under the 1.5× cap;
and no existing file is modified.
