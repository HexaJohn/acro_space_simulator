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

  static final Map<String, FactoryItem> table = {
    for (final i in const [
      ore, pigIron, slag, steelBillet, steel, tubes, crateSteel, crateTubes,
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
