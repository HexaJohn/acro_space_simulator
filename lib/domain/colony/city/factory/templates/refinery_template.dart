// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Refinery's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6), redrawn for EXPLICIT MACHINE PORTS (§10 item 19,
/// `station_ports.dart`).
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
/// ## The ports, and what they force
///
/// Belts feed a station only at its input ports and carry its outputs
/// only from its output ports; handlers work it only at its hand port; no
/// arm touches a machine. Two facts about the kiln (a furnace: ore in at
/// the back, volatiles out the front, the hand port under its second
/// tile) shaped this floor:
///
/// * **Both lines must flow the same way.** A kiln's input and output are
///   on opposite faces, and the one ore door must reach both kilns' inputs
///   while both volatiles lines leave for the filling bay. Point the
///   lines opposite ways (or face the kilns at each other across the
///   press) and the ore belt to one kiln would wall a volatiles line in:
///   floors have no belt bridges. So both kilns face east, inputs to the
///   west, where the ore comes from.
/// * **East-facing kilns open their hand ports SOUTH.** Two lines stacked
///   the old way put line A's kiln hand on the wall side, six tiles and
///   more from any press both cranes could share; the first port draw's
///   cranes spent their shift travelling and starved the press. So the two
///   kilns are STAGGERED round the press instead (the hot core below):
///   kiln B sits one row above line A's volatiles belt, its hand port
///   opening onto the tile just above the press's, a one-tile hop.
///
/// ## The hot core (x 0 .. 22, rows m-1 .. m+7, m = [_m]; north up)
///
///     m+7   .............BBBB......
///     m+6   ........KKKK.BBBB>>>>>>   LOX B
///     m+5   ..>>>>>>KKKK>BBBB>>>>>>   fuel B
///     m+4   ..^.....KKKK.BBBBAAAA..
///     m+3   ..r.kkkk.o....o..AAAA>>   LOX A
///     m+2   DD>>kkkk>+++>>>>>AAAA>>   fuel A
///     m+1   ....kkkkPPP......AAAA..
///     m     .....o..PPP.......o....
///     m-1   ........PPP............
///
/// `D` the ore door, `r` the ore arm, `k`/`K` kilns A and B, `P` the
/// press, `A`/`B` the reactors, `+` crossings (walkable belt), `o` the
/// floor tiles the kilns' and reactors' hand ports open onto. The press's
/// hand port (9, m+1) opens onto the crossing (9, m+2).
///
/// * **Ore arrives on a DOCK CONVEYOR**, the way bulk ore really does: one
///   door on the west wall drops 1 pallet/s onto a belt straight into kiln
///   A's input port. An arm on the belt's first tile lifts ore onto a
///   branch that climbs to kiln B's input (arms still work belts, just not
///   machines). The arm takes every pallet its branch has room for, so
///   kiln B runs flat out (a manual kiln roasts 5 ore per 9 s, 0.556/s)
///   and kiln A takes the rest (0.444/s, 80% busy). The door sets the
///   plant's rate, as the Steel Mill's docks set its; `capexOf` charges
///   the conveyor as the upgrade.
/// * **Clinker is heavy, so cranes move it.** Each kiln has no belt at its
///   clinker port, so its clinker waits at its hand port. Kiln B's crane
///   hops one tile, from (9, m+3) to the press's floor tile (9, m+2);
///   kiln A's hook travels four tiles, from over its hand port (5, m+1)
///   to the press's (9, m+1) and back, so its bay has two cranes.
/// * **Catalyst is hand work.** Walkers pick the 25 kg bags at the press's
///   hand port, which opens onto a CROSSING of line A's volatiles belt (a
///   handler can only work a port from a walkable tile), and carry them to
///   the reactors' hand ports: reactor B's is six tiles along the corridor
///   above line A's belt, reactor A's is reached over two more crossings
///   and along row m. One SHARED press is deliberate (the Steel Mill's
///   trap): with a press per line, each reactor's pull would raid the
///   other line's press whenever its own was empty, and the walkers would
///   spend their shift crossing the hall.
/// * **Volatiles go straight in**, kiln output port to reactor input port
///   by belt, and each reactor's two products leave by its two output
///   ports on SEPARATE pipe runs — fuel and oxidizer never share a line —
///   east to the filling bay, away from the hot kilns. Line B's pipes
///   climb two rows at x 30..31 to clear line A's filling bay.
/// * **Totes leave by forklift.** In each filling bay the fuel pipe ends
///   at the fuel filler's input port and the LOX pipe runs over it, then
///   down a tile into the LOX filler's. Each filler's 1 t totes wait at its
///   hand port on a forklift lane that opens onto the shipping aisle and
///   that line's four doors (two per product: a filler sets down four
///   totes at once, more than one door's bay holds; the fuel doors face
///   the lane). The forklifts charge at a bay off the aisle.
///
/// Belts and arms here are pipes and transfer pumps: the floor moves
/// liquids as discrete tank runs, the way it moves everything.
///
/// ## Mass balance through the stations (per second)
///
/// | station        | line B (first)   | line A (rest)    | capacity (manual) |
/// |----------------|------------------|------------------|-------------------|
/// | kiln           | 0.556 ore        | 0.444 ore        | 0.556 ore         |
/// | reactor        | 0.444 volatiles  | 0.356 volatiles  | 0.5 volatiles     |
/// | each filler    | 0.056 runs       | 0.044 runs       | 0.0625 runs       |
///
/// and the one press 0.2 clinker against its 0.25. Out: 0.1 runs of each
/// product, 0.4 fuel and 0.3 oxidizer totes.
///
/// Jobs: 9 manual stations × 2 + 6 forklift drivers + 3 crane drivers + 4
/// catalyst walkers = 31, the spec's 30 within 10%. Build cost ≈ 38.9 ore
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
/// that keeps the filling bays ~40 m from the kilns (a real plant's hazard
/// separation); the open floor north and south of the lines is room for a
/// designer to grow into, and it is also what brings the shed to the
/// spec's build cost. It is under 1% of a 900 × 700 m Refinery site; the
/// rest is yard, tank farm and ore stockpile.
const HallSize kRefineryHall = HallSize(48, 26);

/// Forklifts clearing totes, two per trip: 0.7 totes/s from four fillers
/// to eight doors, and each truck runs flat after 360 s and charges for up
/// to 60 s. Measured: five fall ~7% short of the spec's fuel; six hold it.
const int kRefineryForklifts = 6;

/// Cranes: two in kiln A's bay (a four-tile hop each way to the press, at
/// ~13 s a skip against kiln A's one every ~11 s) and one in kiln B's
/// (a one-tile hop).
const int kRefineryCranes = 3;

/// Catalyst walkers: 0.1 bags/s from the one press to two reactors, a
/// ~20 s round trip to reactor B and ~40 s to reactor A. Measured: three
/// fall ~7% short (and back the ore door up); four hold the rate.
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

  /// One reactor run of fuel, 4 t, piped to its filler; only pipes and
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
/// Every station in the template is MANUAL (speed 0.6). The receiving
/// door, not a machine, sets the template's rate, and the stations behind
/// the kilns have room to spare (see the library doc's table), so there
/// is room to do better.
class RefineryRecipes {
  RefineryRecipes._();

  static const roast = FactoryRecipe(
    id: 'refinery:roast',
    label: 'Roast Ore',
    station: StationKind.furnace,
    inputs: [ItemQty('ore', 5)],
    outputs: [ItemQty('refinery:volatiles', 4), ItemQty('refinery:clinker', 1)],
    // 5.4 s: a manual kiln (9 s a charge) roasts 0.556 ore/s. The ore arm
    // gives kiln B all it can take, so this caps what reaches reactor B at
    // 0.444 volatiles/s, 89% of a manual reactor; kiln A gets the other
    // 0.444 ore/s (80% busy). Faster, and kiln B would feed its reactor
    // exactly to capacity, with no slack.
    seconds: 5.4,
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
    // against line B's 0.056 and line A's 0.044.
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
    // reactor.
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

/// The hot core's reference row: kiln A's hand port opens onto (5, m), its
/// output belt (line A's volatiles) runs along m+2. The core spans rows
/// m-1 .. m+6 and the filling bays m-1 .. m+8, centred in the hall.
const int _m = 10;

/// x of the fuel fillers; the LOX fillers stand five tiles east of them.
const int _fillX = 36;

/// x of the shipping aisle's west lane (two tiles wide), past the fillers.
const int _shipAisleX = _fillX + 8;

/// x of the shipping doors on the east wall, across the aisle.
const int _shipX = _shipAisleX + 2;

/// x where line B's fuel pipe climbs (its LOX pipe climbs one tile west).
const int _climbX = 31;

/// One line's filling bay with its fillers on rows [f] .. f+1 (all
/// east-facing; ports in `station_ports.dart`'s packer layout):
///
///     f+2   LOX > > > > v
///     f+1   fuel > F F F . > L L L
///     f          F h F     L h L
///     f-2..f-1   forklift lane under both hand ports, out to the aisle
///
/// The fuel pipe arrives on row f+1 at x = fx-1, straight into the fuel
/// filler's input port; the LOX pipe on row f+2 runs over the fuel filler
/// and turns down a tile into the LOX filler's input. The fuel filler's
/// output port (fx+2, f+1) has no belt in front of it, so its totes wait
/// at its hand port for the forklifts.
void _fillBay(TemplateLayout l, int f) {
  l.machine(_fillX, f, RefineryRecipes.fillFuel);
  l.add(EntityKind.belt, _fillX + 4, f + 2, dir: Dir4.south);
  l.add(EntityKind.belt, _fillX + 4, f + 1);
  l.machine(_fillX + 5, f, RefineryRecipes.fillLox);
  l.add(EntityKind.aisle, _fillX, f - 2, span: (_shipAisleX - _fillX, 2));
  // The fuel doors face the lane (fuel is the busier product); the
  // oxidizer doors are just north of them.
  l.add(EntityKind.shippingDock, _shipX, f - 2, item: 'fuel');
  l.add(EntityKind.shippingDock, _shipX, f - 1, item: 'fuel');
  l.add(EntityKind.shippingDock, _shipX, f, item: 'oxidizer');
  l.add(EntityKind.shippingDock, _shipX, f + 1, item: 'oxidizer');
}

/// A fresh Refinery template blueprint (the caller may edit it). See the
/// library doc's core diagram for the tiles named here.
FloorBlueprint refineryTemplate() {
  ensureFactoryCatalog();
  registerRefineryChain();
  final l = TemplateLayout();
  const m = _m;

  // Ore: the dock conveyor straight into kiln A's input port (4, m+2);
  // an arm on its first tile lifts ore onto the branch up column 2 and
  // along row m+5 into kiln B's input port (8, m+5).
  l.add(EntityKind.receivingDock, 0, m + 2, item: 'ore');
  l.beltEast(2, 3, m + 2);
  l.arm(2, m + 3, Dir4.north);
  l.add(EntityKind.belt, 2, m + 4, dir: Dir4.north);
  l.beltEast(2, 7, m + 5);

  // The hot core. Kiln A (4, m+1): hand port (5, m+1) onto (5, m). Kiln B
  // (8, m+4): hand port (9, m+4) onto (9, m+3). The press faces WEST so
  // its hand port (9, m+1) opens north onto (9, m+2); its catalyst output
  // port (8, m) and its input port (10, m) have no belt, so clinker comes
  // in and catalyst goes out by hand.
  l.machine(4, m + 1, RefineryRecipes.roast);
  l.machine(8, m + 4, RefineryRecipes.roast);
  l.machine(8, m - 1, RefineryRecipes.pelletise, dir: Dir4.west);
  // Crane bays (crane i rides bay i): two over kiln A's hand port and the
  // press's, one over kiln B's and the press's.
  l.add(EntityKind.craneBay, 5, m, span: (5, 3));
  l.add(EntityKind.craneBay, 5, m, span: (5, 3));
  l.add(EntityKind.craneBay, 9, m + 1, span: (1, 4));

  // Line A's volatiles: kiln A's output port (7, m+2) onto (8, m+2), east
  // into reactor A's input port (17, m+2). (9, m+2) is the press's hand
  // tile's floor, and (10..11, m+2) the walkers' way down to row m: all
  // three are crossings.
  l.beltEast(8, 16, m + 2, crossings: {9, 10, 11});
  // Reactor A (17, m+1): catalyst by hand at (18, m+1), from (18, m).
  l.machine(17, m + 1, RefineryRecipes.synthesise);
  // Line B's volatiles: kiln B's output port (11, m+5) one tile into
  // reactor B's input port (13, m+5). Reactor B (13, m+4): catalyst by
  // hand at (14, m+4), from the corridor tile (14, m+3).
  l.add(EntityKind.belt, 12, m + 5);
  l.machine(13, m + 4, RefineryRecipes.synthesise);

  // Line A's pipes from reactor A's output ports (20, m+2) fuel and
  // (20, m+3) LOX to its filling bay.
  l.beltEast(21, _fillX - 1, m + 2);
  l.beltEast(21, _fillX + 3, m + 3);
  _fillBay(l, m + 1);

  // Line B's pipes from reactor B's output ports (16, m+5) fuel and
  // (16, m+6) LOX, climbing two rows over line A's filling lane: the LOX
  // pipe turns north first (one tile west), so the two never cross.
  l.beltEast(17, _climbX - 1, m + 5);
  l.beltRun(m + 5, m + 6, _climbX, Dir4.north);
  l.beltEast(_climbX, _fillX - 1, m + 7);
  l.beltEast(17, _climbX - 2, m + 6);
  l.beltRun(m + 6, m + 7, _climbX - 1, Dir4.north);
  l.beltEast(_climbX - 1, _fillX + 3, m + 8);
  _fillBay(l, m + 6);

  // The walkers' muster area, south of the core.
  l.add(EntityKind.staging, 12, m - 3, span: (3, 2));
  // The shipping aisle along the east wall, and its charging bay.
  l.add(EntityKind.aisle, _shipAisleX, 0, span: (2, kRefineryHall.h));
  l.add(EntityKind.chargingBay, _shipAisleX - 2, m + 10);
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
