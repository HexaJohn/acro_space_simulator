// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The LAYOUT of a factory floor: what stands where
/// (docs/plans/factory-floors.md §3).
///
/// A [Placement] is pure design data — kind, tile, facing and settings —
/// shared by blueprints, the editor and the sim. Runtime state (items on a
/// belt, a machine's buffers and timer, a handler's trip) belongs to the sim
/// and is keyed by [Placement.id], so the same layout can be measured,
/// drawn, saved and stamped onto a site without carrying any of it.
library;

import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_recipe.dart';

enum EntityKind {
  /// Runs a recipe. Footprint from its recipe's [StationKind].
  machine,

  /// Carries items one tile along [Placement.dir] per step.
  belt,

  /// Swings one item from the tile behind it to the tile in front of it
  /// ([Placement.dir] points at the drop tile).
  arm,

  /// Holds items; handlers and arms take from and put into it.
  chest,

  /// A receiving door on the hall wall: emits [Placement.item] from the
  /// colony. Trucks dock here once freight runs (phase 7).
  receivingDock,

  /// A shipping door: consumes any item (or only [Placement.item]) into the
  /// colony.
  shippingDock,

  /// A floor area kept clear for handlers ([Placement.span]); vehicles path
  /// only on aisle tiles of their width (phase 4).
  aisle,

  /// Lets walkers and vehicles cross a belt (one tile).
  crossing,

  /// A crane runway over [Placement.span]; cranes work only inside one.
  craneBay,

  /// Pallet racking: dense storage a forklift can stack.
  rack,

  /// Where battery vehicles charge (phase 4).
  chargingBay,

  /// Floor area by a dock where unloaded freight is set down.
  staging,
}

/// Fixed footprints (east-facing) for every kind that is not a [machine]
/// and not sized by [Placement.span].
const Map<EntityKind, (int, int)> kEntityFootprint = {
  EntityKind.belt: (1, 1),
  EntityKind.arm: (1, 1),
  EntityKind.chest: (1, 1),
  EntityKind.receivingDock: (2, 1),
  EntityKind.shippingDock: (2, 1),
  EntityKind.crossing: (1, 1),
  EntityKind.rack: (2, 1),
  EntityKind.chargingBay: (2, 2),
};

/// Kinds whose size is the player's [Placement.span] rather than fixed.
const Set<EntityKind> kSpannedKinds = {
  EntityKind.aisle,
  EntityKind.craneBay,
  EntityKind.staging,
};

class Placement {
  const Placement({
    required this.id,
    required this.kind,
    required this.pos,
    this.dir = Dir4.east,
    this.recipe,
    this.mode,
    this.item,
    this.span,
  });

  /// Unique within a floor; runtime state is keyed by it.
  final int id;
  final EntityKind kind;

  /// Lowest-x, lowest-y tile of the footprint.
  final TilePos pos;
  final Dir4 dir;

  /// [EntityKind.machine]: the recipe id it runs.
  final String? recipe;

  /// [EntityKind.machine]: how it is crewed (default [MachineMode.assisted]).
  final MachineMode? mode;

  /// Docks and chests: the item it handles (null = any, for shipping).
  final String? item;

  /// Spanned kinds: width × height in tiles, as laid (no rotation).
  final (int, int)? span;

  MachineMode get crew => mode ?? MachineMode.assisted;

  /// Tiles covered, rotated by [dir]. A machine with an unknown recipe
  /// covers 1×1 so a bad save still loads and shows the fault.
  TileRect get footprint {
    int w, h;
    if (kSpannedKinds.contains(kind)) {
      (w, h) = span ?? (1, 1);
      return TileRect(pos.x, pos.y, w, h);
    }
    if (kind == EntityKind.machine) {
      final st = recipe == null ? null : FactoryRecipes.byId(recipe!)?.station;
      (w, h) = st == null ? (1, 1) : (st.footW, st.footH);
    } else if (span != null &&
        (kind == EntityKind.receivingDock || kind == EntityKind.shippingDock)) {
      // A wall dock (§10 item 3, dock_geometry.dart): its span is the
      // loading area, east-facing, rotated like a fixed footprint. A dock
      // with no span is a legacy 2 × 1 template dock.
      (w, h) = span!;
    } else {
      (w, h) = kEntityFootprint[kind] ?? (1, 1);
    }
    return dir.isVertical ? TileRect(pos.x, pos.y, h, w)
        : TileRect(pos.x, pos.y, w, h);
  }

  Placement copyWith({
    int? id,
    TilePos? pos,
    Dir4? dir,
    String? recipe,
    MachineMode? mode,
    String? item,
    (int, int)? span,
  }) =>
      Placement(
        id: id ?? this.id,
        kind: kind,
        pos: pos ?? this.pos,
        dir: dir ?? this.dir,
        recipe: recipe ?? this.recipe,
        mode: mode ?? this.mode,
        item: item ?? this.item,
        span: span ?? this.span,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'k': kind.name,
        'p': pos.toJson(),
        if (dir != Dir4.east) 'd': dir.name,
        'r': ?recipe,
        if (mode != null) 'm': mode!.name,
        'i': ?item,
        if (span != null) 's': [span!.$1, span!.$2],
      };

  static Placement fromJson(Map<String, Object?> j) {
    final s = j['s'] as List?;
    return Placement(
      id: (j['id'] as num).toInt(),
      kind: EntityKind.values.byName(j['k'] as String),
      pos: TilePos.fromJson(j['p']),
      dir: j['d'] == null ? Dir4.east : Dir4.values.byName(j['d'] as String),
      recipe: j['r'] as String?,
      mode: j['m'] == null ? null : MachineMode.values.byName(j['m'] as String),
      item: j['i'] as String?,
      span: s == null
          ? null
          : ((s[0] as num).toInt(), (s[1] as num).toInt()),
    );
  }

  @override
  String toString() => 'Placement#$id(${kind.name} @ $pos ${dir.name})';
}
