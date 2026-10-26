// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Electronics Plant's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6), laid for EXPLICIT PORTS (§10 item 19,
/// `station_ports.dart`).
///
/// Like every template it is a built-in [FloorBlueprint] whose MEASURED
/// rate matches the plant's flat `CityBuildingSpec` rate within 5%, whose
/// job demand is the spec's `jobs` (within 10%), and whose build cost
/// (`capexOf`) is the spec's `buildCost` (unset, so the default 40 ore).
/// Opening the floor therefore changes nothing for a colony until someone
/// designs a better one. It is "fine, not great" on purpose: almost every
/// bench is a manual pair, the stamping press has no servo assist, the
/// shield press sits at the far end of the board shop from the westmost
/// assembler, and the hall is far bigger than the line.
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
/// has ~20% headroom at that rate (the board benches 25%), so a designer
/// who speeds the press (servo assist: an operator instead of a loader
/// pair) gets ~24% more electronics (measured 0.74 /s) before the
/// de-palletiser and the benches bind: the throughput lever.
///
/// ## The floor (hall 40 × 50 tiles = 80 × 100 m)
///
/// The user's brief (2026-10-12): workers move freight with forklifts,
/// pallet jacks and cranes or on their own, and very few plants have the
/// logistics worked out to load and unload without anyone lifting a
/// finger. Under ports the rule is: belts connect at a station's input and
/// output ports, handlers work it at its hand port, and no arm touches a
/// machine (arms only lift chassis off one belt onto another). Coordinates
/// below are hall tiles, +y north; the line fills x 2..39, y 4..19.
///
///     y 19    ┌── chassis loop (buffer) ──┐
///     y 15    └─► 3..9 ─► A1↓   ◄── 12..27 ◄── STAMP ◄── steel ◄── UNPACK
///     y 13          feeder↓  arm↓      arm↓    offcut↓            ▲ forklift
///     y 10..12      A1  B    A2  B     A3       SHIELD             │ (pallets
///     y 9          crossings + shop walkway (muster at 25..27)     │  on the
///     y 6..8        T1  B    T2  B     T3   B                      │  aisle)
///     y 5     outbound belt 10 ─────────────────────► PACK ─► ship door
///
/// * **Receiving.** Steel arrives on pallets (`crate:steel`) at the
///   receiving door (38, 12), which sets them down on a staging bay on the
///   forklift aisle (x 36..37, y 7..18). The FORKLIFT takes each pallet to
///   the de-palletiser's HAND PORT (33, 17) on a pad off the aisle; walkers
///   can't lift a pallet. Two hands strip it.
/// * **Steel goes by belt.** The de-palletiser (facing west) pushes sheet
///   out of its output port onto one belt tile (31, 15), which points into
///   the stamping press's input port (30, 15).
/// * **The stamping press** (facing west, manual) has two output ports:
///   chassis leave its west port onto the CHASSIS BELT (row 15, westbound);
///   the skeleton leaves its south port onto one belt tile (29, 13) that
///   points straight into the shield press's input port below it.
/// * **Three cells.** Each is an assembler with an operator-run TEST RIG
///   under it, both facing south (x 9, 16, 23). An assembler takes chassis
///   at its north port (input 1); its units leave its south port down one
///   belt tile (a CROSSING, so walkers can step over it) into the rig's
///   north port; the rig's electronics leave its south port onto the
///   OUTBOUND BELT (row 5, eastbound) to the packer. The two eastern cells
///   get chassis from an ARM that lifts them off the chassis belt onto a
///   one-tile feeder into the port: arms never feed machines, but they do
///   move goods belt to belt, so an arm is this floor's only splitter. It
///   takes a chassis only when the feeder has room, so a full cell lets the
///   rest pass. The westmost cell is fed by the belt's own end.
/// * **The chassis loop** (see "Mass balance" below). Past the two arms the
///   belt climbs to row 19, runs west to x 2, comes back down and turns
///   into the first cell: 44 belt tiles, room for ~176 chassis.
/// * **Packing and shipping.** The packer (manual) takes electronics at its
///   input port off the outbound belt's end and pushes its crates out of
///   its output port down a three-tile belt into the shipping door
///   (38, 5). (The pre-ports floor had the forklift carry crates too, but
///   one forklift working both doors through hand ports measured 99% busy
///   and blocked the packer 29% of the time: 0.53 electronics/s.)
/// * **The board shop is hand work.** Five manual benches build board
///   kits from can trays, with no belt at any of their ports: WALKERS carry
///   trays from the shield press's hand port (27, 11) to the benches' hand
///   ports, and kits from there to the assemblers' hand ports (input 2 is
///   hand-fed while input 1 is belt-fed). Two benches stand in each gap
///   between cells, their hand ports (x 15 and 22, y 8 and 12) beside the
///   next cell's assembler hand port (y 10); the fifth stands by the shield
///   press. Walkers cross the cells on the unit crossings in row 9. A
///   bench takes trays from the nearest provider and an assembler kits
///   from the nearest bench with stock, in placement-id order, so the
///   benches nearest the press are placed (and served) first. Measured
///   over 3000 s: trays go 10-34 m ([kElectronicsTrayHaulM]), ~16 m at the
///   median; kits 4-46 m ([kElectronicsKitHaulM]), ~22 m, the westmost
///   assembler fetching from the middle gap. Those trips are the
///   template's real handling, and its weakness.
/// * **No crane.** Nothing in an electronics fab is heavier than a pallet;
///   a crane here would be a driver with nothing to lift.
///
/// The line fills the hall's south 40%; the rest is the clean-room
/// envelope, test space and stores a fab carries. It is what puts the shed
/// at its build cost, and shrinking it is a capex lever for a designer.
///
/// ## Mass balance (and the trap this layout fixed)
///
/// Per stroke the press makes 6 chassis and the skeleton that becomes 1.5
/// kits, and every 4 chassis need exactly 1 kit, so in steady state the
/// chassis and kit flows are locked 4:1. But the kit side holds a lot of
/// work in progress (offcut and trays in the presses' buffers, trays and
/// kits in five benches' buffers, kits in the assemblers' and in walkers'
/// hands), and every kit parked there leaves 4 chassis with nothing to
/// meet: a permanent chassis surplus of ~80 once the shop fills. The first
/// port draw ran the chassis belt straight to the first cell (20 tiles,
/// ~90 chassis with the buffers) and that surplus filled it: the press
/// then blocked, made less offcut, the shop fell behind, and the plant
/// settled at 0.53 electronics/s with no way back (the 4:1 lock means a
/// chassis surplus is never worked off). The loop gives the surplus
/// somewhere to wait: measured, it holds a steady 82 chassis from 300 s on
/// and the press never blocks. Shortening the loop is NOT a free capex win.
///
/// **Levers a designer has** (the Reward section): servo-assist the press
/// (more output), give the benches and assemblers an operator each
/// (assisted: one job instead of two, and faster), put a bench beside the
/// westmost assembler or the shield press in the middle of the shop so the
/// walkers' hauls shrink, or shrink the hall.
///
/// ## Measuring it (BLOCKING for whoever wires it in)
///
/// The line holds ~180 units of work in progress (≈82 chassis on the loop,
/// ~14 staged steel pallets, trays, kits and units), so the first crate
/// ships at ~212 s. It ships in crates of ten, so a 300 s window is ±1-2
/// crates (±5-11%) even once warm. Under `MeasureSettings.standard` (60 s
/// warm-up, 300 s window) a fresh floor therefore reads 0.57 steel / 0.30
/// electronics per second, half the spec. So template floors must be
/// measured with [kElectronicsMeasureSettings] (warm-up ≥ 300 s, window ≥
/// 1200 s), which `measureSettingsFor('electronics')` returns.
///
/// ## Registration (BLOCKING for whoever wires it in)
///
/// The 'electronics:*' items and recipes exist only once
/// [registerElectronicsChain] has run in THAT isolate;
/// `ensureFactoryCatalog` registers only the Steel chain. So the lead must
/// also (1) call [registerElectronicsChain] wherever the catalog is ensured
/// (inside `ensureFactoryCatalog`, or a chain list it walks), or a save
/// holding an electronics floor fails to load (`FactoryFloor.fromJson`)
/// in a process that has not built the template yet; and (2) pass it as
/// the `FloorWorkerSetup` of the `FloorMeasureRunner`, whose worker
/// isolate starts with empty statics. It is a complete setup on its own
/// (it ensures the base catalog too).
///
/// Jobs: 12 manual stations × 2 + 3 assisted test rigs × 1 + 1 forklift
/// driver + [kElectronicsWalkers] walkers = 41, the spec's 40 within 3%.
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
const String kElectronicsType = 'electronics';

/// Hall: 40 × 50 tiles = 80 × 100 m, well inside the 600 × 450 m campus.
/// The line uses the south 40%; the rest is the clean-room envelope a fab
/// carries, sized so the whole floor costs the spec's 40 ore (`capexOf`,
/// measured 39.9).
const HallSize kElectronicsHall = HallSize(40, 50);

/// Workers on foot carrying can trays and board kits, one at a time,
/// 0.3 trips/s in all. Measured: eleven hold the spec rate within 1.5%,
/// twelve exactly; thirteen keeps one spare so a busy moment never starves
/// a bench (and is the headcount the leaner design trims).
const int kElectronicsWalkers = 13;

/// How a template floor of this plant must be measured (see "Measuring
/// it" in the library doc). 300 s of warm-up: the first crate ships at
/// ~212 s and the chassis loop has settled by 300 s. 1200 s of window: one
/// crate of ten is 1.4% of the ~720 units shipped, so crate lumps stay
/// well inside the ±5% template budget (measured: exactly 0.6 /s for every
/// warm-up from 300 to 540 s).
const MeasureSettings kElectronicsMeasureSettings =
    MeasureSettings(warmupS: 300, windowS: 1200);

/// Longest shield-can tray haul a walker makes, press to bench, in metres
/// (measured over 3000 s: the press's hand port to the west gap's benches,
/// 17 tiles of path). Pinned by a test so the doc's handling figures can't
/// drift from the layout.
const double kElectronicsTrayHaulM = 34;

/// Longest board-kit haul, bench to assembly bench, in metres (measured:
/// 23 tiles, a far bench to the westmost assembler).
const double kElectronicsKitHaulM = 46;

/// One forklift works the receiving door: 0.05 steel pallets/s from the
/// staging bay to the de-palletiser's hand port, a hop of a few metres, with
/// time to charge (measured: its equipment runs ~46% of the time).
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

/// Registers the chain's items and recipes, and the base catalog they
/// build on, so it is a complete `FloorWorkerSetup` on its own (see
/// "Registration" in the library doc). Idempotent: the registries accept
/// the identical const object twice.
void registerElectronicsChain() {
  ensureFactoryCatalog();
  for (final i in ElectronicsItems.all) {
    FactoryItems.register(i);
  }
  for (final r in ElectronicsRecipes.all) {
    FactoryRecipes.register(r);
  }
}

// ---- layout ----------------------------------------------------------------

/// x of the forklift aisle (two tiles wide) along the truck court.
const int _aisleX = 36;

/// x of the receiving and shipping doors, east of the aisle.
const int _doorX = 38;

/// x of each final-assembly cell's west column, west to east: the
/// assembler on top, its test rig below, both facing south.
const List<int> _cellX = [9, 16, 23];

/// Row of the chassis belt (westbound, over the cells).
const int _chassisY = 15;

/// Row of the outbound electronics belt (eastbound, under the cells).
const int _outY = 5;

/// A fresh Electronics Plant template (each call a new blueprint the
/// caller may edit).
FloorBlueprint electronicsTemplate() {
  ensureFactoryCatalog();
  registerElectronicsChain();
  final l = TemplateLayout();
  // The walkers' muster area on the shop walkway by the shield press (the
  // first staging area is where idle hands stand).
  l.add(EntityKind.staging, 25, 9, span: (3, 1));

  // Receiving: pallets set down on the aisle; the forklift takes them to
  // the de-palletiser's hand port (33, 17) on a pad off the aisle.
  l.add(EntityKind.aisle, _aisleX, 7, span: (2, 12));
  l.add(EntityKind.receivingDock, _doorX, 12,
      dir: Dir4.west, item: FactoryItems.crateSteel.id);
  l.add(EntityKind.staging, _aisleX, 11, span: (2, 3));
  l.add(EntityKind.aisle, 33, 17, span: (3, 2));
  l.machine(32, 15, ElectronicsRecipes.unpack, dir: Dir4.west);

  // Steel: the de-palletiser's port (32, 15) onto (31, 15), into the
  // stamping press's input port (30, 15).
  l.add(EntityKind.belt, 31, 15, dir: Dir4.west);
  l.machine(28, 14, ElectronicsRecipes.stamp, dir: Dir4.west);
  // Chassis leave its west port (28, 15) onto the chassis belt; the
  // skeleton its south port (29, 14) onto (29, 13), which points straight
  // into the south-facing shield press's input port (29, 12). The shield
  // press has no belt at its output port: its trays wait at its hand port.
  l.beltRun(27, 12, _chassisY, Dir4.west);
  // Past the two arms (x 24 and 17) the belt loops north to row 19, west to
  // x 2 and back east along row 15 (the chassis buffer, see "Mass balance"
  // in the library doc) before it turns down column 10 into the first
  // cell's input port (10, 12).
  l.beltRun(_chassisY, 18, 11, Dir4.north);
  l.beltRun(11, 3, 19, Dir4.west);
  l.beltRun(19, 16, 2, Dir4.south);
  l.beltRun(2, 9, _chassisY, Dir4.east);
  l.add(EntityKind.belt, 29, 13, dir: Dir4.south);
  l.machine(28, 10, ElectronicsRecipes.shield, dir: Dir4.south);

  // The cells, every station facing south. An assembler at (x, 10) takes
  // chassis at its input port (x+1, 12) from (x+1, 13): the westmost from
  // the belt's own end, the others from an arm that lifts them off the
  // chassis belt (x+1, 15) onto that one-tile feeder. Its units leave its
  // output port (x+1, 10) down the crossing (x+1, 9) into the rig's input
  // port (x+1, 8); the rig's electronics leave (x+1, 6) onto the outbound
  // belt (x+1, 5). The assembler's hand port opens onto (x-1, 10), where
  // walkers bring board kits.
  for (final x in _cellX) {
    if (x == _cellX.first) {
      l.beltRun(_chassisY, 13, x + 1, Dir4.south);
    } else {
      l.arm(x + 1, 14, Dir4.south);
      l.add(EntityKind.belt, x + 1, 13, dir: Dir4.south);
    }
    l.machine(x, 10, ElectronicsRecipes.assemble, dir: Dir4.south);
    l.add(EntityKind.crossing, x + 1, 9, dir: Dir4.south);
    l.machine(x, 6, ElectronicsRecipes.test,
        dir: Dir4.south, mode: MachineMode.assisted);
  }
  // The outbound belt into the packer's input port (32, 5); its crates
  // leave its output port (34, 5) down a belt into the shipping door.
  l.beltEast(_cellX.first + 1, 31, _outY);
  l.machine(32, 4, ElectronicsRecipes.pack);
  l.beltEast(35, 37, _outY);

  // The board shop, every bench facing north so its hand port opens on its
  // east side: two benches in each gap between cells (hand ports at y 8
  // and 12, beside the next cell's assembler hand port at y 10), and a
  // fifth by the shield press, whose hand port is (27, 11). Placed nearest
  // the press first: hand-fed inputs pull in placement-id order, so the
  // nearest benches get the trays first and the walks stay short.
  l.machine(26, 6, ElectronicsRecipes.board, dir: Dir4.north);
  for (final x in [19, 12]) {
    l.machine(x, 10, ElectronicsRecipes.board, dir: Dir4.north);
    l.machine(x, 6, ElectronicsRecipes.board, dir: Dir4.north);
  }

  // Shipping: the door beside the aisle, and the forklift's charging bay.
  l.add(EntityKind.shippingDock, _doorX, _outY);
  l.add(EntityKind.chargingBay, _doorX, 8);

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
