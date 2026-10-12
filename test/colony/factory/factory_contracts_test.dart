// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wave 0 contracts (docs/plans/factory-floors.md §6): the shapes every
/// parallel track builds against. These pin the save formats and the
/// footprint/overlap rules, because four tracks read them independently.
void main() {
  FactoryRecipes.register(const FactoryRecipe(
      id: 'test:smelt', label: 'Smelt', station: StationKind.smelter,
      inputs: [ItemQty('ore', 1)], outputs: [ItemQty('pigIron', 1)],
      seconds: 2, powerKw: 50));

  test('a vertical footprint swaps w and h', () {
    const m = Placement(id: 1, kind: EntityKind.machine, pos: TilePos(2, 3),
        recipe: 'test:smelt');
    expect(m.footprint, const TileRect(2, 3, 4, 4));
    const d = Placement(id: 2, kind: EntityKind.receivingDock,
        pos: TilePos(0, 0), dir: Dir4.north);
    expect(d.footprint, const TileRect(0, 0, 1, 2));
    const a = Placement(id: 3, kind: EntityKind.aisle, pos: TilePos(1, 1),
        span: (10, 2), dir: Dir4.north);
    expect(a.footprint, const TileRect(1, 1, 10, 2),
        reason: 'spanned kinds are laid as drawn, never rotated');
  });

  test('validate reports out-of-hall, overlap and unknown recipe', () {
    final bp = FloorBlueprint(name: 't', hall: const HallSize(10, 10),
        placements: [
          const Placement(id: 1, kind: EntityKind.machine,
              pos: TilePos(0, 0), recipe: 'test:smelt'),
          const Placement(id: 2, kind: EntityKind.belt, pos: TilePos(3, 3)),
          const Placement(id: 3, kind: EntityKind.belt, pos: TilePos(10, 0)),
          const Placement(id: 4, kind: EntityKind.machine,
              pos: TilePos(5, 5), recipe: 'nope'),
          const Placement(id: 5, kind: EntityKind.aisle, pos: TilePos(0, 0),
              span: (10, 2)),
        ]);
    final kinds = {
      for (final i in bp.validate()) (i.kind, i.placementId),
    };
    expect(kinds, {
      (BlueprintIssueKind.overlap, 2),
      (BlueprintIssueKind.outOfHall, 3),
      (BlueprintIssueKind.unknownRecipe, 4),
    }, reason: 'an aisle over a machine is a marking, not an overlap');
  });

  test('blueprint and ledger survive a JSON round-trip', () {
    final bp = FloorBlueprint(name: 'Mill', plantType: 'steelmill',
        hall: const HallSize(60, 40), roster: {HandlerKind.onFoot: 6},
        placements: [
          const Placement(id: 1, kind: EntityKind.machine,
              pos: TilePos(4, 4), dir: Dir4.south, recipe: 'test:smelt',
              mode: MachineMode.manual),
          const Placement(id: 2, kind: EntityKind.receivingDock,
              pos: TilePos(0, 0), item: 'ore'),
          const Placement(id: 3, kind: EntityKind.craneBay,
              pos: TilePos(10, 10), span: (20, 8)),
        ]);
    final back = FloorBlueprint.fromJson(bp.toJson());
    expect(back.toJson(), bp.toJson());
    expect(back.jobDemand, 2 + 6, reason: 'manual crew 2 + six walkers');

    final l = FactoryLedger()
      ..seconds = 10
      ..energyKJ = 500
      ..itemMetres = 42;
    l.addWork(WorkRole.handler, 60);
    l.addShipped('steel', 3);
    l.addEquipment(HandlerKind.forklift, 9);
    expect(FactoryLedger.fromJson(l.toJson()).toJson(), l.toJson());
  });

  test('a hall fits an envelope by metres', () {
    final bp = FloorBlueprint(name: 't', hall: const HallSize(50, 30));
    expect(bp.fitsEnvelope(const SiteEnvelope(0, 0, 100, 60)), isTrue);
    expect(bp.fitsEnvelope(const SiteEnvelope(0, 0, 99, 60)), isFalse);
    expect(HallSize.fitting(101, 61), const HallSize(50, 30));
  });

  test('stock port clips take to stock and give to cap', () {
    final p = StockColonyPort(stock: {'ore': 3}, cap: 5);
    expect(p.take('ore', 10), 3);
    expect(p.give('steel', 8), 5);
    expect(p.give('steel', 1), 0);
    expect(FactoryItems.crateSteel.commodity, 'steel');
    expect(FactoryItems.pigIron.commodity, 'pigIron',
        reason: 'an intermediate counts as its own commodity at a dock');
  });

  test('ownership round-trips', () {
    expect(Ownership.fromJson(const Ownership.private('acme').toJson()).firmId,
        'acme');
    expect(Ownership.fromJson(const Ownership.state().toJson()).isState, isTrue);
  });
}
