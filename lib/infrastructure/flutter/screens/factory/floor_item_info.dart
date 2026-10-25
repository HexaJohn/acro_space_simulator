// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the items on a floor ARE (docs/plans/factory-floors.md §10 item 18).
///
/// A coloured square tells the player nothing about whether it is ore or
/// slag. This file is the pure-Dart half of the answer, shared by the hover
/// tooltip, the legend and the painter's close-zoom labels, so all three
/// agree and tests read them without a widget tree:
///
/// * [tipAt]: the items held by whatever is under a tile (a handler's hands,
///   a floor pile, a belt tile, a chest, dock or machine), as name / count /
///   load class rows.
/// * [legendOf]: every item currently on the floor, with its colour and a
///   total, for the collapsible legend.
/// * [itemAbbrev]: the 2-3 letter label drawn on belt items and piles.
///
/// All of it reads the public [FactoryFloorView] (`beltItems`, `piles`,
/// `contentsOf`, `handlers`), so a fake sim works the same as the real one.
library;

import 'dart:ui' show Color;

import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import 'factory_floor_painter.dart' show itemColor;
import 'floor_layout_index.dart';

/// One line of a tooltip: [count] of the item named [name].
class TipRow {
  const TipRow(this.item, this.name, this.count, this.loadClass);
  final String item;
  final String name;
  final int count;

  /// "hand", "pallet" or "heavy"; null for an item no catalog knows.
  final String? loadClass;

  @override
  String toString() => '$name ×$count${loadClass == null ? '' : ' ($loadClass)'}';
}

/// A tooltip: what is under the cursor ([title]) and what it holds.
class FloorTip {
  const FloorTip(this.title, this.rows);
  final String title;
  final List<TipRow> rows;
}

/// One legend entry: an item present on the floor, its colour and total.
class LegendEntry {
  const LegendEntry(this.item, this.name, this.color, this.count);
  final String item;
  final String name;
  final Color color;
  final int count;
}

TipRow _row(String item, int n) {
  final def = FactoryItems.byId(item);
  return TipRow(item, def?.label ?? item, n, def?.loadClass.name);
}

List<TipRow> _rows(Map<String, int> bag) {
  final ks = bag.keys.where((k) => bag[k]! > 0).toList()..sort();
  return [for (final k in ks) _row(k, bag[k]!)];
}

/// The 2-3 letter label for [item]: the first three letters of a one-word
/// name ("Ore" is "Ore", "Slag" is "Sla"), initials of a longer one
/// ("Steel Billet" is "SB"). Crates share their loose good's label with a
/// trailing "x" so a crate never reads as the loose item.
String itemAbbrev(String item) {
  final def = FactoryItems.byId(item);
  final label = def?.label ?? item;
  final words = label
      .split(RegExp(r'[\s_\-:]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  var s = words.length == 1
      ? (words.first.length <= 3 ? words.first : words.first.substring(0, 3))
      : words.take(3).map((w) => w[0].toUpperCase()).join();
  if (def != null && def.isCrate && s.length < 3) s = '${s}x';
  return s;
}

/// What is under tile [t], or null for bare floor. Handlers win over piles,
/// piles over the placement beneath them.
FloorTip? tipAt(FactoryFloorView sim, FloorLayoutIndex ix, TilePos t) {
  for (final h in sim.handlers) {
    final w = kHandlerSpecs[h.kind]!.aisleTiles;
    final side = w < 1 ? 1 : w;
    if (t.x + 1 <= h.x || t.x >= h.x + side) continue;
    if (t.y + 1 <= h.y || t.y >= h.y + side) continue;
    final c = h.carrying;
    return FloorTip('${kHandlerSpecs[h.kind]!.label} (${h.state.name})',
        c == null ? const [] : [_row(c, h.carryingCount)]);
  }
  final pile = <String, int>{};
  for (final p in sim.piles) {
    if (p.tile == t) pile[p.item] = (pile[p.item] ?? 0) + p.count;
  }
  if (pile.isNotEmpty) return FloorTip('Pile', _rows(pile));
  final p = ix.hit(t);
  if (p == null) return null;
  if (p.kind == EntityKind.belt) {
    final bag = <String, int>{};
    for (final b in sim.beltItems) {
      if (b.tile == t) bag[b.item] = (bag[b.item] ?? 0) + 1;
    }
    return FloorTip('Belt', _rows(bag));
  }
  final held = sim.contentsOf(p.id);
  if (held.isEmpty && !_holdsItems(p.kind)) return null;
  return FloorTip(entityKindLabel(p.kind), _rows(held));
}

bool _holdsItems(EntityKind k) =>
    k == EntityKind.machine ||
    k == EntityKind.chest ||
    k == EntityKind.staging ||
    k == EntityKind.shippingDock ||
    k == EntityKind.receivingDock;

/// Every item currently on the floor, sorted by name: belts, piles,
/// handlers' hands and every placement's contents.
List<LegendEntry> legendOf(FactoryFloorView sim) {
  final n = <String, int>{};
  void add(String item, int c) => n[item] = (n[item] ?? 0) + c;
  for (final b in sim.beltItems) {
    add(b.item, 1);
  }
  for (final p in sim.piles) {
    add(p.item, p.count);
  }
  for (final h in sim.handlers) {
    final c = h.carrying;
    if (c != null && h.carryingCount > 0) add(c, h.carryingCount);
  }
  for (final p in sim.blueprint.placements) {
    sim.contentsOf(p.id).forEach((k, v) {
      if (v > 0) add(k, v);
    });
  }
  final out = [
    for (final e in n.entries)
      LegendEntry(e.key, FactoryItems.byId(e.key)?.label ?? e.key,
          itemColor(e.key), e.value),
  ]..sort((a, b) {
      final c = a.name.compareTo(b.name);
      return c != 0 ? c : a.item.compareTo(b.item);
    });
  return out;
}
