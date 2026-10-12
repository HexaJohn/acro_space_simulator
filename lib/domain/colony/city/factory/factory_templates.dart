// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The floor every placed plant ships with (docs/plans/factory-floors.md §3
/// "Templates", §8).
///
/// A template is a built-in [FloorBlueprint] whose MEASURED rate matches
/// the plant's flat `CityBuildingSpec` rate within 5%, so opening a floor
/// never makes a plant worse, and engaging is optional. It is deliberately
/// "fine, not great": every station is manual, so a designer who automates,
/// shortens the walks or adds a dock beats it (the Reward levers).
///
/// Phase 1 ships the Steel Mill only; phase 6 adds the rest. Zoned specs
/// never get one (user decision, 2026-10-12), so the site menu's "Factory
/// floor" action can key off `factoryTemplateFor(type) != null`.
///
/// ## The Steel Mill (spec: 2 ore → 1.5 steel + 0.4 tubes /s, 35 jobs)
///
/// A 120 × 56 m hall, two identical lines and a shared tube corner:
///
/// * Each line's receiving dock emits 1 ore/s onto a belt; arms feed two
///   smelters (ore → pig iron + slag). Arms drop pig iron onto a belt to the
///   furnace (→ billets, heavy: arms only), then the rolling mill (→ steel
///   bars) and a packer (→ steel crates), and crates ride a belt to a
///   shipping dock. The two docks, not any machine, set the rate.
/// * Slag never leaves: an arm from each smelter feeds a press between them
///   that makes tubes from it.
/// * The presses are cleared BY HAND: nine workers walk tubes to the shared
///   tube packer between the lines, crossing the belts at crossings. That
///   walk is the template's real handling work, and its slack is a lever.
///
/// 13 manual stations × 2 crew + 9 walkers = 35 jobs, the spec's count.
library;

import 'factory_catalog.dart';
import 'factory_entities.dart';
import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_recipe.dart';
import 'floor_blueprint.dart';

/// The plant type the Steel Mill template is for (`CityBuildingSpec.type`).
const String kSteelMillType = 'steelmill';

/// Steel Mill hall: 60 × 28 tiles = 120 × 56 m, a mid-size mill shed.
const HallSize kSteelMillHall = HallSize(60, 28);

/// Workers on foot carrying tubes, one at a time, 0.4 tubes/s in all.
/// Measured: eight hold the spec rate, seven fall ~5% short; nine keeps
/// one spare so a busy moment never starves the packer.
const int kSteelMillWalkers = 9;

/// A fresh template blueprint for [plantType], or null when that plant has
/// none (every zoned spec, and every placed plant but the Steel Mill until
/// phase 6).
FloorBlueprint? factoryTemplateFor(String plantType) {
  ensureFactoryCatalog();
  return switch (plantType) {
    kSteelMillType => _steelMill(),
    _ => null,
  };
}

/// Hands out placement ids in order, so the template is stable across
/// builds (saves key runtime state by id).
class _Layout {
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

  void machine(int x, int y, FactoryRecipe r) =>
      add(EntityKind.machine, x, y, recipe: r.id, mode: MachineMode.manual);

  void arm(int x, int y, Dir4 dir, {String? only}) =>
      add(EntityKind.arm, x, y, dir: dir, item: only);

  /// An eastbound belt over x0..x1 inclusive; [crossings] are walkable.
  void beltEast(int x0, int x1, int y, {Set<int> crossings = const {}}) {
    for (var x = x0; x <= x1; x++) {
      add(crossings.contains(x) ? EntityKind.crossing : EntityKind.belt, x, y);
    }
  }
}

/// One ore-to-steel line with its base row at [y].
void _steelLine(_Layout l, int y, {Set<int> oreCrossings = const {}}) {
  // Ore in: dock on the west wall, belt past both smelters.
  l.add(EntityKind.receivingDock, 0, y, item: 'ore');
  l.beltEast(2, 16, y, crossings: oreCrossings);
  l.arm(5, y + 1, Dir4.north);
  l.arm(14, y + 1, Dir4.north);
  // Two smelters with the slag press between them.
  l.machine(4, y + 2, SteelRecipes.smelt);
  l.machine(9, y + 2, SteelRecipes.tube);
  l.machine(13, y + 2, SteelRecipes.smelt);
  l.arm(8, y + 3, Dir4.east); // smelter A → press (takes slag only)
  l.arm(12, y + 3, Dir4.west); // smelter B → press
  // Pig iron to the furnace by belt, with a crossing to the press.
  l.arm(6, y + 6, Dir4.north, only: 'pigIron');
  l.arm(14, y + 6, Dir4.north, only: 'pigIron');
  l.beltEast(6, 15, y + 7, crossings: {10});
  // Furnace → mill → packer → shipping, arm to arm.
  l.machine(16, y + 7, SteelRecipes.cast);
  l.arm(20, y + 8, Dir4.east);
  l.machine(21, y + 7, SteelRecipes.roll);
  l.arm(26, y + 8, Dir4.east);
  l.machine(27, y + 8, SteelRecipes.packSteel);
  l.arm(30, y + 8, Dir4.east);
  l.beltEast(31, 57, y + 8);
  l.add(EntityKind.shippingDock, 58, y + 8);
}

FloorBlueprint _steelMill() {
  final l = _Layout();
  _steelLine(l, 2);
  // The tube corner between the lines: walkers bring tubes from both
  // presses; crates leave by arm and belt.
  l.machine(9, 12, SteelRecipes.packTubes);
  l.arm(12, 12, Dir4.east);
  l.beltEast(13, 57, 12);
  l.add(EntityKind.shippingDock, 58, 12);
  // The walkers' muster area beside it (where new hires stand).
  l.add(EntityKind.staging, 3, 13, span: (4, 2));
  // The upper line's ore belt gets a crossing on the walk to its press.
  _steelLine(l, 16, oreCrossings: {10});
  return FloorBlueprint(
    name: 'Steel Mill',
    plantType: kSteelMillType,
    hall: kSteelMillHall,
    placements: l.out,
    roster: {HandlerKind.onFoot: kSteelMillWalkers},
  );
}
