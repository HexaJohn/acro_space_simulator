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
/// ## The Steel Mill (spec: 2 ore -> 1.5 steel + 0.4 tubes /s, 35 jobs)
///
/// An 84 x 64 m hall, two identical lines and a shared tube corner, laid for
/// EXPLICIT PORTS (docs/plans/factory-floors.md section 10 item 19,
/// `station_ports.dart`): belts connect at a station's input and output
/// ports, handlers work it at its hand port, and no arm touches a machine.
/// The plan's realistic mix (section 3 "Template plants"): conveyors where
/// freight is steady, people where it is fiddly, a crane for the heavy
/// billets and forklifts for the tube pallets.
///
/// * **Ore comes in on a DOCK CONVEYOR.** Each line's receiving dock on the
///   west wall drops 1 ore/s onto a two-tile belt straight into the
///   smelter's input port (the expensive automated dock, charged as one by
///   `capexOf`; unloading by hand saves capex and costs jobs).
/// * **One lights-out smelter per line.** A port belt feeds one machine and
///   floors have no splitter, so two manual smelters could not share a
///   dock's belt: each line runs one AUTOMATED smelter (1.3 ore/s of
///   capacity against the dock's 1.0). Pig iron leaves its front port by
///   belt into the furnace; slag leaves its top port by belt.
/// * **Billets are heavy, so a crane moves them** without travelling: the
///   furnace (facing east) and the rolling mill (facing west, below it)
///   open their HAND PORTS onto the same floor tile, and the crane over
///   the heavy line hangs its hook there.
/// * The mill's bars leave its west port on a belt into a packer, whose
///   steel crates ride a belt onto a shipping dock on the west wall.
/// * **One slag press for both lines.** The two slag belts merge into the
///   press's input port between the lines (0.5 slag/s against a manual
///   press's 0.6). Its tubes wait at its hand port, and workers carry them
///   ONE tile to the tube packer's hand port: one consumer, so no worker
///   ever walks tubes across the hall to the other line's packer (which
///   two packers did, and which halved the rate). The tube crates wait
///   there on a forklift aisle, and the forklifts drive them to the east
///   wall and charge at a bay off the aisle.
///
/// Jobs: 2 automated smelters x 0.25 + 7 manual stations x 2 + 14 walkers
/// + 2 forklift drivers + 2 crane drivers = 34.5, the spec's 35. The tube
/// walk needs three of the walkers: the rest is the headcount a designer
/// trims (`improved_layout_test.dart`), the template's "fine, not great".
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

/// Steel Mill hall: 42 x 32 tiles = 84 x 64 m: the two lines, the tube
/// corner and its forklift aisle to the east wall, plus open floor east of
/// the tube corner and above the upper line for a designer to grow into.
/// Hall area is build cost, and it is sized so the template's capex is the
/// spec's 40 ore (`capex_test.dart`): the port layout needs fewer stations
/// and no arms, so the old 66 x 56 m shed came to ~33.
const HallSize kSteelMillHall = HallSize(42, 32);

/// Workers on foot carrying tubes from the press's hand port to the tube
/// packer's, a one-tile hop: 0.4 tubes/s is three workers' work. The rest
/// is the spec's headcount on the floor, a designer's lever.
const int kSteelMillWalkers = 14;

/// Forklifts clearing tube crates to shipping: 0.04 crates/s is light work
/// for one; the second covers the other line and the first one's charging.
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

/// x of the tube-crate shipping dock, on the east wall.
const int _shipX = 40;

/// One ore-to-steel line with its lowest row at [b]. Every connection is a
/// port (`station_ports.dart`; the tiles are in the comments):
///
///     row b+8       slag belt off the smelter's top port
///     row b+4..7    ore dock > belt > smelter S > belt > furnace F
///     row b+3       crane hook over (11, b+3), F's and M's hand ports
///                   (the crane bay spans x 8..14, rows b..b+6)
///     row b..2      ship < belt < packer K < belt < rolling mill M
///
/// Its slag leaves the smelter's top port onto (6, b+8); the caller routes
/// it to the shared press.
void _steelLine(TemplateLayout l, int b) {
  // Ore: dock conveyor into the smelter's input port (4, b+5).
  l.add(EntityKind.receivingDock, 0, b + 5, item: 'ore');
  l.beltEast(2, 3, b + 5);
  l.machine(4, b + 4, SteelRecipes.smelt, mode: MachineMode.automated);
  // Pig iron: smelter output 1 (7, b+5) onto (8, b+5), into the furnace's
  // input port (10, b+5).
  l.beltEast(8, 9, b + 5);
  l.machine(10, b + 4, SteelRecipes.cast);
  // The rolling mill faces WEST below the furnace: its hand port (11, b+2)
  // and the furnace's (11, b+4) both open onto (11, b+3), under the hook.
  l.machine(9, b, SteelRecipes.roll, dir: Dir4.west);
  // The runway spans the whole heavy line (7 x 7 tiles over furnace and
  // mill), though the hook only ever works the shared tile.
  l.add(EntityKind.craneBay, 8, b, span: (7, 7));
  // Bars: mill output (9, b+1) west onto (8, b+1), into the west-facing
  // packer's input port (6, b+1); crates out its port (4, b+1) onto a belt
  // into the west-wall shipping dock.
  l.beltRun(8, 7, b + 1, Dir4.west);
  l.machine(4, b + 1, SteelRecipes.packSteel, dir: Dir4.west);
  l.beltRun(3, 2, b + 1, Dir4.west);
  l.add(EntityKind.shippingDock, 0, b + 1);
}

FloorBlueprint _steelMill() {
  final l = TemplateLayout();
  _steelLine(l, 1);
  _steelLine(l, 14);
  // Slag to the shared press's input port (16, 11), fed from (15, 11):
  // the lower line's belt runs along row 10 and turns up into it, the
  // upper line's along row 22 and down column 15 into it (a side merge).
  l.add(EntityKind.belt, 6, 9, dir: Dir4.north);
  l.beltEast(6, 14, 10);
  l.add(EntityKind.belt, 15, 10, dir: Dir4.north);
  l.beltEast(6, 14, 22);
  l.beltRun(22, 12, 15, Dir4.south);
  l.add(EntityKind.belt, 15, 11);
  l.machine(16, 10, SteelRecipes.tube);
  // The tube packer faces south so its hand port (19, 9) opens onto (18, 9),
  // beside the press's (17, 9): a worker carries each tube one tile.
  l.machine(19, 8, SteelRecipes.packTubes, dir: Dir4.south);
  // The forklift aisle: a pad over both hand ports, then east along rows
  // 6..7 to the tube-crate dock, with the charging bay off it.
  l.add(EntityKind.aisle, 17, 8, span: (2, 2));
  l.add(EntityKind.aisle, 17, 6, span: (_shipX - 17, 2));
  l.add(EntityKind.shippingDock, _shipX, 6);
  l.add(EntityKind.chargingBay, 27, 4);
  // The walkers' muster area beside the tube corner (where new hires
  // stand).
  l.add(EntityKind.staging, 21, 12, span: (4, 1));
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
