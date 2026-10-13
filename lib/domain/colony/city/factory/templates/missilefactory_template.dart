// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Missile Plant's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6).
///
/// Like every template it must measure at the spec's flat rate (within
/// 5%), staff the spec's jobs and cost the spec's build ore, so opening the
/// floor changes nothing for a colony — and it must be "fine, not great",
/// so a designer has something to win. It is the plan's first real
/// MULTI-INPUT assembly: three goods arrive by three different routes and
/// meet at one station, which is where the layout puzzle is.
///
/// ## Spec: 0.4 tubes + 0.2 rocket parts + 0.2 electronics → 0.15 missiles /s, 60 jobs
///
/// Mass balance per second at the spec rate (commodity units; ten-unit
/// pallets of tubes and crates of electronics arrive, rocket parts come
/// loose because they are crane work):
///
///     0.04 tube pallets ─unpack─► 0.4 tubes ─weld (8:3)──► 0.15 airframes ─┐
///     0.02 elec. crates ─unpack─► 0.2 electronics ─(4:3)─► 0.15 guidance ──┼─integrate─► 0.15 rounds ─test─► 0.15 missiles
///     0.2 rocket parts ───────────────────cast (4:3)─────► 0.15 motors ────┘
///
/// Nothing else leaves and nothing else comes in: the chain has no
/// byproduct, and every intermediate is used up inside the hall.
///
/// ## Who sets the pace
///
/// The TEST CELL does. Each line's checkout station (manual) certifies
/// exactly 0.075 missiles/s; every station upstream has 20-150% slack. A
/// pacing station at the END of the chain, fed by an arm from the station
/// before it, is what makes the measured rate exact: its input buffer is
/// always full once the floor has settled, and its output is lifted by a
/// crane that has nothing else to do. Put the pacing anywhere upstream and
/// the template measures a few percent high for a long while as start-up
/// stock drains through the faster stations after it. It is also how real
/// munitions lines run: acceptance testing, not machining, is the
/// bottleneck. A fresh floor settles in about 8 minutes of sim time (empty
/// buffers, every walker busy at once); after that, input and output rates
/// are flat.
///
/// ## Layout (44 × 28 tiles = 88 × 56 m, two mirrored lines)
///
/// Row 27 at the top, x = 0 at the west wall:
///
///     27 .....................................::.....
///     26 ~~CCC................................::.....
///     25 SSCCC................................::.....
///     24 ~~CCC................................::.....
///     23 ...a.................................::.....
///     22 ..III.....PPP........................::.....
///     21 ..IIIa<<<aPPP........................::.....
///     20 ..III.....PPP........................::.....
///     19 ...a..GGG............................::.....
///     18 ..MMMMGGG.GGG........................::.....
///     17 ..MMMMGGG.GGG........................::___..
///     16 ..MMMM....GGG..TTTEEE................::___RR    R electronics crates
///     15 ..MMMM.........TTTEEE................::___..
///     14 ..____.......___:::::::::::::::::::::::cc...    c forklift charger
///     13 RR____.......___:::::::::::::::::::::::cc...    R rocket parts
///     12 ..MMMM.........TTTEEE................::___..
///     11 ..MMMM....GGG..TTTEEE................::___RR    R tube pallets
///     10 ..MMMMGGG.GGG........................::___..
///      9 ..MMMMGGG.GGG........................::.....
///      8 ...a..GGG............................::.....
///      7 ..III.....PPP........................::.....
///      6 ..IIIa<<<aPPP........................::.....
///      5 ..III.....PPP........................::.....
///      4 ...a.................................::.....
///      3 ~~CCC................................::.....
///      2 SSCCC................................::.....
///      1 ~~CCC................................::.....
///      0 .....................................::.....
///
///     C test cell   I integration   M motor cell   G guidance bench
///     P airframe welder   T tube unpacking   E electronics unpacking
///     a arm   < belt   S missile door   ~ crane runway   : aisle
///     _ staging: receiving at each door, and the walkers' muster area at
///       the head of the centre aisle. The motor crane's runway (not
///       drawn) spans rows 11-16 over both motor cells and the parts
///       staging between them.
///
/// * **Receiving is people and forklifts.** Tube pallets and electronics
///   crates are set down in staging at two east-wall doors. Forklifts run
///   them down the centre aisle to the unpacking stations line-side (a
///   real plant's kitting), and charge at the bay between the doors.
/// * **Walkers carry the hand loads**: loose tubes to the welders,
///   electronics to the guidance benches, and finished guidance sections
///   one step over to integration. Those three walks are the template's
///   handling work and its biggest lever.
/// * **The airframe line is a belt** where flow is steady: each welder
///   drops its sections onto a three-tile conveyor that an arm empties
///   into the integration fixture. It is short on purpose — a long belt is
///   a buffer, and a buffer that takes twenty minutes to fill would make a
///   fresh floor measure high on tubes for that long.
/// * **The heavy work is under cranes.** Rocket parts are lifted off the
///   west-wall door by the motor crane into the two motor cells either
///   side of it; a jib arm sets each motor into integration; a crane over
///   each test cell lowers certified missiles onto the truck at the west
///   wall's missile doors (rounds and missiles are heavy: no walker or
///   forklift may touch them).
/// * **The motor cells are lights-out**, the template's one automated
///   station kind: propellant work is done remotely behind blast walls, a
///   technician's quarter-share each. Everything else is crewed: manual
///   stations with two hands each.
/// * **The open floor east of the lines** is the forklift run and the
///   separation between the receiving doors and the propellant cells that
///   the spec's "blast-distance spacing" asks for. It is also floor a
///   designer can give back (hall area is build cost).
///
/// Jobs: 14 manual stations × 2 + 2 lights-out cells × ¼ technician + 3
/// crane drivers + 3 forklift drivers + 26 walkers = 60.5, the spec's 60.
/// Build cost (`capexOf`) ≈ 40 ore, the spec's default `buildCost`.
///
/// "Fine, not great": the walkers are ~65% busy once settled, most
/// stations idle half the time, and every station but the motor cells is
/// manual. Measured: one operator per station upstream of the test cells
/// holds 0.15 missiles/s on 48.5 jobs (a fifth fewer); assisted test cells
/// lift the plant to 0.18/s on the same floor before the walkers run out;
/// shorter walks free walkers (22 still hold the rate, 20 fall 12% short).
///
/// **Settling.** The colony's default measurement (`MeasureSettings`:
/// 60 s warm-up, ≤ 300 s window) catches this floor mid-start-up and reads
/// it far off its steady state; measure templates with a warm-up of ten
/// minutes or more.
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
const String kMissileType = 'missilefactory';

/// The Missile Plant chain's own intermediates. Ids are saved: never
/// rename. Every colony good it touches (tubes, electronics, rocket parts,
/// missiles and their packs) is `FactoryItems`' own.
class MissileItems {
  MissileItems._();

  /// A welded airframe section: a pallet load (jack or forklift), though
  /// the template moves it by belt and arm only.
  static const airframe = FactoryItem(
      id: 'missilefactory:airframe', label: 'Airframe Section',
      loadClass: LoadClass.pallet, kgPerUnit: 210);

  /// A guidance and control section: avionics a person carries in both
  /// arms.
  static const guidance = FactoryItem(
      id: 'missilefactory:guidance', label: 'Guidance Section',
      loadClass: LoadClass.hand, kgPerUnit: 13);

  /// A cast solid-rocket motor: light enough to lift, but live propellant
  /// is only ever moved by hoist, so it is heavy-class (crane or arm).
  static const motor = FactoryItem(
      id: 'missilefactory:motor', label: 'Rocket Motor',
      loadClass: LoadClass.heavy, kgPerUnit: 130);

  /// An integrated missile before acceptance test: crane work, as the
  /// certified missile it becomes.
  static const round = FactoryItem(
      id: 'missilefactory:round', label: 'Untested Missile',
      loadClass: LoadClass.heavy, kgPerUnit: 1000);

  static const all = [airframe, guidance, motor, round];
}

/// Recipes of the Missile Plant chain. Ids are saved: never rename.
///
/// Per-line need at the spec rate is 0.075 missiles/s (two lines). A
/// manual station runs at speed 0.6, an automated one at 1.3
/// ([MachineMode]). Every station but the test cell has slack, so the test
/// cell IS the plant's rate (see the library doc).
class MissileRecipes {
  MissileRecipes._();

  static const unpackTubes = FactoryRecipe(
    id: 'missilefactory:unpackTubes',
    label: 'Break Tube Pallet',
    station: StationKind.unpacker,
    inputs: [ItemQty('crate:tubes', 1)],
    outputs: [ItemQty('tubes', 10)],
    // 12 s: a manual station (20 s a pallet) frees 0.5 tubes/s against its
    // line's 0.2 — cutting straps and counting tubes is quick work.
    seconds: 12,
    // A strap cutter and a roller table: a few kW.
    powerKw: 5,
  );

  static const unpackElectronics = FactoryRecipe(
    id: 'missilefactory:unpackElectronics',
    label: 'Unpack Electronics',
    station: StationKind.unpacker,
    inputs: [ItemQty('crate:electronics', 1)],
    outputs: [ItemQty('electronics', 10)],
    // 24 s: a manual station (40 s a crate) frees 0.25 units/s against its
    // line's 0.1. Twice the tube time: static-safe unpacking and goods-in
    // inspection of every board.
    seconds: 24,
    // An ESD bench and its ionisers.
    powerKw: 5,
  );

  static const airframe = FactoryRecipe(
    id: 'missilefactory:airframe',
    label: 'Weld Airframes',
    station: StationKind.press,
    // Eight tube sections cut, rolled and welded into three bodies.
    inputs: [ItemQty('tubes', 8)],
    outputs: [ItemQty('missilefactory:airframe', 3)],
    // 12 s: a manual welder (20 s) makes 0.15 sections/s, twice its line's
    // 0.075, so the short belt after it fills in a minute or two.
    seconds: 12,
    // Orbital welders and a stress-relief oven: the hall's biggest crewed
    // draw.
    powerKw: 150,
  );

  static const guidance = FactoryRecipe(
    id: 'missilefactory:guidance',
    label: 'Build Guidance',
    station: StationKind.assembler,
    inputs: [ItemQty('electronics', 4)],
    outputs: [ItemQty('missilefactory:guidance', 3)],
    // 30 s: fiddly hand work — a manual bench (50 s) makes 0.06 sections/s,
    // so each line has two benches (0.12) against its 0.075.
    seconds: 30,
    // Soldering, harness testers and clean-bench air.
    powerKw: 20,
  );

  static const motor = FactoryRecipe(
    id: 'missilefactory:motor',
    label: 'Cast Motors',
    station: StationKind.chem,
    // A batch: cases, nozzles, igniters and propellant ingredients for
    // three motors come as four units of parts (the spec's 0.2 : 0.15).
    inputs: [ItemQty('rocketParts', 4)],
    outputs: [ItemQty('missilefactory:motor', 3)],
    // 26 s: a lights-out cell (20 s at speed 1.3) casts 0.15 motors/s,
    // twice its line's 0.075, so its buffers fill fast at start-up.
    seconds: 26,
    // Propellant mixers, a curing oven and remote handling.
    powerKw: 200,
  );

  static const integrate = FactoryRecipe(
    id: 'missilefactory:integrate',
    label: 'Integrate Missile',
    station: StationKind.assembler,
    inputs: [
      ItemQty('missilefactory:airframe', 1),
      ItemQty('missilefactory:motor', 1),
      ItemQty('missilefactory:guidance', 1),
    ],
    outputs: [ItemQty('missilefactory:round', 1)],
    // 5 s: a manual fixture (8.3 s) mates 0.12 missiles/s against 0.075 —
    // enough slack to ride out a late guidance section, the one input a
    // person brings.
    seconds: 5,
    // Mating fixture hoists and torque tools.
    powerKw: 60,
  );

  static const checkout = FactoryRecipe(
    id: 'missilefactory:checkout',
    label: 'Test & Certify',
    station: StationKind.assembler,
    inputs: [ItemQty('missilefactory:round', 1)],
    outputs: [ItemQty('missiles', 1)],
    // 8 s: a manual test cell (13.3 s) certifies exactly 0.075 missiles/s,
    // its line's share of the spec's 0.15. The pacing station: no slack on
    // purpose.
    seconds: 8,
    // Telemetry rack, X-ray of the motor grain, environmental soak.
    powerKw: 40,
  );

  static const all = [
    unpackTubes, unpackElectronics, airframe, guidance, motor, integrate,
    checkout,
  ];
}

bool _registered = false;

/// Registers the Missile Plant intermediates and recipes. Idempotent: the
/// registries accept the identical const object twice, and the flag skips
/// the work.
void registerMissileChain() {
  if (_registered) return;
  for (final i in MissileItems.all) {
    FactoryItems.register(i);
  }
  for (final r in MissileRecipes.all) {
    FactoryRecipes.register(r);
  }
  _registered = true;
}

/// Missile Plant hall: 44 × 28 tiles = 88 × 56 m — the two lines and the
/// heavy column on the west wall, the receiving doors and their aisle on
/// the east wall, and the open forklift run between (hall area is build
/// cost; this is what brings the template to the spec's 40 ore).
const HallSize kMissileHall = HallSize(44, 28);

/// x of the east forklift aisle's west lane (two tiles wide). East of it:
/// three tiles of staging, then the receiving doors on the wall.
const int _aisleX = 37;

/// x of each line's tube and electronics unpacking stations, on the centre
/// aisle. Measured: here the walkers' three walks keep ~17 of them busy;
/// a few tiles further east the walks grow and that slack is gone.
const int _tubesX = 15;
const int _elecX = 18;

/// Workers on foot: tubes (0.4/s), electronics (0.2/s) and guidance
/// sections (0.15/s), one per trip. Measured ~17 busy once settled; 22
/// hold the rate with no slack, 20 fall 12% short. 26 brings the floor to
/// the spec's 60 jobs and keeps spare hands for the start-up rush, when
/// every station wants stock at once.
const int kMissileWalkers = 26;

/// Forklifts running pallets and crates from the east doors to the four
/// unpacking stations, ~25 tiles each way: about two busy, the third
/// covering charging.
const int kMissileForklifts = 3;

/// One crane on the motor runway, one over each test cell.
const int kMissileCranes = 3;

/// A y for line A as itself, for line B mirrored about the hall's middle
/// (a footprint [h] rows tall at [y]).
int _my(bool lineB, int y, [int h = 1]) =>
    lineB ? kMissileHall.h - y - h : y;

/// One assembly line: test cell, integration and motor cell in the heavy
/// column, the airframe welder on its belt, two guidance benches and the
/// line's unpacking stations. Line A is drawn; line B is its mirror.
void _line(TemplateLayout l, bool b) {
  // "Down the column", towards the line's missile door.
  final out = b ? Dir4.north : Dir4.south;
  // Test cell at the wall, its crane runway over it and the missile door.
  l.machine(2, _my(b, 1, 3), MissileRecipes.checkout);
  l.add(EntityKind.shippingDock, 0, _my(b, 2), item: 'missiles');
  l.add(EntityKind.craneBay, 0, _my(b, 1, 3), span: (5, 3));
  // Integration hands each round to the test cell by arm …
  l.arm(3, _my(b, 4), out);
  l.machine(2, _my(b, 5, 3), MissileRecipes.integrate);
  // … and takes its motors by jib arm from the lights-out cell.
  l.arm(3, _my(b, 8), out);
  l.machine(2, _my(b, 9, 4), MissileRecipes.motor,
      mode: MachineMode.automated);
  // Airframes by a short belt from the welder.
  l.arm(5, _my(b, 6), Dir4.west);
  l.beltRun(8, 6, _my(b, 6), Dir4.west);
  l.arm(9, _my(b, 6), Dir4.west);
  l.machine(10, _my(b, 5, 3), MissileRecipes.airframe);
  // Guidance benches: the first one step from integration's fixture.
  l.machine(6, _my(b, 8, 3), MissileRecipes.guidance);
  l.machine(10, _my(b, 9, 3), MissileRecipes.guidance);
  // Unpacking, line-side on the centre aisle.
  l.machine(_tubesX, _my(b, 11, 2), MissileRecipes.unpackTubes);
  l.machine(_elecX, _my(b, 11, 2), MissileRecipes.unpackElectronics);
}

/// A fresh Missile Plant template (each call a new blueprint the caller
/// may edit).
FloorBlueprint missilefactoryTemplate() {
  ensureFactoryCatalog();
  registerMissileChain();
  final l = TemplateLayout();
  // The walkers' muster area first: the first staging area is where idle
  // walkers wait (`FactoryFloor`), so it sits between the lines' walks.
  l.add(EntityKind.staging, 13, 13, span: (3, 2));
  _line(l, false);
  _line(l, true);
  // Rocket parts: the west-wall door sets them down between the motor
  // cells, under the motor crane's runway.
  l.add(EntityKind.staging, 2, 13, span: (4, 2));
  l.add(EntityKind.receivingDock, 0, 13, item: 'rocketParts');
  l.add(EntityKind.craneBay, 2, 11, span: (4, 6));
  // The forklift aisles: down the east wall, and along the centre to the
  // unpacking stations.
  l.add(EntityKind.aisle, _aisleX, 0, span: (2, kMissileHall.h));
  l.add(EntityKind.aisle, 13, 13, span: (_aisleX - 13, 2));
  // East-wall receiving: tube pallets, electronics crates, the charger
  // between them.
  l.add(EntityKind.staging, _aisleX + 2, 10, span: (3, 3));
  l.add(EntityKind.receivingDock, _aisleX + 5, 11,
      dir: Dir4.west, item: 'crate:tubes');
  l.add(EntityKind.staging, _aisleX + 2, 15, span: (3, 3));
  l.add(EntityKind.receivingDock, _aisleX + 5, 16,
      dir: Dir4.west, item: 'crate:electronics');
  l.add(EntityKind.chargingBay, _aisleX + 2, 13);
  return FloorBlueprint(
    name: 'Missile Plant',
    plantType: kMissileType,
    hall: kMissileHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kMissileWalkers,
      HandlerKind.forklift: kMissileForklifts,
      HandlerKind.crane: kMissileCranes,
    },
  );
}
