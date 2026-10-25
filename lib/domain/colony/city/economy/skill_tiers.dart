// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Which skill every job needs, and what each skill is paid over the cost of
/// living (docs/plans/dynamic-markets.md phase 3, the labour market).
///
/// Before this every worker in a colony cost the same wage: the subsistence
/// basket plus marked-up housing (`local_prices.dart`). A rocket-parts
/// assembler cost what a farm hand cost, so nothing made skilled goods dear
/// to make, and nothing a school did showed up in any plant's books.
///
/// **Tiers.** Every job is one [SkillTier]:
/// - a flat building (a [CityBuildingSpec]) needs ONE tier for all its jobs,
///   by type ([kSpecTier]);
/// - a factory floor's jobs are split by role ([labourProfileOf]): each
///   station's crew needs its RECIPE's tier ([tierOfRecipe]), every handler
///   operator (walkers, jack, forklift and crane drivers) is skilled, and
///   every maintenance share (a technician minding an automated station) is
///   technical.
///
/// **Wages.** A tier's ANCHOR wage is the cost of living times its skill
/// multiple ([kSkillWageMultiple]); the labour market moves its actual wage
/// around that anchor by supply against demand (`labour_market.dart`). The
/// cost solve, the P&L and a firm's investment sums all charge a plant its
/// jobs at the tier wages its profile ([labourSharesOf]) says.
///
/// Pure and deterministic: tables and a cache keyed by plant type.
library;

import '../factory/factory_catalog.dart';
import '../factory/factory_entities.dart';
import '../factory/factory_handling.dart';
import '../factory/factory_recipe.dart';
import '../factory/factory_templates.dart';
import '../factory/floor_blueprint.dart';
import 'economy_contracts.dart';

/// Each tier's wage at equilibrium, as a multiple of the cost-of-living wage
/// (the unskilled anchor). From the ratios of real median wages (US BLS,
/// 2020s): labourers and packers ~$18/h, trades (welders, machinists,
/// operators) ~$25/h (1.4×), technicians and associate professionals
/// ~$32/h (1.8×), engineers ~$50/h (2.8×).
const Map<SkillTier, double> kSkillWageMultiple = {
  SkillTier.unskilled: 1.0,
  SkillTier.skilled: 1.4,
  SkillTier.technical: 1.8,
  SkillTier.engineering: 2.8,
};

/// [tier]'s skill multiple.
double skillMultipleOf(SkillTier tier) => kSkillWageMultiple[tier]!;

/// The tier each flat building type's jobs need. A type not listed is
/// [SkillTier.unskilled] (shops, homes' odd jobs, sheds): only training a
/// job demands moves it up.
///
/// - **Engineering:** the advanced plants (electronics, rocket parts,
///   vehicle assembly, missiles), data centres, fission and fusion reactors,
///   and the planet-scale terraforming machines.
/// - **Technical:** process and lab plants (refinery, chemist, pharma,
///   lab-grown meat), clinics, hospitals and schools, the precision Arms
///   Factory, spaceports, airfields, silos and early warning, the business
///   district, and the environmental plants (sequestrator, regolith baker,
///   greenhouse factory, solar thermal).
/// - **Skilled:** heavy industry (the Steel Mill and every zoned industrial
///   tier), generators, recyclers and sewage, police, emergency and military
///   crews, freight yards and railway stations, crematoria, the mall, and
///   the life-support plants that are operated rather than engineered:
///   electrolysis, air harvesters and the water plant. Skilled, not
///   technical, on purpose: every off-world wage is built from those
///   plants' own labour (`local_prices.dart`: labour's share of the
///   subsistence basket must stay well below one or a dry site's oxygen and
///   food pin at the import ceiling), and at the technical 1.8× a barren
///   lunar site's oxygen reached $95/kg, past the $80 a working electrolysis
///   colony should pay.
/// - **Unskilled:** mining and quarrying (one type, `mine`), farming
///   (hydroponics too: planting and harvesting racks indoors is farm work;
///   at skilled 1.4× a barren Martian colony's food rose to an eighth of
///   its landed price, no longer the far-below a grown colony should see),
///   the aquifer pump, landfill, cemeteries, morgues, shops, transit stops,
///   warehouses, bunkers and the Rations Plant's food packing.
const Map<String, SkillTier> kSpecTier = {
  // Engineering.
  'electronics': SkillTier.engineering,
  'rocketfactory': SkillTier.engineering,
  'assembly': SkillTier.engineering,
  'missilefactory': SkillTier.engineering,
  'datacenter': SkillTier.engineering,
  'reactor': SkillTier.engineering,
  'fusion': SkillTier.engineering,
  'terraformer': SkillTier.engineering,
  'retentionarray': SkillTier.engineering,
  // Technical.
  'refinery': SkillTier.technical,
  'chemist': SkillTier.technical,
  'pharma': SkillTier.technical,
  'labmeat': SkillTier.technical,
  'clinic': SkillTier.technical,
  'hospital': SkillTier.technical,
  'school': SkillTier.technical,
  'gunfactory': SkillTier.technical,
  'spaceport': SkillTier.technical,
  'airfield': SkillTier.technical,
  'silo': SkillTier.technical,
  'warning': SkillTier.technical,
  'c-high': SkillTier.technical,
  'sequestrator': SkillTier.technical,
  'regolithbaker': SkillTier.technical,
  'greenhousefactory': SkillTier.technical,
  'solarthermal': SkillTier.technical,
  // Skilled.
  'steelmill': SkillTier.skilled,
  'i-low': SkillTier.skilled,
  'i-med': SkillTier.skilled,
  'i-high': SkillTier.skilled,
  'gas': SkillTier.skilled,
  'recycler': SkillTier.skilled,
  'sewage': SkillTier.skilled,
  'police': SkillTier.skilled,
  'emergency': SkillTier.skilled,
  'barracks': SkillTier.skilled,
  'base': SkillTier.skilled,
  'gunemplacement': SkillTier.skilled,
  'freightyard': SkillTier.skilled,
  'station': SkillTier.skilled,
  'crematorium': SkillTier.skilled,
  'c-med': SkillTier.skilled,
  'electrolysis': SkillTier.skilled,
  'o2harvester': SkillTier.skilled,
  'water': SkillTier.skilled,
  // Unskilled (listed for the record; the default anyway).
  'mine': SkillTier.unskilled,
  'farm': SkillTier.unskilled,
  'farm-big': SkillTier.unskilled,
  'hydroponics': SkillTier.unskilled,
  'aquifer': SkillTier.unskilled,
  'landfill': SkillTier.unskilled,
  'cemetery': SkillTier.unskilled,
  'morgue': SkillTier.unskilled,
  'c-low': SkillTier.unskilled,
  'transit': SkillTier.unskilled,
  'warehouse': SkillTier.unskilled,
  'bunker': SkillTier.unskilled,
  'rationsfactory': SkillTier.unskilled,
};

/// The tier a building of [type] needs.
SkillTier tierOfType(String type) => kSpecTier[type] ?? SkillTier.unskilled;

/// Recipe-id prefixes that name their plant by another word than its spec
/// type (`steel:smelt` belongs to the Steel Mill).
const Map<String, String> kRecipePrefixPlant = {'steel': 'steelmill'};

/// The tier a station running [recipe] needs: the tier of the plant whose
/// recipe it is (its id's prefix, `rocketfactory:assemble`), adjusted for
/// the kind of station:
/// - packers and unpackers are always unskilled: filling a crate is the
///   same job whatever is in it;
/// - smelters, furnaces, presses and mills are machine tending, never more
///   than technical: a press in the missile plant cuts tube, it doesn't
///   design guidance;
/// - assemblers and chemical stations need the plant's full tier: they ARE
///   the skilled work (wiring avionics, compounding a drug, casting a motor).
///
/// A recipe whose prefix names no plant uses [plantType]'s tier, else
/// skilled (a machine operator).
SkillTier tierOfRecipe(FactoryRecipe recipe, {String? plantType}) {
  final cut = recipe.id.indexOf(':');
  final prefix = cut > 0 ? recipe.id.substring(0, cut) : '';
  final plant = kRecipePrefixPlant[prefix] ?? prefix;
  final SkillTier base;
  if (kSpecTier.containsKey(plant)) {
    base = kSpecTier[plant]!;
  } else if (plantType != null && kSpecTier.containsKey(plantType)) {
    base = kSpecTier[plantType]!;
  } else {
    base = SkillTier.skilled;
  }
  return switch (recipe.station) {
    StationKind.packer || StationKind.unpacker => SkillTier.unskilled,
    StationKind.smelter ||
    StationKind.furnace ||
    StationKind.press ||
    StationKind.mill =>
      base.index > SkillTier.technical.index ? SkillTier.technical : base,
    StationKind.assembler || StationKind.chem => base,
  };
}

/// The tier handler operators need: a trade (driving a forklift, slinging a
/// crane load).
const SkillTier kHandlerTier = SkillTier.skilled;

/// The tier a maintenance share needs: a technician.
const SkillTier kMaintenanceTier = SkillTier.technical;

/// Jobs by tier at full staffing of [bp]: each machine's crew at its
/// recipe's tier, its maintenance share technical, every handler operator
/// skilled. The same jobs [FloorBlueprint.jobDemand] counts, split by tier.
Map<SkillTier, double> labourProfileOf(FloorBlueprint bp) {
  ensureFactoryCatalog(); // the recipes a station names
  final jobs = <SkillTier, double>{};
  void add(SkillTier t, double n) {
    if (n > 0) jobs[t] = (jobs[t] ?? 0) + n;
  }

  for (final p in bp.placements) {
    if (p.kind != EntityKind.machine) continue;
    final id = p.recipe;
    final r = id == null ? null : FactoryRecipes.byId(id);
    final tier = r == null
        ? (bp.plantType == null ? SkillTier.skilled : tierOfType(bp.plantType!))
        : tierOfRecipe(r, plantType: bp.plantType);
    add(tier, p.crew.workers.toDouble());
    add(kMaintenanceTier, p.crew.maintenance);
  }
  for (final k in HandlerKind.values) {
    add(
      kHandlerTier,
      ((bp.roster[k] ?? 0) * kHandlerSpecs[k]!.operators).toDouble(),
    );
  }
  return jobs;
}

/// [jobs] normalised to shares summing to one, in tier order; empty when
/// there are no jobs.
Map<SkillTier, double> sharesOf(Map<SkillTier, double> jobs) {
  var total = 0.0;
  for (final t in SkillTier.values) {
    total += jobs[t] ?? 0;
  }
  if (!(total > 0)) return const {};
  return {
    for (final t in SkillTier.values)
      if ((jobs[t] ?? 0) > 0) t: jobs[t]! / total,
  };
}

/// Each floor plant type's template labour shares, built once.
final Map<String, Map<SkillTier, double>> _templateShares = {
  for (final t in kFactoryPlantTypes)
    t: () {
      final bp = factoryTemplateFor(t);
      final s = bp == null
          ? const <SkillTier, double>{}
          : sharesOf(labourProfileOf(bp));
      return s.isEmpty ? {tierOfType(t): 1.0} : s;
    }(),
};

/// The share of a building of [type]'s jobs in each tier: a floor plant
/// type's template profile (what the cost solve charges a floor plant, as it
/// charges its template's equipment wear), any other type all in its one
/// tier.
Map<SkillTier, double> labourSharesOf(String type) =>
    _templateShares[type] ?? {tierOfType(type): 1.0};

/// Average multiple of the cost-of-living wage one job with [shares] costs,
/// at the labour market's [ratio]s (a tier not listed at its anchor):
/// Σ share × skill multiple × ratio.
double wageMultipleOf(
  Map<SkillTier, double> shares, [
  Map<SkillTier, double> ratio = const {},
]) {
  var m = 0.0;
  for (final t in SkillTier.values) {
    final s = shares[t];
    if (s == null || !(s > 0)) continue;
    m += s * skillMultipleOf(t) * (ratio[t] ?? 1.0);
  }
  return m;
}
