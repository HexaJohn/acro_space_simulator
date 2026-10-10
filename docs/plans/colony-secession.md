# Colony loyalty and secession

Status: draft for review, 2026-10-10. Baseline `dev` at `34a83f7`. Paths are relative to the repo root.

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

### 3.4 Stages (with hysteresis)

| Stage | Loyalty | Effect |
|---|---|---|
| Loyal | ≥ 0.6 | none |
| Restless | < 0.6 (back above 0.65) | status notification + HUD chip; the colony starts **self-governing**: laws auto-vote whatever the government, and an over-high tax is pulled down toward what the mood bears (a tax revolt) |
| Defiant | < 0.3 (back above 0.35) | **strikes**: `restThrottle` × 0.7 and tax collection halved (non-payment); a louder warning naming the causes (neglect, unrest, revolts) |
| Seceded | ≤ 0, or 3 revolts within 15 days | `allegiance = independent` (§4) |

The causes shown are the actual terms of the drift equation, so the warning says *why*, for example "no orders
for 34 days" or "rebellion 0.82: crime, inequality".

## 4. Independence

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

## 7. Phases

1. **Loyalty**: clock, attendance, the drift equation, stages and their effects, warnings in the status list
   and the HUD (including the revolt toasts that are missing today), and saving the political state.
   Domain plus HUD. Tests: neglect alone, misrule alone, recovery, hysteresis, and the save round-trip.
2. **Independence**: the control gate across every call site plus the sweep test, the independent governor,
   and the independent HUD state.
3. **Negotiate + win hearts**: terms, the binding-term gate, reputation, petitions.
4. **Force**: garrison/projection/resistance, occupation.

Each phase is one commit or a few, shipped behind nothing, since the first phase already only warns.

## 8. Open questions for the user

- **Q1 Negotiate currency.** Terms only (proposed), or add a player-wide purse so a colony can be bought
  back? A purse is a bigger change: today every colony has its own treasury.
- **Q2 Attention.** Should opening the colony's editor without acting count as attention? Proposed: no.
- **Q3 Timescales.** Is ~10 days' grace then ~40 days to secede from neglect alone (about 1.5 hours of
  play at 1×, less under warp) the right order? Misrule is about 10 days.
- **Q4 Government.** Should Autocracy and Monarchy resist longer (slower erosion, harsher revolts), or only
  through the existing `rebellionSensitivity`? Proposed: only through sensitivity, plus Autocracy keeps its
  garrison-style suppression in phase 4.
- **Q5 The flat sandbox** `CityBuilderScreen` (`NewCityScreen._found`, never in a world). Does loyalty apply
  there? Proposed: yes, but with no reputation route, since it is the only colony.
