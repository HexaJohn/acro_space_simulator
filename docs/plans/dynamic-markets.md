# Dynamic markets

Status: draft, 2026-10-14. Short on purpose: vision, model, phases, decisions.
Only the next phase gets a detailed spec, just before it is built. This is the economy plan
`factory-floors.md` §3 promised before its phase 5. It replaces that phase's price model.

## 1. Vision

No price is typed into a table. Every good's price in every market comes from supply against
demand, anchored by what it costs to make. What it costs to make falls as the world makes more of
it.

A new technology is ruinously expensive at first. The first rocket parts carry the specialised
machinery and the scarce skilled people who know how to build them. Each doubling of output makes
them cheaper. A colony that builds its own rocket-parts industry early earns monopoly rents while
the good is scarce. Those rents fade as plants multiply and the market fills. Being first pays;
being tenth pays normally.

User's words (2026-10-14): *"rare/high tech things cost a ton when they are first invented, but
get cheaper as more advanced technology is produced. It shouldn't be hard coded … it should be a
highly dynamic supply and demand system."*

## 2. Today (from the code)

- `earth_market.dart` `kEarthPricePerKg` is a hand-set Earth price per good (rocket parts
  $1,000/kg). Every colony's import ceiling and export floor derive from it.
- `local_prices.dart` `solveLocalPrices` runs once per colony day. It sets each price to local
  production cost × a scarcity factor, clamped between the export floor and the import ceiling.
  The price has no memory: each day is re-solved from scratch, so nothing trends.
- Unit cost uses fixed recipes from the `CityBuildingSpec` flat rates. Nothing learns.
- A firm's revenue is everything shipped × price, whether or not anyone wants the goods. A Missile
  Plant nobody buys from still books ~$600/s of value. That is why corporate tax needed the 4×
  cap (`city_economy.dart` `kCorporateTaxWorkerMultiple`).
- Off-world, a plant that is the only source of its good sets its price at its own cost. That is
  why off-world margins are ~0.1%.

## 3. Core model

**Markets.** Earth (the world market) plus each colony. Each market keeps, per good: a price, a
stock, and smoothed supply and demand flows (exponential, about 3 colony days). This state is
saved; prices have memory.

**Price moves by excess demand.** It updates once per colony day (tâtonnement):

    p ← p · exp( η · clamp( (D − S) / max(D, S, ε)  +  κ · (cover* − cover) / cover*, −1, 1 ) )

- *D, S*: the day's demand and supply flows.
- *cover*: days of stock at current demand; *cover\**: the target (~30 days).
- *η*: per-good speed. Bulk and perishable goods move fast; capital goods move slowly. *κ*
  weights the stock term.

Supply and demand set the price. Cost sets profitability.

**Arbitrage bounds.** A colony with a working spaceport can import at the source price plus
transport (Δv, as today) and export at the destination price minus transport. Its price can't
leave that band for long: arbitrage pulls it back at a fixed rate per day. A colony with no
working port floats free, so a siege or a closed port really does send prices soaring.

**Unit cost learns (Wright's law).**

    unitCost(g) = matureCost(g) · (1 + firstUnitPremium(g) · (Q(g) / Q0(g))^(−b(g)))

- `matureCost`: today's cost model (inputs, energy, wages, capital).
- `Q`: cumulative production in the scope that does the learning (§7 Q2).
- `b = −log2(1 − LR)`, with learning rate LR around 10–25% per doubling, by good class.
- `firstUnitPremium`: tooling, R&D and skilled-labour scarcity at invention. Large for advanced
  goods, about 0 for water and oxygen.

A good is expensive when new and approaches its mature cost as the world makes more. Nothing about
it is a hand-set price.

**Earth is a market like any other.** Its prices come from Earth's facts (cheap energy, a
breathable atmosphere, huge stocks) plus world cumulative output, which grows every game day from
Earth's own industry.
- Mature goods sit near cost and barely move.
- A newly invented good starts dear and slides down its curve over game years.
- The per-good seeds (current `Q`, LR, premium, `Q0`) are world state that evolves. They are not
  prices.

**Invention.** Each advanced good has an invention point. Before it, the good doesn't exist:
there's no import source and no local recipe. After it, it's at the expensive end of its curve.
The trigger is open (§7 Q1).

**Skilled labour.** A recipe declares a skill tier, and wages for that tier carry a premium. In
phase 2 the premium becomes a labour market: skilled supply (education coverage, population)
against the skilled jobs posted, priced like any other good.

**Consequences.**
- *Revenue counts only what's sold.* Supply beyond demand piles up in stock, the price falls, and
  stock beyond cover\* pushes it down harder. A Missile Plant with no buyer earns little.
- *Corporate tax needs no cap.* Rents are high while a good is scarce and new, and shrink as
  supply grows. A generous safety ceiling stays, with a smooth curve, against runaway bugs.
- *Off-world margins fix themselves.* Price is set by supply and demand, not pinned to the local
  plant's cost, so a colony short of steel pays well above cost and its mill is healthy.

## 4. Phases

1. **Market core (headless).** Market state per good, a daily tâtonnement with arbitrage bounds,
   smoothed flows, and saving. Revenue only on sales. Earth as a market seeded from today's prices
   once, then free to move. Replace the tax cap with a soft safety ceiling. Retune the plant
   health tests to the new dynamics.
2. **Learning curves and invention.** Track Q per scope. Unit cost follows Wright's law, and Earth
   prices move with world learning. Add invention points and the first-unit premium.
3. **Skilled labour market.** Skill tiers per recipe, a skilled supply from education, and a
   priced premium.
4. **Inter-colony trade.** Each player colony is a source and destination for the others, linked
   by transport cost.
5. **UI.** A price chart per good ("why this price": supply, demand, cover, curve position,
   bounds), invention news, and a plant's margin trend.

## 5. Invariants

- Deterministic: no RNG, fixed daily cadence, sorted iteration.
- Prices are always positive and finite; the per-day change is clamped.
- Money is still shadow, except corporate tax, subsidies and deficits (factory-floors decision
  Q8).
- Old saves load: a market missing from a save is seeded from today's model.

## 6. Risks

- **Oscillation** (cobweb cycles between price and capacity). Mitigation: damped η, smoothed
  flows, and a cap on daily change. Test with a step-change scenario.
- **Unbounded inflation in a closed colony.** Mitigation: a price ceiling at a large multiple of
  unit cost, since the colony would build the thing itself before paying more.
- **Tuning load.** Mitigation: per-good-class parameters (bulk, life support, industrial,
  advanced), not per good.

## 7. Decisions for the user

1. **What triggers an invention?** *Rec:* Earth's world timeline sets when a good first appears.
   Colony research (the unused `research` accumulator) can let a colony invent it EARLIER for
   itself, which makes being first a real strategy.
2. **Who learns?** *Rec:* both. Colony production builds local experience, which lowers that
   colony's unit cost. World experience lowers Earth's price and so the import ceiling. Knowledge
   spills over slowly, so local experience gets a fraction of world progress.
3. **Do new firms appear on their own when margins are high?** *Rec:* not yet. In phase 1 only
   your existing plants expand or contract. AI entrepreneurs founding plants is a later phase.
4. **Skilled labour:** a fixed premium per skill tier now, and a full labour market in phase 3
   (rec)?
5. **Price speed:** the default is about a week of game days for most goods to cover half the gap
   to equilibrium. Faster feels lively but swings; slower feels stable but sluggish.
