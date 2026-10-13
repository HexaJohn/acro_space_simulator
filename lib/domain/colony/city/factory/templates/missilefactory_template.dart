// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Missile Plant's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6).
///
/// Like every template it must measure at the spec's flat rate (within
/// 5%), staff the spec's jobs and cost the spec's build ore, so opening the
/// floor changes nothing for a colony; and it must be "fine, not great",
/// so a designer has something to win. It is the plan's first real
/// MULTI-INPUT assembly: three goods arrive by three routes and meet at one
/// fixture.
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
/// ## Measured the way the colony measures
///
/// The colony re-measures a plant with `MeasureSettings.standard` (60 s of
/// warm-up, then at most 300 s, stopping early when a 30 s sub-window
/// agrees with the running mean), from a FRESH floor whenever its editor
/// closes. Two rules follow, and the template is built around them:
///
/// * **Settle inside a minute.** The pace is set at the FRONT: the three
///   kitting stations, the only ones that take a colony good, run flat out
///   at exactly the spec's input rates (two saws at 0.2 tubes/s each, two
///   electronics benches at 0.1 units/s, one motor-kitting station at 0.2).
///   Everything after them has a quarter's slack, so nothing downstream
///   ever fills up: there is no start-up stock to build or drain, and the
///   one transient is the pipeline's first pass. Every move on that
///   critical path is a belt, an arm, a crane hook over both ends or a
///   forklift parked across both, so the first missile ships about a
///   minute in, and the rates are flat from there.
/// * **Lumps small next to 300 s.** Goods come loose, never in packs: a
///   ten-unit crate arriving a moment either side of a window edge is 8%
///   of a 300 s window of tubes and 17% of one of electronics, while the
///   biggest lump here (a saw's two tubes) is under 2%. The kitting
///   stations' cycles (10 s and 5 s) divide 30 s, so every sub-window
///   takes the same inputs; the line ships 3 missiles every 20 s, so
///   sub-windows alternate 4 and 5 and the early stop can never catch a
///   lucky run of equal lumps (it measures the full 300 s, 45 missiles).
///
/// ## Layout (52 × 36 tiles = 104 × 72 m; the working floor, x 0-21)
///
/// Row 23 at the top, x = 0 at the west wall:
///
///     23 RKKK......R.......R...    R receiving doors: rocket parts (west
///     22 RKKK.EEE..R.......R...      wall), electronics, tubes (north)
///     21 _KKK.EEE___.....___...    _ staging at each door; the walkers'
///     20 ..v..EEE___._______...      muster area between the two north
///     19 .MMMM.v.___._______...      doors (x 12-15)
///     18 .MMMMGGG.EEE....SSSSSS    S tube saws (pace)
///     17 .MMMMGGG<EEE....SSSSSS    E electronics kitting (pace)
///     16 .MMMMGGG.EEE....SSSSSS    K motor kitting (pace)
///     15 ....v.v::WWW.....v..v.    G guidance bench   W welders
///     14 ....III::WWW<|=======.    M lights-out motor casting cell
///     13 ....III::WWW.|........    I integration      T test cell
///     12 ....III::WWW.|........    D missile door     c forklift charger
///     11 .....v.::WWW<|........    : forklift aisle   = | belts
///     10 .....|.::WWW..........    < > ^ v arms
///      9 .TTT.|.::.............
///      8 .TTT<|.::.............    Crane runways (not drawn): over the
///      7 .TTT...::.............    rocket-parts door, its staging and K;
///      6 DD.....::.............    and over T and the missile door.
///      2 .......::cc...........
///
/// * **People at the docks.** Tubes and electronics are set down in
///   staging at the north doors, and workers on foot carry them, one at a
///   time, to the saws and kitting benches whose sides the staging touches.
/// * **Cranes over the heavy work.** Rocket parts are lifted off their door
///   into the motor-kitting station, and certified missiles out of the test
///   cell onto the truck; each crane's hook sits over both ends, so a lift
///   is a pick and a set-down. Kits, motors and untested rounds are moved
///   only by arm (live propellant is never carried by hand).
/// * **Belts where flow is steady**: saw segments to the two welders, and
///   rounds from integration to test.
/// * **Forklifts in the core**: welded airframe sections are pallet loads,
///   shuttled across the aisle to integration (and charged at its foot).
/// * **Crewed stations.** Everything is manual (two hands each) but the
///   motor casting cell, the one lights-out station: propellant is cast
///   remotely behind blast walls, a technician's quarter-share.
/// * **The open floor** east and south of the line is the separation the
///   spec's "blast-distance spacing" asks for between the propellant cell
///   and the rest of the hall, and room to grow. Hall area is build cost:
///   a designer can give it back.
///
/// Jobs: 10 manual stations × 2 + the casting cell's ¼ technician + 2
/// crane drivers + 2 forklift drivers + 34 walkers = 58.25, the spec's 60
/// within 3%. Build cost (`capexOf`) ≈ 39.5 ore, the spec's default 40.
///
/// "Fine, not great": the floor is staffed the way a plant that never
/// studied its docks is. Measured: half a dozen walkers keep the kitting
/// stations fed, so releasing most of the 34 holds 0.15 missiles/s on a
/// third fewer jobs; crewing the three kitting stations as assisted
/// (faster) lifts the plant to ~0.2 missiles/s on the same floor before
/// the welders, guidance bench and test cell run out of slack.
///
/// Measured (`InfiniteColonyPort`): with `MeasureSettings.standard` from a
/// fresh floor, tubes 0.400, electronics 0.200, rocket parts 0.200 and
/// missiles 0.147 (−2.2%: the first pass); re-measured from a settled
/// floor, missiles 0.150 at any phase.
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
  /// inspected and kitted. Propellant is only ever moved by hoist, so it is
  /// heavy-class (crane or arm).
  static const motorKit = FactoryItem(
      id: 'missilefactory:motorKit', label: 'Motor Kit',
      loadClass: LoadClass.heavy, kgPerUnit: 33);

  /// A cast solid-rocket motor: crane or arm work, like its kits.
  static const motor = FactoryItem(
      id: 'missilefactory:motor', label: 'Rocket Motor',
      loadClass: LoadClass.heavy, kgPerUnit: 130);

  /// An integrated missile before acceptance test: crane work, as the
  /// certified missile it becomes.
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
    // 6 s: a manual welder (10 s) makes 0.1 sections/s; the two make 0.2
    // against the plant's 0.15. Ten seconds, not more: it is on the
    // first pass's critical path (see the library doc).
    seconds: 6,
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
    // bench, fed by arm from both kitting benches and handing on by arm,
    // keeps the guidance path off the walkers.
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
    // One unit a cycle is fine here: the crane over its door lifts each
    // in two seconds.
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

/// Missile Plant hall: 52 × 36 tiles = 104 × 72 m. The line itself takes
/// the west 44 m; the rest is the propellant cell's blast separation and
/// what brings the template to the spec's 40 ore (hall area is build cost).
const HallSize kMissileHall = HallSize(52, 36);

/// Workers on foot: the dock crews carrying tubes and electronics to the
/// kitting stations. Measured: six keep the stations fed, four fall ~45%
/// short. 34 fill the spec's jobs: the template's labour slack (see the
/// library doc).
const int kMissileWalkers = 34;

/// Forklifts shuttling airframe sections across the aisle: 0.15 lifts/s
/// with no travel is light work for one; the second covers its charging.
const int kMissileForklifts = 2;

/// One crane over the motor kitting bay, one over the test cells.
const int kMissileCranes = 2;

/// A fresh Missile Plant template (each call a new blueprint the caller
/// may edit).
FloorBlueprint missilefactoryTemplate() {
  ensureFactoryCatalog();
  registerMissileChain();
  final l = TemplateLayout();
  // ---- Receiving, north wall: people at the docks ----
  // The walkers' muster area first: the first staging area is where idle
  // walkers wait (`FactoryFloor`), so it sits between the two hand-fed
  // doors. Each door's staging is small on purpose: it fills in under
  // half a minute, so a fresh floor is not still stocking it when the
  // colony starts measuring.
  l.add(EntityKind.staging, 12, 19, span: (4, 2));
  // Tubes: door, staging touching both saws' tops.
  l.add(EntityKind.staging, 16, 19, span: (3, 3));
  l.add(EntityKind.receivingDock, 18, 22, dir: Dir4.south, item: 'tubes');
  l.machine(16, 16, MissileRecipes.cutTubes);
  l.machine(19, 16, MissileRecipes.cutTubes);
  // Segments by belt to the welders: an arm pulls for the first until it
  // is full, the rest run on to the second.
  l.arm(17, 15, Dir4.south);
  l.arm(20, 15, Dir4.south);
  l.beltRun(20, 14, 14, Dir4.west);
  l.beltRun(14, 11, 13, Dir4.south);
  l.arm(12, 14, Dir4.west);
  l.arm(12, 11, Dir4.west);
  // Electronics: door, staging touching both kitting benches.
  l.add(EntityKind.staging, 8, 19, span: (3, 3));
  l.add(EntityKind.receivingDock, 10, 22,
      dir: Dir4.south, item: 'electronics');
  l.machine(9, 16, MissileRecipes.kitElectronics);
  l.machine(5, 20, MissileRecipes.kitElectronics);
  // ---- Guidance: both kitting benches hand boards over by arm ----
  l.arm(8, 17, Dir4.west);
  l.arm(6, 19, Dir4.south);
  l.machine(5, 16, MissileRecipes.guidance);
  l.arm(6, 15, Dir4.south);
  // ---- Weld bay: sections leave by forklift ----
  l.machine(9, 13, MissileRecipes.weld);
  l.machine(9, 10, MissileRecipes.weld);
  // Forklift aisle between the welders and integration, charger at its
  // foot.
  l.add(EntityKind.aisle, 7, 1, span: (2, 15));
  l.add(EntityKind.chargingBay, 9, 1);
  // ---- Heavy column, west wall ----
  // Integration takes motors and guidance by arm from above, sections by
  // forklift from the aisle, and puts rounds on a short belt to test.
  l.machine(4, 12, MissileRecipes.integrate);
  l.arm(5, 11, Dir4.south);
  l.beltRun(10, 8, 5, Dir4.south);
  l.arm(4, 8, Dir4.west);
  // The test cell's crane hook sits over the cell and the missile door.
  l.machine(1, 7, MissileRecipes.checkout);
  l.add(EntityKind.shippingDock, 0, 6, item: 'missiles');
  l.add(EntityKind.craneBay, 0, 6, span: (4, 4));
  // Motors: the lights-out cell, fed by arm from the kitting station, whose
  // crane lifts rocket parts straight off their door's staging tile.
  l.machine(1, 16, MissileRecipes.castMotor, mode: MachineMode.automated);
  l.arm(4, 15, Dir4.south);
  l.machine(1, 21, MissileRecipes.kitMotor);
  l.arm(2, 20, Dir4.south);
  l.add(EntityKind.staging, 0, 21, span: (1, 1));
  l.add(EntityKind.receivingDock, 0, 22,
      dir: Dir4.south, item: 'rocketParts');
  l.add(EntityKind.craneBay, 0, 21, span: (4, 3));

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
