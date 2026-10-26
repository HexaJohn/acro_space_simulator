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
/// the colony gets or pays. "Measured" means what the game really runs:
/// `FloorMeasureRunner` re-measures a floor with `MeasureSettings.standard`
/// (60 s warm-up, at most 300 s measured), and an untouched template must
/// read the spec there, not only over a long test window. And it is
/// deliberately "fine, not great": a designer can beat it.
///
/// ## Mass balance (spec: 0.5 tubes + 0.3 electronics → 0.4 rocket parts /s)
///
/// Per second, at the spec rate, in colony units:
///
///     0.5 tubes ─────── 6 welding cells, 5 → 2 ──► 0.2 frames ──────┐
///                                                                   ├─ 6 bays ─► 0.4 rocket parts
///     0.3 electronics ─ 6 wiring benches, 3 → 2 ─► 0.2 harnesses ───┘
///
/// (assemble: 1 frame + 1 harness → 2 rocket parts.)
///
/// The floor is six identical MODULES, each one cell, one bench and one
/// bay in exact balance: per minute a manual cell turns 5 tubes into 2
/// frames, a manual bench 3 boards into 2 harnesses, and the bay those 2 + 2
/// into 4 rocket parts. Six modules make the spec's 24 parts a minute.
///
/// Tubes and electronics arrive loose, one unit per item, and rocket parts
/// leave loose, one heavy section at a time, so the docks book exactly the
/// spec's commodities, and a 300 s window counts them to within one unit
/// (under 1%). (Crates would book ten units at a time: one crate either
/// side of a 300 s window is ±7% on tubes and ±11% on electronics.) The
/// two intermediates, a welded frame and an avionics harness, never leave.
/// The plant ships rocket parts and nothing else, and takes tubes and
/// electronics and nothing else.
///
/// ## Explicit ports (§10 item 19, `station_ports.dart`)
///
/// Every station here is an assembler (3 × 3): input ports on its back and
/// both sides, the product port on its front, and ONE hand port on its
/// right-front corner. Belts feed only an input port, with that slot's item;
/// products leave only by the product port; handlers work a station only at
/// its hand port; no arm touches a machine (the template has no arms). So:
///
/// * **Cells and benches face north, into the hall**, so their input port
///   (slot 1) is on the wall side. A bench's electronics door's open end IS
///   that port: the door crew hands boards straight in. A cell's tube door
///   feeds its port through a short roller (the dock conveyor `capexOf`
///   charges for).
/// * **Each bay faces south**: its product port is on the wall side and
///   pushes each section onto a one-tile roller straight through its own
///   shipping door, and its hand port is its low-west corner, opening onto
///   a 2 × 3 aisle pad. Nothing feeds a bay's input ports by belt: frames
///   and harnesses both come by hand, to that pad.
/// * **The cell faces WEST**, not north, so its hand port (top-west corner)
///   opens onto the main forklift aisle; its tube roller climbs its east
///   side into its input port.
///
/// ## Why modules: the pull trap
///
/// A hand-fed input pulls from the nearest source (by centre distance) that
/// has stock, and a bay buffers only two crafts' worth, so at most two
/// frames and two harnesses are ever in flight to it: its rate is capped at
/// 2 ÷ (round-trip time). The first port drafts fed one bay a line from all
/// three cells and benches, and that cap bit: far sources meant long trips
/// (0.26 parts/s, not 0.4), and a bay whose own sources ran dry pulled from
/// the other line's, which starved that line in turn, the same trap the
/// Steel Mill hit with two packers on symmetric lines. A row of modules
/// laid [bench][pad][bay][cell] instead gives every bay its OWN bench (centre
/// 6 tiles away) and cell (3 tiles) as nearest sources, the next module's
/// being 8 and more, so every pull stays in its module and every trip is
/// short: a harness walks two tiles, a frame drives four.
///
/// ## Why the slow stations come first
///
/// What the floor holds in steady state, it must take in before it reads
/// the spec rate: a 300 s window after a 60 s warm-up still counts whatever
/// stock is building up. So the template holds little and fills it fast:
///
/// * **The pace is set at the start of the chain.** The welding cells and
///   wiring benches run at exactly the spec rate (one 60 s cycle each, see
///   [RocketPartsRecipes]), and everything after them is faster. Stock
///   never piles up behind a slow assembly bay; the bays wait for parts.
/// * **Every slow station is fed straight from its own door**, so its
///   buffer is full within seconds and its first cycle ends at about 65 s.
///   No handler stands between a door and a station (an earlier draft that
///   had walkers carry boards from door pads started a minute late and read
///   the re-measure 35% low).
/// * **A 60 s cycle divides the 300 s window exactly**, so a window counts
///   five whole cycles of every station, not four or five by luck.
///
/// ## The floor (36 × 18 tiles = 72 × 36 m)
///
/// Two lines of three modules (12 tiles each). Line one, along the long
/// wall at row 0:
///
///          x 0    5    10   15   20   25   30
///     row 7  ...===============================..   main forklift aisle
///     row 6  ...===============================..   (x 3..33)
///     row 5  ...aaYYYCCC....aaYYYCCC....aaYYYCCC.
///     row 4  BBBaaYYYCCC<BBBaaYYYCCC<BBBaaYYYCCC<     B bench, a bay pad,
///     row 3  BBBaaYYYCCC^BBBaaYYYCCC^BBBaaYYYCCC^     Y bay, C cell,
///     row 2  BBB...s....^BBB...s....^BBB...s....^     s parts roller,
///     row 1  .E....S....T.E....S....T.E....S....T     ^ < tube roller;
///     row 0  .E....S....T.E....S....T.E....S....T     E T S the doors
///
/// Line two is line one turned half a turn about the hall's centre, along
/// the opposite wall. A half TURN, not a mirror: ports have a handedness,
/// and only a rotation keeps each one where the layout expects it. The
/// 2-row middle floor holds the walkers' muster pad, a link aisle between
/// the lines' main aisles and the forklifts' charging bay. This is the
/// realistic mix the user asked for (§3 "Template plants"): rollers where
/// the flow is steady, people for the hand loads, forklifts for the pallet
/// loads.
///
/// * **Frames are pallet loads, so forklifts carry them**, from each cell's
///   hand port on the main aisle round to its bay's pad. Measured: two
///   forklifts fall about 20% short, three about 1% once their batteries
///   cycle, and four hold the rate. The template keeps a fifth as a spare:
///   slack, and a lever.
/// * **Harnesses are hand work.** A walker carries each from the bench's
///   hand port (on the pad) two tiles to the bay's. Measured: four walkers
///   hold the rate even through a re-measure's start-up. The template
///   staffs nine, so the crew is slack too (another lever).
/// * **Rocket parts are heavy**, and no handler on this floor can lift one,
///   so a roller under each bay's product port carries every section
///   straight onto its shipping door. No crane is needed, and none is
///   bought.
///
/// Every station is crewed and manual (two people, speed 0.6): none is
/// lights-out. Jobs: 18 stations × 2 = 36, + 9 walkers + 5 forklift drivers
/// = 50, the spec's count. Capex: about 42 ore (18 stations 18, 18 doors
/// and 6 dock conveyors 11.4, the 2592 m² shed 6.5, five forklifts and their
/// charger 4.4, aisles, rollers and the muster pad 1.8), within 10% of the
/// spec's 40.
///
/// ## Where it leaves room (the Reward levers, §3)
///
/// The bays run about 13% busy and the cells and benches are fully manual.
/// A designer who gives every station one operator and its controls
/// (assisted) gets the same parts for 18 fewer jobs, or more parts from the
/// same doors. Trimming the walkers to four and the forklifts to four costs
/// nothing either.
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
  /// big to carry by hand, so forklift work.
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

  static const weldFrame = FactoryRecipe(
    id: 'rocketfactory:weldFrame',
    label: 'Weld Frame',
    station: StationKind.assembler,
    inputs: [ItemQty('tubes', 5)],
    outputs: [ItemQty('rocketfactory:frame', 2)],
    // 36 s: a manual cell (60 s) uses 5 tubes a minute. Six cells use 0.5
    // tubes/s, exactly the spec, so the cells set the plant's pace (see
    // "Why the slow stations come first"). A 60 s cycle also divides the
    // re-measure's 300 s window exactly.
    seconds: 36,
    // Two arc-welding sets and fume extraction.
    powerKw: 60,
  );

  static const wireAvionics = FactoryRecipe(
    id: 'rocketfactory:wireAvionics',
    label: 'Wire Avionics',
    station: StationKind.assembler,
    inputs: [ItemQty('electronics', 3)],
    outputs: [ItemQty('rocketfactory:avionics', 2)],
    // 36 s: as the welders, a manual bench (60 s) uses 3 boards a minute,
    // and six use the spec's 0.3/s. It also makes harnesses as fast as the
    // cells make frames, so neither intermediate piles up.
    seconds: 36,
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
    // 2.4 s: bolting a finished frame and harness together is a quick
    // fit-up next to welding and wiring. A manual bay (4 s) can make 0.5
    // parts/s, and the template's six make 3.0 against the spec's 0.4. The
    // bays must never set the pace: each module's frames and harnesses land
    // two at a time each minute, and a fast bay clears that lump in seconds.
    seconds: 2.4,
    // Torque tools, a fit-up hoist and a leak-test cart.
    powerKw: 40,
  );

  static const all = [weldFrame, wireAvionics, assemble];
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

/// Hall: 36 × 18 tiles = 72 × 36 m. Each line is 8 rows (doors, rollers,
/// stations, the main aisle), with a 2-row middle floor between them for
/// the link aisle, the charging bay and the walkers' muster pad. A compact
/// assembly shop well inside the 700 × 500 m site; `capexOf` comes to about
/// 42 ore against the spec's 40.
const HallSize kRocketPartsHall = HallSize(36, 18);

/// Walkers carrying harnesses two tiles from each bench's hand port to its
/// bay's. Measured: four hold the rate even through the game's short
/// re-measure (the forklifts take a harness when no walker is near), so
/// nine is slack, a lever for a designer.
const int kRocketPartsWalkers = 9;

/// Forklifts running frames from each welding cell's hand port round to its
/// bay's pad. Measured: four hold the long-run rate, three fall about 1%
/// short once the batteries cycle and two about 20%. The fifth is a spare:
/// slack, and a lever.
const int kRocketPartsForklifts = 5;

/// Columns one module takes along the wall (see [_module]).
const int _moduleW = 12;

/// Modules per line.
const int _modules = 3;

/// Draws one line. Line one is drawn in its own frame (the long wall is row
/// 0); with [turned] every placement is turned half a turn about the hall's
/// centre, so line two sits against the opposite wall. A half TURN, not a
/// mirror: ports have a handedness (an assembler's hand port is on its
/// right-front corner), and only a rotation keeps every port where the
/// layout expects it.
void _line(TemplateLayout l, {required bool turned}) {
  final hw = kRocketPartsHall.w, hh = kRocketPartsHall.h;

  /// Adds [kind] whose hall footprint is [w] × [h] at (x, y) in line one's
  /// frame.
  void put(EntityKind kind, int x, int y, int w, int h,
      {Dir4 dir = Dir4.east, String? item, (int, int)? span}) {
    if (!turned) {
      l.add(kind, x, y, dir: dir, item: item, span: span);
    } else {
      l.add(kind, hw - x - w, hh - y - h,
          dir: dir.opposite, item: item, span: span);
    }
  }

  void machine(int x, int y, FactoryRecipe r, Dir4 dir) {
    final (ox, oy) = turned ? (hw - x - 3, hh - y - 3) : (x, y);
    l.machine(ox, oy, r, dir: turned ? dir.opposite : dir);
  }

  for (var m = 0; m < _modules; m++) {
    _module(put, machine, m * _moduleW);
  }
  // The main forklift aisle along the line, from the first bay's pad past
  // every cell's hand port.
  const x0 = 3, x1 = (_modules - 1) * _moduleW + 9;
  put(EntityKind.aisle, x0, 6, x1 - x0 + 1, 2, span: (x1 - x0 + 1, 2));
}

/// One module at x offset [o] (line one's frame): a wiring bench, the
/// assembly bay's pad, the bay and a welding cell, in balance (2 frames + 2
/// harnesses → 4 rocket parts a minute):
///
///     x  o       o+3 o+5     o+8     o+11
///        = = = = = = = = = = = .    rows 6..7  the main forklift aisle
///        . . . a a Y Y Y C C C .    row 5   B bench, a the bay's pad,
///        B B B a a Y Y Y C C C <    row 4   Y bay, C cell, < ^ the tube
///        B B B a a Y Y Y C C C ^    row 3   roller
///        B B B . . . s . . . . ^    row 2   s parts roller
///        . E . . . . S . . . . T    rows 0..1: electronics, shipping
///                                           and tube doors
///
/// Each bay's own cell (centre 3 tiles from the bay's) and bench (6) are
/// its nearest sources of frames and harnesses; the next module's are 8
/// and more away. Pulls go to the nearest source with stock, so every bay
/// is fed by its own module and no handler crosses the hall (the trap the
/// Steel Mill hit with two symmetric packers).
void _module(
    void Function(EntityKind, int, int, int, int,
            {Dir4 dir, String? item, (int, int)? span})
        put,
    void Function(int, int, FactoryRecipe, Dir4) machine,
    int o) {
  // The wiring bench faces north; its electronics door's open end IS its
  // input port (o+1, 2), so the door crew hands boards straight in. Its
  // harnesses wait at its hand port, whose outside (o+3, 4) is on the
  // bay's pad: a walker carries each one two tiles.
  put(EntityKind.receivingDock, o + 1, 0, 1, 2,
      dir: Dir4.north, item: 'electronics');
  machine(o, 2, RocketPartsRecipes.wireAvionics, Dir4.north);
  // The bay's pad: 2 wide, so a forklift's square covers it from the main
  // aisle; the bay's hand port opens onto (o+4, 3).
  put(EntityKind.aisle, o + 3, 3, 2, 3, span: (2, 3));
  // The assembly bay faces SOUTH: hand port at its low-west corner, and its
  // product port (o+6, 3) pushes each finished section onto a one-tile
  // roller straight through the shipping door below it.
  machine(o + 5, 3, RocketPartsRecipes.assemble, Dir4.south);
  put(EntityKind.belt, o + 6, 2, 1, 1, dir: Dir4.south);
  put(EntityKind.shippingDock, o + 6, 0, 1, 2,
      dir: Dir4.north, item: 'rocketParts');
  // The welding cell faces WEST, so its hand port is its top-west corner
  // (o+8, 5), opening north onto the main aisle (o+8, 6): a forklift picks
  // the frames up there and runs them four tiles round to the bay's pad.
  // Its tube door feeds it through a three-tile roller (the dock conveyor)
  // up its east side and into its input port (o+10, 4).
  put(EntityKind.receivingDock, o + 11, 0, 1, 2,
      dir: Dir4.north, item: 'tubes');
  put(EntityKind.belt, o + 11, 2, 1, 1, dir: Dir4.north);
  put(EntityKind.belt, o + 11, 3, 1, 1, dir: Dir4.north);
  put(EntityKind.belt, o + 11, 4, 1, 1, dir: Dir4.west);
  machine(o + 8, 3, RocketPartsRecipes.weldFrame, Dir4.west);
}

// A fresh Rocket Parts Factory template blueprint (each call a new one the
/// caller may edit).
FloorBlueprint rocketfactoryTemplate() {
  ensureFactoryCatalog();
  registerRocketPartsChain();
  final l = TemplateLayout();
  // The walkers' muster pad comes first: idle walkers gather at the first
  // staging area. It sits mid-floor, between the two lines' middle
  // modules.
  l.add(EntityKind.staging, 15, 8, span: (2, 2));
  _line(l, turned: false);
  _line(l, turned: true);
  // A link aisle joins line one's main aisle (rows 6..7) to line two's
  // (rows 10..11), so every forklift reaches both lines and the one
  // charging bay beside it.
  l.add(EntityKind.aisle, 17, 8, span: (2, 2));
  l.add(EntityKind.chargingBay, 19, 8);
  return FloorBlueprint(
    name: 'Rocket Parts Factory',
    plantType: kRocketPartsType,
    hall: kRocketPartsHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kRocketPartsWalkers,
      HandlerKind.forklift: kRocketPartsForklifts,
    },
  );
}
