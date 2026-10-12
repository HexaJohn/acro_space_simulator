// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// The docks are the floor's only contact with the colony's stock (§3
/// "Coupling"), so they must conserve goods exactly: a receiving dock never
/// takes what it cannot set down (the colony's ore stays in the colony), a
/// partial grant is carried as part-payment rather than rounded away, and a
/// shipping dock keeps what a full colony refuses — the floor backs up
/// instead of destroying goods.
void main() {
  test('receiving takes only what it can place', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    final chest = l.add(EntityKind.chest, 2, 0);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(4, 2));
    final port = StockColonyPort(stock: {'ore': 1000});

    floor.step(100, port);
    expect(floor.contentsOf(chest)['ore'], kChestCapacity);
    expect(port.stock['ore'], 1000 - kChestCapacity,
        reason: 'a full chest in front: the dock stops taking');
    expect(floor.ledger.received['ore'], kChestCapacity);
  });

  test('a short colony part-pays a crate and finishes it later', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'crate:steel');
    final chest = l.add(EntityKind.chest, 2, 0);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(4, 2));
    final port = StockColonyPort(stock: {'steel': 25});

    floor.step(10, port);
    expect(floor.contentsOf(chest)['crate:steel'], 2);
    expect(port.stock['steel'], 0);
    expect(floor.ledger.received['steel'], 25,
        reason: 'the half crate is paid for, not lost');

    port.stock['steel'] = 5;
    floor.step(2, port);
    expect(floor.contentsOf(chest)['crate:steel'], 3);
    expect(port.stock['steel'], 0);
  });

  test('shipping backs up when the colony refuses', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'crate:steel');
    final belts = l.beltRow(2, 5, 0);
    final dock = l.add(EntityKind.shippingDock, 6, 0);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(8, 2));
    final port = CappedGivePort(15);

    floor.step(120, port);
    expect(port.given['steel'], 15,
        reason: 'one crate and half the next fit the warehouse');
    expect(floor.contentsOf(dock)['crate:steel'], kShippingBufferItems,
        reason: 'the refused crates wait in the dock');
    final taken = port.taken['steel']!;
    floor.step(60, port);
    expect(port.taken['steel'], taken, reason: 'the jam reaches receiving');

    var onFloor = floor.contentsOf(dock)['crate:steel']!;
    for (final b in belts) {
      onFloor += floor.contentsOf(b)['crate:steel'] ?? 0;
    }
    // Conservation: taken = 10 per crate still here + what the colony got,
    // with the front crate's accepted half counted in both.
    expect(taken, onFloor * 10 + 15 - 5);
    expect(floor.ledger.shipped['steel'], 15);
  });
}
