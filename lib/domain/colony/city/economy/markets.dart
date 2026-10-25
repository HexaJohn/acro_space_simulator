// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Markets with memory: the price of every good in every market moves by
/// supply against demand, once a colony day (docs/plans/dynamic-markets.md
/// §3, phase 1 "Market core").
///
/// Before this, `local_prices.dart` re-solved each price from scratch every
/// day as local cost × scarcity, so nothing trended, a plant that was the
/// only source of its good set its own price at its own cost (off-world
/// margins of ~0.1%), and a plant's revenue counted everything it shipped
/// whether anyone wanted it or not. The solve still runs; it now supplies
/// the COST ANCHOR, the trade band and the wage. The price itself is state.
///
/// **State.** A [Market] (Earth, or one colony) keeps, per good, a
/// [GoodMarket]: the price, the stock, demand and supply flows smoothed
/// exponentially over [kFlowSmoothingDays], and the cost anchor the price is
/// measured against. Saved with the colony; a market missing from a save is
/// SEEDED from today's model ([seedGood]): the first price is exactly the
/// price the old solve gives, so loading an old save changes nothing on the
/// day it loads.
///
/// **The daily step** ([closeGoodDay]) is the tâtonnement of plan §3:
///
///     p ← p · exp( η · clamp( gap + cover, −1, 1 ) )
///
/// - `gap = (D − S) / max(D, S)` ([flowGap]) with D and S the smoothed flows
///   evaluated AT THE CURRENT PRICE through constant elasticities around the
///   anchor: `D·(p/a)^−εd`, `S·(p/a)^εs`. In phase 1 the sim's flows are
///   physical and do not answer price at all (colonists eat what they eat, a
///   plant runs at its rate); without the elasticities the step would have no
///   equilibrium to approach and every imbalance would drive the price to a
///   bound. They stand in for the response phases 3-4 build for real (a
///   labour market, entrepreneurs founding plants).
/// - `cover` ([coverSignal]): days of stock at current demand against the
///   target [kTargetCoverDays]; an empty shelf bids the price up, a pile
///   pushes it down.
///
/// **η and the half-life (user decision §7.5: most goods close half the gap
/// to equilibrium in about one in-game month).** Near equilibrium
/// `D·q^−εd = S·q^εs` (q = p/a), and the derivative of the gap in ln p is
/// exactly −(εd + εs) = −ε. One daily step therefore multiplies the log
/// distance to equilibrium by (1 − η·ε). Closing half of it in T days means
/// (1 − η·ε)^T = ½. But the market sees a change in demand only through the
/// flow smoothing, which delays it by about its time constant
/// τ = [kFlowSmoothingDays]; a player watching from the day demand changed
/// sees T + τ. So for a class half-life H as the player sees it, T = H − τ:
///
///     η = (1 − 2^(−1/(H − τ))) / ε
///
/// [GoodClassParams.eta] computes exactly this from the class's half-life
/// and elasticities, so the tuning knob is the half-life the user stated,
/// not an opaque speed. Measured from a +25% demand step
/// (markets_dynamics_test) half the gap closes in H to H + 3 days: the
/// bounded gap pushes slightly under its log-linear tangent (0.2 for a
/// 1.25× gap, not ln 1.25 = 0.22), a day or two. The step is stable (no
/// cobweb) whenever η·ε < 1; every class here is below 0.05.
///
/// **Arbitrage.** A colony with a working port ([MarketFacts.canExport]),
/// or one on Earth that trades on its own world, can import at the source
/// price plus transport and export at the destination price less transport
/// (`local_prices.dart` derives both). Each day [kArbitragePullPerDay] of
/// the log distance outside that band is traded away. With no working port
/// the price floats free: a siege or a closed port really does send prices
/// soaring, at the class's η a day.
///
/// **Bounds.** The per-day move is clamped to [kMaxDailyLogStep]; a price
/// never exceeds [kCostCeilingMultiple] × the local unit cost (a colony
/// would build the thing itself first) nor falls below [kPriceFloorFraction]
/// of its anchor; a non-finite result resets to the anchor. Prices are
/// always positive and finite. The bounds outrank the daily clamp: when the
/// local cost collapses (a cheaper recipe unlocks, the wage falls) the cost
/// ceiling brings the price down with it at once.
///
/// The half-life above holds near a BALANCED equilibrium. Far from one the
/// bounded gap (D − S)/max(D, S) pushes less than its log-linear tangent
/// (a 2× gap reads 0.5, not ln 2), and with a standing stock signal the
/// equilibrium sits where the gap answers it, where its slope is shallower
/// (see [kCoverShortWeight]); both make the approach slower, never faster,
/// so neither can overshoot.
///
/// **Sell-through** ([sellThroughOf]): the share of a good's supply that
/// found a buyer, so a plant's revenue counts only what sold. A good that
/// can be exported at a positive floor always sells.
///
/// Pure and deterministic: no RNG, no clock but the daily close it is handed,
/// every map a [SplayTreeMap] walked in key order.
library;

import 'dart:collection';
import 'dart:math' as math;

import '../commodity.dart';
import 'commodity_mass.dart';
import 'earth_market.dart';
import 'economy_clock.dart';
import 'economy_contracts.dart';
import 'local_prices.dart';

// ---- good classes ------------------------------------------------------------

/// How a good's market behaves (plan §6 "Tuning load": parameters per class,
/// not per good).
enum GoodClass {
  /// What people eat, drink and breathe: demand barely answers price, and
  /// shelves turn over in days, so prices move fastest.
  lifeSupport,

  /// Raw and semi-raw bulk: ore, propellants, pig iron, slag.
  bulk,

  /// Plate, tube, billet: the month-scale default.
  industrial,

  /// Electronics, aerospace, arms and pharmaceuticals: long contracts and
  /// slow capacity, so prices move slowest.
  advanced,
}

/// The class of [commodity]; a good no rule names is [GoodClass.industrial],
/// the month-scale default.
GoodClass goodClassOf(String commodity) => switch (commodity) {
      Commodity.food ||
      Commodity.water ||
      Commodity.oxygen ||
      Commodity.rations =>
        GoodClass.lifeSupport,
      Commodity.ore ||
      Commodity.fuel ||
      Commodity.oxidizer ||
      'pigIron' ||
      'slag' =>
        GoodClass.bulk,
      Commodity.electronics ||
      Commodity.rocketParts ||
      Commodity.guns ||
      Commodity.ammo ||
      Commodity.missiles ||
      Commodity.medicine =>
        GoodClass.advanced,
      _ => GoodClass.industrial,
    };

/// One class's market parameters.
class GoodClassParams {
  const GoodClassParams({
    required this.halfLifeDays,
    required this.demandElasticity,
    required this.supplyElasticity,
    required this.worldFlowKgPerS,
  });

  /// Colony days, counted from a change in demand or supply, to close half
  /// the log distance to the new equilibrium (user decision §7.5: about a
  /// month for most goods).
  final double halfLifeDays;

  /// −d ln D / d ln p and d ln S / d ln p around the anchor.
  final double demandElasticity;
  final double supplyElasticity;

  /// World trade in a good of this class, kg per colony second: Earth's
  /// market depth ([closeEarthDay]). A colony second is 1/120 of a day, so a
  /// game-year is 43,830 of them.
  final double worldFlowKgPerS;

  /// ε = εd + εs: how hard the flow gap pushes back per unit of ln p.
  double get elasticity => demandElasticity + supplyElasticity;

  /// The step's own half-life, days: [halfLifeDays] less the flow
  /// smoothing's delay τ = [kFlowSmoothingDays].
  double get stepHalfLifeDays => halfLifeDays - kFlowSmoothingDays;

  /// The daily speed that closes half the gap in [halfLifeDays] as seen from
  /// the change: (1 − 2^(−1/(H − τ))) / ε (see the library doc for the
  /// derivation).
  double get eta =>
      (1 - math.pow(0.5, 1 / stepHalfLifeDays).toDouble()) / elasticity;
}

/// Every class's parameters.
///
/// Half-lives (user: "most goods close half the gap … in about one in-game
/// month", bulk and life support faster, capital goods slower but still
/// month-scale): 20, 25, 30 and 40 days.
///
/// Elasticities, total ε: life support 0.5 (εd 0.2: food and air are bought
/// whatever they cost; εs 0.3), bulk 1.0 and industrial 1.0 (the textbook
/// unit-elastic pair, 0.5 each), advanced 1.5 (0.75 each: a dear part is
/// designed out and a cheap one bought in volume). A lower ε means a given
/// imbalance moves the price further: doubling demand for food at fixed
/// supply raises its equilibrium price 2^(1/0.5) = 4×, steel's 2×.
///
/// So, with τ = 3, η: life support (1 − 2^(−1/17))/0.5 = 0.0799 a day; bulk
/// (1 − 2^(−1/22))/1 = 0.0310; industrial (1 − 2^(−1/27))/1 = 0.0253;
/// advanced (1 − 2^(−1/37))/1.5 = 0.0124. The most a price can move by the
/// step alone is η a day (the clamped signal is ±1): 8%, 3.1%, 2.5%, 1.2%;
/// η·ε is at most 0.04, far inside the stable range.
///
/// World flows (Earth's depth), kg per colony second (a game-year is 43,830
/// colony seconds): life support 1e8 (world food is ~4e12 kg a year, ~9e7);
/// bulk 1e7 (LNG ~4e11 kg/yr, ~9e6; ore far more); industrial 1e7 (steel
/// ~1.9e12 kg/yr is ~4e7, tube and billet less); advanced 200 (world
/// aerospace and munitions hardware is thousands of tonnes a year, ~8,800 t
/// at this figure). So a colony's bulk exports are a drop in Earth's sea,
/// but one Missile Plant (150 kg/s) or Rocket Parts plant (40 kg/s) moves
/// the world price of its good, as it should.
const Map<GoodClass, GoodClassParams> kGoodClassParams = {
  GoodClass.lifeSupport: GoodClassParams(
      halfLifeDays: 20,
      demandElasticity: 0.2,
      supplyElasticity: 0.3,
      worldFlowKgPerS: 1e8),
  GoodClass.bulk: GoodClassParams(
      halfLifeDays: 25,
      demandElasticity: 0.5,
      supplyElasticity: 0.5,
      worldFlowKgPerS: 1e7),
  GoodClass.industrial: GoodClassParams(
      halfLifeDays: 30,
      demandElasticity: 0.5,
      supplyElasticity: 0.5,
      worldFlowKgPerS: 1e7),
  GoodClass.advanced: GoodClassParams(
      halfLifeDays: 40,
      demandElasticity: 0.75,
      supplyElasticity: 0.75,
      worldFlowKgPerS: 200),
};

/// [commodity]'s class parameters.
GoodClassParams paramsOf(String commodity) =>
    kGoodClassParams[goodClassOf(commodity)]!;

// ---- tuning --------------------------------------------------------------------

/// Time constant of the smoothed demand and supply flows, colony days (plan
/// §3: "exponential, about 3 colony days"). Long enough that one day of
/// brownout or a freighter's lump doesn't read as a shift in the market,
/// short against the month-scale price half-life so it barely slows it.
const double kFlowSmoothingDays = 3;

/// Weight of an EMPTY shelf (cover below target) in the price signal: an
/// empty shelf with supply matching demand pushes like half an all-or-
/// nothing flow gap. Half, not one: a colony whose consumers take every
/// unit as it is made (the normal state of a plant's customer) is missing a
/// buffer, not a supply, and at full weight its bid would never stop
/// rising. At ½ it settles where the flow gap answers it, q^−ε − 1 = −½:
/// 2^(1/ε) above the anchor, ×2 for steel, ×4 for food (famine prices), and
/// a standing signal slows the approach to that point by the same ½ (the
/// gap's slope there is −ε·q^−ε).
const double kCoverShortWeight = 0.5;

/// Weight of a PILE (cover above target) in the price signal: stock on hand
/// stands in for supply one for one, so a pile two targets deep (the signal
/// saturates at −1) fully offsets demand with no local supply at all. Under
/// one, a colony drawing on years of stockpile with no plant would bid the
/// price up as if it were running dry.
const double kCoverGlutWeight = 1.0;

/// Flow (units/s) below which a market reads as idle on that side.
const double kFlowEps = 1e-9;

/// Share of the log distance outside the trade band that arbitrage closes
/// each day: half. A port lands cargo every few days and traders price
/// against what is inbound, so a price out of band is mostly back within a
/// few days; with the step's own push (at most η a day) a price held
/// against a bound settles at most one push, ≤ 8%, past it.
const double kArbitragePullPerDay = 0.5;

/// Largest move of ln p in one day, everything included: ln 1.25. Never
/// binding for the step alone (η ≤ 0.08); it bounds arbitrage's pull back
/// from far out of band, so a port reopening after a siege brings prices
/// down over a week of landings, not in one night.
const double kMaxDailyLogStep = 0.22314355131420976; // ln 1.25

/// Most a price may reach, as a multiple of the local unit cost (plan §6
/// "Unbounded inflation in a closed colony"). At 10× a plant built to make
/// the good pays back its build cost in weeks, so a colony would found one
/// long before paying more (phase 4's entrepreneurs do exactly that). For a
/// good with no local recipe the multiple is of its anchor (what landing it
/// costs).
const double kCostCeilingMultiple = 10;

/// Least a price may fall to, as a share of its anchor: 1%, scrap value.
/// A good nobody wants decays toward it at η a day, a month to halve, and
/// stays positive however long nobody buys.
const double kPriceFloorFraction = 0.01;

/// Earth's market id: the world market every colony can trade with
/// (`CelestialBody.id` of Earth).
const String kEarthMarketId = 'earth';

// ---- state -------------------------------------------------------------------

/// One good in one market.
class GoodMarket {
  GoodMarket({
    required this.price,
    required this.anchor,
    this.stock = 0,
    this.demandPerS = 0,
    this.supplyPerS = 0,
  });

  /// Credits per unit.
  double price;

  /// The cost anchor the elasticities are measured from, credits per unit:
  /// the local unit cost (held into the trade band where trade works) for a
  /// colony; for Earth its point on the world's learning curve
  /// (`learning.dart` [applyWorldTech]), the seed on day 0.
  double anchor;

  /// Units held at the last close (a colony's `CitySim.stock`).
  double stock;

  /// Smoothed flows, units per colony second.
  double demandPerS;
  double supplyPerS;

  Map<String, Object?> toJson() => {
        'p': price,
        'a': anchor,
        if (stock != 0) 's': stock,
        if (demandPerS != 0) 'd': demandPerS,
        if (supplyPerS != 0) 'u': supplyPerS,
      };

  static GoodMarket fromJson(Map<String, Object?> j) {
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    return GoodMarket(
      price: d('p'),
      anchor: d('a'),
      stock: d('s'),
      demandPerS: d('d'),
      supplyPerS: d('u'),
    );
  }
}

/// One market: every good it trades.
class Market {
  final SplayTreeMap<String, GoodMarket> goods = SplayTreeMap();

  bool get isEmpty => goods.isEmpty;

  /// Price of [commodity]; null when this market doesn't trade it.
  double? priceOf(String commodity) => goods[commodity]?.price;

  /// Every price, in key order.
  Map<String, double> get prices =>
      {for (final e in goods.entries) e.key: e.value.price};

  Map<String, Object?> toJson() =>
      {for (final e in goods.entries) e.key: e.value.toJson()};

  /// A market restored from [j]; null gives an empty one (seeded later).
  static Market fromJson(Map<String, Object?>? j) {
    final m = Market();
    if (j == null) return m;
    for (final k in (j.keys.toList()..sort())) {
      final v = j[k];
      if (v is Map) {
        final g = GoodMarket.fromJson(v.cast<String, Object?>());
        // A corrupt entry is dropped and re-seeded, never traded at 0.
        if (g.price > 0 && g.price.isFinite && g.anchor > 0) m.goods[k] = g;
      }
    }
    return m;
  }
}

/// What one day brought a good's market: the day's own flows, stock and the
/// bounds the cost model and trade set.
class GoodDay {
  const GoodDay({
    required this.demandPerS,
    required this.supplyPerS,
    required this.anchor,
    this.stock,
    this.unitCost,
    this.importCeiling = double.infinity,
    this.exportFloor = 0,
    this.arbitrage = false,
  });

  /// The day's flows, units per colony second (not yet smoothed).
  final double demandPerS;
  final double supplyPerS;

  /// The cost anchor; see [GoodMarket.anchor].
  final double anchor;

  /// Units held; null turns the cover term off (Earth: its stocks sit at
  /// target, the world's warehouses being far deeper than any colony).
  final double? stock;

  /// Local unit cost, the base of [kCostCeilingMultiple]; null = [anchor].
  final double? unitCost;

  /// The trade band, enforced only when [arbitrage].
  final double importCeiling;
  final double exportFloor;
  final bool arbitrage;
}

// ---- the daily step ------------------------------------------------------------

/// Per-close weight of the day's flows in the smoothed ones:
/// 1 − e^(−1/[kFlowSmoothingDays]).
double get flowSmoothingWeight => 1 - math.exp(-1 / kFlowSmoothingDays);

/// A good's market on the day it is first traded: the price the old model
/// gives ([price]), flows as the day found them (no lag to wind up), and the
/// day's stock and anchor. A non-positive [price] starts at the anchor.
GoodMarket seedGood(double price, GoodDay day) => GoodMarket(
      price: price > 0 && price.isFinite ? price : day.anchor,
      anchor: day.anchor,
      stock: day.stock ?? 0,
      demandPerS: day.demandPerS,
      supplyPerS: day.supplyPerS,
    );

/// The flow gap at price ratio [q] = p / anchor: (D' − S') / max(D', S'),
/// with D' = [demand]·q^−εd and S' = [supply]·q^εs. In [−1, 1]; 0 when the
/// market is idle.
double flowGap(double demand, double supply, double q, GoodClassParams p) {
  final dEff = demand * math.pow(q, -p.demandElasticity).toDouble();
  final sEff = supply * math.pow(q, p.supplyElasticity).toDouble();
  final scale = math.max(dEff, sEff);
  if (!(scale > kFlowEps)) return 0;
  return (dEff - sEff) / scale;
}

/// The stock signal: (cover* − cover) / cover*, clamped to [−1, 1], times
/// [kCoverGlutWeight] when long, and when short times [kCoverShortWeight]
/// and demand's share of the flow, min(1, D / S). With no demand, any stock
/// is a glut (−1 × weight) and none is no signal.
///
/// Why the share: cover is stock over demand, so as demand dies away an
/// empty shelf reads as ever fewer days of cover, a deepening shortage, at
/// the very moment nobody wants the good. An empty shelf is a shortage only
/// as far as demand is what the flow is made of: in full when nothing is
/// supplied or demand matches supply (no buffer), hardly at all when
/// supply dwarfs demand (the shelf is empty because the goods went
/// somewhere other than a buyer).
double coverSignal(double stock, double demandPerS, [double supplyPerS = 0]) {
  double g;
  if (demandPerS > kFlowEps) {
    final coverDays = stock / (demandPerS * kColonyDaySec);
    g = ((kTargetCoverDays - coverDays) / kTargetCoverDays).clamp(-1.0, 1.0);
  } else {
    g = stock > kFlowEps ? -1.0 : 0.0;
  }
  if (g < 0) return kCoverGlutWeight * g;
  final share =
      supplyPerS > kFlowEps ? math.min(1.0, demandPerS / supplyPerS) : 1.0;
  return kCoverShortWeight * g * share;
}

/// Closes one day of [m] with [day]'s facts: smooths the flows, takes the
/// stock and anchor, steps the price (tâtonnement), lets arbitrage pull it
/// toward the band, and applies the bounds. See the library doc.
void closeGoodDay(GoodMarket m, GoodDay day, GoodClassParams p) {
  final w = flowSmoothingWeight;
  m.demandPerS += (day.demandPerS - m.demandPerS) * w;
  m.supplyPerS += (day.supplyPerS - m.supplyPerS) * w;
  final stock = day.stock;
  if (stock != null) m.stock = stock;
  if (day.anchor > 0 && day.anchor.isFinite) m.anchor = day.anchor;
  final anchor = m.anchor;
  if (!(anchor > 0) || !anchor.isFinite) return; // nothing to price against
  // A corrupt price restarts at the anchor rather than stepping from NaN.
  if (!(m.price > 0) || !m.price.isFinite) m.price = anchor;

  final before = math.log(m.price);
  var signal = flowGap(m.demandPerS, m.supplyPerS, m.price / anchor, p);
  if (stock != null) {
    signal += coverSignal(m.stock, m.demandPerS, m.supplyPerS);
  }
  var ln = before + p.eta * signal.clamp(-1.0, 1.0);

  var upper = math.log(kCostCeilingMultiple * (day.unitCost ?? anchor));
  if (day.arbitrage) {
    if (day.importCeiling.isFinite && day.importCeiling > 0) {
      final hi = math.log(day.importCeiling);
      if (ln > hi) ln -= kArbitragePullPerDay * (ln - hi);
    }
    if (day.exportFloor > 0) {
      final lo = math.log(day.exportFloor);
      if (ln < lo) ln += kArbitragePullPerDay * (lo - ln);
      // A buyer at the floor pays it, whatever it costs to make here.
      upper = math.max(upper, lo);
    }
  }
  ln = ln.clamp(before - kMaxDailyLogStep, before + kMaxDailyLogStep);
  final lower = math.log(kPriceFloorFraction * anchor);
  if (upper.isFinite && lower < upper) ln = ln.clamp(lower, upper);
  final next = math.exp(ln);
  m.price = next.isFinite && next > 0 ? next : anchor;
}

/// Share of [m]'s supply that found a buyer: demand over supply, at most
/// one; one when the good can be exported ([exportable]: a working trade
/// route with a positive floor — the world buys whatever lands at its price)
/// or nothing is supplied.
double sellThroughOf(GoodMarket m, {required bool exportable}) {
  if (exportable || !(m.supplyPerS > kFlowEps)) return 1;
  return math.min(1.0, m.demandPerS / m.supplyPerS);
}

// ---- Earth -----------------------------------------------------------------------

/// Earth's depth in [commodity], units per colony second.
double worldFlowPerS(String commodity) {
  final kg = kgPerUnit(commodity);
  return kg > 0 ? paramsOf(commodity).worldFlowKgPerS / kg : 0;
}

/// Earth's market on the day the world economy starts: every tradeable good
/// at its `kEarthPricePerKg` seed, which is also its cost anchor, with
/// world demand and supply balanced at [worldFlowPerS].
///
/// This is the ONLY place the seed table is read as a price. Afterwards
/// Earth's prices are this market's state and move with the world's supply
/// and demand ([closeEarthDay]).
Market seedEarthMarket() {
  final m = Market();
  for (final c in marketGoods()) {
    if (!isShippable(c)) continue;
    final p = earthPrice(c);
    if (!(p > 0)) continue;
    final w = worldFlowPerS(c);
    m.goods[c] = GoodMarket(
        price: p, anchor: p, stock: 0, demandPerS: w, supplyPerS: w);
  }
  return m;
}

/// Closes one day of Earth's market: world demand is Earth's depth plus
/// what colonies bought from it ([importsPerS], units/s), world supply its
/// depth plus what they sold it ([exportsPerS]). No stock term (Earth's
/// stocks sit at target) and no trade band (Earth IS the band); the
/// elasticities around the anchor make it revert to its cost anchor at the
/// class half-life once the colony trade stops. The anchors themselves move
/// down Wright's learning curve as the world makes more (`learning.dart`
/// [applyWorldTech], called first by the daily close).
void closeEarthDay(
  Market earth, {
  Map<String, double> importsPerS = const {},
  Map<String, double> exportsPerS = const {},
}) {
  for (final e in earth.goods.entries) {
    final c = e.key;
    final w = worldFlowPerS(c);
    closeGoodDay(
      e.value,
      GoodDay(
        demandPerS: w + (importsPerS[c] ?? 0),
        supplyPerS: w + (exportsPerS[c] ?? 0),
        anchor: e.value.anchor,
      ),
      paramsOf(c),
    );
  }
}

/// Earth's live price of mixed methalox propellant per kg: its fuel and
/// oxidizer blended at [kMethaloxOxidizerToFuel]. Null when [earth] trades
/// neither (the transport model then falls back to the seed).
double? earthPropellantPerKgIn(Market earth) {
  final fuel = earth.priceOf(Commodity.fuel);
  final ox = earth.priceOf(Commodity.oxidizer);
  if (fuel == null || ox == null) return null;
  final fuelKg = fuel / kgPerUnit(Commodity.fuel);
  final oxKg = ox / kgPerUnit(Commodity.oxidizer);
  return (fuelKg + oxKg * kMethaloxOxidizerToFuel) /
      (1 + kMethaloxOxidizerToFuel);
}

// ---- a colony ----------------------------------------------------------------------

/// Whether [f]'s colony can trade at its band: a working spaceport, or
/// standing on Earth, whose world market it reaches by road.
bool tradeOpen(MarketFacts f) => f.canExport || f.bodyId == kEarthMarketId;

/// What a colony's daily close produced.
class ColonyClose {
  const ColonyClose({
    required this.book,
    required this.sellThrough,
    required this.exportsPerS,
  });

  /// The day's prices (dynamic for every traded good, the solve's for the
  /// rest), with the solve's wage, power price and band.
  final PriceBook book;

  /// Per good, the share of supply that sold ([sellThroughOf]).
  final Map<String, double> sellThrough;

  /// Per good, the day's surplus sold to Earth, units/s (Earth's supply).
  final Map<String, double> exportsPerS;
}

/// Closes one day of [colony]'s market from today's cost solve [solved] and
/// [facts] (the day's flows and stock), seeding any good it doesn't trade
/// yet at the solve's price. [localImportsPerS] are the day's imports, which
/// [facts]' supply counts too but which are not the colony's to export.
///
/// Per good:
/// - the anchor is the local unit cost, held into the band when trade is
///   open; a good with no local recipe anchors on the solve's price (what
///   landing it costs, or its intermediate basis);
/// - goods with no positive, finite anchor (waste, compute, anything with
///   neither recipe nor source) keep the solve's price and have no market.
ColonyClose closeColonyMarket(
  Market colony,
  LocalMarket solved,
  MarketFacts facts, {
  Map<String, double> localImportsPerS = const {},
}) {
  final book = solved.book;
  final open = tradeOpen(facts);
  final prices = <String, double>{...book.prices};
  final sell = SplayTreeMap<String, double>();
  final exports = SplayTreeMap<String, double>();
  for (final c in (book.prices.keys.toList()..sort())) {
    if (!isShippable(c)) continue;
    final hi = book.importCeiling[c] ?? double.infinity;
    final lo = book.exportFloor[c] ?? 0.0;
    final cost = solved.localCost[c];
    final double anchor;
    if (cost != null && cost > 0) {
      anchor = open ? cost.clamp(lo, hi).toDouble() : cost;
    } else {
      anchor = book.prices[c]!;
    }
    if (!(anchor > 0) || !anchor.isFinite) {
      colony.goods.remove(c);
      continue;
    }
    final demand = facts.demandPerS[c] ?? 0.0;
    final supply = facts.supplyPerS[c] ?? 0.0;
    final day = GoodDay(
      demandPerS: demand,
      supplyPerS: supply,
      stock: facts.stock[c] ?? 0.0,
      anchor: anchor,
      unitCost: cost != null && cost > 0 ? cost : null,
      importCeiling: hi,
      exportFloor: lo,
      arbitrage: open,
    );
    final had = colony.goods[c];
    final GoodMarket m;
    if (had == null) {
      m = seedGood(book.prices[c]!, day);
      colony.goods[c] = m;
    } else {
      m = had;
      closeGoodDay(m, day, paramsOf(c));
    }
    prices[c] = m.price;
    final exportable = open && lo > 0;
    sell[c] = sellThroughOf(m, exportable: exportable);
    if (exportable) {
      final surplus = supply - (localImportsPerS[c] ?? 0.0) - demand;
      if (surplus > 0) exports[c] = surplus;
    }
  }
  return ColonyClose(
    book: PriceBook(
      prices: Map.unmodifiable(prices),
      wagePerWorkerS: book.wagePerWorkerS,
      powerPerKJ: book.powerPerKJ,
      importCeiling: book.importCeiling,
      exportFloor: book.exportFloor,
    ),
    sellThrough: Map.unmodifiable(sell),
    exportsPerS: Map.unmodifiable(exports),
  );
}

/// [solved]'s book with [colony]'s traded prices laid over it: what a
/// colony quotes between closes when only the solve is at hand (a just-
/// loaded save before its next close).
PriceBook overlayPrices(PriceBook solved, Market colony) {
  if (colony.isEmpty) return solved;
  return PriceBook(
    prices: Map.unmodifiable({...solved.prices, ...colony.prices}),
    wagePerWorkerS: solved.wagePerWorkerS,
    powerPerKJ: solved.powerPerKJ,
    importCeiling: solved.importCeiling,
    exportFloor: solved.exportFloor,
  );
}
