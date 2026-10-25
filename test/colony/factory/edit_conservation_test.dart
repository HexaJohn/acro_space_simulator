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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// The editor edits a LIVE floor (§3, phase 2), so an edit must never
/// destroy goods: a load in a worker's hands is in his hands, not at the
/// station it came from; what a removed station held is set down beside
/// it; a fired worker puts his load down first. Conservation is the one
/// invariant that makes a floor's ledger — and so its P&L — trustworthy.
void main() {
  setUpAll(ensureFactoryCatalog);

  const kPortMillHall = HallSize(28, 10);
  const kPortMillWalkers = 3;

  /// A compact port-correct steel line (the Steel Mill template's chain on
  /// a 28 × 10 hall), laid here so this test doesn't hang on the template's
  /// layout. Every machine faces east (ports per `station_ports.dart`):
  /// ore belts into the smelter's input port; pig iron leaves its front
  /// port by belt into the furnace; its slag port belts round into the tube
  /// press. The crane carries billets furnace → mill between their hand
  /// ports in one bay; steel belts mill → packer; the forklift clears steel
  /// crates from the packer's hand port (worked from the aisle) to the
  /// dock; walkers clear the press's tubes from its hand port to shipping.
  FloorBlueprint portMill() {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 3, item: 'ore');
    l.beltRow(2, 3, 3); // → smelter input (4, 3)
    l.add(EntityKind.machine, 4, 2, recipe: SteelRecipes.smelt.id);
    l.beltRow(8, 9, 3); // pig iron (7, 3) → furnace input (10, 3)
    l.add(EntityKind.machine, 10, 2,
        recipe: SteelRecipes.cast.id, mode: MachineMode.assisted);
    l.add(EntityKind.machine, 15, 2,
        recipe: SteelRecipes.roll.id, mode: MachineMode.assisted);
    // Hand ports (11, 2) and (17, 2) and their outside tiles under the hook.
    l.add(EntityKind.craneBay, 10, 1, span: (10, 4));
    l.add(EntityKind.belt, 20, 3); // steel (19, 3) → packer input (21, 3)
    l.add(EntityKind.machine, 21, 2, recipe: SteelRecipes.packSteel.id);
    // The packer's hand port (22, 2) is worked from (22, 1) on the aisle.
    l.add(EntityKind.aisle, 20, 0, span: (8, 2));
    l.add(EntityKind.chargingBay, 24, 2);
    l.add(EntityKind.shippingDock, 26, 2);
    // Slag (6, 5) → north, then east into the press input (8, 7).
    l.add(EntityKind.belt, 6, 6, dir: Dir4.north);
    l.beltRow(6, 7, 7);
    l.add(EntityKind.machine, 8, 6, recipe: SteelRecipes.tube.id);
    l.add(EntityKind.shippingDock, 12, 6); // tubes, walked from (9, 5)
    return FloorBlueprint(
      name: 'Port Mill',
      hall: kPortMillHall,
      placements: l.out,
      roster: {
        HandlerKind.onFoot: kPortMillWalkers,
        HandlerKind.forklift: 1,
        HandlerKind.crane: 1,
      },
    );
  }


  /// Steps [portMill] until some walker is carrying (tubes, from the press),
  /// and returns his id and the placement his load came from.
  (FactoryFloor, InfiniteColonyPort, int, int) carryingMill() {
    final f = FactoryFloor.fromBlueprint(portMill());
    final port = InfiniteColonyPort();
    f.step(120, port);
    for (var i = 0; i < 4 * 120; i++) {
      for (final e in handlerJobs(f).entries) {
        if (e.value.$1 == 'carrying') {
          return (f, port, e.key, (e.value.$2[2] as num).toInt());
        }
      }
      f.step(0.25, port);
    }
    fail('no walker ever carried anything');
  }

  test('removing the source of a load in hand keeps the load', () {
    final (f, port, walker, source) = carryingMill();
    final before = f.itemsOnFloor;
    expect(f.remove(source).ok, isTrue);
    expect(f.itemsOnFloor, before,
        reason: 'the press and what it held are gone, nothing it made is');
    expect(conservationError(f), isEmpty);
    final h = f.handlers.firstWhere((h) => h.id == walker);
    expect(h.carrying, 'tubes', reason: 'still in his hands');
    expect(h.state, HandlerState.carrying);
    f.step(60, port);
    expect(conservationError(f), isEmpty);
  });

  test('removing the target of a load in hand re-targets it to a store', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'steel');
    final chest = l.add(EntityKind.chest, 2, 0);
    final packer = l.add(EntityKind.machine, 9, 2,
        recipe: SteelRecipes.packSteel.id, mode: MachineMode.manual);
    final f = FactoryFloor.fromBlueprint(l.blueprint(14, 9, walkers: 1));
    final port = StockColonyPort(stock: {'steel': 4});
    for (var i = 0; i < 4 * 60; i++) {
      f.step(0.25, port);
      if (f.handlers.single.state == HandlerState.carrying) break;
    }
    final h0 = f.handlers.single;
    expect(h0.state, HandlerState.carrying);
    expect(handlerJobs(f)[h0.id]!.$2[3], packer);
    final carried = h0.carryingCount;
    final before = f.itemsOnFloor;
    expect(f.remove(packer).ok, isTrue);
    expect(f.itemsOnFloor, before);
    expect(conservationError(f), isEmpty);
    final h = f.handlers.single;
    expect(h.state, HandlerState.carrying, reason: 'still in his hands');
    expect(h.carryingCount, carried);
    expect(handlerJobs(f)[h.id]!.$2[3], chest,
        reason: 'the chest has room and he can reach it');
    expect(f.floorPiles, isEmpty, reason: 'not set down');
    f.step(60, port);
    expect(f.handlers.single.state, HandlerState.idle);
    expect(f.floorPiles, isEmpty);
    expect(f.contentsOf(chest)['steel'], 4,
        reason: 'every steel taken is back in the chest');
    expect(conservationError(f), isEmpty);
  });

  test('removing a shipping dock keeps its part-paid units booked', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'crate:steel');
    l.beltRow(2, 5, 0);
    final dock = l.add(EntityKind.shippingDock, 6, 0);
    final f = FactoryFloor.fromBlueprint(l.blueprint(8, 2));
    final port = CappedGivePort(15);
    f.step(120, port);
    expect(f.shippedAhead['steel'], 5, reason: 'half the front crate went');
    expect(conservationError(f), isEmpty);
    expect(f.remove(dock).ok, isTrue);
    expect(conservationError(f), isEmpty,
        reason: 'the part-paid half stays booked as prepaid credit');
    final again = f.place(Placement(
        id: 0, kind: EntityKind.shippingDock, pos: const TilePos(6, 0)));
    expect(again.ok, isTrue);
    port.given['steel'] = 0; // the warehouse makes room for 15 more
    f.step(120, port);
    expect(port.given['steel'], 15);
    expect(f.ledger.shipped['steel'], 30);
    expect(conservationError(f), isEmpty,
        reason: 'the next crate used the prepaid half, not a fresh 10');
    expect(f.shippedAhead['steel'] ?? 0, 0,
        reason: '30 shipped is exactly three crates');
  });

  test('removing a receiving dock keeps its part-paid units owed', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'crate:steel');
    final chest = l.add(EntityKind.chest, 2, 0);
    final f = FactoryFloor.fromBlueprint(l.blueprint(4, 2));
    final port = StockColonyPort(stock: {'steel': 25});
    f.step(10, port);
    expect(f.contentsOf(chest)['crate:steel'], 2);
    expect(f.receivedAhead['steel'], 5);
    final dock = f.blueprint.placements
        .firstWhere((p) => p.kind == EntityKind.receivingDock)
        .id;
    expect(f.remove(dock).ok, isTrue);
    expect(conservationError(f), isEmpty,
        reason: 'the 5 units taken are owed to the floor, not lost');
    expect(f.place(Placement(
            id: 0,
            kind: EntityKind.receivingDock,
            pos: const TilePos(0, 0),
            item: 'crate:steel'))
        .ok, isTrue);
    port.stock['steel'] = 5;
    f.step(10, port);
    expect(f.contentsOf(chest)['crate:steel'], 3,
        reason: 'the owed half plus 5 more make the third crate');
    expect(port.stock['steel'], 0);
    expect(f.ledger.received['steel'], 30);
    expect(conservationError(f), isEmpty);
  });

  test('a partial-grant port conserves through dock edits and a save', () {
    final f = FactoryFloor.fromBlueprint(portMill());
    final port = CappedGivePort(40);
    f.step(240, port);
    final docks = [
      for (final p in f.blueprint.placements)
        if (p.kind == EntityKind.shippingDock ||
            p.kind == EntityKind.receivingDock)
          p,
    ];
    expect(docks, isNotEmpty);
    for (final d in docks) {
      expect(f.remove(d.id).ok, isTrue);
      expect(conservationError(f), isEmpty, reason: 'removed ${d.id}');
      f.step(5, port);
      expect(f.place(d.copyWith(id: 0)).ok, isTrue);
      expect(conservationError(f), isEmpty, reason: 'replaced ${d.id}');
    }
    final g = FactoryFloor.fromJson(f.toJson());
    expect(g.shippedAhead, f.shippedAhead);
    expect(g.receivedAhead, f.receivedAhead);
    port.given.clear();
    g.step(120, port);
    expect(conservationError(g), isEmpty);
  });

  test('re-recipeing the source of a load in hand keeps the load', () {
    final (f, _, walker, source) = carryingMill();
    final before = f.itemsOnFloor;
    expect(f.setRecipe(source, SteelRecipes.packTubes.id).ok, isTrue);
    expect(f.itemsOnFloor, before);
    expect(f.handlers.firstWhere((h) => h.id == walker).carrying, 'tubes');
    expect(f.floorPiles, isNotEmpty,
        reason: "the press's old slag and tubes were set down beside it");
  });

  test('firing every walker sets their loads down first', () {
    final (f, port, _, _) = carryingMill();
    final before = f.itemsOnFloor;
    expect(f.hire(HandlerKind.onFoot, -kPortMillWalkers).ok, isTrue);
    expect(f.handlers.where((h) => h.kind == HandlerKind.onFoot), isEmpty);
    expect(f.itemsOnFloor, before);
    expect(f.floorPiles.values.expand((m) => m.keys), contains('tubes'));
    f.step(30, port);
    expect(conservationError(f), isEmpty);
  });

  test('firing prefers an empty-handed walker', () {
    final (f, _, walker, _) = carryingMill();
    expect(f.hire(HandlerKind.onFoot, -1).ok, isTrue);
    expect(f.handlers.map((h) => h.id), contains(walker));
  });

  test('conservation holds through a long run of arbitrary edits', () {
    final f = FactoryFloor.fromBlueprint(portMill());
    final port = InfiniteColonyPort();
    // A fixed LCG: arbitrary, but the same every run.
    var seed = 12345;
    int next(int n) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return (seed >> 8) % n;
    }

    final recipes = SteelRecipes.all;
    var applied = 0;
    f.step(120, port);
    for (var round = 0; round < 160; round++) {
      final ids = [for (final p in f.blueprint.placements) p.id]..sort();
      final machines = [
        for (final p in f.blueprint.placements)
          if (p.kind == EntityKind.machine) p.id,
      ]..sort();
      final EditResult r;
      switch (next(6)) {
        case 0:
          r = f.remove(ids[next(ids.length)]);
        case 1:
          r = machines.isEmpty
              ? f.rotate(ids[next(ids.length)])
              : f.setRecipe(machines[next(machines.length)],
                  recipes[next(recipes.length)].id);
        case 2:
          r = f.rotate(ids[next(ids.length)]);
        case 3:
          r = f.hire(HandlerKind.onFoot, next(5) - 2);
        case 4:
          r = f.place(Placement(
              id: 0,
              kind: EntityKind.chest,
              pos: TilePos(next(kPortMillHall.w), next(kPortMillHall.h))));
        default:
          r = f.place(Placement(
              id: 0,
              kind: EntityKind.belt,
              dir: Dir4.values[next(4)],
              pos: TilePos(next(kPortMillHall.w), next(kPortMillHall.h))));
      }
      if (r.ok) applied++;
      expect(conservationError(f), isEmpty, reason: 'after edit $round');
      f.step(0.25 * (1 + next(80)), port);
      expect(conservationError(f), isEmpty, reason: 'after step $round');
    }
    expect(applied, greaterThan(80), reason: 'most edits really happened');
    expect(f.ledger.shipped, isNotEmpty);
  });
}
