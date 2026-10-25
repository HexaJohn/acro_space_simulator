// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What an advanced plant pays for beyond its recipe: specialised TOOLING
/// capital and the ENGINEERING hours each unit needs. It is part of the
/// mature-cost and local unit-cost models (docs/plans/dynamic-markets.md
/// phase 3 follow-up, "advanced-goods prices").
///
/// **Why.** Phase 3 derived every manufactured good's mature cost from its
/// recipe: inputs, floor labour, energy, the ore build cost and a normal
/// margin. For electronics, rocket parts and missiles that came out 16×,
/// 40× and 190× under real-world prices, because a recipe carries the
/// MATERIALS and the floor crew and nothing else. A real engine or missile
/// is mostly what the recipe leaves out: the clean rooms, jigs and test
/// stands that must exist before the first unit, and the design, test and
/// certification hours spent on every unit after. In the user's words:
/// *"the cost of the rocket parts is to offset the massive upfront
/// investment to set up the specialized machinery and skilled labor"*.
/// This file adds those two lines per plant, each a documented real-world
/// order of magnitude. No price is typed in anywhere: the price still comes
/// out of the cost solve and the market.
///
/// **Tooling capital** ([PlantOverhead.toolingCredits]) is a CREDIT
/// investment the owning firm finances: machines, clean rooms, test stands
/// and ranges. It is NOT the plant's ore [CityBuildingSpec.buildCost],
/// which stays the physical construction cost the colony pays in ore. The
/// plant recovers its tooling straight-line over [kCapitalRecoveryYears]
/// of NAMEPLATE output, the way aerospace program accounting spreads
/// tooling over a programme's planned units. So:
/// - the cost solve (`local_prices.dart`) adds [toolingRecoveryPerS] to the
///   plant's running cost, split over its outputs like the rest of it;
/// - the P&L (`plant_pnl.dart`) books [toolingPerUnit] on every unit the
///   plant ships, as the line [PlantPnL.tooling]: the firm's books pay its
///   tooling back out of its revenue, so a firm's profit and payback are
///   net of it.
///
/// **Engineering hours** ([PlantOverhead.engineeringHoursPerUnit]) are the
/// design, test and certification labour a unit carries: acceptance
/// testing, inspection, failure analysis, paperwork, sustaining
/// engineering. They are OVERHEAD labour, not floor crew: no station gets
/// another worker. The cost solve prices them at the market's ENGINEERING
/// tier wage ([SkillTier.engineering], `labour_market.dart`), and the P&L
/// books them as [PlantPnL.engineering] wages. An hour of work is
/// [kWorkerSecondsPerHour] worker-seconds of the colony clock.
///
/// **Engineering is a traded service** ([engineeringWagePerS]): design,
/// analysis and certification are drawings and data, so a firm whose own
/// colony's engineers cost more than Earth's contracts the hours from
/// Earth's engineering firms at Earth's rate ([earthEngineeringWagePerS]).
/// It pays the cheaper of the two. Without that a Martian plant paid its
/// engineering hours at Mars's wage (life support makes every Martian wage
/// ~25× Earth's, and a 300-person colony's few engineers command a scarcity
/// premium on top), ~$54,000 a colony second for the Rocket Parts Factory
/// against its ~$61,000 of revenue at the import ceiling, and the Missile
/// Plant ran at a loss on every world but Earth. The hours are posted to no
/// colony's labour market for the same reason: the firm's own colonists
/// are not the ones doing them unless they are cheaper.
///
/// **The model's engineering wage is low.** A job's wage is the cost of
/// living times its tier multiple (`skill_tiers.dart`): an engineer costs
/// ~$130 a reference day on Earth, ~$16 an hour, where a real loaded
/// engineer costs $100-150 an hour. Real engineering hours priced at that
/// wage under-cost the real bill by ~8×, so the hours below are the real
/// order of magnitude (not inflated to hit a price) and the tooling, with
/// Earth's learning premium, carries the rest.
///
/// **What is NOT double-counted with the learning premium.** Wright's law
/// (`learning.dart`) puts a premium on top of the mature cost that each
/// doubling of output erodes: the first-of-kind R&D, the tooling that gets
/// scrapped and rebuilt as the process matures, the scarce people who know
/// how. The lines here are the RECURRING part a fully mature industry still
/// pays forever: every plant needs its tooling, every unit is tested and
/// certified. So the split is:
/// - mature cost (here): recurring tooling and per-unit engineering at
///   full nameplate, as a mature line runs;
/// - learning premium (`learning.dart`): everything above that which
///   experience removes. Its seeds ([TechSeed.premiumToday]) say how far
///   above MATURE Earth's price still is and are unchanged: Earth's
///   rocket-parts price is still five times its mature cost, and that
///   mature cost now includes its tooling.
///
/// **Why a colony with few such plants pays more per unit than Earth.**
/// Earth's mature cost assumes the world's industry runs every line full
/// and sells every unit. A colony's plant recovers the same tooling over the
/// same nameplate plan, but:
/// - its learning multiplier ([MarketFacts.learningMult]) multiplies the
///   WHOLE recipe cost, tooling and engineering included: its first line
///   underperforms its plan (rework, test failures, idle tooling), and with
///   world knowledge spilling over slowly a never-producing colony carries
///   ~2.6× Earth's remaining rocket-parts premium (`learning.dart`);
/// - its books pay tooling on every unit SHIPPED, but revenue only on what
///   SELLS (`plant_pnl.dart` sell-through): a small market that takes half
///   the plant's output loads each sold unit with two units' tooling. Earth's
///   world market takes everything.
/// The two are separate effects (one is experience, one is utilisation),
/// so neither counts the other.
///
/// Pure and deterministic: constant tables and arithmetic.
library;

import '../city_building_spec.dart';
import '../commodity.dart';
import 'earth_market.dart';
import 'economy_clock.dart';
import 'economy_contracts.dart';
import 'local_prices.dart';
import 'mature_cost.dart';
import 'skill_tiers.dart';

/// Working hours in one reference day of a full-time job: the 8-hour day.
/// A job in the economy is one worker present for a whole colony day
/// ([kColonyDaySec]), paid a day's wage, so one working hour is an eighth
/// of that.
const double kWorkingHoursPerDay = 8;

/// Colony worker-seconds in one working hour: 120 s ÷ 8 h = 15. The unit
/// [PlantOverhead.engineeringHoursPerUnit] converts through.
const double kWorkerSecondsPerHour = kColonyDaySec / kWorkingHoursPerDay;

/// Earth's engineering wage, credits per worker-second: Earth's cost of
/// living (the subsistence basket at its extraction costs, Earth's air free,
/// plus housing at the world economy's markup) times the engineering skill
/// multiple, every tier at its anchor. Exactly what Earth's mature-cost
/// solve pays an engineer (`mature_cost.dart`, checked in the tests), but
/// from the constants, so the cost solve can read it without solving
/// Earth first.
final double earthEngineeringWagePerS = () {
  final basket = kWaterKgPerPersonDay * kExtractionCostPerKg[Commodity.water]! +
      kFoodKgPerPersonDay * kExtractionCostPerKg[Commodity.food]!;
  final perDay =
      basket * kPeoplePerWorker + kHousingPerPersonDay * wageMarkup(kWorldEconomy);
  return perDay / kColonyDaySec * skillMultipleOf(SkillTier.engineering);
}();

/// The wage an advanced plant pays for its overhead engineering hours: the
/// cheaper of its own market's engineering wage [localEngineeringWage] and
/// Earth's contract rate [earthEngineeringWagePerS] (see the library doc,
/// "Engineering is a traded service").
double engineeringWagePerS(double localEngineeringWage) =>
    localEngineeringWage < earthEngineeringWagePerS
        ? localEngineeringWage
        : earthEngineeringWagePerS;

/// One advanced plant's overhead: its tooling capital and the engineering
/// hours each unit of each good it makes needs.
class PlantOverhead {
  const PlantOverhead({
    required this.toolingCredits,
    required this.engineeringHoursPerUnit,
  });

  /// Specialised tooling, clean rooms, test stands and ranges, credits:
  /// what the firm finances before the first unit. Not ore.
  final double toolingCredits;

  /// Design, test and certification hours per unit of each output good.
  final Map<String, double> engineeringHoursPerUnit;
}

/// Every plant type that carries an overhead, with the real-world reasoning
/// for each number. Throughputs are each plant's nameplate per reference
/// day (output/s × [kColonyDaySec]) and over [kCapitalRecoveryYears].
///
/// Plants not listed (the Steel Mill, Refinery, Rations Plant, mines, farms)
/// are commodity process industries whose capital the ore build cost and
/// the normal margin already cover: their derived prices sit within ~20% of
/// real-world without it. The pharmaceutical chemist is not listed either:
/// medicine lands at ~¼ of real-world, inside its band, and a drug's real
/// price is patent rent and R&D, which is the learning premium's job.
const Map<String, PlantOverhead> kPlantOverheads = {
  // Electronics Plant: 0.6 trays/s = 72 trays (720 kg) of boards and
  // modules a day, ~260 t a year, ~263,000 trays over ten years.
  'electronics': PlantOverhead(
    // A board-and-module plant, not a wafer fab: clean-room SMT lines
    // (~$2-5M each), die attach and packaging, test and burn-in, X-ray and
    // AOI inspection, the clean-room shell (~$1,000-3,000/ft²). A plant of
    // this throughput (a mid-size EMS or avionics-module site) is a
    // $300-600M build: $400M, ~$1,500 a tray at nameplate.
    toolingCredits: 4e8,
    engineeringHoursPerUnit: {
      // Test engineering, firmware load, failure analysis and burn-in
      // supervision: ~2 h per 2.5 kg server-board set, ~8 h a 10 kg tray.
      Commodity.electronics: 8,
    },
  ),
  // Rocket Parts Factory: 0.4 crates/s = 48 crates (4.8 t) of engine and
  // avionics parts a day, ~1,750 t a year: about a thousand methalox
  // engines of ~1.6 t a year, two to three times SpaceX's Raptor rate.
  'rocketfactory': PlantOverhead(
    // An engine works and its test site: precision machining and additive
    // lines, cryogenic clean assembly, and the acceptance test stands every
    // engine is fired on (SpaceX's Hawthorne engine lines plus McGregor,
    // ~$1-2B; Blue Origin's ~$200M Huntsville engine plant at a fraction of
    // the rate). $1.5B: ~$8,600 a crate at nameplate.
    toolingCredits: 1.5e9,
    engineeringHoursPerUnit: {
      // Acceptance test firing, NDT and X-ray inspection, flight-hardware
      // paperwork and sustaining engineering: ~5,000 h per 1.6 t engine
      // (a hand-built RS-25 took far more; a mass-produced engine still
      // thousands), so ~300 h a 100 kg crate. About 1,800 engineers at
      // nameplate, against SpaceX's ~13,000 staff at a lower engine rate.
      Commodity.rocketParts: 300,
    },
  ),
  // Missile Plant: 0.15 missiles/s = 18 tonne-class missiles a day, ~6,600
  // a year: more large missiles than the whole US industry builds.
  'missilefactory': PlantOverhead(
    // Energetics (motor casting and warhead filling behind blast berms),
    // seeker and guidance clean rooms, environmental and EMI test
    // chambers, and a test range for lot acceptance firing. The US
    // large-missile base (Tucson, Camden, Huntsville, Troy) is a ~$5-10B
    // plant estate at a fraction of this rate: $8B, ~$120,000 a missile.
    toolingCredits: 8e9,
    engineeringHoursPerUnit: {
      // Guidance integration and alignment, hardware-in-the-loop test,
      // lot acceptance, certification and the sustaining engineering a
      // weapons programme keeps: ~5,000 h per tonne-class missile (a
      // Tomahawk-class round is $1.5-2M, mostly labour). ~11,000 engineers
      // at nameplate.
      Commodity.missiles: 5000,
    },
  ),
  // Arms Factory: 0.3 rifles/s and 1.0 ammo cases/s = 36 rifles and 120
  // cases (120,000 rounds) a day: ~13,000 rifles and ~44M rounds a year.
  'gunfactory': PlantOverhead(
    // CNC barrel and receiver lines, rifling and proof-firing ranges, and a
    // bermed ammunition loading line. A modern rifle line (~$20M) plus a
    // 40-50M-round ammunition line (~$40M; Lake City's 1.5B rounds a year
    // took a $1B+ modernisation): $60M.
    toolingCredits: 6e7,
    engineeringHoursPerUnit: {
      // Proof firing, inspection and quality records: ~2 h a rifle.
      Commodity.guns: 2,
      // Lot acceptance testing and ballistics records: ~0.1 h a case of
      // 1,000 rounds.
      Commodity.ammo: 0.1,
    },
  ),
};

/// [type]'s overhead, or null for a plant with none.
PlantOverhead? overheadOf(String type) => kPlantOverheads[type];

/// [type]'s tooling recovered per colony second at nameplate, credits:
/// straight-line over [kCapitalRecoveryYears] game-years. Zero for a plant
/// with no tooling.
double toolingRecoveryPerS(String type) =>
    (kPlantOverheads[type]?.toolingCredits ?? 0) /
    (kCapitalRecoveryYears * kGameYearSec);

/// Engineering hours one unit of [good] made by a [type] plant needs.
double engineeringHoursPerUnit(String type, String good) =>
    kPlantOverheads[type]?.engineeringHoursPerUnit[good] ?? 0;

/// The engineering worker-seconds one unit of [good] made by [type] needs.
double engineeringWorkerSecondsPerUnit(String type, String good) =>
    engineeringHoursPerUnit(type, good) * kWorkerSecondsPerHour;

/// The overhead engineers a [type] plant keeps busy at nameplate: its
/// engineering worker-seconds per colony second, i.e. full-time jobs. The
/// firm employs them off the floor; the corporate-tax ceiling counts them
/// with the floor's jobs (`city_economy.dart`).
double overheadJobsOf(String type) {
  final o = kPlantOverheads[type];
  final spec = _specOf(type);
  if (o == null || spec == null) return 0;
  var jobs = 0.0;
  for (final g in o.engineeringHoursPerUnit.keys.toList()..sort()) {
    jobs += (spec.outputs[g] ?? 0) * engineeringWorkerSecondsPerUnit(type, g);
  }
  return jobs;
}

/// The share of a plant's per-second cost borne by its output [good]: by
/// FIXED Earth-value weights, exactly as the cost solve splits a joint
/// product (`local_prices.dart`), so the books and the price agree.
double outputShare(CityBuildingSpec s, String good) {
  var weightSum = 0.0;
  for (final e in s.outputs.entries) {
    weightSum += e.value * earthPrice(e.key);
  }
  final v = s.outputs[good];
  if (v == null) return 0;
  return weightSum > 0 ? v * earthPrice(good) / weightSum : 1 / s.outputs.length;
}

/// Tooling recovered on one unit of [good], credits: the maker's
/// [toolingRecoveryPerS] times [good]'s share, over its nameplate rate.
/// Zero for a good no overhead plant makes.
double toolingPerUnit(String good) {
  final type = overheadMakerOf(good);
  final spec = type == null ? null : _specOf(type);
  if (type == null || spec == null) return 0;
  final rate = spec.outputs[good] ?? 0;
  if (!(rate > 0)) return 0;
  return toolingRecoveryPerS(type) * outputShare(spec, good) / rate;
}

/// Engineering worker-seconds one unit of [good] carries when made by its
/// overhead plant; zero for any other good.
double engineeringWorkerSecondsOf(String good) {
  final type = overheadMakerOf(good);
  return type == null ? 0 : engineeringWorkerSecondsPerUnit(type, good);
}

/// The overhead plant that makes [good], or null. First in key order, so a
/// lookup is deterministic (today no two overhead plants share a good).
String? overheadMakerOf(String good) => _makerOf[good];

final Map<String, String> _makerOf = () {
  final m = <String, String>{};
  for (final type in kPlantOverheads.keys.toList()..sort()) {
    final spec = _specOf(type);
    if (spec == null) continue;
    for (final g in spec.outputs.keys) {
      m.putIfAbsent(g, () => type);
    }
  }
  return m;
}();

CityBuildingSpec? _specOf(String type) {
  for (final s in kUtilCatalog) {
    if (s.type == type) return s;
  }
  return null;
}

/// The overhead a period of shipments books, credits: tooling recovered on
/// every unit shipped, and its engineering hours at the cheaper of
/// [book]'s engineering wage and Earth's ([engineeringWagePerS]).
({double tooling, double engineering}) overheadBooked(
  Map<String, double> shipped,
  PriceBook book,
) {
  var tooling = 0.0, engineering = 0.0;
  final engWage = engineeringWagePerS(book.wageOf(SkillTier.engineering));
  for (final g in shipped.keys.toList()..sort()) {
    final u = shipped[g]!;
    tooling += u * toolingPerUnit(g);
    engineering += u * engineeringWorkerSecondsOf(g) * engWage;
  }
  return (tooling: tooling, engineering: engineering);
}
