// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/dock_geometry.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/dock_logistics.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/supply_world.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Docks on orders and trucks (docs/plans/factory-floors.md §10 items 3, 4,
/// 6, 11): wall placement, a truck that waits for handlers (or a
/// conveyor), finite suppliers, pickups that sell to contracts, and the
/// unlimited switch that brings the old feed back — all conserving goods
/// and bit-for-bit through a save.
void main() {
  setUpAll(ensureFactoryCatalog);

  const hall = HallSize(12, 8);

  /// A tube line: wall dock (west) → belt → wall shipping dock (east).
  /// Returns the floor and the two dock ids.
  (FactoryFloor, int, int) line({int jacks = 0, int walkers = 0}) {
    final l = Lay();
    final recv = l.add(EntityKind.receivingDock, 0, 2,
        item: 'tubes', span: kDockSpan);
    l.beltRow(3, 8, 2);
    final ship = l.add(EntityKind.shippingDock, 9, 2,
        dir: Dir4.west, span: kDockSpan);
    final f = FactoryFloor.fromBlueprint(l.blueprint(hall.w, hall.h,
        walkers: walkers,
        crew: {if (jacks > 0) HandlerKind.palletJack: jacks}));
    return (f, recv, ship);
  }

  /// A world with one tube supplier (lead 30 s, 2 trucks of stock).
  SupplyWorld world({double perHour = 0}) => SupplyWorld(suppliers: [
        Supplier(id: 'ares', name: 'Ares', leadTimeS: 30, truckPallets: 4,
            lines: [
              SupplyLine(
                  good: 'tubes', stock: 80, cap: 80, refillPerHour: perHour),
            ]),
      ], contracts: [
        CustomerContract(
            id: 'c1',
            customer: 'Depot',
            good: 'tubes',
            unitsPerWeek: 15,
            payPerUnit: 3,
            windowDays: {0, 1, 2, 3, 4, 5, 6}),
      ]);

  group('wall docks', () {
    test('a dock mid-hall is refused; on the wall it is fine', () {
      final f = FactoryFloor.fromBlueprint(Lay().blueprint(hall.w, hall.h));
      final mid = Placement(
          id: 0,
          kind: EntityKind.receivingDock,
          pos: const TilePos(4, 3),
          item: 'tubes',
          span: kDockSpan);
      expect(f.check(mid).refusal, EditRefusal.notOnWall);
      // Facing out (door on the inside edge) is refused too.
      final backwards = mid.copyWith(pos: const TilePos(0, 3), dir: Dir4.west);
      expect(f.check(backwards).ok, isFalse);
      final ok = mid.copyWith(pos: const TilePos(0, 3));
      expect(f.check(ok).ok, isTrue);
      expect(ok.footprint, const TileRect(0, 3, 3, 2),
          reason: '4 m door, 6 m deep loading area');
    });

    test('the ghost snaps to the nearest wall, facing in', () {
      final w = snapDockToWall(hall, const TilePos(1, 4),
          EntityKind.receivingDock);
      expect((w.pos, w.dir), (const TilePos(0, 4), Dir4.east));
      final e = snapDockToWall(hall, const TilePos(10, 4),
          EntityKind.shippingDock);
      expect((e.pos, e.dir), (const TilePos(9, 4), Dir4.west));
      final s = snapDockToWall(hall, const TilePos(5, 0),
          EntityKind.receivingDock);
      expect((s.pos, s.dir, s.footprint.h), (const TilePos(5, 0), Dir4.north, 3));
      final n = snapDockToWall(hall, const TilePos(11, 7),
          EntityKind.receivingDock);
      expect(dockOnOuterWall(n, hall), isTrue);
      expect(hall.rect.containsRect(n.footprint), isTrue);
      for (final p in [w, e, s, n]) {
        expect(dockOnOuterWall(p, hall), isTrue);
        expect(truckBayOf(p).overlaps(hall.rect), isFalse,
            reason: 'the truck parks outside');
      }
    });
  });

  group('inbound', () {
    test('a truck arrives after the lead time and waits for handlers', () {
      final (f, recv, _) = line();
      final lg = f.logistics = FloorLogistics(world: world());
      lg.placeOrder(supplier: 'ares', good: 'tubes', packs: 2, dock: recv);
      final port = InfiniteColonyPort();
      f.step(20, port);
      expect(lg.dockedAt(recv), isNull, reason: 'still on the road');
      expect(lg.incomingTo(recv).single.cargo['crate:tubes'], 2);
      f.step(20, port);
      expect(lg.dockedAt(recv), isNotNull);
      f.step(120, port);
      expect(lg.dockedAt(recv)!.cargo['crate:tubes'], 2,
          reason: 'no handler, no conveyor: nobody unloads it');
      expect(f.beltItems, isEmpty);
      expect(f.pendingRequests, greaterThan(0),
          reason: 'the unload request is the "hire a jack" signal');
      expect(conservationError(f), isEmpty);
    });

    test('a pallet jack unloads it, the area breaks it down, the line runs',
        () {
      final (f, recv, _) = line(jacks: 1);
      final lg = f.logistics = FloorLogistics(world: world());
      lg.placeOrder(supplier: 'ares', good: 'tubes', packs: 2, dock: recv);
      final port = InfiniteColonyPort();
      f.step(200, port);
      expect(lg.dockedAt(recv), isNull, reason: 'emptied and gone');
      expect(f.ledger.received['tubes'], 20);
      expect(port.taken, isEmpty, reason: 'the supplier, not the colony');
      final shipDock = f.blueprint.placements
          .firstWhere((p) => p.kind == EntityKind.shippingDock);
      expect(f.contentsOf(shipDock.id)['tubes'] ?? 0, greaterThan(0),
          reason: 'loose tubes rode the belt to the shipping dock');
      expect(conservationError(f), isEmpty);
    });

    test('a worker on foot unloads loose goods from an opened pallet', () {
      final (f, recv, _) = line(walkers: 1);
      final lg = f.logistics = FloorLogistics(world: world());
      lg.placeOrder(supplier: 'ares', good: 'tubes', packs: 1, dock: recv);
      final port = InfiniteColonyPort();
      var opened = false;
      for (var i = 0; i < 4 * 60; i++) {
        f.step(kFactoryStepS, port);
        if ((lg.dockedAt(recv)?.cargo['tubes'] ?? 0) > 0) opened = true;
      }
      expect(opened, isTrue, reason: 'the pallet is opened at the tailgate');
      f.step(120, port);
      expect(f.ledger.received['tubes'], 10);
      expect(conservationError(f), isEmpty);
    });

    test('a dock conveyor unloads by itself', () {
      final (f, recv, _) = line();
      final lg = f.logistics = FloorLogistics(world: world());
      expect(lg.setConveyor(recv, true), kDockConveyorCapexOre);
      lg.placeOrder(supplier: 'ares', good: 'tubes', packs: 2, dock: recv);
      final port = InfiniteColonyPort();
      f.step(31, port);
      f.step(10, port);
      expect(lg.dockedAt(recv), isNull, reason: 'two pallets in ~4 s');
      expect(f.ledger.received['tubes'], 20);
      expect(conservationError(f), isEmpty);
    });

    test('pallet breakdown turns one crate into ten loose tubes', () {
      final (f, recv, _) = line();
      final lg = f.logistics = FloorLogistics(world: world());
      lg.bay(recv).area.add('crate:tubes', 1);
      // Block the belt so nothing leaves the area.
      final front = f.blueprint.placements.firstWhere((p) =>
          p.kind == EntityKind.belt && p.pos == const TilePos(3, 2));
      f.remove(front.id);
      f.step(kHandBreakdownS + 0.5, InfiniteColonyPort());
      expect(lg.areaOf(recv), {'tubes': 10});
      expect(slotsOf('tubes', 10), 1);
      expect(slotsOf('crate:tubes', 3), 3);
    });

    test('a recurring order fires on its schedule', () {
      final (f, recv, _) = line();
      final lg = f.logistics = FloorLogistics(world: world(perHour: 1e6));
      lg.setConveyor(recv, true);
      final id = lg.placeOrder(
          supplier: 'ares',
          good: 'tubes',
          packs: 1,
          dock: recv,
          schedule: const OrderSchedule.every(300));
      final port = InfiniteColonyPort();
      f.step(1000, port);
      expect(lg.orders[id]!.fired, 4, reason: 't = 0, 300, 600, 900');
      expect(lg.orders[id]!.active, isTrue);
      // Weekly: Monday 06:00 start; weekdays 06:00 → next is Tuesday 06:00.
      const clock = SimWeekClock();
      const wk = OrderSchedule.weekly({0, 1, 2, 3, 4}, 6 * 3600);
      expect(wk.nextAfter(0, clock), 86400);
      expect(wk.nextAfter(0, clock, inclusive: true), 0);
      expect(wk.nextAfter(4 * 86400, clock), 7 * 86400,
          reason: 'Friday → skip the weekend');
    });
  });

  test('supplier stock is finite and refills', () {
    final w = world(perHour: 36);
    final s = w.suppliers['ares']!;
    final port = InfiniteColonyPort();
    expect(w.reserve(s, 'tubes', 5, port), 5);
    expect(w.reserve(s, 'tubes', 5, port), 3, reason: '80 tubes = 8 crates');
    expect(w.reserve(s, 'tubes', 1, port), 0);
    expect(w.spent, closeTo(80 * w.priceAt(s, 'tubes'), 1e-6));
    w.refill(1000); // 36 / h → 10 tubes
    expect(s.lines['tubes']!.stock, closeTo(10, 1e-9));
    expect(w.reserve(s, 'tubes', 2, port), 1);
    w.refill(1e7);
    expect(s.lines['tubes']!.stock, 80, reason: 'capped');
  });

  test('a pickup ships, sells to the contract first, then spot', () {
    final (f, recv, ship) = line();
    final lg = f.logistics = FloorLogistics(world: world());
    lg.setConveyor(recv, true);
    lg.placeOrder(supplier: 'ares', good: 'tubes', packs: 3, dock: recv);
    lg.addPickup(dock: ship, whenPallets: 3, leadS: 10);
    final port = InfiniteColonyPort();
    f.step(240, port);
    final shipped = f.ledger.shipped['tubes'] ?? 0;
    expect(shipped, greaterThanOrEqualTo(30));
    final c = lg.world.contracts['c1']!;
    expect(c.deliveredThisWeek, 15, reason: 'the contract takes its 15');
    expect(lg.world.earned,
        closeTo(15 * 3 + (shipped - 15) * lg.world.spotPrice('tubes'), 1e-6));
    expect(port.given, isEmpty, reason: 'sold outside, not to the colony');
    expect(conservationError(f), isEmpty);
  });

  test('a colony world takes from and gives to the colony stock', () {
    final (f, recv, ship) = line();
    final lg = f.logistics = FloorLogistics(world: SupplyWorld.colony());
    lg.setConveyor(recv, true);
    lg.placeOrder(
        supplier: SupplyWorld.kColonyStoresId,
        good: 'tubes',
        packs: 2,
        dock: recv);
    lg.addPickup(dock: ship, whenPallets: 1, leadS: 5);
    final port = StockColonyPort(stock: {'tubes': 15});
    f.step(400, port);
    expect(f.ledger.received['tubes'], 10, reason: 'one whole crate of 15');
    expect(port.stock['tubes'], 15 - 10 + 10,
        reason: 'the part crate went back; the tubes came home');
    expect(conservationError(f), isEmpty);
  });

  test('unlimited supply brings the old feed back and is remembered', () {
    final (f, recv, _) = line();
    final lg = f.logistics = FloorLogistics(world: world());
    final port = InfiniteColonyPort();
    f.step(30, port);
    expect(f.beltItems, isEmpty, reason: 'no order, no tubes');
    expect(lg.world.usedUnlimited, isFalse);
    lg.world.setUnlimited(true);
    f.step(30, port);
    expect(f.beltItems, isNotEmpty);
    expect(port.taken['tubes'], greaterThan(0));
    lg.world.setUnlimited(false);
    expect(lg.world.usedUnlimited, isTrue, reason: 'sticky for the goal');
    expect(recv, isPositive);
  });

  test('save → load → step equals an uninterrupted run', () {
    FactoryFloor build() {
      final (f, recv, ship) = line(jacks: 1, walkers: 1);
      final lg = f.logistics = FloorLogistics(world: world(perHour: 20));
      lg.placeOrder(
          supplier: 'ares',
          good: 'tubes',
          packs: 2,
          dock: recv,
          schedule: const OrderSchedule.every(400));
      lg.addPickup(dock: ship, whenPallets: 2, leadS: 20);
      return f;
    }

    final a = build(), port = InfiniteColonyPort();
    a.step(137, port);
    final saved = jsonEncode(a.toJson());
    final j = jsonDecode(saved) as Map<String, Object?>;
    expect(j['lg'], isNotNull);
    final b = FactoryFloor.fromJson(j);
    expect(jsonEncode(b.toJson()), saved);
    expect(b.logistics!.orders.length, 1);
    expect(b.logistics!.world.suppliers['ares']!.lines['tubes']!.stock,
        a.logistics!.world.suppliers['ares']!.lines['tubes']!.stock);
    a.step(900, port);
    b.step(900, port);
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()),
        reason: 'deterministic through a save');
    expect(conservationError(a), isEmpty);
    expect(a.logistics!.orders.values.first.fired, greaterThan(1));
  });

  test('removing a dock sets its area down and turns its trucks away', () {
    final (f, recv, _) = line();
    final lg = f.logistics = FloorLogistics(world: world());
    lg.bay(recv).area.add('crate:tubes', 2);
    lg.placeOrder(supplier: 'ares', good: 'tubes', packs: 4, dock: recv);
    final port = InfiniteColonyPort();
    f.step(1, port);
    final stockBefore = lg.world.suppliers['ares']!.lines['tubes']!.stock;
    final held = f.itemsOnFloor;
    expect(f.remove(recv).ok, isTrue);
    expect(f.itemsOnFloor, held, reason: 'the area became piles');
    f.step(1, port);
    expect(lg.trucks, isEmpty);
    expect(lg.world.suppliers['ares']!.lines['tubes']!.stock,
        stockBefore + 40, reason: 'the cargo went back to the supplier');
  });
}
