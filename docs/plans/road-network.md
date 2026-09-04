# Road Network Overhaul

**Status:** phase 1 landed (§6); the plat and the sprawl are ONE model
(§8, 2026-09-04). **Goal:** one real, interconnected
traffic network across the whole colony — the platted core and the twenty-mile
sprawl alike — with the road classes, interchanges and junction controls of a
city builder, drawn by one pipeline so nothing reads as a "high-res asset
downtown, placeholder outside".

---

## 0. Where this started (the diagnosis)

The screenshot that opened this: textured roads with sidewalks, lamps and
junction plates in the core, and outside it a wide grey ribbon with one dashed
line, local streets that stopped thirty metres short of it with nothing where
they met, and houses floating beside them. Two separate systems were drawing
two separate ideas of a road:

| | The core (`CityLayout` + `CityNodes`) | The sprawl (`SprawlPlan` + `SprawlNodes`) |
|---|---|---|
| Model | `RoadSpline`s split at every crossing; real topology | Polylines with an ad-hoc `SprawlRoadKind`; never split; ramps ended thirty metres off the roads they "joined" |
| Surface | one 2-lane texture stretched across every width (a 32 m highway had one centre dash) | the same texture, `u` 0..1 across a 24–36 m ribbon |
| Junctions | derived from coincident road ends: plate, stop bars, zebras, signals | none — a county highway crossing another was two ribbons overlapping |
| Local streets | platted, sidewalks, furniture | grown by the renderer as 7 m ribbons, no crossings, sidewalks 1.5 m wide at one tier only |
| Traffic | per-segment streams, one each way, at half the half-width | none |
| Stop bars / zebras | drawn on the road texture at a `u` that was plain asphalt — **invisible** | — |

The plat cannot simply absorb the sprawl: `CityLayout.commitRoad` samples at 2 m
and re-plats lots, and is quadratic in roads. A twenty-mile sprawl is ~2 000 km
of road and sixty thousand local streets. So the fix is not "put everything in
`CityLayout`"; it is **one road model, one junction model, one mesher**, with
the sprawl's roads becoming a real graph that the renderer tiers by distance.

## 1. The road model — `RoadClass` and `LaneLayout`

`RoadClass` (in `parcel.dart`) is the single description of a road. Saves
persist it by index, so new classes are **appended**:

| Class | Lanes | Width | Notes |
|---|---|---|---|
| `street` | 1 each way, 4.0 m | 8.0 | dashed yellow centre, curbs |
| `avenue` | 2 each way, 4.0 m | 16.0 | double yellow; **the county highway is this** |
| `highway` | 4 each way, 3.5 m | 32.0 | urban surface highway: shoulders, painted median |
| `trunk` | 2 each way, 3.7 m | 24.0 | rural arterial, painted median, no lots |
| `elevated` | 3 each way, 3.5 m | 24.0 | viaduct, barrier median |
| `expressway4` | 2 each way, 3.6 m | 24.4 | **new**; limited access, 3 m shoulders, 4 m barrier median |
| `expressway6` | 3 each way | 31.6 | **new** |
| `expressway8` | 4 each way | 38.8 | **new** |
| `ramp` | 1, **one way** | 7.5 | **new**; direction = point order |

Every class with lanes exposes a `LaneLayout`: lane count and width, shoulder,
median (`none | painted | barrier`), centre marking, one-way. From it:

- `laneOffsets` — lane centres to the right of travel. The traffic pass puts
  a stream in every lane; an eight-lane expressway fills all eight.
- `lineOffsets` — every painted line (dashed white dividers, solid white
  edge lines where there is a shoulder, yellow against a median or a
  double yellow centre). The mesher draws exactly these.
- `widthM` — and a test pins it to the enum's `width` so they cannot drift.

Predicates that the rest of the system keys off: `limitedAccess` (expressways,
the viaduct), `joinsJunctions` (everything that carries cars at grade except
alleys and dirt paths — so a ramp terminal or a trunk artery is a junction
leg), `arterial` (avenue/highway/trunk: what warrants signals).

## 2. Junctions — `road_junction.dart`

A junction is a place where road **ends** coincide (three or more; two is a
road carrying on). Its control is decided once, by `junctionControlFor(legs)`:

| Legs | Control |
|---|---|
| any limited-access leg | `merge` — ramp gore, nothing drawn yet |
| planner asks + ≥3 legs, none faster than an avenue | `roundabout` |
| ≥2 arterial legs (a crossing of avenues, a T into one, a ramp terminal, a trunk at the grid) | `signals` |
| otherwise | `stop` (all-way) |

Both renderers ask this: `CityNodes` derives ends from the plat's split roads,
the sprawl reads nodes off the plan. Same rule, same look.

## 3. The sprawl plan is a graph — `sprawl_plan.dart`

`SprawlPlan.roads` are now **segments between junctions** and
`SprawlPlan.nodes` are the junctions, each with its legs (direction, class)
and control. Internally every road is a `_Draft` that accumulates `_Cut`s
(arc positions with the extra legs that meet there); `_Net.build()` splits the
drafts and merges coincident cuts into nodes. Sources of cuts:

- **County highways × county highways** on the mile grid → 4-leg signals.
- **Diamond interchanges.** Ramps leave the cross road at a T
  (`diamondTerminalM` = 110 m from the crossing; on-ramp and off-ramp share
  the terminal, a 4-leg signal) and merge with the expressway's **outer edge
  line** 420 m along it, as a cubic that leaves square-on and eases in along
  the expressway *as it actually bends there*. Two ramps per side are
  on-ramps (highway → expressway) and two off-ramps, by keep-right:
  `si·so·rightOf(dir, odir) > 0` → on-ramp. Off-ramps are laid reversed so
  point order is direction.
- **Cloverleafs.** Loops are circles tangent to both roads' edge lines, eased
  onto the far road where the bends make the circle miss; outer connectors
  are quarter-turn cubics 400 m out. Loops carry the left turns, connectors
  the right turns; direction by the same keep-right rule.
- **Collectors.** Every built section has two collectors per axis a quarter
  of the way in from each side (`SprawlSection.collectorOffsetsFor`), and the
  plan cuts the county highway where each reaches the section line → a
  signalised T (or 4-leg where the neighbour's collector lines up). The
  section builder runs a collector to the line **only where the plan has a
  node** (`hasNodeAt`), otherwise ends it in a turning circle.
- **The plat's arteries** (`SprawlSpec.arteries`) meet the first mile line
  ≥40 m past the core at a signalised T. `CityGenerator._layArteries` now
  measures the mile grid from the origin (it measured from the central
  avenue, so every artery stopped 220 m short) and ends exactly on the line.
- **Lane counts by position.** Radials (axial and diagonal) are
  `expressway6` to the outline and `expressway4` beyond — six because that is
  what the viaduct through the core carries, and a mainline keeps its lane
  count where a deck happens to end; the beltway is `expressway8`. Class
  changes are cuts without nodes, and the **wider piece tapers** to the
  narrower one's width at the shared end (`SprawlRoad.endHalfWidthM`); the
  first piece off the deck starts at the viaduct's width
  (`startHalfWidthM`). The mesher narrows the edge over 90 m and folds any
  line outside the narrowed edge onto it — a dropped lane's divider becomes
  the edge line.
- **The core seam.** The plat's frontage roads under the deck
  (`SprawlSpec.frontageRoads`) carry on as **slip ramps** where the deck comes
  down: the south road is eastbound (keep right), so its east end is an
  on-ramp onto the radial's south edge 350 m out and its west end receives
  the off-ramp; the north road mirrors. The plat's frontage road end and the
  ramp's first point are one point, so nothing stops dead.
- **The inner suburbs carry the plat's grid on.** `SprawlSpec` carries the
  plat's grid (`gridOriginE/N`, `gridStepE/N`); every section that touches
  the core (within 300 m of the outline) lays its streets on those lines
  (`SprawlSection.streetLinesE/N`), skipping the avenues the arteries own,
  with collectors on the lines nearest the quarter points. The section
  builder finds where each line leaves the core to the metre (bisection on
  `coreRadiusAt`) and starts the street 12 m inside it, on top of the
  downtown street that ends there — so a downtown street reads as one
  street across the seam. Farther out, the sections' own 12/8/4 survey grid.
- A county line an axial interstate runs along is dropped (it used to sit
  under the expressway and grow a diamond at every wander).
- **Where an expressway ends.** The north-south radials carry on as the
  plat's central avenue, so their first piece starts at the avenue's width
  and widens over the taper (six lanes out of four) instead of stepping.
  The diagonals have no avenue to continue: each begins on the first
  county-grid crossing on its bearing clear of the core, and that crossing
  is a signalised node with the expressway as a fifth leg —
  `junctionControlFor` treats one limited-access leg among arterials, with
  no ramp, as an expressway's END and warrants signals rather than a merge.
- **Sound barriers.** The walled variant of a ground-level highway is a
  road ATTRIBUTE (`RoadSpline.soundWalls`, `SprawlRoad.soundWalls`, on the
  wire as `walls`), allowed on `canHaveSoundWalls` classes (the expressways
  and the urban highway), not three more classes — so one highway can be
  walled past housing and open past fields. The editor's class row shows a
  "Sound barriers" toggle for those classes; the plan walls every
  expressway piece whose middle lies in a built-up residential section.
  `RoadMesher.soundWalls` draws precast panels 4.6 m tall just outside the
  shoulder each side (steel posts every 6 m when detailed), stops 35 m short
  of either end of a piece (a junction, a merge a ramp has to get through,
  or a class change) and skips bridged stretches, which have parapets.
- **L terminals.** A free end of an elevated rail line (no other piece ends
  on it) gets a terminal station: platforms at deck level each side, a
  canopy on posts, a lit sign band, a bumper, and a stair tower to the
  street (`ElevatedStructure.emitTerminal`, called from `CityNodes`). The
  generator now lays the L two blocks off the central avenue when the
  expressway runs along it; the two stood on the same street.

Core diamonds (the elevated expressway's ramps onto the plat's avenues) emit
their terminal nodes outright on the plat's avenues; their merges are on the
deck and draw nothing.

### Wire

`SprawlRoadSnapshot` carries `roadClassIndex`; `SprawlNodeSnapshot` carries
position, control and flattened legs `(dir xyz, half width, class)`; both ride
`WorldSnapshot`. Ramps drape at 20 m, everything else at 60 m.

## 3b. Lots: parking, driveways and footpaths

The massing places a building's car park INSIDE its parcel — a strip off
one end of the buildable depth, in front for suburban styles and behind
(off the alley) for a street wall — and the building mesh draws its slab.
The lot pass used to draw a second apron from a rough estimate of the lot,
always at the front, with a neck that ended under the raised sidewalk. Now
`CityNodes._emitLotFeatures` takes the massing the building was actually
drawn from (the library's cached archetype, so the same variant) and
`LotFeatures.emitLot` dresses that lot: bay lines and the cars in them
(ranks against the long edges, two facing across an aisle when there is
room), the driveway from the lot's road-side edge to the road — over the
front setback and across the sidewalk as a concrete apron at the walk's
height for a front lot, a metre into the alley for a rear one — and the
footpath from the entrance to the front lot line (and to the back wall from
a rear lot). Everything is paving on the road atlas; nothing is drawn on
the ground palette. Front or rear is decided from where the lot IS relative
to the entrance, not from the style flag, because an installation's lot is
out front whatever the kit. The lot gets an asphalt surface of its own over
the massing's pale slab, so a car park reads as tarmac.

Installations (`_lotFor` in the massing rules) used to lay their car park a
fixed distance OUTSIDE the plot's front line — over whatever the plot
fronted. They now park inside: in the strip between the front line and the
nearest of their own volumes, as deep as the spaces need and no deeper than
the strip allows, or not at all when there is no room for a rank of bays
(`installation_parking_test`).

The sprawl does the same: strip malls get an asphalt lot between the box
and the arterial with a driveway to the curb, a path to the door, two ranks
of bays back to back and cars in them; industrial sheds now stand in the
BLOCKS of the section's streets (the old coarse grid put them astride the
streets) with a yard toward the block's street, a driveway and a path;
houses get a concrete driveway over the sidewalk and a path along the front
to the door.

## 4. One mesher — `road_mesher.dart`

Everything that draws a road goes through `RoadMesher`:

- `carriageway(m, pts, anchor, cls, {halfWidthM, liftM, liftAt, paint, solid})`
  — an asphalt ribbon the full width plus one thin strip per `lineOffset`,
  shoulders, and the median (hatch or concrete + Jersey barrier boxes on
  `solid`). `liftAt(s)` carries bridges (`bridgeLiftAt`).
- `ribbon(...)` for roads with their own texture (alley, dirt) or one atlas band.
- `sidewalks`, `lamps`, `piers`, `culDeSac`.
- `junctionsFromEnds(ends)` → `RoadJunction`s; `junctions(...)` draws plate,
  stop bars, zebras (signals only), masts and heads, signs, or a roundabout
  (16-gon plate, raised concrete island, broken yield lines, keep-right posts).

**The road atlas** (`CityTextureBakes.roadAtlas`, 1024², eight bands along U:
asphalt, concrete, white, yellow, dashed white, dashed yellow, hatch,
shoulder; 12 m per repeat along V so a dash is 3 m on / 9 m off) replaced the
single two-lane strip. Paint is geometry: a 15 cm strip maps a whole band
across itself, so lane count costs nothing but a class. Stop bars and zebras
are finally visible (they sample the white band, not asphalt).

Callers: `CityNodes._emitRoads` (core), `ElevatedStructure` (the viaduct deck
gets its six lanes and barrier), `SprawlNodes._roadStep/_nodeStep` (plan
roads and nodes per group, tiered), `SprawlSectionBuilder._streets` (local
streets, crossings, cul-de-sacs, roundabouts).

## 5. Tiering in the sprawl

Plan roads and nodes are assigned to the section **group** nearest their
middle and built with it (`SprawlNodes._assignRoads`), so they take the
group's tier:

| Tier | Roads | Junctions | Local streets |
|---|---|---|---|
| far (>7.5 km) | asphalt ribbon | — | — (roof silhouettes only) |
| mid | + painted lanes, median hatch | plates | ribbons + centre line, cul-de-sac plates, crossing plates |
| near (<2.8 km) | + barrier, sidewalks (avenue), lamps | + bars, zebras, masts/signs, roundabout islands | + 2 m sidewalks with curbs, stop signs, roundabouts |
| close (<700 m) | as near | as near | + hydrants, driveways, cars (unchanged) |

Traffic (`CityNodes._syncTraffic`) now takes the plat's and the plan's roads
in one loop, one stream per lane per direction (one-way ramps get one),
lifted onto bridges, gated to `trafficRangeM` (3.5 km) of the focus, cap 600.

## 6. Phase status

**Phase 1 — landed in this pass.** One class/lane model; expressway 4/6/8 and
ramp classes; junction warrants; the sprawl as a split graph with typed
nodes; on/off ramps that land on lane edges; collectors, cul-de-sacs, stop
crossings and roundabouts in the subdivisions; one mesher and one atlas for
core, sprawl and viaduct; lane-aware traffic on every road within range;
arteries reach the grid. Then the core seam: the inner ring carries the
downtown grid on (no dead-end streets at the outline), the radial keeps the
viaduct's six lanes and tapers off its deck, lane drops taper, the frontage
roads become slip ramps, and the L ends at terminals. Tests: `road_lanes_test`, `road_junction_test`,
`road_mesher_test`, `sprawl_plan_test` (topology, on/off, lane counts,
collectors, arteries), `sprawl_section_test` (network, node-gated
collectors).

**Phase 2 — interchange geometry and the core.**
- Ramp merges: gore hatching, acceleration/deceleration lanes (a parallel
  lane strip along the mainline for ~250 m, tapering), the ramp arriving at
  2–5°, not 25°.
- Diverging diamond interchange (DDI): needs **one-way carriageways** on the
  cross road between the two terminals (two `ramp`-like one-way segments
  crossing over each other) — add a `oneWay` two-lane class or a per-segment
  flag, then a `_divergingDiamond` template next to `_diamond`/`_cloverleaf`.
  Pick per interchange by the crossing road's class and traffic.
- Partial cloverleaf (parclo) and single-point urban interchange templates;
  interchange kind chosen by what is crossing what, not always cloverleaf
  for expressway × expressway.
- The core's *diamond* ramps (at the avenues inside the core) should land
  on the **frontage roads** (Texas style), not cross them at grade; the
  frontage roads become one-way pairs. The slip ramps at the core's edge
  are in; these interior ones are not.
- The seam in the GROUND: the plat's roads drape on the graded (edited)
  terrain, the sprawl's on the base field, so a street crossing the outline
  can step where the grading ends. The terrain shaper should grade the
  inner ring's streets too, or the sprawl should read the edited field near
  the core.
- Turn lanes: widen approaches to signalised nodes (a left-turn pocket per
  approach, painted arrows in the atlas — add an arrow band), and stop bars
  per lane.
- Roundabout splitter islands and circulating lane markings; multi-lane
  roundabouts at avenue × avenue where the planner prefers them.
- Signal heads that cycle: rebuild the junction furniture batch on a period
  (or move heads to an instanced draw keyed on epoch) instead of freezing at
  build time — true for the core today as well.

**Phase 3 — one network for the sim.**
- A `RoadNetwork` graph (nodes/edges with `LaneLayout`, spatial hash) that
  BOTH `CityLayout` and `SprawlPlan` populate, replacing the `ParcelNetwork`
  touch-test and giving the sim one connectivity/routing structure.
- Routed traffic: vehicles follow paths across junctions (ramp → expressway
  → ramp → arterial → collector), obey signals, queue. Congestion per edge
  from routed flow, feeding `parcelCongestion`.
- The editor draws every class (the class row already lists them); expressway
  and ramp commits split only what they touch (no lot re-plat), and a ramp
  tool that snaps its ends to an expressway edge and a cross road.
- Local streets in the sprawl become real edges of that graph lazily (per
  section, deterministic from the seed), so the sim can route into a
  subdivision without the plat's cost.

**Phase 4 — look.** Guardrails and lamp masts on expressways, overhead sign
gantries at exits, gore-area impact attenuators, painted crosswalk styles,
raised medians with planting on avenues, bus bays at collector T's.

## 7. Gotchas learned here

- A section decides whether to run a collector out to the highway by
  asking whether the plan has a node there (`hasNodeAt`). Compare
  **across the ground**, not through it: the node is draped with a lift on
  the real terrain and the section may stand on a nominal radius, so the
  radial gap can be metres. The first cut compared 3-D distance with a 6 m
  tolerance and the south side of a junction fell back to a cul-de-sac.
- A section that is mostly staked plots (the generator's installations)
  legitimately has almost no streets; the plan only puts a junction on
  the highway if the collector is clear for its first 160 m, or the
  junction gets a stub off the highway to nowhere.
- A plain `dart` script cannot import anything under
  `infrastructure/flutter_scene` (it pulls `dart:ui`); probe renderer
  code with a throwaway `flutter test` file instead.

- `MeshBuilder.triangle` reverses winding; every strip in the mesher keeps
  the `quad(prevL, prevR, r, l)` order of the original ribbon.
- A cut that lands **on** a polyline vertex must not duplicate it (`_splitAt`).
- Bridge ranges shift with a piece but are **never clipped** to it, or the
  deck ramps down at every split.
- `_Along.at` clamps to the polyline; a merge past a short piece's end lands
  on the end. `_ThroughMap` maps the core's composite line back to the
  radial drafts and drops cuts that fall on the deck.
- The sprawl's `_syncTraffic` range gate keys on the road's end points in the
  body frame; a 30 km interstate piece is never "near".

## 8. One plat (2026-09-04)

The two-model split in §0 — `CityLayout` for the core, `SprawlPlan` for the
sprawl — is gone. Everything past the outline is plat, laid by the generator
through the same `commitRoad`, cut by the same subdivider, built through the
same placement, drawn by the same renderer. What made that affordable:

- **The plat scales.** `CityLayout` keeps a `SegmentIndex` of every road's
  samples (a straight road is one segment) and a `BoxIndex` of the lots cut
  so far; every "what is near this?" — crossings, depth rays, corner
  clipping, side streets, curb distance, the connectivity walk — is local.
  Decimation is Douglas-Peucker, so a straight street is its two ends. A
  96x96 grid (18.6k roads, 46k lots) lays and plats in 2.4 s.
- **A road says how it is platted.** `RoadSpline.lotFrontageM/lotDepthM`,
  `frontsLots`, `collector`, `graded`, `bridges`,
  `startHalfWidthM/endHalfWidthM`. A suburb's street cuts house lots; a
  county highway fronts nothing; the sprawl's streets, lots, strips and
  farms are draped, not graded (the shaper skips them — 24k brushes on a
  6-mile city, else).
- **commitRoad knows the expressway's rule.** A road crossing an expressway
  is bridged over, neither cut; two expressways, the earlier goes over; a
  ramp is the exception. Each end may decline to snap (a merge on the edge);
  `splitRoadAt` makes a merge; the commit reports its crossings, which is
  what the interchanges are placed from.
- **The generator lays the sprawl.** `_laySprawlRoads`: county grid, the
  railway on, interstates (six lanes to the outline, four beyond, the deck
  descent, the beltway ring), cloverleafs then diamonds — spaced from each
  other and from other highways, ramps built ALONG the expressway so a bend
  never puts one across the centreline — the core's diamonds, the slip
  ramps, sound walls by section. `_laySections`: each mile square's streets
  (collectors to a real highway junction), lots by a suburb's frontage,
  houses/shops/works by density, strip malls and quarter-section farms as
  plots. `SprawlPlan` is zoning only: outline and sections; interchange
  points ride the spec like the plots do.
- **One tiled renderer.** `CityNodes` buckets the frame into two-mile tiles
  of the body's frame, tiers them by distance (near/mid/far), builds them
  nearest-first within a frame budget, hangs them under one root per body,
  and draws junctions from every road end that falls in the tile.
  `SprawlNodes` and `SprawlSectionBuilder` are deleted; the wire carries no
  sprawl lists.

Measured in the studio: a 6-mile, 7.7k-building city draws at 0.5-3.6 ms
in the city pass; a 20-mile, 110k-building one generates in ~100 s and
draws once its tiles have built.

Still open, for the next passes: the wire re-samples every road and lot
per capture (cache per layout version); the sim walks every lot per tick
(stagger); saves store every road and lot (seed + deltas); house lots take
`r-low`'s housing count (a detached-house spec); parkland sections are bare
ground; the studio's "Sprawl" slider could read "Extent".
