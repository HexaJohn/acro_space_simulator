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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// The editor edits a LIVE floor (§3, phase 2), so an edit must never
/// destroy goods: a load in a worker's hands is in his hands, not at the
/// station it came from; what a removed station held is set down beside
/// it; a fired worker puts his load down first. Conservation is the one
/// invariant that makes a floor's ledger — and so its P&L — trustworthy.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// Steps the template until some walker is carrying, and returns his id
  /// and the placement his load came from.
  (FactoryFloor, InfiniteColonyPort, int, int) carryingMill() {
    final f = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
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
    expect(f.hire(HandlerKind.onFoot, -kSteelMillWalkers).ok, isTrue);
    expect(f.handlers, isEmpty);
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
    final f = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
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
              pos: TilePos(next(kSteelMillHall.w), next(kSteelMillHall.h))));
        default:
          r = f.place(Placement(
              id: 0,
              kind: EntityKind.belt,
              dir: Dir4.values[next(4)],
              pos: TilePos(next(kSteelMillHall.w), next(kSteelMillHall.h))));
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
