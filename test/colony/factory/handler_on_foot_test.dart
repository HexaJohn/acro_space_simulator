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
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Workers on foot are the plan's first handlers (§3 "Material
/// handling"): they fetch what a hand-fed station needs, walk the floor
/// around whatever stands on it, cross belts only where a crossing is laid,
/// and never pick up a load heavier than hand class however close it is.
/// Space is the cost of handling, so these rules are the design puzzle.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// A steel dock fills a chest; a hand-fed packer across the hall needs
  /// the steel. [wall] lays the obstacle between them in column 6.
  (FactoryFloor, int) carryFloor(void Function(Lay l) wall) {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'steel');
    l.add(EntityKind.chest, 2, 0);
    wall(l);
    final packer = l.add(EntityKind.machine, 9, 2,
        recipe: SteelRecipes.packSteel.id, mode: MachineMode.manual);
    return (FactoryFloor.fromBlueprint(l.blueprint(14, 9, walkers: 1)), packer);
  }

  /// Tiles a handler view touches (two while it is between tiles).
  Iterable<TilePos> touched(HandlerView h) sync* {
    final xs = {h.x.floor(), h.x.ceil()}, ys = {h.y.floor(), h.y.ceil()};
    for (final x in xs) {
      for (final y in ys) {
        yield TilePos(x, y);
      }
    }
  }

  test('a worker carries steel from the chest around a wall', () {
    final (floor, packer) = carryFloor((l) {
      for (var y = 0; y <= 6; y++) {
        l.add(EntityKind.chest, 6, y);
      }
    });
    final port = InfiniteColonyPort();
    final solid = <TilePos>{
      for (final p in floor.blueprint.placements)
        if (p.kind != EntityKind.staging) ...p.footprint.tiles,
    };
    var crossedAt = <int>{};
    for (var i = 0; i < 4 * 120; i++) {
      floor.step(0.25, port);
      final h = floor.handlers.single;
      for (final t in touched(h)) {
        expect(solid.contains(t), isFalse, reason: 'stood on $t');
      }
      if (h.x > 5 && h.x < 7) crossedAt.add(h.y.round());
    }
    expect(floor.contentsOf(packer)['steel'], greaterThan(0));
    expect(crossedAt, isNotEmpty);
    expect(crossedAt.every((y) => y >= 7), isTrue,
        reason: 'the only way past the wall is round its end: $crossedAt');
    expect(floor.ledger.itemMetres, greaterThan(0));
  });

  test('a worker crosses a belt only at the crossing', () {
    final (floor, packer) = carryFloor((l) {
      for (var y = 0; y <= 8; y++) {
        l.add(y == 4 ? EntityKind.crossing : EntityKind.belt, 6, y,
            dir: Dir4.north);
      }
    });
    final port = InfiniteColonyPort();
    final ys = <double>{};
    for (var i = 0; i < 4 * 120; i++) {
      floor.step(0.25, port);
      final h = floor.handlers.single;
      if (h.x > 5 && h.x < 7) ys.add(h.y);
    }
    expect(floor.contentsOf(packer)['steel'], greaterThan(0));
    expect(ys, {4.0}, reason: 'belt column 6 is crossed at (6, 4) only');
  });

  test('a truck is unloaded into staging and workers take it from there', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'tubes');
    final staging = l.add(EntityKind.staging, 2, 0, span: (3, 2));
    final packer = l.add(EntityKind.machine, 8, 4,
        recipe: SteelRecipes.packTubes.id, mode: MachineMode.manual);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(14, 9, walkers: 2));
    final port = InfiniteColonyPort();

    floor.step(240, port);
    final staged = floor.contentsOf(staging)['tubes'] ?? 0;
    expect(staged, lessThanOrEqualTo(3 * 2 * kStagingItemsPerTile));
    final packed = floor.contentsOf(packer)['crate:tubes'] ?? 0;
    expect(packed, greaterThan(0),
        reason: 'walkers fed the packer from the staging area');
    // A running (or finished but blocked) craft holds its ten tubes.
    final inCraft = const {MachineStatus.working, MachineStatus.blocked}
            .contains(floor.statusOf(packer))
        ? 10
        : 0;
    expect(floor.ledger.received['tubes'],
        staged + (floor.contentsOf(packer)['tubes'] ?? 0) + 10 * packed +
            inCraft +
            [for (final h in floor.handlers) h.carryingCount]
                .fold<int>(0, (a, b) => a + b),
        reason: 'every tube is staged, in the packer, packed or in a hand');
  });

  test('a worker never lifts a pallet, however close', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    l.add(EntityKind.chest, 2, 0);
    final smelter = l.add(EntityKind.machine, 4, 2,
        recipe: SteelRecipes.smelt.id, mode: MachineMode.assisted);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(10, 8, walkers: 2));
    final port = InfiniteColonyPort();

    floor.step(60, port);
    expect(floor.pendingRequests, greaterThan(0),
        reason: 'the smelter asks; the queue shows the need for a jack');
    for (final h in floor.handlers) {
      expect(h.state, HandlerState.idle);
      expect(h.carrying, isNull);
    }
    expect(floor.statusOf(smelter), MachineStatus.starved);
    expect(floor.ledger.itemMetres, 0);
  });
}
