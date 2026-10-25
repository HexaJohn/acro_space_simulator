// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What moves on a factory floor (docs/plans/factory-floors.md §3).
///
/// Every item counts as some colony commodity when it crosses a dock: loose
/// ore is one unit of `ore`, a steel crate is ten units of `steel`, and an
/// intermediate (pig iron, slag …) is one unit of its OWN commodity id, which
/// joins `Commodity`'s COMPONENTS section at integration (phase 3). So any
/// item can be shipped out or received in — a plant may make its plates in
/// place or buy them from the plant next door.
///
/// [loadClass] decides who can move an item: a worker on foot carries hand
/// loads only, a jack or forklift takes pallets, and only a crane lifts heavy.
library;

/// How heavy a load is to move, lightest first (compare by [index]).
enum LoadClass { hand, pallet, heavy }

class FactoryItem {
  const FactoryItem({
    required this.id,
    required this.label,
    required this.loadClass,
    required this.kgPerUnit,
    String? commodity,
    this.commodityUnits = 1,
  }) : commodity = commodity ?? id;

  /// Stable id, saved in floors and blueprints.
  final String id;
  final String label;
  final LoadClass loadClass;

  /// Mass of ONE item, for transport pricing and handling.
  final double kgPerUnit;

  /// The colony commodity this item counts as at a dock.
  final String commodity;

  /// How many units of [commodity] one item is (a crate holds several).
  final double commodityUnits;

  bool get isCrate => commodityUnits > 1;

  /// The name an item picker shows, making loose vs packed obvious
  /// (docs/plans/factory-floors.md §10 item 6): "Electronics (loose ·
  /// hand)" next to "Electronics ×10 (crate · pallet)".
  ///
  /// The playtest found "Electronics" and "Electronics Crate" side by side
  /// read as the same thing, and a dock set to the crate fed a bench that
  /// wanted loose boards. So the name is DERIVED from what actually differs
  /// — [commodityUnits] and [loadClass] — never hand-written per item, and
  /// a pack is named after the loose good it holds (its [commodity]'s own
  /// label) with the pack word taken from its id prefix ("crate:",
  /// "tote:", "pack:").
  String get pickerLabel {
    final lc = loadClass.name;
    if (!isCrate) return '$label (loose · $lc)';
    final base = FactoryItems.byId(commodity)?.label ?? label;
    final cut = id.indexOf(':');
    final pack = cut > 0 ? id.substring(0, cut) : 'pack';
    final u = commodityUnits;
    final n = u == u.roundToDouble() ? u.toInt().toString() : u.toString();
    return '$base ×$n ($pack · $lc)';
  }
}

/// The item table. Provisional entries for the Steel Mill chain (phase 1);
/// tracks add their own items here, never rename an id once saved.
class FactoryItems {
  FactoryItems._();

  static const ore = FactoryItem(
      id: 'ore', label: 'Ore', loadClass: LoadClass.pallet, kgPerUnit: 1000);
  static const pigIron = FactoryItem(
      id: 'pigIron', label: 'Pig Iron', loadClass: LoadClass.pallet,
      kgPerUnit: 500);
  static const slag = FactoryItem(
      id: 'slag', label: 'Slag', loadClass: LoadClass.pallet, kgPerUnit: 400);
  static const steelBillet = FactoryItem(
      id: 'steelBillet', label: 'Steel Billet', loadClass: LoadClass.heavy,
      kgPerUnit: 1500);
  static const steel = FactoryItem(
      id: 'steel', label: 'Steel', loadClass: LoadClass.hand, kgPerUnit: 100);
  static const tubes = FactoryItem(
      id: 'tubes', label: 'Tubes', loadClass: LoadClass.hand, kgPerUnit: 80);
  static const crateSteel = FactoryItem(
      id: 'crate:steel', label: 'Steel Crate', loadClass: LoadClass.pallet,
      kgPerUnit: 1000, commodity: 'steel', commodityUnits: 10);
  static const crateTubes = FactoryItem(
      id: 'crate:tubes', label: 'Tube Crate', loadClass: LoadClass.pallet,
      kgPerUnit: 800, commodity: 'tubes', commodityUnits: 10);

  // ---- Every colony good, loose and packed (wave 2) ----
  // Defined ONCE here so parallel chains never register the same id twice.
  // A loose item is ONE commodity unit (mass from economy/commodity_mass.dart);
  // a pack is several, sized to what a real handler moves as one load.
  // Chains add only their own intermediates, prefixed '<plant>:'.

  static const water = FactoryItem(
      id: 'water', label: 'Water', loadClass: LoadClass.hand, kgPerUnit: 1);
  /// An IBC tote: a tonne of water on a pallet.
  static const toteWater = FactoryItem(
      id: 'tote:water', label: 'Water Tote', loadClass: LoadClass.pallet,
      kgPerUnit: 1000, commodity: 'water', commodityUnits: 1000);
  static const food = FactoryItem(
      id: 'food', label: 'Food', loadClass: LoadClass.hand, kgPerUnit: 1);
  /// A pallet of boxed food, half a tonne.
  static const crateFood = FactoryItem(
      id: 'crate:food', label: 'Food Pallet', loadClass: LoadClass.pallet,
      kgPerUnit: 500, commodity: 'food', commodityUnits: 500);
  static const oxygen = FactoryItem(
      id: 'oxygen', label: 'Oxygen', loadClass: LoadClass.hand, kgPerUnit: 1);
  /// A cylinder bundle: 100 kg of O₂ in a racked pack (tare not counted: a
  /// pack weighs what it holds, so docks convert mass one for one).
  static const packOxygen = FactoryItem(
      id: 'pack:oxygen', label: 'O₂ Cylinder Pack',
      loadClass: LoadClass.pallet, kgPerUnit: 100, commodity: 'oxygen',
      commodityUnits: 100);
  static const medicine = FactoryItem(
      id: 'medicine', label: 'Medicine', loadClass: LoadClass.hand,
      kgPerUnit: 1);
  static const crateMedicine = FactoryItem(
      id: 'crate:medicine', label: 'Medicine Case', loadClass: LoadClass.hand,
      kgPerUnit: 25, commodity: 'medicine', commodityUnits: 25);
  /// A tonne of propellant in a tote: pallet work.
  static const fuel = FactoryItem(
      id: 'fuel', label: 'Fuel', loadClass: LoadClass.pallet, kgPerUnit: 1000);
  static const oxidizer = FactoryItem(
      id: 'oxidizer', label: 'Oxidizer', loadClass: LoadClass.pallet,
      kgPerUnit: 1000);
  static const electronics = FactoryItem(
      id: 'electronics', label: 'Electronics', loadClass: LoadClass.hand,
      kgPerUnit: 10);
  static const crateElectronics = FactoryItem(
      id: 'crate:electronics', label: 'Electronics Crate',
      loadClass: LoadClass.pallet, kgPerUnit: 100, commodity: 'electronics',
      commodityUnits: 10);
  /// Engine and avionics sections: a hoist or a crane, never a back.
  static const rocketParts = FactoryItem(
      id: 'rocketParts', label: 'Rocket Parts', loadClass: LoadClass.heavy,
      kgPerUnit: 100);
  static const guns = FactoryItem(
      id: 'guns', label: 'Guns', loadClass: LoadClass.hand, kgPerUnit: 4);
  static const crateGuns = FactoryItem(
      id: 'crate:guns', label: 'Arms Crate', loadClass: LoadClass.hand,
      kgPerUnit: 40, commodity: 'guns', commodityUnits: 10);
  static const ammo = FactoryItem(
      id: 'ammo', label: 'Ammo', loadClass: LoadClass.hand, kgPerUnit: 12);
  static const crateAmmo = FactoryItem(
      id: 'crate:ammo', label: 'Ammo Pallet', loadClass: LoadClass.pallet,
      kgPerUnit: 600, commodity: 'ammo', commodityUnits: 50);
  static const rations = FactoryItem(
      id: 'rations', label: 'Rations', loadClass: LoadClass.hand,
      kgPerUnit: 1);
  static const crateRations = FactoryItem(
      id: 'crate:rations', label: 'Ration Pallet', loadClass: LoadClass.pallet,
      kgPerUnit: 200, commodity: 'rations', commodityUnits: 200);
  static const missiles = FactoryItem(
      id: 'missiles', label: 'Missile', loadClass: LoadClass.heavy,
      kgPerUnit: 1000);

  static final Map<String, FactoryItem> table = {
    for (final i in const [
      ore, pigIron, slag, steelBillet, steel, tubes, crateSteel, crateTubes,
      water, toteWater, food, crateFood, oxygen, packOxygen, medicine,
      crateMedicine, fuel, oxidizer, electronics, crateElectronics,
      rocketParts, guns, crateGuns, ammo, crateAmmo, rations, crateRations,
      missiles,
    ])
      i.id: i,
  };

  static FactoryItem? byId(String id) => table[id];

  /// Adds [item] (a later track's chain). Refuses to redefine an id.
  static void register(FactoryItem item) {
    final had = table[item.id];
    if (had != null && !identical(had, item)) {
      throw StateError('FactoryItem ${item.id} already registered');
    }
    table[item.id] = item;
  }
}
