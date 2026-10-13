// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Electronics Plant's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6).
///
/// Like every template it is a built-in [FloorBlueprint] whose MEASURED
/// rate matches the plant's flat `CityBuildingSpec` rate within 5%, whose
/// job demand is the spec's `jobs`, and whose build cost (`capexOf`) is the
/// spec's `buildCost` (unset, so the default 40 ore). Opening the floor
/// therefore changes nothing for a colony until someone designs a better
/// one. It is "fine, not great" on purpose: almost every bench is a manual
/// pair, the stamping press has no servo assist, the shield-can hauls run
/// the length of the board shop and the hall is far bigger than the line.
///
/// ## The chain (spec: 0.5 steel → 0.6 electronics /s, 40 jobs)
///
/// A colony fab: press steel into chassis, build boards, fit them, test and
/// pack. Per second at the spec rate:
///
///     0.05 steel pallets ─unpack─► 0.5 steel ─stamp─► 0.6 chassis ──────┐
///                                              └────► 0.1 offcut         │
///     0.1 offcut ─shield press─► 0.15 can trays ─board bench─►           │
///                                0.15 board kits (4 boards) ─assemble◄───┘
///     ─► 0.6 units ─test─► 0.6 electronics ─pack─► 0.06 crates (×10)
///
/// The stamping skeleton (offcut) is not scrap: a second press draws it
/// into RF shield cans, which go on the boards. That is the byproduct loop
/// (§3 Reward "Efficiency"), and it is why the plant ships nothing but
/// electronics crates. The offcut also sets the board supply EXACTLY to
/// the chassis supply (one stroke: 6 chassis, ½ offcut-pair → 1.5 trays →
/// 1.5 kits → 6 boards), so neither piles up. Component reels, solder and
/// flux are below the colony's ledger, as the Steel Mill's flux is: the
/// spec's only input is steel, so steel is the only thing the floor takes.
///
/// Units are COLONY units, not kilograms: the spec trades 0.5 steel for
/// 0.6 electronics and the chain keeps that ratio exactly.
///
/// **The pacemaker is the stamping press.** Receiving is demand-driven (a
/// dock emits only when its staging has room), so a station, not the dock,
/// sets this plant's rate: one manual press at exactly one stroke per 10 s
/// takes 0.5 steel/s and makes 0.6 chassis/s, and it never waits (measured:
/// working every sampled second of steady state). Each station after it
/// has ~20% headroom at that rate, so a designer who speeds the press
/// (servo assist: an operator instead of a loader pair) gets ~15% more
/// electronics before the benches bind — the throughput lever.
///
/// ## The floor (hall 40 × 50 tiles = 80 × 100 m)
///
/// The user's brief (2026-10-12): workers move freight with forklifts,
/// pallet jacks and cranes or on their own, and very few plants have the
/// logistics worked out to load and unload without anyone lifting a
/// finger. So, from the truck court on the east wall westward:
///
/// * **Steel arrives on pallets** (`crate:steel`) at a receiving door and
///   is set down in a staging bay on the forklift aisle. The FORKLIFT takes
///   each pallet to the de-palletiser beside the aisle, where two hands
///   strip it.
/// * **Sheet goes by arm into the stamping press** (manual: a loader and
///   an operator). Its chassis drop by arm onto the CHASSIS BELT running
///   west along the line; the skeleton goes by arm into the shield press
///   beside it.
/// * **Three final-assembly benches** take chassis off the belt by arm,
///   and hand their units by arm to an operator-run TEST RIG beside each,
///   which puts tested units on the OUTBOUND BELT running back east to the
///   packer by the aisle. Belts carry the steady flows; nobody walks a
///   chassis.
/// * **The board shop is hand work.** North of the line, across the
///   outbound belt, five manual benches build board kits. WALKERS carry
///   trays of shield cans from the press to the benches (up to ~25 m) and
///   kits back across the belt on crossings to the assembly benches' north
///   side (a few metres). Those trips are the template's real handling.
/// * The FORKLIFT also takes the packer's crates across the aisle to the
///   shipping door, and charges at the bay beside it. One driver covers
///   both doors: 0.11 pallets/s of short hops.
/// * **No crane.** Nothing in an electronics fab is heavier than a pallet;
///   a crane here would be a driver with nothing to lift.
///
/// The line fills the hall's south third; the rest is the clean-room
/// envelope, test space and stores a fab carries. It is what puts the shed
/// at its build cost, and shrinking it is a capex lever for a designer.
///
/// **Levers a designer has** (the Reward section): servo-assist the press
/// (more output), give the benches an operator each (assisted: one job
/// instead of two, and faster), move the shield press next to the benches
/// so the walkers' hauls shrink, or shrink the hall.
///
/// Jobs: 12 manual stations × 2 + 3 assisted test rigs × 1 + 1 forklift
/// driver + [kElectronicsWalkers] walkers = 40, the spec's count.
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
const String kElectronicsType = 'electronics';

/// Hall: 40 × 50 tiles = 80 × 100 m, well inside the 600 × 450 m campus.
/// The line uses the south third; the rest is the clean-room envelope a
/// fab carries, sized so the whole floor costs the spec's 40 ore
/// (`capexOf`, measured 40.3).
const HallSize kElectronicsHall = HallSize(40, 50);

/// Workers on foot carrying can trays and board kits, one at a time,
/// 0.3 trips/s in all. Measured: ten hold the spec rate within 2%, eleven
/// exactly; twelve keeps one spare so a busy moment never starves a bench.
const int kElectronicsWalkers = 12;

/// One forklift works both doors: 0.05 steel pallets/s in and 0.06 crates/s
/// out, each a hop of a few metres across the aisle, with time to charge.
const int kElectronicsForklifts = 1;

// ---- items -----------------------------------------------------------------

/// The plant's own intermediates, all prefixed 'electronics:' so no other
/// chain can collide with them. Each is its own commodity (§3
/// "Intermediates are real goods"), so a designer may ship or receive them.
/// All are hand loads: nothing here needs more than a pair of arms.
class ElectronicsItems {
  ElectronicsItems._();

  /// A pressed steel chassis/frame, one per finished unit.
  static const chassis = FactoryItem(
      id: 'electronics:chassis', label: 'Chassis', loadClass: LoadClass.hand,
      kgPerUnit: 6);

  /// The stamping skeleton: the sheet left after the chassis blanks are
  /// punched out.
  static const offcut = FactoryItem(
      id: 'electronics:offcut', label: 'Stamping Offcut',
      loadClass: LoadClass.hand, kgPerUnit: 15);

  /// A tray of RF shield cans drawn from offcut, enough for one board kit.
  static const canTray = FactoryItem(
      id: 'electronics:canTray', label: 'Shield Can Tray',
      loadClass: LoadClass.hand, kgPerUnit: 2);

  /// A kit of four populated, shielded boards: one final-assembly craft.
  static const boardKit = FactoryItem(
      id: 'electronics:boardKit', label: 'Board Kit',
      loadClass: LoadClass.hand, kgPerUnit: 3);

  /// An assembled but untested unit.
  static const unit = FactoryItem(
      id: 'electronics:unit', label: 'Untested Unit',
      loadClass: LoadClass.hand, kgPerUnit: 10);

  static const all = [chassis, offcut, canTray, boardKit, unit];
}

// ---- recipes ---------------------------------------------------------------

/// Recipe ids of the Electronics Plant chain. Saved on machines: never
/// rename. Craft times are at speed 1; a MANUAL station runs at 0.6, an
/// ASSISTED one at 1.0 (`MachineMode`). Power figures are orders of
/// magnitude for the kit named; integration calibrates them against the
/// spec's `powerDraw`.
class ElectronicsRecipes {
  ElectronicsRecipes._();

  static const unpack = FactoryRecipe(
    id: 'electronics:unpack',
    label: 'De-palletise Steel',
    station: StationKind.unpacker,
    inputs: [ItemQty('crate:steel', 1)],
    outputs: [ItemQty('steel', 10)],
    // 8 s: a manual pair (13.3 s) strips 0.075 pallets/s against the
    // press's 0.05 — never the plant's limit.
    seconds: 8,
    // Strapping cutter and a powered roller table.
    powerKw: 5,
  );

  static const stamp = FactoryRecipe(
    id: 'electronics:stamp',
    label: 'Stamp Chassis',
    station: StationKind.press,
    inputs: [ItemQty('steel', 5)],
    outputs: [
      ItemQty('electronics:chassis', 6),
      ItemQty('electronics:offcut', 1),
    ],
    // 6 s: a manual press (10 s a stroke) takes exactly 0.5 steel/s and
    // makes 0.6 chassis/s — the spec rate. This press is the template's
    // pacemaker on purpose (see the library doc).
    seconds: 6,
    // A ~200 t stamping press, averaged over its stroke.
    powerKw: 150,
  );

  static const shield = FactoryRecipe(
    id: 'electronics:shield',
    label: 'Draw Shield Cans',
    station: StationKind.press,
    inputs: [ItemQty('electronics:offcut', 2)],
    outputs: [ItemQty('electronics:canTray', 3)],
    // 9.6 s: a manual press (16 s) draws 0.125 offcuts/s against the 0.1
    // the stamping press leaves — 80%.
    seconds: 9.6,
    // A small drawing press: a fraction of the stamping press.
    powerKw: 40,
  );

  static const board = FactoryRecipe(
    id: 'electronics:board',
    label: 'Build Board Kit',
    station: StationKind.assembler,
    inputs: [ItemQty('electronics:canTray', 1)],
    outputs: [ItemQty('electronics:boardKit', 1)],
    // 16 s for four boards: a manual bench (26.7 s) makes 0.0375 kits/s;
    // five make 0.19 against 0.15 — 80%.
    seconds: 16,
    // A bench pick-and-place, a reflow oven and soldering irons.
    powerKw: 60,
  );

  static const assemble = FactoryRecipe(
    id: 'electronics:assemble',
    label: 'Final Assembly',
    station: StationKind.assembler,
    inputs: [
      ItemQty('electronics:chassis', 4),
      ItemQty('electronics:boardKit', 1),
    ],
    outputs: [ItemQty('electronics:unit', 4)],
    // 9.6 s for four units: a manual bench (16 s) fits 0.25 units/s; three
    // make 0.75 against 0.6 — 80%.
    seconds: 9.6,
    // Screwdrivers, a torque station and a fume hood.
    powerKw: 10,
  );

  static const test = FactoryRecipe(
    id: 'electronics:test',
    label: 'Test & Burn-in',
    station: StationKind.assembler,
    inputs: [ItemQty('electronics:unit', 2)],
    outputs: [ItemQty('electronics', 2)],
    // 8 s a pair: an assisted rig tests 0.25 units/s; three take 0.75
    // against 0.6 — 80%.
    seconds: 8,
    // Burn-in under load: the plant's hungriest station after the press.
    powerKw: 80,
  );

  static const pack = FactoryRecipe(
    id: 'electronics:pack',
    label: 'Crate Electronics',
    station: StationKind.packer,
    inputs: [ItemQty('electronics', 10)],
    outputs: [ItemQty('crate:electronics', 1)],
    // 8 s: a manual packer (13.3 s) crates 0.075/s against 0.06 — 80%.
    seconds: 8,
    // Foam-in-place and a stretch wrapper.
    powerKw: 15,
  );

  static const all = [unpack, stamp, shield, board, assemble, test, pack];
}

/// Registers the chain's items and recipes. Idempotent: the registries
/// accept the identical const object twice.
void registerElectronicsChain() {
  for (final i in ElectronicsItems.all) {
    FactoryItems.register(i);
  }
  for (final r in ElectronicsRecipes.all) {
    FactoryRecipes.register(r);
  }
}

// ---- layout ----------------------------------------------------------------

/// x of the forklift aisle's west lane (two tiles wide), along the east
/// wall's truck court.
const int _aisleX = 33;

/// x of the receiving and shipping doors, east of the aisle.
const int _doorX = 35;

/// x of each final-assembly bench, east to west (its test rig stands four
/// tiles west of it).
const List<int> _assemblyX = [21, 13, 5];

/// x of the board benches along the shop walkway, west to east (a fifth
/// stands behind the easternmost).
const List<int> _benchX = [9, 13, 17, 21];

/// A fresh Electronics Plant template (each call a new blueprint the
/// caller may edit).
FloorBlueprint electronicsTemplate() {
  ensureFactoryCatalog();
  registerElectronicsChain();
  final l = TemplateLayout();
  // The walkers' muster area, mid-walkway in the board shop (the first
  // staging area is where idle hands stand).
  l.add(EntityKind.staging, 16, 8, span: (3, 1));

  // Receiving: a door in the east wall sets pallets down in a staging bay
  // on the aisle; the forklift takes them to the de-palletiser.
  l.add(EntityKind.aisle, _aisleX, 0, span: (2, 12));
  l.add(EntityKind.receivingDock, _doorX, 1,
      dir: Dir4.west, item: FactoryItems.crateSteel.id);
  l.add(EntityKind.staging, _aisleX, 0, span: (2, 3));
  l.machine(30, 0, ElectronicsRecipes.unpack);

  // Sheet by arm into the stamping press. Chassis go west by arm onto the
  // line; the skeleton north by arm into the shield press.
  l.arm(29, 1, Dir4.west);
  l.machine(26, 0, ElectronicsRecipes.stamp);
  l.arm(25, 1, Dir4.west, only: ElectronicsItems.chassis.id);
  l.beltRun(24, 5, 1, Dir4.west);
  l.arm(27, 3, Dir4.north, only: ElectronicsItems.offcut.id);
  l.machine(26, 4, ElectronicsRecipes.shield);

  // The line: each final-assembly bench takes chassis off the belt by arm
  // and hands its units by arm west to a test rig, which puts them on the
  // outbound belt. Walkers bring board kits to the benches' north side.
  for (final x in _assemblyX) {
    l.arm(x + 1, 2, Dir4.north);
    l.machine(x, 3, ElectronicsRecipes.assemble);
    l.arm(x - 1, 4, Dir4.west);
    l.machine(x - 4, 3, ElectronicsRecipes.test, mode: MachineMode.assisted);
    l.arm(x - 3, 6, Dir4.north);
  }
  // The outbound belt east to the packer, with a crossing over each
  // assembly bench's kit drop and one by the shield press.
  l.beltEast(2, 29, 7, crossings: {6, 14, 22, 25});
  l.machine(30, 7, ElectronicsRecipes.pack);

  // The board shop north of the line: four benches along the walkway and
  // a fifth behind the easternmost.
  for (final x in _benchX) {
    l.machine(x, 9, ElectronicsRecipes.board);
  }
  l.machine(21, 13, ElectronicsRecipes.board);

  // Shipping: the door beside the packer across the aisle, and the
  // forklift's charging bay.
  l.add(EntityKind.shippingDock, _doorX, 7);
  l.add(EntityKind.chargingBay, _doorX, 9);

  return FloorBlueprint(
    name: 'Electronics Plant',
    plantType: kElectronicsType,
    hall: kElectronicsHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kElectronicsWalkers,
      HandlerKind.forklift: kElectronicsForklifts,
    },
  );
}
