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
2. **Learning curves and invention.** Track Q per colony and for the world, with world knowledge
   slowly spilling over to colonies. Unit cost follows Wright's law, and Earth prices move with
   world learning. Invention points come from Earth's timeline, and colony research can invent a
   good early. *Built* (`economy/learning.dart`). Every existing good is invented by day 0 (the
   milestone unlocks are population gates, not dates); the mechanism is proven on synthetic goods.
   Rocket Parts and Missile plants still saturate the 30× tax ceiling over a decade (rent 188× and
   705× at year 10): the flat recipes' value added, not the ceiling, is what's left.
3. **Labour market.** Skill tiers per recipe, and skilled supply from population and education
   coverage. Wages for each tier are priced by supply and demand like any good; a shortage raises
   wages and starves low-paying plants of staff.
   *Built* (`economy/skill_tiers.dart`, `economy/labour_market.dart`, `economy/mature_cost.dart`).
   Four tiers (unskilled, skilled, technical, engineering) at 1×, 1.4×, 1.8×, 2.8× the cost of
   living; floors split by role (stations at their recipe's tier, handlers skilled, technicians
   technical). Supply is the labour force × a skill mix that drifts (half a game-year time
   constant) toward what school coverage and wage premiums aim it at; wages are a ratio to their
   anchor, stepped daily by the goods' tâtonnement (half the gap in 30-37 days), floored at the
   cost of living. Flat buildings are staffed first; floors bid for the rest (private firms by
   margin, state plants at the fixed government scale), each taking a balanced crew.
   Carry-over from phase 2: every manufactured good's mature cost is now derived bottom-up from
   its recipe (inputs at Earth's mature prices, tier wages, energy, capital recovery, freight and
   wear, a normal margin of a third over direct cost); raw goods keep a documented extraction
   cost. The Rocket Parts and Missile plants' raw tax is now 17× → 7× and 10× → 2× their workers'
   over a decade, no longer pinned at the 30× ceiling. Finding: the derived prices of
   electronics, rocket parts and missiles land 16×, 40× and 190× under real-world, because their
   flat recipes are far more productive per worker than the real trades; closing that is a recipe
   retune, not a price.
   *Follow-up, advanced overheads* (`economy/industrial_overhead.dart`, user said yes 2026-10-25).
   The Electronics, Rocket Parts, Missile and Arms plants carry a documented TOOLING capital in
   credits ($400M, $1.5B, $8B, $60M: clean rooms, test stands, ranges), recovered over ten
   game-years of nameplate, and ENGINEERING hours per unit (8 h a tray, 300 h a crate, 5,000 h a
   missile, 2 h a rifle, 0.1 h an ammo case) at the cheaper of the colony's and Earth's
   engineering wage (engineering is a traded service). The ore build cost stays the physical
   construction cost. The P&L books both lines on units shipped; they are overhead, not floor
   crew. Day-0 Earth prices are now ×1.00, ×1.05 and ×0.84 the real-world reference for
   electronics, rocket parts and missiles (guns ×0.80, ammo ×0.76). The recurring tooling and
   engineering are in the mature cost; the learning premium stays the non-recurring part, so
   nothing counts twice. An advanced plant's overhead engineers count as staff for the tax
   ceiling: Rocket Parts pays 19× → 8× and Missiles 12× → 3.8× their staff's tax over a decade.
4. **Entrepreneurs.** When a good's local margin stays high, an AI firm founds a plant for it on
   a site the build snap finds (`CitySim.snapSiteCentre`), within the colony's rules (economy
   type, ore, unlocks).
   *Built* (`economy/entrepreneurs.dart`, `city_entrepreneurs.dart`). Each day close scores every
   good a buildable floor plant makes by a new template plant's margin (revenue at today's price
   × the sell-through it could expect with its own output added, against tier wages, inputs,
   power, freight, wear and capital recovery), smoothed over a week. Twenty-one days above 40%
   (the normal margin is 25% of revenue) found a plant, at most one a month: a new firm
   ("Aldine Corp"), seed capital off-world in shadow credits (build cost + a quarter as cash), ore
   from colony stock only when it holds twice the cost, else imported at the ceiling. Gates: idle
   workers for half its jobs, spare power, half its inputs spare; a site from the build snap along
   the roads, never over a zoned or built lot. Socialism at a third of the rate, communism never;
   none while Industrial Licensing (a new law, off by default) is in force, or in a colony that
   is independent, occupied, Defiant, in Standoff or under a no-demolition term. Exit is the
   existing firm policy. Finding: an Earth colony's Refinery reads a 61% margin (its fuel sells
   at Earth's extraction cost, which its ore recipe undercuts), so an Earth colony with spare ore
   and workers will attract refineries.
5. **Inter-colony trade.** Each player colony is a source and destination for the others, linked
   by transport cost.
   *Built* (`economy/world_economy.dart`, `economy/inter_colony_trade.dart`, `city_trade.dart`).
   ONE world market (Earth's market plus the world clock and world output, `WorldTech`) owned by
   the `CityRepository`, which joins each colony as it is added; a lone colony keeps a private
   one and runs exactly as before. The world steps once per round of closes (every member closed,
   or one closed twice), summing every colony's Earth trade in colony-id order. Old saves: each
   colony's copy merges as it joins, the most advanced (highest world day) winning, ties to the
   first; the world is then saved once (`worldEconomy`) and colonies carry none. Every other
   colony with a working port is in the band: a source at its price + freight when it holds
   more than its reserve (30 days of its own use or half its store), a destination at its price −
   freight when it is short; same-body freight $2/kg. Flows are bookkeeping (option a): at its
   close a colony buys from the cheapest landed partner that beats its own and Earth's landed
   price, a fifth of its cover gap a day, capped by its store's room and by both ports' launch
   capacity (100 t a day per unit of a port's fuel draw); stocks move and both days' flows see
   it. Shadow money only: no transfer between treasuries. Two Martian colonies (a 100-person town
   whose farm falls behind, a granary) meet at $5.65 and $3.35 a kg of food by day 30, 4.3 t
   shipped; a Moon granary caps a Martian town's food at $358 landed (Earth's is $481).
   Follow-ups: real cargo flights (shuttle runs, `DeliverySchedule`), a capacity-aware band, and
   road links between same-body colonies. The game can already hold several colonies (the flight
   session founds one per site), so this runs live.
6. **UI.** A price chart per good ("why this price"), the labour market, invention news, and firm
   founding notices.

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

## 7. Decisions (user, 2026-10-14)

1. **Invention:** Earth's world timeline sets when a good first appears. Colony research can let a
   colony invent it earlier for itself.
2. **Learning:** both. Colony production builds local experience; world output drives Earth's
   price; world knowledge spills over to colonies slowly.
3. **Entrepreneurs:** yes. AI firms found plants when margins stay high (phase 4).
4. **Labour:** a full labour market now (phase 3), not a fixed premium.
5. **Price speed:** most goods close half the gap to equilibrium in about one in-game month (30
   colony days).
