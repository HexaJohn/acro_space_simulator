// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What each good costs to make on Earth once nobody has anything left to
/// learn: its MATURE cost, derived bottom-up from the recipes
/// (docs/plans/dynamic-markets.md §3 "Unit cost learns", phase 3).
///
/// Phase 2 calibrated every good's mature cost from the old hand-set Earth
/// price table: seed ÷ (1 + the premium left today). So rocket parts'
/// mature price was whatever $1,000/kg ÷ 5 came to, about eight times what
/// their inputs cost, and the Rocket Parts and Missile plants earned a rent
/// so large it saturated the corporate-tax safety ceiling for a decade by
/// construction. Nothing in the economy said why a rocket part costs that.
///
/// **Cost-plus.** Now a manufactured good's mature cost is what its
/// cheapest recipe costs to run on Earth, plus a normal margin:
///
///     mature(g) = (Σ inputs at Earth's mature prices
///                  + jobs × Earth's wage for each job's skill tier
///                  + energy at Earth's power price
///                  + capital recovery of the plant's build cost
///                  + an advanced plant's tooling recovery
///                  + a floor plant's freight fee and equipment wear)
///                 × (1 + [kNormalMargin]) ÷ output rate
///                + an advanced good's engineering hours per unit
///                  at the engineering wage, × (1 + [kNormalMargin])
///
/// The two advanced lines (`industrial_overhead.dart`) are the specialised
/// tooling a plant's firm finances in credits and the design, test and
/// certification hours each unit needs. Without them electronics, rocket
/// parts and missiles came out 16×, 40× and 190× under real-world; with
/// them they sit within ~5% of it on day 0 (×1.00, ×1.05, ×0.84).
///
/// which is exactly the colony cost solve (`local_prices.dart`) run on
/// Earth's facts with no import source, so the two can never disagree on
/// what a recipe costs. Inputs are themselves mature costs, so the margin
/// compounds along a chain as each stage earns its own.
///
/// **Raw and extracted goods** are not made by any recipe the game models
/// at Earth's scale: Earth's ore, water, food, air and gas come out of the
/// ground and the sky at world volume, for far less labour per kilogram
/// than a colony's starter mine or farm. They keep a documented
/// EXTRACTION-COST anchor ([kExtractionCostPerKg]), the cost of pulling
/// them out at that scale, which the cost-plus chain builds on.
///
/// Earth's price on day 0 is then this mature cost times one plus the
/// learning premium still left today (`learning.dart` [TechSeed.premiumToday]),
/// and it falls toward the mature cost as the world makes more.
///
/// The old `kEarthPricePerKg` table is no input to any of this. It survives
/// as a fixed WEIGHT (the joint-product split of a recipe's cost, the floor
/// reward cap's value measure) and as a sanity reference in the tests
/// (mature_cost_test.dart: derived against real-world).
///
/// Pure and deterministic: one fixed-point solve, computed once.
library;

import '../commodity.dart';
import 'commodity_mass.dart';
import 'economy_contracts.dart';
import 'local_prices.dart';

/// The normal margin a maker earns over its DIRECT cost in a mature,
/// competitive market: a third. The recipes cost only what a plant uses —
/// inputs, labour, energy, freight, wear and a build cost in ore — none of
/// the overheads (management, sales, R&D upkeep, the real capital stock)
/// that a real price also pays for, so the right figure is the GROSS
/// margin, not the operating one: manufacturing gross margins run 25-35%
/// of revenue (S&P 500 industrials ~30%), a markup of ~1/3 on direct cost.
/// It is what keeps a mature plant in business once the scarcity rent is
/// gone. (At an operating-margin 10% an Earth steel mill earned 9% on
/// revenue, and the half-empty first day of a just-opened live floor
/// pushed its firm into a layoff: economy_open_floor_test.dart.) Applied
/// to every manufactured good's recipe cost.
const double kNormalMargin = 1 / 3;

/// What pulling each raw good out of the ground or the sky costs on Earth,
/// credits per kg, at world scale. Costs, not prices: each is the figure a
/// producer breaks even at, the floor any price must cover.
const Map<String, double> kExtractionCostPerKg = {
  // Run-of-mine rock: blasting, loading and hauling, ~$40/t at a large
  // open pit (the colony's ore is crude low-grade rock, not concentrate).
  Commodity.ore: 0.04,
  // Pumping and treating municipal water, ~$2/m³.
  Commodity.water: 0.002,
  // Staple food grown, processed and packed at agricultural scale, ~$3/kg
  // (the farm-gate cost of grain is far less; this is food as shipped).
  Commodity.food: 3,
  // Air separation for breathing-grade oxygen, ~$0.20/kg (bulk industrial
  // oxygen is $0.10-0.30).
  Commodity.oxygen: 0.2,
  // Producing and liquefying natural gas, ~$0.30/kg (~$6/MMBtu plus
  // liquefaction).
  Commodity.fuel: 0.3,
  // Liquid oxygen from an air separation plant at the launch site,
  // ~$0.10/kg.
  Commodity.oxidizer: 0.1,
};

/// The raw goods: priced at their extraction cost, never from a recipe.
Set<String> get rawGoods => kExtractionCostPerKg.keys.toSet();

/// The economy Earth's world market runs under for its wage: a market
/// economy (the wage markup above subsistence is capitalism's 1.4).
const EconomyKind kWorldEconomy = EconomyKind.capitalism;

/// Earth's facts as the mature-cost solve needs them: Earth's air and sun,
/// neutral site yields, every recipe unlocked (a world population), mature
/// (no learning multiplier), every tier at its anchor wage (Earth's labour
/// pool is deep enough that no skill is scarce), and no import source at
/// all, so every manufactured price is its own recipe's.
MarketFacts earthMatureFacts() => MarketFacts(
  bodyId: 'earth',
  economy: kWorldEconomy,
  atmosphere: const {'N2': 0.78, 'O2': 0.21},
  surfacePressureKPa: 101.325,
  airDensity: 1,
  o2Harvestable: true,
  // Every unlock open: the world economy builds anything.
  population: 1 << 30,
  noEarthSource: marketGoods().toSet(),
);

/// The mature-cost solve, computed on first use.
final LocalMarket earthMatureMarket = solveLocalMarket(
  earthMatureFacts(),
  pinned: {
    for (final e in kExtractionCostPerKg.entries)
      e.key: e.value * kgPerUnit(e.key),
  },
  costMarkup: 1 + kNormalMargin,
);

/// Earth's mature cost of one unit of [good], credits; null for a good no
/// recipe makes and no anchor prices (waste, a test's synthetic good).
double? earthMatureCost(String good) {
  final p = earthMatureMarket.book.prices[good];
  return p != null && p > 0 && p.isFinite ? p : null;
}
