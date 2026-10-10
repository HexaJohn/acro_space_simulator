# Colony loyalty and secession

Status: approved for phase 1, 2026-10-10 (Q6/Q7 answered by the user; Q1–Q5 on the proposed defaults, revisable).
Phase 1 is built; phase 2 (independence) is built on `feat/secession-p2` — see "Phase 2, as built" under §7.
Phase 3 (negotiate + win hearts) is built on `feat/secession-p3` — see "Phase 3, as built" under §7.

## 1. Intent

A colony that is mismanaged **corrects itself**, and one that is neglected or misruled long enough
**stops taking orders**. It declares independence and carries on as a faction the simulation runs. The
player can win it back three ways:

- **Negotiate:** rejoin on terms.
- **Win hearts:** it asks to rejoin because the player's other colonies are well run.
- **Force:** military reconquest.

Decided by the user, 2026-10-10:

- A seceded colony becomes an **independent faction**. It keeps living, governs itself, and is visible but not
  controllable.
- **All three** ways back.
- Loyalty wears down from **both** player absence and bad state. Absence erodes it slowly, misrule speeds that
  up, and attention plus good government restore it.
- **Independence needs self-sufficiency** (added 2026-10-10). A colony in a hostile environment, which is any
  body but Earth in practice, lives on the player's supply chains. It can only truly secede if it can keep
  itself alive (§3.4). A dependent colony that turns against the player cannot leave. It can strike, stall
  and wither, but it cannot walk away from the shuttles that feed it. (*The Moon Is a Harsh Mistress*: Luna
  could revolt because it grew its own grain. Antarctic stations never secede.)

## 2. What exists today

| Piece | Where | Gap |
|---|---|---|
| Self-correction: population settles at what the colony can supply, plus community services and burial | `city_sim.dart` (`popTarget`, `coverOf`, 19673a2..34a83f7) | none |
| Auto-voted laws, with hysteresis | `autoVote`, `city_sim.dart:~2040` | only when `govt.lawsAutoVoted` (Republic, Democracy) |
| Rebellion meter | `socialTick`, `city_sim.dart:2024`: unrest = 0.5(1−happiness) + 0.2 crime + 0.2 inequality + 0.1 corruption, × `govt.rebellionSensitivity`; eases toward unrest − 0.4 | at 1.0 a **revolt** is a one-off hit (−30% population, ×0.6 funds, reset to 0.3); it can repeat forever and is never terminal |
| Revolt message | `revoltMsg` → Politics panel banner only (`city_panels.dart:1053`) | missing from the status list (`city_builder_screen.dart:825`) and from the City Game HUD |
| Owner on assets | `Vessel.ownerId`; `Player.ownedAssetIds` + `Session.validate` (`domain/multiplayer`) | **CitySim has no owner**; the city builder bypasses commands |
| Player edit entry points | ~20 CitySim mutators + direct field writes (`govt`, `taxRate`, `laws`) from `city_panels.dart`, `city_edit_overlay.dart`, `road_tool_controller.dart`, `city_site_actions.dart`, `simulation_view_colony.dart` | **no single choke point** |
| Persistence | `CitySim.toJson`/`fromJson`; world `GameStateCodec` | `taxRate`, `laws`, `rebellion`, `crime`, `corruption`, `inequality` are **not saved**: a save/load wipes misrule |
| Neglect clock | none | no colony clock, no "last attended" stamp |
| Force | military specs (`base`, `airfield`, `barracks`, …) feed `safety` only; war deaths | no garrison or strength model |

Supplies reach a colony three ways, and none of them is local:
- scheduled spaceport deliveries and shuttle cargo write straight into `stock` (`shuttle_cargo.dart:114`);
- relief missions (`requestRelief`) bring crew and care packages;
- the spaceport building's own food/water/oxygen output (0.3/s each, fuel-fed) stands for imports.

`supportablePop` (19673a2) counts all of them, so it is not a self-sufficiency measure as it stands.

Treasuries are **per colony** (`CitySim.funds`). There is no player-wide purse. This affects how
**Negotiate** can work (§6.1).

## 3. The model

### 3.1 State (new, saved)

- `colonyTimeS`: colony seconds integrated by `advance`. This is the clock for neglect. World epochs do not
  reach the city headlessly, and colony time is what the economy already runs on (`weekSec`).
- `attendedAtS`: `colonyTimeS` of the player's last **act of governance** on this colony (§3.3).
- `loyalty` ∈ [0, 1]: starts at 1.
- `allegiance`: `colonial` | `independent` | `occupied` (§6.3).
- `revolts`: timestamps of recent revolts (a short list, pruned to the window).
- `desperation` ∈ [0, 1] (§3.4), `selfSufficiency` (eased, §3.4), and `portSeized` plus the impounded craft and cargo (§4.1).
- Also start saving `taxRate`, `laws`, `rebellion`, `crime`, `corruption` and `inequality`. Without that, loyalty
  is a stat the player can save-scum away. This changes the "save only what the player MADE" rule at
  `city_sim.dart:4840` deliberately, and the doc comment is updated to match.

### 3.2 Loyalty drift (per tick)

```
neglect = max(0, colonyTimeS − attendedAtS − graceS) / neglectScaleS     // 0 while attended
misrule = rebellion                                                      // 0..1, already smoothed
content = happiness × serviceCoverage()                                  // a well-run place tolerates absence
dLoyalty/dt = − absenceRate × min(1, neglect) × (1 − 0.7 × content)
              − misruleRate × max(0, misrule − 0.3)
              + recoverRate × (attended recently ? 1 : 0) × content
```

A revolt also knocks `loyalty` down by `revoltHit`.

Proposed defaults on Earth's 120 s day (tunable, `CityLoyaltyTuning`):

| Knob | Default | Reads as |
|---|---|---|
| `graceS` | 10 days (20 min) | an unattended colony is fine for a while |
| `neglectScaleS` | 20 days | erosion ramps to full over the next 20 days |
| `absenceRate` | full erosion at content 0 takes ~40 days from loyalty 1 | absence alone, if the colony is happy, takes ~4× longer |
| `misruleRate` | a colony held at rebellion 0.8 loses its loyalty in ~10 days | misrule speeds it up |
| `revoltHit` | 0.15 | three revolts close together are near-fatal |
| `recoverRate` | ~5 days of attended, content rule restores 0.2 | attention + good rule bring it back |

### 3.3 What counts as attention

An **act of governance**: any player mutation through the control gate (§5), such as zoning, building, roads,
tax, laws or government, or claiming a site. **Opening the editor without acting does not count.** Otherwise
a player could keep a colony loyal by glancing at it. This is open question Q2.

### 3.4 Self-sufficiency

`selfSufficiency` is the share of the colony's life-support need that its **own** buildings cover. It is
computed alongside `lifeNet` in the production loop, but counts only buildings for which `isLifeSupport` is
true, which already excludes the spaceport. Deliveries, cargo and relief are not counted.

```
local_c = net output of local life-support buildings of commodity c        // food, water, oxygen (always)
selfSufficiency = min over c of local_c / (population × perPerson_c)       // clamp 0..1; 1 with no population
```

It is eased over about 5 colony days. A good harvest week should not count as self-sufficient, and a
disaster day should not cancel it.

- **Earth** (breathable, aquifers, farms) clears 1.0 with the starter kit. The rule is the same everywhere;
  hostile worlds are simply hard to satisfy.
- **The Moon / Mars** need hydroponics or lab-grown food, water from ice, sewage recycling or aquifers, and
  oxygen from electrolysis or a harvester, each at the population's scale. Until then they are dependent.
- **Oxygen always counts** (user, 2026-10-10), whatever the complexity setting and whatever world the colony is
  on, because the **air itself** is a local source:
  ```
  local_oxygen = O2 buildings' net output + airO2 × need_oxygen
  ```
  `airO2` is defined in `docs/plans/terraforming.md` §3.4. It is the share of a person's oxygen the sky's real
  partial pressure supplies, from the body's **actual, mutable** atmosphere, which towers change gas by gas.
  - Earth's sky covers it.
  - A raw Mars colony needs electrolysis or a harvester for every person.
  - As towers thicken Mars's air and raise its O2, the sky covers more.

  Terraforming is a road to independence. Below complexity 0.3 the sim does not manage oxygen for survival,
  but it still counts here, so the HUD's independence readout must show it.
- Power and compute are local by construction and do not enter the measure. Fuel and other industrial
  goods do not either: a colony that can breathe, eat and drink can survive alone, even if it cannot grow
  without trade.

**Dependent** = `selfSufficiency` < `independenceBar` when the secession condition fires.

The bar is **not fixed**: it falls with the colony's state of mind (user, 2026-10-10). A content but neglected
colony will not leave until it can feed itself. A colony driven to despair will declare independence even
if it cannot, choosing liberty or death.

```
independenceBar = 0.9 × (1 − desperation)
desperation ∈ [0,1], saved, eased:
  rises with  time spent in standoff (§3.5), each revolt, rebellion pinned near 1, mood near 0,
              a seized port being retaken or starved out (§4.1)
  decays with attended, content rule (the same `content` term as loyalty recovery)
```

Proposed: a colony that sits in standoff at mood ≈ 0 for about 15 days reaches desperation ≈ 1. Each revolt
adds 0.15. Decay takes about 10 days of good rule to clear it.

A colony that secedes **below** sufficiency is starving by its own choice. It stops receiving deliveries
(§4), its `supportablePop` falls, and it either petitions to rejoin (§6.2) before the die-off, or withers.
Which of the two happens is the desperation that drove it: the more desperate it was, the longer it holds out
before petitioning.

### 3.5 Stages (with hysteresis)

| Stage | Loyalty | Effect |
|---|---|---|
| Loyal | ≥ 0.6 | none |
| Restless | < 0.6 (back above 0.65) | status notification + HUD chip; the colony starts **self-governing**: laws auto-vote whatever the government, and an over-high tax is pulled down toward what the mood bears (a tax revolt) |
| Defiant | < 0.3 (back above 0.35) | **strikes**: `restThrottle` × 0.7 and tax collection halved (non-payment); a louder warning naming the causes (neglect, unrest, revolts) |
| Seceded | ≤ 0, or 3 revolts within 15 days, **and self-sufficient** (§3.4) | `allegiance = independent` (§4) |
| Standoff | the secession condition fires, but the colony is **dependent** | it cannot leave. Defiant's strike deepens (`restThrottle` × 0.4, no tax), settlers emigrate at the shortfall rate (the existing emigration path), and the warning reads "would secede, but cannot feed itself". Rebels **seize the spaceport** (§4.1) once
desperation passes 0.4. It resolves when loyalty climbs back (attention + good rule), or the colony withers to its crew floor. If it ever becomes self-sufficient while still in standoff, it secedes at once. |

The causes shown are the actual terms of the drift equation, so the warning says *why*, for example "no orders
for 34 days" or "rebellion 0.82: crime, inequality".

## 4. Independence

### 4.1 Seizing the spaceport (standoff and independence)

The spaceport is a dependent colony's only lever, and rebels take it (user, 2026-10-10):

- **The next delivery is impounded.** Its cargo goes into the colony's own `stock`. This prolongs the standoff,
  as a real impounding would, and the player sees exactly what was taken.
- **Docking is refused after that.** Scheduled deliveries to the seized port are suspended and flagged
  "port held by rebels". A shuttle already en route lands, and is held as well, so its cargo is impounded
  and the craft stays grounded until the port is retaken.
- **The port closes both ways.** Immigration stops (it already needs a working port) and emigration stops
  too. Settlers are trapped, so withering comes from hunger rather than departure. The emigration in §3.5's
  standoff row applies only before the seizure.
- **It shows up in the player's logistics,** not just the colony's HUD. A dependent revolt hurts the
  player's supply network, which gives the player reason to deal with it.
- The port is released when loyalty climbs back past the Defiant line, on secession (it becomes the
  independent colony's port, and stays closed to the player), or when it is retaken by force (§6.3, which
  gives occupation a concrete first target).

- The control gate (§5) refuses every player command on the colony. The HUD shows it as **independent**:
  readouts visible, tools greyed out, with a "Reclaim" panel (§6).
- The colony keeps ticking. It runs on the self-correction it already has, plus an **independent governor**,
  a small rule set run every few colony days:
  - auto-vote laws;
  - set tax to the highest rate that keeps mood ≥ 0.5;
  - if starving or short of water, build the life-support building it can afford on a free lot;
  - with no landfill or morgue past the waste or corpse thresholds, build one;
  - otherwise zone free lots to match RCI demand.

  It is deliberately dumb. It keeps the place alive and growing slowly, which makes it worth reclaiming.
- Its treasury is its own (it already is). Vessels and shuttles owned by it: out of scope for v1.
- **Player deliveries to it stop.** Its schedules are suspended, because it left the supply chain. It lives on
  local production, which is why it had to be self-sufficient to leave.
- **Losing self-sufficiency forces the question.** If an independent colony falls below the bar (it outgrew
  its farms, or a disaster took a plant), its stock runs down and `supportablePop` shrinks. Before that ends
  in a die-off, it **petitions to rejoin** on the player's terms (§6.2). Dependence drives it back, whatever
  the player's reputation.

## 5. The control gate

There is no choke point today. v1 adds one:

- `CitySim.playerControl` → `ControlState { allowed, reason }`, plus `CitySim.attend()`, which stamps
  `attendedAtS`.
- **UI-level gating at the existing call sites**, because domain mutators are also called by the sim itself
  (starter kit, growth, the independent governor) and must not be gated:
  - `CityEditController` (zone, place, clear);
  - `RoadToolController` (build, move, upgrade, rename, reverse, junction);
  - `CityPanels` (govt, tax, laws, economy);
  - `city_site_actions.dart`;
  - `simulation_view_colony.dart` (`claimSite`).

  Each checks `playerControl.allowed` before acting, and calls `attend()` after a successful act.
- A widget test sweeps the tools on an independent colony and asserts that every one is disabled. This
  stops a new tool from bypassing the gate silently.
- Later, for multiplayer: `allegiance` becomes an owner id, and the gate reads `Player.owns`. The
  `PlaceBuildingCommand` path in `ApplyCommands` is still a no-op and stays out of scope.

## 6. Ways back

### 6.1 Negotiate

The colony states **terms**. Accepting rejoins at loyalty 0.5 under **binding terms** for N days, during which the
gate refuses to break them:

- a tax cap;
- named laws kept;
- no demolitions.

It costs no money, because there is no player purse (Q1). The worse the colony was run, the more terms and
the longer they last. Breaking a term is not possible while the terms run; when they expire, normal rule
resumes.

### 6.2 Win hearts

Reputation = the population-weighted mean loyalty × mood of the player's **colonial** colonies in the same
world (`FlightSession.cities`). An independent colony that is doing worse than that reputation builds
**petition** pressure. Past a threshold it asks to rejoin (a notification), on light terms. With no other
colonies there is no reputation, so this route needs a second colony.

**Dependency petition.** An independent colony whose `selfSufficiency` has fallen below the bar petitions
regardless of reputation, on terms the player sets. This is the most common way back for an off-world
colony that seceded at the edge of sufficiency.

### 6.3 Force

This needs a strength model that does not exist yet:

- **Garrison strength** = the safety from military buildings in the player's colonial colonies, **projected**
  by a force-shuttle run to the target (reusing shuttle runs, `shuttle_run.dart`);
- against **resistance** = the population × (1 − happiness) of the target.

A win sets `allegiance = occupied`:

- control returns;
- loyalty is 0.2 and rebellion high;
- the garrison suppresses rebellion growth, but costs mood;
- if the garrison leaves early, it re-secedes fast;
- holding it for M days while loyalty climbs past 0.6 turns it back to `colonial`.

This is the biggest piece and the last phase.

**Blockade** is the cheap alternative to force. An independent colony still needs imports for anything it
does not make, such as fuel, electronics and medicine. The player refusing trade (all independent colonies
are refused in v1, see §4) caps its growth, but cannot starve a colony that is truly self-sufficient. Against
a dependent colony in **standoff**, cutting deliveries is coercion: compliance through hunger. It raises
loyalty fast but costs heavily in mood and reputation (§6.2), and phase 3 should make that trade-off visible.
v1 does not model it beyond the player's existing ability to cancel delivery schedules.

## 7. Phases

1. **Loyalty**: clock, attendance, the drift equation, `selfSufficiency` and `desperation` (§3.4), the standoff
   stage and spaceport seizure (§4.1), stages and their effects, warnings in the status list
   and the HUD (including the revolt toasts that are missing today), and saving the political state.
   Domain plus HUD. Tests: neglect alone, misrule alone, recovery, hysteresis, and the save round-trip.
2. **Independence**: the control gate across every call site plus the sweep test, the independent governor,
   and the independent HUD state.
3. **Negotiate + win hearts**: terms, the binding-term gate, reputation, petitions.
4. **Force**: garrison/projection/resistance, occupation.

Each phase is one commit or a few, shipped behind nothing, since the first phase already only warns.

### Phase 2, as built (2026-10-10)

**The gate (§5).** `CityControl.playerControl` (new `city_control.dart`) answers `ControlState {allowed, reason}`:
refused for `independent` ("This colony has been independent since day N and takes no orders."), allowed for
`colonial` (a Restless, Defiant or standing-off colony still takes orders) and for `occupied` until phase 4
says otherwise. It is an extension on `CitySim` in its own file, not a member, to keep `city_sim.dart` edits to
three lines; `mayAct(onRefused)` is the ask-and-say form every call site uses. Domain mutators stay ungated.

Gated call sites, each greyed with the reason as its tooltip and saying it (blocked line, banner or snack bar)
when tapped, never silently dead:
- `CityEditController`: `applyTo`, `applyToLot`, `applyToParcel`, and picking up an acting tool (`set`,
  `pickUtil`, `pickZone`). `CityEditTool` gained `acts` (default **true**, so a new tool is gated until someone
  decides it only looks); Look and Traffic are `acts: false`. The strip shows the reason before anything is tried.
- `RoadToolEditing.refusedOn` at every method that changes the colony: `clickAt`, `_build`, `upgradeAt`,
  `reverseAt` (and so `rightClickAt`), `commitSpline`, `toggleJunctionAt`, `moveSelectedEnd`, `renameSelected`.
  Previews and quotes stay open. The Traffic chip is not greyed (Routes and Lane speed are readouts); its
  Junctions and Adjust clicks refuse.
- `CityPanels`: government and economy pills, the tax slider, the law switches.
- `CityGameHud`: the Budget tax slider.
- `city_site_actions.dart`: `gatedSiteAction` for meltdown, Design & launch, lander pad, relief and demolish;
  the delivery sheet stays readable but its add, edit, remove, reorder and save are refused.
- `simulation_view_colony.dart`: the own-site `claimSite` path, now `CityEditController.claimOwnSite` so the
  sweep reaches it. Opening the editor goes through `CityEditController.enter(colony, tool)`, which points the
  gate at the colony being opened *before* picking the tool. Before this, `gateCity` was only set when the
  toolbar built, so the opening tool was asked about the colony edited last: a colonial town opened after an
  independent one showed that colony's refusal and kept its old tool. An independent colony opens on Look.
- `CityBuilderScreen`: tap, drag-paint and rect fill for every tool, the tool chips, and calls phase 1 missed:
  the toolbar's Clear-all, Relief, Plant and Buy land, the lander menu's flag and launch, and the host's
  Pilot a landing / Launch in 3D rows. `_Tool` is now the public `CityBuilderTool` (with `acts`) so the sweep
  can enumerate it.

Deliberately **not** gated, because they are game settings or the player's own craft, not orders to the colony
(and they never stamp attention): the World drawer (time warp, difficulty, debug switches, re-siting,
disaster triggers), the editor's terrain-ignore switch, and "Target this pad".

**Sweep test** (`test/colony/city_control_gate_test.dart`). On an independent colony it tries every
`CityEditTool`, `RoadToolMode`, `TrafficInfoView` and `CityBuilderTool` value through the real handlers (tap,
paint, rect, lot, cell, click, right-click, spline commit, junction, adjust, rename, upgrade, reverse), every
`Govt`, `Economy` and law control, every row of the site sheet and the delivery sheet, and the toolbar chips
(each must sit under a tooltip carrying the reason). It then asserts the colony's fingerprint is unchanged:
the save, which includes the loyalty clock, so an act that still stamped attention fails too, plus the
deliveries, lander pad, flag, relief and craft. A check during the build confirmed it fails when one gate is
removed (editor zone, flat paint, site demolish).
After review, the sweep was tightened so that every control it lists can actually fail:
- The site sheet's hooks count their calls, and the test then makes the colony colonial and taps again to show
  the hooks were reachable. A no-op `onOpenVab` cannot tell a bypass from a refusal.
- Each gated row must carry the reason as its own subtitle. Before, one row anywhere on the sheet was enough.
  Only Details, Target this pad and the delivery book are left ungated.
- The flat builder's own site sheet (Pilot a landing, Launch in 3D sim, Design & launch) is driven on a grid
  spaceport through `CityBuilderToolDriver.debugInspect`. A `NavigatorObserver` fails the test if any row
  pushes a screen.
- The fixture gets a cell-map building so the toolbar's Clear renders, and a missing toolbar control now fails
  the test instead of being skipped.
- The own-site claim is tried at a site that is known to be open, and then shown to build once the colony is
  colonial again.
Mutation-checked: removing the `gatedSiteAction` gate, the claim gate or the Clear gate each fails the sweep.
The relief row stays doubly shut. Phase 1's `portHoldReason` already empties its action, so the gate's only
visible effect there is the reason on its subtitle, and that is what the test asserts.

**Independent governor (§4)**, `independent_governor.dart`, called from `CitySim.advance` right after the
loyalty step and inert unless `allegiance == independent`:
- *Calendar*: a sitting on every `periodDays` (3, tunable in `IndependentGovernorTuning`) boundary since
  `independentAtS`, starting on the declaration's own tick. It is stateless, read off the saved clock, so a
  load sits on the same days, and one warped step that spans boundaries sits once.
- *Sitting*: auto-vote the laws (self-government already votes them every tick, so this is mostly a log line);
  move the tax at most ±0.05 toward the rate whose mood cost leaves happiness at 0.5; then **one** build, the
  most urgent first. Life support comes first: food, water, or oxygen (oxygen only where the sim makes people
  breathe made oxygen; that rule is read, never changed) when own production is below need or the colony is
  starving. Then a landfill past waste backlog 0.3 with nothing taking garbage, then the cheapest deathcare
  past max(3, 2% of the living) corpses with none. With nothing built, it zones up to 2 free served street
  lots for the use with the highest `demand / (1 + lots already zoned for it)`. Scoring by raw demand zoned
  shops forever, because commercial demand sits near 1 with no leisure.
- *What it builds for a shortage* (`_fixShortage`). The shortage is read off what was made, but the fix is
  chosen against what the existing buildings could make at full throttle (`_LifePlant`). The first version
  answered every short reading with another cheapest producer. With the power out, that built farm after
  water plant that none of them could run, each adding draw to a dead grid, until the ore reached the
  reserve. A reviewer's probe showed 395 ore spent on 10 dark buildings while the colony starved from 65 to
  3.6. Now, in order:
  1. If life support draws more watts than the colony makes, it builds the generator with the most watts per
     ore that feeds on nothing (a new `GovernorActKind.power`).
  2. If the existing producers are held back by staffing or compute (life throttle under 0.98 with power
     covered), it builds nothing.
  3. If the existing producers would cover the need at full throttle, it builds whatever they are starved of,
     one input deep.
  4. Otherwise it builds the cheapest producer whose inputs the colony makes enough of and whose draw the
     grid can carry. If the input is short, it builds the input first, counting the new building's draw: a
     water-short town gets a pump before another thirsty farm. If the grid cannot carry it, it builds the
     generator first.
- *Pending cap per use.* Zoning stops for a use while 2 of its lots are zoned and unbuilt, rather than while
  any 2 are. Two shop lots stuck on the growth line (demand hovering at 0.2, growing a hair and decaying a
  hair) held a single shared cap full for good. Shop and works lots that goods cannot reach are never zoned,
  since they could never grow.
- *Placement*: an ordinary building goes on the first free served street lot. A building that stakes its own
  plot (farm, landfill, aquifer) first reuses an empty staked plot big enough, such as the field a burned
  farm stood on, then searches for a site beside a road: off each side, past each end and at each corner of
  samples along every road, nearest the centre first, at most 400 checks, through the editor's own
  `siteBlockedReason`, and never covering a zoned or built street lot. Re-cutting the lots under it would
  demolish them. "Covering" tests each kept lot's bounding box. The first version tested only its centroid,
  and the new test caught a plot that missed two deep lots' centres, bit their back halves, and dropped both
  in the re-cut. A colony with no plat (the flat sandbox) uses the cell grid instead.
- *Budget*: ore only, since building costs ore, and never below a 10-ore reserve. It spends no money and
  never lays roads or demolishes.
- *Log*: `governorLog` (bounded, display only, not saved; kept in an `Expando` beside the colony).
- Tests (`test/colony/independent_governor_test.dart`):
  - a seceded starter-kit Earth town stays alive and grows over 40 days;
  - it rebuilds a farm when food runs short;
  - with the power out it builds a generator first and does not drain its ore;
  - a water-starved town, on the plat or on the flat grid, gets water before another farm;
  - a short-staffed farm gets no twin;
  - the tax steps up, steps down and stops at the bearable rate;
  - landfill and deathcare appear past their lines and not under them;
  - zoning picks by demand per zoned lot, and stalled lots hold back only their own use;
  - a new plot staked through `_findSite` keeps every zoned, grown or built lot's id, use and building;
  - it never spends below its reserve or touches funds, and does nothing to a colonial colony;
  - its calendar survives a save, and at least one sitting acts in the first window.

**Independent HUD state.** `IndependencePanel` (`city_control_ui.dart`) shows "Independent since day N",
the causes, what its council has done lately, and a placeholder **Reclaim** section ("Ways to win it back
(negotiation, goodwill, force) are not available yet"). It is worded for players, not with the plan's phase
numbers, because master ships to prod. It appears as a compact card under the City Game HUD's top
bar, in full when the loyalty chip is tapped, and in the Politics drawer's LOYALTY section. Readouts stay live,
and tools are greyed by the gate. The causes are saved: `CityLoyalty.independenceCauses` (`independentWhy` in
the save), recorded at the declaration, because the live causes have moved on by the time anyone reads the panel.

**Deliveries.** These stay suspended by phase 1's dispatch rule (`portClosedToPlayer`), and the test checks it:
no craft for 200 s with a recurring run booked, and relief refused. On an independent colony the delivery
sheet cannot add, edit, remove or reorder, so a suspended run cannot be booked back on. A *seized* port on a
still-colonial colony stays editable, because the colony still takes orders, but its runs stay suspended by
the same rule.

**Deviations and open items.**
- Stretch not done: a **player-flown vessel** landing at a seized or independent pad has its cargo impounded
  (phase 1) but is **not held**. Holding it means locking a player vessel's throttle or launch, which is
  flight-side (input or `advance_simulation_tick.dart`) and invasive, so it is left for a later pass.
- The governor builds power only when life support is dark, and no services or housing beyond zoning. A starter-kit town under it grows (6 → ~65
  settlers in 20 days in a debug run of the test fixture), but its mood sags to ~0.2 as services fall short
  and the tax goes to 0, and it can still revolt. It is dumb by design. Whether it should build a clinic or a
  generator is a tuning question for the user.
- The governor's tax and phase 1's tax revolt both act on an independent colony (stage `seceded` is
  self-governing). The revolt only pulls down; the governor can also raise it, a step per sitting.
- The governor's log is not saved; the panel's "its council" list restarts after a load.
- A starter-kit town under the governor levels off at about 64 settlers after roughly 20 days. This is not
  the pending cap: it is the sim's own RCI balance. Residential demand is `0.2 + (jobs − housing)/120`, so it
  sits on the 0.2 growth line once homes match jobs, and commercial demand `1 − leisure/pop` sits there too.
  New lots of either use flicker around the line and never build. Breaking this needs the governor to add
  jobs or services, a design question left with the user.
- Phase 2 leaves `airO2`, oxygen consumption and the sufficiency/breathable rules untouched (the terraforming
  lane owns them); the governor only reads `airO2` and `breathable` to decide whether oxygen is short.
- **Integration with terraforming phase 2 (integ/phase2).** Once both phase-2 lanes were merged, the governor's
  oxygen need is `CitySim.o2NeedPerSec`, the figure the tick charges (population × (1 − `airO2`), partial
  cover), rather than its own copy of the formula. Its full-throttle plant (`_lifePlant`) also no longer
  counts an Atmospheric Harvester while `o2Harvestable` is false. Terraforming phase 2 idles harvesters under
  a sky below 2% oxygen, and harvesting itself thins the sky. Counted at nameplate, the harvesters that
  thinned a sky past that line read as oxygen "built enough", and the council built nothing while the colony
  suffocated. Pinned by `independent_governor_test.dart` ("harvesters under a sky thinned past 2% oxygen are
  not counted"), and the test was checked by removing the guard to make sure it fails.
- **Cross-lane review fixes (integ/phase2).**
  - **The famine latch is saved.** `starved` and `foodSecurity` were never in `CitySim.toJson`, so a colony
    saved starving loaded fed. The governor reads `starved` to call food short, and happiness pins to 0 on
    it, so after a load an independent colony's council built differently than it would have without one
    (a probe ran 300 ticks to 32.2 against 35.9 settlers). Both are additive keys omitted at their
    defaults, so a fed colony saves byte-for-byte as before.
  - **Placement rules said once.** The governor's `_placeable` now asks `CitySiteRules.placementRefusal`
    (`city_site_rules.dart`), the same rule the flat builder and the in-world editor use. See
    `terraforming.md` §9 for the editor half.
  - **"Target this pad" on a closed port** stays live (§5: the player's own craft is not gated) but now says
    `Unwelcome — <portHoldReason>. Your craft can still land here.` in warning colour. The loyalty explainer
    no longer says the port is "closed to your craft". It says the port takes no relief and deliveries are
    suspended, and that a craft the player flies can still land, unwelcome. That stays true until the
    player-flown hold above is built.

### Phase 3, as built (2026-10-10)

New files: `city_reclaim.dart` (domain: grievance, terms, petitions, reputation), `city_reclaim_ui.dart`
(the Reclaim section, the negotiation dialog, the term picker, the binding-terms card), and
`test/colony/city_reclaim_test.dart`. Edits to the shared files are small: a `reclaim` field, a public
`notice()`, the grievance at `_secede`, the save key and two warning hooks in `city_loyalty.dart`; one
guard in `CitySim.autoVote`; one call in `AdvanceSimulationTick`; the term refusals in `city_control.dart`;
and the gated call sites below.

**State** (`CityReclaim`, held on `CityLoyalty.reclaim`, saved under `loyalty.reclaim`, omitted entirely for
a colony that never left): the `Grievance` recorded at the declaration (days without orders, rebellion,
revolts in the window, desperation), the `BindingTerms` in force and the colony second they run out at,
hearts `pressure`, the dependency holdout clock `dependentS`, and the waiting `Petition`. The grievance is
saved because by the time anyone negotiates the live state has moved on (the same reason
`independenceCauses` is). `reputation` is a per-tick input handed in by the world, not saved. Tuning is in
`ReclaimTuning`.

**Terms (§6.1).** `severity` = 0.3 × neglect (days / 40) + 0.3 × misrule ((rebellion − 0.3) / 0.6) + 0.25 ×
revolts (out of 3) + 0.15 × desperation, clamped to 0..1. Misrule and revolts outweigh absence, so a
mistreated colony asks more than a forgotten one. From severity:
- always a **tax cap**, 25% at severity 0 down to 5% at 1;
- from 0.3, **kept laws**: 1 to 3 of the laws it holds (`Law.values` order). A colony that holds none
  names none;
- from 0.55, **no demolitions**;
- **duration** 10 + 30 × severity days, plus up to 10 more once it has been independent for 30 days.
  Time away lengthens the terms but adds none.

Negotiate is always open on an independent colony. "Negotiate" shows the terms; Accept rejoins, Decline
changes nothing.

**Rejoining** (`_rejoin`): allegiance colonial; loyalty 0.5 (the stage band it lands in, so Restless);
independence date and causes cleared; the revolt window emptied (three leftover revolts would break it away
again the next tick); attention stamped (accepting is an act of governance); and the terms start. A tax over
the cap is pulled to the cap, and the kept laws are enacted. Deliveries resume on their own, since
`portClosedToPlayer` reads the allegiance. A re-secession drops any terms still running.

**The gate under terms** (`city_control.dart`): `taxCeiling`, `taxRefusal(rate)`, `repealRefusal(law)`,
`economyRefusal(economy)`, `demolitionRefusal` and `mayDemolish(onRefused)`. Every refusal reads "The
rejoining terms cap the tax at 10% (12 days left)." Enforced at:
- the Politics/City panels' tax slider and the HUD Budget slider: held at the cap, the reason said on
  release, and a standing line under the slider;
- the law switches: a kept law's switch is greyed with the reason, and turning it off refuses;
- the economy pills: switching to an economy with a fixed levy (Communism, 50%) over the cap refuses;
  otherwise the cap could be dodged by changing economy;
- the in-world editor's bulldozer (picking it up, `applyToLot`, `applyTo`) and its chip;
- the site sheet's Demolish row (`gatedSiteAction(termRefusal:)`);
- the flat builder's bulldozer, Clear-all, and any tap, paint or rectangle that would clear a building
  cell (a road, zone or platform laid over it, a same-type utility tap). A rectangle skips those cells and
  fills the rest, and a fill refused whole no longer stamps attention.

`CitySim.autoVote` never repeals a kept law, because the term was the colony's own demand. Before this
guard, its own vote (it is Restless, so self-governing) repealed the law it had just made the player keep.
When the terms run out, a "terms have run out" notice is raised and normal rule resumes.

**Win hearts (§6.2).** `CityReclaimSim.reputationOf(cities)` is the population-weighted mean of loyalty ×
mood over **colonial** colonies with people in them. Independent and occupied colonies are excluded, and
it is null with no such colony. `AdvanceSimulationTick` hands it to every city before the city loop
(`handOutReputation`), because no colony can see its neighbours from inside its own tick. An independent
colony's own score is its mood. Pressure fills at `gap / (0.2 × 15 days)` while reputation − mood > 0, and
drains over 10 days otherwise. Both are linear in dt, so warp is exact. At 1 it petitions on **light
terms**: the same rule applied to 40% of its grievance and of its time away. The flat sandbox never gets a
reputation, so it has no hearts route (Q5). Declining empties the pressure, so it asks again only once the
pressure has refilled.

**Dependency petition (§6.2).** Dependent = `selfSufficiency` < the live, desperation-scaled bar, **or**
starving while below the undesperate bar (0.9). Deviation: the live bar alone is not enough. Hunger pins
mood at 0, which drives desperation to 1 and the bar to 0, so a starving colony would measure "sufficient"
and never ask for the help it is dying without. `dependentS` rises with dependent time and falls with
sufficient time. Past a holdout of 2 + 12 × (desperation at the declaration) days, it petitions regardless
of reputation, and outranks a hearts petition already waiting. The player picks the terms from the menu: a
cap of 5–25% or none, any of the laws it holds, the demolition ban, and 5–40 days. The player may set none.
Deviation: each term granted adds 0.05 loyalty on top of the 0.5 (goodwill). Without that, nothing makes
binding your own hand worth choosing. Declining resets the holdout.

**UI.** The independence panel's Reclaim section (`ReclaimSection`, key `independence-reclaim`) has the
petition card (Accept/Decline, or Set terms…), Negotiate, a goodwill readout (standing against its mood and
the wish to rejoin, or "none to measure" with no other colony), and **Force** greyed as "Not available yet.".
The compact HUD card says when a petition is waiting. `BindingTermsCard` shows the running terms and days
left under the HUD's top bar and in the Politics LOYALTY section. The status list and HUD chip gain
`petition` and `terms` warnings (icons handshake and gavel). The notices `petition`, `rejoined` and
`termsExpired` join the loyalty notice queue as good news.

**Carried item closed: the governor's log is saved** (`governorLogJson`/`restoreGovernorLog`, under
`loyalty.council`), so "its council" survives a load.

**Tests.** `test/colony/city_reclaim_test.dart` (22) covers: terms scaling with each grievance; kept laws
coming only from laws held; accept at 0.5 with each refusal's wording and days; the auto-vote keeping the
law; expiry; decline; re-secession dropping terms; reputation pop-weighted over colonial colonies only;
handed through the real tick, and null for a lone colony; pressure only while worse, petition past 1,
light terms lighter than stated ones; no reputation means no pressure; warp equivalence; decline and
re-ask; dependency holdout scaling with desperation; the starving clause; dependency outranking hearts;
player terms with goodwill; the save round-trip of grievance, pressure, holdout, petition and terms with
their clock; the governor log save; warnings. The sweep (`city_control_gate_test.dart`) adds term refusals
for the gate wording, the editor bulldozer (and zoning still allowed), the panels (law, levy, tax), the HUD
slider, the site sheet, and the flat builder (every tool on a building, Clear-all), plus the Reclaim UI
(negotiate decline/accept, the dependency term picker, a declined petition, the Force row disabled).
Mutation-checked: removing the site sheet's term refusal or the flat builder's tap check fails the sweep.

**Review fixes (2026-10-10).** Three reviews of the above; what changed:
- **The grievance's misrule was measured after the revolt reset it.** A revolt fires at rebellion 1.0 and
  resets the meter to 0.3 in `socialTick`, which runs before the loyalty step, so every colony driven out by
  its third revolt recorded misrule 0 and stated milder terms than one merely forgotten. `_secede` now
  records the meter's peak over the revolt window: 1.0 with any revolt in it, the live reading otherwise.
  Tests now secede real colonies through `CitySim.advance` by both routes and assert the recorded grievance
  and that the revolt route states the harsher terms; and a re-secession through the real path.
- **The demolition ban now holds against every edit that tears a building down**, not only the bulldozer.
  A road laid, spline-committed, upgraded or re-laid by its end (Traffic > Adjust), and a plot staked for an
  installation, re-cut the lots, and a lot the re-cut gives up loses its building (one dragged road end
  cleared 17 buildings in the probe). No corridor test can say which lots a re-cut keeps (a split re-orders
  the plat), so these edits run **on trial** (`city_term_guard.dart`): under the ban the plat is copied
  (`CityLayout.copy`/`restoreFrom`, `SegmentIndex.copyFrom`), the edit runs, and at the one place every
  re-plat carries its lots (`_carryRenamedLots`, `_carryLotsAcross`), before anything else moves,
  `guardBuiltLots` checks whether a built lot would be lost or doubled up. If so the plat is put back and
  the edit unwinds (no road, no charge, no attention stamp) with "The rejoining terms forbid demolitions (N
  days left). This would tear down 3 buildings." An edit that clears nothing still goes ahead. With no ban
  in force nothing is copied. Also: `_carryLotsAcross` no longer skips `_dropLostLots` when nothing was
  renamed (a dangling building key).
- **The reactor's "Disable safety systems" row** (which demolishes the reactor and sets off the meltdown)
  carries the demolition term, as Demolish does.
- **Flat builder: a road or platform is built, too.** The bulldozer was refused on a road while the Road
  tool's toggle and a zone laid over it removed the same road. Now any tool that would clear a road,
  platform or building is refused under the ban; laying over bare ground still goes ahead.
- **A fixed levy is held under the cap.** Lowering `taxRate`, all rejoining did, moves nothing under
  Communism, which kept levying 50% beside "tax at most 5%". `effectiveTax()` now holds a fixed levy under
  the cap while terms run; the colony keeps its economy, the full levy returns when the terms do, and the
  cap's line shows under the levy too. Switching ONTO a fixed levy stays refused (it would land the full
  levy the day the terms end).
- **Accept binds what was shown.** The colony ticks under the dialog, so the terms recomputed at the tap
  could differ (more days, other laws). `acceptNegotiation(shown)` binds the dialog's own terms.
- **Declining restarts both clocks**, so the other petition is not raised on the next tick.
- **Goodwill (deviation, revised):** each granted term that BINDS adds 0.05 (a cap only below the tax the
  colony pays now, each kept law, the ban), scaled by days / 40, and never past the Restless return line.
  Near-free terms bought Loyal outright. Confirm with the user.
- **Old saves:** an independent colony saved before grievances were (no `reclaim` block) rebuilds one on
  load: neglect from the frozen attention stamp, the revolts in the window ending at the declaration, the
  saved desperation.
- **The council's log is cleared on rejoining**, so a later independence's panel lists only its own acts.
- **Petitions reach the player wherever they are.** `PetitionWatch` (in `city_reclaim.dart`) lets the flight
  view announce each new petition once as a toast (`simulation_view.dart`, a few lines). The colony on screen
  in city mode still says it through its own HUD.
- **The blockade's price is shown** (`blockadeNote`): on a standoff colony's delivery schedule and in its
  loyalty explainer, that starving it wins no loyalty, and that its loyalty × mood counts in the reputation
  that wins independent colonies home, with both figures. It is shown, not modelled further (see below).
- Tests: `test/colony/city_term_guard_test.dart` (8: each re-plat edit bound and unbound as a control, the
  plat after a refused edit identical to an untried one, the meltdown row, the flat builder's road), and in
  `city_reclaim_test.dart` the real-tick secessions, the fixed levy, decline, shown terms, the log, old
  saves, deliveries resuming (by terms and by petition, the grounded craft released), the blockade note and
  the petition watch.

**Deviations and open items.**
- "Demolition" is every act that tears a building down: the bulldozer, the meltdown, any flat-builder tool
  that clears a building, road or platform, and any plat edit whose re-cut would lose a built lot. On the
  plat, re-zoning a built lot is not refused (`setUse` leaves the building standing). Changing the road
  tool's lot frontage/depth re-cuts the whole plat outside the trial, as it always has (a pre-existing gap:
  that re-cut carries nothing).
- A petition is state and a warning on its colony, a notice in its queue, and a one-time toast in the flight
  view. There is no inbox that keeps it after the toast.
- Blockade as coercion is shown, not modelled: cutting a standoff colony's deliveries has no loyalty effect
  of its own (it raises none, since hunger leaves nobody content) and no reputation cost beyond what its
  falling mood already does to loyalty × mood. §6.3 says v1 models nothing beyond cancelling schedules.
- Desperation is still not eased by independence. Only the starving clause above stops a desperate
  colony from never petitioning.
- Force (§6.3) is out of scope; its row is present and disabled.

#### Integrated with terraforming phase 3 (2026-10-10)

Merged without a textual conflict. The governor never builds a terraforming tower, because every tower is
`group: 'env'`, outside `CitySim.isLifeSupport`, and has no power, garbage or deathcare reading the governor acts on
(pinned in `test/colony/phase3_cross_lane_seams_test.dart`). Placing a tower can't break the no-demolition term,
because `footprintFree` refuses any occupied cell. Reputation is measured before the city phase and the planetary
atmosphere phase runs after it, so the two don't interact within a tick. One item within this lane, not new with the
merge: a frame-budgeted (held) colony replays its ticks after the hand-out, so all of its held ticks see the latest
reputation, which was measured on its own state from before the replay. Hearts pressure builds over days, so the
lag is small, but it is not bit-identical to running inline.

## 8. Open questions for the user

**Phase 1 proceeds on the proposed answers to Q1–Q5** (2026-10-10, the user asked to start both plans).
Every number is in a tuning object, so the user can revise any of them without a redesign.

- **Q1 Negotiate currency.** Terms only (proposed), or add a player-wide purse so a colony can be bought
  back? A purse is a bigger change: today every colony has its own treasury.
- **Q2 Attention.** Should opening the colony's editor without acting count as attention? Proposed: no.
- **Q3 Timescales.** Is ~10 days' grace then ~40 days to secede from neglect alone (about 1.5 hours of
  play at 1×, less under warp) the right order? Misrule is about 10 days.
- **Q4 Government.** Should Autocracy and Monarchy resist longer (slower erosion, harsher revolts), or only
  through the existing `rebellionSensitivity`? Proposed: only through sensitivity, plus Autocracy keeps its
  garrison-style suppression in phase 4.
- **Q6 Standoff: ANSWERED 2026-10-10:** strike, emigration and withering, plus rebels seize the spaceport (§4.1).
- **Q7 The bar: ANSWERED 2026-10-10:** 90%, falling toward 0% with desperation (§3.4). Oxygen **always** counts; the real (terraformable) sky is a local source via `airO2` (§3.4, `terraforming.md` §3.4).
- **Q5 The flat sandbox** `CityBuilderScreen` (`NewCityScreen._found`, never in a world). Does loyalty apply
  there? Proposed: yes, but with no reputation route, since it is the only colony.
