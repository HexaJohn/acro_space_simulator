// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Rocket Parts Factory's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6).
///
/// Like every template it is a built-in [FloorBlueprint] whose MEASURED
/// steady state is the plant's flat `CityBuildingSpec` rate within 5%, whose
/// jobs are the spec's within 10%, and whose build cost (`capexOf`) is the
/// spec's `buildCost` within 10%, so opening the floor never changes what
/// the colony gets or pays. And it is deliberately "fine, not great": a
/// designer can beat it.
///
/// ## Mass balance (spec: 0.5 tubes + 0.3 electronics → 0.4 rocket parts /s)
///
/// Per second, at the spec rate, in colony units:
///
///     0.05 tube crates ──de-crate──► 0.5 tubes ──────weld 5→2──► 0.2 frames ──────┐
///                                                                                 ├─assemble─► 0.4 rocket parts
///     0.03 board crates ──unpack──► 0.3 electronics ──wire 3→2──► 0.2 harnesses ──┘
///
/// (assemble: 1 frame + 1 harness → 2 rocket parts.)
///
/// Tubes and electronics arrive as the colony's own crates (ten units each,
/// `FactoryItems.crateTubes` / `crateElectronics`) and rocket parts leave
/// loose, one heavy section at a time (`FactoryItems.rocketParts`), so the
/// docks book exactly the spec's commodities. The two intermediates — a
/// welded frame and an avionics harness — never leave: the plant ships
/// rocket parts and nothing else, and takes tubes and electronics and
/// nothing else.
///
/// ## The floor (46 × 23 tiles = 92 × 46 m)
///
/// Two identical lines, the second mirrored so both lines' benches face a
/// central muster corridor where the walkers wait. Truck doors on the west
/// wall, shipping doors on the east. The realistic mix the user asked for
/// (§3 "Template plants"): conveyors where flow is steady, people and
/// forklifts at the docks, people for the hand loads, and a crane over the
/// heavy work.
///
/// * **Tube crates come in on a dock conveyor.** A roller run carries them
///   across the forklift aisle (on crossings) to a de-crating station with
///   one operator; loose tubes ride a conveyor the length of the hall and up
///   a column past two welding cells, whose arms pick them off. Tubes are
///   the steadiest flow in the plant, so this is where the belt pays.
///   (`capexOf` charges the dock conveyor as the automated upgrade it is.)
/// * **Board crates are a forklift job.** They are set down on a staging
///   pad by the door; a forklift runs each one down the line's aisle to the
///   unpacking bench. Two forklifts share the plant and charge at bays
///   beside the aisle.
/// * **Electronics and harnesses are hand work.** Walkers carry boards from
///   the unpacking bench to two wiring benches, and harnesses from the
///   benches to the final-assembly bays — the near bay by its open side, the
///   far one across a walkway crossing on the tube column. Those walks are
///   the plant's real limit: sixteen walkers hold the spec rate, fifteen
///   fall ~5% short, so the template staffs seventeen.
/// * **Frames go by transfer arm.** Each welding cell stands beside its own
///   assembly bay, and a jib arm swings each frame straight in.
/// * **Rocket parts are heavy, so a crane ships them.** Each line's two
///   assembly bays and its shipping door sit under one crane bay; the hook
///   stands where the door meets both bays, so it lifts every finished
///   section from bay to door without travelling.
///
/// Every station is crewed: the de-craters are assisted (one operator
/// minding the roller table); unpacking, welding, wiring and assembly are
/// manual. Jobs: 2 × 1 + 14 × 2 = 30 at stations, + 17 walkers + 2
/// forklift drivers + 2 crane drivers = 51, against the spec's 50.
///
/// ## Where it leaves room (the Reward levers, §3)
///
/// The assembly bays could make ~4% more than the spec if the walkers kept
/// up; they don't quite, which is what sets the rate. A designer who moves
/// the wiring benches beside the bays, belts the harnesses, or re-crews the
/// manual stations with an operator each gets the same parts for far fewer
/// jobs, or more parts if the bays are sped up too.
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
const String kRocketPartsType = 'rocketfactory';

/// The chain's own intermediates. Saved in floors: never rename an id.
class RocketPartsItems {
  RocketPartsItems._();

  /// A welded tube frame for one pair of stage sections: a pallet load, too
  /// big to carry by hand but light work for a jack or a jib arm.
  static const frame = FactoryItem(
      id: 'rocketfactory:frame', label: 'Welded Frame',
      loadClass: LoadClass.pallet, kgPerUnit: 200);

  /// A boxed avionics harness: boards, looms and connectors, hand-carried.
  static const avionics = FactoryItem(
      id: 'rocketfactory:avionics', label: 'Avionics Harness',
      loadClass: LoadClass.hand, kgPerUnit: 15);

  static const all = [frame, avionics];
}

/// Recipe ids of the rocket parts chain. Saved on machines: never rename.
///
/// Times are at speed 1; a manual station runs at 0.6, an assisted one at 1
/// (`MachineMode`). Power figures are an industrial order of magnitude, like
/// the Steel Mill's; integration calibrates them against the spec.
class RocketPartsRecipes {
  RocketPartsRecipes._();

  static const unpackTubes = FactoryRecipe(
    id: 'rocketfactory:unpackTubes',
    label: 'De-crate Tubes',
    station: StationKind.unpacker,
    inputs: [ItemQty('crate:tubes', 1)],
    outputs: [ItemQty('tubes', 10)],
    // 6 s: an assisted de-crater empties a crate in 6 s, 1.7 tubes/s against
    // a line's 0.25. It idles most of the time, but a fast one fills the
    // long tube conveyor inside the first few minutes, so the plant reaches
    // its steady state quickly.
    seconds: 6,
    // A band cutter and a powered roller table.
    powerKw: 5,
  );

  static const unpackElectronics = FactoryRecipe(
    id: 'rocketfactory:unpackElectronics',
    label: 'Unpack Boards',
    station: StationKind.unpacker,
    inputs: [ItemQty('crate:electronics', 1)],
    outputs: [ItemQty('electronics', 10)],
    // 6 s: a manual bench (10 s) unpacks 1 board/s against a line's 0.15 —
    // never the limit; the walkers fetching from it are.
    seconds: 6,
    // Lighting and an ESD-safe bench.
    powerKw: 5,
  );

  static const weldFrame = FactoryRecipe(
    id: 'rocketfactory:weldFrame',
    label: 'Weld Frame',
    station: StationKind.assembler,
    inputs: [ItemQty('tubes', 5)],
    outputs: [ItemQty('rocketfactory:frame', 2)],
    // 18 s: a manual cell (30 s) makes 0.067 frames/s, so a line's two make
    // 0.13 against the 0.1 its bays use — 75% busy, the Steel Mill's slack.
    seconds: 18,
    // Two arc-welding sets and fume extraction.
    powerKw: 60,
  );

  static const wireAvionics = FactoryRecipe(
    id: 'rocketfactory:wireAvionics',
    label: 'Wire Avionics',
    station: StationKind.assembler,
    inputs: [ItemQty('electronics', 3)],
    outputs: [ItemQty('rocketfactory:avionics', 2)],
    // 18 s: as the welders, two manual benches a line run 75% busy.
    seconds: 18,
    // Soldering stations and a harness test rig.
    powerKw: 10,
  );

  static const assemble = FactoryRecipe(
    id: 'rocketfactory:assemble',
    label: 'Assemble Rocket Parts',
    station: StationKind.assembler,
    inputs: [
      ItemQty('rocketfactory:frame', 1),
      ItemQty('rocketfactory:avionics', 1),
    ],
    outputs: [ItemQty('rocketParts', 2)],
    // 11.5 s: four manual bays (19.2 s each) can make 0.417 parts/s, 4%
    // over the spec — so the bays never cap the plant below its rate, and
    // the harness walkers, not the bays, decide it.
    seconds: 11.5,
    // Torque tools, a fit-up hoist and a leak-test cart.
    powerKw: 40,
  );

  static const all = [
    unpackTubes, unpackElectronics, weldFrame, wireAvionics, assemble,
  ];
}

/// Registers the chain's items and recipes. Idempotent: the registries take
/// the identical const object twice.
void registerRocketPartsChain() {
  for (final i in RocketPartsItems.all) {
    FactoryItems.register(i);
  }
  for (final r in RocketPartsRecipes.all) {
    FactoryRecipes.register(r);
  }
}

/// x of each line's tube column (the belt turning up past the welders):
/// 34 tiles of conveyor from the west docks, with the unpacking and wiring
/// benches in the stretch before it.
const int _colX = 34;

/// Hall: 46 × 23 tiles = 92 × 46 m. Each line is 9 rows; a row of floor
/// along each outer wall and a 3-row muster corridor between them. A long
/// shed, as stage-sized parts want, and well inside the 700 × 500 m site.
const HallSize kRocketPartsHall = HallSize(_colX + 12, 2 * (1 + 9) + 3);

/// Walkers carrying boards and harnesses. Measured: sixteen hold the spec
/// rate, fifteen fall ~5% short; seventeen keeps one spare.
const int kRocketPartsWalkers = 17;

/// Forklifts running board crates from the doors: light work for one, but
/// one is often away charging, so the template keeps two.
const int kRocketPartsForklifts = 2;

/// One crane per line's assembly bay.
const int kRocketPartsCranes = 2;

/// One line. [y0] is its row along the outer wall; [flip] mirrors it about
/// the hall's middle so the second line's benches face the first's across
/// the muster corridor.
void _line(TemplateLayout l, int y0, {required bool flip}) {
  // The row of a thing [h] tiles tall whose near edge is [dy] rows in.
  int y(int dy, [int h = 1]) => flip ? y0 - dy - (h - 1) : y0 + dy;
  final inward = flip ? Dir4.south : Dir4.north;
  const weldX = _colX + 2, asmX = _colX + 6;
  // Tube crates in on a dock conveyor across the forklift aisle, de-crated
  // and sent down the hall on the tube conveyor.
  l.add(EntityKind.receivingDock, 0, y(0), item: 'crate:tubes');
  l.beltEast(2, 6, y(0), crossings: {4, 5});
  l.arm(7, y(0), Dir4.east);
  l.machine(8, y(0, 2), RocketPartsRecipes.unpackTubes,
      mode: MachineMode.assisted);
  l.arm(11, y(0), Dir4.east);
  l.beltEast(12, _colX - 1, y(0));
  // The column past both welding cells; its crossing is the walkers' way
  // to the far assembly bay.
  l.beltRun(y(0), y(6), _colX, inward, crossings: {y(1)});
  l.arm(_colX + 1, y(3), Dir4.east);
  l.machine(weldX, y(2, 3), RocketPartsRecipes.weldFrame);
  l.arm(_colX + 1, y(6), Dir4.east);
  l.machine(weldX, y(5, 3), RocketPartsRecipes.weldFrame);
  // Frames by jib arm straight into the assembly bays.
  l.arm(weldX + 3, y(3), Dir4.east);
  l.arm(weldX + 3, y(6), Dir4.east);
  l.machine(asmX, y(2, 3), RocketPartsRecipes.assemble);
  l.machine(asmX, y(5, 3), RocketPartsRecipes.assemble);
  // The shipping door between the bays' ends, all under one crane.
  l.add(EntityKind.shippingDock, asmX + 3, y(4), item: 'rocketParts');
  l.add(EntityKind.craneBay, asmX, y(2, 6), span: (5, 6));
  // Board crates: staging by the door, a forklift lane to the unpacking
  // bench, and the wiring benches a short walk on.
  l.add(EntityKind.receivingDock, 0, y(2), item: 'crate:electronics');
  l.add(EntityKind.staging, 2, y(2, 2), span: (2, 2));
  l.add(EntityKind.aisle, 6, y(2, 2), span: (_colX - 14, 2));
  l.machine(_colX - 8, y(2, 2), RocketPartsRecipes.unpackElectronics);
  l.machine(_colX - 7, y(5, 3), RocketPartsRecipes.wireAvionics);
  l.machine(_colX - 4, y(5, 3), RocketPartsRecipes.wireAvionics);
  l.add(EntityKind.chargingBay, 2, y(4, 2));
}

/// A fresh Rocket Parts Factory template blueprint (each call a new one the
/// caller may edit).
FloorBlueprint rocketfactoryTemplate() {
  ensureFactoryCatalog();
  registerRocketPartsChain();
  final l = TemplateLayout();
  // The muster corridor's staging area comes first: idle walkers gather at
  // the first staging area, and here that is the middle of their work.
  l.add(EntityKind.staging, _colX - 1, 10, span: (3, 3));
  _line(l, 1, flip: false);
  _line(l, kRocketPartsHall.h - 2, flip: true);
  // The forklift aisle down the dock wall.
  l.add(EntityKind.aisle, 4, 0, span: (2, kRocketPartsHall.h));
  return FloorBlueprint(
    name: 'Rocket Parts Factory',
    plantType: kRocketPartsType,
    hall: kRocketPartsHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kRocketPartsWalkers,
      HandlerKind.forklift: kRocketPartsForklifts,
      HandlerKind.crane: kRocketPartsCranes,
    },
  );
}
