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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_unlocks.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Vehicles add new ways for an edit to strand goods: a crane bay lifted
/// with a billet on the hook, an aisle painted out from under a loaded
/// forklift, a vehicle sent to charge, an unlock revoked. Conservation —
/// held + shipped − received − craftNet = 0 — must survive every one, or a
/// floor's ledger (and so its P&L) stops being trustworthy.
void main() {
  setUpAll(ensureFactoryCatalog);

  const kPortMillHall = HallSize(28, 10);
  const kPortMillWalkers = 2;

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
    final f = FactoryFloor.fromBlueprint(portMill());
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
    expect(piles, contains('steelBillet'), reason: 'set down, not carried');
    for (final h in f.handlers) {
      if (h.kind == HandlerKind.crane) {
        expect(h.carrying, isNull, reason: 'no hook keeps a load');
      }
    }
    f.step(120, port);
    expect(conservationError(f), isEmpty);
  });

  test('an aisle painted out under a loaded forklift keeps the load', () {
    final f = FactoryFloor.fromBlueprint(portMill());
    final port = InfiniteColonyPort();
    final fl = carrier(f, HandlerKind.forklift, port);
    final before = f.itemsOnFloor;
    final metres = f.ledger.itemMetres;
    final stood = TilePos(fl.x.round(), fl.y.round());
    final aisle = f.blueprint.placements.firstWhere(
      (p) => p.kind == EntityKind.aisle,
    );
    expect(f.remove(aisle.id).ok, isTrue);
    expect(f.itemsOnFloor, before);
    expect(conservationError(f), isEmpty);
    // Off its aisle, it sets the crates down WHERE IT STOOD before it is
    // moved (empty-handed) to the charging bay: goods never jump across
    // the hall with no trip and no item-metres.
    final h = f.handlers.firstWhere((h) => h.id == fl.id);
    expect(h.carrying, isNull, reason: 'cut off: it set the crates down');
    expect(f.ledger.itemMetres, metres, reason: 'no free ride');
    final crates = [
      for (final e in f.floorPiles.entries)
        if (e.value.containsKey('crate:steel')) e.key,
    ];
    expect(crates, isNotEmpty);
    expect(
      crates.any((t) => (t.x - stood.x).abs() + (t.y - stood.y).abs() <= 2),
      isTrue,
      reason: 'set down beside $stood, not at its new home',
    );
    f.step(5, port);
    expect(conservationError(f), isEmpty);
    f.step(120, port);
    expect(conservationError(f), isEmpty);
  });

  test('conservation holds through arbitrary vehicle and layout edits', () {
    final f = FactoryFloor.fromBlueprint(portMill());
    final port = InfiniteColonyPort();
    var seed = 424242;
    int next(int n) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return (seed >> 8) % n;
    }

    TilePos anywhere() =>
        TilePos(next(kPortMillHall.w), next(kPortMillHall.h));
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
