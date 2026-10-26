// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Missile Plant's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6), laid for EXPLICIT PORTS (§10 item 19,
/// `station_ports.dart`).
///
/// Like every template it must measure at the spec's flat rate (within
/// 5%), staff the spec's jobs and cost the spec's build ore, so opening the
/// floor changes nothing for a colony; and it must be "fine, not great",
/// so a designer has something to win. It is the plan's first real
/// MULTI-INPUT assembly: three goods arrive by three routes and meet at one
/// fixture, each through its own port.
///
/// ## Spec: 0.4 tubes + 0.2 rocket parts + 0.2 electronics → 0.15 missiles /s, 60 jobs
///
/// Mass balance per second at the spec rate (commodity units; every colony
/// good arrives LOOSE, one unit an item; see "Measured the way the colony
/// measures" for why):
///
///     0.4 tubes ──saw (2:3)──► 0.6 segments ──weld (4:1)──► 0.15 airframes ─┐
///     0.2 electronics ─kit (1:3)─► 0.6 boards ─build (4:1)─► 0.15 guidance ─┼─integrate─► 0.15 rounds ─test─► 0.15 missiles
///     0.2 rocket parts ─kit (1:3)─► 0.6 motor kits ─cast (4:1)─► 0.15 motors ┘
///
/// Nothing else leaves and nothing else comes in: the chain has no
/// byproduct, and every intermediate is used up inside the hall.
///
/// ## The port rules, and what they decide here
///
/// A belt feeds a machine only into an input port, pointing in, with that
/// slot's item; outputs leave only by their output port; arms never touch a
/// machine; handlers work a machine only at its hand port. So:
///
/// * **Integration takes each part by a different door.** Its recipe lists
///   the airframe, the motor and guidance in that order, so motors drop
///   down a belt into input 2 (the top), guidance comes up a belt into
///   input 3 (bottom middle, from (15, 15) beside the forklift pad), and
///   airframes come by forklift to the hand port (bottom right). Input 1
///   (the west face) is left bare.
/// * **Hand ports open onto each other, so handlers don't travel.** The
///   welder faces west BELOW the forklift pad, so its hand port (16, 13)
///   opens onto (16, 14), right under integration's (16, 15): a forklift
///   parked on the 2 × 2 pad covers both, and a lift is a pick and a
///   set-down. The two saws' hand ports (one saw faces north, one east)
///   open onto the tube staging column itself, which is also the walkers'
///   muster: a walker picks a tube where he stands and drops it at most
///   two tiles on. The motor-kitting station faces west so its hand port
///   opens onto the rocket-parts staging, under the crane's hook.
/// * **Electronics never needs a hand.** Arms are allowed to work staging,
///   so two arms swing ESD totes off the electronics staging onto two
///   one-tile belts into the two kitting benches' input ports.
///
/// ## Measured the way the colony measures
///
/// The colony re-measures a plant with `MeasureSettings.standard` (60 s of
/// warm-up, then at most 300 s, stopping early when a 30 s sub-window
/// agrees with the running mean), from a FRESH floor whenever its editor
/// closes. Three rules follow, and the template is built around them:
///
/// * **Settle inside a minute.** The pace is set at the FRONT: the three
///   kitting stations, the only ones that take a colony good, run flat out
///   at exactly the spec's input rates (two saws at 0.2 tubes/s each, two
///   electronics benches at 0.1 units/s, one motor-kitting station at 0.2).
///   Everything after them has a quarter's slack, so nothing downstream
///   ever fills up: there is no start-up stock to build or drain, and the
///   one transient is the pipeline's first pass. Every move on that
///   critical path is a belt, an arm, a crane hook over both ends or a
///   forklift parked across both, and the belts are short (the missile belt
///   is three tiles: the east wall is drawn close for it), so the first
///   missiles ship inside the warm-up minute and the backlog of the first
///   pass clears inside the window.
/// * **Hand-fed stations wait for nobody far away.** A station asks for
///   only two crafts' worth of each input, so a handler's round trip from
///   where he idles must be well under two cycles, or the station starves
///   while the plant looks overstaffed. Walkers idle at the first staging
///   area (here the tube staging, which both saws' hand ports touch) and
///   vehicles park where they finished (on the pad over both hand ports).
///   The first port draft fed the benches from a staging 25 tiles from the
///   muster and two welders five tiles apart; both read 40% low.
/// * **Lumps small next to 300 s, and never equal.** Goods come loose,
///   never in packs: the biggest lump here (a saw's two tubes) is under 2%
///   of a 300 s window. Every stream runs in a 20 s rhythm: both saws feed
///   ONE welder, which welds 3 sections every 20 s; the guidance bench
///   builds 3 sections every 20 s from the two benches' boards; the casting
///   cell casts 3 motors every 20 s. So the plant ships exactly 9 missiles
///   in every 60 s, and two 30 s sub-windows in a row always count 4 and 5
///   (in some order): the early stop can never catch a lucky run of equal
///   lumps, and the colony measures the full 300 s, 45 missiles. (The first
///   draft's two welders, each paced by its own saw, welded in 40 s rhythms
///   and sent sections in clumps; a floor saved at 711 s read 4, 4, 4 and
///   stopped at 0.133 missiles/s.)
///
/// ## Layout (26 × 80 tiles = 52 × 160 m; the working floor, rows 0-26)
///
/// x = 0 at the west wall, y = 0 at the south wall, north up:
///
///     26 .....EEE..................   R receiving doors: tubes (south
///     25 .._a>EEEv............___RR     wall), electronics (west), rocket
///     24 .._..EEEv............___..     parts (east); D the missile door
///     23 .._.....v.......MMMM.KKK..   _ staging at each door
///     22 RR_..EEEv......vMMMM<KKK..   S tube saws (pace)
///     21 .._a>EEEv......vMMMM.KKK..   E electronics kitting (pace)
///     20 .._..EEEv......vMMMM......   K motor kitting (pace)
///     19 ........v......v..........   W the welder   G guidance bench
///     18 ........v.....III.TTT.....   M lights-out motor casting cell
///     17 ........v.....III>TTT>>>DD   I integration  T test cell
///     16 ........vGGG..III.TTT.....   : forklift pad c forklift charger
///     15 ........>GGG>>>^::cc......   < > ^ v belts  a arms
///     14 .........GGG....::cc......
///     13 ...............WWW........   The crane runway (not drawn) spans
///     12 ...............WWW<.......   x 21-23, rows 23-25: the hook works
///     11 ...............WWW^.......   (21, 24), the rocket-parts staging
///     10 ..................^.......   tile under the kitting station's
///      9 ..................^.......   hand port, so a lift never travels.
///      8 .........>>>>>>>>>^.......
///      7 .........^SSS.....^.......
///      6 .........^SSS>>>>>^.......
///      5 .........^SSS.............
///      4 .........^._..............
///      3 ........SSS_..............
///      2 ........SSS_..............
///      1 ........SSSR..............
///      0 ...........R..............
///
/// * **People at the docks.** Tubes are set down in the staging column
///   inside the south door, and workers on foot carry them one at a time
///   into the saws' hand ports, (11, 2) and (11, 4), both on that column.
/// * **Belts where flow is steady**: the saws' segments (the west saw's up
///   column 9 and along row 8, the east saw's along row 6, meeting in
///   column 18) into the welder's input port; boards down column 8 into
///   the guidance bench; guidance along row 15 and up into integration;
///   kits, motors and
///   untested rounds (the heavy loads, never carried by hand); and
///   certified missiles out to their door.
/// * **A crane for the heavy freight**: rocket parts off their staging into
///   the motor-kitting station, hook over both.
/// * **Forklifts in the core**: welded airframe sections are pallet loads,
///   lifted from the welder's hand port to integration's across the pad.
/// * **Crewed stations.** Everything is manual (two hands each) but the
///   motor casting cell, the one lights-out station: propellant is cast
///   remotely behind blast walls, a technician's quarter-share.
/// * **The open floor** north of row 26 (rows 27-79) is the separation the
///   spec's "blast-distance spacing" asks for between the propellant line
///   and the rest of the site, and room to grow. Hall area is build cost,
///   and it is what brings the template to the spec's 40 ore: a designer
///   can give it back.
///
/// Jobs: 9 manual stations × 2 + the casting cell's ¼ technician + 1 crane
/// driver + 2 forklift drivers + 38 walkers = 59.25, the spec's 60. Build
/// cost (`capexOf`) 39.09 ore (hall 22.02, machines 11.40, conveyors 2.34,
/// staging 0.15, vehicles 3.18), the spec's 40 within 3%.
///
/// "Fine, not great": the floor is staffed the way a plant that never
/// studied its docks is. Four walkers keep the saws fed (two fall 5%
/// short), so releasing most of the 38 holds 0.15 missiles/s on as few as
/// 25 jobs; crewing the three kitting stations as assisted (faster) lifts
/// the plant to 0.1875 missiles/s, the welder's ceiling, on the same
/// floor.
///
/// Measured (`InfiniteColonyPort`): with `MeasureSettings.standard` from a
/// fresh floor, tubes 0.400, electronics 0.200, rocket parts 0.200 and
/// missiles 0.150, the full 300 s; re-measured from floors saved at 100 s
/// to 1500 s, the same at every phase; 600 s + 2400 s, the same. Mean draw
/// 645 kW (`measureBlueprint(...).powerKw`).
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
/// missiles) is `FactoryItems`' own.
class MissileItems {
  MissileItems._();

  /// A cut, rolled and seam-welded shell segment: one person's carry.
  static const segment = FactoryItem(
      id: 'missilefactory:segment', label: 'Shell Segment',
      loadClass: LoadClass.hand, kgPerUnit: 52);

  /// A welded airframe section: a pallet load (jack or forklift).
  static const airframe = FactoryItem(
      id: 'missilefactory:airframe', label: 'Airframe Section',
      loadClass: LoadClass.pallet, kgPerUnit: 210);

  /// A populated, goods-in-tested circuit board.
  static const board = FactoryItem(
      id: 'missilefactory:board', label: 'Guidance Board',
      loadClass: LoadClass.hand, kgPerUnit: 3);

  /// A guidance and control section: avionics a person carries in both
  /// arms.
  static const guidance = FactoryItem(
      id: 'missilefactory:guidance', label: 'Guidance Section',
      loadClass: LoadClass.hand, kgPerUnit: 13);

  /// A quarter of one motor's case, nozzle, igniter and propellant charge,
  /// inspected and kitted. Propellant is never carried by hand, so it is
  /// heavy-class: it rides a belt (or a crane hook).
  static const motorKit = FactoryItem(
      id: 'missilefactory:motorKit', label: 'Motor Kit',
      loadClass: LoadClass.heavy, kgPerUnit: 33);

  /// A cast solid-rocket motor: belt or crane work, like its kits.
  static const motor = FactoryItem(
      id: 'missilefactory:motor', label: 'Rocket Motor',
      loadClass: LoadClass.heavy, kgPerUnit: 130);

  /// An integrated missile before acceptance test: a tonne, belt or crane
  /// work, like the certified missile it becomes.
  static const round = FactoryItem(
      id: 'missilefactory:round', label: 'Untested Missile',
      loadClass: LoadClass.heavy, kgPerUnit: 1000);

  static const all = [
    segment, airframe, board, guidance, motorKit, motor, round,
  ];
}

/// Recipes of the Missile Plant chain. Ids are saved: never rename.
///
/// A manual station runs at speed 0.6, an automated one at 1.3
/// ([MachineMode]). The three KITTING stations, the only ones that take a
/// colony good, run flat out at exactly the spec's input rates: they are
/// the plant's pace (see the library doc). Every station after them has a
/// quarter's slack, so it never backs up into them.
class MissileRecipes {
  MissileRecipes._();

  static const cutTubes = FactoryRecipe(
    id: 'missilefactory:cutTubes',
    label: 'Cut Tubes',
    station: StationKind.press,
    // Two tubes cut, rolled and seamed into three shell segments; four
    // segments make an airframe, so one takes 8/3 tubes: the spec's
    // 0.4 : 0.15.
    inputs: [ItemQty('tubes', 2)],
    outputs: [ItemQty('missilefactory:segment', 3)],
    // 6 s: a manual saw (10 s a cut) takes exactly 0.2 tubes/s; the two
    // take the spec's 0.4. A PACER: no slack on purpose. Two tubes a cut
    // gives the walkers two cuts (20 s) to bring each pair, and a lump of
    // two is still under 2% of a 300 s measurement.
    seconds: 6,
    // A band saw and a ring roller.
    powerKw: 30,
  );

  static const weld = FactoryRecipe(
    id: 'missilefactory:weld',
    label: 'Weld Airframe',
    station: StationKind.press,
    inputs: [ItemQty('missilefactory:segment', 4)],
    outputs: [ItemQty('missilefactory:airframe', 1)],
    // 3.2 s: the one manual welder (5.33 s) makes 0.1875 sections/s
    // against the plant's 0.15, a quarter's slack. One welder fed by both
    // saws, not one per saw: two welders each paced by its own saw weld in
    // a 40 s rhythm, and their sections reach integration in clumps (see
    // the library doc's "Lumps"). Short, too: it is on the first pass's
    // critical path.
    seconds: 3.2,
    // Orbital welders and a stress-relief oven: the hall's biggest crewed
    // draw.
    powerKw: 150,
  );

  static const kitElectronics = FactoryRecipe(
    id: 'missilefactory:kitElectronics',
    label: 'Kit Electronics',
    station: StationKind.assembler,
    // A unit of electronics is three boards; four boards make a guidance
    // section: the spec's 0.2 : 0.15.
    inputs: [ItemQty('electronics', 1)],
    outputs: [ItemQty('missilefactory:board', 3)],
    // 6 s: a manual ESD bench (10 s) takes exactly 0.1 units/s; the two
    // take the spec's 0.2. A PACER. Static-safe unpacking and goods-in
    // test of every board.
    seconds: 6,
    // ESD bench, ionisers and a flying-probe tester.
    powerKw: 5,
  );

  static const guidance = FactoryRecipe(
    id: 'missilefactory:guidance',
    label: 'Build Guidance',
    station: StationKind.assembler,
    inputs: [ItemQty('missilefactory:board', 4)],
    outputs: [ItemQty('missilefactory:guidance', 1)],
    // 3 s: the manual bench (5 s) makes 0.2 sections/s against 0.15. One
    // bench, fed by one belt that both kitting benches' boards join, and
    // handing on by belt, keeps the guidance path off the walkers.
    seconds: 3,
    // Soldering, harness testers and clean-bench air.
    powerKw: 20,
  );

  static const kitMotor = FactoryRecipe(
    id: 'missilefactory:kitMotor',
    label: 'Kit Motor Parts',
    station: StationKind.assembler,
    // A unit of rocket parts kits three quarter-motors; four kits make a
    // motor: the spec's 0.2 : 0.15.
    inputs: [ItemQty('rocketParts', 1)],
    outputs: [ItemQty('missilefactory:motorKit', 3)],
    // 3 s: the manual station (5 s) takes exactly 0.2 units/s, the spec's
    // rate. A PACER. Unpacking, and an X-ray of every case and igniter.
    // One unit a cycle is fine here: the crane's hook hangs over both the
    // staging tile and the hand port, so it lifts each in two seconds.
    seconds: 3,
    // Inspection X-ray and a hoist.
    powerKw: 20,
  );

  static const castMotor = FactoryRecipe(
    id: 'missilefactory:castMotor',
    label: 'Cast Motor',
    station: StationKind.chem,
    inputs: [ItemQty('missilefactory:motorKit', 4)],
    outputs: [ItemQty('missilefactory:motor', 1)],
    // 6.5 s: the lights-out cell (5 s at speed 1.3) casts 0.2 motors/s
    // against 0.15.
    seconds: 6.5,
    // Propellant mixers, a curing oven and remote handling.
    powerKw: 200,
  );

  static const integrate = FactoryRecipe(
    id: 'missilefactory:integrate',
    label: 'Integrate Missile',
    station: StationKind.assembler,
    // Slot order is PORT order (`station_ports.dart`): the airframe's
    // input 1 (west face) stays empty, it comes by forklift to the hand
    // port; the motor rides a belt into input 2 (top), guidance one into
    // input 3 (bottom middle). The order is also the product tree's walk
    // order (`product_tree_test.dart`: the tube branch must be met before
    // the electronics branch, whose pig iron it credits), so it is kept.
    inputs: [
      ItemQty('missilefactory:airframe', 1),
      ItemQty('missilefactory:motor', 1),
      ItemQty('missilefactory:guidance', 1),
    ],
    outputs: [ItemQty('missilefactory:round', 1)],
    // 3 s: the manual fixture (5 s) mates 0.2 missiles/s against 0.15:
    // enough slack that a section arriving late never holds the line.
    seconds: 3,
    // Mating fixture hoists and torque tools.
    powerKw: 60,
  );

  static const checkout = FactoryRecipe(
    id: 'missilefactory:checkout',
    label: 'Test & Certify',
    station: StationKind.assembler,
    inputs: [ItemQty('missilefactory:round', 1)],
    outputs: [ItemQty('missiles', 1)],
    // 3 s: the manual test cell (5 s) certifies 0.2 missiles/s against
    // 0.15. One cell, not two slower ones: the first would take every
    // round until its queue backed up, so a fresh floor would ship at the
    // one cell's rate for its first minutes.
    seconds: 3,
    // Telemetry rack, X-ray of the motor grain, environmental soak.
    powerKw: 40,
  );

  static const all = [
    cutTubes, weld, kitElectronics, guidance, kitMotor, castMotor, integrate,
    checkout,
  ];
}

bool _registered = false;

/// Registers the Missile Plant intermediates and recipes. Idempotent: the
/// registries accept the identical const object twice, and the flag skips
/// the work. `ensureFactoryCatalog` calls it, so a missile floor loaded
/// from a save, or measured on a worker isolate, finds its recipes.
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

/// Missile Plant hall: 26 × 80 tiles = 52 × 160 m. The line takes the
/// south 54 m; the north is open floor, the propellant line's blast
/// separation and what brings the template to the spec's 40 ore (hall area
/// is build cost). The east wall stands three tiles past the test cell, so
/// the missile belt is short (see the library doc's first-pass rule).
const HallSize kMissileHall = HallSize(26, 80);

/// Workers on foot: the tube crews feeding the two saws from the staging
/// they idle on. Four would do; 38 fill the spec's jobs: the template's
/// labour slack (see the library doc).
const int kMissileWalkers = 38;

/// Forklifts lifting airframe sections from the welder to integration:
/// 0.15 lifts/s with no travel is light work for one; the second covers
/// its charging.
const int kMissileForklifts = 2;

/// One crane over the rocket-parts staging and the motor-kitting station.
const int kMissileCranes = 1;

/// A fresh Missile Plant template (each call a new blueprint the caller
/// may edit).
FloorBlueprint missilefactoryTemplate() {
  ensureFactoryCatalog();
  registerMissileChain();
  final l = TemplateLayout();
  void belt(int x, int y, Dir4 d) => l.add(EntityKind.belt, x, y, dir: d);

  // ---- Tubes: people at the south door ----
  // The tube staging column comes FIRST: the first staging area is the
  // walkers' muster, so they idle on it. Both saws' hand ports, (11, 2)
  // and (11, 4), open onto it.
  l.add(EntityKind.staging, 11, 2, span: (1, 3));
  l.add(EntityKind.receivingDock, 11, 0, dir: Dir4.north, item: 'tubes');
  // Saw A faces north (hand port on its east face, segments out the top
  // at (9, 4)); saw B faces east (hand port below, segments out at
  // (13, 6)).
  l.machine(8, 1, MissileRecipes.cutTubes, dir: Dir4.north);
  l.machine(10, 5, MissileRecipes.cutTubes);
  // Saw A's segments up column 9 and east along row 8; saw B's east along
  // row 6 and up column 18, where row 8 joins from the side; one belt into
  // the welder.
  l.beltRun(4, 7, 9, Dir4.north);
  l.beltRun(9, 17, 8, Dir4.east);
  l.beltRun(13, 17, 6, Dir4.east);
  l.beltRun(6, 11, 18, Dir4.north);
  belt(18, 12, Dir4.west);
  l.machine(15, 11, MissileRecipes.weld, dir: Dir4.west);
  // The welder faces west: input port fed from (18, 12), hand port opening
  // up onto (16, 14). Its west output port (14, 12) is left bare, so the
  // sections wait at the hand port for a forklift.
  // ---- Forklift pad over the welder's and integration's hand ports ----
  // 2 × 2, so a forklift parked on it covers (16, 14) and (16, 15) at
  // once; the charger beside it is where the forklifts start.
  l.add(EntityKind.aisle, 16, 14, span: (2, 2));
  l.add(EntityKind.chargingBay, 18, 14);
  // ---- Electronics: west door, arms off staging onto port belts ----
  l.add(EntityKind.staging, 2, 20, span: (1, 6));
  l.add(EntityKind.receivingDock, 0, 22, item: 'electronics');
  l.arm(3, 21, Dir4.east);
  belt(4, 21, Dir4.east);
  l.machine(5, 20, MissileRecipes.kitElectronics);
  l.arm(3, 25, Dir4.east);
  belt(4, 25, Dir4.east);
  l.machine(5, 24, MissileRecipes.kitElectronics);
  // Boards: both benches' output ports, (8, 25) and (8, 21), sit on one
  // southbound belt down column 8 that turns into the guidance bench's
  // input port at (9, 15); guidance rides east along row 15 and turns up
  // at (15, 15) into integration's input 3.
  l.beltRun(25, 16, 8, Dir4.south);
  belt(8, 15, Dir4.east);
  l.machine(9, 14, MissileRecipes.guidance);
  l.beltEast(12, 14, 15);
  belt(15, 15, Dir4.north);
  // ---- Motors: east door, staging, crane, kitting, the propellant cell ----
  // The kitting station faces west: its hand port (21, 23) opens onto the
  // staging tile (21, 24) the crane's hook works, its kits leave by
  // (20, 22) straight into the casting cell's input port, and the cell's
  // motors leave by (15, 22) down column 15 into integration's top port.
  l.add(EntityKind.staging, 21, 24, span: (3, 2));
  l.add(EntityKind.receivingDock, 24, 25, dir: Dir4.west, item: 'rocketParts');
  l.add(EntityKind.craneBay, 21, 23, span: (3, 3));
  l.machine(21, 21, MissileRecipes.kitMotor, dir: Dir4.west);
  belt(20, 22, Dir4.west);
  l.machine(16, 20, MissileRecipes.castMotor,
      mode: MachineMode.automated, dir: Dir4.west);
  l.beltRun(22, 19, 15, Dir4.south);
  // ---- Integration and test ----
  // Rounds by one belt tile into the test cell, missiles by three to the
  // east-wall door.
  l.machine(14, 16, MissileRecipes.integrate);
  belt(17, 17, Dir4.east);
  l.machine(18, 16, MissileRecipes.checkout);
  l.beltEast(21, 23, 17);
  l.add(EntityKind.shippingDock, 24, 17, dir: Dir4.west, item: 'missiles');

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
