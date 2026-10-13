// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's factory floors: the `CitySim` side of
/// docs/plans/factory-floors.md (phase 3, "Colony integration").
///
/// `CitySim` holds the state ([CitySim.factoryFloors],
/// [CitySim.selectedFloorBlueprint], [CitySim.pendingFloorInvestment]) and
/// calls in from its placement, demolition, rename, save and tick paths;
/// the rules live here so `city_sim.dart` carries one line per hook.
///
/// **Which sites get a floor.** Only a player-placed plant whose type ships a
/// template ([kFactoryPlantTypes]): never a zoned lot (user decision,
/// 2026-10-12). A grown industrial block levels up and is torn down without
/// the player's say; a floor designed there could vanish under them.
///
/// **No regression by construction.** A plant gets its TEMPLATE floor by
/// default, and the template's rates are SEEDED from the spec's own flat
/// rate ([flatRatesOf]) rather than measured: the template's measured rate is
/// only within 5% of the spec, and seeding makes a fresh plant (or an old
/// save's plant, back-filled on load) produce exactly what it always did.
/// Only a DESIGNED floor is measured, and until then it runs on the same
/// seeded rates.
///
/// **One driver.** The colony steps every floor, live or not, once per tick
/// through `FactoryFloors.stepAggregate`; the editor screen is opened with
/// `drivesSim: false` and only watches. Two drivers would run a live floor
/// twice as fast and split its ledger.
library;

import 'city_building_spec.dart';
import 'city_economy.dart';
import 'city_sim.dart';
import 'economy/colony_economy.dart';
import 'factory/city_factory_port.dart';
import 'factory/factory_capex.dart';
import 'factory/factory_floor.dart';
import 'factory/factory_floors.dart';
import 'factory/factory_handling.dart';
import 'factory/factory_sim_api.dart';
import 'factory/factory_templates.dart';
import 'factory/factory_unlocks.dart';
import 'factory/floor_blueprint.dart';
import 'economy/local_prices.dart' show kKjPerPowerUnitS;

/// [kFactoryPlantTypes] as a set, for the per-tick membership test.
final Set<String> kFactoryPlantTypeSet = {...kFactoryPlantTypes};

/// Whether [spec] is a placed plant that carries a factory floor.
bool isFloorPlant(CityBuildingSpec spec) =>
    kFactoryPlantTypeSet.contains(spec.type);

/// Nominal "measured seconds" stamped on seeded rates. Any value > 0 marks
/// them usable (`MeasuredRates.seconds == 0` means never measured, and such
/// a floor moves nothing); 1 s says plainly that nothing was measured.
const double kSeededRatesSeconds = 1;

/// Population at which each factory unlock tier opens, matching the
/// colony's milestone tiers (`city_progression.dart`): Settlement (120, the
/// Steel Mill's own unlock) brings pallet jacks and one-operator stations;
/// Small Town (300, heavy industry) forklifts and overhead cranes; City (600,
/// compute and research) AGVs and lights-out stations. Hands and manual
/// stations are always open.
const double kUnlockPalletJackPop = 120;
const double kUnlockForkliftPop = 300;
const double kUnlockAutomationPop = 600;

/// The spec's flat recipe as steady-state floor rates: its inputs and
/// outputs per second, its jobs, and its power draw in kW (one power unit is
/// one MW: `kKjPerPowerUnitS` kJ per unit-second).
MeasuredRates flatRatesOf(CityBuildingSpec spec) => MeasuredRates(
  inPerS: Map.of(spec.inputs),
  outPerS: Map.of(spec.outputs),
  powerKw: spec.powerDraw * kKjPerPowerUnitS,
  jobs: spec.jobs.toDouble(),
  seconds: kSeededRatesSeconds,
);

/// What closing a floor's editor changed, for the economy to settle.
class FloorEditOutcome {
  const FloorEditOutcome({
    required this.record,
    required this.capexBefore,
    required this.capexAfter,
  });

  /// The record after closing (null: the site has no floor).
  final FloorRecord? record;

  /// Build cost of the layout before and after the edit, in ore.
  final double capexBefore, capexAfter;

  /// Ore the edit costs (negative: kit sold off). Also added to
  /// [CitySim.pendingFloorInvestment].
  double get capexDelta => capexAfter - capexBefore;
}

extension CityFactories on CitySim {
  /// What the colony may hire and set on its floors, from its population
  /// milestones (see [kUnlockPalletJackPop]); everything under the
  /// unlock cheat ([CitySim.ignoreUnlocks]).
  FactoryUnlocks get factoryUnlocks {
    if (ignoreUnlocks) return FactoryUnlocks.all;
    final handlers = {HandlerKind.onFoot};
    final modes = {MachineMode.manual};
    if (population >= kUnlockPalletJackPop) {
      handlers.add(HandlerKind.palletJack);
      modes.add(MachineMode.assisted);
    }
    if (population >= kUnlockForkliftPop) {
      handlers
        ..add(HandlerKind.forklift)
        ..add(HandlerKind.crane);
    }
    if (population >= kUnlockAutomationPop) {
      handlers.add(HandlerKind.agv);
      modes.add(MachineMode.automated);
    }
    return FactoryUnlocks(handlers: handlers, modes: modes);
  }

  // ---- blueprint choice and cost -----------------------------------------

  /// The designed blueprint the player picked for new [plantType] plants (a
  /// copy from the library), or null for the template. A pick whose library
  /// entry was deleted, or drawn for another plant, reads as no pick.
  FloorBlueprint? floorBlueprintFor(String plantType) {
    final name = selectedFloorBlueprint[plantType];
    if (name == null) return null;
    final bp = factoryFloors.blueprintNamed(name);
    if (bp == null) return null;
    final drawnFor = bp.plantType;
    if (drawnFor != null && drawnFor != plantType) return null;
    return bp;
  }

  /// Picks the library blueprint [name] for new [plantType] plants; null
  /// goes back to the template.
  void selectFloorBlueprint(String plantType, String? name) {
    if (name == null) {
      selectedFloorBlueprint.remove(plantType);
    } else {
      selectedFloorBlueprint[plantType] = name;
    }
  }

  /// Ore placing [spec] costs: the chosen designed floor's capex, or the
  /// spec's own build cost. The template uses `buildCost` verbatim (its
  /// capex is calibrated to within 10% of it, not equal), so a colony that
  /// never designs a floor pays exactly what it always did.
  double buildCostOf(CityBuildingSpec spec) {
    if (!isFloorPlant(spec)) return spec.buildCost;
    final bp = floorBlueprintFor(spec.type);
    return bp == null ? spec.buildCost : capexOf(bp).total;
  }

  /// Why [spec] can't be placed with the chosen blueprint: its hall is wider
  /// or deeper than the plant's site. Null when it fits or the template is
  /// used.
  String? floorBlueprintRefusal(CityBuildingSpec spec) {
    if (!isFloorPlant(spec)) return null;
    final bp = floorBlueprintFor(spec.type);
    if (bp == null) return null;
    final site = spec.siteMetres(cellM: CitySim.cellM);
    if (bp.hall.widthM <= site.width && bp.hall.depthM <= site.depth) {
      return null;
    }
    return 'The ${bp.name} floor (${bp.hall.widthM.round()} × '
        '${bp.hall.depthM.round()} m) does not fit a ${spec.label} site '
        '(${site.width.round()} × ${site.depth.round()} m).';
  }

  // ---- records ------------------------------------------------------------

  /// Gives a just-placed [spec] at [site] its floor: the chosen designed
  /// blueprint (dirty, so the runner measures it) or the template, both
  /// running on the spec's flat rates until measured. Any other spec clears
  /// whatever floor the site held.
  void assignFloorFor(String site, CityBuildingSpec spec) {
    if (!isFloorPlant(spec)) {
      floorSiteGone(site);
      return;
    }
    final seeded = flatRatesOf(spec);
    final designed = floorBlueprintFor(spec.type);
    if (designed != null) {
      factoryFloors.assign(site, designed, designed: true, rates: seeded)
          .dirty = true;
    } else {
      final template = factoryTemplateFor(spec.type);
      if (template == null) return;
      factoryFloors.assign(site, template, rates: seeded);
    }
    // Run by a firm or the state, as the colony's economy has it.
    ensureFloorOwner(site);
  }

  /// Squares the floors with what stands: every built floor plant without a
  /// record gets its template (an old save, a plant placed by a path that
  /// predates floors), and a record whose site holds no floor plant goes.
  /// Run after load, so loading an old colony changes nothing.
  void reconcileFactoryFloors() {
    final live = <String, CityBuildingSpec>{};
    for (final e in utils.entries) {
      if (isFloorPlant(e.value)) live[CitySim.siteIdOfCell(e.key)] = e.value;
    }
    for (final e in parcelBuildings.entries) {
      if (isFloorPlant(e.value)) live[e.key] = e.value;
    }
    for (final id in factoryFloors.siteIds) {
      if (!live.containsKey(id)) floorSiteGone(id);
    }
    for (final id in (live.keys.toList()..sort())) {
      if (factoryFloors[id] != null) continue;
      final template = factoryTemplateFor(live[id]!.type);
      if (template != null) {
        factoryFloors.assign(id, template, rates: flatRatesOf(live[id]!));
      }
    }
    // Every floor has an owner, and no books outlive their plant.
    for (final id in factoryFloors.siteIds) {
      ensureFloorOwner(id);
    }
    final e = colonyEconomy;
    for (final id in {...e.books.keys, ...e.throttle.keys, ...e.stashed.keys,
        for (final o in e.offers) o.site}.toList()..sort()) {
      if (factoryFloors[id] == null) e.dropSite(id);
    }
  }

  /// Carries [oldId]'s floor and its colony-side state onto [newId].
  void floorSiteRenamed(String oldId, String newId) {
    if (oldId == newId) return;
    factoryFloors.rename(oldId, newId);
    final due = pendingFloorInvestment.remove(oldId);
    if (due != null) pendingFloorInvestment[newId] = due;
    final bank = floorValueBank.remove(oldId);
    if (bank != null) floorValueBank[newId] = bank;
    colonyEconomy.renameSite(oldId, newId);
  }

  /// Drops [site]'s floor and its colony-side state (the plant is gone).
  void floorSiteGone(String site) {
    factoryFloors.remove(site);
    pendingFloorInvestment.remove(site);
    floorValueBank.remove(site);
    colonyEconomy.dropSite(site);
  }

  /// Whether [site]'s floor was designed (not the template): demolishing it
  /// loses the design, so the UI asks first.
  bool floorIsDesigned(String site) => factoryFloors[site]?.designed ?? false;

  // ---- editor ---------------------------------------------------------------

  /// Opens [site]'s floor at full fidelity for the editor, built with the
  /// colony's [factoryUnlocks]. The colony keeps stepping it (open the
  /// screen with `drivesSim: false`). Null when the site has no floor.
  FactorySim? openFloor(String site) => factoryFloors.open(
    site,
    (bp) => FactoryFloor.fromBlueprint(bp, unlocks: factoryUnlocks),
  );

  /// Closes [site]'s editor. An edited layout becomes designed and dirty
  /// (the runner re-measures it); its change in build cost is added to
  /// [CitySim.pendingFloorInvestment] for the economy to settle.
  FloorEditOutcome closeFloor(String site) {
    final rec = factoryFloors[site];
    if (rec == null) {
      return const FloorEditOutcome(
        record: null,
        capexBefore: 0,
        capexAfter: 0,
      );
    }
    final before = capexOf(rec.blueprint).total;
    // The layout an unpaid edit falls back to (`settleFloorInvestment`).
    final stash = FloorEditStash(
      blueprint: rec.blueprint.copy(),
      rates: rec.rates,
      designed: rec.designed,
    );
    final rev = rec.rev;
    factoryFloors.close(site);
    if (rec.rev != rev) stashFloorEdit(site, stash);
    final after = capexOf(rec.blueprint).total;
    final delta = after - before;
    if (delta.abs() > 1e-9) {
      pendingFloorInvestment[site] =
          (pendingFloorInvestment[site] ?? 0) + delta;
    }
    return FloorEditOutcome(
      record: rec,
      capexBefore: before,
      capexAfter: after,
    );
  }

  // ---- measurement ----------------------------------------------------------

  /// Floors whose rates are stale and not open, sorted: the runner's queue.
  /// Measure `factoryFloors[id]!.blueprint`, hand back `rev`.
  List<String> get floorsNeedingMeasure => factoryFloors.needsMeasure;

  /// Stores [rates] measured for [site]; a result for an older layout
  /// ([rev] no longer the record's) is dropped. True when stored.
  ///
  /// A stored result for an edited floor settles the edit's cost
  /// ([CityEconomy.settleFloorInvestment]): only now is it known what the
  /// edit saves, which is what a private firm decides on.
  bool applyFloorMeasure(String site, MeasuredRates rates, {int? rev}) {
    final old = factoryFloors[site]?.rates;
    if (!factoryFloors.applyMeasured(site, rates, rev: rev)) return false;
    if (old != null) settleFloorInvestment(site, old);
    return true;
  }

  // ---- colony tick ----------------------------------------------------------

  /// Steps [site]'s floor ([spec] stands there) for [dt] against the colony.
  ///
  /// [powerShare] / [staffingShare] are the colony's throttles for the plant
  /// (see `advance`); [stockCap] is the tick's cached cap. The plant's
  /// reward-cap bank accrues `1.5 × flat value × dt` first, capped at
  /// [kFloorValueBankSeconds] of it, and keeps what the step leaves.
  FloorStepReport stepFloorSite(
    String site,
    CityBuildingSpec spec,
    double dt, {
    required double stockCap,
    required double powerShare,
    required double staffingShare,
  }) {
    final capPerS = kFloorRewardCap * flatOutputValuePerS(spec.outputs);
    final banked = (floorValueBank[site] ?? 0) + capPerS * dt;
    final ceiling = capPerS * kFloorValueBankSeconds;
    // A firm's idled stations or closed plant (`city_economy.dart`).
    final ft = floorThrottleOf(site);
    final port = CityFactoryPort(
      stock: stock,
      stockCap: stockCap,
      powerShare: powerShare * ft,
      staffingShare: staffingShare * ft,
      valueAllowance: banked < ceiling ? banked : ceiling,
      outputMult: (c) => biomeMult(c) * bountyMult * eventProductionMult,
    );
    final report = factoryFloors.stepAggregate(dt, site, port);
    floorValueBank[site] = port.valueAllowance > 0 ? port.valueAllowance : 0;
    return report;
  }
}
