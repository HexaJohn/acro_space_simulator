// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Arms Factory's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6).
///
/// Like every template it is a built-in [FloorBlueprint] whose MEASURED
/// rates match the plant's flat `CityBuildingSpec` within 5%, whose build
/// cost (`capexOf`) is the spec's `buildCost` and whose job demand is the
/// spec's `jobs`, so opening the floor changes nothing for a colony. It is
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
/// runs flat out at exactly 0.3 guns/s; every other station has 20-60%
/// slack, so the bench — skilled hands, not a machine — is the plant's
/// rate, and the docks take in only what it uses.
///
/// ## The floor (110 × 56 m hall on the 500 × 350 m site)
///
/// Rows y = 17 … 0 (south wall at the bottom; north of y = 17 is clear
/// floor), one character per 2 m tile. R/S receiving/shipping doors,
/// s staging, X saw (under the crane), M receiver centres, B barrel
/// borers, F fitting bench, P packers, W swarf press, D case press,
/// L loader, a arms, `> < ^` belts, + walkway crossings, : forklift aisle,
/// C charging bay:
///
///     |...................................................::CC|
///     |...................................................::..|
///     |............................................LLL.PPP::..|
///     |.......................>>>>>>>>>>>>>>>>>>>>>LLLaPPP::SS|
///     |.......................a....................LLL....::..|
///     |......................WWW....................a.....::..|
///     |...................sssWWW...................DDD....::..|
///     |...................sssWWW...................DDD....::SS|
///     |..........................PPP...............DDD....::..|
///     |RR>>>>>>>>>>>>>>>+>>>>FFFaPPP................+.....::..|
///     |..............>>>+>>>>FFF<<<<<+<<............^.....::..|
///     |..............a....a..FFF..a....a............^.....::..|
///     |............MMMMMMMMMM...BBBBBBBBBB..........^.....::..|
///     |............MMMMMMMMMM...BBBBBBBBBB..........^.....::..|
///     |............MMMMMMMMMM...BBBBBBBBBB..........^.....::..|
///     |..ssss.......a....a.......a....a.............^.....::..|
///     |RRssssXXXa>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>^.........|
///     |..ssssXXX..............................................|
///
/// The plan's realistic mix (§3 "Template plants"; the user's brief:
/// "workers should be used in conjunction with heavy vehicles … or just on
/// their own to move freight"):
///
/// * **Steel stockyard (south-west), crane over it.** Steel arrives as
///   bundles (pallet crates) at a MANUAL receiving dock and is set down in
///   a staging yard; an OVERHEAD CRANE lifts each bundle onto the cut-off
///   saw beside it, as in any bar-stock yard.
/// * **Blanks ride a belt through the machining hall.** One conveyor runs
///   the length of the south wall past four manual machining centres (two
///   for receivers, two for barrels) and on, round the corner, to the
///   ammunition line's casing press; arms load each station from it.
///   Steady flow, so a belt.
/// * **Parts converge on the fitting bench.** Receivers ride a belt east,
///   barrels a belt west, into the bench between the two pairs of
///   machines. The electronics (boxed fire-control and sight modules) come
///   from their own door down a roller conveyor into the bench's other
///   side — light boxes, a trickle — and `capexOf` charges that door as
///   the automated dock it is. The fitters' guns go by arm to the case
///   packer beside them.
/// * **Swarf and gun cases are hand work.** Walkers lift the chip bins
///   from the machines to the swarf press north of the bench, crossing the
///   part belts at walkway crossings, and carry the finished gun cases
///   (40 kg, a two-hand carry) across the hall to their shipping door.
///   That walking is the template's slack: a designer who sets a press
///   beside the machines with arms, or belts the cases out, frees most of
///   it.
/// * **The ammunition line stands apart**, east of an 18 m separation:
///   the case press and the bullet belt meet at an ASSISTED loading
///   machine, an arm feeds the pallet packer, and a FORKLIFT on a marked
///   aisle, with its charging bay, drives the 600 kg ammo pallets to their
///   door.
///
/// Jobs: 10 manual stations × 2 (saw, four mills, bench, two packers,
/// case press, swarf press) + 1 assisted loader + [kArmsWalkers] walkers
/// + 1 forklift driver + 1 crane driver = 35, the spec's count.
///
/// Build cost (`capexOf`): hall and doors ~16.8, stations ~13.7, belts,
/// arms and the electronics dock conveyor ~7.0, crane, forklift and their
/// bays ~2.6, staging ~0.2 — ~40.3 ore against the spec's default 40.
library;

import '../factory_catalog.dart';
import '../factory_entities.dart';
import '../factory_grid.dart';
import '../factory_handling.dart';
import '../factory_item.dart';
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
/// Craft times are set so each station's crew mode gives it 20-60% slack
/// at the spec rate, except the fitting bench, which runs flat out and so
/// IS the plant's rate (see the library doc). A manual station runs at
/// speed 0.6, an assisted one at 1.0 ([MachineMode]).
class ArmsRecipes {
  ArmsRecipes._();

  static const saw = FactoryRecipe(
    id: 'gunfactory:saw',
    label: 'Saw Bar Stock',
    station: StationKind.unpacker,
    inputs: [ItemQty('crate:steel', 1)],
    outputs: [ItemQty('steel', 10)],
    // 5 s: a manual saw (8.3 s a bundle) cuts 1.2 blanks/s against 0.5. A
    // saw is quick; the slack fills the long blank belt within the first
    // few minutes, so a fresh floor settles fast.
    seconds: 5,
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
    // 12 s: a manual centre (20 s) makes 0.2 receivers/s; two make 0.4
    // against the bench's 0.3.
    seconds: 12,
    // A 5-axis machining centre: spindle, axes, coolant pumps.
    powerKw: 60,
  );

  static const boreBarrel = FactoryRecipe(
    id: 'gunfactory:boreBarrel',
    label: 'Bore & Rifle Barrels',
    station: StationKind.mill,
    inputs: [ItemQty('steel', 2)],
    outputs: [ItemQty('gunfactory:barrel', 4), ItemQty('gunfactory:swarf', 1)],
    // 12 s, as the receivers: two manual borers make 0.4 barrels/s.
    seconds: 12,
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
    // 12 s: a manual packer (20 s a case) takes 0.5 guns/s against 0.3.
    seconds: 12,
    powerKw: 3,
  );

  static const drawCasings = FactoryRecipe(
    id: 'gunfactory:drawCasings',
    label: 'Draw Cases',
    station: StationKind.press,
    inputs: [ItemQty('steel', 1)],
    outputs: [ItemQty('gunfactory:casing', 5)],
    // 2.4 s: a manual transfer press (4 s) draws 1.25 trays/s against 1.0.
    seconds: 2.4,
    // A multi-station transfer press: the hall's biggest single draw.
    powerKw: 150,
  );

  static const swageBullets = FactoryRecipe(
    id: 'gunfactory:swageBullets',
    label: 'Swage Bullet Cores',
    station: StationKind.press,
    // A charge of six bins: the press's hopper holds two charges (12
    // bins), which is how far ahead its walkers can fetch — a small charge
    // would starve it between their ~35 s round trips.
    inputs: [ItemQty('gunfactory:swarf', 6)],
    outputs: [ItemQty('gunfactory:bullet', 40)],
    // 18 s: a manual press (30 s) takes 0.2 bins/s against 0.15.
    seconds: 18,
    // Chip compaction and swaging: a hydraulic press.
    powerKw: 80,
  );

  static const loadRounds = FactoryRecipe(
    id: 'gunfactory:loadRounds',
    label: 'Load Rounds',
    station: StationKind.assembler,
    inputs: [ItemQty('gunfactory:casing', 5), ItemQty('gunfactory:bullet', 5)],
    outputs: [ItemQty('ammo', 5)],
    // 4 s: an assisted loading machine (4 s) loads 1.25 rounds/s against
    // 1.0. Charging powder is the one step nobody does by hand.
    seconds: 4,
    // Rotary loader: indexing table, powder measures, crimp station.
    powerKw: 40,
  );

  static const packAmmo = FactoryRecipe(
    id: 'gunfactory:packAmmo',
    label: 'Palletise Ammo',
    station: StationKind.packer,
    inputs: [ItemQty('ammo', 50)],
    outputs: [ItemQty('crate:ammo', 1)],
    // 24 s: a manual packer (40 s a pallet) takes 1.25 cans/s against 1.0.
    seconds: 24,
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
/// hall ends at x = 34, so the gap between is the 18 m separation the
/// spec's "separated, bermed ammunition line" asks for.
const int _ammoX = 44;

/// Workers on foot: swarf bins to the press (0.15/s, ~35 s round trips
/// across the part belts) and gun cases to their door (0.03/s, a long
/// walk). Measured: eight just hold the spec rate, seven fall ~15% short.
/// Twelve is the template's honest overstaffing — a crew sized for the
/// worst shift, and the first thing a designer trims.
const int kArmsWalkers = 12;

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
  // The walkers' muster area, beside the swarf press (where new hires
  // stand and idle walkers wait). First, so it is the floor's idle spot.
  l.add(EntityKind.staging, 19, 10, span: (3, 2));

  // ---- steel stockyard: manual dock, staging yard, crane, saw ----
  l.add(EntityKind.receivingDock, 0, 1, item: 'crate:steel');
  l.add(EntityKind.staging, 2, 0, span: (4, 3));
  l.machine(6, 0, ArmsRecipes.saw);
  l.add(EntityKind.craneBay, 2, 0, span: (7, 3));
  l.arm(9, 1, Dir4.east);

  // ---- the blank belt: along the south wall, then north to the press ----
  // The last tile, feeding the press, is a crossing: the walkers' way east
  // to the shipping doors.
  l.beltEast(10, _ammoX, 1);
  l.beltRun(1, 8, _ammoX + 1, Dir4.north, crossings: {8});

  // ---- machining: two receiver centres, the bench, two barrel borers ----
  for (final (x, r) in [
    (12, ArmsRecipes.machineReceiver),
    (17, ArmsRecipes.machineReceiver),
    (25, ArmsRecipes.boreBarrel),
    (30, ArmsRecipes.boreBarrel),
  ]) {
    l.arm(x + 1, 2, Dir4.north); // blanks in
    l.machine(x, 3, r);
    // Parts out (filtered: the swarf stays for the walkers).
    l.arm(x + 2, 6, Dir4.north, only: r.outputs.first.item);
  }
  l.beltEast(14, 21, 7, crossings: {17}); // receivers → bench
  l.beltRun(32, 25, 7, Dir4.west, crossings: {30}); // barrels → bench
  l.machine(22, 6, ArmsRecipes.fit);

  // ---- electronics: dock conveyor into the bench's west side ----
  l.add(EntityKind.receivingDock, 0, 8, item: 'electronics');
  l.beltEast(2, 21, 8, crossings: {17});

  // ---- guns: arm to the case packer east of the bench ----
  l.arm(25, 8, Dir4.east);
  l.machine(26, 8, ArmsRecipes.packGuns);

  // ---- the swarf press north of the bench; bullets belt east ----
  l.machine(22, 10, ArmsRecipes.swageBullets);
  l.arm(23, 13, Dir4.north);
  l.beltEast(23, _ammoX - 1, 14);

  // ---- ammunition line: cases and bullets meet at the loader ----
  const a = _ammoX;
  l.machine(a, 9, ArmsRecipes.drawCasings);
  l.arm(a + 1, 12, Dir4.north);
  l.machine(a, 13, ArmsRecipes.loadRounds, mode: MachineMode.assisted);
  l.arm(a + 3, 14, Dir4.east);
  l.machine(a + 4, 14, ArmsRecipes.packAmmo);

  // ---- east wall: forklift aisle, charging bay, shipping doors ----
  l.add(EntityKind.aisle, a + 7, 2, span: (2, 20));
  l.add(EntityKind.chargingBay, a + 9, 17);
  l.add(EntityKind.shippingDock, a + 9, 14, item: 'crate:ammo');
  l.add(EntityKind.shippingDock, a + 9, 10, item: 'crate:guns');

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
