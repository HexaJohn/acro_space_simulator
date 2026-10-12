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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling_dispatch.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// A worker with a load never freezes and never loses it (§3 "Material
/// handling"): walled off from his target he takes it to the nearest store
/// he can reach, or sets it down where he stands for someone to collect.
/// Idle workers go back to the muster spot and stand on a tile, not
/// between two — what the editor draws is where they really are.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// Steel dock → chest at the west wall; a hand-fed packer at (9, 2).
  (FactoryFloor, int dock, int chest, int packer) floor(
      {bool staging = false}) {
    final l = Lay();
    final dock = l.add(EntityKind.receivingDock, 0, 0, item: 'steel');
    final chest = l.add(EntityKind.chest, 2, 0);
    final packer = l.add(EntityKind.machine, 9, 2,
        recipe: SteelRecipes.packSteel.id, mode: MachineMode.manual);
    if (staging) l.add(EntityKind.staging, 0, 6, span: (2, 2));
    return (
      FactoryFloor.fromBlueprint(l.blueprint(14, 9, walkers: 1)),
      dock,
      chest,
      packer
    );
  }

  void stepUntilCarrying(FactoryFloor f, FactoryColonyPort port) {
    for (var i = 0; i < 4 * 60; i++) {
      f.step(0.25, port);
      if (f.handlers.single.state == HandlerState.carrying) return;
    }
    fail('the worker never picked anything up');
  }

  /// Walls the packer (3x2 at (9, 2)) in with belts that carry nothing.
  void wallInPacker(FactoryFloor f) {
    for (var y = 1; y <= 4; y++) {
      for (var x = 8; x <= 12; x++) {
        if (x > 8 && x < 12 && y > 1 && y < 4) continue;
        expect(f.place(Placement(id: 0, kind: EntityKind.belt,
            pos: TilePos(x, y))).ok, isTrue);
      }
    }
  }

  test('walled off, a load goes to the nearest reachable store', () {
    final (f, _, chest, _) = floor();
    final port = InfiniteColonyPort();
    stepUntilCarrying(f, port);
    wallInPacker(f);
    final storedBefore = f.contentsOf(chest)['steel'] ?? 0;
    for (var i = 0; i < 4 * 30; i++) {
      f.step(0.25, port);
      if (f.handlers.single.state != HandlerState.carrying) break;
    }
    expect(f.handlers.single.state, isNot(HandlerState.carrying),
        reason: 'not stuck holding it forever');
    expect(f.contentsOf(chest)['steel'] ?? 0, greaterThan(storedBefore - 1),
        reason: 'the load went back into the chest');
    expect(conservationError(f), isEmpty);
  });

  test('with nowhere to take it, the load is set down, not lost', () {
    final (f, dock, chest, _) = floor();
    final port = InfiniteColonyPort();
    stepUntilCarrying(f, port);
    expect(f.remove(dock).ok, isTrue);
    expect(f.remove(chest).ok, isTrue);
    wallInPacker(f);
    f.step(30, port);
    final h = f.handlers.single;
    expect(h.state, HandlerState.idle);
    expect(h.carrying, isNull);
    final piled = f.floorPiles.values
        .fold<int>(0, (a, m) => a + (m['steel'] ?? 0));
    expect(piled, f.ledger.received['steel']!.toInt(),
        reason: 'every steel the dock took is on the floor, none packed');
    expect(conservationError(f), isEmpty);
  });

  test('idle workers walk back to the muster spot, onto a whole tile', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'steel');
    l.add(EntityKind.chest, 2, 0);
    l.add(EntityKind.machine, 9, 2,
        recipe: SteelRecipes.packSteel.id, mode: MachineMode.manual);
    l.add(EntityKind.staging, 0, 6, span: (2, 2));
    final f = FactoryFloor.fromBlueprint(l.blueprint(14, 9, walkers: 1));
    final port = StockColonyPort(stock: {'steel': 3});
    f.step(240, port);
    expect(f.ledger.received['steel'], 3);
    final h = f.handlers.single;
    expect(h.state, HandlerState.idle);
    expect((h.x, h.y), (0.0, 6.0),
        reason: 'all steel delivered, the worker is back at staging');
  });

  test('going idle mid-step lands on a whole tile', () {
    final far = FloorHandler(
        id: 1, kind: HandlerKind.onFoot, at: const TilePos(2, 2))
      ..next = const TilePos(3, 2)
      ..prog = 0.6
      ..state = HandlerState.toPickup;
    far.goIdle();
    expect((far.at, far.next, far.prog), (const TilePos(3, 2), null, 0.0));
    final near = FloorHandler(
        id: 2, kind: HandlerKind.onFoot, at: const TilePos(2, 2))
      ..next = const TilePos(3, 2)
      ..prog = 0.2;
    near.goIdle();
    expect((near.at, near.next, near.prog), (const TilePos(2, 2), null, 0.0));
  });
}
