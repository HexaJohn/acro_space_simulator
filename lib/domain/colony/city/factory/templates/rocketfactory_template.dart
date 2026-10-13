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
///                                                                   ├─ 4 bays ─► 0.4 rocket parts
///     0.3 electronics ─ 6 wiring benches, 3 → 2 ─► 0.2 harnesses ───┘
///
/// (assemble: 1 frame + 1 harness → 2 rocket parts.)
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
/// ## Why the slow stations come first
///
/// What the floor holds in steady state, it must take in before it reads
/// the spec rate: a 300 s window after a 60 s warm-up still counts whatever
/// stock is building up. So the template is laid out to hold little and to
/// fill it fast:
///
/// * **The pace is set at the start of the chain.** The welding cells and
///   wiring benches run at exactly the spec rate (one 60 s cycle each, see
///   [RocketPartsRecipes]), and everything after them is faster. Stock
///   never piles up behind a slow assembly bay; the bays wait for parts.
/// * **Every slow station is fed straight from its own door**, so its
///   buffer is full within seconds. Each welding cell has a tube door and a
///   one-tile roller run; each wiring bench has an electronics door whose
///   crew hands boxes straight onto the bench. No long belt or staging pad
///   fills up for minutes. Measured, the floor settles at about 120 tubes
///   and 54 electronics, all on the doors' rollers and in the stations'
///   buffers, and holds that from the first minute on.
/// * **A 60 s cycle divides the 300 s window exactly**, so a window counts
///   five whole cycles of every station, not four or five by luck.
///
/// ## The floor (26 × 20 tiles = 52 × 40 m)
///
/// Two identical lines, the second mirrored across a 4-row middle floor.
/// Line one (the long wall is row 0):
///
///          x 0    5    10   15   20   25
///     row 0  ..T..T..T........E..E..E..    T tube door, E electronics door
///     row 1  ..T..T..T........E..E..E..
///     row 2  ..b..b..b...SS..HHHHHHHHH.    b roller run, SS shipping door
///     row 3  .WWWWWWWWWAAAAAAHHHHHHHHH.    W welding cell, A assembly bay,
///     row 4  .WWWWWWWWWAAAAAAHHHHHHHHH.    H wiring bench
///     row 5  .WWWWWWWWWAAAAAA..........
///     row 6  .========================.    forklift aisle
///     row 7  .========================.
///
/// The crane runway covers x 10-15, rows 2-5: both bays and the door. The
/// middle floor holds the walkers' muster pad (by the benches), the
/// forklifts' charging bay and a link aisle between the two lines. This is
/// the realistic mix the user asked for (§3 "Template plants"): roller
/// conveyors where the flow is steady, people and forklifts for the hand
/// and pallet loads, and a crane over the heavy work.
///
/// * **Frames are pallet loads, so forklifts carry them** along the aisle
///   from the cells to the bays. Measured: two forklifts fall about 12%
///   short once their batteries start to cycle, and three hold the rate.
///   The template keeps a fourth as a spare. It is slack, and a lever.
/// * **Harnesses are hand work.** Walkers carry them from the benches to
///   the bays. Measured: six walkers hold the long-run rate, and eight also
///   hold it through the start-up a re-measure sees. The template staffs
///   twelve, so the crew is slack too (another lever).
/// * **Rocket parts are heavy, so a crane ships them.** The shipping door
///   sits where the two bays meet, so the hook lifts every finished section
///   from bay to door without travelling.
///
/// Every station is crewed and manual (two people, speed 0.6): none is
/// lights-out. Jobs: 16 stations × 2 = 32, + 12 walkers + 4 forklift
/// drivers + 2 crane drivers = 50, the spec's count.
///
/// ## Where it leaves room (the Reward levers, §3)
///
/// The bays run about 20% busy and the cells and benches are fully manual.
/// A designer who gives every station one operator and its controls
/// (assisted) gets the same parts for 16 fewer jobs, or more parts from the
/// same doors. Trimming the walkers to eight and the forklifts to three
/// costs nothing either.
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
    // parts/s, and the four make 2.0 against the spec's 0.4. The bays must
    // never set the pace: the cells' frames land six at a time each
    // minute, and fast bays clear that lump in seconds, not minutes.
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

/// Hall: 26 × 20 tiles = 52 × 40 m. Each line is 8 rows (doors, rollers,
/// stations, aisle), with a 4-row middle floor between them. It is a
/// compact assembly shop well inside the 700 × 500 m site, sized so that
/// `capexOf` lands near the spec's 40 ore.
const HallSize kRocketPartsHall = HallSize(26, 20);

/// Walkers carrying harnesses from the benches to the bays. Measured: six
/// hold the long-run rate, and eight also hold it through the first
/// minutes. Twelve is slack, a lever for a designer.
const int kRocketPartsWalkers = 12;

/// Forklifts running frames from the welding cells to the bays. Measured:
/// two fall about 12% short once the batteries cycle, and three hold the
/// rate. The fourth is a spare: slack, and a lever.
const int kRocketPartsForklifts = 4;

/// One crane per line's pair of bays.
const int kRocketPartsCranes = 2;

/// x of a line's first assembly bay and of its first wiring bench.
const int _bayX = 10, _wireX = 16;

/// One line. [y0] is its first row inside the long wall (the doors take
/// that row and the wall row behind it); [flip] mirrors it about the
/// hall's middle, so the second line's doors are on the opposite wall.
void _line(TemplateLayout l, int y0, {required bool flip}) {
  // The row of a thing [h] tiles tall whose near edge is [dy] rows in.
  int y(int dy, [int h = 1]) => flip ? y0 - dy - (h - 1) : y0 + dy;
  final inward = flip ? Dir4.south : Dir4.north;
  // Three welding cells, each fed by its own tube door and roller run.
  for (var i = 0; i < 3; i++) {
    final x = 1 + 3 * i;
    l.add(EntityKind.receivingDock, x + 1, y(-1, 2),
        dir: inward, item: 'tubes');
    l.beltRun(y(1), y(1), x + 1, inward);
    l.machine(x, y(2, 3), RocketPartsRecipes.weldFrame);
  }
  // Two bays side by side, the shipping door over their seam, all under
  // one crane.
  l.machine(_bayX, y(2, 3), RocketPartsRecipes.assemble);
  l.machine(_bayX + 3, y(2, 3), RocketPartsRecipes.assemble);
  l.add(EntityKind.shippingDock, _bayX + 2, y(1), item: 'rocketParts');
  l.add(EntityKind.craneBay, _bayX, y(1, 4), span: (6, 4));
  // Three wiring benches, each loaded straight from its own door.
  for (var i = 0; i < 3; i++) {
    final x = _wireX + 3 * i;
    l.add(EntityKind.receivingDock, x + 1, y(-1, 2),
        dir: inward, item: 'electronics');
    l.machine(x, y(1, 3), RocketPartsRecipes.wireAvionics);
  }
  // The forklift aisle along the line, under the cells and the bays.
  l.add(EntityKind.aisle, 1, y(5, 2), span: (_wireX + 8, 2));
}

/// A fresh Rocket Parts Factory template blueprint (each call a new one the
/// caller may edit).
FloorBlueprint rocketfactoryTemplate() {
  ensureFactoryCatalog();
  registerRocketPartsChain();
  final l = TemplateLayout();
  final h = kRocketPartsHall.h;
  // The walkers' muster pad comes first: idle walkers gather at the first
  // staging area. It sits in the middle floor below the benches, where
  // their work starts.
  l.add(EntityKind.staging, 20, h ~/ 2 - 1, span: (3, 2));
  _line(l, 1, flip: false);
  _line(l, h - 2, flip: true);
  // A link aisle joins the two lines' aisles, so every forklift can reach
  // both lines and the one charging bay beside it.
  l.add(EntityKind.aisle, 3, 6, span: (2, h - 12));
  l.add(EntityKind.chargingBay, 1, h ~/ 2 - 1);
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
