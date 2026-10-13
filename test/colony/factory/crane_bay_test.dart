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

/// Only a crane lifts heavy loads (§3 "Load classes"), and a crane bay
/// FIXES where heavy stations go: the crane runs over everything inside
/// its bay — machines and belts included, it ignores floor traffic — but
/// works only what lies under or beside that bay. Billets are the Steel
/// Mill's heavy item, so this is the template's heavy line in miniature.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// A billet dock fills a chest; a belt wall (x 3-4) stands between it
  /// and a hand-fed rolling mill whose bars go by arm to shipping. [bays]
  /// lays the crane bays; [cranes] cranes.
  (FactoryFloor, int) billetFloor(List<(int, int, int, int)> bays, int cranes) {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'steelBillet');
    l.add(EntityKind.chest, 2, 1);
    for (var y = 0; y <= 2; y++) {
      l.add(EntityKind.belt, 3, y, dir: Dir4.north);
      l.add(EntityKind.belt, 4, y, dir: Dir4.north);
    }
    final mill = l.add(
      EntityKind.machine,
      5,
      0,
      recipe: SteelRecipes.roll.id,
      mode: MachineMode.assisted,
    );
    l.add(EntityKind.arm, 10, 1);
    l.add(EntityKind.shippingDock, 11, 1);
    for (final (x, y, w, h) in bays) {
      l.add(EntityKind.craneBay, x, y, span: (w, h));
    }
    return (
      FactoryFloor.fromBlueprint(
        l.blueprint(13, 4, crew: {HandlerKind.crane: cranes}),
      ),
      mill,
    );
  }

  test('a crane carries billets over the belts within its bay', () {
    final (f, _) = billetFloor([(2, 0, 8, 3)], 1);
    final port = InfiniteColonyPort();
    var overBelts = false;
    for (var i = 0; i < 4 * 120; i++) {
      f.step(0.25, port);
      final c = f.handlers.single;
      if (c.carrying == 'steelBillet' && c.x >= 3 && c.x <= 4) {
        overBelts = true;
      }
      expect(c.x, inInclusiveRange(2, 9), reason: 'never leaves its bay');
    }
    expect(
      overBelts,
      isTrue,
      reason: 'the crane passes over the belt wall a walker could not',
    );
    expect(
      f.craftNet['steel'] ?? 0,
      greaterThan(0),
      reason: 'the mill rolled the billets it was brought',
    );
    expect(f.ledger.shipped['steel'], greaterThan(0));
    expect(f.ledger.equipmentSeconds[HandlerKind.crane], greaterThan(0));
    expect(conservationError(f), isEmpty);
  });

  test('a heavy trip across two bays waits; so does a bay with no crane', () {
    // Chest and mill each under their own bay, one crane each: neither
    // bay covers both ends, so the billet waits.
    final (f, mill) = billetFloor([(1, 0, 3, 3), (5, 0, 5, 3)], 2);
    final port = InfiniteColonyPort();
    f.step(60, port);
    expect(f.pendingRequests, greaterThan(0));
    expect(f.contentsOf(mill)['steelBillet'] ?? 0, 0);
    for (final c in f.handlers) {
      expect(c.state, HandlerState.idle);
    }

    // One bay over both ends, but the floor's only crane is bound to the
    // first bay by id (a useless one): the covering bay is inert.
    final (g, mill2) = billetFloor([(0, 3, 2, 1), (2, 0, 8, 3)], 1);
    g.step(60, port);
    expect(
      g.contentsOf(mill2)['steelBillet'] ?? 0,
      0,
      reason: 'crane 1 runs in bay 1; bay 2 has no crane',
    );
    expect(g.handlers.single.y, 3, reason: 'it stays in its own bay');
    expect(conservationError(g), isEmpty);
  });
}
