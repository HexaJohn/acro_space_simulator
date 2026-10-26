// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Learning curves and invention: what a good costs to make falls as the
/// world, and the colony, make more of it (docs/plans/dynamic-markets.md §3
/// "Unit cost learns", phase 2).
///
/// **Wright's law.** The unit cost of a good after Q units have been made is
///
///     unitCost = matureCost · (1 + P · (Q / Q0)^(−b)),  b = −log2(1 − LR)
///
/// - `matureCost`: what the good costs once nobody has anything left to
///   learn. For a colony that is today's recipe cost (`local_prices.dart`:
///   inputs, wages, energy, capital); for Earth it is DERIVED bottom-up
///   (`mature_cost.dart`, phase 3): its recipe's inputs at Earth's mature
///   prices, labour at Earth's tier wages, energy, capital recovery and a
///   normal margin, or a raw good's extraction cost. Earth's price on day 0
///   is that mature cost times one plus the premium still left today.
/// - `Q0`: the first production lot, the cumulative output the first-unit
///   premium is quoted at.
/// - `P` ([TechSeed.firstUnitPremium]): what the first lot carries above
///   mature cost — tooling, R&D, scarce skilled people. Large for advanced
///   goods, nothing for water and oxygen.
/// - `LR` ([TechSeed.learningRate]): the share of the PREMIUM that each
///   doubling of Q removes (the premium term is a pure power law, so it falls
///   by exactly LR per doubling; [premiumAt]). 10-25% by class, the
///   empirical range (Wright's 1936 airframes: 20%; semiconductors ~25%;
///   mature process industry ~10%).
///
/// **Two scopes of experience (user decision §7.2: "both").**
/// - **The world** ([TechState.worldQ]): Earth's industry makes every
///   invented good at its market depth (`markets.dart` [worldFlowPerS]) every
///   colony day, plus whatever colonies export to it. Earth's cost anchor is
///   the curve at world Q ([TechState.earthUnitCost]), so a dear good slides
///   down over game years while a mature one sits at cost.
/// - **The colony** ([TechState.localQ]): every unit the colony itself made,
///   flat plants and factory floors alike (not freight it landed). Its
///   effective experience ([TechState.effectiveQ]) is
///
///       Qeff = Q0 + Qlocal + φ · max(0, Qworld − Q0)
///
///   with φ = [kWorldSpillover]: a small fraction of everything the world
///   has learned since the first lot reaches the colony through published
///   designs, licences and trained immigrants. Small because knowing how is
///   not having done it: world knowledge spills over SLOWLY, and a colony
///   that wants the world's cost has to build its own experience. The Q0
///   floor means a colony that has made nothing pays at most the first lot's
///   premium, never more.
///
/// Closed form worth knowing: a colony that has made none of a good invented
/// long ago pays `r0 · φ^(−b)` premium where Earth pays `r0`, the premium
/// remaining today ([TechSeed.premiumToday]) — φ^(−b) = 20^b is 1.6× for
/// LR 10%, 2.0× for 15%, 2.6× for 20%, 3.5× for 25%. A mature good's tiny
/// premium stays tiny off-world (steel: 2% on Earth, 4% on Mars); a young
/// one's stays large (rocket parts: 400% on Earth, ~1,050% in a colony).
///
/// **Invention (user decision §7.1).** Each good has an invention day on
/// EARTH'S world timeline ([TechSeed.inventionDay], colony days from the
/// world economy's start, [TechState.worldDay]). Before it the good does not
/// exist: Earth doesn't trade it (no import source), no recipe that makes
/// or uses it is allowed (the cost solve skips it, the colony refuses the
/// building, a factory floor refuses the recipe), and nothing has learned
/// it. On the day it appears world Q is the first lot, so it starts at the
/// expensive end of its curve, and Earth's industry ramps up to full depth
/// over [kAdoptionRampDays].
///
/// Every good in today's game is invented on or before day 0
/// ([kInventedBeforeStart]): the colony's milestone unlocks are population
/// gates, not dates, so any positive invention day for an existing good
/// would lock buildings a growing colony is already promised (and break
/// saves). They sit mid-curve instead, with the premium [TechSeed.premiumToday]
/// still to learn away. The invention mechanism is proven on synthetic goods
/// in the tests (test/colony/economy/learning_*).
///
/// **Inventing early.** A colony can spend research (`CitySim.research`) to
/// invent a good for ITSELF before Earth does ([TechState.inventEarlyCost]).
/// It then has the good alone: recipes allowed, no import source, no export
/// floor, and its own first-lot premium — high local prices, the first
/// mover's rent, until Earth catches up.
///
/// **Ownership.** Like Earth's market (`ColonyEconomy.earthMarket`) each
/// colony carries its own copy of the world's state until phase 5 gives the
/// world a single owner: its world clock counts the economy days since that
/// colony's economy started.
///
/// Pure and deterministic: no RNG, no clock but the daily close, every map
/// a [SplayTreeMap] walked in key order.
library;

import 'dart:collection';
import 'dart:math' as math;

import '../commodity.dart';
import 'commodity_mass.dart';
import 'economy_clock.dart';
import 'local_prices.dart';
import 'markets.dart';
import 'mature_cost.dart';

// ---- tuning --------------------------------------------------------------------

/// φ: the fraction of the world's learning since a good's first lot that
/// counts as a colony's own experience. 5%: a colony gains as much from the
/// world making twenty units as from making one itself. Small on purpose
/// (user: "world knowledge spills over to colonies slowly"): drawings and
/// licences travel, the shop-floor know-how that makes Wright's law work
/// mostly doesn't. With it a never-producing colony pays 20^b times Earth's
/// remaining premium (see the library doc), so a mature good stays mature
/// everywhere and a young one is far dearer to make off-world.
const double kWorldSpillover = 0.05;

/// Colony days over which Earth's industry for a NEWLY invented good ramps
/// up from nothing to its full market depth ([worldFlowPerS]), linearly:
/// five game-years, the span of a new product's adoption S-curve (real ones
/// take 5-15 years from first sale to mass market). Without it a good would
/// be made at full world volume the day it was invented and slide down
/// several doublings in its first week. Goods invented before the game
/// starts are already at full depth.
const double kAdoptionRampDays = 5 * 365.25;

/// The invention day every good in today's game carries: invented before
/// the world economy starts, so it exists from day 0 (see the library doc
/// for why no existing good can have a later date).
const double kInventedBeforeStart = 0;

/// Research points a colony spends to invent a good early, per game-year of
/// lead on Earth's timeline, on top of the good's base cost
/// ([TechSeed.inventEarlyResearch]): the cost is base × (1 + years early).
/// Inventing it a decade ahead of the world is eleven times the work of
/// inventing it on the eve of Earth's own discovery.
const double kInventEarlyYearScale = 1;

/// Research a colony spends to invent a good early when its seed names
/// none: 250,000 points, about half a game-year of a 1,000-person colony's
/// research at typical happiness (`CitySim.researchPerPopPerSec` 0.02/s per
/// head × 0.6 happiness × 43,830 colony seconds a year ≈ 526,000 points).
const double kDefaultInventEarlyResearch = 250000;

// ---- per-good seeds ------------------------------------------------------------

/// A good's learning curve and invention point: WORLD STATE the curve starts
/// from, never a price.
///
/// For a good invented before the game starts ([inventionDay] ≤ 0) the curve
/// is calibrated, not typed: world Q today is [worldYearsToday] game-years of
/// Earth's output at its market depth, the first lot Q0 is wherever the
/// premium today comes out at [premiumToday], and the mature cost is
/// DERIVED from the recipes (`mature_cost.dart` [earthMatureCost]). So
/// Earth's anchor on day 0 is mature × (1 + [premiumToday]).
///
/// (Phase 2 took the mature cost as the old `kEarthPricePerKg` seed over
/// (1 + [premiumToday]), which made Earth's day-0 price the seed exactly but
/// left rocket parts' mature price eight times their inputs: a rent no cost
/// explained. A save from phase 2 keeps its Earth prices; their anchors move
/// to the derived curve, the cost ceiling (`kCostCeilingMultiple` × the
/// anchor) brings any price far above it down on the first close, and the
/// rest follows at the class half-life.)
///
/// For a good invented later Q0 is [firstLotUnits] and the mature price
/// [maturePrice], both required.
class TechSeed {
  const TechSeed({
    required this.learningRate,
    required this.firstUnitPremium,
    this.premiumToday = 0,
    this.worldYearsToday = 0,
    this.inventionDay = kInventedBeforeStart,
    this.firstLotUnits,
    this.maturePrice,
    this.worldOutputPerS,
    this.inventEarlyResearch = kDefaultInventEarlyResearch,
  }) : assert(learningRate >= 0 && learningRate < 1);

  /// LR: share of the premium each doubling of experience removes.
  final double learningRate;

  /// P: the first lot's cost above mature, as a multiple of mature cost.
  final double firstUnitPremium;

  /// The premium Earth's industry still carries on day 0, a multiple of
  /// mature cost (a good invented before the game starts only).
  final double premiumToday;

  /// Earth's cumulative output on day 0, in game-years of its output today
  /// (a good invented before the game starts only).
  final double worldYearsToday;

  /// Colony day of Earth's world timeline the good first exists on.
  final double inventionDay;

  /// Q0 for a good invented after the start, units.
  final double? firstLotUnits;

  /// Mature cost per unit on Earth for a good invented after the start
  /// (one invented before it is derived from its recipe, [earthMatureCost]).
  final double? maturePrice;

  /// Earth's output of the good at full depth, units per colony second;
  /// null = its market depth ([worldFlowPerS]).
  final double? worldOutputPerS;

  /// Base research cost of inventing it early ([kInventEarlyYearScale]).
  final double inventEarlyResearch;

  /// b = −log2(1 − LR): the exponent of the premium's power law.
  double get exponent =>
      learningRate <= 0 ? 0 : -math.log(1 - learningRate) / math.ln2;

  /// Whether the good learns at all (water and oxygen don't).
  bool get learns => firstUnitPremium > 0 && learningRate > 0;
}

/// Learning rates by class (plan §6 "Tuning load": per class, not per good).
/// Life support and bulk 10%: mature process industry whose cost is energy
/// and raw material, little left to learn. Industrial 15%: plate and tube
/// still gain from better mills. Advanced 20%: Wright's original airframe
/// figure, the classic aerospace curve. Electronics overrides it with 25%,
/// the semiconductor rate.
const Map<GoodClass, double> kClassLearningRate = {
  GoodClass.lifeSupport: 0.10,
  GoodClass.bulk: 0.10,
  GoodClass.industrial: 0.15,
  GoodClass.advanced: 0.20,
};

/// Every good's seed. A good not listed (waste, compute) never learns and is
/// always invented.
///
/// The two numbers that set how the game FEELS are each good's premium today
/// (how far above its mature cost Earth's price still is) and its age in
/// years of today's output (how fast the world's doubling erodes that):
/// - water, oxygen: no premium at all (P = 0). Pumping and splitting water
///   is as cheap as it will ever get.
/// - food, rations, ore, pig iron, slag: 1-2% left after a century or more.
/// - fuel, oxidizer, steel, tubes, billet: 2% left; steel's is the
///   Bessemer curve run out.
/// - medicine 30% left after 30 years (generics still get cheaper), guns
///   and ammunition 5% after 50.
/// - electronics 25% left after 10 years: chips still learn fastest.
/// - rocket parts 400% left after ONE year of today's output: reusable
///   methalox engines are young; today's ~$1,000/kg is five times what they
///   will cost. Missiles 300% after two.
///
/// First-unit premiums P: 0.5 life support, 1 bulk, 2 industrial, 3 arms,
/// 5 medicine, 10 electronics, 20 aerospace (a first engine at ~20× its
/// production cost is the Apollo-era figure).
const Map<String, TechSeed> kTechSeeds = {
  Commodity.water: TechSeed(learningRate: 0.10, firstUnitPremium: 0),
  Commodity.oxygen: TechSeed(learningRate: 0.10, firstUnitPremium: 0),
  Commodity.food: TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 0.5,
      premiumToday: 0.01,
      worldYearsToday: 100),
  Commodity.rations: TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 0.5,
      premiumToday: 0.02,
      worldYearsToday: 30),
  Commodity.ore: TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 1,
      premiumToday: 0.01,
      worldYearsToday: 100),
  'pigIron': TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 1,
      premiumToday: 0.01,
      worldYearsToday: 100),
  'slag': TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 1,
      premiumToday: 0.01,
      worldYearsToday: 100),
  Commodity.fuel: TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 1,
      premiumToday: 0.02,
      worldYearsToday: 50),
  Commodity.oxidizer: TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 1,
      premiumToday: 0.02,
      worldYearsToday: 50),
  Commodity.steel: TechSeed(
      learningRate: 0.15,
      firstUnitPremium: 2,
      premiumToday: 0.02,
      worldYearsToday: 100),
  Commodity.tubes: TechSeed(
      learningRate: 0.15,
      firstUnitPremium: 2,
      premiumToday: 0.02,
      worldYearsToday: 100),
  'steelBillet': TechSeed(
      learningRate: 0.15,
      firstUnitPremium: 2,
      premiumToday: 0.02,
      worldYearsToday: 100),
  Commodity.medicine: TechSeed(
      learningRate: 0.15,
      firstUnitPremium: 5,
      premiumToday: 0.3,
      worldYearsToday: 30),
  Commodity.guns: TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 3,
      premiumToday: 0.05,
      worldYearsToday: 50),
  Commodity.ammo: TechSeed(
      learningRate: 0.10,
      firstUnitPremium: 3,
      premiumToday: 0.05,
      worldYearsToday: 50),
  Commodity.electronics: TechSeed(
      learningRate: 0.25,
      firstUnitPremium: 10,
      premiumToday: 0.25,
      worldYearsToday: 10),
  Commodity.rocketParts: TechSeed(
      learningRate: 0.20,
      firstUnitPremium: 20,
      premiumToday: 4,
      worldYearsToday: 1),
  Commodity.missiles: TechSeed(
      learningRate: 0.20,
      firstUnitPremium: 20,
      premiumToday: 3,
      worldYearsToday: 2),
};

/// A set of seeds: the game's ([TechCatalog.standard]) or a test's, with a
/// synthetic good to prove the invention mechanism.
class TechCatalog {
  const TechCatalog(this.seeds);

  final Map<String, TechSeed> seeds;

  static const TechCatalog standard = TechCatalog(kTechSeeds);

  /// Every seeded good, in key order.
  List<String> get goods => seeds.keys.toList()..sort();

  TechSeed? operator [](String good) => seeds[good];

  /// Earth's output of [good] at full depth, units per colony second.
  double worldOutputPerS(String good) =>
      seeds[good]?.worldOutputPerS ?? worldFlowPerS(good);

  /// World Q on day 0 of a good invented before the start: its age in years
  /// of today's output, never below the first lot.
  double worldQAtStart(String good) {
    final s = seeds[good];
    if (s == null) return 0;
    if (s.inventionDay > 0) return 0;
    final q = s.worldYearsToday * worldOutputPerS(good) * kGameYearSec;
    return q > 0 ? q : 1;
  }

  /// Q0, units: given for a later invention; for one before the start, the
  /// lot at which the curve's premium on day 0 is [TechSeed.premiumToday]:
  /// P·(Qstart/Q0)^(−b) = r0 ⇒ Q0 = Qstart·(r0/P)^(1/b).
  double firstLot(String good) {
    final s = seeds[good];
    if (s == null) return 1;
    final given = s.firstLotUnits;
    if (given != null && given > 0) return given;
    final qs = worldQAtStart(good);
    if (!s.learns || !(s.premiumToday > 0) || qs <= 0) return math.max(qs, 1);
    return qs *
        math.pow(s.premiumToday / s.firstUnitPremium, 1 / s.exponent)
            .toDouble();
  }

  /// Mature cost per unit on Earth: given (a later invention, or a test's
  /// synthetic good); otherwise derived from its recipe or extraction cost
  /// ([earthMatureCost], `mature_cost.dart`).
  double? maturePrice(String good) {
    final s = seeds[good];
    if (s == null) return null;
    final given = s.maturePrice;
    if (given != null) return given;
    if (s.inventionDay > 0) return null;
    return earthMatureCost(good);
  }

  /// The premium (multiple of mature cost) at experience [q] units.
  double premiumAt(String good, double q) {
    final s = seeds[good];
    return s == null ? 0 : _premium(s, good, q);
  }

  double _premium(TechSeed s, String good, double q) {
    if (!s.learns) return 0;
    final q0 = firstLot(good);
    final ratio = math.max(q, q0) / q0;
    return s.firstUnitPremium * math.pow(ratio, -s.exponent).toDouble();
  }
}

// ---- state ---------------------------------------------------------------------

/// The WORLD's half of the learning state: the world clock and Earth's
/// cumulative output of every seeded good (docs/plans/dynamic-markets.md
/// phase 5, "one world market").
///
/// Split out of [TechState] so that every colony in a game can share ONE
/// (`world_economy.dart` [WorldEconomy] owns it, beside Earth's market):
/// before phase 5 each colony carried its own copy of the world clock and
/// world Q, so two colonies each advanced "the world" a day per close and
/// each colony's exports taught only its own copy of Earth. A colony that
/// stands alone (a city-builder screen, a test) still has a private one, and
/// behaves exactly as before.
class WorldTech {
  /// Colony days since the world economy started (one per world close).
  int day = 0;

  /// Earth's cumulative output of each invented seeded good, units. Absent
  /// = its day-0 seed ([TechCatalog.worldQAtStart]).
  final SplayTreeMap<String, double> q = SplayTreeMap();

  /// Day 0, nothing made: what an old save without world state loads as.
  bool get isFresh => day == 0 && q.isEmpty;

  /// Replaces this state with [o]'s (the merge rule's "take the most
  /// advanced world", `world_economy.dart`).
  void copyFrom(WorldTech o) {
    day = o.day;
    q
      ..clear()
      ..addAll(o.q);
  }

  /// Steps the world one colony day under [catalog]: the clock advances;
  /// every good Earth makes adds a day of its industry's output (ramped for
  /// a good invented after the start, [kAdoptionRampDays]) plus what
  /// colonies sold it ([exportsUnits], units over the day); a good whose
  /// invention day has come starts at its first lot. Returns the goods
  /// invented today.
  List<String> advanceDay(TechCatalog catalog,
      {Map<String, double> exportsUnits = const {}}) {
    final before = day;
    day++;
    final invented = <String>[];
    for (final g in catalog.goods) {
      final s = catalog[g]!;
      if (s.inventionDay > day) continue;
      if (s.inventionDay > before) {
        q[g] = catalog.firstLot(g);
        invented.add(g);
        continue;
      }
      final age = day - s.inventionDay;
      final ramp = s.inventionDay <= 0
          ? 1.0
          : math.min(1.0, age / kAdoptionRampDays);
      final exported = exportsUnits[g] ?? 0.0;
      q[g] = qOf(catalog, g) +
          catalog.worldOutputPerS(g) * kColonyDaySec * ramp +
          (exported > 0 && exported.isFinite ? exported : 0.0);
    }
    return invented;
  }

  /// World Q of [g] for a good Earth already makes: the saved value, or its
  /// seed (the first lot for a good invented after the start, else
  /// [TechCatalog.worldQAtStart]).
  double qOf(TechCatalog catalog, String g) {
    final saved = q[g];
    if (saved != null) return saved;
    final s = catalog[g];
    if (s == null) return 0;
    return s.inventionDay > 0
        ? catalog.firstLot(g)
        : catalog.worldQAtStart(g);
  }

  Map<String, Object?> toJson() => {
        'day': day,
        if (q.isNotEmpty) 'wq': {...q},
      };

  /// Restores [j]'s world fields ('day', 'wq'); a map with neither (a colony
  /// saved while it shared a world, whose world is saved once by its owner)
  /// leaves this state untouched.
  void restore(Map<String, Object?> j) {
    if (!j.containsKey('day') && !j.containsKey('wq')) return;
    day = (j['day'] as num?)?.toInt() ?? 0;
    q.clear();
    ((j['wq'] as Map?) ?? const {}).forEach((k, v) {
      final x = (v as num?)?.toDouble() ?? 0;
      if (x > 0 && x.isFinite) q[k as String] = x;
    });
  }
}

/// What one colony knows about making things, and the world's state as that
/// colony sees it: the world clock and world output ([world], shared by
/// every colony of a game since phase 5), its own cumulative output, and
/// the goods it invented ahead of Earth. Held by `ColonyEconomy.tech`;
/// saved by `CitySim` under its own key, so a colony that never had a plant
/// still keeps its world clock (Earth's prices would jump back to their
/// seed on every load otherwise).
class TechState {
  TechState({this.catalog = TechCatalog.standard});

  /// The seeds (runtime: never saved, always the game's outside a test).
  final TechCatalog catalog;

  /// The world clock and world output this colony reads: its own private
  /// one until it joins a shared world (`world_economy.dart`).
  WorldTech world = WorldTech();

  /// Colony days since the world economy started ([WorldTech.day]).
  int get worldDay => world.day;
  set worldDay(int d) => world.day = d;

  /// Earth's cumulative output of each invented seeded good, units
  /// ([WorldTech.q]). Absent = its day-0 seed ([TechCatalog.worldQAtStart]).
  SplayTreeMap<String, double> get worldQ => world.q;

  /// This colony's own cumulative output of each learning good, units.
  final SplayTreeMap<String, double> localQ = SplayTreeMap();

  /// Goods this colony invented before Earth did.
  final SplayTreeSet<String> early = SplayTreeSet();

  /// Nothing learned, nothing invented, day 0: what an old save loads as.
  bool get isFresh => world.isFresh && isLocalFresh;

  /// Nothing of the colony's OWN: no local output, nothing invented early.
  bool get isLocalFresh => localQ.isEmpty && early.isEmpty;

  // ---- invention ----

  /// Whether Earth's industry makes [good] yet.
  bool inventedOnEarth(String good) {
    final s = catalog[good];
    return s == null || s.inventionDay <= worldDay;
  }

  /// Whether this colony may make and use [good]: Earth invented it, or
  /// the colony did first.
  bool availableHere(String good) =>
      inventedOnEarth(good) || early.contains(good);

  /// Seeded goods Earth doesn't make yet (no import source).
  Set<String> get missingOnEarth => {
        for (final g in catalog.goods)
          if (!inventedOnEarth(g)) g,
      };

  /// Seeded goods this colony may not make or use.
  Set<String> get unavailableHere => {
        for (final g in catalog.goods)
          if (!availableHere(g)) g,
      };

  /// Colony days until Earth invents [good] (0 when it has).
  double daysUntilInvented(String good) {
    final s = catalog[good];
    if (s == null) return 0;
    return math.max(0.0, s.inventionDay - worldDay);
  }

  /// Research it costs this colony to invent [good] now, ahead of Earth;
  /// null when it can't (unknown good, Earth already has it, or invented
  /// here already).
  double? inventEarlyCost(String good) {
    final s = catalog[good];
    if (s == null || availableHere(good)) return null;
    final years = daysUntilInvented(good) / 365.25;
    return s.inventEarlyResearch * (1 + kInventEarlyYearScale * years);
  }

  /// Marks [good] invented here. The caller pays ([inventEarlyCost]).
  bool markInventedEarly(String good) {
    if (inventEarlyCost(good) == null) return false;
    early.add(good);
    return true;
  }

  // ---- experience ----

  /// Earth's cumulative output of [good]; 0 before it is invented.
  double worldQOf(String good) {
    if (!inventedOnEarth(good)) return 0;
    return world.qOf(catalog, good);
  }

  /// This colony's own cumulative output of [good].
  double localQOf(String good) => localQ[good] ?? 0;

  /// Qeff = Q0 + Qlocal + φ·max(0, Qworld − Q0): the experience this
  /// colony's plants make [good] with (library doc).
  double effectiveQ(String good) {
    final q0 = catalog.firstLot(good);
    final world = worldQOf(good);
    return q0 + localQOf(good) + kWorldSpillover * math.max(0.0, world - q0);
  }

  /// Multiplier on this colony's mature (recipe) cost of [good]:
  /// 1 + P·(Qeff/Q0)^(−b).
  double localCostMultiplier(String good) =>
      1 + catalog.premiumAt(good, effectiveQ(good));

  /// [localCostMultiplier] for every seeded good that learns and is
  /// available here, in key order (`MarketFacts.learningMult`).
  Map<String, double> localCostMultipliers() => {
        for (final g in catalog.goods)
          if (catalog[g]!.learns && availableHere(g))
            g: localCostMultiplier(g),
      };

  /// Earth's cost anchor for [good] today: mature × (1 + premium at world
  /// Q); mature × (1 + [TechSeed.premiumToday]) on day 0. Null when Earth
  /// hasn't invented it, or the good has no seed.
  double? earthUnitCost(String good) {
    final s = catalog[good];
    if (s == null || !inventedOnEarth(good)) return null;
    final mature = catalog.maturePrice(good);
    if (mature == null) return null;
    final q = worldQOf(good);
    if (s.inventionDay <= 0 && !worldQ.containsKey(good) && s.learns) {
      // Day 0: the premium exactly as seeded, no round trip through Q0.
      return mature * (1 + s.premiumToday);
    }
    return mature * (1 + catalog.premiumAt(good, q));
  }

  // ---- the daily close ----

  /// Adds a day of this colony's own production ([madeUnits], units made,
  /// not landed) to its experience, for every learning good.
  void recordLocal(Map<String, double> madeUnits) {
    for (final g in (madeUnits.keys.toList()..sort())) {
      final s = catalog[g];
      final u = madeUnits[g]!;
      if (s == null || !s.learns || !(u > 0) || !u.isFinite) continue;
      localQ[g] = localQOf(g) + u;
    }
  }

  /// Steps the world one colony day ([WorldTech.advanceDay] under this
  /// colony's catalog). Returns the goods invented today.
  List<String> advanceWorldDay({Map<String, double> exportsUnits = const {}}) =>
      world.advanceDay(catalog, exportsUnits: exportsUnits);

  // ---- saving ----

  /// The saved state. [withWorld] false (a colony sharing a world, which is
  /// saved once by its owner) leaves the world clock and world Q out.
  Map<String, Object?> toJson({bool withWorld = true}) => {
        if (withWorld) ...world.toJson(),
        if (localQ.isNotEmpty) 'lq': {...localQ},
        if (early.isNotEmpty) 'early': early.toList(),
      };

  /// Restores a saved state into this fresh one; null (an old save) leaves
  /// it at day 0 with every curve at its seed. A save without world fields
  /// leaves [world] as it is.
  void restore(Map<String, Object?>? j) {
    if (j == null) return;
    Map<String, Object?> m(Object? o) =>
        ((o as Map?) ?? const {}).cast<String, Object?>();
    world.restore(j);
    m(j['lq']).forEach((k, v) {
      final q = (v as num?)?.toDouble() ?? 0;
      if (q > 0 && q.isFinite) localQ[k] = q;
    });
    for (final g in (j['early'] as List? ?? const [])) {
      early.add(g as String);
    }
  }
}

// ---- Earth with learning -------------------------------------------------------

/// Every good Earth's market may trade: the market goods plus any seeded
/// good no commodity names (a test's synthetic one), in a fixed order.
List<String> worldGoods(TechCatalog catalog) {
  final base = marketGoods();
  return [
    ...base,
    for (final g in catalog.goods)
      if (!base.contains(g)) g,
  ];
}

/// Earth's market as [tech] finds it: every invented, tradeable good at its
/// cost anchor today ([TechState.earthUnitCost]; a good with no seed at its
/// mature cost, [earthMatureCost]), flows balanced at its depth. A good
/// Earth hasn't invented, or that nothing prices (waste), is not traded.
///
/// This is how Earth's market starts: its prices are derived, never read
/// from the old seed table, and move with the world's supply and demand
/// from then on (`markets.dart` [closeEarthDay]).
Market seedEarthMarketFor(TechState tech) {
  final m = Market();
  for (final c in worldGoods(tech.catalog)) {
    if (!isShippable(c) || !tech.inventedOnEarth(c)) continue;
    final p = tech.earthUnitCost(c) ?? earthMatureCost(c) ?? 0.0;
    if (!(p > 0) || !p.isFinite) continue;
    final w = worldFlowPerS(c);
    m.goods[c] = GoodMarket(
        price: p, anchor: p, stock: 0, demandPerS: w, supplyPerS: w);
  }
  return m;
}

/// Brings [earth] in line with [tech] before its daily step: each seeded
/// good's anchor moves to today's point on its curve; a good invented today
/// joins at its first-lot price; one Earth doesn't make (a catalog that
/// changed under a save) leaves.
void applyWorldTech(Market earth, TechState tech) {
  for (final c in tech.catalog.goods) {
    if (!isShippable(c)) continue;
    if (!tech.inventedOnEarth(c)) {
      earth.goods.remove(c);
      continue;
    }
    final a = tech.earthUnitCost(c);
    if (a == null || !(a > 0) || !a.isFinite) continue;
    final had = earth.goods[c];
    if (had == null) {
      final w = worldFlowPerS(c);
      earth.goods[c] = GoodMarket(
          price: a, anchor: a, stock: 0, demandPerS: w, supplyPerS: w);
    } else {
      had.anchor = a;
    }
  }
}
