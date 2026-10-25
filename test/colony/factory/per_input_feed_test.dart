// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Feeds are per INPUT, not per machine (§3 "Material handling": belts
/// cover the fixed runs, handlers the rest), and with explicit ports
/// (`station_ports.dart`) that is per PORT: a station with a belt on one
/// input port still asks walkers to bring the other input to its hand port,
/// and a station whose main product leaves by its output-port belt still
/// offers a byproduct with no port belt to handlers at the hand port.
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
    // Assembler 3×3 at (6, 1): input 1 (steel) at (6, 2) fed from (5, 2);
    // output 1 at (8, 2) onto the belt at (9, 2); hand port (8, 1), the
    // walker stands at (8, 0) with the tubes (input 2 has no belt). The
    // tube chest sits on the hand port's side of the steel belt, a short
    // walk along y = 0.
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 2, item: 'steel');
    l.beltRow(2, 5, 2);
    final asm = l.add(EntityKind.machine, 6, 1, recipe: assemble.id);
    l.add(EntityKind.belt, 9, 2);
    l.add(EntityKind.shippingDock, 10, 2);
    l.add(EntityKind.receivingDock, 0, 0, item: 'tubes');
    l.add(EntityKind.chest, 2, 0);
    final f = FactoryFloor.fromBlueprint(l.blueprint(16, 10, walkers: 1));
    final port = InfiniteColonyPort();

    f.step(120, port);
    expect(f.ledger.shipped['test:frame'], greaterThanOrEqualTo(3),
        reason: 'the walker brings tubes while the belt brings steel');
    expect(f.contentsOf(asm)['steel'], greaterThan(0),
        reason: 'the belt keeps the steel side full; tubes are the walk');
    expect(conservationError(f), isEmpty);
  });

  test('a station whose pig iron leaves by belt offers its slag', () {
    // Smelter 4×4 at (4, 3): ore into input 1 at (4, 4) from (3, 4); pig
    // iron out output 1 at (7, 4) onto (8, 4); the slag port (6, 6) has no
    // belt, so slag goes to the hand port (5, 3), handler at (5, 2).
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 4, item: 'ore');
    l.beltRow(2, 3, 4);
    final smelter = l.add(EntityKind.machine, 4, 3, recipe: 'steel:smelt');
    l.beltRow(8, 9, 4);
    l.add(EntityKind.shippingDock, 10, 4);
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

  test('a hand-class byproduct with no port belt is walked to shipping', () {
    // Press 3×3 at (6, 1): steel into (6, 2) from (5, 2); tubes out output
    // 1 at (8, 2) onto (9, 2) to shipping; the offcut port (7, 3) has no
    // belt, so walkers pick offcuts at the hand port (7, 1) from (7, 0).
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 2, item: 'steel');
    l.beltRow(2, 5, 2);
    l.add(EntityKind.machine, 6, 1, recipe: cut.id);
    l.add(EntityKind.belt, 9, 2);
    l.add(EntityKind.shippingDock, 10, 2);
    l.add(EntityKind.shippingDock, 10, 7);
    final f = FactoryFloor.fromBlueprint(l.blueprint(16, 10, walkers: 2));
    final port = InfiniteColonyPort();

    f.step(120, port);
    expect(f.ledger.shipped['test:offcut'], greaterThanOrEqualTo(3),
        reason: 'walkers clear the offcuts the tube belt leaves');
    expect(f.ledger.shipped['tubes'], greaterThanOrEqualTo(3));
    expect(conservationError(f), isEmpty);
  });
}
