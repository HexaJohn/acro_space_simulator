# Agent-based traffic (Cities: Skylines style) — design

Status: design, revision 4, branch feat/agent-traffic, 2026-09-15

This document is self-contained, with one exception: parking in sites (driveways, car parks, access roads) follows the road side's `docs/plans/site-access.md`, whose §7 is the contract (D49). An implementer needs only these and the code.

- **Baseline.** Every E-hook (§1.2), and every line cited in a file that changed after `62a3a55`, is cited against `dev` at **`c672eb3`** (revision 3). Its last two commits touch no file this document cites, so every anchor reads the same at `721e585`.
  - Revision 2's baseline, `62a3a55`, had added the road agent's directed `RoadGraph` (road_graph.dart) and its routed traffic model (`CityTrafficModel` and `CityRoadTraffic`, road_traffic_model.dart). It wired that model into `CitySim.advance`, added road noise and land value, and gave the tiles and the graph one junction warrant (`junctionPlanForNetwork`).
  - Since then dev has added the traffic readout seam (`CityTrafficReadout`, f66e0d8 and 38e05fe), fire reach and real deliveries (1d2e78d, e608e35), a graph that clusters ends by the layout's level rule and plans junctions over drawn legs (229cb9c to 50c8b4e), lost lots torn down on a re-plat (08f8cf3), and the road tool's editor (ec9e5e9, b7e62e7).
  - Those commits rewrite `road_graph.dart`, `road_traffic_model.dart`, `simulation_view_colony.dart`, `city_edit_overlay.dart` and `city_tile_bucketing.dart`. They move lines in `city_sim.dart` (by up to 33 past line 3345), `city_layout.dart`, `parcel.dart`, `road_junction.dart`, `road_mesher.dart`, `city_tile_mesher.dart`, `city_traffic.dart`, `city_nodes.dart`, `simulation_view.dart`, `city_game_hud.dart`, `sim_view_control.dart`, `main_city_game_dev.dart` and `tool/drive_city_game.dart`.
  - Files dev has not touched since `62a3a55` read the same at both. Among them: `road_catalog.dart`, `road_elevation.dart`, `spatial_index.dart`, `city_building_spec.dart`, `city_generator.dart`, `city_starter_kit.dart`, `world_snapshot.dart`, `vehicle_meshes.dart` and `scene_sync.dart`.
  - The worktree branch holds this design (`5476ca9`) and slices 1a and 1b (`f634f4b`, `4b114f8`) on dev's `cf36b49`, 24 commits behind `c672eb3`. **It is rebased onto `dev` again before slice 1 merges.**
- **Lineage of the design.** The skeleton is the panel's "integration" design. Grafts come from the "fidelity" and "scale" designs, and every fatal flaw the judges listed has been fixed. §0.3 records each decision with a one-line reason. Revision 2 answers a critic's review and the landing of the road agent's routed model. Revision 3 follows dev to `c672eb3`: the traffic readout seam, fire and delivery reach, the graph's level rule and drawn-leg plans, and the landed road tool. Revision 4 adopts the road side's site-access contract (site networks, stall parking, home back-outs) and splits slice 4 into T4a and T4b. The **Revision log** at the end lists every change.
- **Paths.** `lib/` and `test/` are the repo's own. "The road agent" is the other agent working on road placement on `dev`.

---

## 0. Summary

### 0.1 The architecture in fifteen lines

1. A new pure-Dart package, `lib/domain/colony/city/traffic/`, holds the whole simulation behind one facade, `CityAgents`. `CitySim` owns one, as `CitySim.agents`. The names `traffic` (the grid's per-cell map) and `roadTraffic` (the road agent's routed model, city_sim.dart:3343) are already taken.
2. **One tick hook, one readout.** In agent colonies, `CitySim.advance` calls `agents.advance(dt)` right after the road agent's `roadTraffic.advance(dt)` (city_sim.dart:1675). Everything that reads traffic reads `CitySim.trafficReadout` (3352), which E37 points at the agents' `CityTrafficReadout`, so `advanceParcelTraffic()` (1677) stays as it is and takes their measured congestion. In slice 1 the agents answer congestion, volumes and routes, and forward reach, noise, land value and the tax factor to the routed model. From slice 2 they answer everything, and `roadTraffic.advance` no longer runs in agent colonies (§12.3, D46). Every other `CitySim` edit is a guarded one- or two-line hook (§1.2).
3. **The lane graph is derived from the road agent's `RoadGraph`** (`CitySim.roadGraph`, city_sim.dart:3344).
   - We use their nodes (road ends clustered in plan and by the layout's grade-separation rule), pieces, directed edges, junction plans (read over the legs the tiles draw) and lot access as they are, and add lanes, connectors, conflicts and stub sinks. Alleys and paths still route; outside the plan, they give way to the drawn legs (D48).
   - We rebuild when the `RoadGraph` object changes. That happens on `roadsRevision`, which moves with every road edit and every junction override. A graph that was only patched (overrides or road names) needs a refresh of node controls, nothing more.
4. **Routing happens at spawn only.** It is an edge-based A* whose cost is seconds:
   - length ÷ limit × road-type weight;
   - plus junction and turn penalties;
   - plus each directed edge's **measured delay at plan time**. That delay is measured against the vehicle's own free-flow time and the expected control delay, and published every 2 s.
5. **The lane on every edge is locked at plan time**, stored as a connector list in an `Int32List` route arena. There are two planners:
   - A new trip leaving an access point may choose its start lane. It uses edge A* plus a lane pass.
   - A plan that starts in a lane the vehicle already occupies (a re-plan, a parking leg) uses an A* over (edge, lane) states. That search expands only real connectors.
6. **Lanes change only at nodes**: through turn connectors, lane drops and adds, and adjacent-lane straight connectors at real junctions. The one other place is the access point where a car joins or leaves the road. For new trips the connector rules are lane-feasible by construction.
7. **Routes never change for traffic.**
   - A network edit (a road, a junction override, a stub, a bus or rail line or stop) remaps live routes through road-split lineage. Only a remap that fails ("route impossible") triggers a re-plan. So trips already planned drive straight through a new road's junction.
   - A destination demolished mid-trip changes nothing en route. The vehicle finds out on arrival, and a new appended leg is planned then.
8. Vehicles move with IDM car-following on a fixed 0.2 s sub-step, fed by an **integer-microsecond** accumulator.
   - Junction entry follows the network's own warrant (`RoadNode.plan`) plus the rest of §5.
   - The simulation owns the signal clock.
   - Vehicles never block the box.
   - Stuck vehicles despawn after 120 s, but never while dwelling or waiting for a re-plan.
9. **Citizens** are records with a home, a job and a car. They realise the `population` scalar through immigration, emigration and death budgets. Trips come from an activity wheel.
10. **Buildings** hold garbage, corpse, crime, mail, fire and sickness accumulators. A service counts only when its dispatched vehicle arrives.
    - Depots are chosen by straight-line distance, as in CS1, so a badly placed depot floods its district.
    - `wasteBacklog`, `corpses`, `crime` and the safety and health coverage scalars are **derived** from the accumulators and the deliveries, so the HUD and happiness keep working.
    - Under the police flag, every passive safety source is retired.
11. **Parking and pedestrians.** Parking is searched on arrival: a binding reservation, then circling, then giving up. Pedestrians walk the pavements and cross on the walk phase.
12. **Other modes and the map edge.**
    - Outside connections are position-keyed stubs, each with its own virtual edge to its own sink. Their flows are defined one by one: visitors in; residents' out-of-town errands and emigrants out; imports and exports; through traffic.
    - A City Builder colony is founded with two trunk spurs that end in stubs.
    - Bus lines are drawn by the player. Their stops are keyed by position and heading.
    - Rail and the L become agents in slice 9b.
    - Mode choice picks walk, car, bus or rail.
13. **What the renderer receives.** It sees only `WorldSnapshot.cityTraffic`. Agent columns `(elem, s, v, a, lat)` are published per sub-step in a triple buffer, stamped with the agent clock.
14. **How agents are drawn.** Poses go onto per-edge geometry sliced from the **same capture's** `RoadSnapshot` points and `lifts`; the road agent already flips reversed roads on the wire. The domain publishes the agent kind plus an opaque variant byte, and the renderer maps them to meshes.
15. **Determinism, budgets and scheduling.**
    - Everything is seeded and web-safe; claims hold **per platform**.
    - Iteration is in integer-id order, and steady state allocates nothing.
    - Budgets are counted in node expansions, agent counts and sub-steps, never in wall-clock milliseconds.
    - A frame hold never runs more than 4 agent sub-steps in one UI frame. It replays whole world ticks later instead, so catch-up frames stay bounded and results stay deterministic.
    - Slices 1–10 run inline. Slice 11 adds a lock-step worker isolate and turns agents on in every ticking colony.

### 0.2 The user's binding decisions (not re-opened here)

1. **Congestion is read at spawn time** (CS2-like). Route cost includes each directed edge's **measured** delay when the trip is planned. Route and lanes are then locked. A trip re-plans only when a network edit makes its route impossible.
2. **Services are per building.**
   - Citizen records hold home, workplace and car.
   - Each building has its own garbage, corpse, crime and mail accumulators; sickness and fire are included here as well (§9).
   - A service is delivered only when its vehicle arrives. Radius and global coverage are retired for these services.
   - A Post Office is added.
3. **Every mode is in scope:**
   - player-drawn bus lines with stops, and buses as agents;
   - a walk, drive or bus choice per trip;
   - pedestrians on pavements;
   - a parking search at the destination.
4. **Outside connections.** Special highway stubs spawn and despawn inbound, outbound and through traffic (freight and cars). In the long term a stub becomes a highway to another colony.

### 0.3 Decision log: where the designs disagreed, and each fatal flaw fixed

| # | Topic | Decision | Reason |
|---|---|---|---|
| D1 | Base | Integration's structure, edit list and coordination contract | The only complete design, and the lowest merge risk |
| D2 | Facade name | `CitySim.agents` / `CityAgents` | `traffic` and `roadTraffic` are already taken on `CitySim` |
| D3 | Graph source and revision | The lane graph is **derived from `CitySim.roadGraph`**, the road agent's `RoadGraph`, and keyed on that object's identity. `CitySim.roadsRevision` (city_sim.dart:425) moves on every road mutation (`CityLayout.revision`, city_layout.dart:125; bumped at 171, 643, 800, 811, 882, 895, 910 and 1040) and on every junction override (city_sim.dart:4035). | One clustering of one network, so our routes, their fire reach and their delivery reach agree about what connects. No duplicate build, and no counter of our own. |
| D4 | Junction-override key | **Removed.** Overrides reach us through the graph's own node plans (`RoadGraph.withOverrides`). | `setJunctionOverride` already moves `roadsRevision` |
| D5 | Lane connectors | Interval-overlap turn bands; straight from every lane that has an aligned out-lane; turns that may land in any out-lane; median-aligned continuations; **adjacent-lane straight connectors at real junctions** (rule 5) | New trips are lane-feasible by construction, so there is no A* retry loop. Rule 5 is the spec's "change lanes at nodes". |
| D6 | Kerb lane at the destination | The last connector fixes it. The destination lane set is {kerb lane}, or {innermost lane} for a far-side driveway. Unchanged by site plans: applied per join, so each in-capable join has its own mask (§3.10). | There is no mid-segment "move to lane 0 for the last 60 m" |
| D7 | Far-side access | Exactly where `RoadGraph`'s lot access allows it (`lotDirs`, road_graph.dart:685-696): two-way roads with one lane each way. On two-way roads with two or more lanes each way, own side only. On one-way roads, either kerb, from the travel direction. Kerb **parking** is on the right kerb of travel, and on both kerbs of a one-way road. Unchanged by site plans: every join has `joinDirs == _dirsFor(road, side)`, and a join's role restricts in or out, never direction. | Our reachability must match the network's. Cars never cross a median or a four-lane road mid-block. |
| D8 | Sub-step | h = 0.2 s on an integer-µs accumulator | Half the 25× cost of 0.1 s, and any partition of dt gives an identical sub-step sequence |
| D9 | Degradation | None driven by wall-clock time. Shedding uses a vehicle cap, a path-queue cap and the frame hold (D35), all counted in agents, expansions or sub-steps. Deferred spawns wait at their origin. Milliseconds are only reported and fed to `FrameBudget`. | A time-driven ladder breaks determinism |
| D10 | Over-capacity trips | Deferred: the citizen waits at the origin. No "virtual" teleport trips. | Every trip is an individual entity |
| D11 | Congestion table | Each traversal reports a signed observation against **the vehicle's own free time and the expected control delay**. Observations feed an EMA, combined with the live queue beyond the first stopped vehicle of each lane. A new buffer is published every 2 s, and a search captures the buffer it started with. | An empty network publishes D ≈ 0, and control delay is not charged twice |
| D12 | Dispatch | Straight line × (1 + 0.1·inUse/fleet), as in CS1. A `dispatchByPathCost` knob defaults to off. Chaining within 600 m. A failed vehicle re-queues its request with the original stamp. A depot with no road to the target yields to the next depot, then the request backs off. | A badly placed depot floods its district by construction, and there are no per-depot Dijkstras |
| D13 | Service rates | Per-capita generation at **parity** (garbage totals 0.006/person/s, city_sim.dart:326). Fleet × capacity is sized so that throughput per reference cycle ≥ the depot's processing rate. Deathcare is the exception: its processing rates (0.8–5 bodies/s) never bind, so its fleets are sized to the death rate. A steady-state test pins both. | Parity keeps the difficulty curve; sizing the fleets removes the 10–100× throughput shortfall |
| D14 | Waste and corpses at depots | Per-depot buffers, processed at the spec rate × throttle. Owned specs skip the global production loop, and their pollution scales with the work they did. | The stock-cap sweep (city_sim.dart:1680-1684) would otherwise delete truck loads |
| D15 | `wasteBacklog` | Overdue garbage (above the request threshold) plus the sewage stock, over population × 2 | Same normaliser as today (1415-1419); sewage stays a pipe scalar |
| D16 | Population | `population` stays the field every reader reads. With agents owning it, migration and deaths become budgets realised as citizens. External writes are detected as deltas and turned into budgets. One-tick contract (§12). | Migration becomes visible and spatial, and no existing reader or writer breaks |
| D17 | Parking | Searched on arrival, in this order (revision 4, site-access §7.5): (1) the destination's own stalls, reserved at the arrival gate; (2) kerb slots ahead on the arrival edge within 60 m, skipping slots masked by `KerbCuts.blocked`; (3) adjacent edges within 800 m; (4) circling, with step 1 retried only if the loop ends on an in-capable join's edge; (5) giving up after the third circle, and the car is garaged. Every found stall or slot is reserved and **the reservation is binding**. Other sites' lots are never searched. On a home driveway the car parks nose-in and leaves by backing out into the street on a gap; car parks, yards and installations are left forward through their throats (§7.5). | The spec asks to *find* a spot; reserving at plan time hides that, and a binding reservation leaves no race |
| D18 | Frame timing | Published per sub-step and stamped with the agent clock. The renderer keeps its own agent clock, advanced by wall time × a measured rate. That clock pauses only when the host's warp is 0 (`SceneSync.simWarp`), never merely because a frame ran no tick. | Removes the 10 Hz stutter and the epoch-quantisation stutter |
| D19 | Render geometry | Per-edge polylines are **sliced from the same capture's `RoadSnapshot.points`**, which the road agent already flips for reversed roads (world_snapshot.dart:2134-2158). They are cached per (graph object, `groundCacheStamp`). There is no second drape. Unchanged for roads; site poses (D49) are placed on the plan's own points, never sliced from a road. | Cars sit exactly on the paint, with zero extra ground reads |
| D20 | Height | Deck roads use `RoadSnapshot.lifts`; draped roads with bridges use the cosmetic pass's bridge-lift term (city_traffic.dart:257). Both add the ribbon lift. Unchanged for roads; site poses use `CitySiteFrame` heights (`ptUp`, `stallUp`; site-access §5.2), their own source, never a re-drape. | One height reference per road, never counted twice |
| D21 | Worker isolate | Slice 11, lock-step. `cityClockHeldS` holds the economy's dt until the worker confirms. A free-run mode exists for development only and is declared non-deterministic. | A late reply would otherwise feed stale state or stall ambiguously |
| D22 | Tools and overlays | Our own `TrafficToolController` and `TrafficOverlayState`. No edits to `city_edit_overlay.dart`, the `road_tool_*.dart` files, `road_mesher.dart`, `road_overlay_state.dart` or `road_overlay_nodes.dart`. The road agent's Routes view reads `CitySim.trafficReadout`, so in an agent colony it draws the agents' routes; ours is the lane-speed view and the route inspector (C8, resolved). | Those files are the road agent's, and one question gets one answer: their view asks the readout, and the agents answer it |
| D23 | Baked signal lamps | A coordination request (C3). Until it lands, lamps are drawn twice. The baked ones switch only by epoch parity at mesh time (road_mesher.dart:1431-1435). | We don't edit the mesher |
| D24 | Exposure | In slices 1–10, agents are enabled only for City Builder colonies, through `CityStarterKit.found(agentTraffic: true)`. **Slice 11 turns them on in every ticking colony**, behind the topology audit and the perf gates. The enabled flag persists from slice 1 (E15/E16), and the lot-rename hooks land in slice 1 (E12–E14). | "Re-plan only when impossible" must hold the first time the player draws a road or saves, and the spec rules out an abstract flow number anywhere |
| D25 | Outside sinks | One virtual 2,000 m edge pair per stub, with a U-turn at its own sink. The sink sits at `stub.at + heading × 2000 m`. No shared sink. | A shared sink would let through trips bypass the town; a sink position keeps the heuristic admissible |
| D26 | Bus-line legs | **Routed once at line creation, remapped on every graph revision, and a leg is re-routed only when its remap fails.** Stops re-resolve each revision: an edge within 8 m, heading within 45°, stop on the right-hand side. | Lines follow the same locked-route rule as cars |
| D27 | RNG and maths | xoshiro128**, which multiplies only by 5 and 9 and so is exact on web. `fnv1a32` uses a split 32-bit multiply. No `exp`, `log` or trigonometry in the sub-step; lookup tables instead (`sqrt` is correctly rounded everywhere). Determinism is claimed **per platform**. Unchanged by site networks: the site mover's sub-step maths (site-lane IDM, stall manoeuvres, the home back-out arc) follows the same rules, and the road side's plan generation uses no trigonometry either (site-access C-11). | Web-safe and honest |
| D28 | Stuck despawn | 120 s of agent time (a knob), accrued only while driving. The timer is frozen while dwelling, and while held for a queued re-plan. | A colony day is `dayLengthSec` (120 s on an Earth-like body, city_sim.dart:1150); a fire engine on scene is not stuck |
| D29 | `city_traffic_test.dart` | Not retired | The cosmetic pass still serves the studio, which never ticks, and non-agent colonies until slice 11 |
| D30 | Save schema | `GameStateCodec.schemaVersion` stays **1** (game_state_codec.dart:35). The new `'agents'` key is additive and has its own `v`. | The city JSON is nested |
| D31 | `FrameBudget` | Fed the tick cost from slice 1 (scene_sync.dart:354-355), **only while an agent colony ticks** | The flight view is otherwise blind to inline agent work, and other modes keep today's behaviour |
| D32 | Baked parked cars | Two knobs control them. `CityNodes.onStreetParking` governs kerb cars and the parked-car ceiling governs lot cars. Both are read only when a tile request is built (city_nodes.dart:612-624), and neither is in the base-tile key; the detail layer's key does include them (city_detail_layer.dart:200). So both are set **before the first tile request** of an agent colony, and a mid-session enable calls `invalidate()` once. | Flipping them later would leave baked cars under live ones |
| D33 | Staffing | Slice 1: `commuteEff` comes from measured trips (E4), so the published congestion and staffing move together. Slice 10: per-building presence. | No slice changes staffing silently |
| D34 | Fixed-start plans | Re-plans, and appended legs that begin in the lane the vehicle already occupies, run an A* over (edge, lane) states that expands only real connectors. New trips keep edge A* plus the lane pass. | A fixed lane can make an edge sequence lane-infeasible; the state search never returns an undrivable route |
| D35 | Frame hold | When the host sets `frameBudgeted`, at most `maxAgentSubStepsPerFrame = 4` agent sub-steps run per UI frame. Further world ticks are queued **whole** and replayed in order on later frames, with economy and agents advancing together. | A 25-tick catch-up frame would otherwise run about 62 sub-steps (≈ 50 ms); replaying whole ticks keeps the `advance` sequence identical |
| D36 | What may change a plan | Only network edits: roads, junction overrides, stubs, and bus or rail lines and stops. A destination demolished mid-trip, or one whose access an edit moved, is found on arrival and handled by an appended leg (§3.9, counted as `appendedLegs`, not `replans`). A delayed bus never changes a rider's plan. A site-plan change re-plans only the site legs of cars in or bound for that site, and their road routes stay locked (snap, relocate, garage, limbo, `siteRetarget`: site-access §7.6). | Decision 1 and the spec, verbatim |
| D37 | Safety and crime | Under the police flag every passive safety term is retired: the Police Station's, Emergency Services' and the military specs'. `services['safety'] = policeCoverage × pop`, from answered calls. The crime target comes from per-building crime (E35). | Decision 2 retires global coverage for crime |
| D38 | Stub flows | Visitors come in on a schedule. Out-of-town errands and emigrants go out as they arise. Trucks in and out are exactly the §10.2 imports and exports. Through traffic is scheduled per stub pair and does not scale with population. | Every inbound vehicle has a destination building and every outbound one an origin building |
| D39 | Starter spurs | An agent City Builder colony is founded with two trunk spurs to enabled stubs (E17, slice 8) | Otherwise no player sees traffic from the map edge |
| D40 | Rail and the L | In scope, as slice 9b: trains as agents on rail edges, stations as stops, rail in mode choice. Freight rail sits behind a knob. | Decision 3: every mode is in scope |
| D41 | Mail and goods | A direct happiness drag (E34), not a leisure rewrite | `serviceCoverage` takes the minimum of clamped ratios (city_sim.dart:2820-2829), which hides both |
| D42 | Layering | The domain publishes `AgentKind` plus an opaque variant byte; the `VehicleKind` mapping is the renderer's | The domain may not import infrastructure (source_hygiene_test.dart:183-190) |
| D43 | Beside the routed model | **Superseded by D46 (revision 3).** Was: the agents own congestion, commute, safety, health and fire, and the routed model keeps noise, land value and delivery reach until a volume seam lands (C7). | The two models must never both write one scalar. D46 keeps that rule and needs no seam. |
| D44 | Tapers | No lane cut. A tapered end keeps its lanes, and the drop or add happens at the seam's continuation connectors. Rendering scales lanes laterally over the taper. | A cut at the taper could leave an edge with no lane at all |
| D45 | Where agents are drawn | A `part` file of `city_nodes.dart` with its own slots, run outside the cosmetic `traffic` toggle. The cosmetic road-car cap is zeroed in `_syncTraffic`'s cascade, before `begin`. | Four one-line hunks in a shared file, and no rewrite of its `place` closure |
| D46 | The readout seam | `CityAgents.readout` is an `AgentTrafficReadout implements CityTrafficReadout` (traffic_readout.dart:49-105), and E37 makes `CitySim.trafficReadout` return it in agent colonies. **Slice 1:** the agents answer `hasRun`, `peakCongestion`, `averageCongestion`, `congestionOf` and `volumeOf` (measured from speeds and flows), `routesThrough` (live vehicles' locked routes) and `passes`. `serviceReach`, `fireReach`, `deliveryReach`, `noiseOf`, `landValueOf`, `averageLandValue` and `taxLandValueFactor` are forwarded to `city.roadTraffic`, which keeps advancing. **Slice 2:** the agents answer all of them, and `roadTraffic.advance` is skipped in agent colonies (E3a). `advanceParcelTraffic` is kept unchanged. | Every consumer already reads the seam (the tax line, the delivery and noise gates, `advanceParcelTraffic`, lot fires, the road tool's Routes view), so none changes, and each question has exactly one answerer |
| D47 | The readout's contract | Answers are the last **complete** picture. Before one they punish nothing: `hasRun` false, congestion 0, every lot reached, noise 0, a tax factor of exactly 1. The agents take a picture at every congestion epoch from the first, whether or not anything has driven (an empty picture is no congestion and no routes), so a colony with no traffic yet is never left "still being counted". `passes` starts at the routed model's own count, never goes back, and moves whenever any answer may have changed. `fireReach` counts only stations with safety cover (`TrafficRole.fightsFires`, road_traffic_model.dart:149-152), so a clinic's ambulance is no fire cover. `deliveryReach` never counts a lot's own goods, its own lorries turning at the next node included. | The road agent's rules (traffic_readout.dart:15-17, 54-57 and 77-91; 1d2e78d, e608e35, 38e05fe), and their views key what they drew on `passes` |
| D48 | Graph levels and junction plans | We take `RoadGraph`'s clustering as it is. Ends meet by `CityLayout.levelsSeparated`: two decks meet unless 4.5 m or more apart, and a deck meets the ground unless it is on piers or in a tunnel there. A node's plan is read over its **drawn** legs (`RoadClass.joinsJunctions`), with `stopLegs` numbered back into the full leg list. The arbiter reads `RoadNode.plan` as it is. A leg outside the plan (an alley or a path) gives way to every drawn leg; no second plan is computed. | The graph joins what the layout cut and the tiles drew (229cb9c), so a stop the player sees is a stop the agents make, and an alley stays a kerb cut |
| D49 | Site networks | Driveways, car parks and access roads are **not** in the `LaneGraph`, which stays roads only. **Plans are the road side's:** `SiteAccessPlan` views over `SiteAccessChunk`s, immutable after publish and replaced copy-on-write (site-access §2.3, §4.1); traffic never generates, edits or re-derives site geometry. **Traffic owns** a per-site network (site lanes, stall bitmaps, binding reservations, `stallOrder[j]`, next hops) and a site mover (IDM on site lanes, turnarounds, stall manoeuvres, `sharedSingle` claims, the home back-out of §7.5). Both are rebuilt on `sitesRev`, never on `graphRev`. A vehicle crosses between road and site **only at a join**, as a logged ENTER or EXIT access event (§5.5). The book's sync runs inside `CitySim.advance` before `roadTraffic.advance` and `agents.advance`, so a plan made this tick is seen by agents this tick and the frame hold (D35) replays it with the tick. Site vehicles count against `maxVehicles`; parked cars do not. | Plans never move `roadsRevision` (site-access S1), so a site change cannot rebuild the lane graph or remap a locked route, and one generator is the only source of site geometry for renderer and agents alike |

**Revision 4 (site access).** `docs/plans/site-access.md` is the parking contract for sites, and its §7 is binding on this document (D49; §3.10, §7, §13.1, §14.1, §18). Its three amendments that needed our ack are **acked**:
- **C-5:** the generation seed is position-free (program version, frame W and D at 0.5 m, road class, spec type), not a hash of the site id.
- **C-19:** stall indices are stable only per plan `rev`, so traffic keys reservations and saves by `stallKey` and remaps indices on every `rev` change.
- **C-20:** the plan's `joins[0]` comes **from** `RoadGraph` join slot 0 (slot → plan), not the other way round.

The user decided site-access §10.2 on 2026-09-15: every recommendation is accepted except Q3, which is changed so that home-driveway cars back out into the street (§7.5). The schedule is road R0–R4 now, and traffic slice 2 → T4a → slice 3 → T4b (§18).

---

## 1. Module map

### 1.1 New files

- **Domain** files are pure Dart. They import no `flutter`, `application`, `adapters` or `infrastructure` code (the rule is enforced by test/tools/source_hygiene_test.dart:183-200).
- **Every** new `.dart` file starts with the exact 4-line PolyForm header (source_hygiene_test.dart:108-113).
- The directory `D` below is `lib/domain/colony/city/traffic/`.

| Path | Layer | Responsibility |
|---|---|---|
| `D/traffic_rng.dart` | domain | `TrafficRng` (xoshiro128** on four `Uint32` words; `nextU32`, `nextInt(n)`, `nextUnit()`, `fork(salt)`, `toJson`/`fromJson`); `fnv1a32(String)`; `mul32(a,b)` |
| `D/traffic_time.dart` | domain | `AgentClock` (integer µs, `timeUs`, `accumUs`); `kStepUs = 200000`; µs↔s helpers; lookup tables `Lut.expNeg`, `Lut.gumbel` |
| `D/traffic_tuning.dart` | domain | `AgentTuning`: every tunable constant as a static with a default. Only simulation-invariant values that twin runs share. |
| `D/agent_kind.dart` | domain | Append-only enums. `AgentKind` declares every kind in slice 1: car, truck, semi, bus, garbageTruck, hearse, policeCar, ambulance, fireEngine, mailVan, deliveryVan, train, lTrain, freightTrain. The others: `CitizenState`, `ServiceKind`, `TripPurpose`, `TravelMode`, `NodeControlKind`. |
| `D/slot_pool.dart` | domain | `SlotPool`: `Int32List` free list plus `Uint16List` generations; `handle = gen << 20 \| slot` (always < 2³¹) |
| `D/lane_graph.dart` | domain | `LaneGraph`: immutable structure-of-arrays edges (one per `RoadGraph` edge, then the stub sinks), lanes, connectors, conflicts and node kinds, with compressed-row adjacency; query helpers |
| `D/lane_graph_builder.dart` | domain | `LaneGraphBuilder.build(RoadGraph, stubs, …)`: node kinds from `RoadNode.plan`, lanes, connectors, conflicts, stop back-offs, stub sink edges; a control-only refresh for a patched graph. Resumable by phase for large networks. |
| `D/lane_connectors.dart` | domain | The connector rule set (§3.5) and connector geometry (lengths, curvature caps, conflicts) |
| `D/node_control.dart` | domain | `NodeControl`; `SignalPlan` (phases, integer-µs clock, `stateAt`); the mapping from `RoadNode.plan` to `NodeControlKind` |
| `D/network_key.dart` | domain | `TrafficNetKey(graph, stubsRev, stopsRev)`: the `RoadGraph` object, compared with `identical`, plus our two counters |
| `D/graph_lineage.dart` | domain | `EdgeLineage` and `RouteRemapper`. Holds the *old* `RoadGraph` for exactly one rebuild. |
| `D/access_points.dart` | domain | Building and site access from `RoadGraph` (`lotPiece`, `lotS` and `lotDirs`; `attachFootprint` for grid sites), the lot's side, destination lane sets. From T4a, per join of the site's plan (`ofJoin`, side from `joinRight`; §3.10). |
| `D/edge_delay.dart` | domain | `EdgeDelayTable`: signed observations, EMA, live queue, per-edge 60 s flow counters, and a pool of three published epoch buffers |
| `D/route_arena.dart` | domain | `RouteArena`: an `Int32List` with power-of-two size-class free lists |
| `D/path_search.dart` | domain | `SearchContext` (a resumable edge-based A* with a typed heap and generation-stamped scratch) and `PathQueue` (a FIFO budgeted in expansions, with a separate lane for service, transit and freight requests) |
| `D/lane_planner.dart` | domain | Free-start plans: backward feasibility sets plus a cost dynamic programme that gives one locked lane per edge. Also the sticky span repair used by remaps. |
| `D/lane_state_search.dart` | domain | Fixed-start plans: a resumable A* over (edge, lane) states whose transitions are the connectors |
| `D/zone_skims.dart` | domain | Zone-to-zone car, walk and transit skims for mode choice and job matching, fed through the path budget |
| `D/vehicle_table.dart` | domain | `VehicleTable` columns and per-element ordered occupancy lists |
| `D/vehicle_mover.dart` | domain | IDM integration, hand-over between elements, stuck detection |
| `D/junction_arbiter.dart` | domain | Entry rules for every control, opposing-left gaps, don't-block-the-box, forced priority, the wedge breaker, pedestrian yield |
| `D/building_table.dart` | domain | `BuildingTable`: site id ↔ int, spec, capacities, access, accumulators, requests; the rename and clear hooks |
| `D/citizen_table.dart` | domain | `CitizenTable` (itinerary columns included) and the activity wheel |
| `D/population_ledger.dart` | domain | Immigration, emigration, death and external budgets, and how they are realised |
| `D/trip_planner.dart` | domain | Activities → trips; mode choice; spawn caps and deferral; `CommuteSynth` (slices 1–2 only) |
| `D/parking.dart` | domain | `ParkingTable` (kerb slots and lot capacity), `ParkedCarTable`, the arrival search |
| `D/pedestrian_graph.dart` | domain | Pavement, tube and crossing graph derived from the lane graph |
| `D/pedestrian_table.dart` | domain | Pedestrian columns and the walking mover |
| `D/service_calibration.dart` | domain | The single table of generation rates, thresholds, capacities and fleets (§9.2), plus the reference-cycle formula |
| `D/service_dispatch.dart` | domain | Requests, the depot table, CS1 dispatch with the no-route fallback, multi-stop legs, unloading, depot processing, the lot-fire step (E11) |
| `D/freight.dart` | domain | Goods buffers, freight trips, import/export ledger |
| `D/outside_connection.dart` | domain | `OutsideConnection` stubs, their resolution, sink edges, the visitor table, the visitor and through schedules |
| `D/transit.dart` | domain | `TransitStop`, `TransitLine`, line routes, buses, stop queues, boarding, and the itinerary tables (stop-to-stop rides, transfer lists) |
| `D/rail_graph.dart` | domain | Slice 9b: the rail network, built from `isRail` roads (the `RoadGraph` leaves rail out) with the same plan-and-height clustering rule; blocks; stations |
| `D/rail_transit.dart` | domain | Slice 9b: rail and L lines, trains, block signalling, station queues; optional freight rail |
| `D/agent_frame.dart` | domain | `AgentFrame` and `PedFrame` columns, the triple-buffer `AgentFrameBuilder`, `TrafficNetColumns` (heads, stops, stubs per revision) |
| `D/traffic_stats.dart` | domain | Rolling statistics read by `CitySim`, the HUD and the development hooks |
| `D/agent_traffic_readout.dart` | domain | `AgentTrafficReadout implements CityTrafficReadout` (traffic_readout.dart:49-105; D46, D47): measured congestion and volumes, live routes as `TripRoute`s, and `passes`. In slice 1 it forwards reach, noise, land value and the tax factor to `city.roadTraffic`. From slice 2 it answers them from `agent_reach.dart` and a noise pass on `RoadNoiseSampler` (road_noise.dart:110-136). |
| `D/agent_reach.dart` | domain | Slice 2: the reach fields behind the readout. Bounded multi-source searches over directed edges: from every station that sends vehicles (service), from stations with safety cover only (fire), and from goods sources, never the lot's own (delivery). |
| `D/traffic_metrics.dart` | domain | Wall-clock timings for **reporting only**. The only traffic file allowed to use `Stopwatch`. |
| `D/agents_codec.dart` | domain | `toJson` / `restore` for the `'agents'` save block |
| `D/city_agents.dart` | domain | The `CityAgents` facade. Holds `advance`, the frame hold (`holdTick`, `endFrame`), the edit and rename hooks, `ownsSpec`, `serves`, the derived scalars, `readout` (the colony's `CityTrafficReadout`, D46) and `describe(handle)`. Its constructor allocates nothing; the tables are built when `enabled` turns on. |
| `D/agent_scheduler.dart`, `D/agent_scheduler_sync.dart`, `D/agent_scheduler_isolate.dart` | domain | Slice 11: the scheduler seam, chosen by conditional import on `dart.library.isolate`, following mesh_scheduler.dart:24-31 |
| `lib/application/snapshot/city_traffic_frame.dart` | application | `CityTrafficFrame` and `TrafficGeometry` (the wire types) |
| `lib/application/snapshot/traffic_capture.dart` | application | `TrafficCapture.frameFor(city, bodyId, roads)`: per-edge geometry sliced from this colony's `RoadSnapshot`s in the same capture, cached per (graph object, `groundCacheStamp`) in an `Expando<CitySim>`; everything else passed by reference |
| `lib/infrastructure/flutter_scene/city/agent_traffic_pass.dart` | infrastructure | Pure pose maths: anchor-relative edge tables, the render agent clock, distance rings, the `AgentKind` → `VehicleKind` mapping |
| `lib/infrastructure/flutter_scene/city/agent_nodes.dart` | infrastructure | `part of 'city_nodes.dart'`: `_syncAgents` and `_syncAgentExtras`; the agent slot map (near slots cast shadows, far ones don't); high-water padding; signal heads, pedestrians, parked cars and overlays |
| `lib/infrastructure/flutter_scene/city/pedestrian_meshes.dart` | infrastructure | An instanceable pedestrian figure: two boxes, +Y forward, +Z up, scene units |
| `lib/infrastructure/flutter_scene/city/signal_head_layer.dart` | infrastructure | Live red, amber and green heads as three constant-count instanced meshes |
| `lib/infrastructure/flutter_scene/city/traffic_overlay_nodes.dart` | infrastructure | Traffic-view lane ribbons, the route-inspector ribbon, stop, station and stub markers, bus shelters at stops |
| `lib/infrastructure/flutter_scene/city/traffic_overlay_state.dart` | infrastructure | UI-only statics: view toggle, selected vehicle, route points, line-tool ghost. A sibling of `RoadOverlayState`, never that singleton. |
| `lib/infrastructure/flutter/screens/traffic_tools.dart` | infrastructure | `TrafficToolController` (a `ChangeNotifier`): the bus-line, rail-line and outside-connection tools, and the toolbar sub-row widget |
| `lib/infrastructure/flutter/screens/city_traffic_panels.dart` | infrastructure | Traffic, Services and Transit drawers; the vehicle inspector card; the extra rows on the site sheet |
| `test/traffic/**` | test | Fixtures, unit, property, scenario, determinism and benchmark tests (§17) |

### 1.2 Edits to existing files (all of them), cited against `dev` at `c672eb3`

"Risk" is the risk of a textual or semantic conflict with the road agent's work. Their work so far covers road build, upgrade and adjust; decks, decorations and names carried through splits and saves; the wire's road ids, lifts and reversed flip; the directed `RoadGraph` and routed traffic model wired into the tick; one junction warrant; the tile bucketing; the traffic readout seam; a graph that clusters by the layout's level rule and plans over drawn legs; and the road tool's editor, panel and input (ec9e5e9, b7e62e7). Still announced: the renderer's lamp pass.

| # | File : line | Edit | Why | Risk |
|---|---|---|---|---|
| E1 | — | **Removed in revision 2.** The graph keys on the `RoadGraph` object (D3); `spatial_index.dart` is untouched. | `roadsRevision` is live on dev | — |
| E2 | `city_sim.dart` after `parcelCongestion` (3335) | `late final CityAgents agents = CityAgents(this);` plus an import. The constructor allocates nothing. | Owner of the agent state | MED (beside their `roadTraffic` and `trafficReadout` block, 3337-3352) |
| E3a | `city_sim.dart:1675`, right after `roadTraffic.advance(dt);` | `if (agents.enabled) agents.advance(dt);`. **Slice 2:** line 1675 itself becomes `if (!agents.enabled) roadTraffic.advance(dt);`. | The tick hook. `advanceParcelTraffic()` (1677) is kept unchanged: it reads `trafficReadout` (4143-4148), which E37 points at the agents, so `parcelCongestion` takes their measured congestion by itself. From slice 2 the agents answer the whole readout (D46), and the routed model stops running in agent colonies. | MED (their 1675-1678 block) |
| E3b | `city_sim.dart:1176-1178`, first line of `advance` | `if (agents.holdTick(simDt)) return;` | The frame hold (D35, §5.7). Returns false unless a host has set `agents.frameBudgeted`. | LOW |
| E4 | `city_sim.dart:1244` | `final commuteEff = agents.enabled ? agents.stats.commuteEff : 1 - math.max(congestion, parcelCongestion) * 0.4;` | Staffing from measured trips from slice 1 (D33), with the same one-tick lag as today | LOW |
| E5 | `city_sim.dart`, after the medicine gate (1272) | `if (agents.enabled) agents.rewriteServices(services, population);` | Safety and health come from deliveries under their flags (§9.5) | LOW |
| E5b | `city_sim.dart:1538` and `405` | `funds += (taxIncomeRate + lawUpkeepRate - roadUpkeepRate + agents.fundsRate) * dt;` and `netFundsRate` gains `+ agents.fundsRate` (`fundsRate` is 0 when disabled) | Trade, fares, fleet and bus upkeep (slices 8–9); the budget readout's net rate agrees | MED (their road-upkeep term) |
| E6 | `city_sim.dart`, grid loop 1278-1291 and parcel loop 1297-1308 | First line of each loop body: `if (agents.ownsSpec(s)) { pollutionRate += s.pollution * agents.depotRun(s) * emissionCut * uf; continue; }`. `uf` is 1 in the grid loop. `depotRun(s)` is the previous tick's drained fraction of that spec's depots × throttle. | Depots process their own buffers (D14). Pollution scales with the work done, as `run` scales it today. | LOW |
| E7 | `city_sim.dart:1410-1423` | `if (agents.serves(ServiceKind.garbage)) { sewage-only injection; wasteBacklog = agents.wasteBacklog; } else { …as is… }` | Garbage comes from per-building accumulators (D15) | LOW |
| E8 | `city_sim.dart:1482-1490` | Under `agents.ownsPopulation`: `agents.ledger.addDeaths(died)` instead of writing `population` (1483). Under `agents.serves(deathcare)`: `corpses` is not incremented (1484) and `careRate` (1486-1490) is skipped. | Deaths are assigned to homes; corpses are derived | LOW |
| E9 | `city_sim.dart:1564-1576` | The migration arithmetic unchanged, into a local `next`; then `if (agents.ownsPopulation) agents.ledger.addMigration(next - population); else population = next;` | Population is realised by citizens (D16) | LOW |
| E10 | `city_sim.dart:1772` | First line of `transitBonus()`: `if (agents.serves(ServiceKind.transit)) return agents.transitBonus;` | Ridership (§11.6) | LOW |
| E11 | `city_sim.dart:4188`, in `advanceParcelFires` (4179) after the fire-disaster spark (4181-4187) and before `if (lotFires.isEmpty) return;` | `if (agents.serves(ServiceKind.fire)) { agents.advanceLotFires(dt); return; }`. The agents' step owns growth, engines on scene, burnout, spread (on `TrafficRng`) and the new ignition. | Engines must be on scene; lot fires become deterministic (§9.4) | MED (their `fireReach` factor, 4204, sits in the step it replaces) |
| E12 | `city_sim.dart:3515`, first line of `_carryRenamedLots` | `agents.onLotsRenamed(renamed);` | One line covers every road operation that renames lots: `commitRoad` (3503, only when it re-plats), `buildRoad` (3678), `upgradeRoad` (3783) and `moveRoadEnd` (4000). The helper then tears down whatever stood on a lot the re-plat gave up (`_dropLostLots`, called at 3533, body 3544-3554; 08f8cf3). The next building sync, immediate because the layout moved (§2.6), tombstones those buildings. | MED (their helper; one line) |
| E13 | `city_sim.dart:4702`, in `_carryLotsAcross` (4673), before its `_dropLostLots()` | `agents.onLotsRenamed(moved);`. The buildings `_dropLostLots` tears down are tombstoned by the next building sync. | Same | LOW |
| E14 | `city_sim.dart:4894` (`clearParcel`) | `agents.onLotCleared(parcelId);` | Evict residents, cancel requests, mark the building gone for trips arriving there | LOW |
| E15 | `city_sim.dart:4407` (`toJson`, after `'support'`, the last key) | `if (agents.hasState) 'agents': agents.toJson(),`. Slice 1 writes `{'v': 1, 'enabled': true}`; slice 3 adds the rest. | Persistence from slice 1 | MED (their `'roads'` and junction keys sit earlier in the same map) |
| E16 | `city_sim.dart:4580` (`fromJson`, after `sim.recompute()`, before `return sim`) | `sim.agents.restore(j['agents']);` | Persistence from slice 1 | LOW |
| E17 | `city_starter_kit.dart:153-259` | A `bool agentTraffic = false` parameter. When it is true: `sim.agents.enabled = true;`, and from slice 8 the two trunk spurs with enabled stubs (§10.4). Both happen before `claimMilestones()` (258). | Enables agents for City Builder only (D24, D39) | LOW |
| E18 | `lib/infrastructure/flutter/screens/city_game_screen.dart:76` | Pass `agentTraffic: true` | The play surface | LOW |
| E19 | `lib/application/snapshot/world_snapshot.dart` | Field `final List<CityTrafficFrame> cityTraffic` (default `const []`); constructor parameter (1916-1930); `copyWithEpoch` passes it (1939-1953); a local list beside `roads` (2001). After `roadsRevision[city.id] = city.roadsRevision;` (2219): `if (city.agents.enabled) cityTraffic.add(TrafficCapture.frameFor(city, body.id.value, roads));`. Passed in the return (2356-2378). `toJson` untouched. | The renderer's only input | HIGH file. No hunk inside their road loop (2071-2183) or junction loop (2188-2218). |
| E20 | `lib/infrastructure/flutter_scene/city/city_nodes.dart` | Four one-line hunks: (a) `part 'agent_nodes.dart';`; (b) in `_syncTraffic`'s cascade (2125-2129), `..maxVehicles = snap.cityTraffic.isEmpty ? _maxVehicles : 0` before `..begin(...)`; (c) after `_syncTraffic(...)` (1208), `_syncAgents(snap, origin, moved, focusWorld);`; (d) after `_syncRoadOverlay(...)` (1214), `_syncAgentExtras(snap, origin, moved);`. Both bodies live in our part file with their own slots (§13.8). | Draw agents; cosmetic road cars off in agent frames; cosmetic trains untouched | HIGH file; four one-line hunks, none in their tile or overlay code |
| E21 | `lib/infrastructure/flutter_scene/city/vehicle_meshes.dart:26-56` | **Append**, all at once in slice 5: `bus, garbageTruck, hearse, policeCar, ambulance, fireEngine, mailVan, deliveryVan`. `emit` covers them. Add a `liveryU` getter: 0.5 for the existing five, fixed per kind for the new ones. `road` and `airless` (54-55) are **unchanged**. | New models. The parked-car family picks (city_tile_mesher.dart:2398) index those lists, so they must not move. | LOW |
| E22 | `lib/domain/colony/city/city_building_spec.dart`, plus the massing and parking rule tables that test/architecture/installation_massing_test.dart and installation_parking_test.dart read | New specs: Post Office after Police Station (358), Fire Station after Emergency Services (496), Bus Depot and Cargo Terminal after Freight Yard (512). Massing and parking rules for the two site-claiming ones (§9.7). Regenerate `docs/REFERENCE.md` with `test/tools/gen_reference_test.dart` (C11). | New depots; specs persist by label | LOW-MED |
| E23 | `lib/domain/colony/city/commodity.dart` | `goods` constant, label, and the FINISHED GOODS section (the default of `section()`, 60-65) | Freight (slice 8) | LOW |
| E24 | `lib/infrastructure/flutter_scene/perf_knobs.dart:55` | Append the §15.4 knobs to `PerfKnobs.all` | A/B testing | LOW |
| E25 | `lib/main_city_game_dev.dart:69-76`, `100-145`, `206-224` | `agentTraffic: const bool.fromEnvironment('AGENTS', defaultValue: true)` in the founding call. New `ext.acro.citygame` parameters handled before the status return (124), after the existing `zones=`, `walk=` and `zone=` (103-123). An `agents` block in `_status`. Their `ext.acro.roadtool` (151-164) is not touched. | Headless verification | LOW |
| E26 | `lib/infrastructure/flutter/simulation_view.dart` | (a) After the tick loop (1950): `for (final c in _cities.all()) c.agents.endFrame();`, then `SceneSync.tickCostMs = anyAgentColony ? swSteps.elapsedMicroseconds / 1000.0 : 0;` and `SceneSync.simWarp = _clock.warpFactor;`. (b) Where the injected city is taken (initState): if it has agents, set `agents.frameBudgeted = true`, and from T4b (E36 stage 2) `CityNodes.onStreetParking = false; CityNodes.maxParkedCars = 0;` before the first frame. (c) `dispose` (2180+): restore those statics and reset the `TrafficOverlayState` statics. (d) **V** in `_simKeys` (1211-1242, where V is still free) and `_onKey`, for the traffic view. (e) `CityGameHud(...)` (3328) gets `trafficOn`/`onToggleTraffic` beside `zonesOn`/`onToggleZones` (3331-3332), and a `tools` argument. (f) The pick gate moved into the colony part, `_cityPickLayer()` (simulation_view_colony.dart:998-1047, placed at simulation_view.dart:3309). Its `open` predicate (1009-1010) becomes `adjust ? _adjustGateOpen(p) : c.active \|\| _trafficTools.active \|\| _siteUnder(p) != null \|\| _vehicleUnder(p) != null`, and `_PickClaim`'s `claim` (1015) and the tap routing (1028-1030) treat `_trafficTools.active` as they treat `c.active`. | The frame hold, budget visibility, baked cars off, the inspector | MED ((f) sits in their input code) |
| E27 | `lib/infrastructure/flutter/simulation_view_colony.dart` | `_editCityAt` (599): early `if (_trafficTools.active) { _trafficTools.tap(city, hit); return; }` after its ground pick (602-603) and before the road tool's branch (609-612). `_hoverCityAt` (120): the same for hover, after its ground pick. `_inspectCityAt` (672): try `_vehicleUnder` before the site sheet. Plus a new `_vehicleUnder(Offset)` helper in this `part` file. | Line and stub tools, and clicking a vehicle | HIGH (their road tool's input lives here now, and the file changed heavily since `62a3a55`). One early return each. Their tool UI has landed (C4), so nothing waits on it. |
| E28 | `lib/infrastructure/flutter_scene/scene_sync.dart:119`, `354-355` | `static double tickCostMs = 0; static double simWarp = 1;` and `+ tickCostMs` inside `frameBudget.feed(...)` | `FrameBudget` sees agent tick cost (D31); the render clock sees pauses (D18) | LOW |
| E29 | `lib/infrastructure/flutter/screens/city_game_hud.dart` | `CityGamePanel` (28, `{ none, milestones, budget }`) gains `traffic, services, transit`; `_drawer`'s two-way choice (398-400) becomes a `switch`; a Flow chip; a traffic toggle mirroring `zonesOn` (fields 35-36 and 49-50, button 162-166) | Panels | LOW-MED |
| E30 | `lib/infrastructure/flutter/screens/city_panels.dart:191-211` | The congestion row reads `sim.parcelCongestion` when `sim.agents.enabled` | The two readouts agree | LOW |
| E31 | `lib/domain/colony/city/city_generator.dart`, after the interstates are laid (1204-1253) | `if (city.agents.stubsEnabled) city.agents.stubs.markFreeEnds(...)` | Outside connections on generated colonies, in slice 11 when those colonies get agents | MED (their merge fixes sit near 1703-1718) |
| E32 | `lib/infrastructure/flutter/sim_view_control.dart:17-116` | `selectVehicle`, `setTrafficView`, `trafficTool` references beside their `roadTool` (88-94), and all three in `clear()` (96-115) | Development hooks | LOW |
| E33 | `tool/drive_city_game.dart:25-96` | Every bare argument of the form `key=value` is forwarded to `ext.acro.citygame` before the status call; `step=<s>` waits until the colony has advanced | Manual acceptance from the command line. The tool already replays a JSON list of extension calls (`--script=<steps.json>`, 10-17 and 73-85), which covers anything longer. | LOW |
| E34 | `city_sim.dart:1499-1506` (`socialDrag`) | `+ agents.happinessDrag`, which is 0 when disabled: `0.15·mailBacklog + 0.15·goodsShortage` | Mail and goods move happiness (D41) | LOW |
| E35 | `city_sim.dart:1826`, in `socialTick` after the curfew line | `if (agents.serves(ServiceKind.police)) crimeTarget = agents.crimeTarget;` | Crime from per-building accumulators (D37) | LOW |
| E36 | `city_nodes.dart:442` and `622` | `static const int _maxParkedCars = 400;` becomes `static int maxParkedCars = 400;`, and its one use follows. **Staged per site (revision 4).** Stage 1, T4a: traffic publishes the agent-managed site ordinals (destination lots with a live network plan), and `CitySiteFrame.agentManaged` makes the road side's R6 baking skip those sites. Stage 2, T4b, completes E36: `maxParkedCars = 0` and `onStreetParking = false` before the first tile request (E26 b). | Baked lot cars off in agent colonies (D32; T4a per site, T4b everywhere) | MED |
| E37 | `city_sim.dart:3352` | `CityTrafficReadout get trafficReadout => agents.enabled ? agents.readout : roadTraffic;` | The readout seam (D46). Every consumer already reads it: the tax line (1530), the delivery and noise gates (4113, 4125), `advanceParcelTraffic` (4143-4148), the lot-fire reach (4204), and the road tool's Routes view (road_tool_scene.dart:578-603; road_tool_panel.dart:510). | LOW (one line of theirs, written for this) |

**Untouched on purpose:** `road_mesher.dart`, `city_edit_overlay.dart`, `road_tool_controller.dart`, `road_tool_panel.dart`, `road_tool_scene.dart`, `road_overlay_state.dart`, `road_overlay_nodes.dart`, `city_layout.dart`, `parcel.dart`, `road_junction.dart`, `road_graph.dart`, `road_traffic_model.dart`, `road_noise.dart`, `traffic_readout.dart` (we implement it), `spatial_index.dart`, `city_traffic.dart`, `city_tile_mesher.dart`, `city_tile_bucketing.dart`, `city_tile_columns.dart`, and `test/flutter_scene/city_traffic_test.dart`.

### 1.3 Coordination contract with the road agent (post, and settle, before slice 1 merges)

- **C1. The graph is theirs.**
  - Our lane graph is derived from `CitySim.roadGraph`. That covers nodes, pieces, directed edges, legs, `RoadNode.plan`, lot access and `attachFootprint` for grid sites. We never cluster ends ourselves, so the two models cannot disagree about reachability.
  - We ask three things:
    - keep those arrays public, and keep their numbering stable within one graph object;
    - keep `sharesStructureWith` meaning "nothing routing reads has changed";
    - tell us before changing the clustering, attach or lot-access rules, because remaps and access points depend on them.
  - We add nothing to `road_graph.dart`. `node_control_test` also compares `RoadNode.plan` with what the tiles draw (`RoadMesher.junctionPlan` over `junctionsFromEnds`); any mismatch is reported to them, since both are theirs.
  - The clustering has changed once already (229cb9c to 50c8b4e: ends meet by `CityLayout.levelsSeparated`, and plans are read over drawn legs). §3.1, §3.2 and §3.7 follow it; D48 records how.
  - **Lot access = join slot 0 (revision 4).** The rule moves into `lib/domain/colony/city/site_access/site_join.dart` (`SiteJoinPlacer.primary`), the road side's R1, posted to us as a C1 notice with its commit hash (site-access §7.3).
    - `RoadGraph` publishes join slot columns: `lotJoinStart`, `joinPiece`, `joinS`, `joinDirs`, `joinRight`, `joinFlags`, `joinRoomM`, `joinKerbE/N`, `joinNormE/N`, `joinCrossStart` and `joinCrossLot` (site-access §2.2). They ride `withOverrides` and `refreshedFor`, so `sharesStructureWith` keeps its meaning.
    - `lotPiece`, `lotS` and `lotDirs` are always slot 0's, and `attachFootprint` is slot 0 of `attachFootprintJoins`. A site plan's `joins[0]` comes from slot 0 (C-20, acked).
    - We read a join's side from `joinRight`, never from the centroid. We still add nothing to `road_graph.dart`.
- **C2. Who writes what in an agent colony.**
  - **Agents:**
    - the traffic readout (E37, D46): congestion, volumes, routes and `passes` from slice 1; reach, noise, land value and the tax factor from slice 2;
    - `parcelCongestion`, through `advanceParcelTraffic`, unchanged, which reads the readout;
    - `commuteEff` (E4);
    - `services['safety']` and `services['health']` under their flags (E5);
    - `crime` under the police flag (E35);
    - fire under the fire flag (E11, which replaces the whole lot-fire step, its `fireReach` factor at 4204 included).
  - **The routed model:**
    - in slice 1, `roadTraffic.advance` (1675) runs and answers what the readout forwards to it: `serviceReach`, `fireReach`, `deliveryReach`, `noiseOf`, `landValueOf`, `averageLandValue` and `taxLandValueFactor`, as read by the growth gates (4113, 4125), the tax line (1530) and the lot-fire step (4204);
    - from slice 2, nothing: E3a skips its `advance` in agent colonies, and `city.roadGraph` still syncs the graph on read (road_traffic_model.dart:1697-1700).
  - Colonies without agents are untouched.
- **C3. Signal lamps.**
  - **Request.** While a frame carries `cityTraffic`, the junction pass bakes masts **without** lit lamps. Today it switches them by epoch parity (road_mesher.dart:1431-1435, fed the tile's epoch at city_tile_mesher.dart:1816). A `CityMeshKnobs.agentSignals` flag would do.
  - **Offer.** `TrafficNetColumns.nodes` (position, `NodeControlKind`, per-leg stop flags) and `SignalPlan.stateAt`, so that their lamps and our arbiter agree.
- **C4. Their editor has landed.** `CityEditTool` (city_edit_overlay.dart:30-51, with its `traffic` tool at 50) and the editor toolbar are theirs. So are `RoadToolEditing` (road_tool_controller.dart:215), `TrafficInfoView` (55-67), `road_tool_panel.dart` and `road_tool_scene.dart` (ec9e5e9, b7e62e7). Ground input moved into the colony part's `_cityPickLayer()` (simulation_view_colony.dart:998-1047). Our tools live in `TrafficToolController` and open from our HUD drawer. E26(f) and E27 are re-anchored on that code and wait on nothing; they land with their slices (2, 8 and 9). Buttons for our tools in their toolbar remain a request.
- **C5. The wire.**
  - Our edge geometry is sliced from the capture's own `RoadSnapshot`s: `id`, points flipped for reversed roads, and `lifts`, all at world_snapshot.dart:2134-2182. We depend on those semantics and ask to be told before they change.
  - Our capture hook sits after 2219, outside their loops. In `city_nodes.dart` we touch only the four E20 lines and E36.
  - Since 229cb9c the tiles group junction ends by the graph's own rule, read in lifts (`RoadMesher.liftsSeparated`, road_mesher.dart:1024-1033), and every tile end carries an `onDeck` flag into its key (city_tile_bucketing.dart:334-378 and 899; city_tile_columns.dart:517 and 683). So every node we draw signal heads at is a junction the tiles drew. We depend on that as well.
- **C6. Generator topology.** Ramp merges ending 9–16 m beside the mainline are now joined by `RoadGraph`'s dead-end attach. We report what is still dangling (`graph=audit`, `sprawl_topology_audit_test`) to them.
- **C7. A volume seam: resolved in revision 3, and not needed.** From slice 2 the agents answer noise, land value, the tax factor and reach themselves through the readout (D46), from measured flows and their own searches, and E3a skips `roadTraffic.advance` in agent colonies. No assigned volume is left in an agent colony, so nothing is asked of `CityRoadTraffic`.
- **C8. One traffic view: resolved in revision 3.**
  - Their Routes view reads `city.trafficReadout` (road_tool_scene.dart:567-617, keyed on `passes` at 584; road_tool_panel.dart:504-516) and draws `routesThrough` in the `TripRoute` shape (traffic_readout.dart:26-46). In an agent colony that is our readout, so from slice 1 it draws live vehicles' locked routes with no second code path. Their Junctions view draws `city.roadGraph`'s plans (road_tool_scene.dart:492-493), the plans our arbiter reads.
  - Our slice-2 view is the lane-speed overlay (V) and the route inspector (§13.9). It shows per-lane speeds and one vehicle's remaining route, which theirs does not, so the two complement each other.
- **C9. Renderer hooks (new).**
  - A per-body cosmetic cap (`CityTraffic.capFor(bodyId)`), needed once slice 11 runs agent and non-agent colonies side by side.
  - Hiding cosmetic trains per body, for slice 9b.
  - Both live in `city_traffic.dart`, which we do not edit.
- **C10. Parked-car knobs (new).** Base tiles do not key on `onStreetParking` or the parked-car ceiling (D32). We set both before the first tile request and call `invalidate()` on a mid-session enable. **Optional request:** add them to the base-tile key in `city_tile_bucketing.dart`.
- **C11. `docs/REFERENCE.md` (new).** E22 regenerates it; the main checkout has an uncommitted edit to it. Agree with them, and with the user, who commits it.

**Slice-1 merge gate:** C1, C2 and C5 acknowledged, C3 posted, and the worktree rebased onto `dev`.

---

## 2. Core data model

### 2.1 Conventions

- **Layout.** All agent state is structure-of-arrays in typed lists (`Int32List`, `Float32List`, `Uint8List`, `Uint16List`), with a capacity.
  - Tables grow by doubling (`_grow`). A table may only grow during warm-up or on a graph rebuild, and it never shrinks within a session.
  - Nothing in steady state creates a per-agent Dart object. Old-generation GC mark cost scales with live objects (perf-threading report §1.4: pauses of 25–78 ms).
- **Handles.** A handle is `gen << 20 | slot`.
  - `slot` is below 2²⁰ (1,048,576) and `gen` is a `Uint16` (below 2¹¹ in use), so a handle stays under 2³¹ and is web-safe.
  - A stale handle is detected by its generation.
- **Iteration.** Always in slot order or in element-id order. Maps are used for id lookup only and are never iterated in simulation logic; a grep test enforces this (§17.4).
- **Strings.** They appear only in the building table's site-id column, in stop, line and stub ids, and in persistence.

### 2.2 Id schemes and lifetimes

| Entity | Runtime id | Persisted id | Lifetime |
|---|---|---|---|
| Node / edge / lane / connector | dense int per `LaneGraph` build; edge ids equal the `RoadGraph`'s | none (lineage remaps across builds) | one graph object |
| Building | dense int in `BuildingTable` | **site id** string: the lot id (`lot-<road>-<r\|l><n>`, city_layout.dart:1294; `lot-m<n>` for a hand-drawn lot, 1065) or `cell-<k>` for a grid building | until demolished. Follows the rename seams: `_carryRenamedLots` (E12), `_carryLotsAcross` (E13) and `clearParcel` (E14). |
| Citizen | handle | dense index at save time, rewritten densely | from arrival to emigration or death |
| Visitor | row in the `VisitorTable` (§10.4) | not persisted | from the stub back to a stub |
| Vehicle / pedestrian | handle | not persisted | one trip, one service run, or one bus or train shift |
| Parked car | handle | `(owner citizen, where, site id or kerb e,n,heading, variant)` | while parked or garaged |
| Route | arena offset and length | not persisted | one leg |
| Request | `(building int, ServiceKind)` plus a `requestStampUs` | re-raised from accumulators on load | until served |
| Depot | building int | derived from spec label | with its building |
| Stop / line / stub | `'s<n>'` / `'L<n>'` / `'oc<n>'` strings; int index at runtime | yes, with sequence counters | until deleted |

The persisted counters are `seq.stop`, `seq.line`, `seq.oc` and the RNG state. There is no per-citizen persisted id, because citizens are re-indexed densely on save.

### 2.3 `VehicleTable` (initial capacity 4096; the cap `AgentTuning.maxVehicles` defaults to 4096)

| Column | Type | Meaning |
|---|---|---|
| `gen` | `Uint16List` | slot generation |
| `kind` | `Uint8List` | `AgentKind` (append-only, §1.1) |
| `variant` | `Uint8List` | an opaque byte drawn from `TrafficRng` at spawn. The renderer uses it to pick a model within a kind (D42); the domain never names a mesh. |
| `state` | `Uint8List` | `driving`; `holdAtEdgeEnd` (a re-plan is queued); `dwelling` (a service stop, a bus or train at a stop, a fire engine on scene); `parkingSearch`; `leaving` (despawn next sub-step) |
| `elem` | `Int32List` | current element: a lane id `< nLanes`, or a connector `nLanes + c` |
| `s` | `Float32List` | metres along the element, in simulation arc |
| `v`, `a` | `Float32List` | speed (m/s) and last acceleration (m/s²), for rendering |
| `v0` | `Float32List` | desired speed, cached when the vehicle enters an element |
| `f` | `Float32List` | the desired-speed factor drawn for this trip (§5.3); delay observations divide by it (§4.2) |
| `len` | `Float32List` | vehicle length (m) |
| `routeOff`, `routeLen`, `routeCur` | `Int32List` | arena slice and cursor |
| `destS` | `Float32List` | stop position on the final edge |
| `destKind` | `Uint8List` | building access, kerb slot, lot entrance, stop, stub sink, or depot |
| `owner` | `Int32List` | citizen handle, visitor row, request index, line index or stub index, depending on the kind |
| `payload` | `Float32List` | cargo units, bodies, passengers or goods |
| `stuckT`, `waitT` | `Float32List` | seconds without progress, accrued only in `driving` and `parkingSearch` (§5.6); seconds at the current stop line |
| `movedSinceReset` | `Float32List` | metres since `stuckT` was reset |
| `edgeEnterUs` | `Float64List` | agent time the vehicle entered its current edge (integer µs held in a double), for the delay observation |
| `tripT0Us` | `Float64List` | agent time the trip started (integer µs held in a double; exact below 2⁵³) |
| `freeFlowS` | `Float32List` | free-flow time of the planned route, for trip statistics |
| `prev`, `next` | `Int32List` | leader and follower within `elem` |
| `parkTry` | `Uint8List` | parking circles so far |

- **Occupancy.** `elemHead` and `elemTail` (`Int32List`, one per element) are rebuilt on a graph swap by re-inserting live vehicles.
- **Size.** About 120 B per vehicle, so 4096 vehicles take about 0.5 MB.

### 2.4 `PedestrianTable` (capacity 4096)

Columns:
- `gen`, `state` (walking, waitingCross, waitingStop, riding, entering);
- `pav` (a `PedestrianGraph` edge), `s`, `dir` (±1), `v`;
- `routeOff/Len/Cur` in a second `RouteArena` (pedestrian edge ids);
- `owner` (citizen), `rideVehicle`, `waitT`.

### 2.5 `CitizenTable` (capacity 16384, doubling)

| Column | Type | Meaning |
|---|---|---|
| `gen` | `Uint16List` | generation |
| `home`, `work` | `Int32List` | building int, or −1 (homeless or unemployed) |
| `car` | `Int32List` | the car's `ParkedCarTable` handle while it is parked **or garaged**; −1 while it is being driven; −2 when the citizen owns no car. Where the car is (lot, kerb or garaged) is that row's `where`: there is one representation. |
| `state` | `Uint8List` | `CitizenState`: atHome, travelling, atWork, atErrand, outOfTown, movingIn, leaving, riding |
| `activityUntilUs` | `Float64List` | agent-µs wake time (in the activity wheel) |
| `agent` | `Int32List` | vehicle or pedestrian handle while travelling |
| `flags` | `Uint8List` | sick, late-today, hasLicence |
| `sleepsNear` | `Int32List` | for the homeless, the nearest building, used for police generation (§9.2) |
| `itS1`, `itL1`, `itX1`, `itX2`, `itL2`, `itS2` | `Int32List` | a transit trip's locked itinerary: boarding stop, first line, the two transfer stops (−1 when direct), second line, alighting stop (§4.9) |

**The activity wheel.** 512 buckets × 0.5 s (a 256 s horizon) with intrusive `Int32List` next-links. A citizen due beyond the horizon sits in an overflow list, which is rescanned whenever the wheel wraps. Waking the due citizens costs O(due).

### 2.6 `BuildingTable`

It is rebuilt incrementally every `buildingSyncS = 2.0` s of agent time. It is rebuilt immediately when `layout.version`, `parcelBuildings.length` or the `RoadGraph` object changes. Between syncs, E12–E14 carry ids across renames and clears.

| Column | Type | Source / meaning |
|---|---|---|
| `siteId` | `List<String>` | lot id or `cell-<k>`; `idOf: Map<String,int>` rebuilt on sync |
| `spec` | `List<CityBuildingSpec?>` | **the spec instance** (types collide: services-economy report §2) |
| `use` | `Uint8List` | `ParcelUse.index` |
| `housing`, `jobs` | `Int32List` | `(x*uf).round()`, exactly as city_sim.dart:1202-1203 and 1227-1228 do it. `uf` is 1 for placed lots and `parcelUtil` for grown ones (1220-1222). |
| `served` | `Uint8List` | `parcelNetwork().lotServed(id)` (city_sim.dart:1217-1219) until slice 10, then reachability on the lane graph |
| `accessEdge`, `accessS`, `accessSide` | `Int32List` / `Float32List` / `Uint8List` | §3.10. From T4a, per-join access rows (edge, `T`, lane, left bit per direction, role, kind) replace them; slot 0 comes first. |
| `centroidE`, `centroidN` | `Float64List` | from the parcel |
| `lotCap`, `lotUsed` | `Int16List` | parking (§7.1) |
| `garbage`, `corpses`, `crime`, `mail`, `goods` | `Float32List` | accumulators (§9); `goods` is the freight buffer |
| `sickWaiting`, `ambAssigned` | `Uint8List` | patients waiting for an ambulance, and ambulances dispatched to them. Health requests are **counts**. |
| `fireWanted`, `fireAssigned` | `Uint8List` | engines a burning lot needs (1 + [intensity > 0.4] + [intensity > 0.7]) and engines dispatched to it |
| `fireHazard` | `Float32List` | ignition weight |
| `requestMask`, `assignedMask` | `Uint8List` | one bit per single-request kind (garbage, deathcare, police, mail, goods) |
| `requestStampUs` | `Float64List` × kinds | oldest open request per kind |
| `retryAtUs` | `Float64List` × kinds | the no-route back-off (§9.3) |
| `noRoute` | `Uint8List` | an A* returned no path from or to this building |

**Removal.** A building removed by a sync, a clear or a burnout is tombstoned:
- its residents become homeless and its workers unemployed;
- its requests are cancelled;
- trips already heading there are **not** touched en route. They find the building gone on arrival (§4.7).

### 2.7 Parking tables

- **Kerb.**
  - Per directed edge: `kerbCap` (`Uint16`) and `kerbUsed` (`Uint16`), plus an occupancy bitmap in one shared `Uint8List`, addressed through `kerbBitOff[edge]`. A set bit is a parked car **or a binding reservation** (§7.3).
  - For one-way roads, both kerbs belong to the single edge: `kerbCapL` and `kerbCapR`.
  - Slot i sits at `s = stopBack(from) + 6 + (i + 0.5)·6.5` m.
- **Lots.** `BuildingTable.lotCap` and `lotUsed`. From T4a, each site with a network plan also has a stall bitmap (a parked car or a binding reservation), synced on `sitesRev` (§7.3, D49).
- **`ParkedCarTable`** (capacity 16384) has these columns:
  - `where` (lot, kerb, garaged);
  - `building` or `edge` + `slot` + `side`; a lot car from T4a holds `(site, stallKey)` (§7.4);
  - `owner` (a citizen handle, or a visitor row);
  - `variant`.

  The table carries `parkedRev`, which is bumped on every park and unpark (the renderer rebuilds its layer at most at 0.5 Hz).

### 2.8 Depots, requests and fleets

- **`DepotTable`** is derived on each building sync from buildings whose spec label is in `kDepotByLabel` (§9.2). Columns:
  - `building`, `kind`, `fleet`, `out` (vehicles on the road), `capacity`;
  - `buffer` (`Float32`: garbage units or bodies waiting to be processed);
  - `processRate` (the spec's rate: `inputs[garbage]` or `deathcareRate`, city_building_spec.dart:84).
- **`RequestQueue[kind]`** is a FIFO ring of `Int32` building ints, ordered by `requestStampUs`.

### 2.9 Stops, lines and stubs (objects: few, player-made)

- `TransitStop { String id; Vec2 at; double headingRad; String name; }`. Resolved per graph revision to a runtime `(edge, s)` or `broken`.
- `TransitLine { String id; String name; int argb; int mode; List<String> stops; int vehiclesWanted; String? depotSite; }`. `mode` is bus, rail or L (§11.7). Runtime: the line's shared route block in the arena, the stop `s` offsets, and the cycle time.
- `OutsideConnection { String id; Vec2 at; double headingRad; int classIndex; bool enabled; }`. Runtime: its stub node, its sink node at `at + heading × 2000 m`, its sink edge pair, and a broken flag. There are **no per-stub rates**: every flow is defined in §10.4.

### 2.10 Route arena

- **Storage.** `RouteArena` is one `Int32List`, initially 262,144 ints (1 MB). Size-class free lists hold blocks of 8, 16, 32 and so on up to 1024 ints.
- **Route format.** `[firstLane, conn₁, …, connₙ]`. The final stop is held in `destS`.
- **Long routes.** A route over 1024 elements is split at a waypoint node into chained legs; only freight crossing a whole sprawl gets this long.
- **Transit lines.** A line's route is one shared block, and each bus holds only a cursor into it.
- **Compaction** runs only when fragmentation exceeds 50%. It copies live blocks into a preallocated twin and rewrites `routeOff`.

### 2.11 Memory at the design point

The design point is 5,000 citizens, 2,000 vehicles and 1,000 pedestrians.

| Item | Size |
|---|---|
| Tables | ≈ 3 MB |
| Arena | 1 MB |
| A* scratch | 4 contexts × ≈ 16 B × edges; for 6,000 edges, 0.4 MB |
| Lane graph | ≈ 1 MB at 2,000 roads |

---

## 3. Lane graph

### 3.1 Derived from the road agent's `RoadGraph`

**Source.** `final g = city.roadGraph;` (city_sim.dart:3344), a getter on `roadTraffic.graph` (road_traffic_model.dart:1697-1700).
- `CityRoadTraffic._sync` (road_traffic_model.dart:1729-1761) keeps it current on `(layout.version, roadsRevision, junctionOverrides.length)`.
- It either rebuilds the graph (`RoadGraph.of`) or patches it (`refreshedFor`, `withOverrides`) when only overrides or names changed.
- In slice 1, `roadTraffic.advance` (city_sim.dart:1675) has already synced it this tick when `agents.advance` runs, so the read is a few integer compares. From slice 2 E3a skips that call in agent colonies, and the getter syncs on read instead: the same compares, and the rebuild after an edit.

**What `RoadGraph` decides, and we never re-decide** (at `c672eb3`; D48):
- **Nodes.** Road ends are clustered within `nodeMatchPlanM = 8` m in plan (road_graph.dart:202) wherever the layout's grade-separation rule says they meet (799-858). Each end's level is `CityLayout.levelOf(deck, s, len)` (city_layout.dart:318-332), and two ends join unless `CityLayout.levelsSeparated` (357-363) says they pass. That is the rule that cut the roads into junctions and snapped their ends, so the graph joins exactly what the layout cut (229cb9c).
  - Two ends on the ground always meet. A draped road is on the ground **whatever its bridges**, so a bridged mainline's split ends meet a ground-level ramp, which is the cloverleaf loop-ramp case.
  - Two deck ends meet unless their heights differ by `RoadElevation.gradeSeparationM` (4.5 m, road_elevation.dart:59) or more.
  - A deck end meets a ground end unless the deck is clear of the ground there, on its piers or in its tunnel. So viaducts and tunnels never join the streets they cross in plan, and a deck graded into the ground does.
  - `RoadNode.atGrade` is false when any end at the node is off the ground (road_graph.dart:968-979); it holds when every end has `level == null || !level.offGround`.
  - The old rule is gone from the graph: decks within `RoadElevation.nodeMatchM` (2 m), `_sameLevel`, and `startAtGrade`.
  - **Deck ranges.** A deck's structure and tunnel ranges are measured along the road its survey walked: `RoadDeck.rangeLengthM` (parcel.dart:700), saved as `'l'` (794). A probe of them at an index arc goes through `RoadDeck.offGroundAt` (715-718) or `CityLayout.levelOf`, which read it at `rangeArc` (705-711). A save re-samples a curved road by millimetres, and read raw at its very end a viaduct stepped off its piers and joined the street below. Our code (access points, the rail graph of §11.7, the audit) never reads `onStructureAt` or `inTunnelAt` directly.
- **Dead ends against another road.** The dead-end attach pass in `RoadGraph.of` joins a dead end lying against another road to it, part way along, as a node on that road (road_graph.dart:896-935).
  - The reach is `own.halfWidth + other.halfWidth + attachSlackM` (4 m).
  - Only a ramp may meet a limited-access road part way along.
  - The end must be at that road's level there, by the same rule (road_graph.dart:926-931).
  - This covers ramp merges ending 9–16 m beside the mainline, failed merges, and T's the layout never cut.
- **Pieces and directed edges.** A piece is the stretch of one road between consecutive nodes. Directed edges honour `oneWay` and `reversed` (road_graph.dart:1093-1130).
- **Legs and plans.** Every non-rail road end at a node is a leg, alleys, paths and decks included, and every leg routes (`RoadNode.legs`, road_graph.dart:81-84).
  - The plan is read over the **drawn** legs only: those whose class `joinsJunctions` (parcel.dart:246-250: roads that carry cars, other than the elevated road, an alley or a path). `_planOf` (road_graph.dart:639-669) runs `junctionPlanForNetwork` (road_junction.dart:392-421) over them and numbers `stopLegs` back into the full leg list. The roundabout and `lifted` inputs count drawn legs too (1068-1073).
  - So an alley or a path meeting a street is a kerb cut, never a stop, and a node with fewer than three drawn legs stops nobody (`junctionControlFor`, road_junction.dart:53-83).
  - `defaultStopLegs` (road_junction.dart:279-305) decides the all-way stop over every car leg, leaving legs included. A motorway off-ramp, or a one-way street leaving an avenue, no longer stops the through road; an on-ramp still stops the ramp. Only the leg-aware warrant reads it, at junctions the road tool had a hand in.
  - The tiles ask the same question over the same legs (`RoadMesher.junctionPlan`, road_mesher.dart:1211-1220), so a light the player sees is a light the agents wait at.
- **Lot access.** Each lot has a piece, an arc position and a direction mask (road_graph.dart:1162-1203, `_dirsFor` at 685-696). Grid sites go through `attachFootprint`, the same call the routed model makes (road_traffic_model.dart:1844-1876).

**What we keep.** A reference to the graph object: its `roads`, its `roadRecs` (`IndexedRoad` records whose `Float64List`s are never mutated) and its arrays. The old object stays alive for exactly one rebuild, for lineage (§3.9).

**Why derived rather than parallel.** Two independently clustered graphs of one network disagree about reachability. Then a fire engine the routed model says can reach a lot, and a route our agents cannot find, would both be "true" at once.

### 3.2 Node kinds

| `RoadNode` | `NodeControlKind` |
|---|---|
| one leg, `atGrade` | `deadEnd`, or `stub` when an `OutsideConnection` resolves there (§10.4) |
| one leg, not `atGrade` | `danglingDeck`: a dead end, drawn in the traffic view as a network error |
| two legs, plan `none`; or plan `merge` with no ramp leg | `continuation` (the 6→4 seams, a class change, a ring's seam) |
| plan `merge` with a ramp leg | `rampMerge` |
| plan `stop`, every inbound **drawn** car leg in `stopLegs` | `allWayStop` |
| plan `stop`, otherwise | `stop`, with a per-leg stop flag |
| plan `signals` | `signals` |
| plan `roundabout` | `roundabout` |

- The warrant never returns `none` for three or more legs (road_junction.dart:53-83, 211-238), but the plan is read over the **drawn** legs (§3.1). A node of three or more legs with fewer than three drawn, such as a street's seam with an alley or a path meeting it, therefore plans `none`. It is `uncontrolled`: legs outside the plan give way to drawn legs, and the rest follow tier rank and then the right-hand rule (§5.4).
- The elevated road is outside the plan too, so its two-leg seam with an expressway plans `none` where it planned `merge`. Both map to `continuation`.
- **A ring piece** has `from == to`. An example is the beltway without interchanges: its first and last controls coincide (city_generator.dart:1238-1250), and it is committed as an ordinary open expressway8 (1514-1519).
  - Its node is a `continuation` whose straight connector joins the edge to itself.
  - The connector, planner and lineage code treat a piece whose ends are the same node explicitly, and never as a U-turn.

### 3.3 Directed edges

- **Ids.** Lane-graph edge ids **equal** `RoadGraph` edge ids (0 … `g.edgeCount − 1`). Stub sink edges are appended after them (§10.4). Delay tables, occupancy and lineage are all indexed by these ids.
- **Per-edge columns:**

| Column | Meaning |
|---|---|
| `edgeRoad` | `g.pieceRoad[g.edgePiece[e]]` |
| `edgeDir` | `g.edgeForward[e]`: 1 is polyline order |
| `edgeS0`, `edgeS1` | `g.pieceS0/pieceS1`, the arc range on the road's own polyline; a backward edge maps `s_travel = s1 − s` |
| `edgeFrom`, `edgeTo` | `g.edgeFrom/edgeTo` |
| `edgeLen` | `g.edgeLength` |
| `edgeLimit` | `g.roadSpeedMps[r]`, looked up once per kind of road by `RoadGraph.of` |
| `edgeWType` | §4.1 |
| `edgeTier` | `RoadTier.rank` (parcel.dart:471-481) |
| `edgeLaneBase`, `edgeLaneCount` | the edge's lanes |
| `edgeFlags` | sealed, hasPavement, parking (`RoadType.hasParking`, road_catalog.dart:92-94, excluding `RoadClass.highway`, road-agent trap 11), divided, bridge, busAllowed |

- **Divided** means `lanes.divided` (a median wider than 0: parcel.dart:577) or `limitedAccess`. On a one-way road the far kerb is the left kerb, which the edge owns, so there is no crossing.
- `g.edgeTime` (drive time plus their node delay) is not used. Our cost is §4.1.

### 3.4 Lanes and offsets

- **Index.** Lane `k = 0` is the **rightmost (kerb) lane** of the directed edge, increasing to the left. Let `L = lanesEachWay` of `road.lanes` (decoration-aware, parcel.dart:1001) and `w = laneWidthM`.
- **Offsets**, in metres right of travel:
  - Two-way road: `offTravel(k) = medianM/2 + (L−1−k+0.5)·w`. That is `laneOffsets[L−1−k]` (parcel.dart:593-596).
  - One-way road: `offTravel(k) = (L−1−k+0.5)·w − L·w/2` (parcel.dart:588-591).
  - Path or alley (no layout): one lane each way at `offTravel = halfWidth/2`.
- **Starter street check:** L = 1, w = 4, no median, so `offTravel(0) = 2.0`. That matches the pinned `road_lanes_test.dart:79`.
- **Stored per lane:** `laneEdge`, `laneIdx`, `laneOff` (`Float32`, right of travel, at full width).
- **Tapers (D44).** A road with `startHalfWidthM` or `endHalfWidthM` keeps all L lanes to its end node. Examples: the radial interstates, which start at the avenue's or the viaduct's half width (city_generator.dart:1213-1220), and the 6→4 seams.
  - The drop or add happens at that node's `continuation` connectors (rule 2), which is where lanes may change.
  - The renderer scales lane offsets over the tapered stretch by `hw(s)/hw`, the cosmetic pass's `laneScale` rule (city_traffic.dart:534-539).
  - No edge ever has zero lanes.
  - **Example.** The radial expressway6 has 3 lanes each way and starts at the avenue's half width of 8.0 m. It meets the core avenue, which has 2 lanes each way.
    - Inbound (3 → 2): in-lanes 2 and 1 align to out-lanes 1 and 0; in-lane 0 merges into out-lane 0 as a dropped lane.
    - Outbound (2 → 3): in-lanes 1 and 0 align to out-lanes 2 and 1; in-lane 0 also fans out into out-lane 0.

### 3.5 Connectors: the only place a lane changes

For node N with in-edges I and out-edges O.

**Turn geometry.**
- `θ(in, out) = atan2(cross(dIn, dOut), dot(dIn, dOut))` from the end tangents, taken from the first sample at least 3 m in from the node. This runs at build time only; `atan2` is deterministic on a given platform.
- In the East-North frame, **negative cross means a right turn** (road-topology §6 step 7).
- Classes:
  - straight: `|θ| < 30°`;
  - right: `θ ≤ −30°`;
  - left: `θ ≥ 30°`;
  - sharp: `|θ| > 135°`.
- A U-turn is `out` being the reverse edge of `in`: the same piece, the opposite direction.
- The **straight out** is the out-edge with the smallest `|θ|` under 30°, if one exists.

**Allowed movements.** Every (in, out) pair except U-turns. U-turns are allowed only at **dead ends**, **stub nodes** and **roundabouts** (§3.6).

**Rule set.** For in-edge I with n lanes, sort its allowed non-straight outs **right to left** as `o₀ … o_{m−1}`. The straight out takes part in the banding at its angular position.

1. **Turn bands by interval overlap.**
   - Movement j owns the interval `[j·n/m, (j+1)·n/m)`; in-lane i owns `[i, i+1)`.
   - In-lane i may make movement j iff the two intervals overlap: `j·n/m < i+1 && (j+1)·n/m > i`.
   - Examples:
     - n = 1, m = 3: lane 0 makes R, S and L. The starter kit's one-lane streets therefore get every movement.
     - n = 2, m = 3: lane 0 makes R and S; lane 1 makes S and L (shared lanes).
     - n = 3, m = 3: R, S, L from lanes 0, 1, 2.
2. **Straight from every aligned lane.** For the straight out S with M lanes, **every** in-lane that has an aligned out-lane gets a straight connector, whatever the banding says.
   - The alignment is **median-aligned**: in-lane `n−1−t` goes to out-lane `M−1−t` for `t = 0 … min(n, M)−1`.
   - **Lane drop** (n > M): in-lanes `0 … n−M−1` get a straight connector to out-lane 0. They merge into the kerb lane, and they yield (§5.4).
   - **Lane add** (n < M): out-lanes `0 … M−n−1` are fed from in-lane 0 (fan-out).
3. **Turns may land in any out-lane.** Each (in-lane, turn movement) pair from rule 1 gets a connector to **every** lane of that out-edge. The lane planner (§4.5) prefers natural landings: a right turn into the kerb lane, a left turn into the innermost lane.
4. **Continuation and merge nodes use rule 2's alignment everywhere.**
   - At a `rampMerge` node, the ramp lane connects only to mainline out-lane 0, on the carriageway where `cross(mainDir, rampEnd − node) < 0`.
   - At a diverge, mainline in-lane 0 connects to ramp lane 0 as well as to its straight out.
   - No connector ever reaches the opposite carriageway.
5. **Adjacent-lane straight connectors at real junctions.**
   - These are added at nodes with three or more legs whose kind is `stop`, `allWayStop`, `signals`, `roundabout` or `uncontrolled`. They are never added at `continuation`, `rampMerge`, `deadEnd`, `stub` or `danglingDeck` nodes.
   - Each in-lane with an aligned straight out-lane (rule 2) also gets straight connectors to the out-lanes one to the left and one to the right of that aligned lane, where they exist.
   - They are ordinary connectors. Their conflicts are computed from their Bézier polylines like any other, and the lane planner charges 1.0 per lane shifted (§4.5).
   - This is the spec's "vehicles change lanes at nodes": a shift of one lane per junction, planned at spawn.

**Guarantees** (checked by `connector_coverage_property_test` and `lane_planner_feasibility`):
- **Free start** (a new trip leaving an access point, a depot, a stop or a sink, which may enter any lane of its first edge):
  - every allowed movement's interval has positive length, so it overlaps at least one in-lane (rule 1);
  - every out-lane of every allowed movement has a feeding in-lane (rules 2 and 3);
  - so for **any** edge sequence the A* returns, the backward sets of §4.5 are non-empty. There is no A* retry loop.
  - A split always offers "same lane, straight on" (rule 2), so a remap never fails because of lanes on an unchanged road.
- **Fixed start** (a re-plan from the lane the vehicle is in, or an appended leg that begins in its current lane): **not** guaranteed for an arbitrary edge sequence.
  - Example: an avenue with n = 2 and m = 3, and a vehicle held in lane 0 whose next movement is a left. Lane 0 makes only R and S. The edge sequence "straight, straight, left" would be drivable only if lane 1 could be reached, and without rule 5 it could not.
  - Every fixed-start plan therefore runs the (edge, lane) state search (§4.5). It expands only real connectors and returns a drivable route or "no path". Rule 5 widens what it can reach: straight through into lane 1, then left at the next junction. A right turn and a block round is always a candidate too.

**Connector columns:**
- `conFromLane`, `conToLane`.
- `conLen`: a quadratic Bézier from the in-lane end to the out-lane start, with the control point at the tangent intersection, clamped to 2× the chord. Sampled at 8 points for length.
- `conTurn`.
- `conRole`: priority, yield, merge-yield, dropped-lane, shift, U.
- `conVmax = sqrt(3.0·Rmin)`, precomputed. A 90° turn at an 8 m radius gives 4.9 m/s.
- `conConflictOff/N`, a compressed list into `conflicts`.
  - Two connectors of one node conflict if their 8-point Bézier polylines intersect, or if they merge into the same out-lane from different in-lanes. Diverging from one in-lane is not a conflict.
  - Each conflict stores the arc position of the conflict point on both connectors, which the arbiter-safety property uses.

**Stop back-off.** `stopBack(N) = maxHalfWidth × 1.45 × 0.92`. That is the renderer's stop-bar radius: road_mesher.dart:1379 sets `r = maxHalfWidthM × 1.45`, and 1390-1396 draws the bars at `r × 0.92`.
- For roundabouts: `max(14, maxHalfWidth·2 + 6) × 0.96`, the renderer's yield line (road_mesher.dart:1457-1497).
- For none, continuation, merge and dead-end nodes: 0.
- Lanes run from `stopBack(from)` to `edgeLen − stopBack(to)`, and connectors cross the plate, so vehicles stop at the drawn bar.

### 3.6 U-turns and dead ends

- **Dead-end node.** Every in-lane connects to every lane of the reverse edge. Length: a semicircle of radius `(offIn + offOut)/2`, minimum 4 m. `J = 20 s` (§4.1).
- **Stub node.** The U-turn at the stub's own sink is free (§10.4). The stub node itself allows U-turns in case the sink is disabled.
- **Roundabout.** U-turn connectors from the innermost in-lane.
- Nowhere else. A car that needs to reverse finds a block to go round, or a dead end.

### 3.7 Node control and who owns signal state

**Legs.** The node's `RoadGraph` legs (`RoadNode.legs`, with `startsHere` and `heading` as the graph built them), sorted by heading, ascending, so `stopLegs` indices are reproducible (road-agent trap 9).
- Every leg routes, alleys and paths included. They carry cars, and the warrant ranks them `RoadTier.minor`.
- The plan is read over the drawn legs only (§3.1, D48). An alley or a path leg is never in `stopLegs` and never shapes the control, and `stopLegs` already index the full leg list.
- The arbiter gives every leg outside the plan one rule: it gives way to every drawn leg (§5.4). No plan of our own is computed.

**Plan.** `RoadNode.plan` as the graph computed it over the drawn legs: the warrant chosen by `keepsClassWarrant` (road_junction.dart:379-380; the class-only warrant for the generator's junctions, the leg-aware one where the road tool had a hand), with the player's nearest override within 6 m applied. We map it to a kind by §3.2 and never re-evaluate it, so the tiles, the routed model and the agents all read one answer.

**`SignalPlan`** (`node_control.dart`):
- **Phase grouping.** Inbound legs are grouped into axes: a leg joins axis 0 when `|cos(heading − h₀)| ≥ cos 45°`, where h₀ is leg 0's heading; otherwise it joins axis 1. If the result is degenerate (for example three legs within 90°), each leg gets its own phase.
- **Timings** (integer µs): `greenUs = 12e6`, `amberUs = 3e6`, `allRedUs = 1e6`. A 2-phase cycle is 32 s.
- **Offset.** `offsetUs = fnv1a32(JunctionOverride.keyFor(node.at)) % cycleUs`. The key is whole metres (road_junction.dart:158), so the offset is stable across splits and sessions.
- **State.** `stateAt(phase, timeUs)` with `t = (timeUs + offsetUs) % cycleUs`. It is pure integer arithmetic, and both the arbiter and the renderer call this same function.
- **Walk phase.** It is the parallel green: pedestrians crossing leg L walk while the phase perpendicular to L is green (§8.3).

**Ownership.**
- Signal state belongs to the simulation's agent clock. It is not stored: it is a function of `timeUs`.
- The renderer draws heads from `TrafficNetColumns.heads` (per revision) through `SignalPlan.stateAt(renderTimeUs)` (§13.6).
- The tiles' epoch-parity lamps (road_mesher.dart:1431-1435) stay until C3 lands.

### 3.8 Revision and invalidation

**Key.** `TrafficNetKey(graph, stubsRev, stopsRev)`.
- `graph` is the `RoadGraph` object, compared with `identical`.
- `stubsRev` and `stopsRev` are ours, bumped by our tools and hooks.
- **Polling.** `agents.advance` first compares `city.roadsRevision` (city_sim.dart:425) and `layout.version` (city_layout.dart:116) with the values it last saw. It fetches `city.roadGraph` only when either has moved.
- There is no hash of the junction overrides. `setJunctionOverride` moves `roadsRevision` (city_sim.dart:4035), and the graph carries the resulting plans.

**When the key moves.** At the start of the next `advance`, before its first sub-step:

| Change | Work |
|---|---|
| `identical(g, built)` | Nothing |
| `g.sharesStructureWith(built)`: only overrides or road names changed (`refreshedFor`, `withOverrides`) | Refresh node kinds, stop flags, signal plans and connector roles. Lanes, connectors and ids stand, and no route is remapped. Vehicles waiting at a changed junction re-arbitrate on the next sub-step. |
| Anything else | 1. Build the new lane graph. 2. Remap every live route (§3.9). 3. Re-insert vehicles and pedestrians. 4. Re-resolve access points, kerb slots, stops, stubs, depots and line routes (remap first, §11.2). 5. Swap, and bump `graphRev`, which the render geometry keys on. |
| `stubsRev` or `stopsRev` moved | Rebuild the stub sink edges or re-resolve the stops; remap the routes that used them |

**Build cost.** The derivation is O(edges + connectors), with no clustering of its own. Target: ≤ 5 ms for 2,000 roads, confirmed by the slice-1 benchmark (§15.5).
- `RoadGraph.of`'s own cost is paid by the road agent's model on every edit, whether or not agents exist.
- Above `graphBuildInlineMaxRoads = 3000`, `LaneGraphBuilder` runs resumably across advances. Its phases are edges → lanes → connectors → conflicts → controls, each budgeted by item count. The old lane graph keeps running meanwhile, and new spawns wait.
- In batch generation (`regenerateLots: false`, city_layout.dart:434, 644) nothing ticks, so no rebuild storm occurs.

### 3.9 Road-split lineage and route remap

**Why remapping is possible.** Split pieces are named `'${id}x$i'`, numbered along the parent after slivers under 8 m are dropped (city_layout.dart:983). The old `RoadGraph` holds the old roads' `IndexedRoad`s, whose lists are never mutated.

**Children of an old road R** in the new graph:
- Every new road whose id starts with `R.id + 'x'`. This covers nested chains such as `r5x1x0`.
- For each candidate C, project C's first and last samples onto R's old polyline. That gives C's arc range `[c0, c1]` on R.
- Accept the projection if both distances are ≤ 0.5 m. Decimation uses 0.15 m, and cuts lie exactly on the polyline.
- Children are ordered by `c0`.
- A gap between children of up to 8.5 m (a dropped sliver) is bridged **only if** the two children share a node in the new graph.
- **A re-laid road is not a child.**
  - Adjust Roads lays new geometry under `childIdFor(id)`, which is `<id>x<k>` (city_layout.dart:928-936; city_sim.dart:3974-3998).
  - A candidate whose ends do not both project within 0.5 m is treated as **a new road**. Every route through R fails its remap, because the network changed under it, and re-plans.
  - A vehicle on R stays only if its current position projects onto the new road within 0.5 m in the travelled direction. Otherwise it despawns (`despawnEdit`).

**The same road id still present** (an attribute change; `upgradeRoad` keeps the id, city_layout.dart:845 ff.):
- The edge maps to the same arc range if the direction still exists.
- A reversal removes the old direction, so routes in it fail.
- A changed lane count triggers the sticky lane repair (step 3).

**Remapping one route** (`RouteRemapper.remap(handle)`):
1. Walk the remaining old elements. Map each old edge's remaining arc range, from the vehicle's position onward for the current edge, to the ordered chain of new edges with the same root road and direction that cover it.
2. **Inside one old edge**, consecutive new edges meet at a new node. Use the straight connector for the vehicle's lane there. Rule 2 guarantees that "same index, straight on" exists when the lane count is unchanged.
3. **At each old node**, find in the new graph the connector from the last new edge of this chain, in the planned lane, to the first new edge of the next chain, landing in the planned out-lane.
   - If that exact connector exists, keep it. Lanes are unchanged.
   - Otherwise, if the movement still exists, run a **sticky repair over the affected span only**. The span runs from the last kept connector before the first changed node to the first downstream node where the planned lane is reachable again.
     - Inside the span, a lane pass with the current lane fixed charges 0 for keeping each old lane index, 1 per lane of change, plus the §4.5 penalties.
     - Connectors outside the span are kept exactly.
     - If no assignment exists with the current lane fixed, the route is impossible in lane terms, and the remap fails.
4. **Fail** if any of these holds:
   - a root road is gone, re-laid, or now has no directed edge in the travelled direction;
   - chains are not contiguous at a node within 1 m;
   - the movement at a node is no longer allowed (an override or rule change removed it);
   - the sticky repair found no assignment.
5. **The vehicle's current element** maps to the new edge covering its arc position, at `s' = s − (c0 − oldEdgeS0)` in the travelled direction. A vehicle on a connector stays on its old connector geometry until it hands over; that geometry is copied into a one-revision "limbo" table.
6. **Carry through a new box** (`_carryThroughBox`). A new node on the vehicle's edge brings a stop bar and a lane start. The mapped travel arc (`placeT`) can then fall outside the new lane's usable range `[edgeLaneS0, edgeLaneS1]`. Clamping it would drag the car up to ~5 m, onto its neighbour. So the car keeps its place:
   - **Past the lane's end** (`placeT > edgeLaneS1`), with the route going on: the car goes on `route[1]`, the connector its route takes through the box, at `s = placeT − edgeLaneS1` (clamped to the connector), with `routeCur = 1`. If the route ends on that edge, the stop clamps to the lane end and the car arrives there.
   - **Before the lane's start** (`placeT < edgeLaneS0`, just past the new node): the car goes on the connector into its lane from the piece of its own road behind it, same direction, same lane index or the nearest (`RouteRemapper.connectorBehind`). The route becomes `[fromLane, connector, lane, rest…]`, with `s = conLen − (edgeLaneS0 − placeT)` clamped, and `routeCur = 1`. With no such connector the clamp stays, and step 7 guards it.
   - A car waiting on a plan (held or dwelling) is not carried: a fixed-start re-plan resolves only from a lane.
7. **No overlap after placement** (`_separate`). After `relinkAll`, each element's list is walked front to back. A car within 0.5 m of the tail ahead is moved back, never below `s = 0`, and counted in `stats.remapNudges`. The lists are already ordered and a nudge never reorders them, so no scratch is needed. A clean edit nudges nobody: tests assert 0.

**A stop at a lane's start.** A stop clamped into a new box, or a lot met at a stop bar (`sOn` clamps there), can sit exactly at the lane's start. Seen from the connector, the stop is taken at least 1 m into the lane, so the car rolls onto the lane and arrives. A car arrives only on a lane, so without this it would wait on the connector for good and wedge the queue behind it.

**Re-target on arrival (`kSiteRetargetTag`).** An edit can move a destination's access: a lot re-hung on another piece or road, or a stop clamped out of a new box. The route is not re-planned for that (D36). Instead, at arrival, `arrived` checks whether the building still stands and has access, but not on the vehicle's edge within 1.5 m of its stop. If so, the vehicle dwells and gets **one fixed-start leg** to the building's current access (the D34 (edge, lane) search). That leg counts in `stats.appendedLegs`, never in `replans`. If no path is found, the vehicle arrives where it stopped.

**On failure.**
- The vehicle's state becomes `holdAtEdgeEnd`: it keeps driving and stops at the end of its current edge. Its `stuckT` is frozen while the re-plan is queued (§5.6).
- A **fixed-start** re-plan goes to the path queue from `(current edge, current lane)` and runs the (edge, lane) state search (§4.5).
- If the current edge itself has no child covering the vehicle, the vehicle is despawned and counted in `stats.despawnEdit`.

**Consequence.** A new road crossing a planned route inserts a node on it, and the remap passes **straight through** that node. Trips already planned do not use the new road, which is the spec's "may not see immediate use". Pedestrian routes remap the same way on the pedestrian graph.

### 3.10 Building access points

**Where access comes from:**
- **Layout lots** (auto and hand-drawn): `g.lotPiece[i]`, `g.lotS[i]` and `g.lotDirs[i]`.
  - An auto lot hangs on its own frontage road at its frontage midpoint.
  - A hand-drawn lot hangs on the nearest road within 90 m of any part of its footprint.
  - Both rules are at road_graph.dart:1162-1203. From the road side's R1 they are join slot 0's rule in `site_access/site_join.dart` (C1): narrow lots join 4.5 m from the lot line, wide lots at the clamped midpoint, set-back lots at their corridor (site-access §3.2, §3.7a).
- **Grid sites** (utilities and grown cells placed with the 2D builder): `g.attachFootprint(parcelForCell(anchor, spec).polygon)` (city_sim.dart:4249). This is exactly what `CityRoadTraffic._gridSites` does, and the result is cached while `sharesStructureWith` holds. From R1, `attachFootprint` is slot 0 of `attachFootprintJoins`.
- **Sites with a plan (from T4a; D49).** A site's access is **its plan's joins**. `joins[0]` is `RoadGraph` join slot 0, which is `lotPiece`, `lotS` and `lotDirs`; further joins are further slots of the same lot, each with a role (in, out or both).
  - `AccessPoints.ofJoin(lg, joinNo)` resolves one join; `ofLotIndex(i)` becomes `ofJoin(lotJoinStart[i])`.
  - **Goals** come from in-capable joins (`addGoals`), each with its own D6 lane mask. **Origins** come from out-capable joins (`addOrigins`), from any lane. `leftOf` resolves by `(edge, T)`.
  - A plan with `!SiteAccessBook.isCurrentFor(siteId, graph)`, for the `RoadGraph` the agents run, is **kerbside at that graph's slot 0**, never at its old joins. So is a built site whose plan has not been generated yet.
  - The routed model's consumers keep reading `lotPiece`, `lotS` and `lotDirs`.

**The lot's side.** Today it is computed from the lot centroid against the road polyline at `lotS`: a negative cross is the right of the polyline direction. From R1 it is read from `joinRight` (1 = the lot is right of the road polyline, first to last control, at `joinS`), never from the centroid.
- Never use the `'r'`/`'l'` letter in the lot id, which is backwards (road-topology trap 14).
- `RoadGraph._rightOf` is private, so until R1 `access_points.dart` re-implements it. A test pins it to `lotDirs` on roads with two or more lanes each way, where the mask implies the side.

**Serving directed edges and lane sets.** The serving edges are the directions in `lotDirs` (per join: `joinDirs`):
- a lot on the right of travel → destination lane set `{0}`;
- a lot on the left of travel → `{L−1}`, a left-in or left-out driveway movement from the innermost lane. This happens on the far side of a two-way street with one lane each way, and at the left kerb of a one-way road.

`RoadGraph` allows far-side access only on two-way roads with one lane each way (`_dirsFor`). So agents never cross a median, or a four-lane road, mid-block (D7). Every join has `joinDirs == _dirsFor(road, side)`; its role restricts in or out, never direction.

**Resolution.** Access resolves on every graph build. After a split, lots are hung on the new pieces by the graph itself. A site's access also re-resolves on a new site, a spec change, or a `sitesRev` change for that site. A control refresh never changes access.

**Unreachable buildings.** A building with no access (`lotPiece < 0`, or `attachFootprint` returned null) is `noAccess`. One whose access node lies outside the largest strongly connected component is `isolated`. Both show in the inspector. From slice 10 they replace `ParcelNetwork.lotServed` for agent colonies (§12.3). **Reachability is per role:** a site with a plan is reachable when it is served, has an in-capable join with a serving edge in the main component, and has an out-capable join likewise. A kerbside plan reduces to the rule above.

---

## 4. Pathfinding

### 4.1 Cost function (seconds)

A route has directed edges `e₁…e_k` and node transitions `n₁…n_{k−1}`. Its cost is:

```
C = Σ_i [ len(e_i)/limit(e_i) · wType(e_i) · wVeh(kind, e_i) + D_i ]
  + Σ_j [ J(n_j, role_j) + T(turn_j) ]
```

The first and last edges are charged only for the part actually driven.

**`wType`, the road-type weight:**

| Road class | Weight |
|---|---|
| street, streetOneWay | 1.00 |
| avenue, boulevard | 0.97 |
| highway, trunk, motorway, expressway4/6/8, elevated | 0.93 |
| ramp | 1.00 |
| alley | 1.60 |
| path | 1.80 |
| stub sink edge | 1.00 |

This nudges through traffic onto arterials and keeps it out of alleys.

**`wVeh`, the vehicle weight.** Trucks, semis and delivery vans pay ×1.5 on `RoadTier.minor` edges, except the origin and destination edges. Every other kind pays 1.0.

**`D_i`, the measured delay** of edge `i` in the delay buffer the search captured when it started (§4.2). Its weight is 1.0 and it has no cap beyond the table's 600 s clamp.

**`J`, the junction penalty,** by the control and this movement's role:

| Control / role | Seconds |
|---|---|
| none, continuation | 0 |
| rampMerge, when yielding | 1.5 |
| stop, when this leg stops | 5.0 |
| stop, when this leg has priority | 0.5 |
| allWayStop | 5.0 |
| signals | 6.0 (the expected red wait over a 32 s cycle, plus start-up) |
| roundabout | 3.0 |
| deadEnd U-turn | 20.0 |

**`T`, the turn penalty:**

| Turn | Seconds |
|---|---|
| straight | 0 |
| right | 2.0 |
| left | 4.0, plus 3.0 at any node that is not signalised |
| sharp | 6.0 |
| U (outside dead ends) | 20.0 |

### 4.2 Measured congestion (the "measured delay at plan time")

`EdgeDelayTable` keeps these per directed edge.

**The observation.** When a vehicle leaves an edge's outgoing connector (it hands over to the next edge), it reports one observation for that edge and that movement:

```
obs = (t_lane + t_con) − free − Jexp
free = laneLen / (limit · f) + conLen / min(limit · f, conVmax)
```

- `t_lane` is the time from entering the edge (`edgeEnterUs`) to entering the connector, **including** any wait at the stop line. `t_con` is the time on the connector.
- `f` is that vehicle's own desired-speed factor (§5.3), so a slow driver does not read as congestion.
- `Jexp` is the §4.1 `J` of the movement taken at that node: 6 s at signals, 5 s for a stopping leg, and so on.
  - It is the control delay the cost already charges, so `D` does not charge it twice.
  - `J` is **defined** as the expected control delay; §17.1's empty-network test pins the two together.
- A vehicle that ends its trip on the edge reports its lane time up to `destS`, with `conLen = 0` and `Jexp = 0`.
- `obs` is **signed**. An arrival on green reports a negative value and an arrival on red a positive one. Their mean is the delay beyond the expected control delay.

**The EMA.** `emaS += α·(obs − emaS)`, with `α = LUT(1 − exp(−1/nEff))` and `nEff = clamp(flowPerMin, 8, 40)`, which gives a half-life of about 60 s at moderate flow.
- **`flowPerMin`** is the number of departures from the edge in the last complete 60 s window of agent time. It is a `Uint16` counter per edge, rolled into `lastWindow` every 60 s.
- **Decay.** An edge with no departures in a whole window halves `emaS`, through the same table. A cleared jam therefore stops deterring new trips.

**The live queue.** `liveQueueS = max(0, stopped − laneCount) × 2.0 s / laneCount`, recomputed every sub-step while walking the edge's lanes. `stopped` counts vehicles with v < 1 m/s. The first stopped vehicle in each lane is the expected red wait, already in `J`; only a queue beyond it counts.

**The published value.** Every `congestionEpochS = 2.0` s of agent time the table publishes `D = clamp(max(emaS, liveQueueS), 0, 600)` into a **fresh** `Float32List` taken from a pool of three.
- A `SearchContext` holds a reference to the buffer that was current when its search began. A search spanning several sub-steps therefore prices every edge from one consistent table.
- A buffer returns to the pool only when no suspended search holds it. If all three are still held, publishing skips that epoch.

So "measured at plan time" means measured at most 2 s before the search started. **In an empty network `D ≈ 0`, signalised edges included.**

**Derived readouts:**
- `load(e) = D/(D + len/limit)`, in [0, 1), for the traffic view.
- `laneSpeedPct[l]`: a 60 s EMA of the mean `v/limit` of vehicles on lane `l`, quantised 0–100 into a `Uint8`.
- `congestionIndex = 1 − (distance driven)/(distance at the limit over the same vehicle-time)`, as an EMA over 60 s. It needs no delay table, so it ships in **slice 1**. It is CS's "traffic flow" inverted: the HUD shows Flow = 1 − index.
- **Per road**, for the readout (D46): `congestionOf(road)` is the congestion index over the road's worst piece in the last 60 s window, and `volumeOf(road)` the vehicles through its busiest piece in the last 600 s.
- The readout publishes `averageCongestion = congestionIndex` and `peakCongestion` = the worst road's `congestionOf`. `advanceParcelTraffic` (city_sim.dart:4137-4172, unchanged) turns them into `parcelCongestion` (3335) = `0.5·(peak + average)` once `hasRun` (4143-4148). From slice 1 the HUD row (city_game_hud.dart:582-583) therefore shows measured congestion with no code change.

### 4.3 Heuristic and ties

- **Heuristic:** `h(n) = |pos(n) − goal| / 29.9`.
  - 29.9 = 27.8/0.93: the fastest limit in the catalogue (100 km/h, road_catalog speeds) divided by the smallest weight.
  - No penalty term enters `h`, so it is admissible.
- **Stub sinks have positions.** A sink sits at `stub.at + heading × 2000 m`, the far end of its 2,000 m virtual edge at 100 km/h. The edge costs 72 s, which is more than 2000/29.9 = 66.9 s, so `h` stays admissible for trips to and from the edge of the map.
- **Ties:** the heap orders by `(f, g, edge id)`, a total order, so results are deterministic.
- `path_search_test` checks that A* cost equals Dijkstra cost (`h ≡ 0`) on 200 random origin–destination pairs.
- The (edge, lane) state search (§4.5) uses the same `h`, evaluated at the edge's end node.

### 4.4 Origins and destinations

**Origins.** A search starts from the origin's **serving** directed edges (§3.10), each with its partial cost `(edgeLen − s)/limit`. Origins are:
- a building's access point;
- a kerb slot or lot, for a parked car leaving;
- a depot;
- a stop;
- a stub's sink;
- or a vehicle's current `(edge, lane)` for a re-plan.

**The goal** is any serving edge of the destination, reached at `destS`.

A car trip's A* targets the **destination building's access point**. Parking is searched on arrival (§7.3).

### 4.5 Lane assignment at plan time

There are two planners. Which one runs depends on whether the first lane is free.

**Free-start plans (`LanePlanner`).** These are new trips leaving an access point, a depot, a stop or a sink: an access point is a lane-choice point (§5.5). The input is the edge sequence `e₁…e_k` from the edge A*, the start lane set (any lane of `e₁`), and the destination lane set.

1. **Destination lane set, `A_k`:**
   - `{0}`, the kerb lane, when arriving at the right kerb or a right-in driveway;
   - `{L−1}` for a permitted left-in (§3.10), or the left kerb of a one-way road;
   - all lanes, for a stub sink or a pass-through leg end.
2. **Backward pass.** `A_i` = lanes `ℓ` of `e_i` with a connector `ℓ → ℓ'`, `ℓ' ∈ A_{i+1}`. By the §3.5 free-start guarantee these sets are never empty; the `lane_planner_feasibility` property test checks that.
3. **Cost pass.** `cost_i(ℓ) = min over connectors ℓ→ℓ'∈A_{i+1} of [ pen(ℓ→ℓ') + cost_{i+1}(ℓ') ]`, where `pen` is:

   | Connector | Penalty |
   |---|---|
   | aligned straight, or a natural landing (right turn into lane 0, left turn into lane M−1) | 0 |
   | fan-out, or a dropped lane merging | 0.5 |
   | adjacent-lane straight (rule 5) | 1.0 per lane shifted |
   | any other turn landing | 1 per lane away from the natural one |

4. **Forward pick.**
   - **Start lane.** The vehicle may enter **any** lane of `A₁`. It takes the lowest-cost lane, with ties going to the rightmost.
   - **At each node,** among the cost-minimal `ℓ'`, it picks the lane with the fewest vehicles currently on that out-lane, which spreads through traffic across lanes at plan time. Ties go to the lower index.
5. **Output.** The connector ids go into the arena. **The lane on every edge is now fixed for the trip.**

**Fixed-start plans (`LaneStateSearch`, D34).** This planner runs whenever the first lane is the one the vehicle already occupies:
- a re-plan after a failed remap (§3.9);
- an appended leg that begins on the carriageway: a parking or circling leg (§7.3), a service vehicle's next stop or its return to the depot (§9.4), a bus's or train's return to its depot (§11.3).

It is an A* over **states (edge, lane)**:
- the start is `(current edge, current lane, s)`;
- the transitions are exactly the connectors leaving that lane at the edge's end node: turns, straights, rule-5 shifts, drops and adds;
- the cost is §4.1's edge and node terms plus `pen`;
- the goal is any state `(goal edge, ℓ ∈ destination lane set)`;
- the heuristic is §4.3's, evaluated at the edge's end node.

Properties:
- It expands only real connectors, so whatever it returns is drivable, and "no path" is a real no path (§4.8).
- A state expansion counts as one expansion of the shared budget.
- Its scratch is sized to the lane count, which is 2–3 times the edge count. That is why new trips, the vast majority, do not use it.
- Its output is the connector list itself, so the lanes are locked by construction.

**Sticky lane repair** is used only by remaps (§3.9 step 3).

The kerb lane at the destination is fixed by the **last connector**, not by any mid-edge manoeuvre (D6).

### 4.6 Locked-route semantics

A vehicle follows its connector list exactly. Speed, queues, red lights, congestion and a late bus never change it.

The only things that may change a route are:
1. a remap after a **network edit**: roads, junction overrides, stubs, bus and rail lines and stops (§3.8, §3.9);
2. a re-plan when that remap fails (D36);
3. new legs **appended** after an arrival:
   - a parking or circling leg (§7.3);
   - a service vehicle's next stop or its return to the depot (§9.4);
   - a bus's or train's leg to or from its depot (§11.3);
   - a transit rider's transfer or egress walk, planned at alighting (§4.9);
   - a re-target after arriving at a building that is gone (§4.7).

An appended leg is a new plan, not an edit of the old one. A line's shared route block is planned once for the line (§11.2), and a bus's cursor moving round it is not an appended leg.

### 4.7 What triggers a re-plan

| Trigger | Result |
|---|---|
| A network edit makes the remap fail (§3.9) | `holdAtEdgeEnd`, then a fixed-start re-plan from the current `(edge, lane)` |
| The current edge vanished | Despawn (`despawnEdit`) |
| The player deletes a bus or rail line or a stop, or sets a line's vehicles to 0 | A network edit: the line remaps and skips broken stops. Riders whose itinerary used the vanished part re-plan from where they are (a new mode choice). |
| The player disables a stub | A network edit: the stub's virtual edges vanish. Vehicles on them despawn (`despawnEdit`, not drawn anyway). Routes through the stub fail their remap and re-plan to another enabled stub; with none left, they drive to the stub node's dead end and despawn there (`despawnEdit`). |

**Not re-plans:**
- **The destination building is demolished, burns out or is removed by a sync, mid-trip.** The vehicle drives its locked route to the old access point; the road is still there. On arrival it finds the building gone, and **an appended re-target leg** is planned: home, or a new errand. This is counted in `stats.arrivedGone`, and the route was never edited.
- **A bus delayed by traffic.** Riders keep waiting (§11.4).
- Congestion, or a new road that would be faster.

### 4.8 A budgeted, deterministic request queue

**The queue.** `PathQueue` is a ring buffer (`Int32` and `Float64` columns) of requests:
- requester (a citizen, vehicle, request, visitor or line handle);
- mode, and whether the start lane is fixed;
- origin and destination descriptors: a building int, stop, stub, or `(edge, lane, s)`;
- destination lane-set kind;
- enqueue sequence.

Requests are served FIFO within their lane.

**The budget** is `pathExpansionsPerStep = 4000` node or state expansions per sub-step (a knob), shared by up to **4 resumable search contexts**.
- A search that exhausts the budget keeps its heap and scratch in its context and resumes on the next sub-step.
- The budget counts expansions, not microseconds, so results are identical on every machine and at every warp.

**Lanes of priority,** in order:
1. re-plans;
2. service, transit and freight legs;
3. car trips;
4. pedestrian legs, which have their own budget of `pedExpansionsPerStep = 1500`;
5. zone skims, only when the queue is otherwise empty.

**Waiting agents.** A citizen waiting for a path stays in their building, or their car stays parked. No vehicle slot is used until the path is ready.

**Staleness.** When the graph revision changes, queued requests keep their descriptors and are re-rooted on the new graph. Suspended searches restart.

**No path:**
- **A citizen** goes idle for 60 s, and `BuildingTable.noRoute` is set for the origin or destination. The inspector shows "unreachable".
- **A service request:** §9.3 (the next depot, then a back-off).
- **A freight request:** the next supplier or customer by the same score, then a 60 s back-off.
- **A visitor or through trip:** a different stub pair is drawn; if none works, the spawn is skipped and counted.

**Scratch.** Each search context has `gScore` (`Float32List`), `parent` (`Int32List`) and `stamp` (`Int32List`, so there is no clearing between searches). It also has a binary heap on parallel `Int32List` and `Float32List` columns. Everything is sized to the edge count (or lane count for the state search), reused, and reallocated only when the graph grows.

**Deterministic shedding** (D9, D10):
- If `pathQueue.length ≥ maxQueuedPaths = 512`, or the vehicle table is at `maxVehicles`, new car trips are **deferred**. The citizen stays at the origin with `activityUntil += 30 s`, and the event is counted in `stats.deferred`.
- **Reserved capacity for service, transit and freight.** Service, bus, rail and freight dispatches are never deferred for the car caps. They draw on the 10% of `maxVehicles` reserved for them, and their path requests use their own lane, capped by `maxQueuedServicePaths = 128`, not `maxQueuedPaths`.
- **When the reserve itself is full,** a dispatch stays in its request queue with its stamp unchanged and is retried on the next dispatch second.

### 4.9 Multimodal search and mode choice

Running a full multimodal search per trip would not fit the budget. Instead, the mode **and the transit itinerary** are chosen **first**, from cheap skims and line tables. Then exactly one real search runs for each leg of the chosen mode.

| Mode | Available when | Generalised cost (s) |
|---|---|---|
| walk | **always** | `1.35·d/1.3` (1.35 is the network detour factor) |
| car | the citizen owns a car and it is parked at the origin | `skimCar(zO, zD) + 45` (expected parking search) `+ 60` (walk from the car) |
| bus | a stop within 450 m of both ends, on one line or with one transfer | `walk₁ + 1.5·headway/2 + ride(L, s₁→s₂) + walk₂ + 180·transfers + 60·fare` |
| rail (slice 9b) | a station within 800 m of both ends | the bus formula with rail's headway and ride table; a bus↔rail change counts as one transfer |

- **Walking is always available, so every trip has a mode.** A long walk is chosen only when nothing else exists, because it costs about 1.04 s per metre. A walk over 2.5 km is counted as `stats.longWalks`.
- **`skimCar`** is a zone-to-zone matrix. A zone is the graph's nodes binned on a 400 m grid; City Builder colonies have at most about 100 zones.
  - Each row is one Dijkstra from the zone's centroid node, pricing `freeFlow + D`.
  - Rows are refreshed round-robin, one zone every 3 s of agent time, through the skim priority of the path budget. That staggers the work and never lands on one tick.
- **`skimWalk`** is `1.35·d/1.3`, with no search. **`skimTransit`** is the best itinerary cost between zone centroids from the line tables, refreshed with the ride tables every 60 s.
- **Itinerary selection** (bus and rail) comes from each line's per-revision stop-to-stop ride table (§11.2):
  - Boarding candidates are the 4 nearest stops within 450 m of the origin (stations within 800 m). Alighting candidates are found the same way at the destination.
  - A **direct** option is every line holding a boarding stop s₁ and a later alighting stop s₂, in loop order.
  - A **one-transfer** option uses, per revision, a transfer list for each ordered pair of lines (L₁, L₂): the pairs of stops, one on each line, within 150 m of each other. Its cost adds the walk between them and 180 s.
  - The lowest cost wins; ties go to the lower stop index.
  - The chosen itinerary is **locked at departure** in the citizen's `itS1, itL1, itX1, itX2, itL2, itS2` columns (§2.5), like a car route. Only §4.7's network-edit rule changes it.
- **Choice rule:** `argmin(cost + 45·G)`, where `G = Lut.gumbel(rng.nextU32() >> 22)` (1024 entries). This is deterministic and gives a realistic mode split rather than an all-or-nothing one.
- **What runs after the choice:**
  - A car trip runs the real A* from the parked car's slot.
  - A walk trip runs the pedestrian A*.
  - A transit trip runs the pedestrian A* to s₁ at departure, followed by queued boarding (§11.4).
  - The transfer walk and the egress walk (s₂ → destination) are **appended legs planned at alighting**, just as parking is appended at arrival.
- **Before the modes exist:**
  - Before T4b (pedestrians), the walk from the car is an instant placement, and citizens without a car travel as instant placements (`stats.instantTrips`).
  - Before slice 9 (transit), the bus mode does not exist.

---

## 5. Movement and junctions

### 5.1 Sub-step and integer clock

- **The clock.** `AgentClock.accumUs += (dt * 1e6).round()`, where `dt` is the clamped value from `CitySim.advance` (≤ 0.5 s, city_sim.dart:1178).
  - While `accumUs ≥ kStepUs` (200,000), run one sub-step and add `kStepUs` to `timeUs`.
  - At dt ≤ 0.5 that means at most 3 sub-steps per `advance`.
- **Partition invariance.** Any split of the same total dt gives the **same** sub-step sequence; for example 25 × 0.02 against 1 × 0.5 (25 × 20,000 µs = 500,000 µs). The legacy 2D host's variable wall-clock dt (city_builder_screen.dart:177-181) feeds the same accumulator.
- **Rates.** At 1×, one sub-step every 10 world ticks (5 per second). At the 25× clamp, 2.5 per tick on average.
- **Leftover.** The fraction below one step stays in `accumUs`. That is at most 0.2 s of lag, which the renderer absorbs (§13.4).
- **The frame hold** (§5.7) changes only *when* a tick runs, never its dt.

### 5.2 Order within a sub-step (fixed)

1. **Wake.** Activity-wheel wake-ups and ledger realisation (§6.2). On the one sub-step of each whole agent second (`timeUs % 1e6 == 0`): dispatch, at most 8 requests per kind in FIFO order (§9.3), and the visitor and through schedules (§10.4–10.5). These enqueue path requests.
2. **Path pump.** Run the budgeted searches. Ready paths spawn vehicles and pedestrians, capped at `maxSpawnsPerStep = 24` of each; spawns beyond the cap wait for the next sub-step in queue order.
3. **Vehicles, in element-id order.** Within an element, from the leader (largest `s`) to the tail. Across elements a follower sees the next element's pre-step tail, which is deterministic.
4. **Pedestrians,** in slot order.
5. **Arrivals and departures:** service stops, bus and train dwells, parking searches, despawns.
6. **Edge delays.** Record observations (§4.2), update the live queues and roll the 60 s flow windows. Every 2 s, publish.
7. **Publish** an `AgentFrame` (triple buffer, §13.2).

Signals have no step: their state is `stateAt(timeUs)`.

### 5.3 Car-following (IDM)

| Kind | a (m/s²) | b (m/s²) | T (s) | s₀ (m) | v₀ factor |
|---|---|---|---|---|---|
| car | 1.4 | 2.0 | 1.2 | 2.0 | U(0.92, 1.05), drawn once per trip |
| truck, delivery van, service vehicle | 0.9 | 1.8 | 1.5 | 2.5 | 0.95 |
| semi | 0.7 | 1.6 | 1.8 | 3.0 | 0.90 |
| bus | 1.0 | 1.8 | 1.4 | 2.5 | 0.95 |

- **Desired speed.** `v₀ = limit × factor` on a lane; `min(that, conVmax)` on a connector.
- **Constants.** δ = 4, and `(v/v₀)⁴` is computed as `sq(sq(v/v₀))`. `√(a·b)` is precomputed per kind.
- **Leader,** in this order:
  1. `prev[v]` in the same element.
  2. Otherwise the **tail** of the next element on the vehicle's own route, with the gap summed across elements (looking ahead at most 2 elements or 150 m).
  3. A virtual **stationary leader** at the stop line whenever the arbiter refuses entry (§5.4).
  4. A virtual leader at `destS` on the last edge.
- **Update** (ballistic, stable at h = 0.2 s):

```
acc  = a·[1 − (v/v0)^4 − (sStar/gap)^2],  sStar = s0 + v·T + v·dv/(2·sqrt(a·b))
v'   = v + acc·h
if v' < 0: s += v*v/(2·(−acc)); v' = 0          // stops inside the step
else:      s += (v + v')/2 · h
s = min(s, sLeaderTail − 0.1)                    // never overlaps
```

- **Hand-over.** When `s ≥ elemLen`, the vehicle unlinks, advances its cursor, sets `s −= elemLen`, and links at the **tail** of the next element. At most 4 hand-overs per sub-step, which is enough for short connectors.
- `v0` and `limit` are cached on entry to each element.

### 5.4 Junction entry rules (`JunctionArbiter`)

**When the decision is made.** Once the vehicle is within `dDec = max(v²/(2b) + 5, 12)` m of its lane's stop point. The next connector's role and the node's control decide.

**Conflicts.**
- "A conflicting connector is **occupied**" means some vehicle on it has not yet passed the conflict point.
- "An **approaching** conflict" means a vehicle on a conflicting approach lane with `ETA = distToEntry / max(v, 0.5)` below the gap for this control.

**The opposing-left gap, at every control.** A left connector crosses the opposing carriageway. That includes a far-side driveway left-in or left-out (§3.10). It may enter only when:
- no conflicting connector is occupied; and
- no vehicle on an opposing approach lane it crosses has ETA < 4.0 s.

At signals this is the permissive left. It applies equally at stop and priority legs, at uncontrolled nodes and at driveways. A driveway left-out also needs that gap in every lane it crosses and in its target lane (§5.5). **A far-side left-in takes the opposing gap at the arrival gate** (site-access §7.4 G2, their ask 14): no ENTER while an opposing vehicle's ETA at the crossing is below 4.0 s, using `canJoin`'s `fromLeft` predicate; the ETA part is waived after 25 s, as a counted forced grant.

**Signals:**
- Green: go, subject to the box check, the opposing-left gap for lefts, and pedestrians.
- Amber: go if `v²/(2b) > distance to the line` (the dilemma rule), otherwise stop.
- Red or all-red: stop.
- A left-turner already waiting at the line may clear on amber if its conflict set is **unoccupied**.

**All-way stop.** The vehicle must come to rest (`v < 0.3`). Vehicles then go in **arrival order** `(arrivalUs, handle)`, from a per-node FIFO of up to 16 entries, provided no conflicting connector is occupied.

**Stop (minor legs) and priority:**
- Stopping legs halt, then accept a gap. The gap needs every conflicting higher-rank connector (`RoadTier.rank`, parcel.dart:471-481) unoccupied, with no approaching vehicle at ETA < 4.0 s.
- Priority legs go subject to the box check, an unoccupied conflict set, and, for lefts, the opposing gap.
- **A leg outside the plan** (an alley or a path, §3.7) gives way to every drawn leg at every control. It halts at its line and takes a gap as a stopping leg does, against every conflicting drawn connector whatever its rank. Among themselves such legs follow the uncontrolled rules below. The arbiter reads `RoadNode.plan` as it is and computes no plan of its own (D48).

**Uncontrolled nodes** (`uncontrolled`, §3.2: three or more legs, fewer than three of them drawn, such as a street seam with an alley):
- Legs outside the plan give way to drawn legs first (above).
- A lower-rank approach yields to a higher-rank one.
- Among equal ranks, the right-hand rule applies: yield to conflicts coming from the right.
- Lefts also take the opposing gap.
- Two-leg continuations have no conflicts except drops and merges, which follow the next two rules.

**Ramp merge.** The ramp connector yields to mainline lane 0. It enters when the gap behind the mainline tail is at least `s₀ + v·T` and that follower's ETA is at least 2.5 s. Otherwise it waits at the gore.

**Continuation with a dropped lane.** A `dropped-lane` connector yields to the aligned connector feeding the same out-lane: a zipper with a 2.0 s gap.

**Roundabout.** Every entry yields to occupied conflicting connectors of the same node, i.e. the circulating traffic. No ring geometry is modelled.

**Pedestrians** (slice T4b). A connector is refused while any crossing it passes is **occupied**, or while a pedestrian is **stepping on** to it. Stepping on means committed (§8.3): the walker is on the crossing edge or started it this sub-step. A pedestrian waiting at the kerb does not count. So right-turners on green give way to walkers, and a stopped car and a waiting walker cannot deadlock each other.

**Don't block the box** (knob `dontBlockBox`, default on). Entry requires the **exit** lane to have `freeTail ≥ len + s₀`, or its tail vehicle to be moving faster than 3 m/s.

**Forced priority** (the deadlock breaker). Once `waitT > impatientGrantS` (default 25 s) and the box check passes, the ETA part of the gap rules is waived. The vehicle still requires no *occupied* conflicting connector. Every forced grant is counted.

`arbiter_safety_property_test` checks that two conflicting granted connectors are never both occupied short of their conflict point.

### 5.5 Lane changes: only through connectors, or at an access point

- `elem` changes only when the vehicle hands over to its next route element, and consecutive elements are always joined by a connector. So no vehicle ever moves to a sibling lane of the same edge.
- **The two exceptions are the access events EXIT and ENTER** (site-access §7.4), logged at an access point, which acts as a node for lane choice:
  - **EXIT.** Leaving an access point, the vehicle enters a lane of `A₁` at `s = accessS`. The arbiter checks for a gap in every lane from 0 up to its target lane. A far-side left-out also needs the opposing-left gap in every opposing lane it crosses (§5.4). A site's out-join logs EXIT on a `canJoin` grant; a home back-out logs it when the car's rear crosses the kerb line (§7.5).
  - **ENTER.** Arriving, it leaves the carriageway from its locked destination lane. A site's in-join logs ENTER on a grant at the arrival gate (§7.3).
- Property test (§17.2): at every sub-step, for every vehicle, `laneEdge(elem_t) == laneEdge(elem_{t−1}) ⇒ elem_t == elem_{t−1}`, unless an access event is logged.
  - **Site elements (from T4a).** A road↔site element change is legal only with a logged event whose `(edge, T ± 1.5 m)` is that join's, and whose lane is `destLane` (ENTER) or inside `canJoin`'s target set (EXIT; for a home back-out, its target lane). Inside a site, the site lane changes only through site-access §2.5 movements or stall manoeuvres.

### 5.6 Stuck detection and despawn

- **Measuring.** `stuckT += h` while all of these hold:
  - `v < 0.1`;
  - no hand-over happened in the step;
  - the state is `driving` or `parkingSearch`.
  It resets once `movedSinceReset > 1 m`.
- **Frozen states.** `stuckT` does **not** accrue:
  - in `dwelling`, which has its own completion rule: a service stop's dwell time; a fire engine staying until the lot's fire is out or burned out (§9.4); a bus or train dwell (§11.3, §11.7);
  - in `holdAtEdgeEnd` while its re-plan request is still queued (§3.9).
  So a fire engine fighting a large fire for 300 s, or a bus boarding a crowd, is never despawned.
- **Despawn** at `stuckDespawnS = 120` s of agent time (a knob, 30–600): "despawning hides mistakes". The vehicle is unlinked, its reservations freed and its route block returned.
- **Accounting.** `stats.despawnStuck` and `edgeStuckCount[e]` go up; the latter feeds the red dots in the traffic view. No `DomainEvent` is raised, because the event list is capped at 64 per frame (simulation_view.dart:1758).
- **What happens to the owner:**
  - **Citizen:** placed at the destination, and the trip counts as **failed** (§6.2 commute efficiency).
    - Their car is **garaged**, exactly as in a parking give-up (§7.3 step 5). It becomes a virtual row that is never drawn and takes no kerb or lot space.
    - It reappears at the destination's access point when the citizen next leaves.
    - It is never put into a real slot without a search.
  - **Visitor:** the car and the visitor row are removed, counted in `stats.visitorsLost`.
  - **Service vehicle:** its unserved requests are re-queued **with their original stamps** (D12), and its payload is lost. Accumulators of buildings it did not reach keep growing: a stuck truck means uncollected garbage.
  - **Freight:** the cargo is lost, and an import's price is not refunded.
  - **Bus or train:** passengers are placed at their destination stops as failed trips, and the line respawns the vehicle at its depot.

### 5.7 Time-warp policy and the frame hold

- **Up to 25×:** agents run at real speeds in lock-step with the economy.
- **Above 25×:** `CitySim.advance` clamps dt to 0.5 s (city_sim.dart:1178). The whole colony, economy and agents alike, therefore falls behind world epoch by the same amount. This split already exists: shuttles run on world epoch (advance_simulation_tick.dart:565-597). No agent mode changes, and there is no coarse step.
- **`eventSimWarp`** (0.4–2.1) scales dt before it reaches us, as it does for everything else.

**The frame hold (D35).**
- **The problem.** The host runs up to 25 ticks in one frame when time has piled up (simulation_view.dart:1934-1950; fixed step 0.02 s, simulation_clock.dart:27). At 25× or more each tick is dt 0.5 s (simulation_clock.dart:31). So one catch-up frame can owe 12.5 s of city time: about 62 sub-steps, ≈ 50 ms at the §15.1 cost per sub-step. A long frame then owes more ticks, which feeds the step spiral.
- **The hold.** The host marks an agent colony with `agents.frameBudgeted = true`; `SimulationView` does this for its injected City Builder colony (E26).
  - Every `CitySim.advance(simDt)` of that colony is then **queued whole** by `holdTick` (E3b) instead of run.
  - After the tick loop the host calls `agents.endFrame()` (E26). It replays queued ticks, oldest first, while the frame's budget of `maxAgentSubStepsPerFrame = 4` agent sub-steps allows, counting each tick's sub-steps exactly from `accumUs`.
- **Determinism.** The economy and the agents advance together, through exactly the same sequence of `advance(simDt)` calls as without the hold; only the wall-clock time at which each runs differs. So every result is identical, and `frame_hold_invariance` (§17.4) pins it.
- **Lag.** The city runs behind world epoch by the queue, as it already does above 25×.
  - At 25× and 60 Hz, demand is about 2.08 sub-steps per frame, so a queue drains at about 1.9 extra sub-steps per frame. A 25-tick hitch clears in about 0.5 s.
  - In steady state the queue is empty at every capture, because `endFrame` runs before the frame is captured.
  - World systems that read the city inside the tick loop see it as of the previous frame's end: at most one frame of lag.
- **Overflow.** If the queue holds more than `maxHeldCityS = 10` s of city time, `endFrame` drains all of it that frame. That is a hitch but never a drop, so determinism still holds.
- **Hosts and tests that never set the flag** run every tick inline, exactly as today.

**Cold start.**
- The generator's single `advance(0.1)` (city_generator.dart:472) and `fromJson` spawn nothing. A generated colony gets agents only in slice 11, after generation. A restored colony starts its spawn ramp.
- `warmupS = 10` s ramps `maxSpawnsPerStep` from 0.

**Pause** (warp 0) runs no ticks (simulation_view.dart:1940), so the agents freeze exactly.

### 5.8 Deadlock avoidance, summarised

1. Don't block the box (§5.4).
2. Forced priority after 25 s.
3. Stuck despawn at 120 s, never while dwelling or held for a re-plan.
4. **Wedge breaker:** if at least 3 approach heads at one node each have `waitT > 60` s, the one with the largest `waitT` is despawned (ties go to the smaller handle) and counted in `stats.despawnWedge`.
5. **Structural.**
   - No connector joins an edge back into its own start node, except at dead ends, stubs, roundabouts, and a ring piece's continuation, where `from == to` (§3.2).
   - An all-way stop's FIFO is capped at 16.
6. Waiting pedestrians get priority after 20 s, and walkers give up after 300 s without progress (§8.3).
7. **Site access (from T4a).** `sharedSingle` throats are one claim unit, with opposite claims refused and ties by (sub-step, handle) (site-access §7.4); arrival-gate forced grants and give-ups (§7.3); the home back-out's serialised claims, inbound priority and tandem shuffle (§7.5).

---

## 6. Citizens and trips

### 6.1 The time-scale decision

- **Vehicles move at real speeds.** City Builder opens at 1× (simulation_view.dart:1623), so cars must look right there: a street's 40 km/h is 11.1 m/s.
- **The colony's day** is `dayLengthSec` (city_sim.dart:1150): 120 s for an Earth-like rotation, scaled by the body's rotation to 20–1200 s. A 1.5 km commute takes about 140 s, longer than an Earth-like day.
- **So activities run on dwell timers in agent seconds, not on `dayPhase`.** `dayPhase` only *modulates* departure rates, as rush-hour flavour:

  ```
  rush(φ) = 1 + 0.6·(bump(φ; 0.30, 0.05) + bump(φ; 0.72, 0.05))
  ```

  - `bump` is a 64-entry table of a Gaussian, so no `exp` runs in the tick.
  - `rush` multiplies home→work and work→home wake-ups.
  - It is normalised so that daily throughput is unchanged.
- **Calibration.** The `activityDwellScale` knob, default 1.0, sets the steady-state number of moving vehicles. The calibration test (§17.3 #15) pins it at 8–12% of population.

### 6.2 Population, citizens and the one-tick contract

**The field.** `CitySim.population` stays the value every reader reads: milestones, tax, research, RCI, the HUD, laws. `agents.ownsPopulation` switches on with the citizens slice (3) for colonies with agents enabled.

**The `PopulationLedger`** holds four fractional budgets:

| Budget | Fed by |
|---|---|
| `migrationBudget` | E9. Migration (city_sim.dart:1564-1576) is computed exactly as today, but only its **delta** is added. |
| `deathBudget` | E8. `died` from 1482. |
| `externalBudget` | Any change to `population` the agents did not make: a revolt (1853), disasters (2298-2448), a relief crew (4952), a test setting `city.population = 200`, a save load. At the start of each `agents.advance`, `ext = population − lastWrittenPopulation` is added here. |
| `pendingFraction` | The part of each budget smaller than one person |

**Realisation,** on each sub-step in which a budget holds a whole person:

- **Arrival (+1): spawn a citizen.**
  - Home: a building with a vacancy, drawn by `TrafficRng` weighted by vacancy, in stable building order; `home = −1` (homeless) if there is none.
  - Entry point: drawn between the spaceport and the resolved stubs. The spaceport is weighted by `padCountOf` (city_sim.dart:4729-4733), each stub by `2·classFactor(stub)` (§10.4).
  - The citizen starts `movingIn`. That is either a car trip from a stub to the new home (an inbound stub vehicle that parks at home, §7.3, §10.4), or a walk from the pad's access point (a rover on sealed worlds). They **count in population from the moment they are spawned**.
  - At most `max(4, 0.02·count)` spawns per sync; the rest waits in the budget.
- **Departure (−1): remove a citizen.**
  - Order: the homeless first, then the unemployed, then a random pick by `TrafficRng`.
  - If a car-owning emigrant can reach a stub, they drive out on a `leaving` trip, which is outbound stub traffic (§10.4). Otherwise they walk to the pad and vanish there.
  - They count as gone immediately.
- **Death (−1):**
  - A resident is picked in building order, weighted by `residents`, and `corpses[home] += 1` (served by hearses from slice 5). The citizen is removed.
  - Homeless deaths go to the `sleepsNear` building.
  - Before slice 5, deaths still remove citizens, but corpses stay on the scalar path (E8 inactive for deathcare).
- **Write-back.** At the end of `advance`: `population = citizens.liveCount + ledger.pendingFraction`, and `lastWrittenPopulation` is set.

**Hard invariants** (property test):
- `Σ residents ≤ Σ housing` after each sync, where housing is the tick's per-building `(x*uf).round()` sum.
- `Σ workers ≤ Σ jobs`.
- When a building's utilisation drops, excess residents are evicted to homeless in reverse arrival order.
- `homeless` (city_sim.dart:1808) is still computed by `socialTick` as `pop − housing`, which matches because unhoused citizens exist.

**Parity.** `population_parity_test` runs 10 agent-minutes of growth and asserts that `population` stays within ±5% of the integrated scalar budget at every sync. The only lag is the spawn cap. `forgiveness`, the food-security target and the spaceport gate at 1564 are untouched.

**The one-tick contract.**
- Everything `CitySim` reads from the agents was published at the end of the *previous* `agents.advance`: `stats.commuteEff`, the derived scalars, the service rewrites, the incomes.
- Everything the agents read from `CitySim` comes from the tick in progress: `throttle` (1252), budgets, and `services` for health gating.
- §12 lists every value. The lag is the same one `parcelCongestion` has today: computed at 1677, read at 1244.

### 6.3 Housing and job assignment

- **Housing.** Citizens get a home at spawn (§6.2). Homeless citizens are re-housed once per sync: up to 64 moves, in citizen slot order, into vacancy-weighted buildings.
- **Jobs.** Once per sync, up to 64 unemployed citizens with a home are matched, in slot order.
  - **The skim is the citizen's own mode.** A car owner uses `skimCar(zone(home), zone(job))`. A citizen without a car uses `min(skimWalk, skimTransit)` (§4.9), so nobody is given a job only a car could reach.
  - The job chosen is the vacancy with the smallest skim. Candidates within 30 s of the best are tie-broken by `TrafficRng`.
  - Before skims exist (slices 3–4), straight-line distance stands in: divided by 12 m/s for car owners, and by 1.3/1.35 m/s for everyone else.
- **Job loss.** Workers lose their job when a building's `jobs` falls below `workers`: last hired, first out.
- **The workforce scalar** `workforce = min(pop, jobs)` (city_sim.dart:1238) stays until slice 10 (§12.3).

### 6.4 The activity loop

| From | Dwell (agent s) × `activityDwellScale` | Next | Probability |
|---|---|---|---|
| atHome, employed | U(150, 420) ÷ rush | commute → atWork | 0.85, else an errand |
| atHome, unemployed | U(200, 600) | errand | 0.5, else stay home |
| atWork | U(240, 540) ÷ rush | → home | 0.8, else errand, then home |
| atErrand | U(40, 120) | → home | 1.0 |
| outOfTown | U(600, 1800) | → home, from a stub | 1.0 |

- **Errand destinations:** a commercial building (from slice 8, only those with goods), a park or leisure site, or a civic building. Picked with weight `1/(1 + skim/180)`.
- **Out-of-town errands** (from slice 8, when at least one stub is resolved):
  - A car owner's errand goes out of town with probability `outOfTownShare = 0.08`: a car trip to a stub drawn by `classFactor`.
  - The citizen then spends the `outOfTown` dwell off the map. The car is with them, not parked.
  - They come back by a trip home from a stub drawn by `classFactor`, and park at home.
  - These are the colony's outbound and inbound resident cars (§10.4).
- **Mode** is chosen at every departure (§4.9). A car trip needs the citizen's car at their current location. A citizen who drove to work drives home; one who walked or took transit cannot use the car until they are home again.

### 6.5 Trip generation rates and caps

- **Steady state:**
  - 2,000 citizens, 60% employed, 75% owning a car, 85% choosing the car.
  - One commute cycle ≈ 915 s (285 home + 120 commute + 390 work + 120 return).
  - So there are 0.6 × 0.75 × 0.85 / 915 ≈ **0.00042 outbound car commutes per resident per second**, ≈ 0.84 per second across 2,000 residents. With the return trips that is ≈ 1.7 car trips/s. At a ≈ 120 s mean trip length, ≈ 200 cars are moving, which is **10% of population**, before errands, services and freight.
- **Caps:**
  - `maxSpawnsPerStep = 24` vehicles and 24 pedestrians. Wake-ups beyond that roll into the next sub-step, in wheel order.
  - `maxVehicles = 4096`, of which 10% is reserved for services, transit and freight.
  - `maxPeds = 4096`.
  - `maxQueuedPaths = 512` for car trips, and `maxQueuedServicePaths = 128` for the reserved lane.
  - Over any cap a trip is **deferred**, never teleported (D10).

### 6.6 Car ownership

- **At arrival:** `hasCar = rng < carOwnership`. The default is 0.75 on breathable worlds and 0.6 on sealed ones, where the vehicle drawn is a rover (city_traffic.dart:520).
- **Where a new car goes:** a parked car at home, in the home lot if it has room, otherwise at a kerb slot within 150 m, otherwise `garaged` (a virtual space that is never drawn).
- Buying and selling cars is out of scope.

### 6.7 `CommuteSynth`: synthetic demand for slices 1–2 only

Until citizens exist, `CommuteSynth` stands in:
- Each **built, served** residential lot with housing `H` emits outbound commute trips at **`0.00042·H` per second**, the §6.5 rate per resident.
- The destination is drawn by `TrafficRng`, weighted by `jobs`, among built job lots. The return trip follows after U(240, 540) s.
- There is no car ownership or parking: vehicles appear at the origin's access point and vanish at the destination's.
- Trips target building ints. A road edit that renames lots carries them through E12–E14, which land in slice 1.
- The deferral rules and the spawn ramp apply.
- Completed trips feed `tripRatio` and `failedShare`, so `commuteEff` (E4) is measured from slice 1.

`CommuteSynth` is deleted when slice 3 lands.

---

## 7. Parking

### 7.1 Capacities

**Kerb slots** exist only on edges where all of these hold:
- `RoadType.of(road).hasParking` (road_catalog.dart:92-94);
- the class is not `RoadClass.highway` (road-agent trap 11);
- the road is not `sealed`.

```
kerbCap = max(0, floor((edgeLen − stopBack(from) − stopBack(to) − 12) / 6.5))
```

- On a two-way road, each directed edge owns its **right** kerb.
- On a one-way road, the single edge owns both kerbs.

**Lot spaces.** From T4a, `lotCap = stallCount` of the site's network plan (`SiteAccessPlan.capacity`), and 0 for a kerbside plan. `lotUsed` counts parked cars plus binding reservations. A network plan with `stallCount == 0` is a legal drop-off-only site.

The table below is therefore no longer a capacity. It becomes the road generator's target, which the road side sizes from `parkingSpaces(spec)` (site-access §3.3); only the stall count is contractual. Until T4a it is the capacity:

| Building | Spaces |
|---|---|
| residential | `housing / 3` |
| commercial | `jobs / 2 + 8` |
| industrial | `jobs / 3` |
| civic or utility | 12 |
| `claimsOwnSite` installation | 80 |
| spaceport | 200 |

The lot's entrances are its in-capable joins (§3.10).

### 7.2 Where parked cars sit: no overlap with moving cars

A street is 8 m wide: one 4 m lane each way, lane centres at ±2.0 m (parcel.dart:262-266). A 1.85 m car centred in the lane spans 1.075–2.925 m. The naive kerb slot at `halfWidth − 1.1` overlaps it by about 0.95 m.

The rule, applied **only when rendering**:
- **Parked car** centre at `halfWidth − 0.35` m: a wheel up on the kerb, spanning 2.725–4.575 m.
- **Moving vehicles** in the kerb lane of an edge with kerb parking are drawn 0.25 m inward of the lane centre, spanning 0.825–2.675 m.

Result:
- 5 cm clear between moving and parked cars.
- 1.65 m between opposing moving cars.
- The street furniture band starts at `halfWidth + 3·0.22 = 4.66` m (street_furniture.dart:58-66), 8 cm clear of the parked car.

### 7.3 Search on arrival (CS-style)

Nothing is reserved at plan time. A car trip ends at the destination's access point, in its locked destination lane, and then searches **in this order**:

1. **The destination's own stalls** (revision 4, site-access §7.4–§7.5), if the destination has a network plan current for the graph (§3.10), the arrival join is in-capable, and a stall is free.
   - The stall is reserved **at the arrival gate**: the first free stall in `stallOrder[j]`, precomputed at site sync by site-path length from the join's in-lane, ties by index. **The reservation is binding.**
   - The gate grants when the throat in-lane has room for the car, no outbound `sharedSingle` claim is held, a far-side left-in has its opposing gap (§5.4), and the car is at ≤ 3 m/s. A refused car is held at `destS` by its virtual leader. After 25 s the ETA part is waived (a counted forced grant); after 30 s refused on throat room alone, the car releases the stall and goes to step 2.
   - On the grant it logs ENTER (§5.5), turns in from its locked lane (right-in, or a far-side left-in), drives the site under IDM and parks forward-in (nose-in) with a scripted final curve that ends exactly on the stall pose.
   - A kerbside plan (`lotCap = 0`), an in-incapable join or a full lot goes straight to step 2, and this lot is never retried on this arrival. Other sites' lots are never searched (`kPlanPublic` is reserved).
2. **Kerb slots ahead on the arrival edge**, within 60 m, on the kerb its lane serves: lane 0 → the right kerb; lane `L−1` on a one-way road → the left kerb.
   - **Kerb masks (from T4a).** A slot is skipped when `KerbCuts.blocked(cuts, side, s_i, halfLenM: 3.25)` holds for a cut join of a live network plan. The slot's travel arc and right-of-travel side are first converted to the canonical index arc and `joinRight` side (`s = T` on a forward edge; `s = L − T`, side flipped, on a backward edge; site-access §5.5). The owning kerb follows D7. Masks update on `sitesRev`, and a car on a newly masked slot relocates as a car on a vanished stall does.
3. **Adjacent edges.** A breadth-first search over the directed edges leaving the arrival edge's end node: up to 800 m of network distance, at most 64 edges, in deterministic edge-id order. Each free slot is scored `walkDistance + 10 × BFS rank`, with the walk distance measured on the pedestrian graph.
   - **A slot found in step 2 or 3 is reserved, and the reservation is binding.** Its bit is set at once, so no other car can take it, and a car never finds its reserved slot taken.
   - A **parking leg** is appended (§4.6). It is a fixed-start plan (§4.5) from the car's `(edge, lane, s)` to `(edge, slotS)`. Its destination lane set is `{0}` for a right-kerb slot and `{L−1}` for a left-kerb slot on a one-way road.
   - If a network edit removes the slot's edge while the car is on its way, the remap fails. The car searches again from where it is, and that does not count as a circle.
   - `stats.parkWalkM` records the walk distance.
4. **Circling.** If nothing is free within 800 m:
   - `parkTry += 1`, and a loop leg (a fixed-start plan) is appended to an edge 150–300 m away drawn by `TrafficRng`.
   - On reaching it, the car searches again from step 2. Step 1 is retried only if the loop ends on the edge of one of the destination's in-capable joins.
   - This adds real vehicle-kilometres and congestion.
5. **Give up** when `parkTry` reaches 3, i.e. when the third circle also finds nothing.
   - The car is `garaged` at the destination: removed from the world, not drawn, holding no slot, and counted in `stats.parkingGiveUps`.
   - The citizen walks from the car's current position.
   - When the citizen next leaves, the car reappears at that building's access point.

**After parking,** the citizen spawns as a pedestrian from the slot or stall to the building's entrance (`entrancePt`/`entranceNode` for a site with a plan). The walk is skipped (instant) when it is under 15 m.

**Staging (revision 4).** T4a runs steps 1 and 2 only and garages what they cannot place; the walk from the car is an instant placement. T4b brings steps 3–5 (adjacent edges, circling, give-up) together with the pedestrian graph, so the walk-scored search of step 3 never runs without one.

### 7.4 Parked cars as entities, and how they are drawn

- **Rows.** A `ParkedCarTable` row is created when a car parks and deleted when it leaves. `parkedRev` is bumped each time. A lot car's row is `(site, stallKey, variant, owner)`, created when the stall manoeuvre ends and the vehicle row is freed.
- **The frame** carries parked-car columns only when `parkedRev` changes, at most at 0.5 Hz:
  - kerb cars as `(edge, side, s, variant)`;
  - lot cars **on plan stalls, under `sitesRev`**: `ParkedColumns` gains `sitesRev` and lot rows `(lotSite, lotStall, lotVariant)`, where `lotSite` is the site's ordinal in `CitySiteFrame` order and `lotStall` the stall index in the plan of that `sitesRev` (site-access §7.5).
- **Drawing.**
  - Kerb cars are placed by the pose pass on the edge geometry, at the lateral in §7.2.
  - Lot cars are drawn at the stall pose (`stallE/N`, nose along `stallDir`) at the `CitySiteFrame` height `stallUp`, only when the columns' `sitesRev` matches the frame's; otherwise the layer holds its last publish once. No lot geometry is derived in `agent_nodes.dart`.
  - One instanced slot per model is rewritten only when the columns change.
- **Baked parked cars go in two stages (E36).**
  - **T4a:** traffic publishes the agent-managed site ordinals, and `CitySiteFrame.agentManaged` makes the road side's R6 baking skip those sites. Home pads and kerbs keep baked cars.
  - **T4b completes it,** as the rest of this list describes.
  - Baked kerb cars follow `CityNodes.onStreetParking` (city_tile_mesher.dart:1718-1727).
  - Baked lot cars follow the parked-car ceiling (`_carBudget = knobs.maxParkedCars`, city_tile_mesher.dart:815 and 1379-1404), which E36 turns into the settable static `CityNodes.maxParkedCars`.
  - Both are read only when a tile request is built (city_nodes.dart:612-624), and neither is in the base-tile key (D32). Flipping them later would leave already-built tiles as they were.
  - So from T4b E26 sets `onStreetParking = false` and `maxParkedCars = 0` **before the first frame** of an agent colony. City Builder hands its colony to `SimulationView` before any tile is requested.
  - A mid-session enable (the drawer button, §19.2 Q6) calls `CityNodes.invalidate()` once, paying one full re-cut and re-stream.
  - `dispose` restores both.
  - From T4b, every parked car drawn in an agent colony is an agent.
- **Rendering caps:** `parkedRenderCap = 1500`, within 1.5 km of the focus.

### 7.5 Home driveways: cars back out into the street

**User decision** (site-access §10.2 Q3, changed 2026-09-15). On a home driveway (program `homeDriveway`) a car drives in forward and parks nose-in, and leaves by **backing out into the street**. Car parks, yards and installations keep forward-out departures through their throats: reverse out of the stall inside the lot, wait 1 m inside the kerb line, EXIT on a `canJoin` grant (site-access §7.4). This section is traffic's side of the home rule.

**Arrival.** Through the arrival gate like any site (§7.3 step 1), up the driveway forward, nose-in into a stall. Tandem stalls fill **deepest free stall first**.

**Departure.**
1. The road route is planned first, from the join's `(edge, T)`; the car stays parked during the search.
2. **Target lane:** the near-direction kerb lane. On a 1+1 undivided street, where `joinDirs` allow the far direction, it may be the far lane, with the near lane crossed.
3. **Gap acceptance**, checked before the reverse starts. All of these must hold:

   | Rule | Value |
   |---|---|
   | Footprint on the target lane | `[T − 10 m, T + 2 m]`, along the target lane's travel |
   | Bodies | none in the footprint, and no queue within 15 m upstream of it |
   | Approaching vehicles | ETA to the footprint ≥ 8 s, with ETA = distance / `max(v, 5 m/s)`; ≥ 10 s when crossing to the far lane |
   | Opposing lane (1+1 streets) | also free of bodies within `[T − 6, T + 6]` |
   | Next same-direction lane (avenues, 2-lane one-way streets) | the ~5 m tail swing overhangs it: free of bodies within `[T − 6, T + 6]`, and approaching vehicles' ETA to `T − 6` ≥ 8 s (same speed floor) |
   | Forced grant | after 120 s of waiting, waives only the ETA rules, down to a 6 s floor; never with a body in any checked interval; counted |

   The footprint is measured from `T` whichever stall the car left: side-by-side stall axes sit ±1.3 m from `T` on a 5.2 m drive, and the scripted arc always ends on the target lane. Home stalls on the pad axis are `inline` (an appended `StallAngle`): the stall links the pad's forward and backward lanes as a reverse-only movement, and the pad end is the one dead end a plan may have without a turnaround (site-access V7, V9; 42d1c53).

4. **The manoeuvre.** The car reverses down the driveway and, at the kerb line, swings its tail upstream onto the target lane in one scripted arc (D27). It stops for 0.5 s, then drives off forward.
5. **EXIT is logged when the rear crosses the kerb line** (§5.5). From then the car is in the target lane as a reversing vehicle, flagged `reversing` on the wire (§13.1), and followers treat its footprint as a stopped obstacle. A far-direction departure also holds a claim on the near-lane footprint until it drives off.

**Where home driveways exist** (the road side's generator enforces it; traffic relies on it):
- minor-tier roads at ≤ 40 km/h, in both allowed directions;
- avenues (50 km/h), near direction only;
- no `homeDriveway` on roads above 50 km/h or on divided roads.

**Deadlock rules:**
- Overlapping back-out claims (neighbouring driveways whose footprints overlap) are serialised by (sub-step, handle).
- An outbound car that has not committed yields to an inbound car held in its footprint.
- Tandem stalls are assigned LIFO. If a deeper car must leave while the outer one stays, it waits; after 120 s the outer car is shuffled to a free kerb slot (counted).
- A back-out yields to pedestrians on the pavement crossing (T4b).

**Test.** `home_back_out_test` replaces site-access A9 (`home_pad_hammerhead_test`): 2 stalls; both directions on a 1+1 street; a 60 s kerb-lane stream; the inbound/outbound conflict; a tandem shuffle. It asserts no EXIT with a body in the footprint, and no deadlock over 600 s at 10× rate.

**Pending on the road side.** The rewrite of site-access §3.4, the home rows of V9, §7.4's departure and A9 to this rule. The geometry guarantees are theirs: a window margin of ≥ 12 m upstream for `homeDriveway` joins, kerb masks of `[T − 12, T + 3]` around them, and side-by-side stalls preferred, with tandem at most 2 deep.

---

## 8. Pedestrians

### 8.1 The pavement graph (`PedestrianGraph`, built with the lane graph)

- **Pavements.** For every road with `hasPavement && paved && !sealed` (the renderer's walked predicate, city_tile_mesher.dart:1634), the graph has **two** undirected pavement edges, left and right, at a lateral of ±(halfWidth + 2.3) m.
  - That is inside the 3 m raised pavement (road_mesher.dart:853-908), and outside the street-furniture band at 0.66–1.65 m from the kerb (street_furniture.dart:58-66).
- **Sealed roads.** One tube edge on the **right-hand side only**, at `halfWidth + 1.7 + 1.0` (pedestrian_tube.dart:57). Walkers use the tube in both directions.
  - Buildings on the far side reach it through node crossings, which are drawn as nothing (an underpass).
- **Paths** (`RoadClass.path`) are walked along their centreline. **Alleys** are walked on the carriageway, at 1.5× cost.
- **Corner nodes.**
  - At each lane-graph node there is one corner node between each pair of adjacent legs, sorted by heading.
  - Pavement ends pull back to the corner at `halfWidth × 1.45 + 5.5` (city_tile_mesher.dart:1629).
- **Crossings.** One crossing edge spans each junction leg, joining the corners either side of it. Its length is the leg's width plus 2 m.
  - At `signals` nodes the crossing walks on the parallel phase. Zebras are drawn only there (road_mesher.dart:1402-1411).
  - At stop, none and roundabout nodes it is uncontrolled. The crossing exists in the graph even though nothing is drawn, as in CS1.
- There are **no mid-block crossings and no jaywalking.**
- **Building entrances** are points on the pavement edge on the building's side, at `accessS`. Manual sites use their gate.

### 8.2 Walking legs

- **Search:** A* on the pavement graph. Cost is length / 1.3 m/s, plus 10 s per uncontrolled crossing and 15 s per signalised one. It shares the path queue on the pedestrian budget.
- **Movement:** constant speed `1.3 × U(0.85, 1.15)` m/s, drawn once per leg. Pedestrians pass through each other (not modelled, as in CS1).
- **Legs that exist:**
  - home or work to parked car, and back;
  - a whole walk trip;
  - to a stop or station at departure, and a transfer or egress walk appended at alighting (§4.9);
  - spaceport arrivals walking in.

### 8.3 Crossings and the vehicle/pedestrian conflict

- **Signal crossing.** A pedestrian starts only when the walk phase (the green perpendicular to the crossed leg) has **at least 6 s** left, so nobody is stranded mid-crossing.
- **Uncontrolled crossing.**
  - A waiting pedestrian starts when no vehicle on the crossed leg's approach lanes, or on a connector that crosses it, has ETA < 3 s.
  - **After waiting 20 s** the pedestrian has priority and commits anyway. Vehicles then see an occupied crossing and yield (§5.4). A vehicle already past its stop point keeps going, and the walker's commit waits until that connector's conflict point is clear.
- **"Stepping on"** means **committed**: the pedestrian is on the crossing edge, or started it in this sub-step. A pedestrian waiting at the kerb is not stepping on. The vehicle rule (§5.4) refuses entry only for committed walkers, so a stopped car and a waiting walker cannot hold each other up.
- **Vehicles yield** to any occupied crossing their connector passes. This covers right-turners on green giving way to walkers.
- **Pedestrian give-up.** A pedestrian with no progress for 300 s is despawned: placed at the destination, the trip counted as failed, `stats.pedGiveUps`. With the 20 s priority rule this should not happen, and the counter shows it if it does.

### 8.4 Render cap

- In the simulation: at most 4,096 pedestrians.
- Drawn: `pedRenderCap = 800` within `pedRangeM = 600` m of the focus, filled nearest ring first.
- One instanced mesh, `PedestrianMeshes`: a 1.75 m two-box figure with no glazing. A walking bob comes from `phase = s / 0.7`, computed in the pose writer.

---

## 9. Services and dispatch

### 9.1 Calibration method (why these numbers)

Rates are per agent second. Two constraints must hold at once:

- **Parity.** Per-capita generation stays at today's rate where one exists. Garbage totals `CitySim.garbagePerPersonPerSec = 0.006` (city_sim.dart:326). One landfill processes `inputs[garbage] = 2.0 u/s` (city_building_spec.dart:365), which is enough for about 333 people. Keeping both keeps the difficulty curve.
- **Fleet throughput.** A fleet's collection rate `N·C / cycle` must reach at least the depot's processing rate over a **reference cycle**:

  `refCycleS = 2·1200 m / 9 m/s + stops·(dwell + 17 s)`

  Here 1200 m is a well-placed depot's mean trip, 9 m/s is street speed including junctions, and 17 s is one 150 m hop between chained stops.

What follows from the two constraints:
- A **well-placed** depot is limited by its processing rate, as today.
- A **badly placed** one is limited by collection, because its cycle grows. That is the CS "a badly placed depot floods a district" effect.
- **Deathcare is collection-bound by design.** The morgue, crematorium and cemetery process 1.5, 5.0 and 0.8 bodies/s (city_building_spec.dart:377-385), far above any fleet's collection rate. So hearse fleets are sized to the death rate instead (D13).
- Units stay abstract. A garbage "u" is today's stock unit, so capacities are large numbers.

`service_calibration_test` (§17.3 #16) pins the steady states. The constants live in one file, `service_calibration.dart`. The figures below are **targets**, to be re-tuned against the test and not hand-edited elsewhere.

### 9.2 Per-service table

| Service | Generated at, per agent second | Request at | Vehicle (`AgentKind`) | Capacity, dwell | Depots (fleet) | Reference cycle → throughput per depot | Served per depot at reference |
|---|---|---|---|---|---|---|---|
| **garbage** | `residents·0.0045 + workers·0.0025` u, which totals ≈ 0.006·pop at 60% employment (parity) | ≥ 24 u | garbageTruck | 240 u, 4 s | Landfill 4, Recycling Center 6 | ≈ 8 stops → 435 s → 2.2 u/s (landfill) / 3.3 u/s (recycler) | processing-bound: 333 / 500 people. At a 900 s cycle: 178 / 267 people (floods) |
| **deathcare** | `deathBudget` realised at homes (the §6.2 formula, unchanged) | ≥ 1 body | hearse | 10 bodies, 6 s; chains up to 10 stops | Morgue 8, Crematorium 12, Cemetery 4 | Bodies arrive one per home, so the reference is **6 stops of 1 body** → 405 s → 0.0148 bodies/s per hearse → 0.119 / 0.178 / 0.059 bodies/s | at 500 pop and disease 0.02 (0.1 deaths/s) a morgue runs at 84% |
| **police** | `occupants·4.0e-5·m_b` calls, × 0.6 under curfew | ≥ 1.0 call | policeCar | 1 call, 20 s on scene | Police Station 5 | 287 s → 0.0174 calls/s | at 400 occupants and m = 0.5, 0.008 calls/s (46%) |
| **mail** | `occupants·0.0006` u | ≥ 6 u | mailVan | 60 u, 3 s | Post Office 5 (**new**) | ≈ 8 stops → 427 s → 0.70 u/s | ≈ 1,170 occupants; 600 occupants run it at 51% |
| **health** | each resident falls sick at `disease·0.002`/s | a **count**: one request per waiting patient (`sickWaiting_b`) | ambulance | 1 patient, 8 s pick-up | Clinic 2, Hospital 6, Emergency Services 3 | 275 s → 0.0073 / 0.022 / 0.011 patients/s | at 500 pop and disease 0.02, 0.02 sick/s; a hospital covers 110% |
| **fire** | ignition `2e-6·hazard_b·(1 + pollution/200)`/s, drawn from `TrafficRng`; hazard is 1 residential, 1.5 commercial, 3 industrial | engines wanted: 1 at ignition, 2 above intensity 0.4, 3 above 0.7 (`fireWanted_b`) | fireEngine | none; stays on scene while the lot burns | Fire Station 5 (**new**), Emergency Services 3 | none | §9.4 |

**Definitions:**
- **Occupants** means residents for residential buildings, and the workers present (`present`) otherwise.
- **`m_b`** is `0.3 + unemployedFrac_b + 0.6·homelessNear_b`.
  - `unemployedFrac_b` is unemployed residents over residents (0 for a building with none).
  - `homelessNear_b` is the number of homeless citizens whose `sleepsNear` is b, over `max(1, occupants_b)`, capped at 1.
- **The fleet is scaled by staffing:** `fleetAvail = round(fleet × min(1, workers_b/jobs_b))`. Before slice 10 that is the global `staffing`.
- **Fleet upkeep:** 0.02 § per vehicle-second on the road, from slice 8, inside `agents.fundsRate` (E5b). Buses and trains carry their own upkeep (§11.3, §11.7).
- **Fire ignition is new in normal play.** Today a parcel lot ignites only from the fire disaster (city_sim.dart:4181-4187). Under the fire flag, `agents.advanceLotFires` also runs the per-building ignition above. That is a balance change (§19.1).

### 9.3 Requests and dispatch

1. **Request.** For the single-request kinds (garbage, deathcare, police, mail, goods), when an accumulator crosses its threshold and `requestMask` has no bit for that kind:
   - set the bit;
   - stamp `requestStampUs`;
   - push the building int onto `RequestQueue[kind]`.

   For **health** each waiting patient is one queue entry (`sickWaiting_b` counts them), and one ambulance is dispatched per patient. For **fire** the queue holds the building while `fireAssigned_b < fireWanted_b`.
2. **Dispatch** runs **on one sub-step per whole agent second** (`timeUs % 1e6 == 0`). It takes **at most 8 requests per kind**, in FIFO order.
   - The depot chosen is the one of that kind with `fleetAvail > out` that minimises **straight-line distance** × `(1 + 0.1·out/fleet)`.
   - Straight line is deliberate: it is the CS1 `TransferManager` rule. A depot that is close as the crow flies but far by road still wins the job, and its trucks then take the long way.
   - The knob `dispatchByPathCost` (default off) switches the score to a skim-based travel time.
   - The vehicle spawns at the depot's access point, runs a normal locked car trip, and the assigned mask (or count) is set.
3. **No road from the depot.** When the dispatched vehicle's search returns no path:
   - that depot is marked `noRoute` for that building for 600 s, and the request goes to the next depot by the same score;
   - with no depot left, the request backs off: `retryAtUs = now + 60 s`, its original stamp kept;
   - the Services drawer counts it as **unreachable**.

   A badly connected depot therefore never burns path budget every second.
4. **When the vehicle reserve is full** (§4.8), the request stays queued with its stamp and is retried next second.

### 9.4 Multi-stop runs, unloading and processing

- **Service happens only on arrival.** The vehicle stops **in its locked destination lane** at the building's `accessS` and dwells there, blocking the lane as in CS. That is lane 0 normally, and `L−1` for a far-side driveway or the left kerb of a one-way road. Then:
  - `load += min(acc_b, capacity − load)`;
  - `acc_b` drops by the same amount;
  - the request bits clear.
- **Chaining** (garbage, mail, and hearses up to 10 bodies).
  - While `load < capacity`, the vehicle takes the nearest **unassigned** open request of its kind within `chainRadiusM = 600` straight-line (≤ 16 candidates, ties by building id) and appends a new leg to it (a fixed-start plan, §4.5). This is the CS1 truck wander.
  - Otherwise it appends a leg back to the depot.
- **Unloading.** At the depot, `DepotTable.buffer += load`. The collected commodity goes to the depot's own buffer, **never the capped global stock** (D14).
- **Processing,** in `agents.advance`, per depot:
  - Garbage: the buffer drains at `spec.inputs[garbage] × throttle`. `throttle` is `CitySim.throttle`, set at city_sim.dart:1252 this tick. Recycler outputs (`ore 0.3`, `steel 0.2`) go into the global `stock`, scaled by the fraction drained, times `biomeMult`, `bountyMult` and `eventProductionMult`, as today at 1305-1306.
  - Deathcare: the buffer drains at `spec.deathcareRate` (city_building_spec.dart:84), which never binds.
  - Mail: sorted at the Post Office at 5 u/s (never binding).
  - E6 skips these specs in the production loops, so nothing is processed twice. It keeps their pollution, scaled by the drained fraction.
- **Police.** On arrival, `crime_b = 0`; the call's answer time (arrival − stamp) is recorded for `policeCoverage` (§9.5); then 20 s on scene, and the car returns.
- **Fire,** under the fire flag: `agents.advanceLotFires(dt)`, reached through E11.
  - **Growth:** `next = intensity + (kFireGrow − kFireSuppress·engines(id))·dt`, with `kFireGrow = 0.0025/s` (burn-out in about 6.7 min without an engine) and `kFireSuppress = 0.01/s` per engine on scene.
  - **Engines wanted** follow intensity (§9.2), and dispatch fills the difference.
  - **Burn-out** at 1.0 removes the building as today (`parcelBuildings`, `grownParcels`). A fire is put out at ≤ 0.
  - **Spread** to built lots within 30 m, with probability `next × 0.15 × 0.01 × dt` per neighbour per step, drawn from `TrafficRng` in lot-id order. Today's spread draws unseeded `math.Random()` (city_sim.dart:4223); this is what makes lot fires deterministic.
  - **Ignition**, per §9.2.
  - **Engines stay** until the lot's fire is out or burned out (their dwell rule; `stuckT` frozen, §5.6), then return.
  - Colonies without the flag keep today's step, including its reach factor, which reads `trafficReadout.fireReach` (4204). That counts only stations with safety cover (`TrafficRole.fightsFires`, road_traffic_model.dart:149-152), so a clinic's ambulance is no fire cover (1d2e78d). In an agent colony before slice 7 the answer is the routed model's in slice 1 and the agents' own from slice 2, by the same rule (D47). The existing fire test (parcel_growth_test.dart:171-194) is unchanged.
- **Health.** An ambulance takes the patient to the nearest depot that has a free bed (beds = `services.health / 20`: clinic 4, hospital 10, emergency 3). Treatment takes 60 s.
  - Treatment succeeds with probability `medCov = stockOf(medicine)/(medDemand + 0.01)`, which is the gate at city_sim.dart:1261-1272 recomputed over the building table.
  - Otherwise the patient goes home still sick, and counts ×5 in the death-assignment weights.
  - Medicine keeps flowing through the clinics' spec inputs in the production loop; health specs are **not** owned by E6.
- **Failure.** A despawned or stuck vehicle re-queues every unserved request it held, with the **original stamps**. Its payload is lost.

### 9.5 How the city scalars are derived (the HUD and happiness keep working)

`CityAgents` writes these at the end of `advance`, and E5, E34 and E35 read them. `CitySim` reads them on the next tick (the one-tick contract).

| Scalar | Derivation when the agents own the service |
|---|---|
| `wasteBacklog` | `clamp((Σ_b max(0, garbage_b − 24) + stock[sewage]) / max(1, pop × 2), 0, 1)`. This is the old normaliser (city_sim.dart:1415-1419) applied to overdue garbage only (D15). Sewage stays a global pipe scalar: it is still injected at 1413-1414 and drained by sewage plants. |
| `stock[garbage]` | Not written. Garbage lives in buildings, vehicles and depot buffers. The Stock panel shows 0; the Services drawer shows the buffers. |
| `corpses` | `Σ corpses_b + Σ hearse payloads + Σ depot buffers`. `liveHousing = housing − corpses` (1554), the disease term (1460), the happiness drag (1496-1498) and the miasma gate keep working. |
| `services['safety']` | **Replaced, not adjusted**, under the police flag (D37): `policeCoverage × pop`. |
| `crime` | Under the police flag the crime **target** comes from the accumulators (E35), and `crime = ease(crime, target, dt, 0.5)` runs as today. |
| `services['health']` | **Replaced** under the health flag: `needHealth × treatedShare600`. |
| `mailBacklog` (new, on `CityAgents`) | `clamp(Σ_b max(0, mail_b − 6) / max(1, occupants × 0.36), 0, 1)`. |
| `goodsShortage` (new, slice 8) | The jobs-weighted share of commercial buildings whose goods buffer is empty, as a 300 s EMA. |
| `happinessDrag` (E34) | `0.15·mailBacklog + 0.15·goodsShortage`. |
| fire suppression | Per lot, from engines on scene (E11) |
| `parcelCongestion` (3335) | Written by `advanceParcelTraffic`, unchanged, from the agents' readout: `0.5·(peak + average)` of measured congestion (§4.2, D46), from slice 1 |

**Safety.** Under the police flag, `services['safety']` is replaced outright.
- **Every passive safety term is retired:**
  - Police Station 220 (city_building_spec.dart:356-358);
  - Emergency Services 100 (493-496);
  - Barracks 150, Military Base 400, Gun Emplacement 120 and Airfield 200 (448-468).
- **`policeCoverage`** is a 600 s EMA of the occupant-weighted share of police calls answered within 300 s of their stamp.
  - With no calls in the window, it is 1 if the colony has a police depot with `fleetAvail > 0`, and 0 otherwise.
  - So a colony with no Police Station reads 0 from the first tick, and coverage rises only as police cars arrive.
- **Its readers** are `serviceCoverage` (city_sim.dart:2820-2829) and, while the fire flag is off, lot-fire suppression (4193-4195).

**Crime.** The target formula at 1822-1825 is replaced by:
- `Σ_b occ_b·min(1, crime_b/3) / Σ_b occ_b`, where a building with 3 unanswered calls counts as fully criminal;
- curfew is already in the generation rate (§9.2), so E35 sits after the curfew line and it is not applied twice;
- laws, rebellion and the auto-vote read the same scalar as today.

**Health.** `needHealth = max(0, pop − 20)`, the formula at 1455-1456, recomputed in E5 because E5 runs before it.
- `treatedShare600` is the share of citizens who fell sick in the last 600 s who were treated.
- With nobody sick in the window, it is 1 if a health depot has `fleetAvail > 0`, and 0 otherwise.
- The Clinic, Hospital and Emergency Services health terms are retired. The disease formula (1457-1467) is unchanged.

**Mail and goods.** Neither goes through `services['leisure']`. `serviceCoverage` takes the **minimum** of the clamped ratios, and commercial leisure (60–400 per building, city_building_spec.dart:176-187) keeps leisure above 1, so a leisure term would do nothing. Both are direct terms in the happiness `socialDrag` (E34) instead. The HUD reads `agents.mailBacklog`.

### 9.6 Global code retired (per service flag, the old code kept in `else` branches)

| Flag | Retired code |
|---|---|
| garbage | Injection at 1411-1412. The landfill and recycler global draw (E6). |
| deathcare | The `careRate` draw (1486-1490), which processed **nothing** in the parcel city; the morgue and crematorium draw |
| police | **Every** passive term in `services['safety']`: Police Station, Emergency Services and the four military specs. The crime target formula (1822-1825). |
| mail | Nothing (new) |
| health | The clinic, hospital and emergency terms in `services['health']` |
| fire | The city-wide lot-fire step (4189-4233), including its `fireReach` factor, and its unseeded spread |

The flags are `agents.serves(kind)`, all on for agent colonies once their slice lands.

The else-branches are deleted only in the polish slice, after the flag-off tests migrate.

### 9.7 New buildings (E22)

Every `unlockPop` sits on a milestone rung (city_progression.dart: 0/60/80/120/200/300/400/600/800/1000).

| Spec (label) | Type | Group | Jobs | Power | Build cost (ore) | Unlock pop | Site |
|---|---|---|---|---|---|---|---|
| Post Office | `postoffice` | `svc` | 12 | 6 | 40 | 60 | lot |
| Fire Station | `firestation` | `prep` | 16 | 8 | 50 | 80 | lot |
| Bus Depot | `busdepot` | `transport` | 20 | 10 | 60 | 120 | 180×90 m |
| Cargo Terminal | `cargoterminal` | `transport` | 30 | 12 | 120 | 200 | 300×160 m, `storageBonus: 600` (goods) |

- `kDepotByLabel` in `service_dispatch.dart` is keyed by **label**. Labels are the persistence key (the `utils` map in `toJson`, city_sim.dart:4399-4401, and the lot buildings), and types collide.
- **Site-claiming specs are swept by existing tests.** Bus Depot and Cargo Terminal claim their own site (`claimsOwnSite = siteWidthM > 0`, city_building_spec.dart:135).
  - `installation_massing_test.dart:92-117` iterates every `kUtilCatalog` spec. It requires finite volumes inside the site at scales 1.0, 0.3 and 0.05.
  - `installation_parking_test.dart:31` iterates every site-claiming spec.
  - So E22 adds a massing rule (a depot shed plus a yard) and a parking rule for each, in the rule tables those tests read (`building_massing.dart`). Both tests stay green (§17.5).
- `docs/REFERENCE.md` is regenerated with `test/tools/gen_reference_test.dart` in the same commit (C11).
- **Fire Station declares a `safety` service term**, as Emergency Services does. In a colony without agents that is what makes it fire cover: the lot-fire step suppresses by `services['safety']` (city_sim.dart:4193-4195), and `fireReach` counts only stations with it (`TrafficRole.fightsFires`, road_traffic_model.dart:149-152). Under the police flag the term is retired with the other passive safety terms (D37), and engines do the work (§9.4).

---

## 10. Freight and outside connections

### 10.1 Goods

`Commodity.goods` is added (E23), in the FINISHED GOODS section. It lives in **building buffers**, not the global stock.

| Building | Behaviour |
|---|---|
| Industrial (`i-*`) | Makes goods at `jobs × 0.002 × run` u/s, on top of the existing ore→steel flow, which is unchanged. Buffer cap 60 u. |
| Commercial (`c-*`) | Uses goods at `jobs × 0.0015` u/s. Buffer cap 40 u. A shop with an empty buffer sells nothing: it counts in `goodsShortage`, a direct happiness drag (E34, §9.5). Its leisure term is left alone, for the reason given in §9.5. |
| Warehouse, Cargo Terminal | Hold up to `storageBonus` goods (city_building_spec.dart:471-473). |

### 10.2 Freight trips

- **Requests.** A commercial building whose buffer falls below 30% raises a `goods` request.
- **Supplier.** The nearest industrial building or warehouse holding at least 20 u, by straight line. Failing that, the nearest resolved stub, as an **import**.
- **Loads.** A truck or delivery van carries 20 u. Imports and exports run as semis carrying 60 u.
- **Exports.** An industrial building with at least 20 u and no local request for 30 s ships to a warehouse or Cargo Terminal with room. Failing that it ships to a stub, as an **export**.
- **No path.** The next supplier or customer by the same score, then a 60 s back-off (§4.8).
- **Delivery reach**, the growth gate on shops and works (city_sim.dart:4112-4113), stays a reach question: the routed model's in slice 1, the agents' own from slice 2 (D46), by one rule. Goods reach a lot only from another lot's source. A works' own goods, and its own lorries turning at the node beside it, are no delivery (e608e35; road_traffic_model.dart:521-537), so a works on a street nothing else reaches the right way round declines like a shop there.
- **Scale check.** 10 `i-med` buildings (28 jobs each) make 0.56 u/s. That is 0.028 truck trips/s, or about 8 trucks moving at a 300 s trip.

### 10.3 Money (behind the `freightEconomy` flag)

- An export pays **+0.8 §/u** on arrival at the stub.
- An import costs **−1.2 §/u** when dispatched, and is lost if the truck despawns.
- Service fleet upkeep (§9.2), bus upkeep (§11.3) and train upkeep (§11.7) are charged in the same `agents.fundsRate`.
- The funds line becomes `funds += (taxIncomeRate + lawUpkeepRate - roadUpkeepRate + agents.fundsRate) * dt;` (E5b, city_sim.dart:1538), and `netFundsRate` (405) agrees.
- A new display field, `tradeIncomeRate`, joins the Budget drawer (city_game_hud.dart:515-585) through E29.
- **Balance check.** The existing tax is `workforce·h·tax·0.05` (about 2.25 §/s at 500 workers). Against that, 0.56 u/s of exports is about 0.45 §/s: a real but secondary income. `freight_balance_test` pins a mid-size colony's funds trend over 3,600 s to within ±20% of the same colony without freight.

### 10.4 The outside-connection stub

**Fields** (`OutsideConnection`, §2.9):
- `id = 'oc<n>'`;
- `at`, the colony-local position of the free road end;
- `headingRad`, pointing away from the city;
- `classIndex`;
- `enabled`.

Stubs are keyed by **position**, like `JunctionOverride`. They carry no rates: every flow is defined below.

**Resolution** (each graph build):
- The stub attaches to a **free-end** node within 12 m of `at`. A free-end node is a `RoadGraph` node with one leg that is `atGrade`.
- Its road must be eligible: `RoadTier.medium` or above, which is avenue, trunk, boulevard, highway, the expressways and motorway.
  - Elevated roads are excluded: a raised free end is a `danglingDeck`, never a ground dead end.
  - Ramps, minor roads and rail are excluded too.
- If none matches, the stub is `broken`: it draws red in the tool and spawns nothing.

**Graph shape: one virtual edge pair per stub** (D25):
- `stub node ↔ sink node`, 2,000 m long at 100 km/h (72 s), weight 1.0.
- The sink sits at `at + heading × 2000 m`, so the heuristic stays admissible (§4.3).
- A U-turn at its **own** sink.
- Sinks are never connected to each other. A through trip from A to B must therefore enter the town at A's stub and leave at B's, and its cost is real.

**Spawning.** Vehicles spawn at the sink and drive the virtual edge; they are drawn only once they reach the stub node, since the virtual edge has no geometry. Vehicles leaving the map despawn at the sink.

**The flows (D38).** Every inbound vehicle has a destination building and every outbound vehicle an origin building. Through traffic, which runs sink to sink, is the only exception.

| Flow | What it is | Rate | Origin → destination | Afterwards |
|---|---|---|---|---|
| **Visitor in** | A car from beyond the map visiting the town | `2 × classFactor(stub) × max(0.25, min(1, pop/500))` per minute per stub | stub sink → a built non-residential building with jobs, drawn by `TrafficRng` weighted by jobs (commercial ×2, leisure and civic ×1.5) | Parks (§7.3), dwells U(120, 480) s, then leaves for a stub drawn by `classFactor`: a **visitor out** |
| **Out-of-town errand** | A resident's trip beyond the map (§6.4) | `outOfTownShare = 0.08` of car owners' errands | home → stub sink; then, after U(600, 1800) s, a stub drawn by `classFactor` → home | Parks at home |
| **Emigrant out** | A §6.2 departure by car | the ledger | home → stub sink | Vanishes at the sink |
| **Immigrant in** | A §6.2 arrival by car | the ledger | stub sink → the new home | Parks at home |
| **Import** (truck in) | A §10.2 goods request filled from outside | demand | stub sink → the requesting shop | Unloads (30 s dwell), then returns to a stub |
| **Export** (truck out) | A §10.2 surplus shipped out | demand | works → stub sink | Vanishes at the sink |
| **Through** | Traffic between places beyond the map | §10.5 | stub A sink → stub B sink | Vanishes |

- **There is no separate truck schedule.** Trucks in and out are exactly the import and export trips.
- **Visitors are entities.** Each is a row in the `VisitorTable` (building, parked car, `leaveAtUs`, exit stub; capacity 1024). Visitors are not citizens and not in population.
- **Visitor rates scale with population, floored at 25%.** So a fresh colony already sees them, and they need a destination: with no non-residential building, none spawn.
- **`classFactor`:** expressway4, expressway6, expressway8 and motorway 1.0; trunk 0.6; boulevard and highway 0.4; avenue 0.2.

**Where stubs come from:**
- **City Builder agent colonies (E17, slice 8).** `CityStarterKit.found(agentTraffic: true)` lays two `RoadClass.trunk` spurs from the ends of the east–west starter street: (±300, 0) → (±2,300, 0), committed with `frontsLots: false`, as a founding gift.
  - Their free far ends get enabled stubs `oc1` and `oc2`, each 2.3 km from the origin.
  - The spurs run along y = 0, between the spaceport and solar field (north-east and south-east) and between the pump and farm (north-west and south-west), which all sit at least 60 m off the axis.
  - Through traffic can then cut through the crossroads when that is cheapest, as the spec expects.
  - These are the "special highway outside connection segments" of decision 4.
- **The player** (§16.1): the "Outside connection" tool, on a free end of an eligible road at least 1.5 km from the origin. Enabling costs 200 §. Disabling is free, and is a network edit (§4.7).
- **Generated colonies** (E31, slice 11, when they get agents): after the interstates are laid, `markFreeEnds` adds a stub at each interstate free far end. These run at least 8 km past the outline (city_generator.dart:1054-1057, 1183). The trunk outreach ends (841-865) get stubs too.
- **Later:** a stub becomes a highway to another colony's stub.

Stubs persist under `agents.outside` (§14).

### 10.5 Through traffic

- **Rate.** For each ordered pair of enabled stubs (A, B), A ≠ B: `0.5 × classFactor(A) × classFactor(B)` vehicles per minute. It is **not** scaled by population: it is traffic between places beyond the map. The mix is 60% semis and 40% cars.
- **Routing** uses the normal cost function. Whether through freight cuts through town is decided by cost alone. The only thing discouraging it is `wVeh` ×1.5 on minor streets, and a bypass built later draws only the trips planned after it exists.

### 10.6 Immigration through connections and the spaceport

- Arrivals (§6.2) enter at the spaceport or a stub. An arrival by stub is an **immigrant in** trip to the new home (§10.4).
- The migration **gate** stays `hasSpaceport` (city_sim.dart:1564). The knob `connectionsAllowMigration` (default off) lets a resolved stub open the gate as well.
- **Emigrants** leave by car to a stub (visible outbound traffic), or walk to the pad.

---

## 11. Transit (buses, rail and the L)

### 11.1 Stops: keyed so they survive road splits

- **Placing a stop** (§11.5):
  - The tap snaps with `layout.nearestRoadPoint(p, withinM: 15)` (city_layout.dart:242).
  - The heading is the road's travel direction **on the tapped side**. Traffic keeps right, so the side is the right of travel.
  - The stop stores `(at, headingRad)`, never a road id.
- **Resolving it** on each graph revision:
  - It resolves to the nearest directed edge within 8 m whose travel heading is within 45° of `headingRad`, with `at` on that edge's right-hand side.
  - That gives `(edge, s)`, with `s` clamped to `[stopBack + 8, len − stopBack − 8]`.
  - If no edge qualifies, the stop is `broken`: its line shows a warning and buses skip it.
- **Shelters.** A bus shelter is drawn at each resolved stop by `traffic_overlay_nodes.dart`, through the public `StreetFurniture.place(m, StreetProp.busShelter, at, along, up, rnd)` (street_furniture.dart:178).
  - The random bag's shelter weight (street_furniture.dart:81) is left alone. Setting it to 0 for agent colonies needs a tile-mesher knob, which is a slice-12 coordination request.

### 11.2 Lines

- **Route.** A line's route is the concatenation of locked legs `stop_i → stop_{i+1}`, wrapping from the last stop to the first. Each leg's destination lane set is {kerb lane} at the stop's `s`.
- **Routing (D26).**
  - The legs are **routed once**, when the line is created or when the player edits its stops.
  - On every graph rebuild the whole block is **remapped** like any vehicle's route (§3.9). **Only a leg whose remap fails is re-routed.**
  - So a road opened later is used by the line only if the player edits the line.
- **Storage.** One arena block per line, shared by every bus on it through a cursor. The legs from the depot to stop 0, and back, are separate appended legs (§4.6).
- **Ride table.** `ride[i→j]` = the sum of leg free-flow times plus the mean `D` along them, refreshed every 60 s. Each revision also builds the transfer lists between lines (§4.9).

### 11.3 Buses, depots and headway

- **Vehicle.** A bus is `AgentKind.bus`: 12 m long, 30 seats.
- **Fleet.** `min(vehiclesWanted, 10 per Bus Depot)`. Each bus in service costs 0.05 §/s in upkeep, inside `agents.fundsRate`.
- **Launch.** Buses leave the depot on an appended leg to stop 0, then loop the line's shared block.
  - Departures from stop 0 are spaced `k·cycleT/buses` apart.
  - After that they run free, with no holding control, so bunching emerges as in CS1 (a non-goal to fix).
- **Stopping.** At a stop, a bus dwells **in its locked destination lane** (the kerb lane at the stop) for `2 + 0.5·(boarding + alighting)` s. Following traffic queues behind it. There are no bus bays. `stuckT` is frozen while it dwells (§5.6).
- **Shift end, or a smaller fleet.** The bus finishes its loop to stop 0, then takes an appended leg to the depot.

### 11.4 Passengers

A citizen whose locked itinerary (§4.9) includes a ride:
1. walks to stop s₁ (a leg planned at departure);
2. joins `stopQueue[s₁]` (a ring of citizen handles, tagged with the wanted line) in state `waitingStop`;
3. boards, in FIFO order up to capacity, when a vehicle of that line arrives. The citizen's state becomes `riding`, with `rideVehicle = bus`, and they are not drawn. Each bus has a 30-slot passenger ring.
4. alights at the transfer stop or at s₂. The transfer walk or the egress walk is an **appended pedestrian leg planned then** (§4.6).

A transfer repeats steps 2 to 4 once.

**No giving up (D36).**
- A rider waits however long the bus takes: traffic delaying a bus never changes a rider's plan.
- A wait longer than `2 × headway + 120` s counts the trip as late (`stats.transitLate`), and nothing more.
- Only a **network edit** re-plans a rider: the player deleting the line or the stop, or setting the line's vehicles to 0 (§4.7). They then choose a mode again from where they are.

**Fare.** 1 § per boarding, into `transitIncomeRate`. It is 0 under `Law.freePublicTransit`, whose happiness bonus and upkeep (city_sim.dart:1784, 1797) are unchanged.

### 11.5 The line tool

The tool is `TrafficToolController` in `traffic_tools.dart` (D22).

- **Modes and state.**
  - Modes: `busLine`, `railLine` (slice 9b: stations instead of stops, §11.7) and `outsideConnection`.
  - State: `editingLineId` and `pendingStops`.
- **Methods:**
  - `tap(CitySim, SurfaceHit)`: add a stop (snapped, heading from the side);
  - `removeLastStop()`;
  - `commitLine(CitySim)`, which creates the stops and the line through `agents.transit`;
  - `cancel()`;
  - `setVehicles(lineId, n)` (buses or trains);
  - `deleteLine(id)`;
  - `toggleStub(CitySim, hit)`.
- **Sub-row widget.** Follows the pattern of their `TrafficToolPanel` (road_tool_panel.dart:461-588), a row of mode chips over a row for the mode. Ours holds the line list, a vehicle-count stepper, a colour swatch, and tick and cross buttons. It lives in *our* file and opens from the HUD's Transit drawer; a button in their toolbar is a request (C4).
- **Preview.** Pending stops draw as rings and the routed legs as a dashed ribbon in the line's colour, through `TrafficOverlayState`, never `RoadOverlayState`. Hover runs through E27's early return.

### 11.6 Transit and happiness

- **Bonus.** With the transit flag, `transitBonus()` (city_sim.dart:1772-1779, grid-only today) returns `agents.transitBonus = 0.1 × clamp(transitShare / 0.25, 0, 1)`. `transitShare` is the 600 s moving average of bus and rail trips over all completed trips (E10).
- **Transit Stop building.** The existing Transit Stop (city_building_spec.dart:498-500) keeps its leisure service. It becomes an optional *terminal* that lines may start from. Retiring it is an open question (§19.2).
- **Persistence.** Stops, lines and counters are saved; buses and trains respawn on load (§14).

### 11.7 Rail and the L (slice 9b)

Decision 3 puts every mode in scope, and the game already has a railway (`RoadClass.rail`), the elevated line (`RoadClass.transit`, "Elevated Rail", parcel.dart:100, 115) and a Railway Station (city_building_spec.dart:505-507). Slice 9b makes their trains agents.

- **The rail graph.**
  - `RoadGraph` leaves rail out, so `rail_graph.dart` builds its own graph from `isRail` roads, using the same rule: ends within 8 m in plan and at one level, decks compared by height.
  - Each rail piece is double track, one directed edge each way.
  - Rail nodes are switches, with no road junction control.
  - Rail edges are never joined to road edges.
- **Stations.**
  - On the railway, a station is a Railway Station building within 60 m of a rail piece. It resolves to `(edge, s)` like a bus stop.
  - On the L, a station is a stop placed by the rail-line tool on a transit piece. It is keyed by position and heading, like a bus stop (§11.1).
- **Lines.** Drawn with the line tool in rail mode: an ordered list of stations, with `TransitLine.mode = rail` or `L`. They are routed once on the rail graph, remapped per revision, and re-routed only when a remap fails (D26).
- **Trains.**
  - `AgentKind.train`: 4 cars, 200 seats. `AgentKind.lTrain`: 3 cars, 120 seats.
  - IDM with a = 0.8 and b = 1.0 m/s².
  - **Block signalling:** a block is one directed rail edge, and a train may enter it only when it is empty.
  - 20 s dwell at stations, with `stuckT` frozen.
  - Each line's first station is its depot. Fleet `min(vehiclesWanted, 6)`, upkeep 0.2 §/s per train.
- **Riders** behave exactly like bus riders (§11.4). Rail enters mode choice with stations within 800 m (§4.9), and a bus↔rail change is one transfer.
- **Freight rail** (knob `freightRail`, default off): freight trains between a Freight Yard and a rail stub at a free rail end. A rail stub is marked like a road stub (§10.4). Freight trains carry imports and exports in place of semis.
- **Rendering.**
  - Train agents use the existing rail car and train meshes: `_railCarMesh` and `ElevatedStructure.emitTrainCar`, as the cosmetic pass draws them in `_syncTraffic`.
  - The cosmetic trains are hidden for agent bodies through C9. If C9 has not landed, a fifth E20 hunk skips `sink.railCars` and `sink.trainCars` for bodies in `snap.cityTraffic` (city_nodes.dart:2184-2203).
- **Rules.** Trains follow the same determinism, allocation and locked-route rules as every other agent.

---

## 12. Economy rewiring

### 12.1 The tick, with agents enabled

Line numbers are those of `CitySim.advance` on dev (city_sim.dart:1176-1720). "prev" means the value the agents published at the end of the previous tick's `agents.advance`.

| Step | Lines | With agents |
|---|---|---|
| 0 Frame hold | 1176-1178 | E3b: `if (agents.holdTick(simDt)) return;`. A no-op unless the host set `frameBudgeted` (§5.7). |
| 1 Day phase | 1181-1183 | Unchanged |
| 2 Aggregation | 1185-1234 | Unchanged. The building table derives capacities with the same per-building rounding on its own 2 s sync, so no hook is needed here. |
| 3 Ratios, workforce | 1235-1238 | Unchanged until slice 10 (§12.3) |
| 4 `commuteEff` | 1244 | E4, **from slice 1**: `agents.stats.commuteEff` (prev) |
| 5 Staffing, throttle | 1248-1255 | Unchanged formula |
| 6 Medicine gate | 1257-1272 | Unchanged |
| 6b Service rewrite | new line after 1272 | E5: `agents.rewriteServices(services, population)` (prev coverage values) |
| 7 Production | 1274-1308 | E6: owned depot specs skip; their pollution scales with the work done |
| 8 Pollution | from 1310 | Unchanged |
| 9 Life support | up to 1403 | Unchanged |
| 10 Waste | 1405-1423 | E7: sewage still injected; `wasteBacklog = agents.wasteBacklog` (prev) |
| 11 `socialTick` and the others | 1425-1441 | In `socialTick`, E35 replaces the crime target under the police flag (1826) |
| 12 Mortality | 1443-1490 | `deathRate` formula unchanged. E8: `died` goes to the ledger; `corpses = agents.corpseTotal` (prev); `careRate` skipped. |
| 13 Happiness | 1492-1519 | Formula unchanged, plus E34's `agents.happinessDrag` in `socialDrag` (1499-1506). Reads the derived scalars and `transitBonus()` (E10). |
| 14 Tax and research | 1521-1543 | Unchanged. The land-value factor (1530) reads `trafficReadout.taxLandValueFactor`: the routed model's through the readout in slice 1, the agents' own from slice 2 (D46). E5b adds `agents.fundsRate` at 1538, from slice 8. |
| 15 Population | 1545-1576 | E9: the migration delta goes to the ledger when `ownsPopulation` |
| 16 RCI | 1578-1596 | Unchanged |
| 17 Grid growth | 1598-1671 | Unchanged |
| 18 Parcel dynamics | 1673-1678 | See the bullets below |
| 19 Cap sweep, milestones | 1680 onward | Unchanged. Garbage is no longer in `stock`, so the sweep cannot delete it. |

Step 18 in detail:
- `roadTraffic.advance(dt)` (theirs, 1675) runs in slice 1. From slice 2, E3a skips it in agent colonies.
- **E3a**, right after it: `if (agents.enabled) agents.advance(dt);`.
- `advanceParcelGrowth(dt)` (1676) reads `trafficReadout.deliveryReach` and `noiseOf` (4113, 4125): the routed model's answers in slice 1, the agents' own from slice 2.
- `advanceParcelTraffic()` (1677) is unchanged. It reads `trafficReadout` (4143-4148), so it writes `parcelCongestion` from the agents' measured congestion.
- `advanceParcelFires(dt)` (1678) contains E11. Until the fire flag, its reach factor reads `trafficReadout.fireReach` (4204).

### 12.2 What `agents.advance(dt)` does, in order

1. **Poll the key.** If `roadsRevision` or `layout.version` moved, fetch `city.roadGraph`. Then do nothing, refresh controls, or rebuild, remap and swap (§3.8).
2. **Detect the external population delta** (§6.2).
3. **Building sync** every 2 s, spread over 4 advances in quarters of the building list: capacities, access points, depots, parking capacity, tombstones.
4. **Integrate accumulators** by `dt` for every flagged service (§9.2), including fire ignition under the fire flag. This is per building, O(buildings), with no allocation.
5. **Run the sub-step loop** (§5.1–5.2), which includes ledger realisation, dispatch, and the visitor, through and freight schedules.
6. **Process depot buffers** (§9.4).
7. **Roll up statistics**, then publish the readout's picture when a congestion epoch completes (D47), and the derived scalars and coverage numbers for the next tick's hooks: `commuteEff`, `wasteBacklog`, `corpseTotal`, `policeCoverage`, `crimeTarget`, `treatedShare`, `mailBacklog`, `goodsShortage`, `happinessDrag`, `transitBonus`, `fundsRate`, `depotRun`.
8. **Write back** `population` (§6.2).
9. **Report timing** through `TrafficMetrics` (reporting only).

### 12.3 Exact replacements

| Today | Becomes (flag / slice) |
|---|---|
| `advanceParcelTraffic()` (called at 1677; body 4137-4172) | **Kept, unchanged** (revision 3). Its readout branch (4143-4148) reads `trafficReadout`, the agents' in an agent colony (E37), so from slice 1 it writes their measured congestion. Its frontage-local fallback runs only before a first picture. |
| `parcelCongestion` (3335) | From **slice 1**: `0.5·(peak + average)` of the agents' measured congestion, written by `advanceParcelTraffic` from the readout (§4.2) |
| `commuteEff = 1 − max(congestion, parcelCongestion)·0.4` (1244) | From **slice 1** (E4): `stats.commuteEff = clamp(1 − 0.4·(0.5·(tripRatio − 1) + failedShare), 0.6, 1)`. `tripRatio` is an EMA of actual/free-flow time over completed commutes, capped at 3; `CommuteSynth` trips feed it in slices 1–2. `failedShare` is the despawned share of commutes over the last 600 s. Grid `congestion` is ignored in agent colonies. |
| `workforce = min(pop, jobs)` (1238) | Slice 10: `Σ_b min(present_b + recentlyArrived_b, jobs_b)`. A job nobody can reach is an unfilled job. |
| Staffing (1248-1255) | Slice 10: per building, `staff_b = present_b/jobs_b`, applied as `uf × staff_b` in the parcel production loop. This is part of E6's line, keyed by spec plus a per-building staffing lookup. The global `staffing` becomes the job-weighted mean, for the UI. |
| `ParcelNetwork` serving (used at 1216-1219 and in growth) | Slice 10, agent colonies only: `lotServed` becomes "the access node is in the lane graph's largest strongly connected component", from the same `RoadGraph` the routed model reads. `sprawl_topology_audit_test` gates it. |
| `transitBonus()` (1772-1779) | E10 (slice 9) |
| `hasSpaceport` migration gate (1564) | Unchanged. Stubs add arrival points only (knob in §10.6). |
| Crime target (1822-1825) | E35 (slice 6): from the per-building accumulators (§9.5) |
| `services['safety']` | E5 (slice 6): `policeCoverage × pop`, every passive term retired (§9.5) |
| Waste (1405-1423), corpses (1482-1490) | E7 and E8 (slice 5) |
| Lot fires (4189-4233) | E11 (slice 7) |
| HUD Congestion (city_game_hud.dart:582-583) | Code unchanged; it reads the agent-fed `parcelCongestion` |
| Status-panel congestion (city_panels.dart:191-211) | E30: reads `parcelCongestion` when the agents are enabled |

**The readout (D46, D47, C2).** In an agent colony everything that reads traffic reads `CitySim.trafficReadout`, and E37 makes that `agents.readout`.
- **Slice 1.** The agents answer `hasRun`, `peakCongestion`, `averageCongestion`, `congestionOf` and `volumeOf` (§4.2), `routesThrough` and `passes`.
  - `routesThrough(road)` lists the live vehicles whose locked route uses the road. Each is a `TripRoute` (traffic_readout.dart:26-46): `TripKind` from the trip's purpose (commute → commuter; errands, visits and out-of-town trips → shopper; freight → goods; service, bus and train runs → service), weight 1 per vehicle, `roadIds` in route order with each visit once, and the whole route's polyline from `RoadGraph.polylineOf` (road_graph.dart:351-353). They come heaviest first, ties by handle, at most `limit`, filtered by `kinds`.
  - The picture is taken at each congestion epoch (2 s), and `passes` moves with it.
  - `serviceReach`, `fireReach`, `deliveryReach`, `noiseOf`, `landValueOf`, `averageLandValue` and `taxLandValueFactor` are forwarded to `city.roadTraffic`, which keeps advancing (1675). So that a forwarded answer that changes moves `passes` too, `passes` is `hasRun ? own + roadTraffic.passes : 0`; neither count ever goes back (road_traffic_model.dart:1712-1715).
- **Slice 2.** The agents answer the rest, and E3a skips `roadTraffic.advance`.
  - **Noise, land value and the tax factor.** Per piece, emission is `g.roadEmission[r] × RoadNoise.volumeFactor(c_p)` (road_graph.dart:247; road_noise.dart:46-51). `c_p` is the piece's measured load: the larger of its speed-based congestion and its flow against capacity (vehicles per lane-minute over the last 60 s against `AgentTuning.laneFlowPerMin = 30`, a lane at free flow). A lot's noise is `RoadNoiseSampler.noiseAt` over those emissions (road_noise.dart:110-136). Land value is `RoadNoise.landValue` with the frontage bonus and the colony's pollution. The tax factor is `RoadNoise.taxFactor` of the built lots' average without pollution, exactly 1 until a built lot is valued (road_noise.dart:99-100; road_traffic_model.dart:566-575).
  - **Reach** (`agent_reach.dart`). Bounded multi-source searches over directed edges, run through the path budget's skim lane: `serviceReach` from every station that sends vehicles, `fireReach` from stations with safety cover only, and `deliveryReach` from every goods source but the lot's own (D47). The radius is the routed model's, `TrafficTuning.serviceReachM` (4 km).
- **Nothing abstract is left.** From slice 2, no answer in an agent colony comes from assigned volumes. The old residual (C7) is resolved.

### 12.4 HUD and panel compatibility

- **No field changes type.** Every scalar the UI reads still exists and is written every tick: `parcelCongestion`, `wasteBacklog`, `corpses`, `crime`, `homeless`, `services[...]`, `staffing`, `throttle`, `population`.
- **New readouts** come from `agents.stats`. They are precomputed in the tick, because `CityGameHud` rebuilds every frame (city_game_hud.dart:90-92).

---

## 13. Snapshot and renderer

### 13.1 The wire schema (application layer)

New field on `WorldSnapshot` (E19): `final List<CityTrafficFrame> cityTraffic` (default `const []`).

```dart
class CityTrafficFrame {                 // application/snapshot/city_traffic_frame.dart
  final String colonyId, bodyId;
  final AgentFrame agents;               // new identity every agent sub-step (domain type)
  final PedFrame peds;                   // new identity every sub-step
  final TrafficGeometry geometry;        // identity per (graph object, groundCacheStamp)
  final TrafficNetColumns net;           // per graphRev: signal heads + plans, stops, stubs, node list
  final Uint8List laneSpeedPct;          // per congestion epoch (2 s); 0..100, index = lane id
  final ParkedColumns parked;            // per parkedRev; carries sitesRev for its lot rows (§7.4)
  final TransitColumns transit;          // per stopsRev/graphRev: stop and station poses, line colours + lane lists
  final CitySiteFrame sites;             // per sitesRev, by identity: the SAME object as the colony's WorldSnapshot.sites entry (site-access §5.2); from T4a
}
```

**`AgentFrame`** (domain, `agent_frame.dart`). Its typed columns are **immutable after publish**.

- Scalars:
  - `count`;
  - `timeUs` (the agent clock at this sample, a `double` holding an exact integer);
  - `worldEpochS` (the world epoch the tick carried);
  - `graphRev`;
  - `sitesRev` (from T4a): the site revision the site columns refer to.
- Rows:

  | Column | Type | Meaning |
  |---|---|---|
  | `handle` | `Int32List` | vehicle handle |
  | `elem` | `Int32List` | lane `< nLanes`, connector `≥ nLanes`, −1 = not on a road element (parked, garaged, on a virtual stub edge, or inside a site) |
  | `next` | `Int32List` | next element on the route, or −1 |
  | `s`, `v`, `a` | `Float32List` | position, speed, acceleration (along the site lane while inside a site) |
  | `lat` | `Float32List` | extra lateral offset: 0 while driving; the §7.2 nudge; −0.8 m while dwelling at a kerb |
  | `kind` | `Uint8List` | `AgentKind` |
  | `variant` | `Uint8List` | the opaque per-vehicle byte (§2.3); the renderer maps `(kind, variant)` to a mesh (§13.7) |
  | `flags` | `Uint8List` | braking, emergency lights, doors, stopping, reversing (a stall manoeuvre or a home back-out, §7.5) |
  | `siteOrd` | `Int32List` | from T4a: the site's ordinal in `CityTrafficFrame.sites` order while the vehicle is inside a site, −1 on the road |
  | `siteLane` | `Int32List` | from T4a: the plan-local site lane (site-access §2.5) while `siteOrd ≥ 0`, else −1 |

- **Site elements are separate columns** (D49), never encoded as `elem ≤ −2`, so the lane-id space and every road consumer of `elem` are unchanged. Site poses use the plan's points and `CitySiteFrame` heights (D19, D20); the site manoeuvre geometry is built in `traffic_capture.dart`.
- Rows are written in slot order, so a vehicle keeps its row while it lives. About 30 B per vehicle, plus 8 B for the site columns.
- The domain never stores or publishes a `VehicleKind` (D42).

**`PedFrame`**: `handle`, `pav`, `s`, `side` (`Int8`), `v`, `flags`.

**`TrafficGeometry`** is built by `TrafficCapture` in the application layer. It is cached per (graph object, `groundCacheStamp`) in `static final Expando<_GeomCache> _cache` keyed by the `CitySim`, so **no field is added to `CitySim`**. It holds:

- **Per directed edge**, a travel-order polyline:
  - `ptsBF` (`Float64List` xyz, body-fixed);
  - `cumGeom` (`Float32List`, arc length on this polyline);
  - `lift` per point (§13.3);
  - `simLen` (the edge length in simulation arc).
- **Per lane:** `laneOff` (right of travel, from the graph).
- **Per connector:** 8 body-fixed Bézier points, `conLen`, and the lift at each end.
- **Per pavement edge:** a polyline and a side offset.

The domain publishes `TrafficNetColumns` per graph revision, holding everything the renderer needs from the graph:
- lane → edge;
- connector endpoints in local east-north;
- the nodes;
- signal heads `(node, phase, leg dir, leg halfWidth, r)`;
- the signal plans (offset, phase count, µs timings).

**Filled and dropped:**
- `copyWithEpoch` (world_snapshot.dart:1939-1953) passes `cityTraffic` through. The studio's frame carries none, because the studio never ticks.
- JSON: **not serialised**. Traffic is transient, and the JSON frame is not a save. `toJson` is untouched (documented).
- The hand-copied frame builders get the empty default: `city_studio_screen.dart:1366-1378`, `terrain_studio_screen.dart:778` and `flatbuffer_codec.dart:337` (snapshot-wire report §3). That is correct, since none of them has agents.

### 13.2 Buffering and identity

- **Three buffers.** The domain keeps **three** column sets of capacity `maxVehicles`.
  - Sub-step `k` writes set `k mod 3` and publishes a **new tiny `AgentFrame` wrapper** over those typed lists: one small allocation per sub-step, 5 per second at 1×.
  - A set is rewritten only two publishes later, so a frame the renderer still holds is never mutated. That honours the contract at city_patch_columns.dart:166-171.
  - The same applies to `PedFrame`.
- **Capture** passes wrappers by reference: O(1) per frame, with no per-agent work in `capture`. The geometry is cached, so capture adds only the `Expando` lookup and the key compare.
- **Geometry (on a rebuild only), sliced from the same capture.** E19's hook runs after the colony's road loop (world_snapshot.dart:2071-2183), so `roads` already holds this colony's `RoadSnapshot`s: the trailing run whose `colonyId` is this city's. `TrafficCapture` reads them; it never re-samples or re-drapes.
  - It maps road id → snapshot through `RoadSnapshot.id` (2179).
  - It reads the points (2144-2151). They are the capture's own samples, draped from `city.groundCache` and, for a reversed one-way road, **already flipped** to travel order (2134-2158).
  - It reads `lifts` (2126-2133, flipped with the points) and `bridges` (2168-2175, mirrored for reversed roads).
  - Each directed edge's polyline is the slice of its road's snapshot between the edge's arc range, in travel order: reversed for a backward edge on a two-way road, and as is for the forward edge of a reversed one-way road, whose snapshot is already flipped.
  - There are **zero ground queries**. A query costs milliseconds in a built city (world_snapshot.dart:2085-2087), and here every height is the ribbon's own.

### 13.3 The pose frame: lane id and s, not body-fixed positions

The simulation publishes `(elem, s, lat)`. The renderer maps these through the travel-order geometry. Reasons:

1. **Frames and drape.** The domain has no terrain field, and per-agent ground queries are forbidden. Slicing the ribbon's own points puts cars **exactly on the paint**.
2. **Precision.** Geometry is `Float64`, converted once per geometry identity to be anchor-relative on the body root's `anchorBF`, the same frame as `TrafficTile.build` (city_traffic.dart:427). `s` in `Float32` is exact to 1 mm on edges under 8 km.
3. **Payload.** About 30 B per agent, against 40 B or more for positions plus a basis. There is no conversion work in the domain or in capture.
4. **Interpolation** is natural in `s` (§13.4).
5. **Direction.** Edge polylines are **in travel order**. The renderer never flips anything; the only flip is the road agent's own on the wire.

**Arc mismatch.** Simulation `s` is measured on the index polyline (2 m samples, or the two controls of a straight road). The geometry is the capture's 6 m samples through the same controls; the two differ by decimetres (road-topology trap 13). The pass maps `s_geom = s × cumGeom.last / simLen` per edge, a uniform rescale. For an edge of a reversed road, the offset is measured from the flipped start. The residual is centimetres of along-road error, never lateral.

**Lift (one reference per road, D20):**
- For an edge of a **deck** road: `L = RoadMesher.ribbonLiftM` (0.12, road_mesher.dart:193) `+ lifts[i]`, interpolated between samples from `RoadSnapshot.lifts`. The same numbers raise the ribbon.
- For an edge of a **draped** road: `L = ribbonLiftM + cls.deckHeightM + SprawlPlan.bridgeLiftAt(s, bridges)`. This is the cosmetic pass's own term (city_traffic.dart:257) plus the ribbon lift it missed (renderer trap 3: cars sat 0.12 m inside the asphalt).
- For a connector: `plateLiftM` (0.16, road_mesher.dart:204) plus the end lifts, interpolated.
- `traffic_capture_test` pins our deck-road `L` to `RoadSnapshot.lifts`.

**Lateral and basis:**
- `fwd` = segment direction (travel order);
- `up = normalize(p + anchorBF)` (radial, as city_traffic.dart:919-921);
- `side = fwd × up` (right of travel, determinant +1, never mirrored: instance_packing's mirrored path draws a second call);
- `pos = p + side·(laneOff·scale(s) + lat) + up·lift`, where `scale(s) = hw(s)/hw` on a tapered stretch and 1 elsewhere (§3.4);
- written with `TrafficRoad.writePose` (city_traffic.dart:302).

**Segment search.** A per-slot hint (`Int32List` sized to capacity) is tried first; a binary search on `cumGeom` is the fallback. There is no linear scan (renderer trap 11).

### 13.4 Interpolation: the renderer's agent clock

`AgentTrafficPass` keeps `renderT` (seconds of agent time) per colony.

- **Rate estimate.** On the first frame that carries a new `AgentFrame` identity, the pass records `(wallNow, cols.timeUs)`. `rate` is `Δ agent time / Δ wall time` over the samples from the last 0.5 s of wall time, as an EMA. That gives 1 at 1× and about 25 at the clamp.
- **Why a frame without a tick is normal.** World ticks are a fixed 20 ms accumulated per frame (simulation_view.dart:1934-1945; simulation_clock.dart:27). So at 60 Hz about one frame in six runs no tick, and at 120–144 Hz most frames run none. A frame whose `snap.epoch` did not move is **not** a pause: `renderT` keeps advancing at the estimated rate.
- **Pause.** `rate = 0` exactly when `SceneSync.simWarp ≤ 0` (E26, E28), the host's own warp.
- **Stall guard.** If no new `AgentFrame` has arrived for 0.5 s of wall time while the warp is above 0 (a hitch, or a held frame queue), `renderT` is clamped to `t + h`, so cars never run away.
- **Advance.** Each frame: `renderT += wallDt × rate`, then clamp `renderT` into `[t − h, t + h]`, where `t = cols.timeUs/1e6`. If it falls outside `[t − 2h, t + 2h]` (a hitch, a warp change, the first frame), snap it to `t`.
- **Pose time.** `τ = renderT − t`, which can be negative. Then `s' = s + v·τ + ½·a·τ²`, with these rules:
  - Past the element's end, roll into `next` with the remainder, using `next`'s length, and keep going if needed.
  - Never roll past a flagged stop point, whether `next == −1` or the vehicle is stopping.
  - Never go below 0.

Consequences:
- Extrapolation is in **agent time against wall time** (fixing J1's epoch-quantisation and rate flaws).
- Each sample is stamped with its **own** sub-step clock (fixing the J2 per-tick stamping stutter).
- Frames without a tick do not stall; a pause freezes everything exactly.
- `agent_traffic_pass_test` pins both with 16.7 ms frames against 20 ms ticks.

### 13.5 Junction turn paths

A vehicle on a connector is lerped along the connector's 8 Bézier points by `s/conLen`. The heading comes from the local chord, and the lift is interpolated between the end lifts, plus the plate lift. The same Bézier is the one the domain sampled for `conLen`, so the speed is consistent.

### 13.6 Signal heads (`signal_head_layer.dart`)

- **Why.** Tile junctions bake one head per signalised leg. The junction pass switches its lamps by epoch parity (road_mesher.dart:1431-1435), fed the epoch the tile was meshed at (city_tile_mesher.dart:1816). So a drawn light does not follow the simulation's signal clock.
- **Geometry.** From `net.heads`:
  - `corner = at + dir·r·0.98 + side·(hw + 1.6)` and `top = corner + up·4.6`, the mesher's own mast placement in `_crossing` (road_mesher.dart:1373-1437, with `r = maxHalfWidth × 1.45` at 1379);
  - `at` comes from the node position, lifted like the connectors (plate lift plus the end lifts).
- **Drawing.** Three `InstancedMesh`es (red, amber, green lamp boxes), each with **one instance per head, always**.
  - A head not showing a colour gets a zero-scale matrix in that colour's mesh.
  - Counts stay constant, so only `setInstanceTransform` runs and never the clear-and-re-add path (city_nodes.dart:2226).
  - Lamps sit 0.4 m beside the baked box until C3 removes it.
- **State.** `SignalPlan.stateAt(phaseOf(head), renderTimeUs)`: the **same function** the arbiter calls.
  - The drawn state can lag the arbiter's by at most one sub-step (0.2 s), which falls inside the 3 s amber.
  - §17.3 #11 checks that no connector is granted against a drawn red.

### 13.7 Meshes, liveries, kinds

**New `VehicleKind`s, appended all at once in slice 5** (E21). `road` and `airless` at vehicle_meshes.dart:54-55 are unchanged, so the parked-car family picks at city_tile_mesher.dart:2398 do not move.

| Kind | Length (m) | Width (m) | Height (m) | Axles | `liveryU` |
|---|---|---|---|---|---|
| bus | 12.0 | 2.55 | 3.1 | 2 | 0.30 |
| garbageTruck | 8.5 | 2.5 | 3.3 | 3 | 0.62 |
| hearse | 5.6 | 1.9 | 1.5 | 2 | 0.05 |
| policeCar | 4.9 | 1.85 | 1.5 | 2 | 0.12 |
| ambulance | 6.2 | 2.1 | 2.7 | 2 | 0.95 |
| fireEngine | 9.5 | 2.5 | 3.2 | 3 | 0.20 |
| mailVan | 5.2 | 2.0 | 2.3 | 2 | 0.80 |
| deliveryVan | 5.8 | 2.05 | 2.5 | 2 | 0.70 |

- **Livery.** `emitModel` passes `u: kind.liveryU`, which is 0.5 for the existing five kinds (vehicle_meshes.dart:69-70), so their output is byte-identical. The facade atlas column gives each service vehicle a distinct colour: police, ambulance and fire engine read by colour.
- **Mapping** (in `agent_traffic_pass.dart`, infrastructure; D42). `AgentKind` → `VehicleKind`:
  - Private cars pick coupe or sedan by `variant & 1`.
  - Trucks map to truck, and semis to semi.
  - On sealed worlds, cars and trucks map to rover, the cosmetic rule (city_traffic.dart:520). Service vehicles and buses keep their shapes.
  - Trains and L trains use the existing rail car and train meshes (§11.7).
- **Pedestrians.** `PedestrianMeshes.emitModel`: 1.75 m tall, body and head boxes, no glazing.
- **Tests.** `traffic_meshes_test.dart` gains the new kinds in its "every kind" loops. The family pin (`VehicleKind.airless == [rover]`, line 76) is untouched.

### 13.8 How agents are drawn (E20, E36)

- **Where the code lives.** `agent_nodes.dart`, a `part of 'city_nodes.dart'` (E20's `part` directive).
  - It reaches `CityNodes`' private scene, roots, `_vehicleMesh` and `_anchorTransform` without widening their API.
  - It keeps its **own** slot map. The cosmetic `_trafficSlots` and the `place` closure inside `_syncTraffic` (city_nodes.dart:2149-2175) are not touched.
- **Cosmetic road cars off.**
  - In `_syncTraffic`'s cascade (2125-2129): `..maxVehicles = snap.cityTraffic.isEmpty ? _maxVehicles : 0`.
  - It is set **before** `..begin(_structureSig)`, because `begin` captures each sink's cap (`sink._reset(maxVehicles)`, city_traffic.dart:703-717). Setting the cap after `begin` would change nothing.
  - A frame carrying any agent colony zeroes the cosmetic road-car cap for every body; City Builder has one colony.
  - A per-body cap needs `city_traffic.dart` (C9), which matters only once slice 11 runs agents beside non-agent colonies.
  - Cosmetic trains are not counted against the cap (city_traffic.dart:611-614). They keep running until slice 9b.
- **Independent of the `traffic` toggle.**
  - `_syncAgents` runs after `_syncTraffic` (1208), outside its `if (!traffic)` early return (2111-2114). The cosmetic toggle hides scenery, not the simulation.
  - Agents have their own render knob, `agentsDrawn`.
- **Near and far slots.**
  - Keys are `'$bodyId/agent/${kind.name}/near|far/solid|glazing'`.
  - Near slots cast shadows. Far ones, beyond `agentShadowRangeM = 800` m from the focus, are created with `castsShadow = false`, which saves one packing pass per far instance (59 ns per instance per pass: perf-threading report §1.6).
- **Distance rings.** Selection fills rings of 0–500, 500–1,500 and 1,500–3,500 m nearest-first, taking agents in column (slot) order within each ring. Lanes are bucketed into rings by their geometry bounds, once per geometry. The result is deterministic, and the cap goes to what is near.
- **High-water counts.**
  - Per slot, the pass keeps `hw = max(hw, roundUp(count, 64))` and pads the buffer with zero-scale matrices.
  - The count only grows, so the in-place `setInstanceTransform` path is taken (as `_setInstances` does at 2217-2225). Agents coming and going never trigger `clearInstances()`.
  - `hw` resets when the slots are dropped.
- **Caps.** `agentRenderCap` (a static knob, default 1500) and `agentRangeM` 3500. Pedestrians and parked cars have their own caps (§7.4, §8.4).
- **`_syncAgentExtras`** runs after `_syncRoadOverlay` (1214): signal heads, pedestrians, parked cars, traffic overlays.
- **Baked parked cars** are switched off before the first frame (E26 plus E36, §7.4).
- **Timing.** Reported as `phaseMs['city.agents']`.

### 13.9 Overlays

- **Traffic view: the lane-speed view (V), beside the road agent's Routes view (C8).**
  - Toggled by key **V** (free in `_simKeys`, simulation_view.dart:1211-1242) or a HUD chip, into the `TrafficOverlayState.trafficView` static.
  - Draws lane ribbons from the geometry, coloured by `laneSpeedPct`: green ≥ 70, amber 40–70, red < 40.
  - One mesh per body, rebuilt only when the `laneSpeedPct` identity changes (every 2 s), following the signature pattern of `_syncZoning` (city_nodes.dart:2417+).
  - Also shows red dots for stuck-despawn hotspots, and warning markers for `danglingDeck` nodes, broken stops and broken stubs.
  - **Routes through a road** are the road agent's Routes view, not ours. It reads `city.trafficReadout.routesThrough` (road_tool_scene.dart:578-603), which in an agent colony is our readout from slice 1: the locked routes of the live vehicles using that road, in the `TripRoute` shape (traffic_readout.dart:26-46; §12.3). Their view needs no second code path.
- **Route inspector.**
  - `CityNodes.vehicleNearBF(bodyId, bf, radiusM: 4)` scans the agent pose buffers drawn this frame (≤ 1,500 entries).
  - It is called only from the pick layer's `open` predicate (simulation_view_colony.dart:1009-1010, which `_PickGate` runs on every click and hover hit test, a few microseconds) and from `_inspectCityAt`.
  - The picked handle goes into `TrafficOverlayState.selected`.
  - `CityAgents.describe(handle)` returns: kind, owner, purpose, origin and destination site ids, trip time against free-flow, stuck timer, and the remaining connector list with its lanes.
  - The view draws the remaining route as a ribbon (from geometry plus connectors) in `traffic_overlay_nodes.dart`. Like `PlannerOverlay`, this state is UI-only, never on the frame (simulation_view.dart:289; scene_sync.dart:140).
- **Service heat.** Per-building accumulator heat through the existing `heatBF` / `heatKind` statics (city_nodes.dart:510-513), per kind, while the Services drawer is open.
- **Stops, stations and stubs.** Rings and arrows from the `net` and `transit` columns. Bus shelters are drawn at resolved stops (§11.1).

### 13.10 `city_traffic_test.dart`

It is **not retired** (D29). The cosmetic `CityTraffic` pass is unchanged and still serves:
- the city studio, which never ticks `CitySim` (city_studio_screen.dart:1198-1204, 2327);
- colonies with agents disabled, until slice 11.

Its byte-equality test keeps holding. We only **add** `agent_traffic_pass_test.dart`. Retiring the cosmetic pass is a non-goal until the studio has a ticking driver.

---

## 14. Persistence

### 14.1 What is saved

Under `CitySim.toJson()['agents']` (E15), present only when `agents.hasState`. From slice 1 the block is at least `{"v": 1, "enabled": true}`, so a save and load keeps agents on. T4a adds `sites` and the lot rows of `cars`, with the opaque owner of §18 until slice 3 ports ownership to citizens. Slice 3 adds the rest:

```json
{ "v": 1, "enabled": true, "serves": [0,1,2,3],
  "timeUs": 123400000, "rng": [a,b,c,d],
  "seq": {"stop": 12, "line": 3, "oc": 2},
  "sites": ["cell-212", "lot-r3-l2", "..."],
  "cit":  {"home": [..], "work": [..], "car": [..], "state": [..], "wakeInUs": [..], "flags": [..]},
  "cars": [[ownerIdx, where, siteIdx, stallKey, variant], [ownerIdx, where, siteIdx, e, n, headingMilli, variant], ...],
  "acc":  {"g": [..], "c": [..], "cr": [..], "m": [..], "sick": [..], "goods": [..]},
  "depots": {"<siteIdx>": buffer, ...},
  "ledger": {"mig": 0.4, "death": 0.7, "ext": 0.0},
  "stops": [...], "lines": [...], "outside": [...],
  "trade": {"imp": 0, "exp": 0}
}
```

- **Ordering.** `sites` is the string table, **sorted by site id**. Every column is indexed by the sorted order, so a save is deterministic (fidelity graft).
- **Format.** Columns are plain JSON number lists; the codec is JSON (game_state_codec.dart:58-59).
- **Citizens** are written densely, in slot order at save time. `home`, `work` and car `siteIdx` are indices into `sites` (−1 for none).
- **Parked cars:**
  - in a lot, from T4a: `[ownerIdx, where = 0, siteIdx, stallKey, variant]`, i.e. by `(siteId, stallKey)`, **never by stall index** (C-19). `siteIdx` names the lot or site id string current at save (renames follow `_carryRenamedLots`). On load, after the site-access full drain (site-access §4.4), the stall is `stallIndexOfKey(stallKey)` on the site's plan; if the key is gone, the nearest free stall by distance; if there is none, the car is garaged. A site unknown after load drops its lot cars. Reservations and vehicles inside sites are not saved;
  - at the kerb: `where = 1`, with `(e, n, heading)`, re-snapped on load to the nearest kerb slot within 12 m whose heading is within 45°;
  - garaged: `where = 2`.

### 14.2 What is re-derived on load

- The lane graph (from the loaded colony's `RoadGraph`), the pedestrian graph and access points.
- The building table (capacities from specs).
- Depot fleets, kerb capacity, skims.
- Edge delays, which start at 0.
- The path queue, vehicles, pedestrians and signal plans. The signal phase comes from `timeUs`.
- Requests are re-raised on the first tick from accumulators above threshold.

### 14.3 Agents in flight

They are **not saved**. That follows the `toJson` philosophy that transient machinery re-derives (the comment above `CitySim.toJson`, city_sim.dart:4302), and it avoids saving a route arena tied to one graph object.

On load:
- A citizen who was travelling resumes at their trip **origin**, with `wakeInUs = 5 s`. Their car is where it was parked before the trip.
- Service vehicles are back at their depots; their payloads are lost (logged in `stats.loadDropped`).
- Freight cargo in transit is lost. Visitors in town are dropped.
- Buses and trains respawn spaced along their lines.
- The `warmupS` spawn ramp (§5.7) prevents a burst.

### 14.4 Schema and versioning

- Additive only:
  - `GameStateCodec.schemaVersion` stays **1** (game_state_codec.dart:35).
  - An absent `agents` key means disabled. A colony that enables agents later (the drawer button; slice 11 for every colony) starts with citizens reconciled from `population`, through the `external` budget.
- `agents.v` bumps on any change to the agents schema. `restore` migrates the previous version or drops the block with a logged warning.
- Enums saved by index (`CitizenState`, `ServiceKind`, the car `where`) are **append-only**.
- **Load order.**
  - `fromJson` builds the layout and calls `recompute()` (city_sim.dart:4410-4580). `agents.restore` (E16) runs **after** that and only stores the JSON.
  - Binding sites to building ints happens lazily on the first `advance`, once lot ids exist.
  - An unknown site id drops the home or job. It happens with a lot renamed by a changed plat rule, or a megatower or strip mall that vanished on load (services-economy report §5.9). The citizen becomes homeless or unemployed and is re-matched.
- **The in-memory save.** `SimulationView._save`/`_load` (simulation_view.dart:2622-2661) round-trip every colony through `CitySim.fromJson` (game_state_codec.dart:229). From slice 1 that keeps the `enabled` flag, so loading a City Builder game no longer turns agents off.

### 14.5 Dependency on the road agent

**Resolved on dev.**
- Splits carry `reversed`, `deck`, `decoration` and `name` (city_layout.dart:599-601, 791-793).
- Saves persist them, with junctions per colony (commit 121277e).
- The wire flips reversed roads and fills `id`, `decoration` and `lifts` (world_snapshot.dart:2134-2182, commit 56a8cb2).
- So a reversed one-way road loads pointing the way it was saved, and routes after a load match the network that was saved. Stops, stubs and kerb cars still re-snap by position and heading, which also covers a lot renamed by a re-cut.

---

## 15. Performance and threading

### 15.1 Budgets (targets; the slice-1 benchmark must confirm them)

The design point is a City Builder colony of 5,000 citizens, 2,000 vehicles, 1,000 pedestrians and about 2,000 roads.

| Work | Cost basis | At 1× (5 sub-steps/s) | At 25× (≈2.08 sub-steps per 60 Hz frame on average) |
|---|---|---|---|
| Vehicle step | ≤ 80 ns per vehicle (IDM, leader, hand-over) | 0.16 ms per sub-step, landing on 1 frame in 12 | ≈ 0.33 ms/frame |
| Path pump | ≤ 4,000 expansions × ≈ 150 ns = 0.6 ms per sub-step | 0.6 ms on 1 frame in 12 | ≈ 1.25 ms/frame |
| Pedestrians | ≤ 40 ns each | 0.04 ms | 0.08 ms/frame |
| Building sync, accumulators, dispatch | O(buildings), in quarters per advance | ≤ 0.1 ms per tick | ≤ 0.1 ms per tick |
| **Catch-up frame** | The host runs up to 25 ticks in one frame (simulation_view.dart:1941-1950). At ≥ 25× each tick is dt 0.5 s (simulation_clock.dart:31; city_sim.dart:1178), so one frame can owe 62 sub-steps. | — | ≈ 50 ms inline **without** the hold; **≤ 4 sub-steps ≈ 3.2 ms with the hold** (D35), the rest replayed on later frames |
| Capture | O(1) references plus a cached-geometry key compare | ≤ 0.05 ms/frame | same |
| Geometry rebuild | Only on a graph or terrain change; slices the capture's own `RoadSnapshot`s, with no ground reads | a few ms, once | — |
| Graph derivation and remap | ≤ 5 ms for 2,000 roads (the `RoadGraph` build itself is the routed model's, already paid); remapping ≤ 4 ms at 4,096 vehicles | once per edit | — |
| Render pose pass | 1,500 vehicles and 800 pedestrians × ≈ 0.3 µs, plus packing (59 ns × 2 passes near, × 1 far) | ≤ 0.8 ms | same |

**Hard gates**, enforced by the benchmark and by the in-app A/B:
- inline agent work ≤ 1.5 ms in **every** frame at 1×, and ≤ 3.2 ms in **every** frame at 25×, catch-up frames included (the hold makes these maxima, not averages);
- render pass ≤ 1 ms;
- **slice 1:** frame p95 ≤ baseline + 1 ms with 1,000 agents in City Builder (scale graft);
- zero allocation across 1,000 sub-steps after warm-up.

These fit the 2–4 ms of in-motion headroom under the 15 ms target (perf-threading report §1.5).

**`FrameBudget` visibility** (E26 and E28, slice 1).
- `SceneSync.frameBudget.feed` (scene_sync.dart:354-355) includes `tickCostMs`: the frame's measured tick-loop time, `endFrame` included (simulation_view.dart:1934-1950).
- It does so **only while an agent colony ticks**. Otherwise `tickCostMs` is 0, and every other mode, the flight view at high warp included, behaves exactly as today.
- `TrafficMetrics` reports `phaseMs['city.agents.tick']` separately.

**No wall-clock ladder** (D9).
- **Simulation shedding is deterministic:** the vehicle cap, the path-queue caps, the per-sub-step spawn and dispatch caps, and the frame hold. All of them are counted, never timed.
- **Wall-clock milliseconds drive only render-side shedding**, and never touch simulation state.
  - `CityFrameGovernor` exists only in the city studio (city_studio_screen.dart:186, 287), where it scales `CityNodes.trafficDensity` (303-306). The studio never ticks agents.
  - In City Builder there is no governor: `agentRenderCap` is a static knob, set by the A/B tooling, not by frame time.

### 15.2 Allocation-free rules

- Typed columns and `SlotPool` free lists only. They grow by doubling, during warm-up or on a rebuild.
- A* scratch is reset by generation stamp. The heap is typed. Contexts are reused.
- The route arena uses size classes and compacts into a preallocated twin.
- There are no closures, `Vec2`s, records, `Map`s or `List`s in the step, mover, arbiter, planner or pump loops. Occupancy lists are intrusive; queues are ring buffers.
- Graph derivation, geometry build and building sync may allocate; they run only on edits, on syncs or once per 2 s.
- The building sync iterates `autoParcels` and `manualParcels` (views, city_layout.dart:141-142). It never uses `layout.parcels`, which allocates (137), and never `parcelBuiltLots()`.
- The one small allocation per sub-step is the frame wrapper (§13.2). The frame hold's tick queue is a preallocated `Float64List` ring.
- **Gate.** `traffic_alloc_test` runs 1,000 sub-steps after warm-up under `developer`-service heap sampling. The bar is new-space growth under 64 KB, excluding the wrappers.
- **Status after slice 1: the weighed gate is NOT met; the structural half is.**
  - Structural (always runs): no column, arena, queue, search context or frame set is reallocated in steady state (`collectBuffers` on every table).
  - Weighed (`fvm flutter test --enable-vmservice --dart-define=ACRO_ALLOC=true test/traffic/traffic_alloc_test.dart`, debug JIT): 33.8 MB over 1,000 sub-steps beyond the frames, at ten times the design commute rate with 511 routes waiting to pull out. The pull-out queue (`TripPlanner.spawnReady`) boxes about 64 B per waiting route per sub-step; the mover about 120 B per vehicle. The agent clock's microseconds pass 2³⁰ after 1,074 s, and every one passed across a non-inlined call is then a boxed int on a compressed-pointer build.
  - Impact: short-lived new-space garbage, about 4 MB/s at 25× in that saturated case, well under the renderer pacer's deliberate 1 MiB a frame. Not a slice-1 blocker; owed by slice 11.

### 15.3 Inline or worker isolate

**Slices 1–10: inline** (`SyncAgentScheduler` is simply `CityAgents.advance`). Reasons:
- City Builder colonies are small.
- The web build has no isolates.
- Inline is deterministic, runs headless in tests, and needs no protocol.
- The one-tick contract (§6.2) already makes the economy read only published outputs.
- The frame hold (§5.7) bounds the worst frame.

**Slice 11: `IsolateAgentScheduler`,** behind `AgentScheduler.platform()`, a conditional import on `dart.library.isolate` following mesh_scheduler.dart:24-31.
- One persistent worker owns the `AgentCore` (every table and the graph; everything except `CitySim`).
- **Inputs:**
  - Per graph object: road and parcel columns as typed lists, **shipped once**, as the terrain pool ships its field once (mesh_scheduler_isolate.dart:17-24). Object graphs are never sent: a send deep-copies, and 13 sends once cost 214 ms (city_nodes.dart:1376).
  - Per tick: small typed deltas `{dtUs, budgets, building capacities, renames, clears, tool commands}`.
- **Outputs:** the `AgentFrame` and `PedFrame` bytes for **in-range rows only** (≤ 64 KB) through `TransferableTypedData`, plus a derived-scalar block.
- **Determinism** (D21). Dart cannot block on a port, so **the city clock waits for the agents**.
  - `CitySim.advance` holds its economy dt in `agents.cityClockHeldS` until the worker confirms the agent step for that time, then applies it. This is the frame hold's queue (§5.7), drained by worker confirmations instead of a sub-step budget.
  - The economy sees the same agent outputs at the same agent times as it does inline.
  - A slow worker slows the city, which is CS behaviour.
  - A **free-run** mode (never hold the clock) exists behind the `agentWorkerFreeRun` knob for profiling only, and is documented as non-deterministic.
- **Risk.** In AOT the isolates share one heap and garbage collector (perf-threading report §1.4). The worker obeys the same no-allocation rules.

### 15.4 Knobs (E24; each backed by an `AgentTuning` or `CityNodes` static)

**Simulation knobs.** These change determinism, so twin runs must share them.

| Knob | Default |
|---|---|
| `agentsOn` | flag, on for City Builder |
| `pathExpansionsPerStep` | 4000 |
| `pedExpansionsPerStep` | 1500 |
| `maxVehicles` | 4096 |
| `maxPeds` | 4096 |
| `maxQueuedPaths` | 512 |
| `maxQueuedServicePaths` | 128 |
| `maxSpawnsPerStep` | 24 |
| `stuckDespawnS` | 120 |
| `impatientGrantS` | 25 |
| `dontBlockBox` | on |
| `dispatchByPathCost` | off |
| `activityDwellScale` | 1.0 |
| `outOfTownShare` | 0.08 |
| `freightEconomy` | on from slice 8, after its balance test |
| `fleetUpkeep` | 0.02 § per vehicle-second, from slice 8 |
| `connectionsAllowMigration` | off |
| `freightRail` | off |

**Scheduling knobs.** These change *when* ticks run, never results.

| Knob | Default |
|---|---|
| `maxAgentSubStepsPerFrame` | 4 |
| `maxHeldCityS` | 10 |
| `frameBudgeted` | set by the host per colony; not a user knob |

**Render knobs.**

| Knob | Default |
|---|---|
| `agentsDrawn` | on |
| `agentRenderCap` | 1500 |
| `agentRangeM` | 3500 |
| `agentShadowRangeM` | 800 |
| `pedRenderCap` | 800 |
| `pedRangeM` | 600 |
| `parkedRenderCap` | 1500 |
| `agentWorker` | 0/1, slice 11 |
| `agentWorkerFreeRun` | 0 |

### 15.5 Benchmark plan (`test/traffic/bench/`, tagged by name and skipped by default; 5-minute timeout like the existing benches)

1. **`graph_build_bench_test`.** Lane-graph derivation and remap from the `RoadGraph` of:
   - the starter kit;
   - a 4-block generated core (`CityGenerator`, sprawl 0);
   - a synthetic 30×30 grid (about 3,600 edges);
   - the roads of a 2-mile sprawl.
2. **`path_search_bench_test`.** 1,000 random origin–destination pairs on the grid: expansions per request, µs per expansion and µs per request, for the edge A* and for the (edge, lane) state search.
3. **`agent_step_bench_test`.** 2k and 4k vehicles on the grid for 1,000 sub-steps: ns per vehicle per sub-step, and allocation (the §15.2 gate).
4. **`agent_warp_bench_test`.**
   - The headless starter colony at 5,000 citizens for 10 agent-minutes of `advance(0.5)`: per-tick p50 and p99.
   - **The catch-up frame:** 25 × `advance(0.5)` then `endFrame()` per simulated frame.
     - With `frameBudgeted` off, it measures the worst-case hitch, which is reported.
     - With it on, it checks ≤ 4 sub-steps per frame, gated at ≤ 3.2 ms, and measures the queue's drain time back to empty.
5. **`agent_pass_bench_test`.** The agent pass with 1,500 vehicles and 800 pedestrians: µs per frame.

**In-app A/B:** run `tool/city_perf_ab.dart --knob=agentsOn` through `tool/drive_city_game.dart` against a founded colony with 1,000 agents (`traffic=spawn`), and check the slice-1 p95 gate. Never measure while other agents run tests (perf-threading report §1.4, measurement noise).

---

## 16. UI and dev hooks

### 16.1 Tools (`TrafficToolController`, our own; D22)

- **Bus line** (slice 9): §11.5. **Rail line** (slice 9b): the same tool in rail mode, with stations instead of stops (§11.7).
- **Outside connection** (slice 8):
  - Hover highlights qualifying free ends (§10.4) within 25 m of the cursor.
  - A tap on a free end toggles its stub. Enabling costs 200 § and needs the end at least 1.5 km from the origin. Disabling is free, and is a network edit (§4.7).
  - The ghost is an arrow marker with the label "to the next colony".
  - The starter spurs' stubs (E17) exist, enabled, from founding.
- **Where they live.** All tools are opened from the HUD's Transit drawer. Buttons in their editor toolbar (city_edit_overlay.dart:341) are a request to the road agent (C4).
- **Routing input.** Taps and hover reach the controller through E27's early returns. While a tool is held, the pick layer's gate opens and claims the pointer (E26 f).
- **New buildings** (Post Office, Fire Station, Bus Depot, Cargo Terminal) use the existing Build tool.

### 16.2 Panels (`city_traffic_panels.dart`, reached through E29)

- **HUD chip:** "Flow 82% · 412 cars" (Flow = 1 − `congestionIndex`). Tapping it opens the Traffic drawer.
- **Traffic drawer:**
  - flow; vehicles by kind; pedestrians; parked cars;
  - average trip time against free-flow; late share;
  - stuck, wedge and edit despawns per minute;
  - path queue and deferred trips;
  - parking give-ups and average walk from the car;
  - stub traffic: visitors, inbound, outbound and through; mode split (walk, car, bus, rail);
  - the 5 worst edges (tap one to frame it).
- **Services drawer.** Per `ServiceKind`: open requests, oldest request age, fleet in use against total, depot buffers, backlog scalar, average response time, unreachable requests (§9.3), and the 5 worst buildings (tap to frame).
- **Transit drawer:** bus and rail lines, vehicles, riders per 10 minutes, average wait, late share, stops and stations (broken ones in red), and the tool buttons.
- **Budget drawer:** trade income, fares, and fleet, bus and train upkeep lines (E29, E5b).
- **Site sheet**, through `CitySiteHooks.extra` (city_site_actions.dart:48-49):
  - residents / housing, workers / jobs;
  - parking (used / capacity);
  - accumulator bars with request ages;
  - a depot's fleet and buffer;
  - "unreachable" when access fails.

### 16.3 Overlays

The traffic view, route inspector, service heat, stops and stubs (§13.9). They are statics in `TrafficOverlayState`, reset in `dispose` (E26).

### 16.4 `ext.acro.citygame` (E25)

`main_city_game_dev.dart` founds its colony with `agentTraffic: const bool.fromEnvironment('AGENTS', defaultValue: true)` (69-76), so the headless entrypoint has agents unless told otherwise. Parameters are handled **before** the status that is always returned (124). Each maps to a `CityAgents` debug API on the captured `colony`.

| Parameter | Action |
|---|---|
| `agents=on\|off` | enable or disable agents |
| `serve=garbage,police,…` | set the `serves` flags |
| `traffic=stats` | add the detailed stats block |
| `traffic=spawn&n=<k>[&from=<site>&to=<site>]` | force car trips (random built origin and destination by default) |
| `vehicle=<handle>` | the `describe` dump |
| `service=<kind>[&site=<id>&amount=<x>]` | per-kind requests, fleets and backlogs; optionally inject an accumulator |
| `line=add&mode=bus\|rail\|L&stops=e,n,h;e,n,h;…&vehicles=<n>` | create a line |
| `oc=add&e=<e>&n=<n>` / `oc=off&id=<id>` / `oc=clear` | stubs |
| `road=add&pts=e,n;e,n&class=<index>` | `commitRoad`, to exercise remaps live. An avenue across a starter street gives a signalised junction. Their `ext.acro.roadtool` (151-164) lays a road the player's way instead: snapped, priced and built with `buildRoad`. |
| `step=<cityS>` | advance the colony headless by agent seconds in `advance(0.5)` chunks, for scripted scenarios |
| `graph=audit` | node, edge, lane and connector counts; dead ends; dangling decks; no-access sites; stub state |

`_status` (206-224) gains:

```
agents: {enabled, citizens, visitors, vehicles, peds, parked, pathQueue, deferred,
         flow, avgTripS, lateShare, despawn: {stuck, wedge, edit}, parkingGiveUps,
         held: {ticks, cityS},
         services: {kind: {pending, busy, fleet, backlog, unreachable}},
         stubs: {in, out, through},
         graph: {rev, nodes, edges, lanes, connectors, deadEnds, danglingDecks}, tickMs}
```

- `SimViewControl` (E32) gains `selectVehicle`, `setTrafficView` and `trafficTool`, all nulled in `clear()` (sim_view_control.dart:96-115).
- `tool/drive_city_game.dart` (E33) takes positional arguments, `<uri> [out.png] [waitSeconds] [walk]`, and `--script=<steps.json>`, a list of extension calls replayed after the settle (10-17, 26-49 and 73-85).
  - It gains one rule: every later bare argument of the form `key=value` is forwarded to `ext.acro.citygame` before the status call.
  - Example: `drive_city_game.dart <uri> shot.png 20 - zone=residential step=600 traffic=stats`, where `-` keeps the fourth positional empty.

---

## 17. Testing strategy

**Location and fixtures.** Everything lives under `test/traffic/`, uses `flutter_test` (the repo convention), and shares `traffic_fixture.dart`:

| Fixture | What it builds or does |
|---|---|
| `foundFlat({roads})` | `CitySim.found` (the parcel_growth_test.dart:20-32 pattern), then `commitRoad` for each road, so splits are **real** (road_graph_test.dart:70-75). Never `addRoad`. |
| `grid(n, spacingM, cls)` | A street grid |
| `signalised()` | An avenue crossing a street. The avenue is split into two arterial legs, so the class-only warrant gives signals (road_junction.dart:77-81). |
| `starterKit({agentTraffic: true})` | The City Builder founding |
| `place(site, spec)` | Put a building on a site |
| `run(city, seconds, dt: 0.5)` | Advance the city (no frame hold unless `frameBudgeted` is set) |
| `forceTrip(from, to, kind)` | Queue a trip between two sites |
| `routeOf(handle)`, `laneOn(handle, edge)` | Inspect a vehicle's route and lanes |
| `stall(handle)` | `CityAgents.debugStall` |
| `freezeDelays()`, `setDelay(edge, s)` | Pin the delay table, for tests whose arithmetic assumes a known `D` |

**Every scenario sets** `hostility = 0` and `autoDisasterTimer = 1e9`. This keeps the 20 unseeded `math.Random()` calls in `CitySim` (city_sim.dart:889 … 4223) from firing:
- the disasters that start grid fires (`fireTick`, 2587-2589) and parcel fire sparks (4181-4187) never happen;
- with the fire flag on, lot fires, their spread and their ignition run on `TrafficRng` (E11), so they are deterministic too.

### 17.1 Unit tests

- **`traffic_rng_test`.** The golden first 32 outputs of a seed. JSON round trip. `fork` gives independent streams. `fnv1a32` and `mul32` goldens, also run under `--platform chrome` in CI where available.
- **`graph_derivation_test`:**
  - Lane-graph edge ids equal `RoadGraph` edge ids, and node kinds follow §3.2.
  - A junction-override toggle yields a patched graph (`sharesStructureWith`): controls refresh, and nothing is remapped.
  - A road edit yields a new graph: a rebuild and a remap.
  - Polling reads `roadGraph` only when `roadsRevision` or `layout.version` moved.
- **`lane_graph_builder_test`** (each case named):
  - **Starter crossroads.** Two `RoadClass.street` roads (city_starter_kit.dart:175-182) give 1 four-leg node plus 4 dead ends, 8 directed edges and **8 lanes**.
    - 12 non-U connectors at the centre (one lane each way, so lane 0 gets R, S and L: rule 1), and 4 dead-end U-turns.
    - No rule-5 shifts, because there is only one lane.
    - The kind is `allWayStop`: the class-only warrant gives `stop`, and every inbound leg stops.
  - **A street T-snapped mid-road** joins the graph's attach node.
  - **A ramp ending 12.8 m beside an expressway6** joins the attach node. Its only connector goes to mainline lane 0 on the correct carriageway.
  - **A cloverleaf** loop ramp (ground level) merging onto the bridged over-road's split end joins it. The split ends sit about 8 m up by `bridgeLiftAt`, but a draped road has no level, and two ground ends always meet (`CityLayout.levelsSeparated`).
  - **An elevated road** crossing a street in plan shares **no** node.
  - **Levels by the layout's rule** (D48). Two deck ends 4 m apart in height share a node, and 5 m apart they do not. A deck end on its piers does not join the street below; the same deck graded into the ground does. A deck saved with `rangeLengthM` and re-sampled on load keeps its end on its piers.
  - **A reversed one-way** gives a backward edge only.
  - **Tapers.**
    - A 6→4 taper keeps 3 lanes to the seam, and the seam's continuation drops in-lane 0 into out-lane 0.
    - **Avenue-width taper:** a radial expressway6 tapered to the avenue's 8.0 m half width keeps its lanes, and its seam with the avenue drops 3→2. No edge has zero lanes.
  - **The beltway seam,** tested both ways:
    - without interchanges, it is a ring piece (`from == to`) whose continuation joins the edge to itself;
    - with interchange splits, it is an ordinary continuation.
  - **The 6→4 seam** gives `continuation`, not `merge`.
  - **A dead end** has U connectors.
  - **Rail and transit** are excluded.
  - **Lane offsets** equal `LaneLayout.laneOffsets` for every class and decoration, and street lane 0 is at 2.0.
- **`lane_connectors_test`:**
  - n=1, m=3: lane 0 makes R, S and L.
  - n=2, m=3: lane 0 makes R and S; lane 1 makes S and L.
  - Boulevard (n=3) at a 4-way: straight from all three lanes; R from lane 0 only; L from lane 2 only; rule-5 shifts 0↔1 and 1↔2 on the straight.
  - A lane drop is median-aligned, and the dropped lane merges into lane 0.
  - A merge never reaches the far carriageway.
  - No rule-5 connector at a continuation, ramp merge or stub.
- **`node_control_test`:**
  - Kinds equal §3.2's mapping of `RoadNode.plan` at every node.
  - On the generator fixture, at every node the tiles draw (`RoadMesher.junctionsFromEnds` over the same roads), `RoadMesher.junctionPlan` gives the same control. A mismatch is reported to the road agent (C1), since both functions are theirs.
  - An override with `lights: true` flips stop to signals through `withOverrides`, and **editing an override in place** refreshes the control.
  - Stop legs come out in heading order.
  - **Drawn legs only** (D48). A street seam with an alley T is `uncontrolled`, and the alley gives way. A four-way street stop with an alley as a fifth leg stays `allWayStop` over its drawn legs. No alley or path leg is ever in `stopLegs`, and `stopLegs` index `RoadNode.legs`.
  - **Leaving legs.** At a leg-aware junction, an off-ramp or a one-way street leaving an avenue stops nothing on the avenue, and an on-ramp's own leg stops.
- **`signal_plan_test`.** `stateAt` is periodic. Offsets are stable across a split (keyed by position). Two axes are never green together. The amber and all-red durations hold.
- **`access_points_test`:**
  - Access equals `RoadGraph`'s `lotPiece`, `lotS` and `lotDirs`.
  - The side comes from geometry, not from the `'r'` letter, and agrees with `lotDirs` on roads with two or more lanes each way.
  - A manual lot within 90 m resolves; one at 91 m does not.
  - The starter spaceport gets access.
  - Far-side driveway access is allowed on a one-lane street and refused on an avenue (two lanes each way). The left kerb works on a one-way road.
  - A grid building resolves through `attachFootprint`.
- **`path_search_test`:**
  - A* cost equals Dijkstra cost (`h ≡ 0`) on 200 random origin–destination pairs on a random grid.
  - The route is identical for budgets of 1, 17 and 4,000 expansions per sub-step (resumability).
  - Ties are deterministic.
  - The sink heuristic is admissible.
- **`lane_planner_test`.** Backward sets are never empty for free starts. The destination lane is 0 for right-kerb arrivals. Unnatural landings are minimised.
- **`lane_state_search_test`:**
  - **The avenue example** (n = 2, m = 3): the vehicle is fixed in lane 0, and its goal needs a left three nodes on. The result is drivable: straight into lane 1 by rule 5 and a later left, or a right turn and a block round. It is never an infeasible sequence.
  - A fixed-lane re-plan starting with a left from lane 0 at the very first node never returns that left.
  - Every returned route is connector-contiguous.
- **`edge_delay_test`:**
  - EMA and decay use the lookup table.
  - Publishing makes a new buffer every 2 s.
  - A suspended search keeps pricing from its captured buffer across a publish.
  - **An empty network gives |D| < 1 s** on signalised edges after 10 agent-minutes of light traffic. This pins `J` to the real mean control delay.
  - `flowPerMin` rolls every 60 s.
  - A slow driver (f = 0.92) on a free edge reports ≈ 0.
- **`route_arena_test`.** 10k random alloc/free cycles cause no growth after warm-up. Compaction preserves every live route.
- **`route_remap_test`.** Named cases:
  - a single split;
  - nested `x` chains;
  - a split within 8 m of a node (sliver dropped) with the children joined by a node;
  - a lane-count change: the sticky repair touches only the affected span, and downstream connectors are unchanged;
  - **a fixed-start repair that is infeasible** (the avenue example): the remap fails, followed by one re-plan;
  - a one-way reversal (impossible, so a re-plan);
  - a removal (impossible);
  - **an end drag** (`moveRoadEnd` re-lays under `childIdFor`): vehicles on the unchanged stretch stay, the others despawn, and routes through the road re-plan;
  - an unrelated road added (no change).
- **`idm_test`.** A single-lane queue settles without overlap. The speed limit is respected. h = 0.2 s is stable. A stop inside the step is exact.
- **`service_dispatch_test`:**
  - Straight-line dispatch picks the near-as-the-crow-flies depot even when it is far by road.
  - The in-use factor spreads load across depots.
  - Chaining stays within 600 m.
  - A despawned truck re-queues its requests with the original stamps.
  - **A depot on a disconnected road** yields to the next depot. With none left, the request backs off 60 s and counts as unreachable. It never spends path budget every second.
- **`population_ledger_test`.** Budgets realise to whole citizens. An external write becomes a budget. Deaths pick residents.
- **`traffic_readout_test`** (slice 1; the D47 contract):
  - before the first picture (the first congestion epoch, 2 s of agent time, with or without traffic): `hasRun` false, `passes` the routed model's own count, congestion 0, no routes, every reach true, noise 0, a tax factor of exactly 1;
  - `passes` never goes back, across publishes, graph rebuilds, remaps and a save and load, and it moves on every publish and whenever a forwarded answer changes;
  - `routesThrough` lists live vehicles' locked routes: kinds from purpose, weight 1, `roadIds` in route order with each visit once, the polyline from `RoadGraph.polylineOf`, and the `kinds` filter and `limit` honoured;
  - `CitySim.trafficReadout` is `agents.readout` exactly when agents are enabled (E37), and after a tick `parcelCongestion` equals `0.5·(peak + average)` of it;
  - slice 1 forwards reach, noise, land value and the tax factor to `roadTraffic` answer for answer, and a clinic up the street is no fire cover.
- **`agent_reach_test`** (slice 2). Reach follows one-way streets. `fireReach` counts only stations with safety cover. A works' own goods, and its own lorries turning at the next node, are no delivery. A lot the picture does not know is reached. `roadTraffic.advance` never runs in an agent colony.
- **`traffic_capture_test`:**
  - Every car edge's polyline equals the matching slice of that capture's `RoadSnapshot.points`, **byte for byte**. For reversed roads it is compared with the **flipped** snapshot the capture sent.
  - A deck road's `L` equals `ribbonLiftM + RoadSnapshot.lifts`.
  - Geometry identity holds across frames, and changes on a new graph object **or** on a `groundCacheStamp` change.
  - Capture makes zero ground queries.
- **`agent_traffic_pass_test`** (`test/flutter_scene/`):
  - pose on straight and curved edges;
  - C0 continuity across the connector's ends;
  - no negative-determinant basis;
  - the cap and the rings;
  - `instanceCount` stays stable while the agent count moves within a 64-bucket (scale graft);
  - **with 16.7 ms frames against 20 ms ticks, the render clock never stalls on a tickless frame.** It freezes when `SceneSync.simWarp = 0`, and snaps when a hitch exceeds 2h;
  - the cosmetic road-car cap is 0 in agent frames (set before `begin`), and agents draw with `CityNodes.traffic` off.

### 17.2 Property tests (seeded; 200–500 cases each)

- **Connector coverage.** For every allowed movement, every out-lane has at least one feeding in-lane.
- **Lane-planner feasibility.** On random grids, with random decorations and one-way roads:
  - random free-start routes are never lane-infeasible;
  - random fixed-start state searches return only drivable routes.
- **Arbiter safety.** Two conflicting granted connectors are never both occupied short of their conflict point, except for forced grants, which are logged and counted.
- **Lane changes only at nodes.** 500 agents, 2,000 sub-steps. For every agent and sub-step, `laneEdge(elem_t) == laneEdge(elem_{t−1}) ⇒ elem_t == elem_{t−1}` unless an access event is logged, and the lane id is never a sibling lane of the same edge. From T4a it adds the site-element rule of §5.5 (road↔site changes only with a matching ENTER or EXIT; site lanes change only through site movements or stall manoeuvres), run with STRIP and LOOP sites on the grid (site-access A15).
- **Occupancy consistency.** Heads, tails and prev/next round-trip. `gap ≥ 0` after every sub-step.
- **Capacity invariants.** `Σ residents ≤ Σ housing` and `Σ workers ≤ Σ jobs` after each sync. Accumulators are never negative. Loads are conserved: building → vehicle → depot, or lost with a counter.
- **Random edits.** Sequences of commits, splits, removals and end drags never crash, and every surviving route stays connector-contiguous.

### 17.3 Scenario tests: the user's behaviours, one each

1. **`route_locked_despite_traffic`.** Two parallel routes, A (short) and B.
   - Plan X on A, then stall 30 vehicles on A.
   - X's arena slice (hashed) and its lane on every edge are unchanged at every sub-step until arrival.
   - Y, planned after the next delay epoch, takes B. This second half needs the delay table (slice 2).
2. **`faster_slightly_longer_preferred`.** The delay table is frozen at 0 (`freezeDelays`), so the arithmetic holds.
   - A 1,000 m street at 40 km/h costs 90 s × 1.00 = 90.0 s.
   - A 1,150 m avenue at 50 km/h costs 82.8 s × 0.97 = 80.3 s.
   - Junction penalties are equal, so the planner takes the avenue.
   - `setDelay` then puts 20 s on the avenue (100.3 s > 90 s): **new** trips take the street, and trips already planned stay on the avenue.
3. **`new_road_not_used_by_planned_trips`.** Plan 20 trips the long way round, then `commitRoad` a shortcut that crosses their route.
   - All 20 pass straight through the new node.
   - `stats.replans == 0`, and their lane indices are unchanged. Destination lots renamed by the re-cut are carried by E12, so no trip loses its destination.
   - Trips planned after the commit use the shortcut.
4. **`replan_only_when_impossible`:**
   - (a) An unrelated road is added: 0 re-plans.
   - (b) A road ahead on the route is removed: exactly 1 re-plan per affected vehicle, and each still arrives.
   - (c) The road a vehicle is on is removed: that vehicle despawns (`despawnEdit`).
   - (d) A one-way is reversed ahead: the vehicle re-plans.
   - (e) An end drag re-lays a road on the route: those routes re-plan, and nothing else does.
5. **`lane_choice_matches_next_turn`.**
   - On a two-lane **avenue**, a left turn at the next node puts the vehicle in lane 1 and a right turn in lane 0.
   - On a **boulevard** (3 lanes), a left-turner is in lane 2.
   - Through traffic spreads across the lanes (occupancy tie-break).
6. **`lane_changes_only_at_nodes`.** The §17.2 property, run on the starter colony for 10 agent-minutes.
7. **`stuck_despawn`.**
   - A blocked dead end: the follower despawns at 120 ± 0.2 s and never earlier.
   - A garbage truck stuck the same way leaves its target's accumulator unserved, and the request is re-queued with its original stamp.
   - A stuck citizen's car is garaged virtually, and no kerb or lot slot is taken.
8. **`bad_depot_floods_district`.** 200 houses. Case A has the landfill behind a single 2 km detour street; case B has it beside the arterial.
   - After 1,800 s, A shows at least **3×** the mean measured delay on the access street.
   - A has a higher mean `garbage_b` and `wasteBacklog > 0.4`, against B below 0.15.
9. **`freight_cuts_through_when_cheapest`.** Two trunk stubs, E and W, with the delay table frozen at 0.
   - Downtown avenue, 2,000 m: 144 s × 0.97 + 4 signals × 6 s = 163.7 s.
   - Trunk loop, 5,000 m at 80 km/h: 225 s × 0.93 + 2 merges × 1.5 s = 212.3 s.
   - So through semis take the downtown avenue. Avenue is medium tier, so there is no ×1.5.
   - A 2,200 m trunk bypass (99 s × 0.93 + 3 s = 95.1 s) is then built. Only newly spawned through trips use it; trips already in flight do not.
10. **`parking_search`.**
    - (a) The destination edge has 2 kerb slots, the lot is full, and 5 cars arrive. 2 park on the edge, and the other 3 reserve adjacent-edge slots, with `parkWalkM` recorded. No reservation is ever contested.
    - (b) Every slot within 800 m is full. Each car circles exactly 3 times, then gives up: `parkingGiveUps` counts one per car, and the citizen walks.
    - (c) A left-kerb slot on a one-way road is reached in lane `L−1`.
11. **`signals_obeyed_as_drawn`** (on the `signalised()` fixture). For every head at every sub-step:
    - no connector of that head is granted while its state is red or all-red;
    - an amber grant happens only under the dilemma rule, or for a left-turner already at the line with an unoccupied conflict set.
12. **`dont_block_the_box`.** With a saturated exit lane, no vehicle ever waits on a connector.
13. **`service_only_on_arrival`**, for **all six** `ServiceKind`s:
    - garbage, mail and deathcare accumulators decrease only at a collection event;
    - `crime_b` resets only when a police car arrives;
    - a patient is treated only after an ambulance pick-up;
    - a lot fire is suppressed only while an engine is on scene;
    - a depot with no road to its district never serves it;
    - with **no Police Station and only Emergency Services**, `services['safety']` is 0 under the police flag; with no health depot, `treatedShare600` is 0.
14. **`economy_follows_agents`.** A congested commute raises `tripRatio`, lowers `commuteEff` and lowers `staffing`. From slice 1 this uses `CommuteSynth` trips.
15. **`calibration`.** In the starter colony grown to 2,000 people, moving vehicles are 8–12% of population in steady state.
16. **`service_calibration`.** One well-placed landfill, 300 residents:
    - ≤ 5 garbage trucks active;
    - mean request age < 240 s;
    - `wasteBacklog < 0.15`.

    Police utilisation is 20–70% at 400 occupants. Post Office utilisation is 30–80% at 600 occupants. A morgue with 8 hearses keeps up at 0.1 deaths/s, with a mean body age under 600 s.
17. **`deathcare_parcel`.** A placed parcel morgue now processes corpses; the `careRate` draw (1486-1490) never did. `corpses` equals the sum over its sources.
18. **`outside_connection`.**
    - A stub still resolves after the road beneath it is split.
    - **Every inbound vehicle** (visitor, immigrant, import) has a building destination and parks or unloads there. **Every outbound vehicle** (departing visitor, errand, emigrant, export) has an origin building. Through vehicles go sink to sink.
    - Visitor and through rates are within ±15% of their formulas over 3,600 s.
    - There is no stub → sink → stub shortcut.
    - Disabling a stub is a network edit: routes through it re-plan to the other stub, and vehicles on its virtual edge despawn.
19. **`bus_line`.**
    - A stop survives a road split across it.
    - A loop visits its stops in order, and boarding respects capacity.
    - A stop on a deleted road breaks and is skipped.
    - `transitShare > 0` when a line links homes to jobs.
    - A line created before a new road ignores it until the line is edited.
20. **`population_parity`.** §6.2.
21. **`freight_balance`.** §10.3.
22. **`fire_engine`.** A burning lot survives when engines arrive. With no station it burns out in about 6.7 minutes. Spread is identical across twin runs.
23. **`fixed_start_feasibility`.** The avenue example from §3.5, run live: a vehicle held in lane 0 by a failed remap re-plans to a drivable route and arrives.
24. **`pavement_walk_lateral`.** Walkers stay at ±(halfWidth + 2.3) m, on the tube side on sealed roads.
25. **`walk_phase_gating`.** No pedestrian starts a signalised crossing with less than 6 s of walk left.
26. **`vehicles_yield_to_walkers`.**
    - Right-turners on green wait for a committed walker.
    - A walker waiting at an uncontrolled crossing on a busy arterial gets priority after 20 s and crosses.
    - A waiting walker never blocks a car.
27. **`service_no_route`.** A depot on a disconnected road: the next depot serves, or the request backs off, and `unreachable` counts it.
28. **`mail_happiness`.** Happiness drops measurably with no Post Office and recovers after one is built. From slice 8 the same holds for goods with no industry.
29. **`dwell_not_stuck`.** A fire engine on scene for 300 s and a bus dwelling for 60 s are never despawned. A vehicle in `holdAtEdgeEnd` with a queued re-plan is never despawned.
30. **`starter_outside_traffic`** (slice 8). A fresh agent City Builder colony shows at least one stub-inbound, one stub-outbound and one through vehicle within 600 s of agent time.
31. **`bus_delay_no_replan`.** A rider waiting on a bus that traffic has delayed by 10 minutes never re-plans; the trip is scored late.
32. **`rail_line`** (slice 9b). Trains obey blocks (never two in one block), stop at stations, board riders, and appear in the mode split. Cosmetic trains are hidden for the agent colony.
33. **`destination_demolished`.** A vehicle whose destination lot is cleared mid-trip keeps its route and lanes to the old access point, then re-targets with an appended leg. `replans == 0`, and `arrivedGone` counts one.
34. **`no_mode_walks`.** A citizen without a car, 4 km from work, with no line, walks; and job matching used the walk skim.

### 17.4 Determinism tests

- **`twin_run_digest`.** Two cities with the same seed and the same `dt` sequence, including edits mid-run, give identical `CityAgents.digest()` after 5 agent-minutes.
  - The digest is `fnv1a32` over every column, with `s` quantised to 1 mm and `v` to 1 mm/s.
  - It runs with every service flag on, the fire flag included (lot-fire spread and ignition on `TrafficRng`), and with disasters off.
- **`partition_invariance`.** Scoped to **agent state with the economy frozen** (J1's fix):
  - Run `AgentCore` with a frozen `EconomyInputs` snapshot (fixed building table, zero budgets) and disasters off.
  - Split 60 s of agent time as 3,000 × 0.02 and as 120 × 0.5: identical sub-step sequences (integer µs) and identical digests.
- **`frame_hold_invariance`.** The same tick sequence, run inline and through the hold with `maxAgentSubStepsPerFrame` at 1, 4 and 12 and random frame boundaries, gives identical digests and identical economy scalars.
- **`save_resume`.**
  - Citizens, accumulators, cars, lines, stubs, ledger and RNG are equal after a round trip.
  - After the load, the trajectory matches a reference run that dropped its in-flight agents at the same instant.
  - From slice 1: the `enabled` flag survives `SimulationView`'s in-memory save and load (`GameStateCodec`).
- **`binding_equivalence`** (slice 11). The sync binding and the lock-step isolate binding give identical digests and identical published frames for a scripted command stream.
- **`traffic_source_hygiene`** (grep over `lib/domain/colony/city/traffic/**`). Fails on any of:
  - `math.Random(`;
  - `.hashCode`;
  - `Object.hash`;
  - `DateTime`;
  - `Stopwatch` outside `traffic_metrics.dart`;
  - iterating a `Map` or `Set` outside `agents_codec.dart` (which sorts).
    - `.entries`, `.keys` and `.forEach(` always count as iteration.
    - `.values` counts on any receiver **except** an enum type. The pattern allows `\b[A-Z]\w*\.values`, an enum's `values` (road_graph.dart uses `RoadClass.values` this way), and flags every other `.values`.

  It also checks the 4-line header, which `source_hygiene_test` already does repo-wide.

Determinism is claimed **per platform**. Cross-platform bit-identity is not claimed: no transcendentals run in the sub-step, but doubles may still compile differently.

### 17.5 Tests that change or must stay green

**Must stay green in every slice:**
- `test/flutter_scene/city_traffic_test.dart` (cosmetic pass unchanged)
- `traffic_meshes_test` (extended, families pinned)
- `parcel_growth_test`, including the fire test at 171-194, with agents off
- `happiness_test`
- `city_starter_kit_test`, with the default `agentTraffic: false`
- `shuttle_cargo_test`
- `city_save_roundtrip_test`, extended with the `agents` block; saves without it still load
- `source_hygiene_test`
- `sprawl_roads_test`
- `test/architecture/installation_massing_test.dart` and `installation_parking_test.dart`, which sweep E22's new site-claiming specs
- the road agent's `road_graph_directed_test`, `road_traffic_model_test`, `road_traffic_window_test`, `road_traffic_economy_test`, `road_ops_test` and `road_wire_test`, and the road tool's `road_tool_controller_test`, `road_tool_scene_test` and `road_tool_panel_test`. We change none of their code, so a failure means a hook leaked.
- `gen_reference_test`, with `docs/REFERENCE.md` regenerated (C11)

**New in slice 1:** `sprawl_topology_audit_test`.
- It generates the small sprawl fixture from `city_generator_test` and builds its `RoadGraph`.
- It pins **upper bounds** on dangling ramp ends (target 0), `danglingDeck` nodes, unjoined cloverleaf merges (target 0) and sites with no access.
- It prints the gap distribution (road-topology report §7).
- Slice 11 gates enabling agents on generated colonies on its targets.

---

## 18. Slice plan

**How each slice lands:**
- Merged into `feat/agent-traffic`, then cherry-picked to `dev` after verification. Per the worktree-cleanup rule, the worktree is brought up to `dev` first and removed afterwards.
- One canonical commit per slice, screenshots excluded, plus a `v0.3.N` tag and a bump to `pubspec`, the stamp and `CHANGELOG.md` whenever it ships to master (prod hotfix tagging).
- Before every merge: rebase on the road agent's latest work, re-check every E-hook's anchor (§1.2), run `flutter test`, run `flutter analyze`, and capture a `tool/drive_city_game.dart` screenshot.
- Every slice is **playable** in City Builder and survives a save and load. The only exception is the scale slice's worker, which is invisible to the player by design.

**Order (revision 4, the user's decision of 2026-09-15):** 1 → 2 → **T4a** → 3 → **T4b** → 5 onward. Slice 4 is split into T4a and T4b (site-access §9). Meanwhile the road side builds R0–R4, which connects the starter sites visibly without agents; T4a needs their R1 and R2a.

Sizes include tests.

### Slice 1 — Real cars on real routes (City Builder) — L, ≈ 5.8k LOC, depends on nothing

**Goal.** In a City Builder colony, the player zones along the starter crossroads and watches buildings grow. Cars then:
- leave homes for jobs and come back on locked A* routes, in the lane for their next turn;
- stop at the drawn stop bars, and obey live, cycling signal heads where a junction has lights (draw an avenue across a starter street to get one);
- U-turn at dead ends and vanish if wedged.

Drawing a new road never teleports a car: routes remap through the split, lots renamed by the re-cut keep their trips, and trips re-plan only when their road is removed. The HUD's congestion figure is measured from vehicle speeds, and staffing follows measured commutes. Saving and loading keeps agents on, and the road tool's Routes view draws the cars' locked routes.

**Commit order:**
- **1a, groundwork (lands dark):** `traffic_rng`, `traffic_time`, `traffic_tuning`, `agent_kind` (every `AgentKind` declared), `slot_pool`, `route_arena`, the fixture, `traffic_source_hygiene`.
- **1b, graph:** `lane_graph`, `lane_graph_builder` (derived from `RoadGraph`), `lane_connectors`, `node_control`, `network_key`, `access_points`.
- **1c, the simulation:**
  - `path_search`, `lane_planner`, `lane_state_search`, `vehicle_table`, `vehicle_mover`, `junction_arbiter`, `graph_lineage`;
  - `building_table`, with capacities, access, and the rename and clear hooks;
  - `trip_planner`, with `CommuteSynth` only;
  - `traffic_stats` (`congestionIndex`; `commuteEff`), `agent_traffic_readout` (congestion, volumes, live routes and `passes`; the rest forwarded to `roadTraffic`), `traffic_metrics`, `city_agents` (with the frame hold), `agent_frame`, `agents_codec` (the `enabled` flag only).
- **1d, wire and renderer:** `city_traffic_frame`, `traffic_capture`, `agent_traffic_pass`, `agent_nodes`, `signal_head_layer`.
- **Edits:**
  - E2, E3a, E3b, E4, E12, E13, E14, E37;
  - E15 and E16 (the flag only);
  - E17 (the flag only), E18, E19, E20, E24;
  - E25 (`agentTraffic`, `agents`, `traffic=stats|spawn`, `vehicle=`, `road=add`, `step=`, `graph=audit`);
  - E26 (a: `endFrame`, `tickCostMs`, `simWarp`; b: `frameBudgeted`; c: dispose);
  - E28, E33.

**Scope cuts:**
- No measured delay: `D ≡ 0`, so cost is free-flow plus penalties. Speed-based congestion and measured commutes still ship.
- Reach, noise, land value and the tax factor are still the routed model's, forwarded through the readout (D46).
- Roundabouts arbitrate as yield-to-circulating; they are already in the rules.
- No parking: vehicles appear and vanish at access points.
- No pedestrians and no citizens.
- Persistence holds only the `enabled` flag (E15/E16), which is enough for a save and load to keep agents on.

**Acceptance.**
- §17.1: derivation, builder, connectors, node control, signals, access, path search, lane planner, state search, arena, remap, IDM, capture equality, pass, and the readout contract (`traffic_readout_test`).
- §17.2: connector coverage, feasibility (free and fixed start), arbiter safety, lanes-only-at-nodes.
- §17.3:
  - #1, the X-locked half only; the "Y takes B" half needs slice 2's delay table;
  - #3, #4, #5, #6, #7 (car variant), #11 (on `signalised()`), #12, #14, #23, #33.
- §17.4: twin run, partition invariance, frame-hold invariance, and the save round trip of the flag.
- `sprawl_topology_audit_test`.
- The road tool's Routes view lists live agents' routes in an agent colony (`ext.acro.roadtool` with `tool=traffic&view=routes`, then a click on a road).
- Benchmarks 1–3 and 5, plus the catch-up case of 4. The p95 ≤ baseline + 1 ms gate at 1,000 agents.
- **Manual:**
  1. Launch `main_city_game_dev` (agents on by default).
  2. `drive_city_game.dart <uri> shot.png 20 - zone=residential step=600`: check `agents.vehicles > 0`.
  3. `road=add&pts=-300,150;300,150&class=<avenue index>`: an avenue across the north–south street.
  4. `step=300`, then screenshot the cars at the crossroads and at the avenue's signal heads.
  5. Save and load in the view, and check `agents.enabled`.

**Merge gate:** C1, C2 and C5 acknowledged, C3 posted, the worktree rebased onto `dev`, and E19 and E20 re-anchored on the road agent's latest `world_snapshot.dart` and `city_nodes.dart`.

### Slice 2 — Measured congestion and the traffic view — M, ≈ 2k LOC, depends on slice 1

**Goal.**
- New trips avoid congested roads using delay measured at plan time, while old trips stay on their locked routes.
- The agents answer the whole readout: noise, land value and the tax factor from measured flow, and service, fire and delivery reach from their own searches. The routed model stops advancing in agent colonies (E3a, D46).
- The lane-speed view (V), beside the road agent's Routes view (C8). The route inspector (click a car). The Flow chip and the Traffic drawer.

**Files:**
- `edge_delay`, the planner's cost term, `traffic_overlay_state`, `traffic_overlay_nodes`, `city_traffic_panels` (Traffic drawer);
- `agent_reach` and the readout's slice-2 half (noise, land value, the tax factor, reach), and E3a's slice-2 line;
- E26 d–f (the V key, the HUD arguments, `_PickGate`);
- E27, `_vehicleUnder` and `_inspectCityAt` only (the tool early returns come in slices 8 and 9);
- E29, E30, E32.

**Agreed with the road side on 2026-09-15.** This supersedes the drawer and the separate V view above.
- **Lane speed is a fourth `TrafficInfoView`** (`'Lane speed'`) inside the road agent's Traffic tool. There is no Traffic drawer.
  - Traffic supplies the overlay nodes and the data behind a small provider API.
  - The only edits in their files are minimal wiring: the enum value in road_tool_controller.dart, and one tab plus a switch arm in road_tool_panel.dart and road_tool_scene.dart that call the provider. They are flagged at merge.
  - **V** and the **Flow chip** both open the Traffic tool on Lane speed. The `traffic` panel (E29) routes to the tool.
  - A vehicle pick comes before the site sheet in the default inspect path, and on Lane speed. Routes' road click is unchanged.
- **E3a and the tick pin.** E3a lands after the road side's R2 merge: city_sim.dart, city_layout.dart and city_starter_kit.dart stay untouched until then. The pin becomes "siteAccess.sync runs before agents.advance, and before roadTraffic.advance whenever that runs" (site_access_tick_order_test).
- **Wire and capture.** R3 owns world_snapshot.dart and city_nodes.dart. Any wire or capture change slice 2 needs stays small and is announced first.
- **Economy rules.** Reach rules, `RoadNoiseSampler` and the land-value and tax formulas do not change in R2–R4. Reach builds on join slot 0 (`lotPiece`/`lotS`/`lotDirs`).
- **The economy probe.** From R2, the four starter easement lots (lot-r0x1-l10, lot-r0x0-l0, lot-r0x0-r1, lot-r0x1-r5) refuse growth, so the probe must not count on them.
- **Merge order:** R2, slice 2, then R3.

**Acceptance:** §17.3 #1 (full) and #2; `edge_delay_test`, including the empty-network case; the inspector's `describe` matches `vehicle=`; overlay rebuilds limited to 0.5 Hz; `agent_reach_test`; the road agent's economy probe (`road_traffic_economy_test`'s starter town, zoned all three ways) still grows all three ways with agents on; `roadTraffic.advance` never runs in an agent colony (a counter pinned at 0).

### Slice T4a — Site networks and lot parking — L, depends on slice 1 and the road side's R1 + R2a; scheduled after slice 2

**Goal.**
- Cars on today's `CommuteSynth` trips turn in at a kerb cut, drive the site, park nose-in in a reserved stall, and leave again: forward out through the throat of a car park, yard or installation, or backing out of a home driveway (§7.5).
- Parked lot cars are agents, drawn on plan stalls, and survive a save and load.

**Scope** (site-access §7.8 items 1–11):
- **Access:** `AccessPoints.ofJoin`, per-join `BuildingTable` rows, `addGoals`/`addOrigins`/`leftOf`, reachability per role (§3.10).
- **Site networks (D49):** site sync on `sitesRev` (plan reference and `rev` per building, `lotCap`, stall bitmaps, binding reservations, `stallOrder[j]`, next hops, site elements); the site mover (IDM on site lanes, node movements, turnarounds, stall manoeuvres, `sharedSingle` claims, speed caps).
- **Arrival gate and departure** (§7.3 step 1, §7.5): the gate's grants, forced grant and give-up, the far-side left-in gap (§5.4); route first, reverse out, `throatWait` and `canJoin`, the home back-out; route remap on a graph rebuild.
- **Access events** and the extended property test (§5.5, §17.2); the D36 extension (snap, relocate, garage, limbo, `siteRetarget`, with counters).
- **Parking:** `parking` with D17 steps 1–2 and the kerb masks; what they cannot place is garaged. The lot-car owner is opaque (`ownerKind` + id), for slice 3's port.
- **Wire:** lot rows in `ParkedColumns`, `siteOrd`/`siteLane` and `sitesRev` in `AgentFrame`, `CityTrafficFrame.sites`, site manoeuvre geometry in `traffic_capture`, drawing in `agent_nodes` (§7.4, §13.1).
- **Persistence** of lot cars by `(siteId, stallKey)` (§14.1), so no save between T4a and T4b holds lot cars under another scheme or drops them.
- **Digest:** `CityAgents.digest` folds `plan.rev`, stall bitmaps and reservation owners.
- **E36 stage 1:** baked cars off on agent-managed sites only (§7.4).

Built on the road side's R2a fixtures (`SyntheticSites`: HOME, STRIP, LOOP, UTILITY, KERBSIDE) first, then real plans after their R2, and the wire after their R3.

**Acceptance:** site-access §7.9 A4–A11 (A9 is `home_back_out_test`, §7.5; A10 with its save/resume case), A13–A15, and the traffic half of A12. Merge is gated on the structural allocation test A13 (`site_alloc_test`), not on the weighed §15.2 allocation gate, which slice 11 owes.

### Slice 3 — Citizens — L, ≈ 2.6k LOC, depends on slice 2 and T4a (whose opaque lot-car owners it ports)

**Goal.**
- Traffic comes from people: homes, jobs and cars, with rush-hour flavour on the visible day.
- Emigrants leave, and deaths are assigned to homes.
- Population is realised from citizens, and citizens are saved.

**Interim until T4b:**
- cars park in destination stalls and at kerbs ahead, as in T4a; at homes they still appear and vanish at the access point, because residents' cars at home pads and kerbs come in T4b;
- citizens without a car travel as instant placements (`instantTrips`);
- arrivals from the spaceport are placed at their new home at once;
- walkers arrive in T4b.

**Files:** `citizen_table`, `population_ledger`, `trip_planner` (the activity loop; `CommuteSynth` deleted), `building_table` (occupancy), `agents_codec` (the full block), the port of T4a's lot-car owners to citizens; E8 (the death budget only), E9.

**Acceptance:** §17.3 #15, #20; §17.4 save/resume; the capacity properties; `city_save_roundtrip_test` extended.

### Slice T4b — Residents' parking and pedestrians — L, with or after slice 3

Slice 4 before revision 4, less what moved to T4a.

**Goal.**
- Residents' cars park at home pads and kerbs. Cars search, circle and park, or give up (the full D17). Every drawn parked car in an agent colony is an agent: baked kerb **and lot** cars are gone.
- People walk from the stall or kerb to the door (`entrancePt`/`entranceNode`), cross at corners on the walk phase, and walk short trips.
- Tubes on airless worlds.
- Vehicles yield to pedestrians, a home back-out included (§7.5).

**Files:** `parking` (D17 steps 3–5), `pedestrian_graph`, `pedestrian_table`, `pedestrian_meshes`, `zone_skims`, the walk and car mode choice, mode-aware job matching, and the kerb-car layer in `agent_nodes`. E36 stage 2. E26 b: both knobs set before the first frame, and restored in dispose.

**Acceptance:** §17.3 #10, #24, #25, #26 and #34; the lanes-only-at-nodes property still green with access events; the pedestrian render cap respected; site-access A16, a screenshot showing no baked parked car in the agent colony and cars entering and leaving the pump and home-pad lots.

### Slice 5 — Services I: garbage and deathcare — L, ≈ 2.3k LOC, depends on slice 3 (T4b recommended)

**Goal.**
- Garbage and corpses accumulate per building until a truck or hearse arrives.
- A badly placed landfill floods its district.
- Parcel morgues finally process bodies.
- A Services drawer.

**Files:** `service_calibration`, `service_dispatch` (with the no-route fallback); E5 (the skeleton), E6, E7, E8 (the corpse part); E21 (**all** eight new `VehicleKind`s, in its listed order); the Services drawer and site-sheet rows.

**Acceptance:** §17.3 #7 (service variant), #8, #13 (garbage and deathcare), #16 (garbage and deathcare rows), #17, #27, and #29 (a service dwell); load conservation; `wasteBacklog` unchanged in meaning with the flag off (the existing tests).

### Slice 6 — Services II: police and mail — M, ≈ 1.4k LOC, depends on slice 5

**Goal:**
- Crime is local and cleared by visiting police cars.
- Safety coverage comes only from answered calls.
- There is a mail backlog, a Post Office, and happiness that feels both.

**Files:** police and mail kinds in dispatch; E5 (the safety replacement); E34 (the mail term); E35; E22 (Post Office).

**Acceptance:** §17.3 #13 (police and mail), #16 (police and mail rows), #28; safety coverage is 0 with only Emergency Services; `mailBacklog` rises with no Post Office and falls with one.

### Slice 7 — Services III: fire and health — M, ≈ 1.5k LOC, depends on slice 5

**Goal:**
- Engines put out fires only on scene, and lot fires are deterministic.
- Ambulances carry the sick to beds, and medicine gates treatment.

**Files:** E11 (`advanceLotFires`: growth, engines wanted, and spread and ignition on `TrafficRng`); E5 (the health replacement); E22 (Fire Station). The new `VehicleKind`s already landed with E21 in slice 5.

**Acceptance:** §17.3 #13 (fire and health), #22, #29 (the fire engine); untreated patients raise mortality when medicine runs out; `parcel_growth_test`'s fire test is unchanged because the flag is off; `twin_run_digest` with the fire flag on.

### Slice 8 — Outside connections and freight — L, ≈ 2.6k LOC, depends on slices T4b and 5

**Goal:**
- Highway stubs bring visitors in, take residents out on errands and back, carry emigrants and immigrants, and pass through traffic between stubs.
- Industry trucks goods to shops and warehouses and exports the surplus. It imports what is missing, and imports cost money.
- Freight takes the cheapest path, including through downtown.
- A fresh City Builder colony shows all of this from its starter spurs.

**Files:**
- `outside_connection` (with the visitor table), `freight`;
- E23 (goods), E22 (Cargo Terminal), E5b (the funds line and `netFundsRate`);
- E17 (the starter spurs and their stubs);
- E34 (the goods term);
- `TrafficToolController` (outside-connection mode);
- E27 (the tool early returns, on their landed input code, C4).

**Acceptance:** §17.3 #9, #18, #21 and #30; imports, exports and fleet upkeep appear in the budget readout.

### Slice 9 — Transit (buses) — L, ≈ 2.4k LOC, depends on slices T4b and 8 (the tool controller)

**Goal:**
- Draw bus lines with stops. Buses run from a depot and dwell in the kerb lane.
- Citizens choose walk, drive or bus, with a locked itinerary.
- The transit bonus comes from ridership.

**Files:** `transit` (with the itinerary tables); E22 (Bus Depot); the line tool; the Transit drawer; shelters at stops; E10.

**Acceptance:** §17.3 #19 and #31; the mode split includes bus when a line links homes to jobs; a stop survives a split.

### Slice 9b — Rail and the L — L, ≈ 2.2k LOC, depends on slice 9

**Goal:**
- The railway and the elevated line carry trains as agents between stations.
- Riders choose rail as they choose the bus.
- Freight rail sits behind a knob.

**Files:** `rail_graph`, `rail_transit`; the line tool's rail mode; station markers; C9, or the fifth E20 hunk that hides cosmetic trains for agent bodies.

**Acceptance:** §17.3 #32; the mode split includes rail when a line links homes to jobs; no cosmetic train is drawn in the agent colony.

### Slice 10 — Economy on agents and one network — M, ≈ 1.2k LOC, depends on slices 5–9b

**Goal:**
- Jobs are staffed by the workers who actually arrive, per building (§12.3).
- Agent colonies judge "served" by lane-graph reachability.

**Files:** the E6 staffing lookup; the workforce change (E4-adjacent, on 1238); the SCC serving hook, a one-line guard where `parcelNetwork()` is consulted (1216-1219); the balance tests.

**Acceptance:**
- **Headless balance test:** the starter kit reaches tier 3 within ±20% of the time it takes without agents.
- Growth on the fixture cities within ±5%.
- The audit passes.

### Slice 11 — Scale, and agents in every colony — M-L, ≈ 2.2k LOC, depends on slice 10 (the scheduler work may start after slice 5)

**Goal:**
- Big colonies stay inside the frame budget.
- **Every ticking colony runs agents.** No colony keeps an abstract traffic figure: every readout is the agents'.

**Scope:**
- `agent_scheduler*`: the isolate binding with `cityClockHeldS` and graph shipping.
- A resumable graph derivation above 3,000 roads.
- **Meeting the §15.2 allocation gate**, weighed as well as structural: the pull-out queue's and the mover's per-item boxing (§15.2 status), for instance the agent clock in sub-steps rather than microseconds past 2³⁰, and the hot helpers inlined.
- **Enabling agents for every ticking colony:**
  - generated colonies are enabled after generation, and E31 adds their interstate stubs;
  - older saves auto-enable on load, with citizens reconciled from `population` through the external budget;
  - C9's per-body cosmetic cap.
- An optional `CityStudioDevHooks.trafficBench` driver.

**Gates for enabling:**
- `sprawl_topology_audit_test` at its targets: 0 dangling ramp ends, 0 unjoined cloverleaf merges, and no isolated built lots in the fixture;
- the 16k-vehicle benchmark;
- the catch-up-frame gate.

**Acceptance:**
- `binding_equivalence_test`.
- A 16k-vehicle benchmark with UI traffic cost ≤ 1 ms p95.
- The zero-allocation gate on the worker.
- A generated colony in the flight view runs agents, and `roadTraffic.advance` is never called in any ticking colony (a counter pinned at 0). `advanceParcelTraffic` still runs, and its frontage-local fallback only before a first picture.

### Slice 12 — Polish and retirement — M, depends on slice 11

**Scope:**
- The shelter random-bag weight set to 0 for agent colonies, through a tile-mesher knob (coordination).
- Toolbar buttons, if the road agent takes the request (C4).
- Deletion of the flag-off `else` branches after their tests migrate.
- The service heat overlay.
- Documentation (a `docs/plans` follow-up and the wiki).

---

## 19. Risks, open questions, non-goals

### 19.1 Risks and mitigations

1. **Merge conflicts with the road agent.**
   - The shared files:
     - `city_sim.dart`: E2–E16 and E34–E35, several beside their `roadTraffic`, road-upkeep and rename code;
     - `world_snapshot.dart`;
     - `city_nodes.dart`;
     - `simulation_view_colony.dart`;
     - `city_edit_overlay.dart`, which we don't edit.
   - Mitigations:
     - every E hook is 1–5 lines and listed with its dev anchor (§1.2);
     - we don't edit their files (§1.2, "Untouched on purpose");
     - E26(f) and E27 are anchored on their landed input code (C4);
     - each slice is re-anchored and rebased before merging;
     - `traffic_capture_test` catches any drift in their wire.
2. **The graph is theirs (C1).** A change to `RoadGraph`'s clustering, attach or lot-access rules changes our topology. It has happened once (229cb9c: the level rule and drawn-leg plans), and revision 3 absorbed it with no change to our derivation (D48).
   - Mitigations: `graph_derivation_test` and `access_points_test` pin what we rely on; C1 asks for notice; the derivation reads only public arrays.
3. **Topology holes in generated colonies:** offset or failed ramp merges, the 8 m sliver drop, the elevated road over the central avenue.
   - Mitigations:
     - `RoadGraph`'s dead-end attach and its ground rule for draped roads cover ramps and cloverleafs;
     - dead ends and `danglingDeck` nodes are explicit;
     - `graph=audit` and `sprawl_topology_audit_test` report what is left;
     - a trip stranded by a hole ends in a stuck despawn.
   - Generator fixes are theirs (C6). Agents turn on for generated colonies only in slice 11, behind the audit's targets.
4. **Time scale.** Real speeds against a 120 s day can read as "traffic lags the day". Mitigations: dwell timers with a rush curve, and the calibration test (§17.3 #15).
5. **Balance shift:**
   - spatial garbage collection, local police and working parcel deathcare;
   - trade income, fares, fleet and bus upkeep;
   - staffing driven by commutes (slice 1 via `CommuteSynth`, per building in slice 10);
   - **every passive safety source retired** under the police flag, military included (D37);
   - **fire ignition in normal play** (§9.2), where today lots ignite only during a fire disaster.

   Mitigations: every one of these sits behind `serves(kind)` or `freightEconomy`, with calibration and balance tests and a before/after HUD capture per slice.
6. **Determinism holes outside our code.** `CitySim`'s 20 unseeded `math.Random()` calls perturb the economy, and through it the budgets and citizens.
   - Our tests freeze those: disasters off, partition tests on a frozen economy, lot fires on `TrafficRng` under the fire flag.
   - Seeding `CitySim` itself is out of scope.
7. **Inline cost at 25×.**
   - The frame hold bounds every frame at 4 sub-steps (D35), at the price of the city lagging the world during catch-up.
   - The deterministic caps bound the simulation, render shedding bounds the frame, and the worker comes in slice 11.
8. **Old-generation GC.** Any per-agent object that slips into steady state shows up as pauses of 25–78 ms. The zero-allocation gate catches it.
9. **Double signal lamps** until C3 lands. It is a visual glitch only.
10. **Calibration constants are targets** (§9.2). The steady-state tests are the contract, not the numbers.
11. **A mid-session enable re-cuts every tile** (D32, C10). That is one hitch, paid once. City Builder colonies enable before their first frame and never pay it.

### 19.2 Open questions (each has a default; the user may overrule)

1. **Do stubs open migration without a spaceport?** Default **no**. The `connectionsAllowMigration` knob exists.
2. **What happens to a commuter whose car despawns?** Default: they arrive, the trip is counted as failed, and it costs them 50% productivity through `commuteEff`. The CS2-harsher alternative is that they miss the shift.
3. **Does the Transit Stop building (city_building_spec.dart:498) survive?** Default: yes, as an optional line terminal.
4. **Does sewage get trucks?** Default **no**; it stays a pipe scalar.
5. **Do Emergency Services keep engines and ambulances once a Fire Station exists?** Default **yes** (3 of each).
6. **Do old saves of starter-kit colonies auto-enable agents on load?**
   - Before slice 11, default **no**: the Traffic drawer offers an "enable agents" button that runs the external-budget reconcile and one tile re-cut.
   - From slice 11, **yes**.
7. **Does the city studio ever tick agents?** Not planned beyond the slice 11 benchmark driver.
8. **Does the military keep any passive safety under the police flag?** Default **no** (D37): decision 2 retires global coverage for crime. The alternative is a capped military share, for example at most 25% of `services['safety']`.
9. **Is deleting a bus or rail line, or a stop, a "change to the network" that may re-plan riders?** Default **yes** (D36): it is the transit network the rider's route runs on. The alternative is that riders keep waiting at a dead stop until a stuck-style timeout.
10. **Is freight rail on by default?** Default **no** (the `freightRail` knob).

### 19.3 Explicit non-goals

**Traffic modelling:**
- Mid-segment lane changes, overtaking, bus bays, protected-left phases, adaptive signals, signal-timing optimisation.
- TM:PE-style tools: lane connectors, priority signs, vehicle restrictions.
- Districts and policies.
- Congestion re-routing of trips already planned, which the brief forbids.

**Vehicles and people:**
- Bicycles, taxis, tourists, ships and aircraft.
- Pedestrian–pedestrian collisions and jaywalking.
- Emergency vehicles pulling over.
- Bus and train headway control and holding.
- Per-instance vehicle colour beyond one livery per kind.
- Airless variants of service vehicles.

Trains, the L and freight rail are **in scope**: slice 9b.

**Persistence and networking:**
- Saving agents in flight.
- City traffic in `AuthoritativeSimulation` frames (authoritative_simulation.dart:65-83 passes no cities), in the fingerprint, or on the FlatBuffers wire.

**Scope boundaries:**
- Colony-to-colony trade links (the stub is their placeholder).
- Seeding `CitySim`'s existing randomness.
- Retiring the cosmetic `CityTraffic` pass or its test (it keeps serving the studio).
- Any Unreal work (the native UE rewrite is abandoned).

---

## Revision log

**Revision 2 (2026-09-11)** answers the critic's review, and rebases the design on `dev` at `62a3a55`.

- **Baseline and coordination.**
  - The header, §1.2 and §1.3 are re-cited against dev `62a3a55`. That is one commit past the review's `7134031`; it wires the routed model into the tick and moves the shared warrant into the domain.
  - Every E-hook has a dev anchor.
  - The coordination contract is rewritten for a road agent that has shipped:
    - new items: C1 (the graph is theirs), C2 (who writes which scalar), C7 (a volume seam), C8 (one traffic view), C9 (renderer hooks), C10 (parked-car knobs) and C11 (REFERENCE.md);
    - marked as landed: attributes carried through splits and saves, and the wire's flip.
- **The lane graph is derived from `RoadGraph`.** §3 is rewritten; D3, D4, D7 and D44 changed.
  - E1 and the FNV override hash are dropped. The graph is keyed on the `RoadGraph` object.
  - Access follows `lotDirs`, so far-side driveways exist only on two-way roads with one lane each way.
  - The cloverleaf case is resolved by the graph's ground rule for draped roads, and `rampLevelSlackM` is gone.
  - The taper cut is dropped, so no edge has zero lanes.
  - The beltway is a ring piece, not a closed road.
  - Node control is `RoadNode.plan` (`junctionPlanForNetwork`), tested against `RoadMesher.junctionPlan`.
- **Fixed-start plans (blocker).**
  - Rule 5 adds adjacent-lane straight connectors at real junctions.
  - An (edge, lane) state search serves re-plans and appended legs (§3.5, §4.5, D34).
  - The remap's lane repair is sticky and limited to the affected span (§3.9).
  - New tests: `lane_state_search_test`, the avenue example, and new remap cases.
- **Stub flows are defined (blocker).** §10.4, D38 and D39.
  - The per-stub rates are gone. Visitors are scheduled; errands and emigrants arise from citizens; trucks are exactly the §10.2 imports and exports; through traffic does not scale with population.
  - The sink position is defined.
  - E17 lays two starter trunk spurs with stubs.
  - Test #18 is rewritten, and #30 added.
- **Plans change only on network edits (blocker).** §4.6, §4.7, §11.4 and D36.
  - A demolished destination is handled on arrival, by an appended leg.
  - The bus give-up is removed.
  - Disabling a stub, and deleting a line or a stop, are network edits.
  - Tests #31 and #33 added.
- **Safety and crime from deliveries (blocker).** §9.5, §9.6, E5, E35 and D37.
  - Under the police flag every passive safety term is retired, military included. This is flagged as open question 8.
  - `policeCoverage` comes from answered calls, and is 0 with no station.
  - The crime target is derived from `crime_b`.
  - Test #13 now covers all six services, and the Emergency-Services-only case.
- **Stuck despawn.** `stuckT` is frozen while dwelling or held for a re-plan, and a stuck citizen's car is garaged virtually (§5.6; test #29).
- **Map-edge traffic in play, and agents everywhere.** Outside connections are visible in play through the starter spurs (E17). Agents run in every colony from slice 11, and E31 moves there (§18, D24).
- **Rail and the L** are in scope as slice 9b (§11.7, D40); the non-goal is removed.
- **Delay measurement** (§4.2, D11):
  - each observation is signed, against the vehicle's own free time and the expected control delay;
  - the live queue counts only vehicles beyond the first stopped one in each lane;
  - `flowPerMin` is defined;
  - an empty-network test is added;
  - tests #2 and #9 state their assumption about `D`.
- **Parking** (§7.3, D17).
  - The reservation is binding.
  - The steps are ordered: search, then circle up to three times, then give up.
  - Appended legs are fixed-start.
  - Left-kerb slots use the lane set `{L−1}`.
  - Test #10 is rewritten.
- **Baked parked cars** (§7.4, D32, E36). Both knobs are set before the first tile request, lot cars included, all in slice 4. The false "re-meshes" claim is corrected.
- **Mail and goods** are a direct happiness drag (E34, D41). The goods leisure scaling is removed, and test #28 added.
- **Transit itineraries** (§4.9, §11.2).
  - Stop pairs and transfers are chosen from line tables and stored on the citizen.
  - Egress and transfer walks are appended at alighting.
  - D26 is reworded.
- **Minors:**
  - one dispatch cap: 8 per kind, on one sub-step per second;
  - ignition on `TrafficRng`, and a rule for engines per fire;
  - definitions added: `needHealth`, `treatedShare600`, `homelessNear_b`, `flowPerMin`, sink positions, fleet upkeep, reserve exhaustion, `classFactor` eligibility;
  - walking is always available, and job matching uses the citizen's own mode;
  - pedestrians: "stepping on" defined, priority after 20 s, and a give-up;
  - the slice-3 interim rules;
  - a no-route fallback for services and freight;
  - test #11 restated;
  - the `CommuteSynth` rate corrected to 0.00042·H;
  - deathcare fleets re-derived from one body per stop;
  - opposing-left gaps at every control and at driveways;
  - naming made consistent: `fundsRate`, one garaged representation, `VehicleKind`s appended together in slice 5, the dwell in the locked destination lane, health requests as counts.
- **Follow-ons from the dev baseline:**
  - E12 moved into `_carryRenamedLots`, which covers four road operations, and E12–E14 moved to slice 1;
  - E15/E16 in slice 1, so the enabled flag survives a save and load;
  - the render clock pauses on the host's warp, not on an unchanged epoch (§13.4);
  - the frame hold bounds catch-up frames at 4 sub-steps (§5.7, D35, E3b);
  - `model` is replaced by `variant` in the domain (D42);
  - geometry is sliced from the capture's own flipped `RoadSnapshot`s and lifts (§13.2–13.3, D19, D20);
  - lot fires are deterministic under the fire flag (E11);
  - E20 becomes a part file, with the cosmetic cap set before `begin` (§13.8, D45);
  - lineage handles an Adjust Roads re-lay;
  - `main_city_game_dev` founds with agents, and `drive_city_game` forwards `key=value`;
  - the slice-1 congestion contradiction is resolved: E4 lands in slice 1;
  - slice-1 acceptance is limited, and a signalised fixture added;
  - the `CityAgents` constructor allocates nothing;
  - `tickCostMs` is gated to agent colonies, and the governor note corrected;
  - E5b rebased onto the road-upkeep term;
  - E6's depot pollution scales with the work done;
  - E22 adds the rules the installation tests need;
  - slice dependencies fixed;
  - the hygiene grep allows enum `values`.

**Rejected:** none.

**One fix took a different route than the critic suggested.** For the 25-tick frame (§15.1), the design neither caps world ticks at host level nor only documents the hitch. It holds whole city ticks in a queue (D35), so the sequence of `advance` calls, and therefore every result, is unchanged. That is the critic's "cap ticks for agent colonies" option, made deterministic.

**Revision 3 (2026-09-11)** follows dev from `62a3a55` to `c672eb3`.

- **The readout seam** (D46, D47, E37; §0.1, §1.3, §12.3). Everything that reads traffic reads `CitySim.trafficReadout` (`CityTrafficReadout`, f66e0d8 and 38e05fe). `CityAgents.readout` implements it, and E37 returns it in agent colonies.
  - Slice 1: the agents answer congestion, volumes, live routes and `passes`; reach, noise, land value and the tax factor are forwarded to the routed model, which keeps advancing.
  - Slice 2: the agents answer everything, and `roadTraffic.advance` is skipped in agent colonies.
  - E3a is replaced: `advanceParcelTraffic` stays as it is and takes the agents' congestion through the readout, and `agents.advance` runs right after `roadTraffic.advance`. §4.2, §9.5 and §12.1–12.3 follow.
  - D43 is superseded. C7 (a volume seam) and C8 (one traffic view) are resolved, and the residual-flow risk is gone from §19.1.
  - New tests: `traffic_readout_test` (slice 1) and `agent_reach_test` (slice 2).
  - Slice 11's gate becomes "`roadTraffic.advance` never runs in a ticking colony", since `advanceParcelTraffic` keeps running.
- **Fire and delivery reach** (D47; §9.4, §9.7, §10.2). Fire cover counts only stations with safety cover, so a clinic is no fire cover (1d2e78d). A works' own goods, and its own lorries turning at the next node, are no delivery (e608e35). Fire Station declares a `safety` term.
- **The graph's new rules** (D48; §3.1, §3.2, §3.7, §5.4, §17.1).
  - Ends meet by `CityLayout.levelsSeparated`, and deck ranges are read through `offGroundAt` or `levelOf`.
  - Plans are read over drawn legs, with `stopLegs` mapped back, and `defaultStopLegs` asks every car leg.
  - The arbiter reads the plan as it is; alleys and paths give way to drawn legs.
  - The `_sameLevel` and 2 m text is gone, and new builder and node-control cases pin the rules.
- **The road tool has landed** (C4; E25, E26, E27, E29, E32, E33; §11.5, §16). The pick gate moved into `_cityPickLayer()` in simulation_view_colony.dart, and E26(f) moved with it. Our UI edits no longer wait on theirs. `drive_city_game` already takes `--script`, and E33 is reworded.
- **Lost lots** (E12, E13). A re-plat now tears down what stood on a lot it gave up (`_dropLostLots`, 08f8cf3), and the building sync tombstones those buildings.
- **Re-anchored.** Every E-hook, and every line cited in a file that changed since `62a3a55`, is re-cited against `c672eb3`. The header records the worktree's position.

**Revision 4 (2026-09-15)** adopts the road side's site-access design (`docs/plans/site-access.md`) as the parking contract, applying its §7.7 list. Anchors are not re-cited; line numbers still read against `c672eb3`.

- **The contract and the acks** (§0.3 note). C-5 (position-free generation seed), C-19 (stall indices stable per plan `rev` only, so reservations and saves key on `stallKey`) and C-20 (the plan's `joins[0]` comes from `RoadGraph` slot 0) are acked. The user accepted every site-access §10.2 recommendation except Q3.
- **Site networks** (new D49; D19, D20, D27 notes). Separate from the lane graph; plans are the road side's, immutable and copy-on-write; traffic owns the per-site network and site mover, rebuilt on `sitesRev`, never `graphRev`; handover only at joins; the book syncs inside `CitySim.advance` before the agents.
- **Access per join** (§3.10, D6, D7, C1, §1.1, §2.6). A site's access is its plan's joins, with `joins[0]` = slot 0 = `lotPiece/lotS/lotDirs`; side from `joinRight`; goals from in-capable joins, origins from out-capable joins; reachability per role; a plan not current for the graph is kerbside at slot 0. C1 records the R1 join slot columns and `site_join.dart`.
- **Gate and events** (§5.4, §5.5, §5.8, §17.2). The far-side left-in takes the opposing gap at the arrival gate. The access-point exceptions are the ENTER and EXIT access events, and the property test gains the site-element rule.
- **Parking** (§7.1, §7.3, §7.4, D17, §2.7). `lotCap = stallCount`, and the old capacity table becomes the generator's target. D17's order: destination stalls at the gate, masked kerb slots ahead within 60 m, adjacent edges, circling, give-up. Lot cars sit on plan stalls under `sitesRev`, and the positions-only `emitLot` port is deleted.
- **Home back-outs** (new §7.5, D17, D49). Q3 changed by the user: home-driveway cars park nose-in and back out into the street on a gap, with the target-lane, gap-acceptance, EXIT, restriction and deadlock rules; `home_back_out_test` replaces A9. The road side's rewrite of site-access §3.4, V9, §7.4 and A9 is pending.
- **D36.** A site-plan change re-plans only site legs; road routes stay locked.
- **Wire and saves** (§13.1, §14.1). `CityTrafficFrame.sites`, `AgentFrame.sitesRev`, and `siteOrd`/`siteLane` as separate columns (not `elem ≤ −2`), plus a `reversing` flag. Lot cars are saved by `(siteId, stallKey)` from T4a.
- **Slices** (§18, E26, E36, §6.2). Slice 4 is split into T4a (site networks, lot parking, persistence, E36 stage 1) and T4b (residents' cars, full D17, pedestrians, E36 stage 2). The order becomes 1 → 2 → T4a → 3 → T4b. Slice 3 now depends on T4a, and slices 5, 8 and 9 on T4b.