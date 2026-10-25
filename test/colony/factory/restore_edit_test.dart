// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_unlocks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// The `restore` edits (docs/plans/factory-floors.md §10 item 9): the
/// editor's undo puts back what a floor had, which is not a purchase, so
/// it skips the colony's unlock gate — and nothing else. Without it, a
/// young colony could never undo deleting a template's assisted station.
void main() {
  setUpAll(ensureFactoryCatalog);

  FactoryFloor starter() => FactoryFloor.fromBlueprint(Lay().blueprint(20, 10),
      unlocks: FactoryUnlocks.starter);

  Placement smelter(int x, MachineMode mode) => Placement(
      id: 0, kind: EntityKind.machine, pos: TilePos(x, 0),
      recipe: SteelRecipes.smelt.id, mode: mode);

  test('restore places a locked kind; the layout rules still hold', () {
    final f = starter();
    expect(f.place(smelter(0, MachineMode.automated)).refusal,
        EditRefusal.notAllowed, reason: 'a purchase needs the unlock');
    final r = f.place(smelter(0, MachineMode.automated), restore: true);
    expect(r.ok, isTrue);
    expect(f.place(smelter(0, MachineMode.automated), restore: true).refusal,
        EditRefusal.overlaps, reason: 'restore never skips overlap');
    expect(
        f.place(
                const Placement(id: 0, kind: EntityKind.machine,
                    pos: TilePos(10, 0), recipe: 'no-such-recipe'),
                restore: true)
            .refusal,
        EditRefusal.unknownRecipe);
    expect(
        f.place(smelter(19, MachineMode.automated), restore: true).refusal,
        EditRefusal.outOfHall);
    expect(FactoryRecipes.byId(SteelRecipes.smelt.id), isNotNull);
  });

  test('restore sets a locked mode and re-hires a locked kind', () {
    final f = starter();
    final id = f.place(smelter(0, MachineMode.manual)).placementId!;
    expect(f.setMode(id, MachineMode.automated).refusal,
        EditRefusal.notAllowed);
    expect(f.setMode(id, MachineMode.automated, restore: true).ok, isTrue);
    expect(f.blueprint.byId(id)!.crew, MachineMode.automated);
    expect(f.hire(HandlerKind.forklift, 1).refusal, EditRefusal.notAllowed);
    expect(f.hire(HandlerKind.forklift, 1, restore: true).ok, isTrue);
    expect(f.blueprint.roster[HandlerKind.forklift], 1);
  });
}
