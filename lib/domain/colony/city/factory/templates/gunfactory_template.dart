// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Arms Factory's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6).
///
/// Like every template it is a built-in [FloorBlueprint] whose MEASURED
/// rates match the plant's flat `CityBuildingSpec` within 5% — measured
/// with [kArmsMeasureSettings], NOT `MeasureSettings.standard` (see
/// "Measuring it" below) — whose build cost (`capexOf`) is the spec's
/// `buildCost` and whose job demand is the spec's `jobs`. It is
/// deliberately "fine, not great": a designer who re-crews it, trims its
/// walkers or shortens its walks beats it (the Reward levers).
///
/// ## The chain (spec: 0.5 steel + 0.1 electronics → 0.3 guns + 1.0 ammo /s)
///
/// As a mass balance per second, in commodity units:
///
///     0.05 steel crates ──saw──► 0.5 steel blanks
///       0.15 ──machine receivers──► 0.3 receivers + 0.075 swarf bins
///       0.15 ──bore barrels────────► 0.3 barrels   + 0.075 swarf bins
///       0.2  ──draw cases──────────► 1.0 case trays
///     0.3 receivers + 0.3 barrels + 0.1 electronics ──fit──► 0.3 guns
///     0.15 swarf bins ──swage──► 1.0 bullet trays
///     1.0 case trays + 1.0 bullet trays ──load──► 1.0 ammo
///
/// then packers put guns in cases of ten and ammo on pallets of fifty.
///
/// **Swarf is not waste.** Machining a receiver or boring a barrel cuts
/// away chips; pressing them into steel bullet cores is this plant's
/// byproduct loop (the Steel Mill's slag → tubes), and it is why the plant
/// ships nothing but guns and ammo. It also TIES the two products
/// together: every gun's worth of machining leaves exactly the swarf for
/// 10/3 rounds, so the ammunition line runs at 1.0/s because the gun line
/// runs at 0.3/s, and a starved fitting bench starves the cartridges too.
/// (Propellant and primers are the plant's own small consumables, not
/// modelled: the spec takes no chemical input.)
///
/// **What sets the pace.** One manual fitting bench ([ArmsRecipes.fit])
/// runs flat out at exactly 0.3 guns/s; every other station has 65-100%
/// slack, the saw excepted (300%, see its comment), so the bench — skilled
/// hands, not a machine — is the plant's rate, and the docks take in only
/// what it uses.
///
/// ## Measuring it (aggregate mode)
///
/// This floor needs a LONGER measurement than the colony's default, and
/// the reason is arithmetic, not tuning. `MeasureSettings.standard` (60 s
/// warm-up, at most 300 s measured) reads a fresh floor as about steel
/// 1.17/s (+133%), electronics 0.19/s (+93%), guns 0.20/s (-33%) and ammo
/// 1.0/s (on spec only by luck of the lumps):
///
/// * An ammo pallet is fifty rounds, fifty seconds of the line's output.
///   For the 300 s window to see all six of its pallets the first would
///   have to leave ~110 s after a COLD start, i.e. steel would have to go
///   dock → saw → machining → swarf walk → swage → loader in ~20 s. No
///   real plant does; the first pallet and the first gun case leave at
///   ~175 s here.
/// * Before then the floor fills its work-in-progress — the 40-tile blank
///   belt alone holds ~160 blanks, the two part collectors ~90 parts —
///   and a fill still running inside the window is counted as intake.
/// * **The start-up surge.** Every part the collectors take on while they
///   fill also leaves a quarter of a swarf bin, so a cold floor makes
///   ~150 rounds' worth of swarf more than its guns account for. The
///   ammunition line is given 100% slack (case press, swage, loader and
///   pallet packer) so it works that surge off by ~240 s; with the 25%
///   it once had, the surplus was still shipping 30 minutes in and read
///   as +5-8% ammo.
///
/// So the template is tuned to SETTLE fast instead, and
/// [kArmsMeasureSettings] measures it: a 300 s warm-up, then a full
/// 1800 s window, long enough that one 50-round pallet either side is
/// under 3%. Any warm-up from ~240 s on, with any window of 1800 s or
/// more, reads within 5% (the test sweeps misaligned ones). Whoever wires
/// the off-screen re-measure must pass these settings for `kArmsType` (or
/// measure a warm saved state via `measureSaved`); the standard settings
/// would misreport an untouched Arms Factory.
///
/// **Off-thread registration.** The chain lives in this file, not in
/// `ensureFactoryCatalog`, so a floor measured on a fresh worker isolate
/// knows the 'gunfactory:*' recipes only if the worker registers them:
/// pass `setup: registerArmsChain` (or a shared setup that calls it) to
/// `FloorMeasureRunner.platform`. Without it every station's recipe is
/// unknown there and the plant measures as making nothing.
///
/// ## The floor (110 × 56 m hall on the 500 × 350 m site)
///
/// Laid for EXPLICIT PORTS (docs/plans/factory-floors.md §10 item 19,
/// `station_ports.dart`): a belt feeds a station only at an input port
/// with that slot's item, every output leaves by its own output port (or
/// waits at the hand port), handlers work a station at its hand port
/// only, and no arm touches a machine.
///
/// Rows y = 21 … 0 (south wall at the bottom; north of y = 21 is clear
/// floor), one character per 2 m tile. R/S receiving/shipping doors,
/// s staging, X saw (under the crane), B barrel borers, M receiver
/// centres (both facing north), F fitting bench (facing west), P packers,
/// K the swarf skip, W swarf press, D case press, L loader, a arms,
/// `> < ^ v` belts, + walkway crossings, : forklift aisle, C charging bay:
///
///     |...................................................::..|  21
///     |...................................................::..|
///     |...................................................::..|
///     |...................................................::CC|
///     |...................................................::CC|
///     |RR>>>>>>>>>>>>>>>>>>>v.............................::..|  16
///     |.....................v.............................::..|
///     |................PPP.FFF..WWW.......................::..|
///     |................PPP<FFF<>WWW>>>>>>>+>>>>>>>>>v.....::..|
///     |SS..................FFF^aWWW.................v.....::..|  12
///     |.....................^.^K....sss........DDD.LLL....::..|
///     |.....................+.+.....sss.......>DDD>LLL>PPP::..|
///     |.............>>+>>>+>^.^<<<+<<.........^DDD.LLL.PPP::..|
///     |............BBB.BBB.....MMM.MMM........^........:::::SS|   8
///     |............BBB.BBB.....MMM.MMM........^........:::::..|
///     |............BBB.BBB.....MMM.MMM........^...........::..|
///     |............BBB.BBB.....MMM.MMM........^...........::..|
///     |............BBB.BBB.....MMM.MMM........^...........::..|   4
///     |.............^...^.......^...^.........^...........::..|
///     |..ssss.......a...a.......a...a.........^...........::..|
///     |RRssssXXX>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>^...............|
///     |..ssssXXX..............................................|   0
///
/// The plan's realistic mix (§3 "Template plants"; the user's brief:
/// "workers should be used in conjunction with heavy vehicles … or just on
/// their own to move freight"):
///
/// * **Steel stockyard (south-west), crane over it.** Steel arrives as
///   bundles (pallet crates) at a MANUAL receiving dock and is set down in
///   a staging yard; an OVERHEAD CRANE lifts each bundle to the cut-off
///   saw's hand port (7, 0), under its hook, as in any bar-stock yard.
/// * **Blanks ride a belt through the machining hall.** The saw's output
///   port pushes blanks onto one conveyor along the south wall, past four
///   manual machining centres and up the riser at x = 39 into the case
///   press's input port (the belt's dead end, so it backs up and every
///   arm along it always has blanks). Floors have no splitter and a port
///   belt feeds one machine, so each centre gets its own: an ARM lifts
///   blanks off the main belt (row 1) onto a one-tile feeder (row 3)
///   pointing into the centre's input port. Steady flow, so a belt.
/// * **Parts converge on the fitting bench** by their output ports:
///   barrels ride a collector east along row 9 and up into the bench's
///   input 2 (21, 12), receivers a collector west and up column 23 into
///   its input 1 (22, 13). The electronics (boxed fire-control and sight
///   modules) come from their own door down a roller conveyor into input
///   3 (21, 14) — light boxes, a trickle — and `capexOf` charges that door
///   as the automated dock it is. The bench pushes guns out of its west
///   port onto one belt tile into the case packer.
/// * **Swarf and gun cases are hand work.** Each centre's chip bins wait
///   at its hand port, in the one-tile gap east of it; walkers carry them
///   up through the collector crossings to the swarf SKIP (K, a chest
///   that takes swarf only) and an arm feeds the press's input port from
///   it by belt. (A skip, not the press's hopper: walkers pulling straight
///   into a two-charge hopper could keep only six bins in flight and ran
///   the plant 8% short.) Walkers also carry the finished gun cases
///   (40 kg, a two-hand carry) from the case packer's hand port to their
///   door on the west wall. That walking is the template's slack: a
///   designer who belts the cases out, or sets the skip closer to the
///   centres, frees most of it.
/// * **The ammunition line stands apart**, east of an 18 m separation:
///   the case press and the bullet belt meet at an ASSISTED loading
///   machine, port to port by one-tile belts into the pallet packer, and a
///   FORKLIFT on a marked aisle (a pad at the packer's hand port, then the
///   east wall), with its charging bay, drives the 600 kg ammo pallets to
///   their door.
///
/// Mass balance on the floor, per second: 0.05 crates in by crane → saw
/// → 0.5 blanks on the belt; the four arms take 0.3 (0.075 each, 56% of
/// a centre's pace) and the case press the 0.2 that reaches the dead end. 0.3 barrels + 0.3 receivers + 0.1 electronics → 0.3 guns →
/// 0.03 cases out the west door. 0.15 swarf bins walk to the skip → 1.0
/// bullets meet 1.0 case trays at the loader → 1.0 ammo → 0.02 pallets out
/// the east door. Nothing else leaves; nothing is scrapped.
///
/// Jobs: 10 manual stations × 2 (saw, four mills, bench, two packers,
/// case press, swarf press) + 1 assisted loader + [kArmsWalkers] walkers
/// + 1 forklift driver + 1 crane driver = 35, the spec's count.
///
/// Build cost (`capexOf`): hall and doors ~16.8, stations ~13.7, belts,
/// crossings, five arms and the electronics dock conveyor ~6.3, crane,
/// forklift and their bays ~2.6, staging and the skip ~0.3 — ~39.7 ore
/// against the spec's default 40.
library;

import '../factory_catalog.dart';
import '../factory_entities.dart';
import '../factory_grid.dart';
import '../factory_handling.dart';
import '../factory_item.dart';
import '../factory_measure.dart';
import '../factory_recipe.dart';
import '../floor_blueprint.dart';
import '../template_layout.dart';

/// The plant type this template is for (`CityBuildingSpec.type`).
const String kArmsType = 'gunfactory';

/// Intermediates of the Arms Factory chain. Ids are saved: never rename.
class ArmsItems {
  ArmsItems._();

  /// A machined receiver (the gun's frame): a few kilos, a hand part.
  static const receiver = FactoryItem(
    id: 'gunfactory:receiver',
    label: 'Receiver',
    loadClass: LoadClass.hand,
    kgPerUnit: 2,
  );

  /// A bored and rifled barrel: a hand part.
  static const barrel = FactoryItem(
    id: 'gunfactory:barrel',
    label: 'Barrel',
    loadClass: LoadClass.hand,
    kgPerUnit: 1.5,
  );

  /// A bin of machining chips: 25 kg, what one worker carries.
  static const swarf = FactoryItem(
    id: 'gunfactory:swarf',
    label: 'Swarf Bin',
    loadClass: LoadClass.hand,
    kgPerUnit: 25,
  );

  /// A tray of drawn cartridge cases.
  static const casing = FactoryItem(
    id: 'gunfactory:casing',
    label: 'Case Tray',
    loadClass: LoadClass.hand,
    kgPerUnit: 4,
  );

  /// A tray of swaged steel-core bullets.
  static const bullet = FactoryItem(
    id: 'gunfactory:bullet',
    label: 'Bullet Tray',
    loadClass: LoadClass.hand,
    kgPerUnit: 6,
  );

  static const all = [receiver, barrel, swarf, casing, bullet];
}

/// Recipes of the Arms Factory chain. Ids are saved: never rename.
///
/// Craft times are set so each station's crew mode gives it 65-100% slack
/// at the spec rate — the saw excepted (300%, see its comment) — except
/// the fitting bench, which runs flat out and so IS the plant's rate (see
/// the library doc). The ammunition line's stations take the top of that
/// range (100%) so the start-up surge of swarf clears within the warm-up
/// (library doc, "Measuring it"). A manual station runs at speed 0.6, an
/// assisted one at 1.0 ([MachineMode]).
class ArmsRecipes {
  ArmsRecipes._();

  static const saw = FactoryRecipe(
    id: 'gunfactory:saw',
    label: 'Saw Bar Stock',
    station: StationKind.unpacker,
    inputs: [ItemQty('crate:steel', 1)],
    outputs: [ItemQty('steel', 10)],
    // 3 s: a manual saw (5 s a bundle) cuts 2 blanks/s against 0.5 — 300%
    // slack, pushed straight out of its output port onto the belt. A band
    // saw through bar stock is quick; the slack is there so the 40-tile
    // blank belt (~160 blanks once backed up) fills in the first minutes
    // instead of ~600 s. A saw with little slack would leave the belt
    // still filling inside any measurement window, read as extra intake.
    seconds: 3,
    // A cold-cut band saw and its infeed: tens of kW.
    powerKw: 30,
  );

  static const machineReceiver = FactoryRecipe(
    id: 'gunfactory:machineReceiver',
    label: 'Machine Receivers',
    station: StationKind.mill,
    // Two blanks make four receivers and fill one chip bin.
    inputs: [ItemQty('steel', 2)],
    outputs: [
      ItemQty('gunfactory:receiver', 4),
      ItemQty('gunfactory:swarf', 1),
    ],
    // 9 s: a manual centre (15 s) makes 0.27 receivers/s; two make 0.53
    // against the bench's 0.3. The 78% slack fills the 11-tile collector
    // to the bench (44 parts) in ~3 minutes, not seven.
    seconds: 9,
    // A 5-axis machining centre: spindle, axes, coolant pumps.
    powerKw: 60,
  );

  static const boreBarrel = FactoryRecipe(
    id: 'gunfactory:boreBarrel',
    label: 'Bore & Rifle Barrels',
    station: StationKind.mill,
    inputs: [ItemQty('steel', 2)],
    outputs: [ItemQty('gunfactory:barrel', 4), ItemQty('gunfactory:swarf', 1)],
    // 9 s, as the receivers: two manual borers make 0.53 barrels/s.
    seconds: 9,
    // Deep-hole drilling and button rifling: a long, hard-driven spindle.
    powerKw: 60,
  );

  static const fit = FactoryRecipe(
    id: 'gunfactory:fit',
    label: 'Fit & Test Guns',
    station: StationKind.assembler,
    inputs: [
      ItemQty('gunfactory:receiver', 3),
      ItemQty('gunfactory:barrel', 3),
      ItemQty('electronics', 1),
    ],
    outputs: [ItemQty('guns', 3)],
    // 6 s: a manual bench (10 s) fits exactly 0.3 guns/s, the spec rate.
    // This is the pacing station: no slack on purpose.
    seconds: 6,
    // Torque tools, a test-fire tunnel's extraction: light.
    powerKw: 8,
  );

  static const packGuns = FactoryRecipe(
    id: 'gunfactory:packGuns',
    label: 'Case Guns',
    station: StationKind.packer,
    inputs: [ItemQty('guns', 10)],
    outputs: [ItemQty('crate:guns', 1)],
    // 12 s: a manual packer (20 s a case) takes 0.5 guns/s against 0.3,
    // fed by one belt tile from the bench's output port.
    seconds: 12,
    powerKw: 3,
  );

  static const drawCasings = FactoryRecipe(
    id: 'gunfactory:drawCasings',
    label: 'Draw Cases',
    station: StationKind.press,
    inputs: [ItemQty('steel', 1)],
    outputs: [ItemQty('gunfactory:casing', 5)],
    // 1.5 s: a manual transfer press (2.5 s) draws 2 trays/s against 1.0.
    seconds: 1.5,
    // A multi-station transfer press: the hall's biggest single draw.
    powerKw: 150,
  );

  static const swageBullets = FactoryRecipe(
    id: 'gunfactory:swageBullets',
    label: 'Swage Bullet Cores',
    station: StationKind.press,
    // A charge of three bins: small lumps, so the first bullets go out
    // after three bins and the ammo line's work-in-progress swings by 20
    // rounds, not 40. The press is fed from the walkers' swarf skip by an
    // arm and a belt, never from walkers' hands: its hopper holds only two
    // charges (6 bins), and walkers pulling straight into it could keep at
    // most six bins in flight, ~0.14 bins/s on ~43 s round trips against
    // the 0.15 the guns make (measured: the plant ran 8% short).
    inputs: [ItemQty('gunfactory:swarf', 3)],
    outputs: [ItemQty('gunfactory:bullet', 20)],
    // 6 s: a manual press (10 s) takes 0.3 bins/s against 0.15.
    seconds: 6,
    // Chip compaction and swaging: a hydraulic press.
    powerKw: 80,
  );

  static const loadRounds = FactoryRecipe(
    id: 'gunfactory:loadRounds',
    label: 'Load Rounds',
    station: StationKind.assembler,
    inputs: [ItemQty('gunfactory:casing', 5), ItemQty('gunfactory:bullet', 5)],
    outputs: [ItemQty('ammo', 5)],
    // 2.5 s: an assisted loading machine (2.5 s) loads 2 rounds/s against
    // 1.0. Charging powder is the one step nobody does by hand.
    seconds: 2.5,
    // Rotary loader: indexing table, powder measures, crimp station.
    powerKw: 40,
  );

  static const packAmmo = FactoryRecipe(
    id: 'gunfactory:packAmmo',
    label: 'Palletise Ammo',
    station: StationKind.packer,
    inputs: [ItemQty('ammo', 50)],
    outputs: [ItemQty('crate:ammo', 1)],
    // 15 s: a manual packer (25 s a pallet) takes 2 cans/s against 1.0.
    seconds: 15,
    // Can sealer and stretch wrapper.
    powerKw: 10,
  );

  static const all = [
    saw,
    machineReceiver,
    boreBarrel,
    fit,
    packGuns,
    drawCasings,
    swageBullets,
    loadRounds,
    packAmmo,
  ];
}

bool _registered = false;

/// Registers the Arms Factory intermediates and recipes. Idempotent: the
/// registries accept the identical const object twice, and the flag skips
/// the work.
void registerArmsChain() {
  if (_registered) return;
  for (final i in ArmsItems.all) {
    FactoryItems.register(i);
  }
  for (final r in ArmsRecipes.all) {
    FactoryRecipes.register(r);
  }
  _registered = true;
}

/// Arms Factory hall: 55 × 28 tiles = 110 × 56 m — the stockyard, the
/// machining hall, the 18 m separation and the ammunition line, with the
/// dock aisle on the east wall, and the clear floor north of the lines
/// that a plant keeps for inspection, tool cribs and gangways. (Hall area
/// is build cost; this is what brings the template to the spec's 40 ore.)
const HallSize kArmsHall = HallSize(55, 28);

/// x of the ammunition line's west edge (the casing press). The machining
/// hall ends at x = 30, so the gap between is the 18 m separation the
/// spec's "separated, bermed ammunition line" asks for (crossed only by
/// the blank belt's riser and the bullet belt).
const int _ammoX = 40;

/// Workers on foot: swarf bins from the machines' hand ports to the skip
/// (0.15/s, ~35 s round trips through the walkway crossings) and gun cases
/// from the case packer to their door on the west wall (0.03/s, ~60 s
/// round trips). Measured: eight just hold the spec rate, seven fall ~13%
/// short. Twelve is the template's honest overstaffing — a crew sized for
/// the worst shift, and the first thing a designer trims.
const int kArmsWalkers = 12;

/// How the Arms Factory must be measured (library doc, "Measuring it"):
/// 300 s warm-up — the port floor settles by ~240 s, plus a minute's
/// margin — and a full 1800 s window, so one 50-round ammo pallet is 2.8%
/// of the window and one 10-gun case 1.9%. No early stop: the floor ships
/// in lumps, so its sub-windows never agree before the cap anyway, and a
/// fixed window keeps the reading free of chance agreement.
const MeasureSettings kArmsMeasureSettings = MeasureSettings(
  warmupS: 300,
  windowS: 1800,
  earlyStop: false,
);

/// One forklift moves 0.02 ammo pallets/s along a short aisle: light work,
/// and its charging bay covers its battery.
const int kArmsForklifts = 1;

/// One crane over the steel stockyard: a bundle every 20 s, hook travel
/// of a few metres.
const int kArmsCranes = 1;

/// A fresh Arms Factory template (the caller may edit it).
FloorBlueprint gunfactoryTemplate() {
  ensureFactoryCatalog();
  registerArmsChain();
  final l = TemplateLayout();
  // The walkers' muster area, between the receiver centres and the swarf
  // press. First, so it is the floor's idle spot.
  l.add(EntityKind.staging, 29, 10, span: (3, 2));

  // ---- steel stockyard: manual dock, staging yard, crane, saw ----
  l.add(EntityKind.receivingDock, 0, 1, item: 'crate:steel');
  l.add(EntityKind.staging, 2, 0, span: (4, 3));
  // Hand port (7, 0), under the hook; blanks leave output 1 (8, 1).
  l.machine(6, 0, ArmsRecipes.saw);
  l.add(EntityKind.craneBay, 2, 0, span: (7, 3));

  // ---- the blank belt: south wall east, then up into the case press ----
  // It dead-ends in the case press's input port (40, 10), so it backs up
  // and the machining arms along row 1 always find blanks behind them.
  l.beltEast(9, _ammoX - 2, 1);
  l.beltRun(1, 9, _ammoX - 1, Dir4.north);
  l.add(EntityKind.belt, _ammoX - 1, 10);

  // ---- machining: barrel borers west of the bench, receivers east ----
  // A north-facing mill at (x, 4) covers x..x+2, rows 4..8: input port
  // (x+1, 4) fed from (x+1, 3), main product out (x+1, 8) onto row 9,
  // hand port (x+2, 6) worked from (x+3, 6) — the one-tile gap east of
  // it, where its chip bins wait (its swarf port, west, has no belt).
  for (final (x, r) in [
    (12, ArmsRecipes.boreBarrel),
    (16, ArmsRecipes.boreBarrel),
    (24, ArmsRecipes.machineReceiver),
    (28, ArmsRecipes.machineReceiver),
  ]) {
    l.arm(x + 1, 2, Dir4.north); // blank belt > feeder
    l.add(EntityKind.belt, x + 1, 3, dir: Dir4.north); // > input port
    l.machine(x, 4, r, dir: Dir4.north);
  }
  // The bench faces west at (20, 12): input 1 (receivers) at (22, 13) from
  // the east, input 2 (barrels) at (21, 12) from below, input 3
  // (electronics) at (21, 14) from above, guns out (20, 13) west. Each
  // collector has a crossing over each gap and over the row-10 walkway.
  // Barrels: east along row 9, up column 21 into input 2.
  l.beltEast(13, 20, 9, crossings: {15, 19});
  l.beltRun(9, 11, 21, Dir4.north, crossings: {10});
  // Receivers: west along row 9, up column 23, into input 1.
  l.beltRun(29, 24, 9, Dir4.west, crossings: {27});
  l.beltRun(9, 12, 23, Dir4.north, crossings: {10});
  l.add(EntityKind.belt, 23, 13, dir: Dir4.west);
  l.machine(20, 12, ArmsRecipes.fit, dir: Dir4.west);

  // ---- electronics: dock conveyor down into the bench's input 3 ----
  l.add(EntityKind.receivingDock, 0, 16, item: 'electronics');
  l.beltEast(2, 20, 16);
  l.beltRun(16, 15, 21, Dir4.south);

  // ---- guns: one belt tile west into the case packer ----
  // The packer faces west at (16, 13): input (18, 13), hand port (17, 14)
  // worked from (17, 15); walkers take its cases to the west-wall door.
  l.add(EntityKind.belt, 19, 13, dir: Dir4.west);
  l.machine(16, 13, ArmsRecipes.packGuns, dir: Dir4.west);
  l.add(EntityKind.shippingDock, 0, 12, item: 'crate:guns');

  // ---- swarf: the walkers' skip, an arm, the press; bullets east ----
  // Walkers tip bins into the skip from the row-10 walkway; the arm lifts
  // them onto (24, 13), into the press's input port (25, 13). Bullets
  // leave its output port (27, 13) along row 13 (a crossing at x = 35)
  // and down into the loader's input 2 (45, 11).
  l.add(EntityKind.chest, 24, 11, item: ArmsItems.swarf.id);
  l.arm(24, 12, Dir4.north, only: ArmsItems.swarf.id);
  l.add(EntityKind.belt, 24, 13);
  l.machine(25, 12, ArmsRecipes.swageBullets);
  l.beltEast(28, _ammoX + 4, 13, crossings: {35});
  l.beltRun(13, 12, _ammoX + 5, Dir4.south);

  // ---- ammunition line: case press > loader > pallet packer ----
  // Port to port along row 10: case trays (43, 10) into the loader's
  // input 1, rounds (47, 10) into the packer, whose pallets wait at its
  // hand port (49, 9) over the forklift pad.
  const a = _ammoX;
  l.machine(a, 9, ArmsRecipes.drawCasings);
  l.add(EntityKind.belt, a + 3, 10);
  l.machine(a + 4, 9, ArmsRecipes.loadRounds, mode: MachineMode.assisted);
  l.add(EntityKind.belt, a + 7, 10);
  l.machine(a + 8, 9, ArmsRecipes.packAmmo);

  // ---- east wall: forklift aisle, charging bay, the ammo door ----
  l.add(EntityKind.aisle, a + 8, 7, span: (3, 2));
  l.add(EntityKind.aisle, a + 11, 2, span: (2, 20));
  l.add(EntityKind.chargingBay, a + 13, 17);
  l.add(EntityKind.shippingDock, a + 13, 8, item: 'crate:ammo');

  return FloorBlueprint(
    name: 'Arms Factory',
    plantType: kArmsType,
    hall: kArmsHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kArmsWalkers,
      HandlerKind.forklift: kArmsForklifts,
      HandlerKind.crane: kArmsCranes,
    },
  );
}
