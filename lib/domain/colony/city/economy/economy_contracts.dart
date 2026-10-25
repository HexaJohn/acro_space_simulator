// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The shapes the colony economy layer trades in
/// (docs/plans/factory-floors.md §3 "Ownership and money", §7 Q8-Q11).
///
/// Decided by the user (2026-10-12):
/// - SHADOW PRICES first: firms keep a P&L at local market prices; the only
///   real money moving is corporate tax into `funds` and subsidies out.
/// - The player designs any floor; a private firm builds only parts that pay
///   back within [kFirmPaybackYears]; the rest needs a subsidy.
/// - A state plant's loss is charged to `funds` as an industry deficit.
/// - A failing firm lays off, idles stations, then closes and is offered for
///   nationalisation or sale.
///
/// Prices are LOCAL and DERIVED, never hand-set: a colony's price for a good
/// is its local production cost × scarcity, held between the export floor
/// and the import ceiling (source price + transport by Δv and the rocket
/// equation). Money is in credits, the same unit as `CitySim.funds`;
/// integration calibrates the scale.
library;

/// Game-years a private firm will wait for an investment to pay back.
const double kFirmPaybackYears = 5;

enum OwnerKind { state, private }

class Ownership {
  const Ownership.state() : kind = OwnerKind.state, firmId = null;
  const Ownership.private(String this.firmId) : kind = OwnerKind.private;

  final OwnerKind kind;
  final String? firmId;

  bool get isState => kind == OwnerKind.state;

  Map<String, Object?> toJson() => {'k': kind.name, 'f': ?firmId};
  static Ownership fromJson(Map<String, Object?> j) =>
      OwnerKind.values.byName(j['k'] as String) == OwnerKind.state
          ? const Ownership.state()
          : Ownership.private(j['f'] as String);
}

/// How much training a job takes (docs/plans/dynamic-markets.md phase 3,
/// the labour market). Ordered: a worker of a tier can take any job of a
/// LOWER tier (an engineer can pack rations; a packer can't wire avionics),
/// which is why the enum's order matters (`labour_market.dart` fills from
/// the top down). Which tier each building and station needs, and what each
/// tier is paid over the cost of living, is `skill_tiers.dart`.
enum SkillTier {
  /// No training beyond the job itself: farm hands, packers, miners.
  unskilled,

  /// A trade: welders, machine and crane operators, forklift drivers.
  skilled,

  /// Associate-professional training: process operators, maintenance
  /// technicians, lab and clinic staff.
  technical,

  /// A degree: engineers, avionics and electronics assemblers, reactor
  /// operators.
  engineering,
}

/// The colony's ideology, as the economy needs it. Mirrors `CitySim`'s
/// `Economy` enum by NAME (kept separate so this layer doesn't import the
/// aggregate).
enum EconomyKind { capitalism, freeMarket, socialism, communism }

/// Everything about a colony a price depends on. Built by the aggregate at
/// integration; built by hand in tests.
class MarketFacts {
  const MarketFacts({
    required this.bodyId,
    required this.economy,
    this.solarFactor = 1,
    this.waterMult = 1,
    this.oreMult = 1,
    this.atmosphere = const {},
    this.stock = const {},
    this.demandPerS = const {},
    this.supplyPerS = const {},
    this.population = 0,
    this.foodMult = 1,
    this.surfacePressureKPa,
    this.airDensity,
    this.o2Harvestable,
    this.powerFactors = const {},
    this.canExport = false,
    this.learningMult = const {},
    this.unavailable = const {},
    this.noEarthSource = const {},
    this.wageRatio = const {},
  });

  /// `CelestialBody.id` the colony stands on ('earth', 'mars', 'moon' …).
  final String bodyId;
  final EconomyKind economy;

  /// Sunlight relative to Earth's at 1 AU (`CitySim.solarFactor`).
  final double solarFactor;

  /// Site yield multipliers (`biomeFx.water`, `biomeFx.ore`): ice near a
  /// Martian pole makes water cheap; a dry equator makes it dear.
  final double waterMult;
  final double oreMult;

  /// Gas mole fractions of the body's air (terraforming tracks the real
  /// inventory): 'O2', 'CO2', 'N2' …; empty = airless.
  final Map<String, double> atmosphere;

  /// Units in stock, and the colony's steady consumption and production.
  final Map<String, double> stock;
  final Map<String, double> demandPerS;
  final Map<String, double> supplyPerS;

  final int population;

  /// Site yield multiplier on food (`biomeFx.food`), like [waterMult].
  final double foodMult;

  /// Surface air pressure, kPa, which with [atmosphere]'s fractions gives
  /// O₂'s partial pressure (whether the air feeds a colonist for free).
  /// Null = the body's datum pressure from its reference data;
  /// terraforming passes the live value.
  final double? surfacePressureKPa;

  /// Surface air density relative to Earth's (`CitySim.sky.airDensity`).
  /// Null = the body's datum density from its reference data.
  final double? airDensity;

  /// Whether an O₂ harvester can pull oxygen here (`CitySim.o2Harvestable`:
  /// O₂ ≥ 2% of air at least 0.05 kg/m³ dense). Where it can, it runs at
  /// its full nameplate — the sim gates it, it does not scale it. Null =
  /// the same rule applied to [atmosphere] and [airDensity].
  final bool? o2Harvestable;

  /// Multiplier on a power spec's nameplate output by spec type
  /// (`CitySim.powerFactor(type)`; the aggregate fills it, so the sim stays
  /// the one source of truth). A type not listed falls back to the sim's
  /// rule with neutral biome and no nuclear winter: 'solar' ×
  /// [solarFactor], 'wind' × air density (0..3), everything else × 1.
  final Map<String, double> powerFactors;

  /// Whether the colony can SELL off-world (a working spaceport). Without
  /// it no export floor holds a price up: a colony that cannot ship to
  /// Earth cannot get Earth's price for anything.
  final bool canExport;

  /// Multiplier on each good's recipe (mature) cost from the colony's
  /// learning curve, 1 + P·(Qeff/Q0)^(−b) (`learning.dart`); a good not
  /// listed costs its recipe. Empty in a bare solve.
  final Map<String, double> learningMult;

  /// Goods not invented for this colony (`learning.dart`): no recipe that
  /// makes or uses one is eligible, and it has no import source.
  final Set<String> unavailable;

  /// Goods Earth doesn't trade yet (not invented on its timeline, though the
  /// colony may have invented one early): no import source from Earth.
  final Set<String> noEarthSource;

  /// Each skill tier's market wage as a multiple of its anchor (the cost of
  /// living × the tier's skill multiple, `skill_tiers.dart`), from the
  /// colony's labour market (`labour_market.dart`); a tier not listed is at
  /// its anchor. A ratio, not a wage, so the cost solve's wage stays the
  /// fixed point of its own life-support prices and the map stays monotone.
  final Map<SkillTier, double> wageRatio;
}

/// A colony's local prices: credits per commodity unit, plus the wage and
/// the power price every unit cost is built from.
class PriceBook {
  const PriceBook({
    required this.prices,
    required this.wagePerWorkerS,
    required this.powerPerKJ,
    this.importCeiling = const {},
    this.exportFloor = const {},
    this.tierWages = const {},
  });

  final Map<String, double> prices;

  /// Credits per staffed worker-second at the COST OF LIVING: the
  /// subsistence basket plus marked-up housing, which is the unskilled
  /// tier's anchor and the floor under every wage (`labour_market.dart`).
  /// A book with no [tierWages] (one built by hand, from before the labour
  /// market) pays every worker this.
  final double wagePerWorkerS;

  /// Credits per staffed worker-second by skill tier: the labour market's
  /// wages (docs/plans/dynamic-markets.md phase 3). Empty in a single-wage
  /// book.
  final Map<SkillTier, double> tierWages;

  /// What a worker of [tier] costs per second: its market wage, or the one
  /// wage of a single-wage book.
  double wageOf(SkillTier tier) => tierWages[tier] ?? wagePerWorkerS;

  /// Credits per kilojoule of electricity.
  final double powerPerKJ;

  /// The bounds each price was clamped to (for the UI's "why this price").
  final Map<String, double> importCeiling;
  final Map<String, double> exportFloor;

  double price(String commodity) => prices[commodity] ?? 0;
}

/// A plant's P&L over a period (credits; positive = income).
class PlantPnL {
  const PlantPnL({
    required this.seconds,
    required this.revenue,
    required this.inputs,
    required this.wages,
    required this.power,
    required this.logistics,
    required this.equipment,
    required this.tax,
    this.wagesByTier = const {},
    this.tooling = 0,
    this.engineering = 0,
  });

  static const PlantPnL zero = PlantPnL(
      seconds: 0, revenue: 0, inputs: 0, wages: 0, power: 0, logistics: 0,
      equipment: 0, tax: 0);

  final double seconds;
  final double revenue;
  final double inputs;
  final double wages;
  final double power;
  final double logistics;
  final double equipment;

  /// Corporate tax owed (private) — what moves into `funds`. Zero for state.
  final double tax;

  /// [wages] by skill tier (the labour market's wage for each tier times
  /// the hours the plant's profile puts in it); empty for a single-wage
  /// book, where [wages] is all at the one wage.
  final Map<SkillTier, double> wagesByTier;

  /// Specialised tooling recovered on the units shipped, credits: the
  /// credit investment an advanced plant's firm financed, paid back out of
  /// revenue (`industrial_overhead.dart`). Zero for a plant with none.
  final double tooling;

  /// Overhead ENGINEERING wages, credits: the design, test and
  /// certification hours the units shipped carry, at the engineering tier
  /// wage (`industrial_overhead.dart`). Not floor crew, so not in [wages]
  /// or [wagesByTier], which are the floor's hours.
  final double engineering;

  double get costs =>
      inputs + wages + power + logistics + equipment + tooling + engineering;
  double get preTax => revenue - costs;
  double get profit => preTax - tax;

  Map<String, Object?> toJson() => {
        's': seconds, 'rev': revenue, 'in': inputs, 'wage': wages,
        'pow': power, 'log': logistics, 'eq': equipment, 'tax': tax,
        if (tooling != 0) 'tool': tooling,
        if (engineering != 0) 'eng': engineering,
        if (wagesByTier.isNotEmpty)
          'wt': {for (final e in wagesByTier.entries) e.key.name: e.value},
      };
}

/// What a firm does about its books this period (phase 5 policy).
enum FirmAction { none, invest, layoff, idleStations, close }

/// Where a plant's operator stands.
enum FirmHealth { healthy, strained, distressed, closed }

/// Credits per kg to move cargo from one body's surface to another's.
abstract interface class TransportCostModel {
  double perKg(String fromBodyId, String toBodyId);
}
