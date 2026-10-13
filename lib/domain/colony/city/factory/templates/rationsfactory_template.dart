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
/// great": its haul from the kitchen to the filling room is long, so it
/// needs walkers a designer can engineer away.
///
/// ## The Rations Plant (spec: 1.0 food → 0.8 rations /s, 18 jobs)
///
/// Mass balance per second at the spec rate:
///
///     1.0 food ──depalletise──► 1.0 food (loose cases)
///         ──cook (2 kettles)──► 0.08 pans of stew (10 portions each)
///         │                     └─► 0.2 kg/s steam, vented (no item)
///         ──fill & seal──► 0.8 pouches ──retort──► 0.8 rations
///         ──pallet──► 0.004 ration pallets (200 each)
///
/// Food arrives as half-tonne pallets (`crate:food`, 500 units) and leaves
/// as 200-unit ration pallets (`crate:rations`), both the colony's own
/// packs from `FactoryItems`. The 20% the plant "loses" is moisture boiled
/// off in the kettles, not a byproduct item, so the plant takes nothing
/// but food and ships nothing but rations.
///
/// The pace-setter is the kitchen: two MANUAL kettles each cook 50 food in
/// 100 s, exactly 1.0 food/s between them, and everything downstream has
/// 20-50% slack. So the spec rate is the kettles' rate, not a dock's.
///
/// ## The hall: 124 × 88 m, docks on opposite walls
///
/// A food plant's realistic mix (§3 "Template plants", the user's brief:
/// people and vehicles move freight, very few plants are lights-out):
///
/// * **Receiving is people and a pallet jack.** Food pallets are set down
///   in a small cold-store staging bay inside the west door; a pallet-jack
///   driver walks each one to the depalletiser, where two workers break it
///   down by hand onto a conveyor. No dock conveyor: one pallet every eight
///   minutes doesn't pay for one.
/// * **Belts where the flow is steady.** Loose food rides a belt past both
///   kettles, and arms tip it in; sealed pouches ride a long belt across
///   the hall from the filling room to the retort. These are the plant's
///   continuous ~1 item/s flows, and nobody carries those by hand.
/// * **Walkers carry the hot pans.** Each kettle batch fills four hotel
///   pans that cooks' helpers carry, one at a time, across the kitchen to
///   the filling table. That walk is the template's real handling work —
///   and its slack is the lever: see [kRationsWalkers].
/// * **Manual and assisted stations.** Kettles, filler, depalletiser and
///   palletiser are hand work (two each); the retort is ASSISTED, one
///   operator minding a steam autoclave.
/// * **A forklift at dispatch.** Finished ration pallets wait at the
///   palletiser for a forklift, which drives them along the aisle down the
///   east wall to the shipping door and charges at a bay beside it.
///
/// Nothing needs a crane: the heaviest load is a half-tonne pallet.
///
/// Jobs: 5 manual stations × 2 + 1 assisted × 1 + 5 walkers + 1 pallet
/// jack + 1 forklift = 18, the spec's count.
///
/// Capex (`capexOf`): the hall is most of it — 124 × 88 m of chilled,
/// washable food-grade shed (~27 ore) plus doors and aisle — then the
/// stations (~6.7), belts and arms (~2.4), the two vehicles and their
/// charger (1.4): ~39 ore against the spec's default 40.
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

  /// A gastronorm hotel pan of cooked stew, ten portions: 10 kg, carried
  /// by hand (two-handed, hot).
  static const tray = FactoryItem(
      id: 'rationsfactory:tray', label: 'Pan of Stew',
      loadClass: LoadClass.hand, kgPerUnit: 10);

  /// One filled, sealed, not-yet-sterilised retort pouch: one ration's
  /// worth (rations are 1 kg units).
  static const pouch = FactoryItem(
      id: 'rationsfactory:pouch', label: 'Sealed Pouch',
      loadClass: LoadClass.hand, kgPerUnit: 1);

  static const all = [tray, pouch];
}

/// Recipe ids of the rations chain. Saved on machines: never rename.
class RationsRecipes {
  RationsRecipes._();

  static const depalletise = FactoryRecipe(
    id: 'rationsfactory:depalletise',
    label: 'Break Down Food Pallet',
    station: StationKind.unpacker,
    inputs: [ItemQty('crate:food', 1)],
    outputs: [ItemQty('food', 500)],
    // 150 s: two workers (manual, 250 s) unwrap and de-stack a half-tonne
    // pallet in about four minutes, 2 food/s against the 1.0 needed — the
    // depalletiser works ahead and waits on a full output buffer.
    seconds: 150,
    // A stretch-wrap cutter and the roller table: a few kW.
    powerKw: 3,
  );

  static const cook = FactoryRecipe(
    id: 'rationsfactory:cook',
    label: 'Cook Stew',
    station: StationKind.chem,
    inputs: [ItemQty('food', 50)],
    outputs: [ItemQty('rationsfactory:tray', 4)],
    // 60 s: a manual kettle (100 s) cooks 0.5 food/s, so the template's
    // two kettles ARE the spec's 1.0 food/s — the plant's pace-setter.
    // 50 food in, 40 portions out: 20% boiled off as steam.
    seconds: 60,
    // A ~300 L steam-jacketed tilting kettle: ~40 kW of heating.
    powerKw: 40,
  );

  static const fill = FactoryRecipe(
    id: 'rationsfactory:fill',
    label: 'Portion and Seal Pouches',
    station: StationKind.assembler,
    inputs: [ItemQty('rationsfactory:tray', 1)],
    outputs: [ItemQty('rationsfactory:pouch', 10)],
    // 6 s: a manual filling table (10 s a pan) seals 1.0 pouch/s against
    // the 0.8 needed — 80% busy.
    seconds: 6,
    // A depositor and an impulse heat-sealer.
    powerKw: 10,
  );

  static const retort = FactoryRecipe(
    id: 'rationsfactory:retort',
    label: 'Retort Pouches',
    station: StationKind.furnace,
    inputs: [ItemQty('rationsfactory:pouch', 20)],
    outputs: [ItemQty('rations', 20)],
    // 20 s: a basket of 20 pouches through the assisted autoclave (speed
    // 1) every 20 s, 1.0 rations/s against 0.8. Gameplay-scaled — a real
    // retort cycle is ~an hour on a cart of thousands.
    seconds: 20,
    // A steam retort is the plant's biggest heater.
    powerKw: 60,
  );

  static const pack = FactoryRecipe(
    id: 'rationsfactory:pack',
    label: 'Pallet Rations',
    station: StationKind.packer,
    inputs: [ItemQty('rations', 200)],
    outputs: [ItemQty('crate:rations', 1)],
    // 100 s: two workers (manual, 167 s) case and stack a 200-ration
    // pallet, 1.2 rations/s against 0.8.
    seconds: 100,
    // A stretch wrapper.
    powerKw: 5,
  );

  static const all = [depalletise, cook, fill, retort, pack];
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

/// Rations hall: 62 × 44 tiles = 124 × 88 m, inside the 320 × 240 m site.
/// Roomy on purpose: the spec prices the plant at 40 ore, and a chilled
/// food-grade shed with a kitchen, a separate clean filling room and a
/// cold store is mostly floor (hall area is build cost).
const HallSize kRationsHall = HallSize(62, 44);

/// Walkers carrying pans of stew from the kettles to the filling table.
/// The filler only ever calls for two pans at once, so: three hold the
/// rate only with the pallet-jack driver lending a hand, four hold it
/// alone, and the fifth is a spare who mostly waits — the slack a designer
/// can take back by putting the filler beside the kettles.
const int kRationsWalkers = 5;

/// One pallet jack walks food pallets from the receiving bay to the
/// depalletiser: one every 500 s, light work for one driver.
const int kRationsJacks = 1;

/// One forklift takes ration pallets to the shipping door: one every
/// 250 s, a one-tile hop, so one driver with time to spare.
const int kRationsForklifts = 1;

/// x of the forklift aisle's west lane (two tiles wide).
const int _aisleX = 58;

/// x of the shipping door, on the east wall beyond the aisle.
const int _shipX = 60;

/// Row of the receiving bay and the food belt (the hall's lower middle).
const int _foodY = 15;

/// Row of the filling room's pouch belt.
const int _pouchY = 26;

/// x of the filling table: across the kitchen from both kettles.
const int _fillX = 24;

/// A fresh Rations Plant template (the caller may edit it).
FloorBlueprint rationsfactoryTemplate() {
  ensureFactoryCatalog();
  registerRationsChain();
  final l = TemplateLayout();
  // The walkers' muster area in the kitchen (the first staging by id is
  // where idle hands stand and new hires start).
  l.add(EntityKind.staging, 16, _foodY + 8, span: (3, 2));
  // Receiving: west door, a 2 × 2-tile cold-store bay (8 pallets), and the
  // depalletiser a short jack trip away.
  l.add(EntityKind.receivingDock, 0, _foodY + 1, item: 'crate:food');
  l.add(EntityKind.staging, 2, _foodY, span: (2, 2));
  l.machine(8, _foodY, RationsRecipes.depalletise);
  // Loose food on a belt past both kettles; an arm tips it into each.
  l.arm(11, _foodY, Dir4.east);
  l.beltEast(12, 28, _foodY);
  l.machine(16, _foodY + 2, RationsRecipes.cook);
  l.arm(17, _foodY + 1, Dir4.north);
  l.machine(25, _foodY + 2, RationsRecipes.cook);
  l.arm(28, _foodY + 1, Dir4.north); // at the belt's last tile
  // The filling room: walkers bring pans; pouches leave on a long belt to
  // the retort, then by arm to the palletiser.
  l.machine(_fillX, _pouchY, RationsRecipes.fill);
  l.arm(_fillX + 3, _pouchY, Dir4.east);
  l.beltEast(_fillX + 4, 48, _pouchY);
  l.arm(49, _pouchY, Dir4.east);
  l.machine(50, _pouchY, RationsRecipes.retort, mode: MachineMode.assisted);
  l.arm(54, _pouchY, Dir4.east);
  l.machine(55, _pouchY, RationsRecipes.pack);
  // Dispatch: the forklift aisle down the east wall, the shipping door
  // beside the palletiser, and the forklift's charger just north of it.
  l.add(EntityKind.aisle, _aisleX, 0, span: (2, kRationsHall.h));
  l.add(EntityKind.shippingDock, _shipX, _pouchY, item: 'crate:rations');
  l.add(EntityKind.chargingBay, _shipX, _pouchY + 4);
  return FloorBlueprint(
    name: 'Rations Plant',
    plantType: kRationsType,
    hall: kRationsHall,
    placements: l.out,
    roster: {
      HandlerKind.onFoot: kRationsWalkers,
      HandlerKind.palletJack: kRationsJacks,
      HandlerKind.forklift: kRationsForklifts,
    },
  );
}
