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
    final smelt = Lay();
    smelt.add(EntityKind.receivingDock, 0, 2, item: 'ore');
    smelt.beltRow(2, 8, 2);
    smelt.add(EntityKind.arm, 5, 3, dir: Dir4.north);
    smelt.add(EntityKind.machine, 4, 4,
        recipe: SteelRecipes.smelt.id, mode: MachineMode.assisted);
    smelt.add(EntityKind.arm, 8, 5);
    smelt.beltRow(9, 13, 5);
    smelt.add(EntityKind.shippingDock, 14, 5);
    final a = FactoryFloor.fromBlueprint(smelt.blueprint(18, 10));

    final steel = Lay();
    steel.add(EntityKind.receivingDock, 0, 2, item: 'pigIron');
    steel.beltRow(2, 5, 2);
    steel.add(EntityKind.machine, 6, 1,
        recipe: SteelRecipes.cast.id, mode: MachineMode.assisted);
    steel.add(EntityKind.arm, 10, 2);
    steel.add(EntityKind.machine, 11, 1,
        recipe: SteelRecipes.roll.id, mode: MachineMode.assisted);
    steel.add(EntityKind.arm, 16, 2);
    steel.add(EntityKind.machine, 17, 2,
        recipe: SteelRecipes.packSteel.id, mode: MachineMode.assisted);
    steel.add(EntityKind.arm, 20, 2);
    steel.add(EntityKind.belt, 21, 2);
    steel.add(EntityKind.shippingDock, 22, 2);
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
