// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Intermediates are real goods (user decision, 2026-10-12): a plant may
/// specialise — a smelting floor ships pig iron, and another plant receives
/// it and skips smelting. Through the colony's stock the two floors must
/// hand goods across exactly, with pig iron counted as its own commodity.
void main() {
  setUpAll(ensureFactoryCatalog);

  test('one floor ships pig iron that another turns into steel', () {
    // Every station is joined by belts on its ports (no arms into
    // machines). Smelter 4×4 at (4, 1): ore in at (4, 2) from (3, 2), pig
    // iron out at (7, 2) onto (8, 2), slag out at (6, 4) onto (6, 5).
    final smelt = Lay();
    smelt.add(EntityKind.receivingDock, 0, 2, item: 'ore');
    smelt.beltRow(2, 3, 2);
    smelt.add(EntityKind.machine, 4, 1,
        recipe: SteelRecipes.smelt.id, mode: MachineMode.assisted);
    smelt.beltRow(8, 13, 2);
    smelt.add(EntityKind.shippingDock, 14, 2);
    smelt.add(EntityKind.belt, 6, 5, dir: Dir4.north);
    smelt.add(EntityKind.shippingDock, 6, 6);
    final a = FactoryFloor.fromBlueprint(smelt.blueprint(18, 10));

    // Furnace 4×3 at (4, 1) → mill 5×3 at (9, 1) → packer 3×2 at (15, 1),
    // each output port's belt sitting on the next station's input port's
    // outside tile, pointing in.
    final steel = Lay();
    steel.add(EntityKind.receivingDock, 0, 2, item: 'pigIron');
    steel.beltRow(2, 3, 2);
    steel.add(EntityKind.machine, 4, 1,
        recipe: SteelRecipes.cast.id, mode: MachineMode.assisted);
    steel.add(EntityKind.belt, 8, 2);
    steel.add(EntityKind.machine, 9, 1,
        recipe: SteelRecipes.roll.id, mode: MachineMode.assisted);
    steel.add(EntityKind.belt, 14, 2);
    steel.add(EntityKind.machine, 15, 1,
        recipe: SteelRecipes.packSteel.id, mode: MachineMode.assisted);
    steel.add(EntityKind.belt, 18, 2);
    steel.add(EntityKind.shippingDock, 19, 2);
    final b = FactoryFloor.fromBlueprint(steel.blueprint(26, 5));
    expect(a.blueprint.validate(), isEmpty);
    expect(b.blueprint.validate(), isEmpty);

    final colony = StockColonyPort(stock: {'ore': 1e6});
    for (var i = 0; i < 60; i++) {
      a.step(10, colony);
      b.step(10, colony);
    }
    final shipped = a.ledger.shipped['pigIron']!;
    final received = b.ledger.received['pigIron']!;
    expect(shipped, greaterThan(100));
    expect(received, greaterThan(100));
    expect(colony.stock['pigIron'], shipped - received,
        reason: 'what the second plant took came from the first');
    expect(b.ledger.shipped['steel'], greaterThan(0),
        reason: 'the second plant skipped smelting and still made steel');
    expect(a.ledger.shipped.containsKey('steel'), isFalse);
  });
}
