// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's local prices, derived from what it would cost to make each
/// good HERE (docs/plans/factory-floors.md §3 "Prices are local and
/// derived").
///
/// The question that shaped this: *"How are costs for goods derived? Say,
/// oxygen. Probably a lot cheaper on Earth than on Mars, unless there is
/// production from the Martian ice caps."* The answer is that every price is
/// a production cost, and every production cost is local:
///
/// - **Each building spec IS a recipe.** Its `inputs`/`outputs` per second,
///   its `jobs` (labour), its `powerDraw` (energy) and its `buildCost` in
///   ore (capital) price one unit of what it makes. The cheapest spec the
///   colony can build wins. The SITE scales the yield: ice under a Martian
///   pole (`waterMult`) makes water cheap and so electrolysis oxygen cheap;
///   a dry equator makes both dear. Every food recipe — hydroponics too —
///   is scaled by the site's food multiplier, as `CitySim.biomeMult` scales
///   all food output. An O₂ harvester runs at full nameplate where
///   `CitySim.o2Harvestable` says the air holds oxygen, and not at all
///   elsewhere — on Mars, the Moon and Venus oxygen comes from electrolysis.
/// - **Power** is priced the same way from the power plants, each scaled by
///   `CitySim.powerFactor` (the best levelised option wins).
/// - **The wage** is the local cost of a colonist's SUBSISTENCE basket (O₂,
///   water, food at REAL per-person consumption) plus housing times an
///   economy markup: the household's take above subsistence. Wages feed
///   every price and life-support prices feed the wage, so the two are
///   solved together by FIXED-POINT iteration.
/// - **Scarcity** (days of cover in stock) nudges the cost up or down.
/// - **Trade bounds it**: never above the IMPORT CEILING (the cheapest
///   source's price + transport by Δv, `transport_cost.dart`; Earth is
///   always a source) and never below the EXPORT FLOOR (the best market it
///   could sell into, less transport — only with [MarketFacts.canExport],
///   or into a market on its own world). A good the colony cannot make is
///   imported, at the ceiling.
///
/// The result: oxygen costs cents on Earth, ~$10/kg at a Martian ice cap,
/// ~$25-40 on a dry Martian plain or the lunar regolith, and hundreds
/// landed from Earth — so Mars and the Moon breathe their own. Electronics
/// sit at the import ceiling until the colony can run an electronics plant,
/// then fall.
///
/// **Convergence.** Every map in the loop — recipe cost in its input prices
/// and the wage, the wage in life-support prices, the min over recipes, the
/// clamp — is monotone non-decreasing, and the clamp bounds every tradeable
/// price. Starting from zero the iterates therefore rise monotonically to
/// the LEAST self-consistent price set, the cheap one a colony would
/// actually find. The approach is geometric at the rate of LABOUR'S SHARE
/// of the subsistence basket: the worker-seconds it takes to make one
/// colonist's day of O₂, water and food, over the seconds in a day. With
/// the catalogue recipes and the real biome table (`CitySim.biomeFx`) that
/// share stays below one on every real Mars and Moon site down to barren
/// (food 0.3, water 0.6). Only the volcano biome (food 0.2, water 0.3)
/// passes one — a colony that cannot feed its own workers — and there
/// prices pin at their import ceilings and the loop still stops. Joint
/// products (a refinery's fuel and oxidizer) split their cost by FIXED
/// Earth-value weights (the `kEarthPricePerKg` seed read as a weight, not
/// as a price), which keeps the map monotone.
///
/// Since dynamic markets (docs/plans/dynamic-markets.md phase 1) this solve
/// no longer IS a colony's price. It gives the cost anchor
/// ([LocalMarket.localCost]), the trade band, the wage and the power price,
/// and the price a colony's market is seeded at on its first day
/// (`markets.dart`).
///
/// Pure and deterministic: no RNG, maps iterated in fixed list order.
library;

import 'dart:math' as math;

import '../../../universe/celestial_body.dart';
import '../../../universe/real_solar_system.dart';
import '../../../universe/star_system.dart';
import '../city_building_spec.dart';
import '../commodity.dart';
import '../factory/factory_handling.dart';
import '../factory/factory_templates.dart';
import 'commodity_mass.dart';
import 'earth_market.dart';
import 'economy_clock.dart';
import 'economy_contracts.dart';
import 'plant_pnl.dart';
import 'transport_cost.dart';

// ---- life support and the wage -------------------------------------------

/// Oxygen a resting-to-light-work adult breathes, kg per day (NASA).
const double kO2KgPerPersonDay = 0.84;

/// Potable water a colonist drinks and cooks with, kg per day (NASA ISS
/// planning; hygiene water is recycled, not bought).
const double kWaterKgPerPersonDay = 3.5;

/// Food as shipped, packaging included, kg per day (NASA planning figure).
const double kFoodKgPerPersonDay = 1.8;

/// Rent-equivalent housing per person, credits per day: an Earth flat's
/// share (~$900/month). Off-world habs are priced from steel at integration;
/// until then every world pays Earth rent.
const double kHousingPerPersonDay = 30;

/// People one wage keeps alive. 1: the wage covers the worker's own
/// basket; the household above subsistence is the [wageMarkup] on housing.
/// Labour's share of the basket scales with it.
const double kPeoplePerWorker = 1;

/// The economy's markup on the NON-subsistence part of the wage (housing
/// and what a household buys above staying alive), by economy. Communism
/// pays near subsistence; a free market pays the most.
///
/// Applied only above subsistence, deliberately: a markup on the whole
/// basket multiplies labour's share of life support by it, and with the
/// real biome table that pushed every dry Martian and lunar site (desert,
/// barren) past one, pinning O₂ and food at the import ceiling. A worker
/// on a poor site is not paid 1.5× his own oxygen; the premium is what he
/// spends on everything else, priced at Earth rent until habs are priced
/// from steel at integration.
double wageMarkup(EconomyKind e) => switch (e) {
      EconomyKind.communism => 1.1,
      EconomyKind.socialism => 1.25,
      EconomyKind.capitalism => 1.4,
      EconomyKind.freeMarket => 1.5,
    };

/// Partial pressure of O₂ a person breathes unaided, kPa (sea level is
/// 21.2; below ~16 hypoxia sets in). At or above it, oxygen is not in the
/// wage basket: the air gives it.
const double kBreathableO2KPa = 16;

/// `CitySim.o2Harvestable`'s thresholds: O₂ mole fraction, and air density
/// in kg/m³ (`sky.airDensity × earthDensity`).
const double kHarvestO2Fraction = 0.02;
const double kHarvestMinDensityKgM3 = 0.05;

/// Earth's sea-level air density, kg/m³ (`CitySim.earthDensity`).
const double kEarthAirDensityKgM3 = 1.225;

// ---- energy and capital ----------------------------------------------------

/// Kilojoules in one spec power unit for one second. A spec's power unit is
/// a megawatt: the 780 m Solar Farm's 60 units is what ~0.6 km² of panels
/// delivers at peak.
const double kKjPerPowerUnitS = 1000;

/// Game-years over which a plant's build cost (ore at the local price) is
/// recovered in its unit cost, like a loan term.
const double kCapitalRecoveryYears = 10;

/// Wind output scales with air density, clamped like `CitySim.windFactor`.
const double kMaxWindFactor = 3.0;

// ---- scarcity ----------------------------------------------------------------

/// Days of cover at which scarcity is neutral (×1).
const double kTargetCoverDays = 30;

/// Scarcity factor = (target / cover)^elasticity, bounded. 0.5: a quarter
/// of the target cover doubles the price, a ninth of it triples it (the
/// [kScarcityMax] cap); twice the target cover takes ~30% off, which is
/// the [kScarcityMin] floor.
const double kScarcityElasticity = 0.5;

/// Bounds on scarcity: a glut sells at 70% of cost; a shortage at most
/// triples it (beyond that the import ceiling takes over anyway).
const double kScarcityMin = 0.7;
const double kScarcityMax = 3.0;

/// Net drain below which a good counts as not being drawn down, units/s.
const double kScarcityEps = 1e-9;

// ---- solving -----------------------------------------------------------------

/// Iteration cap for the wage ↔ price fixed point.
const int kDefaultMaxIterations = 500;

/// Max relative change between iterates at which the solve has converged.
const double kPriceTolerance = 1e-6;

/// Specs that make goods but are not RECIPES a market can lean on:
/// spaceports "make" food, water and oxygen by landing them (that's the
/// import ceiling, already counted), and a terraforming tower's oxygen goes
/// into the sky.
const Set<String> kNonRecipeTypes = {'spaceport', 'terraformer'};

/// Spec groups whose output is bounded by a waste stream, not by demand:
/// a recycler can't make steel faster than the colony throws things away,
/// so it never sets steel's price.
const Set<String> kNonRecipeGroups = {'waste'};

/// Factory intermediates no colony spec makes, valued at the commodity they
/// stand for until floors' measured recipes price them (wave 3): a pig-iron
/// pallet ≈ the ore pallet it was smelted from, slag ≈ a twentieth of one,
/// a 1.5 t billet ≈ fifteen 100 kg steel units.
const Map<String, (String, double)> kIntermediateBasis = {
  'pigIron': (Commodity.ore, 1.0),
  'slag': (Commodity.ore, 0.05),
  'steelBillet': (Commodity.steel, 15),
};

/// Source tag for a good bought in at the import ceiling.
const String kSourceImport = 'import';

/// Source tag for a good with no recipe and no market (waste).
const String kSourceNone = 'none';

/// Everything a solve found, for tests and the UI's "why this price".
class LocalMarket {
  const LocalMarket({
    required this.book,
    required this.localCost,
    required this.sourceOf,
    required this.scarcity,
    required this.iterations,
    required this.converged,
  });

  final PriceBook book;

  /// Cheapest local production cost per unit (before scarcity and clamp);
  /// absent for a good with no local recipe.
  final Map<String, double> localCost;

  /// Which spec type sets each price, or [kSourceImport] / [kSourceNone].
  final Map<String, String> sourceOf;

  final Map<String, double> scarcity;
  final int iterations;
  final bool converged;
}

/// The colony's local prices. See [solveLocalMarket].
PriceBook solveLocalPrices(
  MarketFacts facts, {
  TransportCostModel? transport,
  Map<String, PriceBook>? otherMarkets,
  Map<String, double>? earthPrices,
  int maxIterations = kDefaultMaxIterations,
  List<CityBuildingSpec>? recipes,
}) =>
    solveLocalMarket(facts,
            transport: transport,
            otherMarkets: otherMarkets,
            earthPrices: earthPrices,
            maxIterations: maxIterations,
            recipes: recipes)
        .book;

/// Every good a market prices, in a fixed order: the colony commodities,
/// then the factory intermediates no commodity names.
List<String> marketGoods() => [
      ...Commodity.ordered,
      for (final k in kIntermediateBasis.keys)
        if (!Commodity.ordered.contains(k)) k,
    ];

/// Solves the wage ↔ price fixed point for [facts].
///
/// [transport] defaults to the real-Solar-System [DeltaVTransportModel].
/// [otherMarkets] are other colonies' books, keyed by their body id; Earth's
/// market is always a source. [earthPrices] are Earth's LIVE prices per unit
/// (its market's state, `markets.dart`); a good it doesn't list, or a null
/// map (a bare solve in a test), falls back to the `kEarthPricePerKg` seed.
/// [recipes] defaults to the utility catalogue plus the zoned industry
/// tiers.
LocalMarket solveLocalMarket(
  MarketFacts facts, {
  TransportCostModel? transport,
  Map<String, PriceBook>? otherMarkets,
  Map<String, double>? earthPrices,
  int maxIterations = kDefaultMaxIterations,
  List<CityBuildingSpec>? recipes,
}) {
  final t = transport ?? _defaultTransport;
  final goods = marketGoods();
  final air = _Air.of(facts);
  final specs = _eligible(recipes ?? _defaultRecipes, facts, air);

  // ---- constant bounds and scarcity ----
  final ceiling = <String, double>{};
  final floor = <String, double>{};
  final markets = otherMarkets ?? const <String, PriceBook>{};
  final marketIds = markets.keys.where((k) => k != facts.bodyId).toList()
    ..sort();
  for (final c in goods) {
    if (!isShippable(c)) continue;
    final kg = kgPerUnit(c);
    var hi = double.infinity, lo = 0.0;
    void source(String body, double price) {
      final inT = t.perKg(body, facts.bodyId);
      if (inT.isFinite) hi = math.min(hi, price + inT * kg);
      // Selling off-world needs a working spaceport; a market on the
      // colony's own world needs none.
      if (!facts.canExport && body != facts.bodyId) return;
      final outT = t.perKg(facts.bodyId, body);
      if (outT.isFinite) lo = math.max(lo, price - outT * kg);
    }

    source('earth', earthPrices?[c] ?? earthPrice(c));
    for (final id in marketIds) {
      final p = markets[id]!.prices[c];
      if (p != null && p > 0) source(id, p);
    }
    if (hi.isFinite) ceiling[c] = hi;
    floor[c] = hi.isFinite ? math.min(lo, hi) : lo;
  }
  final scarcity = {for (final c in goods) c: _scarcity(facts, c)};

  // ---- fixed point ----
  final markup = wageMarkup(facts.economy);
  double wageFor(Map<String, double> p) {
    var perPersonDay = kWaterKgPerPersonDay / kgPerUnit(Commodity.water) *
            (p[Commodity.water] ?? 0) +
        kFoodKgPerPersonDay / kgPerUnit(Commodity.food) *
            (p[Commodity.food] ?? 0);
    if (!air.breathable) {
      perPersonDay += kO2KgPerPersonDay / kgPerUnit(Commodity.oxygen) *
          (p[Commodity.oxygen] ?? 0);
    }
    return (perPersonDay * kPeoplePerWorker + kHousingPerPersonDay * markup) /
        kColonyDaySec;
  }

  var prices = {for (final c in goods) c: 0.0};
  var wage = wageFor(prices);
  var powerUnit = 0.0; // credits per spec power unit-second
  var computeUnit = 0.0; // credits per compute unit-second
  var localCost = <String, double>{};
  var sourceOf = <String, String>{};
  var iterations = 0;
  var converged = false;
  final capexPerS = 1 / (kCapitalRecoveryYears * kGameYearSec);

  while (iterations < maxIterations) {
    iterations++;
    final p = prices;
    // Everything the plant's own books charge (`plant_pnl.dart`), so the
    // plant that SETS a price breaks even at it, plus its capital: without
    // the freight fee and its handlers' wear a price-setting floor plant
    // ran at a loss by construction, and failed on every world whose
    // prices aren't pinned to Earth's. Both apply to floor plants only,
    // the only buildings that pay them.
    double running(CityBuildingSpec s) {
      var cost = s.jobs * wage +
          s.powerDraw * powerUnit +
          s.computeDraw * computeUnit +
          s.buildCost * (p[Commodity.ore] ?? 0) * capexPerS +
          (_templateWearPerS[s.type] ?? 0);
      var units = 0.0;
      for (final e in s.inputs.entries) {
        cost += e.value * (p[e.key] ?? 0);
        units += e.value;
      }
      for (final v in s.outputs.values) {
        units += v;
      }
      // Only a floor plant's books pay the freight fee (`pnlFor` charges it
      // from the floor's ledger); a farm, a water pump or a harvester pays
      // none, so their goods, and the wage built from them, carry none.
      final fee = _floorPlantTypes.contains(s.type) ? kLogisticsFeePerUnit : 0.0;
      return cost + units * fee;
    }

    var nextPower = double.infinity;
    var nextCompute = double.infinity;
    final cost = <String, double>{};
    final from = <String, String>{};
    for (final s in specs) {
      final c = running(s);
      if (s.powerOutput > 0) {
        final out = s.powerOutput * _powerFactor(s, facts, air);
        if (out > 0) nextPower = math.min(nextPower, c / out);
      }
      if (s.computeOutput > 0) {
        nextCompute = math.min(nextCompute, c / s.computeOutput);
      }
      if (s.outputs.isEmpty) continue;
      var weightSum = 0.0;
      for (final e in s.outputs.entries) {
        weightSum += e.value * earthPrice(e.key);
      }
      for (final e in s.outputs.entries) {
        final rate = e.value * _yield(s, e.key, facts, air);
        if (rate <= 0) continue;
        final share = weightSum > 0
            ? e.value * earthPrice(e.key) / weightSum
            : 1 / s.outputs.length;
        final unit = c * share / rate;
        final had = cost[e.key];
        if (had == null || unit < had) {
          cost[e.key] = unit;
          from[e.key] = s.type;
        }
      }
    }
    if (nextPower.isInfinite) nextPower = 0;
    final hasCompute = nextCompute.isFinite;
    if (!hasCompute) nextCompute = 0;

    final next = <String, double>{};
    for (final c in goods) {
      final hi = ceiling[c] ?? double.infinity;
      final lo = floor[c] ?? 0;
      var local = cost[c];
      if (c == Commodity.compute) {
        local = hasCompute ? nextCompute : null;
        if (local != null) from[c] = _computeSource(specs);
      }
      final basis = kIntermediateBasis[c];
      if (local == null && basis != null) {
        local = basis.$2 * (p[basis.$1] ?? 0);
        from[c] = 'basis:${basis.$1}';
      }
      if (local == null) {
        next[c] = hi.isFinite ? hi : 0;
        from[c] = hi.isFinite ? kSourceImport : kSourceNone;
        continue;
      }
      final scaled = local * scarcity[c]!;
      if (scaled >= hi) from[c] = kSourceImport;
      next[c] = scaled.clamp(lo, hi).toDouble();
      cost[c] = local;
    }
    final nextWage = wageFor(next);

    var delta = 0.0;
    double rel(double a, double b) {
      final scale = math.max(a.abs(), b.abs());
      return scale <= 0 ? 0 : (a - b).abs() / scale;
    }

    for (final c in goods) {
      delta = math.max(delta, rel(next[c]!, p[c]!));
    }
    delta = math.max(delta, rel(nextWage, wage));
    delta = math.max(delta, rel(nextPower, powerUnit));
    delta = math.max(delta, rel(nextCompute, computeUnit));

    prices = next;
    wage = nextWage;
    powerUnit = nextPower;
    computeUnit = nextCompute;
    localCost = cost;
    sourceOf = from;
    if (delta < kPriceTolerance) {
      converged = true;
      break;
    }
  }

  return LocalMarket(
    book: PriceBook(
      prices: Map.unmodifiable(prices),
      wagePerWorkerS: wage,
      powerPerKJ: powerUnit / kKjPerPowerUnitS,
      importCeiling: Map.unmodifiable(ceiling),
      exportFloor: Map.unmodifiable(floor),
    ),
    localCost: Map.unmodifiable(localCost),
    sourceOf: Map.unmodifiable(sourceOf),
    scarcity: Map.unmodifiable(scarcity),
    iterations: iterations,
    converged: converged,
  );
}

// ---- helpers -----------------------------------------------------------------

final DeltaVTransportModel _defaultTransport = DeltaVTransportModel();

/// Equipment wear of each floor plant's template roster, credits per colony
/// second (what [running] adds for a plant that runs a factory floor).
/// Built once, on first use.
final Map<String, double> _templateWearPerS = {
  for (final t in kFactoryPlantTypes) t: _rosterWearPerS(t),
};

/// Spec types whose running cost includes the freight fee: the plants that
/// run a factory floor and so keep a ledger `pnlFor` charges it on.
final Set<String> _floorPlantTypes = {...kFactoryPlantTypes};

double _rosterWearPerS(String plantType) {
  final roster = factoryTemplateFor(plantType)?.roster ?? const {};
  var wear = 0.0;
  for (final k in HandlerKind.values) {
    wear += (roster[k] ?? 0) * equipmentWearPerS(k);
  }
  return wear;
}
final StarSystem _realSystem = RealSolarSystem.build();

final List<CityBuildingSpec> _defaultRecipes = [
  ...kUtilCatalog,
  for (final d in Density.values) ?kZoneSpecs['industrial']?[d],
];

/// The body's air as the recipes need it.
class _Air {
  const _Air(this.o2KPa, this.density, this.harvestable);
  final double o2KPa;

  /// Air density relative to Earth's.
  final double density;

  /// `CitySim.o2Harvestable`.
  final bool harvestable;

  bool get breathable => o2KPa >= kBreathableO2KPa;

  static _Air of(MarketFacts f) {
    final datum = _realSystem.body(BodyId(f.bodyId))?.atmosphere;
    final density = f.airDensity ??
        (f.atmosphere.isEmpty
            ? 0.0
            : (datum?.seaLevelDensity ?? 0) / kEarthAirDensityKgM3);
    final o2 = f.atmosphere['O2'] ?? 0;
    final harvestable = f.o2Harvestable ??
        (density * kEarthAirDensityKgM3 > kHarvestMinDensityKgM3 &&
            o2 >= kHarvestO2Fraction);
    final p = f.atmosphere.isEmpty
        ? 0.0
        : f.surfacePressureKPa ?? (datum?.seaLevelPressure ?? 0) / 1000;
    return _Air(o2 * p, density, harvestable);
  }
}

/// `CitySim.powerFactor(type)`: the aggregate's value when it passed one,
/// else the sim's rule with a neutral biome and no nuclear winter.
double _powerFactor(CityBuildingSpec s, MarketFacts f, _Air air) {
  final given = f.powerFactors[s.type];
  if (given != null) return given;
  return switch (s.type) {
    'solar' => f.solarFactor,
    'wind' => air.density.clamp(0.0, kMaxWindFactor).toDouble(),
    _ => 1.0,
  };
}

/// Site multiplier on [s]'s output of [c].
double _yield(CityBuildingSpec s, String c, MarketFacts f, _Air air) {
  // The sim gates a harvester on the sky and otherwise runs it at full
  // nameplate (`CitySim.tick`: `s.type != 'o2harvester' || skyO2`).
  if (s.type == 'o2harvester' && c == Commodity.oxygen) {
    return air.harvestable ? 1 : 0;
  }
  return switch (c) {
    Commodity.water => f.waterMult,
    Commodity.ore => f.oreMult,
    Commodity.food => f.foodMult,
    _ => 1,
  };
}

/// Specs this colony can build and run as recipes, in catalogue order.
List<CityBuildingSpec> _eligible(
    List<CityBuildingSpec> all, MarketFacts f, _Air air) {
  bool produces(CityBuildingSpec s) =>
      s.outputs.isNotEmpty || s.powerOutput > 0 || s.computeOutput > 0;
  bool usable(CityBuildingSpec s) =>
      produces(s) &&
      !kNonRecipeTypes.contains(s.type) &&
      !kNonRecipeGroups.contains(s.group) &&
      s.unlockPop <= f.population &&
      !(s.type == 'o2harvester' && !air.harvestable) &&
      !(s.powerOutput > 0 && _powerFactor(s, f, air) <= 0);
  final base = all.where(usable).toList();
  final computeSource = base.any((s) => s.computeOutput > 0);
  return [
    for (final s in base)
      if (s.computeDraw <= 0 || computeSource) s,
  ];
}

String _computeSource(List<CityBuildingSpec> specs) =>
    specs.firstWhere((s) => s.computeOutput > 0).type;

/// Price multiplier from days of cover.
///
/// A good the colony isn't drawing down is a GLUT only when it is also
/// piling up: more than [kTargetCoverDays] of its own supply in stock.
/// Most of what a plant makes (steel, tubes, fuel) has no flow consumer in
/// the colony at all, so supply always beats demand; reading that as a glut
/// priced every such good at 70% of its cost with nothing in stock, and the
/// plants that make them failed by construction off Earth.
double _scarcity(MarketFacts f, String c) {
  final demand = f.demandPerS[c] ?? 0;
  final supply = f.supplyPerS[c] ?? 0;
  if (demand <= 0 && supply <= 0) return 1; // no market activity, no signal
  final drain = demand - supply;
  if (drain <= kScarcityEps) {
    if (!(supply > 0)) return 1;
    final heldDays = (f.stock[c] ?? 0) / (supply * kColonyDaySec);
    return heldDays > kTargetCoverDays ? kScarcityMin : 1; // a glut, or not
  }
  final coverDays = (f.stock[c] ?? 0) / drain / kColonyDaySec;
  if (coverDays <= 0) return kScarcityMax;
  return math
      .pow(kTargetCoverDays / coverDays, kScarcityElasticity)
      .toDouble()
      .clamp(kScarcityMin, kScarcityMax);
}
