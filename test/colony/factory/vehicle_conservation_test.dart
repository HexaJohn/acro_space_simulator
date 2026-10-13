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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_unlocks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Vehicles add new ways for an edit to strand goods: a crane bay lifted
/// with a billet on the hook, an aisle painted out from under a loaded
/// forklift, a vehicle sent to charge, an unlock revoked. Conservation —
/// held + shipped − received − craftNet = 0 — must survive every one, or a
/// floor's ledger (and so its P&L) stops being trustworthy.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// Steps [f] until some handler of [kind] is carrying; returns it.
  HandlerView carrier(FactoryFloor f, HandlerKind kind, FactoryColonyPort p) {
    for (var i = 0; i < 4 * 600; i++) {
      for (final h in f.handlers) {
        if (h.kind == kind && h.state == HandlerState.carrying) return h;
      }
      f.step(kFactoryStepS, p);
    }
    fail('no ${kind.name} ever carried anything');
  }

  test('a crane bay removed mid-lift sets the billet down', () {
    final f = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final port = InfiniteColonyPort();
    final c = carrier(f, HandlerKind.crane, port);
    final before = f.itemsOnFloor;
    final bay = f.blueprint.placements.firstWhere(
      (p) =>
          p.kind == EntityKind.craneBay &&
          p.footprint.contains(TilePos(c.x.round(), c.y.round())),
    );
    expect(f.remove(bay.id).ok, isTrue);
    expect(f.itemsOnFloor, before, reason: 'nothing vanished with the bay');
    expect(conservationError(f), isEmpty);
    final piles = f.floorPiles.values.expand((m) => m.keys);
    final rebound = f.handlers.where(
      (h) => h.kind == HandlerKind.crane && h.carrying == 'steelBillet',
    );
    expect(
      piles.contains('steelBillet') || rebound.isNotEmpty,
      isTrue,
      reason: 'the billet is on the floor or still on a hook',
    );
    f.step(120, port);
    expect(conservationError(f), isEmpty);
  });

  test('an aisle painted out under a loaded forklift keeps the load', () {
    final f = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final port = InfiniteColonyPort();
    final fl = carrier(f, HandlerKind.forklift, port);
    final before = f.itemsOnFloor;
    final aisle = f.blueprint.placements.firstWhere(
      (p) => p.kind == EntityKind.aisle,
    );
    expect(f.remove(aisle.id).ok, isTrue);
    expect(f.itemsOnFloor, before);
    expect(conservationError(f), isEmpty);
    // Off its aisle it is moved to the charging bay — the only drivable
    // floor left — where no dock can be reached: it sets the crates down.
    f.step(5, port);
    final h = f.handlers.firstWhere((h) => h.id == fl.id);
    expect(h.carrying, isNull, reason: 'cut off: it set the crates down');
    expect(f.floorPiles.values.expand((m) => m.keys), contains('crate:steel'));
    expect(conservationError(f), isEmpty);
    f.step(120, port);
    expect(conservationError(f), isEmpty);
  });

  test('conservation holds through arbitrary vehicle and layout edits', () {
    final f = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final port = InfiniteColonyPort();
    var seed = 424242;
    int next(int n) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return (seed >> 8) % n;
    }

    TilePos anywhere() =>
        TilePos(next(kSteelMillHall.w), next(kSteelMillHall.h));
    List<int> idsOf(Set<EntityKind> kinds) => [
      for (final p in f.blueprint.placements)
        if (kinds.contains(p.kind)) p.id,
    ]..sort();

    var applied = 0;
    f.step(120, port);
    for (var round = 0; round < 200; round++) {
      final ids = idsOf(EntityKind.values.toSet());
      final markings = idsOf({
        EntityKind.aisle,
        EntityKind.craneBay,
        EntityKind.chargingBay,
        EntityKind.staging,
      });
      final machines = idsOf({EntityKind.machine});
      final EditResult r;
      switch (next(10)) {
        case 0:
          r = f.remove(ids[next(ids.length)]);
        case 1:
          r = markings.isEmpty
              ? f.rotate(ids[next(ids.length)])
              : f.remove(markings[next(markings.length)]);
        case 2:
          r = f.hire(
            HandlerKind.values[next(HandlerKind.values.length)],
            next(5) - 2,
          );
        case 3:
          r = f.place(
            Placement(
              id: 0,
              kind: EntityKind.aisle,
              pos: anywhere(),
              span: (1 + next(3), 1 + next(8)),
            ),
          );
        case 4:
          r = f.place(
            Placement(
              id: 0,
              kind: EntityKind.craneBay,
              pos: anywhere(),
              span: (2 + next(8), 2 + next(4)),
            ),
          );
        case 5:
          r = f.place(
            Placement(id: 0, kind: EntityKind.chargingBay, pos: anywhere()),
          );
        case 6:
          r = machines.isEmpty
              ? f.rotate(ids[next(ids.length)])
              : f.setMode(
                  machines[next(machines.length)],
                  MachineMode.values[next(MachineMode.values.length)],
                );
        case 7:
          f.unlocks = next(2) == 0
              ? FactoryUnlocks.starter
              : FactoryUnlocks.all;
          r = const EditResult.ok(null);
        case 8:
          r = f.place(
            Placement(
              id: 0,
              kind: EntityKind.belt,
              dir: Dir4.values[next(4)],
              pos: anywhere(),
            ),
          );
        default:
          r = f.rotate(ids[next(ids.length)]);
      }
      if (r.ok) applied++;
      expect(conservationError(f), isEmpty, reason: 'after edit $round');
      // Short and long steps, some under partial staffing and brownout.
      final share = next(4) == 0 ? 0.5 : 1.0;
      f.step(
        0.25 * (1 + next(120)),
        StockColonyPort(
          stock: {'ore': 1e9},
          staffingShare: share,
          powerShare: share,
        ),
      );
      expect(conservationError(f), isEmpty, reason: 'after step $round');
    }
    expect(applied, greaterThan(100), reason: 'most edits really happened');
    expect(
      {for (final h in f.handlers) h.kind}.length,
      greaterThan(2),
      reason: 'the fuzz really ran a mixed fleet',
    );
  });
}
