// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Rations Plant's default floor (docs/plans/factory-floors.md §3
/// "Templates", phase 6), and the food-packing chain it runs.
///
/// Like every template it is a built-in [FloorBlueprint] whose MEASURED
/// rate matches the plant's flat `CityBuildingSpec` rate within 5%, with
/// the spec's jobs and build cost within 10%, so opening the floor never
/// changes what the colony gets. And like the Steel Mill it is "fine, not
/// great": its kettles are fed by a crew carrying cases out of the cold
/// store, labour a designer can engineer away.
///
/// ## Measured the way the colony measures it
///
/// The colony measures a floor with `MeasureSettings.standard`: one minute
/// of warm-up from an empty floor, then at most five minutes. So the
/// template is built to read its spec rate THERE, not only over hours:
///
/// * **Loose goods at both doors.** Food comes in as loose cases and
///   rations leave as loose cases. The colony's pallets (`crate:food` is
///   500 units, `crate:rations` 200) would arrive once every 500 s and
///   leave once every 250 s, so a five-minute window would read whole
///   pallets, not a rate (a first version did: 3.3 food/s in, nothing
///   out). The receiving dock emits one case a second, which IS the
///   spec's 1.0 food/s: the dock is the pace-setter, everything after it
///   has 20-25% slack.
/// * **Small batches, short cycles.** Every recipe cycles in 8 s or less
///   and holds a few items, so the line fills (and its first rations ship)
///   inside the warm-up, and what the floor holds in steady state is about
///   what it took in during that first minute.
///
/// ## The Rations Plant (spec: 1.0 food → 0.8 rations /s, 18 jobs)
///
/// Mass balance per second at the spec rate:
///
///     1.0 food (cases) ──walkers──► 2 kettles' hand ports
///         ──cook──► 0.2 pans of stew (4 portions each)
///         │         └─► 0.2 food/s boiled off as steam (no item)
///         ──belts──► filling table's input port
///         ──fill & seal──► 0.1 retort carts (8 pouches each)
///         ──forklift, hand port to hand port──► retort
///         ──retort & case──► 0.8 rations ──belt──► shipping door
///
/// The 20% the plant "loses" is moisture boiled off in the kettles, not a
/// byproduct item, so the plant takes nothing but food and ships nothing
/// but rations. Measured over the long window: 1.00 food in, 0.79 rations
/// out (the last 1% is the line's fill, still being topped up).
///
/// ## The hall: 104 × 124 m, the line in the south-west corner
///
/// Laid for EXPLICIT PORTS (docs/plans/factory-floors.md §10 item 19,
/// `station_ports.dart`): belts connect at a station's input and output
/// ports, handlers work it at its hand port only, and no arm touches a
/// machine. A food plant's realistic mix (§3 "Template plants", the user's
/// brief: people and vehicles move freight, very few plants are
/// lights-out):
///
/// * **Receiving is people.** Cases come through the west door into a
///   small cold-store bay; a crew of nine carries them, one at a time, to
///   whichever kettle's hand port calls for food. The two kettles face
///   each other across the bay so both ports are two tiles from it (see
///   [rationsfactoryTemplate]). That is the template's real handling work
///   and it is all needed: measured, eight carriers bring 0.94 food/s,
///   nine the full 1.0 (see [kRationsWalkers]).
/// * **Belts where the flow is steady.** Each kettle pushes its pans out
///   of its front port onto a belt, and the two runs merge into the
///   filling table's input port; nobody carries hot stew.
/// * **A forklift for the carts.** The filling table racks sealed pouches
///   on wheeled retort carts and offers them at its hand port; a forklift
///   on the aisle below runs each cart to the retort's hand port (one
///   every 10 s), and charges at a bay at the aisle's end.
/// * **Manual stations.** Kettles, filling table and retort are hand work,
///   two people each.
///
/// Nothing needs a crane: the heaviest load is a ~60 kg retort cart.
///
/// Jobs: 4 manual stations × 2 + 9 case carriers + 1 forklift driver = 18,
/// the spec's count.
///
/// Capex (`capexOf`): the shed is most of it — 104 × 124 m of chilled,
/// washable food-grade hall (~32 ore): the line itself is small, the rest
/// is the dry store, packaging store, washdown and staff areas a food
/// plant needs but the floor sim doesn't model as entities. Then the
/// stations, the forklift and its charger, the 20 belt tiles, the doors
/// and the aisle: 40.4 ore against the spec's default 40.
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
const String kRationsType = 'rationsfactory';

/// The chain's own intermediates. Saved on floors: never rename an id.
class RationsItems {
  RationsItems._();

  /// A gastronorm hotel pan of cooked stew, four portions: 4 kg. Moved by
  /// arm from kettle to filling table, so it never needs a carrier.
  static const tray = FactoryItem(
      id: 'rationsfactory:tray', label: 'Pan of Stew',
      loadClass: LoadClass.hand, kgPerUnit: 4);

  /// A wheeled retort rack of eight filled, sealed, not-yet-sterilised
  /// pouches. Pallet-class because the steel frame plus its eight 1 kg
  /// pouches (~60 kg) is a forklift or jack load, not a carry.
  static const cart = FactoryItem(
      id: 'rationsfactory:cart', label: 'Retort Cart',
      loadClass: LoadClass.pallet, kgPerUnit: 60);

  static const all = [tray, cart];
}

/// Recipe ids of the rations chain. Saved on machines: never rename.
class RationsRecipes {
  RationsRecipes._();

  static const cook = FactoryRecipe(
    id: 'rationsfactory:cook',
    label: 'Cook Stew',
    station: StationKind.chem,
    inputs: [ItemQty('food', 5)],
    outputs: [ItemQty('rationsfactory:tray', 1)],
    // 4.5 s: a manual kettle (x0.6, 7.5 s a batch) cooks 0.67 food/s, so
    // the template's two take 1.33 food/s against the dock's 1.0 — 75%
    // busy, never the bottleneck. Small batches on purpose: a short cycle
    // fills the line inside the colony's one-minute measurement warm-up.
    // 5 food in, 4 portions out: 20% boiled off.
    seconds: 4.5,
    // A steam-jacketed tilting kettle: ~40 kW of heating.
    powerKw: 40,
  );

  static const fill = FactoryRecipe(
    id: 'rationsfactory:fill',
    label: 'Fill and Seal a Retort Cart',
    station: StationKind.assembler,
    inputs: [ItemQty('rationsfactory:tray', 2)],
    outputs: [ItemQty('rationsfactory:cart', 1)],
    // 4.8 s: a manual filling table (8 s) portions two pans into eight
    // pouches, seals them and racks them: 0.125 carts/s against the 0.1
    // needed, 80% busy.
    seconds: 4.8,
    // A depositor and an impulse heat-sealer.
    powerKw: 10,
  );

  static const retort = FactoryRecipe(
    id: 'rationsfactory:retort',
    label: 'Retort and Case Rations',
    station: StationKind.furnace,
    inputs: [ItemQty('rationsfactory:cart', 1)],
    outputs: [ItemQty('rations', 8)],
    // 4.8 s: two operators (manual, 8 s a cart) load the steam autoclave,
    // unload it and case the eight pouches as rations: 1.0 rations/s
    // against 0.8, 80% busy. Gameplay-scaled: a real retort cycle is ~an
    // hour on a cart of thousands.
    seconds: 4.8,
    // A steam retort is the plant's biggest heater.
    powerKw: 60,
  );

  static const all = [cook, fill, retort];
}

/// Registers the rations chain's items and recipes. Idempotent: the
/// registries accept the identical const object again, so any number of
/// callers (template, save loader, editor palette, tests) may call it.
void registerRationsChain() {
  for (final i in RationsItems.all) {
    FactoryItems.register(i);
  }
  for (final r in RationsRecipes.all) {
    FactoryRecipes.register(r);
  }
}

/// Rations hall: 52 × 62 tiles = 104 × 124 m, inside the 320 × 240 m site.
/// Sized by the spec's 40-ore price (hall area is build cost): the line
/// takes the south-west corner, the rest is the stores, washdown and staff
/// areas any food plant has.
const HallSize kRationsHall = HallSize(52, 62);

/// Workers carrying food cases from the cold-store bay to the kettles'
/// hand ports, 1.0 cases/s in all. Measured (long window): eight bring
/// 0.94 food/s (6% short), nine the full rate — every one of them is
/// working, none is padding.
const int kRationsWalkers = 9;

/// One forklift runs retort carts from the filling table's hand port to
/// the retort's, five tiles along the aisle: one cart every 10 s.
const int kRationsForklifts = 1;

/// Row of the receiving door and the cold-store bay: the gap row between
/// the two kettles, where both open their hand ports. The bay's reach to
/// those two tiles is the carriers' walk (see [rationsfactoryTemplate]).
const int _recvY = 6;

/// A fresh Rations Plant template (the caller may edit it).
///
/// The tiles (x east, y north; every connection a port of
/// `station_ports.dart`, the hall's south-west corner):
///
///     y 8..11  kettle B (east-facing): hand port (5,8) below it, trays
///              out its front port (7,9) onto the collector at (8,9)
///     y 6..7   door (0,6) > bay (2..4,6); carriers stand at (5,7) for
///              kettle B and at (6,6) for kettle A
///     y 2..5   kettle A (WEST-facing, so its hand port (6,5) opens UP
///              into the gap): trays out its front port (4,4) onto (3,4)
///     y 2..4   filling table (10..12, 2..4), retort (16..19, 2..4)
///     y 0..1   tray belt from kettle A along row 1; the forklift aisle
///              (11..18, 0..1) under both hand ports, charger (19..20)
///
/// * **The kettles face each other across a two-row gap.** A kettle's
///   hand port is on its belly, so kettle B (facing east) opens it down
///   onto row 7 and kettle A, turned to face WEST, opens it up onto row
///   6. The cold-store bay sits in that gap inside the west door, one
///   case per tile row: two tiles from both ports. The bay's span is the
///   tuning knob: a 2-tile bay starves nine carriers at 0.78 food/s, a
///   3 x 2 one lets eight carry it all.
/// * **Trays ride belts to the filling table.** Kettle A's front port
///   faces west, so its pans go down column 3, east along row 1 and up
///   column 9; kettle B's go down column 8 and turn east on row 3. The
///   two meet at (9,3), the table's input port (10,3): a side merge, no
///   arm (arms no longer touch machines).
/// * **The forklift works hand ports.** The table has no belt at its
///   output port, so its carts wait at its hand port (12,2) and the
///   forklift, standing on the aisle at (12,1), takes them to the
///   retort's hand port (17,2), outside tile (17,1).
/// * **Rations leave by the retort's output port** (19,3) onto a belt
///   into the shipping door at (21,3). The retort's byproduct port (18,4)
///   is unused: steam is no item.
FloorBlueprint rationsfactoryTemplate() {
  ensureFactoryCatalog();
  registerRationsChain();
  final l = TemplateLayout();
  // Receiving: the cold-store bay inside the west door (3 × 1 tiles, six
  // cases). It is also the first staging by id, so it is where idle
  // carriers wait and new hires start.
  l.add(EntityKind.staging, 2, _recvY, span: (3, 1));
  l.add(EntityKind.receivingDock, 0, _recvY, item: 'food');
  // Kettle A faces west, kettle B east: both hand ports open on the gap.
  l.machine(4, 2, RationsRecipes.cook, dir: Dir4.west);
  l.machine(4, 8, RationsRecipes.cook);
  // Kettle A's pans: (3,4) down to (3,2), east along row 1, up to (9,2).
  l.beltRun(4, 2, 3, Dir4.south);
  l.beltEast(3, 8, 1);
  l.beltRun(1, 2, 9, Dir4.north);
  // Kettle B's pans: (8,9) down to (8,4), then east over (8,3) and into
  // the table's input port from (9,3), where kettle A's run joins.
  l.beltRun(9, 4, 8, Dir4.south);
  l.beltEast(8, 9, 3);
  l.machine(10, 2, RationsRecipes.fill);
  // The forklift aisle under the table's and the retort's hand ports, the
  // charger at its east end.
  l.add(EntityKind.aisle, 11, 0, span: (8, 2));
  l.add(EntityKind.chargingBay, 19, 0);
  l.machine(16, 2, RationsRecipes.retort);
  l.add(EntityKind.belt, 20, 3);
  l.add(EntityKind.shippingDock, 21, 3, item: 'rations');
  return FloorBlueprint(
    name: 'Rations Plant',
    plantType: kRationsType,
    hall: kRationsHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kRationsWalkers,
      HandlerKind.forklift: kRationsForklifts,
    },
  );
}
