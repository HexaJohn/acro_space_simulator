// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Load classes are enforced end to end (§3 "Load classes"): a pallet of
/// ore that sat waiting while only walkers were on the floor must be moved
/// once a pallet jack is — and by the jack, never by a walker. The jack is
/// the cheapest unlock a young colony gets, so this is the first vehicle a
/// player will meet.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// Ore dock → chest; a hand-fed smelter beside it ([jacks] jacks plus two
  /// walkers).
  (FactoryFloor, int) oreFloor(int jacks) {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    l.add(EntityKind.chest, 2, 0);
    final smelter = l.add(
      EntityKind.machine,
      4,
      2,
      recipe: SteelRecipes.smelt.id,
      mode: MachineMode.assisted,
    );
    return (
      FactoryFloor.fromBlueprint(
        l.blueprint(
          10,
          8,
          walkers: 2,
          crew: {if (jacks > 0) HandlerKind.palletJack: jacks},
        ),
      ),
      smelter,
    );
  }

  test('without a jack the ore waits; with one it is moved — by the jack', () {
    final (idle, s0) = oreFloor(0);
    idle.step(60, InfiniteColonyPort());
    expect(idle.statusOf(s0), MachineStatus.starved);
    expect(idle.pendingRequests, greaterThan(0));

    final (f, smelter) = oreFloor(1);
    final port = InfiniteColonyPort();
    var jackCarried = false;
    for (var i = 0; i < 4 * 90; i++) {
      f.step(0.25, port);
      for (final h in f.handlers) {
        if (h.carrying == null) continue;
        expect(
          h.kind,
          HandlerKind.palletJack,
          reason: 'a walker never lifts a pallet, even with a jack around',
        );
        jackCarried = true;
      }
    }
    expect(jackCarried, isTrue);
    expect(f.ledger.received['ore'], greaterThan(0));
    expect(
      f.craftNet['pigIron'] ?? 0,
      greaterThan(0),
      reason: 'the jack fed the smelter and it smelted',
    );
    expect(f.statusOf(smelter), isNot(MachineStatus.unstaffed));
    expect(conservationError(f), isEmpty);
  });
}
