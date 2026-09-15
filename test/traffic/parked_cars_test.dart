// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The parked cars (docs/plans/t4a-implementation.md §1.7, §4 Q3;
/// agent-traffic.md §2.7, §7.4; site-access.md §7.5).
///
/// A parked car is a row, not an object, and its owner is opaque so slice 3
/// can port ownership to citizens without touching the table. What this
/// pins is what the rest of T4a leans on: a row says where the car stands
/// and by which KEY, `parkedRev` moves whenever any of that changes, and a
/// home pool hands its cars out last in first out, skipping a car a tandem
/// stall stands in front of.
library;

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tandem pad: stall [deep] is reached past stall [outer], and nothing
/// else is blocked. What a site table reads off a home plan's stall order.
class _Tandem implements TandemStalls {
  _Tandem({required this.row, required this.deep, required this.outer});

  final int row, deep, outer;

  @override
  int blockerOf(int row, int stall) =>
      row == this.row && stall == deep ? outer : -1;
}

void main() {
  const car = 0; // AgentKind.car, the only kind that parks in T4a

  /// A car of [ownerKind] on [stall] of site [row] of [building].
  int parkLot(ParkedCarTable t,
          {int building = 1,
          int row = 3,
          int stall = 0,
          int key = 1000,
          CarOwnerKind ownerKind = CarOwnerKind.homePool,
          int owner = 7,
          int variant = 2}) =>
      t.parkLot(
          building: building,
          row: row,
          stall: stall,
          stallKey: key,
          ownerKind: ownerKind,
          owner: owner,
          kind: car,
          variant: variant);

  test('a row says where the car stands, and parkedRev moves with it', () {
    final t = ParkedCarTable(capacity: 8);
    expect(t.count, 0);
    expect(AgentKind.values[car], AgentKind.car);

    final rev0 = t.parkedRev;
    final lot = parkLot(t, key: 4242, stall: 2);
    expect(t.parkedRev, greaterThan(rev0));
    final i = SlotPool.slotOf(lot);
    expect(t.isLive(lot), isTrue);
    expect(CarWhere.values[t.where[i]], CarWhere.lot);
    expect(CarOwnerKind.values[t.ownerKind[i]], CarOwnerKind.homePool);
    expect(t.owner[i], 7);
    expect(t.building[i], 1);
    expect(t.row[i], 3);
    expect(t.stall[i], 2);
    expect(t.stallKey[i], 4242, reason: 'a lot car is kept by its KEY (C-19)');
    expect(t.edge[i], -1);
    expect(t.slot[i], -1);
    expect(t.lotCars, 1);

    final rev1 = t.parkedRev;
    final kerb = t.parkKerb(
        building: 1,
        edge: 12,
        slot: 5,
        side: 1,
        ownerKind: CarOwnerKind.commuter,
        owner: 8,
        kind: car,
        variant: 0);
    final k = SlotPool.slotOf(kerb);
    expect(t.parkedRev, greaterThan(rev1));
    expect(CarWhere.values[t.where[k]], CarWhere.kerb);
    expect(t.edge[k], 12);
    expect(t.slot[k], 5);
    expect(t.side[k], 1);
    expect(t.kerbCars, 1);

    final garaged = t.garage(
        building: 2,
        ownerKind: CarOwnerKind.commuter,
        owner: 9,
        kind: car,
        variant: 1);
    expect(CarWhere.values[t.where[SlotPool.slotOf(garaged)]],
        CarWhere.garaged);
    expect(t.garagedCars, 1);
    expect(t.count, 3);

    // Moved, not re-made: the handle stands and the revision moves.
    final rev2 = t.parkedRev;
    t.moveToKerb(lot, 4, 9, 0);
    expect(t.parkedRev, greaterThan(rev2));
    expect(t.isLive(lot), isTrue);
    expect(CarWhere.values[t.where[i]], CarWhere.kerb);
    expect(t.edge[i], 4);
    expect(t.slot[i], 9);
    expect(t.lotCars, 0);
    expect(t.kerbCars, 2);
    t.moveToStall(lot, 3, 1, 4242);
    expect(t.stall[i], 1);
    expect(t.lotCars, 1);
    t.moveToGarage(lot);
    expect(t.garagedCars, 2);

    final rev3 = t.parkedRev;
    t.remove(lot);
    expect(t.parkedRev, greaterThan(rev3));
    expect(t.isLive(lot), isFalse);
    expect(t.count, 2);
    expect(t.garagedCars, 1);
    final rev4 = t.parkedRev;
    t.remove(lot);
    expect(t.parkedRev, rev4, reason: 'a stale handle removes nothing');
  });

  test('a full table answers none, and grows only when its owner says', () {
    final t = ParkedCarTable(capacity: 2);
    final a = parkLot(t, stall: 0);
    final b = parkLot(t, stall: 1);
    expect(t.parkLot(
            building: 1,
            row: 3,
            stall: 2,
            stallKey: 3,
            ownerKind: CarOwnerKind.commuter,
            owner: 0,
            kind: car,
            variant: 0),
        SlotPool.none);
    t.grow(4);
    expect(t.isLive(a), isTrue, reason: 'live handles survive a grow');
    expect(t.isLive(b), isTrue);
    expect(t.stall[SlotPool.slotOf(b)], 1);
    final c = parkLot(t, stall: 2);
    expect(t.isLive(c), isTrue);
    expect(t.count, 3);
  });

  group('the home pool', () {
    test('hands its cars out last in first out', () {
      final t = ParkedCarTable(capacity: 8);
      final first = parkLot(t, building: 5, stall: 0, key: 10);
      final second = parkLot(t, building: 5, stall: 1, key: 11);
      final other = parkLot(t, building: 6, stall: 0, key: 12);
      expect(t.pooledCount(5), 2);
      expect(t.takePooled(5), second, reason: 'last in, first out');
      expect(t.pooledCount(5), 1);
      expect(t.takePooled(5), first);
      expect(t.pooledCount(5), 0);
      expect(t.takePooled(5), SlotPool.none, reason: 'an empty pool');
      expect(t.takePooled(99), SlotPool.none, reason: 'no such building');
      expect(t.takePooled(6), other);

      // A taken car stands where it was, and it is still its owner's.
      expect(t.isLive(second), isTrue);
      expect(t.isPooled(second), isFalse);
      expect(t.claim[SlotPool.slotOf(second)], ParkedCarTable.takenClaim);
      t.returnPooled(second);
      expect(t.isPooled(second), isTrue);
      expect(t.takePooled(5), second, reason: 'the trip never ran');
    });

    test('only home cars pool: a commuter\'s car is nobody\'s to take', () {
      final t = ParkedCarTable(capacity: 8);
      parkLot(t, building: 5, ownerKind: CarOwnerKind.commuter);
      parkLot(t, building: 5, stall: 1, ownerKind: CarOwnerKind.none);
      expect(t.pooledCount(5), 0);
      expect(t.takePooled(5), SlotPool.none);
    });

    test('a tandem stall in front of a car sends the pool past it', () {
      final t = ParkedCarTable(capacity: 8)
        ..tandem = _Tandem(row: 3, deep: 1, outer: 0);
      // Tandem stalls fill deepest first (§7.5), so the DEEP car is the
      // older one and the outer car is on top of the stack anyway.
      final deep = parkLot(t, building: 5, stall: 1, key: 11);
      final outer = parkLot(t, building: 5, stall: 0, key: 10);
      expect(t.takePooled(5), outer);
      t.remove(outer); // it drove off, and the stall behind it is clear
      expect(t.takePooled(5), deep);

      // The other way round: the deep car is the newest, and the pool skips
      // it for the outer one that can actually leave.
      final t2 = ParkedCarTable(capacity: 8)
        ..tandem = _Tandem(row: 3, deep: 1, outer: 0);
      final outer2 = parkLot(t2, building: 5, stall: 0, key: 10);
      final deep2 = parkLot(t2, building: 5, stall: 1, key: 11);
      expect(t2.takePooled(5), outer2, reason: 'LIFO would take the deep car');
      expect(t2.takePooled(5), deep2,
          reason: 'blocked — the outer car is taken but still standing — and '
              'the last one left: it goes and waits for its shuffle rather '
              'than leaving the home with no car at all');
      expect(t2.takePooled(5), SlotPool.none);

      // A stall on another site row is nobody's blocker.
      final t3 = ParkedCarTable(capacity: 8)
        ..tandem = _Tandem(row: 3, deep: 1, outer: 0);
      final elsewhere = parkLot(t3, building: 5, row: 4, stall: 0, key: 10);
      final deep3 = parkLot(t3, building: 5, row: 3, stall: 1, key: 11);
      expect(t3.takePooled(5), deep3);
      expect(t3.takePooled(5), elsewhere);
    });

    test('with no tandem anywhere, the pool is pure LIFO', () {
      final t = ParkedCarTable(capacity: 8);
      final a = parkLot(t, building: 5, stall: 0, key: 10);
      final b = parkLot(t, building: 5, stall: 1, key: 11);
      expect(t.tandem, isNull);
      expect(t.takePooled(5), b);
      expect(t.takePooled(5), a);
    });
  });

  test('the digest is the state, not how it got there', () {
    ParkedCarTable filled() {
      final t = ParkedCarTable(capacity: 8);
      parkLot(t, building: 1, row: 3, stall: 0, key: 10);
      parkLot(t, building: 1, row: 3, stall: 1, key: 11);
      return t;
    }

    final a = filled();
    final b = filled();
    // b reaches the same two cars the long way round: one parked, removed
    // and parked again, so its parkedRev and its slots differ.
    final spare = parkLot(b, building: 2, row: 4, stall: 5, key: 12);
    b.remove(spare);
    expect(b.parkedRev, isNot(a.parkedRev));
    expect(b.digest(0), a.digest(0));

    final c = filled();
    parkLot(c, building: 2, row: 4, stall: 5, key: 12);
    expect(c.digest(0), isNot(a.digest(0)));
  });

  test('parking and unparking all day reallocates no column', () {
    final t = ParkedCarTable(capacity: 64);
    final before = <String, Object>{};
    parkLot(t, building: 3);
    t.collectBuffers(before, 'parked');
    expect(before, isNotEmpty);
    for (var i = 0; i < 1000; i++) {
      final one = parkLot(t, building: 3, stall: i % 4, key: 100 + i % 4);
      final two = t.parkKerb(
          building: 3,
          edge: i % 7,
          slot: i % 5,
          side: i.isEven ? 1 : 0,
          ownerKind: CarOwnerKind.commuter,
          owner: i,
          kind: car,
          variant: 0);
      t.takePooled(3);
      t.remove(one);
      t.remove(two);
    }
    final after = <String, Object>{};
    t.collectBuffers(after, 'parked');
    for (final name in before.keys) {
      expect(identical(before[name], after[name]), isTrue,
          reason: '$name was reallocated');
    }
  });
}
