// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Belts are the floor's arteries (docs/plans/factory-floors.md §3): items
/// must ride at the belt's speed, arrive at the dock in front, and — when
/// the far end is blocked — queue at real spacing and stop the dock feeding
/// them. Back-pressure is what makes a bad layout visibly slow instead of
/// silently losing goods.
void main() {
  test('items ride the belt at belt speed into the shipping dock', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    l.beltRow(2, 13, 1); // 12 tiles: 8 s at 1.5 tiles/s
    l.add(EntityKind.shippingDock, 14, 1);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(16, 3));
    final port = InfiniteColonyPort();

    floor.step(8.5, port);
    expect(port.given['ore'] ?? 0, 0,
        reason: 'the first item left the dock at 1 s and needs 8 s to ride');
    floor.step(2, port);
    expect(port.given['ore'], greaterThan(0));

    final r = measure(floor, port, warmupS: 20, windowS: 200);
    expect(r.outPerS['ore'], closeTo(kReceivingItemsPerS, 1e-9),
        reason: 'a free-running belt passes everything its dock emits');
  });

  test('a blocked belt queues at its spacing and stops the dock', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    final belts = l.beltRow(2, 5, 1); // dead end: nothing in front of (5, 1)
    final floor = FactoryFloor.fromBlueprint(l.blueprint(10, 3));
    final port = InfiniteColonyPort();

    floor.step(120, port);
    final taken = port.taken['ore']!;
    var onBelt = 0;
    for (final id in belts) {
      onBelt += floor.contentsOf(id)['ore'] ?? 0;
    }
    expect(onBelt, taken.toInt(),
        reason: 'every unit taken from the colony is on the floor');
    final perTile = (1 / kBeltGap).round();
    expect(onBelt, inInclusiveRange(perTile * belts.length,
        perTile * belts.length + 1));

    floor.step(60, port);
    expect(port.taken['ore'], taken, reason: 'a jammed dock takes nothing');

    // Items never overlap: along the run, positions are at least a gap apart.
    final xs = [
      for (final v in floor.beltItems) v.tile.x + v.progress,
    ]..sort();
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i] - xs[i - 1], greaterThanOrEqualTo(kBeltGap - 1e-9));
    }
  });
}
