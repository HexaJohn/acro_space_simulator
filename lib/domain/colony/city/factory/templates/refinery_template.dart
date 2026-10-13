// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Refinery's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6).
///
/// Like the Steel Mill's (`factory_templates.dart`), this is a built-in
/// [FloorBlueprint] whose MEASURED rate is the spec's flat rate within 5%,
/// whose job demand is the spec's 30 and whose build cost is the spec's
/// default 40 ore within 10%. So stamping it changes nothing for a colony,
/// and it is "fine, not great": every station is hand-crewed, so a
/// designer who automates beats it on labour.
///
/// ## The chain (spec: 1 ore → 0.4 fuel + 0.3 oxidizer /s, 30 jobs)
///
/// An ISRU propellant plant, the kind a Mars or Moon colony really runs:
/// roast the ore to drive off its ice and carbonates, turn those volatiles
/// into fuel and liquid oxygen, fill totes. Per second at the spec's
/// 1 ore/s:
///
///     1 ore ──roast──► 0.8 volatiles ─────────┐
///             └──────► 0.2 clinker ──pellet──► 0.1 catalyst
///                                             ▼
///          0.8 volatiles + 0.1 catalyst ──synthesis──► 0.1 fuel run
///                                                    + 0.1 LOX run
///          0.1 fuel run ──fill──► 0.4 fuel totes
///          0.1 LOX run  ──fill──► 0.3 oxidizer totes
///
/// Mass closes where it matters: ten tonnes of ore roast to 7 t of
/// volatiles and 3 t of clinker, and the volatiles leave as 4 t of fuel
/// and 3 t of oxidizer (the spec's 0.7 t/t yield). **Nothing but fuel and
/// oxidizer is shipped.** The clinker, the spent roasted rock, is not
/// waste: its iron oxides are pressed into the iron catalyst the synthesis
/// beds burn through (the Fischer-Tropsch / Sabatier catalysts real ISRU
/// plants use), which is this plant's byproduct loop. The rock left over
/// is backfill on site; the floor tracks freight, not tailings.
///
/// ## The layout (a 96 × 52 m process hall, two mirrored lines)
///
/// West to east: ore door and feed conveyor, hot process, a long pipe run,
/// the tank and filling bay, the shipping aisle and its doors. The plan's
/// realistic mix (§3 "Template plants"), in the user's words "workers used
/// in conjunction with heavy vehicles … or just on their own":
///
/// * **Ore arrives on a DOCK CONVEYOR**, the way bulk ore really does: one
///   door on the west wall tips 1 pallet/s onto a feed loop that passes
///   both kilns' feed arms. The door sets the plant's rate (the kilns have
///   25% to spare), as the Steel Mill's docks set its. Unloading by hand
///   was tried and is worse: pallet jacks walk the whole hall (any walker
///   or jack on the floor answers any pallet request), and a forklift
///   fleet shared between a west pad and the east doors spends its battery
///   driving between them. `capexOf` charges the conveyor as the upgrade.
/// * **Clinker is heavy, so cranes move it.** Each line's crane bay runs
///   from its kiln to the one catalyst press between the lines (the two
///   bays overlap over it); a hook lifts each 1.5 t skip a few metres.
/// * **Catalyst is hand work.** Four workers walk the 25 kg bags from the
///   press to both synthesis reactors, ~10 m each way. One SHARED press is
///   deliberate: with a press per line, each reactor's pull would raid the
///   other line's press whenever its own was empty, and the walkers spent
///   their shift crossing the hall.
/// * **Volatiles go straight in** (a transfer arm from kiln to reactor),
///   and the reactor's two products leave on SEPARATE pipe runs — fuel and
///   oxidizer never share a line — 64 m east to the tank bay, away from
///   the hot kilns. Each run ends in a day tank (a chest) that a filling
///   arm draws from.
/// * **Totes leave by forklift.** Each filler's 1 t totes wait for a
///   forklift that runs them across the shipping aisle to that product's
///   two doors (two, because a filler sets down four totes at once — more
///   than one door's bay holds — and a full bay sends the overflow to the
///   far line's doors). The forklifts charge at a bay midway along the
///   aisle.
///
/// Belts and arms here are pipes and transfer pumps: the floor moves
/// liquids as discrete tank runs, the way it moves everything.
///
/// Jobs: 9 manual stations × 2 + 5 forklift drivers + 2 crane drivers + 4
/// catalyst walkers = 29, the spec's 30 within 10%. Build cost ≈ 41.6 ore
/// against the spec's 40.
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
const String kRefineryType = 'refinery';

/// Refinery hall: 48 × 26 tiles = 96 × 52 m. The length is the pipe run
/// that keeps the fuel tanks 64 m from the kilns (a real plant's hazard
/// separation), and it is also what brings the shed to the spec's build
/// cost. It is under 1% of a 900 × 700 m Refinery site; the rest is yard,
/// tank farm and ore stockpile.
const HallSize kRefineryHall = HallSize(48, 26);

/// Forklifts clearing totes, two per trip: 0.7 totes/s across a 4 m
/// aisle is two forklifts' steady work, but both lines' fillers can set
/// down 14 totes in one moment, and each truck runs flat after 360 s and
/// charges for up to 60 s. Measured: four fall ~15% short of the spec's
/// fuel; five hold it.
const int kRefineryForklifts = 5;

/// One crane per line's kiln-to-press bay.
const int kRefineryCranes = 2;

/// Catalyst walkers: 0.1 bags/s from the one press to two reactors, ~30 s
/// a round trip. Measured: three starve the reactors (~17% short); four
/// hold the rate with a quarter to spare.
const int kRefineryWalkers = 4;

// ---- items ------------------------------------------------------------------

/// The Refinery chain's own intermediates. Fuel and oxidizer themselves are
/// the colony goods in [FactoryItems] (1 t pallet totes).
class RefineryItems {
  RefineryItems._();

  /// Steam and CO₂ driven off the ore, condensed into a pressure tote:
  /// 0.875 t, so eight carry the 7 t of volatiles in ten tonnes of ore.
  static const volatiles = FactoryItem(
      id: 'refinery:volatiles', label: 'Volatiles',
      loadClass: LoadClass.pallet, kgPerUnit: 875);

  /// Spent roasted rock in a 1.5 t skip: crane work.
  static const clinker = FactoryItem(
      id: 'refinery:clinker', label: 'Clinker', loadClass: LoadClass.heavy,
      kgPerUnit: 1500);

  /// A 25 kg bag of iron-oxide catalyst pellets: one person carries it.
  static const catalyst = FactoryItem(
      id: 'refinery:catalyst', label: 'Catalyst', loadClass: LoadClass.hand,
      kgPerUnit: 25);

  /// One reactor run of fuel, 4 t, piped to its day tank; only pipes and
  /// pumps move it, so it is heavy to anything with hands.
  static const fuelRun = FactoryItem(
      id: 'refinery:fuelRun', label: 'Fuel (tank run)',
      loadClass: LoadClass.heavy, kgPerUnit: 4000);

  /// One reactor run of liquid oxygen, 3 t, on its own line.
  static const loxRun = FactoryItem(
      id: 'refinery:loxRun', label: 'LOX (tank run)',
      loadClass: LoadClass.heavy, kgPerUnit: 3000);

  static const all = [volatiles, clinker, catalyst, fuelRun, loxRun];
}

// ---- recipes ----------------------------------------------------------------

/// Recipe ids of the Refinery chain. Saved on machines: never rename.
///
/// Every station in the template is MANUAL (speed 0.6), and each craft
/// time is set so it runs at ~80% of capacity at the spec rate (one of
/// each per line, the press one for both): the receiving door, not a
/// machine, sets the template's rate, and there is room to do better.
class RefineryRecipes {
  RefineryRecipes._();

  static const roast = FactoryRecipe(
    id: 'refinery:roast',
    label: 'Roast Ore',
    station: StationKind.furnace,
    inputs: [ItemQty('ore', 5)],
    outputs: [ItemQty('refinery:volatiles', 4), ItemQty('refinery:clinker', 1)],
    // 4.8 s: a manual kiln (8 s a charge) roasts 0.625 ore/s against the
    // 0.5 its line gets — 80% busy, so the ore door sets the rate.
    seconds: 4.8,
    // A rotary kiln baking half a tonne a second; order of magnitude, like
    // the Steel Mill's furnaces (integration calibrates to powerDraw).
    powerKw: 900,
  );

  static const pelletise = FactoryRecipe(
    id: 'refinery:pelletise',
    label: 'Press Catalyst',
    station: StationKind.press,
    inputs: [ItemQty('refinery:clinker', 2)],
    outputs: [ItemQty('refinery:catalyst', 1)],
    // 4.8 s: the one manual press (8 s a pressing) takes 0.25 clinker/s
    // against both kilns' 0.2.
    seconds: 4.8,
    // A pellet press and its crusher: small beside the kiln.
    powerKw: 120,
  );

  static const synthesise = FactoryRecipe(
    id: 'refinery:synthesise',
    label: 'Synthesise Propellant',
    station: StationKind.chem,
    inputs: [ItemQty('refinery:volatiles', 8), ItemQty('refinery:catalyst', 1)],
    outputs: [ItemQty('refinery:fuelRun', 1), ItemQty('refinery:loxRun', 1)],
    // 9.6 s: a manual reactor (16 s a batch) runs 0.0625 batches/s
    // against its line's 0.05.
    seconds: 9.6,
    // Electrolysis stack, reactor and liquefaction compressors: the plant's
    // biggest draw by far.
    powerKw: 1500,
  );

  static const fillFuel = FactoryRecipe(
    id: 'refinery:fillFuel',
    label: 'Fill Fuel Totes',
    station: StationKind.packer,
    inputs: [ItemQty('refinery:fuelRun', 1)],
    outputs: [ItemQty('fuel', 4)],
    // 9.6 s for four totes: a manual filler (16 s) keeps pace with its
    // reactor at 80%.
    seconds: 9.6,
    // Transfer pump and a chiller on the fill head.
    powerKw: 20,
  );

  static const fillLox = FactoryRecipe(
    id: 'refinery:fillLox',
    label: 'Fill Oxidizer Totes',
    station: StationKind.packer,
    inputs: [ItemQty('refinery:loxRun', 1)],
    outputs: [ItemQty('oxidizer', 3)],
    // 9.6 s for three totes: same pace as the fuel filler.
    seconds: 9.6,
    // A cryogenic fill line loses more to boil-off handling than fuel.
    powerKw: 30,
  );

  static const all = [roast, pelletise, synthesise, fillFuel, fillLox];
}

/// Registers the Refinery's items and recipes. Idempotent: the registries
/// accept the identical const object again.
void registerRefineryChain() {
  for (final i in RefineryItems.all) {
    FactoryItems.register(i);
  }
  for (final r in RefineryRecipes.all) {
    FactoryRecipes.register(r);
  }
}

// ---- layout -----------------------------------------------------------------

/// Line A runs south of the feed conveyor; line B is its mirror image
/// across the hall's middle (y ↔ [_mirrorSum] − y).
const int _mirrorSum = 25;

/// x where the pipe runs end in their day tanks.
const int _tankX = 39;

/// x of the shipping aisle's west lane (two tiles wide), past the fillers.
const int _shipAisleX = _tankX + 5;

/// x of the shipping doors on the east wall, across the aisle.
const int _shipX = _shipAisleX + 2;

/// Draws one line in line-A coordinates, mirrored when [mirror].
class _Line {
  _Line(this.l, {required this.mirror});
  final TemplateLayout l;
  final bool mirror;

  /// The low y of a footprint [h] tall whose line-A low y is [y].
  int y(int y, [int h = 1]) => mirror ? _mirrorSum - (y + h - 1) : y;

  Dir4 d(Dir4 dir) => !mirror || !dir.isVertical ? dir : dir.opposite;

  void machine(int x, int y0, FactoryRecipe r,
          {MachineMode mode = MachineMode.manual}) =>
      l.machine(x, y(y0, r.station.footH), r, mode: mode);

  void arm(int x, int y0, Dir4 dir, {String? only}) =>
      l.arm(x, y(y0), d(dir), only: only);

  void add(EntityKind k, int x, int y0, {(int, int)? span, String? item}) =>
      l.add(k, x, y(y0, span?.$2 ?? 1), span: span, item: item);

  void draw() {
    // Hot end: the kiln beside the feed conveyor, its reactor just
    // outboard of it.
    machine(2, 7, RefineryRecipes.roast);
    // The crane bay runs from the kiln to the shared catalyst press in the
    // middle of the hall (the two lines' bays overlap over the press).
    add(EntityKind.craneBay, 2, 7, span: (7, 7));
    // Volatiles straight from kiln to reactor.
    arm(3, 6, Dir4.south, only: RefineryItems.volatiles.id);
    machine(2, 2, RefineryRecipes.synthesise);
    // Fuel and LOX on separate pipe runs east to their day tanks.
    arm(6, 4, Dir4.east, only: RefineryItems.fuelRun.id);
    arm(6, 3, Dir4.east, only: RefineryItems.loxRun.id);
    l.beltEast(7, _tankX - 1, y(4));
    l.beltEast(7, _tankX - 1, y(3));
    add(EntityKind.chest, _tankX, 4, item: RefineryItems.fuelRun.id);
    add(EntityKind.chest, _tankX, 3, item: RefineryItems.loxRun.id);
    arm(_tankX + 1, 4, Dir4.east);
    arm(_tankX + 1, 3, Dir4.east);
    machine(_tankX + 2, 4, RefineryRecipes.fillFuel);
    machine(_tankX + 2, 2, RefineryRecipes.fillLox);
    // Two doors per product, across the shipping aisle from its filler: a
    // filler sets down four totes at a time, more than one door's bay
    // holds, and a full bay would send the overflow across the hall.
    add(EntityKind.shippingDock, _shipX, 5, item: 'fuel');
    add(EntityKind.shippingDock, _shipX, 4, item: 'fuel');
    add(EntityKind.shippingDock, _shipX, 3, item: 'oxidizer');
    add(EntityKind.shippingDock, _shipX, 2, item: 'oxidizer');
  }
}

/// A fresh Refinery template blueprint (the caller may edit it).
FloorBlueprint refineryTemplate() {
  ensureFactoryCatalog();
  registerRefineryChain();
  final l = TemplateLayout();
  // Receiving: ore tipped at one door onto a feed conveyor that loops
  // past both kilns' feed arms, between the two lines.
  l.add(EntityKind.receivingDock, 0, 12, item: 'ore');
  l.beltRun(12, 12, 2, Dir4.south);
  l.beltRun(2, 4, 11, Dir4.east);
  l.beltRun(11, 13, 5, Dir4.north);
  l.beltRun(3, 5, 14, Dir4.west);
  l.arm(3, 10, Dir4.south); // feed conveyor → kiln A (passing)
  l.arm(3, 15, Dir4.north); // conveyor's end → kiln B
  // One catalyst press between the two kilns, under both crane bays, and
  // the walkers' muster area beside it.
  l.machine(6, 11, RefineryRecipes.pelletise);
  l.add(EntityKind.staging, 9, 11, span: (2, 4));
  _Line(l, mirror: false).draw();
  _Line(l, mirror: true).draw();
  // The shipping aisle along the east wall, and its charging bay midway.
  l.add(EntityKind.aisle, _shipAisleX, 0, span: (2, kRefineryHall.h));
  l.add(EntityKind.chargingBay, _shipAisleX - 2, 12);
  return FloorBlueprint(
    name: 'Refinery',
    plantType: kRefineryType,
    hall: kRefineryHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kRefineryWalkers,
      HandlerKind.forklift: kRefineryForklifts,
      HandlerKind.crane: kRefineryCranes,
    },
  );
}
