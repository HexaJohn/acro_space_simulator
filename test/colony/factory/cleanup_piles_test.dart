// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// §10 item 17: Clear orders, Dispose, and flagged stuck piles. Every test
/// ends on the conservation books, scrap included.
FactoryFloor _withPile({bool chest = true, bool ship = false}) {
  final l = Lay();
  final dock = l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
  final tmp = l.add(EntityKind.chest, 2, 0);
  if (chest) {
    l.add(EntityKind.chest, 8, 3);
    l.add(EntityKind.chest, 6, 3); // room for the whole pile
  }
  if (ship) l.add(EntityKind.shippingDock, 8, 0);
  final f = FactoryFloor.fromBlueprint(
      l.blueprint(10, 5, crew: {HandlerKind.palletJack: 1}));
  f.step(10, InfiniteColonyPort());
  expect(f.remove(tmp).ok, isTrue);
  expect(f.remove(dock).ok, isTrue); // no more ore arriving
  expect(f.piles, isNotEmpty);
  return f;
}

void main() {
  test('a Clear order hauls every pile in the box to the chest', () {
    final f = _withPile();
    final tile = f.piles.first.tile;
    expect(f.clearPiles(TileRect(tile.x, tile.y, 1, 1)), 1);
    expect(f.clearPiles(const TileRect(9, 4, 1, 1)), 0);
    final port = InfiniteColonyPort();
    f.step(1, port);
    expect(
        f.pendingRequests +
            f.handlers.where((h) => h.carryingCount > 0).length,
        greaterThan(0));
    f.step(300, port);
    expect(f.piles.where((p) => p.tile == tile), isEmpty);
    expect(conservationError(f), isEmpty);
  });

  test('Dispose ships a pile out through the shipping dock', () {
    final f = _withPile(ship: true);
    final tile = f.piles.first.tile;
    expect(f.disposePile(tile), isTrue);
    final port = InfiniteColonyPort();
    f.step(400, port);
    expect(f.piles.where((p) => p.tile == tile), isEmpty);
    expect(f.ledger.shipped['ore'], greaterThan(0));
    expect(conservationError(f), isEmpty);
  });

  test('scrap destroys the pile and books it in the ledger', () {
    final f = _withPile(chest: false);
    final tile = f.piles.first.tile;
    expect(f.disposePile(tile, scrap: true), isTrue);
    expect(f.piles, isEmpty);
    expect(f.ledger.scrapped['ore'], greaterThan(0));
    expect(f.disposePile(tile, scrap: true), isFalse);
    expect(conservationError(f), isEmpty);
    final back = FactoryFloor.fromJson(f.toJson());
    expect(back.ledger.scrapped, f.ledger.scrapped);
  });

  test('piles nothing can take are flagged', () {
    final f = _withPile(chest: false);
    f.step(1, InfiniteColonyPort());
    expect(f.stuckPiles, {for (final p in f.piles) p.tile});
    expect(f.stuckPiles, isNotEmpty);
  });

  test('a disposed pile with no shipping dock is flagged, not chested', () {
    final f = _withPile();
    final tile = f.piles.first.tile;
    f.disposePile(tile);
    f.step(5, InfiniteColonyPort());
    expect(f.stuckPiles, contains(tile));
  });
}
