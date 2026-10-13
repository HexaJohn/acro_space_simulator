// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The floor every placed plant ships with (docs/plans/factory-floors.md Â§3
/// "Templates", Â§8).
///
/// A template is a built-in [FloorBlueprint] whose MEASURED rate matches
/// the plant's flat `CityBuildingSpec` rate within 5%, so opening a floor
/// never makes a plant worse, and engaging is optional. It is deliberately
/// "fine, not great": most stations are manual, so a designer who
/// automates, shortens the walks or trims the fleet beats it (the Reward
/// levers). And its build cost (`factory_capex.dart`) is the spec's
/// `buildCost`, so placing a templated plant costs what it always did.
///
/// Templates may use ANY handler kind: they are the colony's built-in
/// plants, not purchases, so `FactoryUnlocks` never gates them.
///
/// Phase 1 ships the Steel Mill only; phase 6 adds the rest. Zoned specs
/// never get one (user decision, 2026-10-12), so the site menu's "Factory
/// floor" action can key off `factoryTemplateFor(type) != null`.
///
/// ## The Steel Mill (spec: 2 ore â†’ 1.5 steel + 0.4 tubes /s, 35 jobs)
///
/// A 66 Ã— 56 m hall, two identical lines, a shared tube corner and a
/// forklift aisle down the shipping wall â€” the plan's realistic mix (Â§3
/// "Template plants"): conveyors where freight is steady, people where it
/// is fiddly, a forklift for pallets and a crane over the heavy line.
///
/// * **Ore comes in on a DOCK CONVEYOR.** Each line's receiving dock emits
///   1 ore/s straight onto a belt. Two pallets a second unloaded by hand
///   and forklift into staging would take ~16 forklifts of trips and
///   swamp the 35 jobs, so the template uses the expensive automated dock
///   (Â§3 "Docks are manual by default â€¦ dock conveyors are the upgrade")
///   and `capexOf` charges it as one. A designer who unloads by hand saves
///   that capex and pays in jobs: a real trade, not a free win.
/// * Arms feed two smelters (ore â†’ pig iron + slag) and drop pig iron onto
///   a belt to the furnace. Slag never leaves: an arm from each smelter
///   feeds the press between them, which makes tubes from it.
/// * **Billets are heavy, so a crane moves them.** The furnace and the
///   rolling mill stand end to end under a crane bay; the crane lifts each
///   billet from the furnace to the mill without travelling (its hook sits
///   over the seam). Both stations are ASSISTED: one operator each beside
///   the crane driver.
/// * The mill's bars go by arm to a packer; its steel crates (pallets) wait
///   for a FORKLIFT, which drives them along the aisle to the shipping
///   dock. The forklifts charge at a bay at the aisle's head.
/// * **Tubes are hand work.** Nine workers walk tubes from both presses to
///   the shared tube packer between the lines, crossing belts at
///   crossings. That walk is the template's real handling work, and its
///   slack is a lever. The tube crates ride a belt to their own dock (a
///   forklift fetching them from the middle of the hall would be a full
///   forklift's work), crossing the aisle on crossings.
///
/// Jobs: 9 manual stations Ã— 2 + 4 assisted Ã— 1 + 9 walkers + 2 forklift
/// drivers + 2 crane drivers = 35, the spec's count.
library;

import 'factory_catalog.dart';
import 'factory_entities.dart';
import 'factory_grid.dart';
import 'factory_handling.dart';
import 'floor_blueprint.dart';
import 'template_layout.dart';
import 'factory_measure.dart';
import 'templates/electronics_template.dart';
import 'templates/gunfactory_template.dart';
import 'templates/missilefactory_template.dart';
import 'templates/rationsfactory_template.dart';
import 'templates/refinery_template.dart';
import 'templates/rocketfactory_template.dart';

/// The plant type the Steel Mill template is for (`CityBuildingSpec.type`).
const String kSteelMillType = 'steelmill';

/// Steel Mill hall: 33 Ã— 28 tiles = 66 Ã— 56 m â€” the two lines, the tube
/// corner and a 4 m forklift aisle along the shipping wall, no more (hall
/// area is build cost).
const HallSize kSteelMillHall = HallSize(33, 28);

/// Workers on foot carrying tubes, one at a time, 0.4 tubes/s in all.
/// Measured: eight hold the spec rate, seven fall ~5% short; nine keeps
/// one spare so a busy moment never starves the packer.
const int kSteelMillWalkers = 9;

/// Forklifts clearing steel crates to shipping: 0.15 crates/s, each a
/// one-tile hop from packer to dock, is light work for one, and the second
/// covers the other line and the first one's charging.
const int kSteelMillForklifts = 2;

/// One crane per line's billet bay.
const int kSteelMillCranes = 2;

/// A fresh template blueprint for [plantType], or null when that plant has
/// none (every zoned spec, and every placed plant without a template yet).
FloorBlueprint? factoryTemplateFor(String plantType) {
  ensureFactoryCatalog();
  return switch (plantType) {
    kSteelMillType => _steelMill(),
    kRefineryType => refineryTemplate(),
    kElectronicsType => electronicsTemplate(),
    kRocketPartsType => rocketfactoryTemplate(),
    kArmsType => gunfactoryTemplate(),
    kMissileType => missilefactoryTemplate(),
    kRationsType => rationsfactoryTemplate(),
    _ => null,
  };
}

/// Every plant type that ships a factory floor, in build-menu order. The
/// site menu's "Factory floor" action and the dev entry list these.
const List<String> kFactoryPlantTypes = [
  kSteelMillType,
  kRefineryType,
  kElectronicsType,
  kRocketPartsType,
  kArmsType,
  kMissileType,
  kRationsType,
];

/// How long to run a floor of [plantType] before trusting its rates. Most
/// plants read true under [MeasureSettings.standard]; a plant whose
/// slowest station packs big lumps (a 50-round ammo pallet, a 10-board
/// crate) needs a longer window or one lump either side of the window
/// reads as a 5-10% swing (see each template's doc).
MeasureSettings measureSettingsFor(String plantType) => switch (plantType) {
      kSteelMillType || kRefineryType => kSlowLineMeasureSettings,
      kElectronicsType => kElectronicsMeasureSettings,
      kArmsType => kArmsMeasureSettings,
      _ => MeasureSettings.standard,
    };

/// The Steel Mill's and the Refinery's measurement: five minutes to settle,
/// twenty measured, never cut short. Both fill long tanks and buffers before
/// their slow stations reach their pace (the refinery's cracking column, the
/// mill's slag-to-tube press), so the standard window with its early stop
/// reads the Refinery 22% under its spec (0.31 fuel / 0.23 oxidizer per
/// second against 0.4 / 0.3, while drawing the full 1.0 ore) and the mill's
/// tubes 8% under. A designed or laid-off floor measured that way would burn
/// full input for short output, and its firm's books would follow. Pinned by
/// `template_wiring_test.dart` (every template within 5% of its spec).
const MeasureSettings kSlowLineMeasureSettings = MeasureSettings(
  warmupS: 300,
  windowS: 1200,
  earlyStop: false,
);

/// Hands out placement ids in order, so the template is stable across
/// builds (saves key runtime state by id).
/// x of the forklift aisle's west lane (two tiles wide).
const int _aisleX = 29;

/// x of the shipping docks, on the east wall beyond the aisle.
const int _shipX = 31;

/// One ore-to-steel line with its base row at [y].
void _steelLine(TemplateLayout l, int y, {Set<int> oreCrossings = const {}}) {
  // Ore in on a dock conveyor: dock on the west wall, belt past both
  // smelters.
  l.add(EntityKind.receivingDock, 0, y, item: 'ore');
  l.beltEast(2, 16, y, crossings: oreCrossings);
  l.arm(5, y + 1, Dir4.north);
  l.arm(14, y + 1, Dir4.north);
  // Two smelters with the slag press between them.
  l.machine(4, y + 2, SteelRecipes.smelt);
  l.machine(9, y + 2, SteelRecipes.tube);
  l.machine(13, y + 2, SteelRecipes.smelt);
  l.arm(8, y + 3, Dir4.east); // smelter A â†’ press (takes slag only)
  l.arm(12, y + 3, Dir4.west); // smelter B â†’ press
  // Pig iron to the furnace by belt, with a crossing to the press.
  l.arm(6, y + 6, Dir4.north, only: 'pigIron');
  l.arm(14, y + 6, Dir4.north, only: 'pigIron');
  l.beltEast(6, 15, y + 7, crossings: {10});
  // The heavy line: furnace and mill end to end under one crane bay.
  l.machine(16, y + 7, SteelRecipes.cast, mode: MachineMode.assisted);
  l.machine(20, y + 7, SteelRecipes.roll, mode: MachineMode.assisted);
  l.add(EntityKind.craneBay, 16, y + 7, span: (9, 3));
  // Bars by arm to the packer; its crates wait for a forklift.
  l.arm(25, y + 8, Dir4.east);
  l.machine(26, y + 8, SteelRecipes.packSteel);
  l.add(EntityKind.shippingDock, _shipX, y + 8);
}

FloorBlueprint _steelMill() {
  final l = TemplateLayout();
  _steelLine(l, 2);
  // The tube corner between the lines: walkers bring tubes from both
  // presses; crates leave by arm and belt, crossing the forklift aisle.
  l.machine(9, 12, SteelRecipes.packTubes);
  l.arm(12, 12, Dir4.east);
  l.beltEast(13, _shipX - 1, 12, crossings: {_aisleX, _aisleX + 1});
  l.add(EntityKind.shippingDock, _shipX, 12);
  // The walkers' muster area beside it (where new hires stand).
  l.add(EntityKind.staging, 3, 13, span: (4, 2));
  // The upper line's ore belt gets a crossing on the walk to its press.
  _steelLine(l, 16, oreCrossings: {10});
  // The forklift aisle down the shipping wall, and its charging bay
  // midway between the two lines.
  l.add(EntityKind.aisle, _aisleX, 0, span: (2, kSteelMillHall.h));
  l.add(EntityKind.chargingBay, _shipX, 14);
  return FloorBlueprint(
    name: 'Steel Mill',
    plantType: kSteelMillType,
    hall: kSteelMillHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kSteelMillWalkers,
      HandlerKind.forklift: kSteelMillForklifts,
      HandlerKind.crane: kSteelMillCranes,
    },
  );
}
