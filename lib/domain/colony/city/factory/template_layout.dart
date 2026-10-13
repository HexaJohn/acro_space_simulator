// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A small builder every plant template draws its floor with
/// (docs/plans/factory-floors.md §3 "Templates").
///
/// Ids are handed out in call order from 1, so a template's placement ids
/// are stable as long as its drawing code is: saves of an untouched
/// template floor keep meaning the same machines across versions.
library;

import 'factory_entities.dart';
import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_recipe.dart';

class TemplateLayout {
  final List<Placement> out = [];
  int _id = 1;

  void add(EntityKind kind, int x, int y,
      {Dir4 dir = Dir4.east,
      String? recipe,
      MachineMode? mode,
      String? item,
      (int, int)? span}) {
    out.add(Placement(
        id: _id++,
        kind: kind,
        pos: TilePos(x, y),
        dir: dir,
        recipe: recipe,
        mode: mode,
        item: item,
        span: span));
  }

  void machine(int x, int y, FactoryRecipe r,
          {MachineMode mode = MachineMode.manual, Dir4 dir = Dir4.east}) =>
      add(EntityKind.machine, x, y, recipe: r.id, mode: mode, dir: dir);

  void arm(int x, int y, Dir4 dir, {String? only}) =>
      add(EntityKind.arm, x, y, dir: dir, item: only);

  /// An eastbound belt over x0..x1 inclusive; [crossings] are walkable.
  void beltEast(int x0, int x1, int y, {Set<int> crossings = const {}}) =>
      beltRun(x0, x1, y, Dir4.east, crossings: crossings);

  /// A straight belt run from [from] to [to] along one axis (inclusive),
  /// every tile facing [dir]; tiles whose run coordinate is in [crossings]
  /// are laid as walkable crossings.
  void beltRun(int from, int to, int fixed, Dir4 dir,
      {Set<int> crossings = const {}}) {
    final lo = from < to ? from : to, hi = from < to ? to : from;
    for (var v = lo; v <= hi; v++) {
      final x = dir.isVertical ? fixed : v, y = dir.isVertical ? v : fixed;
      add(crossings.contains(v) ? EntityKind.crossing : EntityKind.belt, x, y,
          dir: dir);
    }
  }
}
