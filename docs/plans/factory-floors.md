# Factory floors

Status: waves 0-3 BUILT on dev 2026-10-13 (phases 1-6 integrated; phase 7 freight waits on agent traffic). Draft 2026-10-12. Short on purpose: vision, model, phases, decisions.
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
- **Grid is to real scale** (user decision, 2026-10-12). Tiles are 2 m *(default)*: a pallet
  is ~1.2 m, so a forklift aisle is 2 tiles (4 m) and a person is 1 tile. The **hall** is
  the building's rectangle inside the site: by default the site envelope minus the yard
  (`site_access` `SiteEnvelope` / `fitFootprint`). The player can resize the hall walls within the
  envelope, and **build cost scales with hall area**, so a compact layout pays.
  - Scale check: a 200×150 m hall = 100×75 = 7.5k tiles. The whole 1100×800 m steel mill
    site would be 220k tiles, so the grid is stored **sparse** (only occupied tiles), and
    belts and machines tick only where they exist.
  - Pathing at this size: handlers use a coarse aisle/nav graph plus cached flow fields
    per busy target, not raw per-trip A*.
  - Specs without real site sizes (electronics, rocket parts, arms, missile and rations
    factories default to 24 m × footprint) need realistic `siteWidthM/siteDepthM` added in
    `city_building_spec.dart`. That file isn't one the other agent is in.
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

**Intermediates are real goods, made in place or shipped** (user decision, 2026-10-12).
Plates, wire, circuits, frames and the like can be made inside the plant that uses them, *or*
shipped out and received elsewhere, whichever makes more sense for the layout.
- Any item can go out through a shipping dock (packed as a crate or pallet), and any item
  can be accepted at a receiving dock. So a plant can specialise: a plate line ships plates,
  and another plant receives plates and skips smelting.
- Destination: a **warehouse or shipping hub** (`warehouse`, `freightyard`, the
  `goodsStoreTypes` set). Until agent-traffic slice 8 that's the colony `stock`, teleport
  style like every other good. After slice 8, trucks haul them.
- Intermediates join `commodity.dart`'s existing **COMPONENTS** section, so the stock UI
  groups them and `stockCap` / warehouse `storageBonus` bound them like everything else.
  A new intermediate only appears in the stock list once something has made it.
- Phase 1 defines intermediates in `factory_item.dart` with commodity-style string ids.
  They are registered into `commodity.dart` in phase 3 (integration), which keeps phase 1
  to zero edits of existing files.
- Reward cap with cross-plant flows: the 1.5× is measured per plant against its template
  on **raw-input-equivalent** value, so splitting a chain across plants can't stack caps.

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
  *(Built, phase 4: the Steel Mill's ore arrives on a dock conveyor — two pallets a second
  by hand and forklift would cost ~16 more jobs — and is charged as that upgrade in
  `factory_capex.dart`; forklifts clear the steel crates and a crane per line lifts the
  billets. Rules: `factory_vehicles.dart`.)*

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

**Design before building** (user decision, 2026-10-12). A floor design is a
**`FloorBlueprint`**: a hall size plus entity layout, with no site attached. It can be made:
- from the build menu, before placing (pick the plant, then "Design floor"), with the hall
  bounds taken from that spec's default site;
- by saving a live floor ("Save as blueprint") into a per-colony blueprint library;
- by starting from the template (every template is just a built-in blueprint).

When the plant is placed, the player picks a blueprint (default: the template), and it is
stamped onto the site's envelope. If it doesn't fit (a smaller lot), the placement preview
shows that before the click. Today placed plants appear instantly. A real construction phase
(floor contents build over time, at a cost scaled by area + machines + vehicles) is a
natural follow-on but touches `city_sim.dart`, so it belongs to phase 3 or later.

**Persistence.** `'factories': ?factoryFloors.toJson()` on `CitySim`, keyed by site id.
It is omitted when empty, following the `war` / `trails` pattern. Lot rename and drop go
through the existing `_carryRenamedLots` / `_dropLostLots` / `clearParcel`.
Demolishing a plant that has a designed floor asks for confirmation first, since the floor is
lost. *(As built: a road edit whose re-plat leaves a placed plant's lot no successor drops it
too, without asking; a designed floor lost that way raises a notice naming it. Refusing such
an edit in the road tool's trial is the road tool owner's call.)*

**Ownership and money** (raised by the user, 2026-10-12: *"if they are private corps,
they must still be able to make money and afford the labor, logistics, materials"*).

*Today:* the treasury (`funds`) earns only worker tax, the Wealth Tax law and milestone
grants. Buildings are paid in **ore**, workers get **no wages**, and goods have **no
prices**. `Economy` (capitalism / freeMarket / socialism / communism) is just multipliers.
Nothing is a firm, and nothing can go bankrupt.

*Model (proposal):*
- **Owner per plant**: `state` or `private(firmId)`. The default follows `Economy`:
  communism = all state; socialism = state by default, private allowed; capitalism /
  freeMarket = private by default, state allowed. Nationalise and privatise are site actions,
  gated by economy type and possibly laws.
- **The floor already measures cost.** The sim counts what a period of operation used:
  worker-hours by role, energy, inputs consumed, item-metres hauled, equipment hours.
  Pricing those counters gives a **unit cost** per output. A better layout really is cheaper
  per unit, so the design reward and the money side are the same lever.
- **Prices are local and derived, not set by hand** *(proposal, 2026-10-12)*. Each colony
  is its own market: `price = clamp(localUnitCost × scarcity, exportFloor, importCeiling)`.
  - *localUnitCost* = materials at local prices + energy × local power cost + labour ×
    local wage + plant wear, all ÷ output × site multipliers. The inputs that make it
    local already exist: `biomeFx.water/ore`, `solarFactor`, the body's gas inventory
    (terraforming).
  - *importCeiling* = min over sources (source price + transport/kg × kg/unit).
    Transport/kg comes from physics: surface-to-surface Δv → rocket equation →
    propellant/kg at the source's fuel price + vehicle wear. Earth's gravity well dominates.
  - *exportFloor* = best (destination price − transport).
  - *Wage* = local cost of the subsistence basket (O₂, water, food) + housing × an economy
    markup (as built: the markup only applies above subsistence; on the whole basket it
    pushed labour's share past one on dry Mars/Moon biomes). It is circular with
    life-support prices, so solve by fixed-point iteration (it converges while labour's
    share of the basket is below one: every real Mars/Moon biome except the volcano).
  - Needs a `kgPerUnit` per commodity (none today).
  - Expected result: low value-per-kg goods (O₂, water, steel, food) are always made
    locally off Earth, and high value-per-kg goods (chips, medicine) are imported until
    local plants exist. Factories exist to replace imports. Example, O₂: Earth ~$0.2/kg;
    Mars at the ice caps ~$5-10; Mars dry equator ~$20-50; imported from Earth ~$500-5,000.
  - Aside: the O₂ Harvester's flat 2.0 output should key off the body's real atmosphere.
  - This pricing reaches far beyond factories, so it gets its own short economy plan
    before phase 5.
- **Private P&L per plant**: revenue = shipped units × price. Costs = inputs × price + wages
  + power + logistics (a flat per-unit freight fee until trucks, then per truck trip) +
  equipment upkeep and depreciation. Profit is taxed into `funds` (a new corporate tax line
  in the Budget drawer). The existing Industrial Subsidy and Robot Tax laws act on it.
- **When a firm struggles**: it cuts handlers first, then idles stations, then closes. A
  closed plant is offered to the state (nationalise) or sold to a new firm. With cash and a
  short payback, it automates instead: real firms buy forklifts when labour is dear.
- **State plants** have no profit test; their P&L is shown for information. Whether their
  running deficit is charged to `funds` is an open question (§7).

This is a new economic layer, bigger than factories (it implies wages and prices
colony-wide). It gets its **own phase after integration**, and probably its own short plan.
Phase 1 only adds the cost counters, so it isn't blocked.

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
   toJson, `FloorBlueprint` + stamp-to-site, sparse 2 m grid, plus **workers on foot**: move requests, dispatcher, grid pathing. (Without
   them the docks can't unload.) One template (Steel Mill: ore → steel + tubes crates). Tests: belt
   transport, arm handoff, machine starve/block, template throughput = spec rate,
   determinism, save round-trip. **Zero edits to existing files.**
2. **Editor screen.** `FactoryFloorScreen` + site-menu entry + overlays + blueprint
   library and "Design floor" from the build menu (pre-placement). A sandbox floor fed
   by an infinite receiving dock, so it is playable before integration. Real-input playtest.
3. **Colony integration.** One small commit into `city_sim.dart`: field, rename/drop/clear
   hooks, save key, one call in `advance`, flat-rate bypass. Coordinate timing with
   whoever is in `city_sim.dart` that day.
4. **Vehicles + automation tiers.** Load classes, pallet jacks, forklifts (aisles,
   charging), overhead crane bays, AGVs; station modes and maintenance; job demand into
   staffing; brownout slowdown; automation unlocked by milestone or research.
5. **Ownership + P&L.** Owner per plant, prices, wages, private P&L, corporate tax, firm
   distress (layoffs → idle → close → nationalise/sell), and a state-plant deficit if chosen.
   Follows the economy plan.
6. **Aggregate mode + templates for every factory spec.** Off-screen steady-state rates,
   worker-isolate re-measure, perf check with ~30 factories.
7. **Freight docks** *(after agent-traffic slice 8)*. Receiving only gets what trucks
   deliver, and shipping loads trucks. Dock count then becomes a real design limit.

## 6. Working in parallel

Phases 1-2 live entirely in new files (`factory/`, `FactoryFloorScreen`) plus one action
in `city_site_actions.dart`, so they can run alongside the traffic-laws / desire-paths
work without conflicts. Phase 3 is the only one that touches `city_sim.dart`, and it is
kept to one reviewable commit. Phase 6 waits on agent traffic and is owned jointly.

### Waves (user go-ahead 2026-10-12: build waves 0-3, then confirm)

- **Wave 0, interfaces** (serial, done). `factory/`: `factory_grid`, `factory_item`,
  `factory_recipe`, `factory_handling`, `factory_entities` (layout `Placement`),
  `floor_blueprint`, `factory_ledger`, `factory_colony_port` (`FactoryColonyPort` plus
  `InfiniteColonyPort` / `StockColonyPort`), `factory_sim_api` (`FactorySim` view, editor,
  step and `MeasuredRates`). `economy/economy_contracts.dart`.
- **Wave 1, in parallel.**
  - A: floor core and on-foot handlers (phase 1).
  - B: editor against a fake `FactorySim` (phase 2).
  - C: economy domain: prices, wages, Δv transport, `kgPerUnit`, P&L, firm policy (phase 5
    domain).
  - D: measurement harness and real site sizes (phase 6 part).
- **Wave 2.** Vehicles and automation on top of A (phase 4), then templates for every
  plant; editor wired to the real floor plus the vehicle palette.
- **Wave 3, single integration.** A `CitySim` port, corporate tax and deficit lines,
  site menu, commodity registration and the save key, then tuning and a real-input
  playtest.

## 7. Decisions for the user

Defaults are marked *(default)* above. Each of these changes what gets built:

1. ~~Which buildings get floors?~~ **Decided:** player-placed plants only, never zoned.
   Engagement is optional and rewarded.
2. ~~Discrete vs flow?~~ **Decided:** discrete items.
3. ~~Off-screen fidelity?~~ **Decided:** measured steady state.
4. ~~Workers: abstract slots vs visible?~~ **Decided:** workers are simulated handlers who
   move freight on foot or with jacks, forklifts and cranes. Full automation is a rare,
   expensive upgrade.
5. ~~Grid size?~~ **Decided:** real scale (2 m tiles, sparse), hall sized within the site
   envelope, and floors can be designed as blueprints before the plant is built.
6. ~~Is design ever required?~~ **Decided:** never (see 1).
7. ~~Intermediates?~~ **Decided:** made in place or shipped to a warehouse / shipping hub
   and received by other plants; they're COMPONENTS-section commodities.

2 and 3 were accepted at the defaults (discrete items; measured steady state off-screen),
along with the inline numbers (2 m tile, 0.25 s step, 1.5× cap, ±5% template, 1 lane).
Phase 1 is not blocked by anything below.

**Money** (decided 2026-10-12, all at the recommendations)

8. ~~How far does money go?~~ **Shadow prices first.** Firms keep a P&L at local market
   prices. The only real money that moves is corporate tax into `funds` and subsidies out.
   Full circulation is a separate, later economy plan.
9. ~~Who designs a private plant?~~ **The player designs any floor.** A private firm builds
   only the parts with a payback under ~5 game-years. The rest needs a subsidy or a state
   contract. A state plant builds whatever the treasury (ore) covers.
10. ~~State plant losses?~~ **Charged to `funds`** as an "industry deficit" Budget line.
11. ~~Failure?~~ Layoffs → idle stations → **close**, then an offer to nationalise or sell
    to a new firm.

Nothing is open. Phase 1 is ready. The economy plan (pricing, wages, transport,
`kgPerUnit`) is written before phase 5.

## 8. Phase 1 spec

Files (all new, license header on each):
- `factory/factory_grid.dart`: `TilePos`, `Dir4`, sparse occupancy map (2 m tiles),
  footprint place/remove with collision, hall bounds.
- `factory/floor_blueprint.dart`: `FloorBlueprint` (hall size + layout, no site),
  `fitsEnvelope`, `stampOnto(site)`; the toJson the library will use.
- `factory/factory_item.dart`: item ids (internal intermediates + crate kinds), map
  to `Commodity` for dock in/out.
- `factory/factory_recipe.dart`: `FactoryRecipe`, `StationKind`, const recipe table
  (ore→iron, iron→steel, iron + slag→tubes, product→crate).
- `factory/factory_entities.dart`: `Machine`, `Belt`, `Arm`, `Chest`, `DockPort`.
- `factory/factory_handling.dart`: `MoveRequest`, `Handler` (on-foot kind only in phase 1,
  but the kind enum is shaped for jack/forklift/crane/AGV), `Dispatcher`, and grid A*.
- `factory/factory_floor.dart`: `FactoryFloor` (grid + entities + `step(dt)` +
  counters `inPerS` / `outPerS`), and `toJson` / `fromJson`.
- `factory/factory_ledger.dart`: per-period cost counters (worker-hours by role,
  energy, inputs consumed, item-metres hauled, equipment hours, outputs shipped). No
  prices; phase 5 multiplies by them.
- `factory/factory_templates.dart`: `factoryTemplateFor(CityBuildingSpec)`, Steel Mill
  only; null for everything else, including all zoned specs.
- `test/colony/factory/`: one test file per behaviour listed in phase 1, plus: a truck
  load is unloaded by workers into staging, belts block pathing except at crossings, and
  dispatch is deterministic, and a plate-only floor ships plates that a second floor
  receives and turns into steel (cross-plant intermediates).

Exit criteria: `flutter test test/colony/factory` is green; the Steel Mill template's measured
rate is within 5% of the Steel Mill's 2 ore → 1.5 steel + 0.4 tubes/s; a hand-tuned test
layout beats the template (proving there's a reward to chase) but stays under the 1.5× cap;
and no existing file is modified.

## 9. As built (2026-10-13)

- **Wave 0** contracts d1a4a9f. **Wave 1**: floor core, editor, economy domain and measurement, merged
  2132234. **Wave 2**: vehicles and automation 376f98c, seven plant templates and the real-floor
  editor 98f9013. **Wave 3**: colony integration b4a53ca..8d699aa.
- **Templates are seeded, not measured.** An untouched plant runs on its spec's flat rate, so placing
  one changes nothing. Only designed floors are measured, off-thread, with `measureSettingsFor`.
- **The 1.5× reward cap is enforced in `CityFactoryPort`** on output value, using Earth prices.
- **The editor opens as an overlay inside the live view** (`drivesSim:false`). The colony keeps
  ticking and drives the open floor; there is exactly one driver.
- **Economy.** Shadow prices are solved once per colony day. Firms book P&L, corporate tax goes to
  `funds` via `kCreditsToFunds`, state losses go to `industryDeficitRate`, and firm offers appear in
  the HUD.
- **Open items:**
  1. A real-input playtest is still owed. The 2026-10-13 run was dev-hook driven because the
     Windows screensaver blocked synthetic input.
  2. A dark blob is drawn at the Steel Mill's charging bay in the live view at default zoom; it isn't
     there offscreen.
  3. Rocket Parts and Missile corporate tax is large relative to worker tax (a balance flag).
  4. Off-world Steel Mill, Refinery and Rations margins are about 0.1-0.3%.
  5. A road edit that drops a designed floor only posts a notice.
  6. Firm offers show in the flight view only while the editor overlay is open.

## 10. Playtest feedback backlog (user, 2026-10-25; GO given 2026-10-25, after dynamic markets)

From the user's own run of the Rocket Parts tutorial (`main_factory_tutorial.dart`):

1. **Placement arrows don't read.** The ghost shows facing as a bare line. Add an arrowhead. An
   arm's ghost tints its "takes from" tile and its "drops into" tile.
2. **Tutorial steps 5 and 6 are unclear** about getting parts out of the assembler. Rewrite them
   as explicit arm-and-belt placement first, with the pallet jack introduced later as the
   alternative.
3. **Docks are oddly sized, and can be placed mid-hall.** There is no wall rule anywhere. A dock
   becomes a door on an outer wall facing out: a 4 m door, a 4×6 m loading area inside, the truck
   drawn outside. The ghost snaps to the wall, and placement elsewhere is refused.
4. **Docks feed constantly. Replace this with ordering, like the spaceport.**
   - Inbound: one-off or recurring orders ("weekdays 06:00, 2 truckloads of tubes"), arriving
     after a lead time and unloaded by handlers. A dock conveyor is a paid upgrade.
   - Outbound: scheduled pickups, or a truck called when N pallets are ready.
5. **Calendar, shifts, time off.**
   - 1st, 2nd and 3rd shifts, weekdays and weekends, a crew per shift, a pay premium for 2nd and
     3rd shift, staggered vacations and holidays.
   - Automated stations run off-hours (the case for automation).
   - Speeds 1/4/16/60×, "Skip to next shift", and an "Auto-skip off-hours" setting.
   - Open: the clock scale (real-time floor vs compressed), and how shifts map to the colony's
     120 s day.
6. **Electronics vs Electronics Crate is confusing.**
   - With ordering, you order goods and trucks bring them packed. Pallets are broken down in the
     dock area, by hand or by an unpacker, so packs stop being a dock choice.
   - Meanwhile, give the picker clearer names ("loose, hand-carried" / "×10 crate, pallet"), mark
     which machines use each item, and warn when nothing uses a dock's item.
7. **Shift+R rotates counter-clockwise**, for the ghost and for rotating a placed item.
8. **Redraw over belts to redirect them.** Belt tiles along a drag take the new direction, items on
   them are kept, crossings keep their walkway, anything that isn't a belt still blocks, and the
   ghost tints the redirected tiles.
9. **Area delete.**
   - Drag a rectangle with the Delete tool. Floor markings are kept unless Shift is held.
   - A red preview with counts. Held goods become floor piles.
   - Ctrl+Z undo. Open: undo for area deletes only, or for every edit.
10. **Belt placement modes:** Straight (axis-locked), L-shape (one corner, a key flips it) and
    Freeform. A toggle by the tool, Shift forces Straight while dragging, and the same modes apply
    to aisles.
11. **The outside world isn't unlimited.**
    - Suppliers have finite stock, a refill rate, a price, a lead time and a truck size.
    - Customers have contracts with delivery windows, plus a spot market.
    - In a colony, these are the colony's own stock and plants plus spaceport imports (via dynamic
      markets later).
    - **Toggleable:** an "Unlimited supply" sandbox switch, and the goal tracker marks runs that
      used it.

12. **Hover-delete hotkey.** Separate from select + Del. Hover anything and press the delete
    key (e.g. X) to remove what is under the cursor, with no tool switch and no selection. Holding
    the key while sweeping the mouse deletes along the path. Undo still applies.
13. **Construction crews, Prison Architect style.**
    - Placing a machine (or belt, dock, rack) does not make it appear. It posts a CONSTRUCTION job:
      a crew brings the materials (the item's capex, carried like freight) and works for a build
      time, then it switches on.
    - Removing posts a DISMANTLE job: a crew takes it down over time and carries back the salvage.
    - Crews are handlers with a builder role, hired like the rest; the job queue is visible.
14. **Blueprint planning mode.**
    - A separate mode with a literal blueprint look: blue background, white lines.
    - Lay out a floor there and SIMULATE it (the sandbox floor, no cost) before building for
      real.
    - "Build this plan" turns the difference between the plan and the live floor into
      construction and dismantle jobs for the crews.
15. **The product tree is too strong for the game.** Keep the full tree as a DEBUG tool (dev
    entry and a debug flag only). In game, the player sees either the raw materials an item needs
    in total, or its DIRECT components (one level). Never the whole chain.

16. **Searchable pickers.** Every item and recipe picker (arm filter, dock item, chest item,
    machine recipe, palette) gets type-to-search, as the product tree's picker already does.

17. **Clean up items off the floor.** Floor piles (left by deletes, re-routed loads, removed
    targets) should never be permanent clutter:
    - a "Clear" area order: drag a box and handlers haul every pile in it to the nearest chest,
      staging area or shipping dock, posted as ordinary move requests and shown in the queue;
    - a "Dispose" option for unwanted goods: hauled to a shipping dock and shipped out (or
      scrapped for nothing in the sandbox);
    - piles that nothing can take (no store with room) are flagged on the floor and in the
      readout, not silently stuck.
18. **See what items ARE.**
    - Hovering a belt tile, pile, chest, dock, machine or handler shows a tooltip with the items
      it holds (name, count, load class).
    - At closer zooms belt items and piles draw a small icon or short label, not just a coloured
      square.
    - A legend lists every item colour currently on the floor.

**Defaults for the open questions** (2026-10-25; the user said go without picking, so these are
the recommendations; revisit if they object):

- **Clock:** the floor runs in REAL time (8 h shifts), with speeds 1/4/16/60×, skip to next shift
  and auto-skip. In a colony, shifts map onto thirds of the colony's 120 s day until the colony
  clock is revisited.
- **Undo:** covers EVERY floor edit (Ctrl+Z / Ctrl+Y). It restores structure, not goods dropped as
  piles.
- **Docks:** a 4 m door with a 4×6 m loading area inside and the truck outside. Handlers unload
  trucks; a dock conveyor is a paid upgrade.

**Built (2026-10-25): items 1, 2, 6 (picker part), 7, 8, 9, 10.**

- Keys: R / Shift+R rotate cw / ccw; Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo (also header arrows);
  M cycles the run shape (Straight → L → Free, chips under Belt / Aisle); F flips the L; Shift held
  forces Straight mid-drag and adds floor markings to a Delete-tool box. None fire in a text field.
- Contract (`FactoryFloorEditor`, all additive): `rotate(id, {ccw})`, `setDir(id, dir)` (redirect
  keeping items), and `restore` on `place` / `setMode` / `hire`, which undo uses to skip the unlock
  gate (never a layout rule), so a young colony can undo deleting a template's assisted stations.
- Undo (`floor_edit_history.dart`) covers every edit, grouped per player action, and replays through
  the editor surface with history-local handles (floor ids are reused). It restores structure, not
  goods: piles stay piles. The colony's capex is a blueprint diff at close, so edit + undo costs 0.
- Picker names are derived (`FactoryItem.pickerLabel`): "Electronics (loose · hand)" vs
  "Electronics ×10 (crate · pallet)", used items listed first with "· used here", and a receiving
  dock nothing consumes gets a warning chip (inspector) and an amber mark (floor).
