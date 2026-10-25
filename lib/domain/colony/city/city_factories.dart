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

/// Each template's power draw as the floor model measures it, kW, under
/// [measureSettingsFor] (re-measured and pinned by
/// `colony_floor_power_test.dart`).
///
/// The floor's stations draw REAL per-machine kilowatts (a smelter, a press,
/// a pick-and-place line), while a spec's `powerDraw` is the colony's own
/// power unit, sized for the city builder's grid and an order of magnitude
/// or two above what the machines on the floor add up to. Stored raw, any
/// measured floor (a belt moved, or a firm's layoff re-measuring a template
/// the player never touched) would cut its plant's colony draw 8-100x:
/// far outside the "a designed floor may beat its template" lever, and
/// unbounded by the 1.5x cap, which only bounds output value.
const Map<String, double> kTemplateMeasuredKw = {
  // Re-pinned for the port layout (#19): one automated smelter a line.
  'steelmill': 3986.887,
  'refinery': 4063.818,
  'electronics': 739.688,
  'rocketfactory': 470.933,
  'gunfactory': 394.452,
  'missilefactory': 734.496,
  'rationsfactory': 117.2,
};

/// Colony kW per floor-model kW for [spec]'s plant: the factor that makes its
/// template measure exactly its spec draw, so a design that halves its
/// stations' kilowatts halves the plant's draw on the grid. 1 for a plant
/// without a pinned template.
double floorPowerCalibration(CityBuildingSpec spec) {
  final kw = kTemplateMeasuredKw[spec.type];
  if (kw == null || !(kw > 0)) return 1;
  return spec.powerDraw * kKjPerPowerUnitS / kw;
}

/// [rates] with the power scaled into [spec]'s colony units
/// ([floorPowerCalibration]).
MeasuredRates calibratedFloorRates(
  MeasuredRates rates,
  CityBuildingSpec spec,
) => MeasuredRates(
  inPerS: rates.inPerS,
  outPerS: rates.outPerS,
  powerKw: rates.powerKw * floorPowerCalibration(spec),
  jobs: rates.jobs,
  seconds: rates.seconds,
);

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
    return FactoryUnlocks(
        handlers: handlers,
        modes: modes,
        // Goods not invented here yet: no recipe may make or use one
        // (docs/plans/dynamic-markets.md phase 2).
        uninvented: colonyEconomy.tech.unavailableHere);
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
  ///
  /// It also refuses to let a record run the wrong plant: one drawn for
  /// another plant type (an id that came to name a different building) is
  /// dropped and replaced by this plant's template. And a TEMPLATE record
  /// (never designed, never cut by a layoff) is re-seeded from today's
  /// template and spec, so a save made before a balance change runs the
  /// template at today's flat rate, as the user's rule has it.
  void reconcileFactoryFloors() {
    final live = <String, CityBuildingSpec>{};
    for (final e in utils.entries) {
      if (isFloorPlant(e.value)) live[CitySim.siteIdOfCell(e.key)] = e.value;
    }
    for (final e in parcelBuildings.entries) {
      if (isFloorPlant(e.value)) live[e.key] = e.value;
    }
    for (final id in factoryFloors.siteIds) {
      final spec = live[id];
      final rec = factoryFloors[id]!;
      final drawnFor = rec.blueprint.plantType;
      if (spec == null || (drawnFor != null && drawnFor != spec.type)) {
        floorSiteGone(id);
      }
    }
    for (final id in (live.keys.toList()..sort())) {
      final spec = live[id]!;
      final rec = factoryFloors[id];
      if (rec != null) {
        final laidOff = colonyEconomy.laidOff[id];
        if (!rec.designed &&
            rec.live == null &&
            (laidOff == null || laidOff.isEmpty)) {
          final template = factoryTemplateFor(spec.type);
          if (template != null) {
            // In place: the record keeps its owner and its day's books.
            rec
              ..blueprint = template
              ..rates = flatRatesOf(spec)
              ..dirty = false
              ..rev += 1;
          }
        }
        continue;
      }
      final template = factoryTemplateFor(spec.type);
      if (template != null) {
        factoryFloors.assign(id, template, rates: flatRatesOf(spec));
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

  /// Every site id any floor-side state is kept under: the records, owed
  /// ore, reward banks and the economy's books, throttles, stashes, layoffs
  /// and offers. Sorted.
  List<String> get floorStateSiteIds {
    final e = colonyEconomy;
    return {
      ...factoryFloors.siteIds,
      ...pendingFloorInvestment.keys,
      ...floorValueBank.keys,
      ...e.books.keys,
      ...e.throttle.keys,
      ...e.stashed.keys,
      ...e.laidOff.keys,
      ...e.lastPnl.keys,
      for (final o in e.offers) o.site,
    }.toList()..sort();
  }

  /// Carries every GRID floor across a renumbering of the grid's cells
  /// (`expandLand`): a grid site id embeds its cell, so every `cell-N` id
  /// changes. [rekeyCell] maps an old cell to its new one; it must be
  /// injective and never decrease a cell, which growing the grid by rows
  /// guarantees.
  ///
  /// Moved in DESCENDING cell order: a move replaces whatever is at its
  /// target ([FactoryFloors.rename]), and with new >= old the only ids a
  /// target could collide with are ones larger than its source, which have
  /// already moved on. Ascending, a plant moving onto another's old id
  /// would overwrite a record that had not moved yet, and the second plant
  /// would come to run the first one's blueprint.
  void rekeyGridFloors(int Function(int cell) rekeyCell) {
    final moves = <(int, String)>[
      for (final id in floorStateSiteIds)
        if (CitySim.cellOfSiteId(id) case final c?) (c, id),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    for (final (cell, id) in moves) {
      floorSiteRenamed(id, CitySim.siteIdOfCell(rekeyCell(cell)));
    }
  }

  /// Ore a demolished plant at [site] ([spec] stood there) was worth, before
  /// the bulldozer's refund fraction: what was really paid for it. A
  /// designed floor cost its capex ([buildCostOf]), less any edit still
  /// unpaid; a template, or a plant without a floor, the spec's own build
  /// cost. Refunding the nameplate for a cheap design would print ore on
  /// every place-and-bulldoze.
  double floorBuildValueOf(String site, CityBuildingSpec spec) {
    final rec = factoryFloors[site];
    if (rec == null || !rec.designed) return spec.buildCost;
    final owed = pendingFloorInvestment[site] ?? 0;
    final paid = capexOf(rec.currentBlueprint).total - (owed > 0 ? owed : 0);
    return paid > 0 ? paid : 0;
  }

  /// A placed plant's lot lost by something other than the player's
  /// demolish (a road edit's re-plat left it no successor): drops the floor
  /// like [floorSiteGone], and a DESIGNED one says so, since nothing asked
  /// the player first.
  void floorSiteLost(String site) {
    final rec = factoryFloors[site];
    if (rec != null && rec.designed) {
      pushEconomyNotice('The road edit took the lot under the '
          '${rec.blueprint.name} floor: the plant and its design are gone.');
    }
    floorSiteGone(site);
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

  /// The designed floor a clear of grid [cell] would lose: the site id of
  /// the building covering it when that building's floor is designed, else
  /// null. Any covered tile counts, as `clearCell` clears the whole
  /// building from any of them.
  String? designedFloorAtCell(int cell) {
    final site = CitySim.siteIdOfCell(anchorOf(cell) ?? cell);
    return floorIsDesigned(site) ? site : null;
  }

  /// The steady-state rates [spec] at [site] runs on this tick, when its
  /// floor runs it (a template's are the spec's own, seeded); null when it
  /// runs on the spec's flat recipe (no floor, or the kill-switch is off).
  /// What the stock readouts must show for a floor plant, or a designed
  /// floor's real output would read as its nameplate.
  MeasuredRates? floorRatesAt(String site, CityBuildingSpec spec) {
    if (!factoryFloorsEnabled || !isFloorPlant(spec)) return null;
    return factoryFloors[site]?.rates;
  }

  // ---- editor ---------------------------------------------------------------

  /// Opens [site]'s floor at full fidelity for the editor, built with the
  /// colony's [factoryUnlocks]. The colony keeps stepping it (open the
  /// screen with `drivesSim: false`). Null when the site has no floor.
  ///
  /// The live floor books its energy in the colony's units, calibrated like
  /// its measured rates ([floorPowerCalibration]), so the plant's P&L reads
  /// the same with the editor open as closed.
  FactorySim? openFloor(String site) {
    final spec = siteSpec(site);
    return factoryFloors.open(
      site,
      (bp) => FactoryFloor.fromBlueprint(bp, unlocks: factoryUnlocks),
      powerCalibration: spec == null ? 1 : floorPowerCalibration(spec),
    );
  }

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
  ///
  /// [rates] come from the floor model; their power is converted into the
  /// colony's units first ([calibratedFloorRates]).
  bool applyFloorMeasure(String site, MeasuredRates rates, {int? rev}) {
    final old = factoryFloors[site]?.rates;
    final spec = siteSpec(site);
    final colonyRates =
        spec == null ? rates : calibratedFloorRates(rates, spec);
    if (!factoryFloors.applyMeasured(site, colonyRates, rev: rev)) {
      return false;
    }
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
    // The day close's starved-of-staff rule needs to know whether the
    // plant had inputs to work while the labour market gave it no one
    // (`noteFloorStaffing`): read off the stock it is about to be offered.
    final rec = factoryFloors[site];
    if (rec != null && ft > 0) {
      var onHand = true;
      final ins = rec.rates.inPerS;
      for (final c in ins.keys) {
        if ((ins[c] ?? 0) > 0 && !(stockOf(c) > 1e-9)) {
          onHand = false;
          break;
        }
      }
      noteFloorStaffing(site, dt, inputsOnHand: onHand);
    }
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
