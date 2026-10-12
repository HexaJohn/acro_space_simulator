// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Feeds are per INPUT, not per machine (§3 "Material handling": belts and
/// arms cover the fixed runs, handlers the rest). A station with one input
/// on a belt still asks walkers for the other, and a station whose only
/// output arm is filtered still offers its other outputs to handlers.
void main() {
  const offcut = FactoryItem(
      id: 'test:offcut', label: 'Offcut', loadClass: LoadClass.hand,
      kgPerUnit: 5);
  const frame = FactoryItem(
      id: 'test:frame', label: 'Frame', loadClass: LoadClass.hand,
      kgPerUnit: 20);
  const assemble = FactoryRecipe(
      id: 'test:assemble', label: 'Assemble Frame',
      station: StationKind.assembler,
      inputs: [ItemQty('steel', 1), ItemQty('tubes', 1)],
      outputs: [ItemQty('test:frame', 1)], seconds: 1, powerKw: 1);
  const cut = FactoryRecipe(
      id: 'test:cut', label: 'Cut Tube', station: StationKind.press,
      inputs: [ItemQty('steel', 1)],
      outputs: [ItemQty('tubes', 1), ItemQty('test:offcut', 1)],
      seconds: 1, powerKw: 1);

  setUpAll(() {
    ensureFactoryCatalog();
    FactoryItems.register(offcut);
    FactoryItems.register(frame);
    FactoryRecipes.register(assemble);
    FactoryRecipes.register(cut);
  });

  test('a belt-fed input and a hand-carried input both reach the station',
      () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'steel');
    l.beltRow(2, 5, 1);
    final asm = l.add(EntityKind.machine, 6, 0, recipe: assemble.id);
    l.add(EntityKind.arm, 9, 1);
    l.add(EntityKind.shippingDock, 10, 1);
    l.add(EntityKind.receivingDock, 0, 6, item: 'tubes');
    l.add(EntityKind.chest, 2, 6);
    final f = FactoryFloor.fromBlueprint(l.blueprint(16, 10, walkers: 1));
    final port = InfiniteColonyPort();

    f.step(120, port);
    expect(f.ledger.shipped['test:frame'], greaterThanOrEqualTo(3),
        reason: 'the walker brings tubes while the belt brings steel');
    expect(f.contentsOf(asm)['steel'], greaterThan(0),
        reason: 'the belt keeps the steel side full; tubes are the walk');
    expect(conservationError(f), isEmpty);
  });

  test('a station whose only arm takes pig iron offers its slag', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    l.beltRow(2, 5, 1);
    l.add(EntityKind.arm, 5, 2, dir: Dir4.north);
    final smelter = l.add(EntityKind.machine, 4, 3, recipe: 'steel:smelt');
    l.add(EntityKind.arm, 8, 4, item: 'pigIron');
    l.add(EntityKind.chest, 9, 4);
    l.add(EntityKind.shippingDock, 9, 9);
    final f = FactoryFloor.fromBlueprint(l.blueprint(14, 12, walkers: 1));
    f.step(60, InfiniteColonyPort());

    final queued = [
      for (final r in (f.toJson()['q'] as List? ?? const []))
        (r as List)[0] as String,
    ];
    expect(queued, contains('slag'),
        reason: 'slag is offered for a handler (a jack: it is a pallet '
            'load) instead of never being asked about');
    expect(f.statusOf(smelter), MachineStatus.blocked,
        reason: 'walkers cannot lift slag: the queue is the "hire a jack" '
            'signal, and the station waits on it');
  });

  test('a hand-class byproduct no arm takes is walked to shipping', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'steel');
    l.beltRow(2, 5, 1);
    l.add(EntityKind.machine, 6, 0, recipe: cut.id);
    l.add(EntityKind.arm, 9, 1, item: 'tubes');
    l.add(EntityKind.shippingDock, 10, 1);
    l.add(EntityKind.shippingDock, 10, 7);
    final f = FactoryFloor.fromBlueprint(l.blueprint(16, 10, walkers: 2));
    final port = InfiniteColonyPort();

    f.step(120, port);
    expect(f.ledger.shipped['test:offcut'], greaterThanOrEqualTo(3),
        reason: 'walkers clear the offcuts the tube arm leaves');
    expect(f.ledger.shipped['tubes'], greaterThanOrEqualTo(3));
    expect(conservationError(f), isEmpty);
  });
}
