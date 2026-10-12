// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What machines make (docs/plans/factory-floors.md §3).
///
/// A recipe is inputs → outputs in [FactoryRecipe.seconds] at speed 1, on one
/// [StationKind]. The station fixes the machine's footprint, so the editor
/// and the sim agree on the space a machine takes without reading recipes.
library;

import 'factory_item.dart';

/// A kind of machine. [footW] × [footH] tiles when facing east; a machine
/// facing north or south swaps them (`Dir4.isVertical`).
enum StationKind {
  smelter(4, 4),
  furnace(4, 3),
  press(3, 3),
  mill(5, 3),
  assembler(3, 3),
  chem(4, 4),
  packer(3, 2),
  unpacker(3, 2);

  const StationKind(this.footW, this.footH);
  final int footW, footH;
}

class ItemQty {
  const ItemQty(this.item, this.count);
  final String item;
  final int count;

  FactoryItem? get def => FactoryItems.byId(item);
}

class FactoryRecipe {
  const FactoryRecipe({
    required this.id,
    required this.label,
    required this.station,
    required this.inputs,
    required this.outputs,
    required this.seconds,
    required this.powerKw,
  });

  /// Stable id, saved on machines.
  final String id;
  final String label;
  final StationKind station;
  final List<ItemQty> inputs;
  final List<ItemQty> outputs;

  /// Craft time at speed 1 (a manual station's speed multiplier scales it).
  final double seconds;

  /// Draw while crafting, before the station mode's power multiplier.
  final double powerKw;
}

/// The recipe table. Provisional Steel Mill chain (phase 1 tunes the numbers
/// so the template matches the spec's flat rate); tracks add their own via
/// [register], never renaming a saved id.
class FactoryRecipes {
  FactoryRecipes._();

  static final Map<String, FactoryRecipe> table = {};

  static FactoryRecipe? byId(String id) => table[id];

  static void register(FactoryRecipe r) {
    final had = table[r.id];
    if (had != null && !identical(had, r)) {
      throw StateError('FactoryRecipe ${r.id} already registered');
    }
    table[r.id] = r;
  }

  /// Recipes a [station] can run, in id order (deterministic menus).
  static List<FactoryRecipe> forStation(StationKind station) =>
      [for (final r in table.values) if (r.station == station) r]
        ..sort((a, b) => a.id.compareTo(b.id));
}
