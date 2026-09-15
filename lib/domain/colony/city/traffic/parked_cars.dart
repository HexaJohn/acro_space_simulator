// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The cars that are parked: on a lot stall, at a kerb slot, or garaged
/// (docs/plans/t4a-implementation.md §1.7; site-access.md §7.5, §14.1).
///
/// - A parked car is a SLOT with typed columns, like a vehicle (§2.1), and
///   it does NOT count against `AgentTuning.maxVehicles`: it is not on the
///   road. Its owner is OPAQUE — a [CarOwnerKind] and an index — so slice 3
///   ports the owners to citizens without touching the table.
/// - **Where** it is ([CarWhere]): a lot stall (its site row, stall index
///   and `stallKey`, which is what a save keeps, §7.5), a kerb slot (its
///   edge, slot and side), or garaged — taken out of the world because
///   nothing could place it, and given back when its owner drives again.
/// - [parkedRev] moves whenever a row appears, goes or moves, so the wire
///   republishes the lot rows only when they changed (§7.5).
/// - **Home pools** ([takePooled]): cars at a home are `homePool`-owned and
///   an outbound commute takes one, LAST IN FIRST OUT, preferring a tandem
///   stall nothing blocks (§0 Q3, §7.5).
///
/// The table never grows by itself, as the vehicle table does not: a park
/// on a full table answers [SlotPool.none] and its owner decides whether
/// this is a moment it may [grow] (§2.1). Nothing here allocates otherwise,
/// so a town parking and unparking all day reallocates no column (A13).
///
/// **What blocks what** is the plan's to know, not the table's: two cars in
/// one tandem pad are two rows with two stall indices, and only the site's
/// plan says that one stands behind the other. So the owner hands the table
/// a [TandemStalls] once ([tandem]) and [takePooled] asks it. Without one
/// every stall reaches the drive on its own, which is true of every site but
/// a tandem home pad.
library;

import 'dart:typed_data';

import 'slot_pool.dart';
import 'traffic_rng.dart';

/// Where a parked car sits. The SAVE INDEX: append-only (§14.1).
enum CarWhere { lot, kerb, garaged }

/// Whose car it is, opaquely. Append-only; slice 3 appends `citizen`.
enum CarOwnerKind { none, commuter, homePool }

/// Which stall of a site stands between another stall and the drive
/// (site-access.md §7.5: tandem pads, at most 2 deep). The site table knows
/// it from the plan; [ParkedCarTable] only asks.
abstract interface class TandemStalls {
  /// The stall of [row] that has to be empty before the car on [stall] can
  /// leave, or −1 when nothing stands in its way.
  int blockerOf(int row, int stall);
}

/// The parked cars. See the library comment.
class ParkedCarTable {
  ParkedCarTable({int capacity = 16384}) : pool = SlotPool(capacity) {
    _allocColumns(capacity);
  }

  /// [claim] of a car nobody has taken.
  static const int unclaimed = -1;

  /// [claim] of a car a trip has taken out of its home pool and not yet
  /// driven away (§0 Q3: the car is taken when the trip is REQUESTED, and it
  /// stands on its stall until it departs). A handle is `gen << 20 | slot`
  /// with generations from 1, so no handle is ever 0 and a later slice can
  /// put the taker's own handle here without ambiguity.
  static const int takenClaim = 0;

  /// Slots and their generations: a car is a handle, like a vehicle.
  final SlotPool pool;

  /// Per car: [CarWhere], [CarOwnerKind], the `AgentKind` index, the
  /// renderer's variant byte (D42), and the kerb side it stands on.
  late Uint8List where, ownerKind, kind, variant, side;

  /// Per car: its opaque owner; the building it belongs to; its site row,
  /// stall and `stallKey` on a lot; its road edge and kerb slot at a kerb;
  /// what it holds; and the next car of its building's home pool (−1).
  late Int32List owner, building, row, stall, stallKey, edge, slot, claim,
      poolNext;

  /// Moves whenever a row appears, goes or moves.
  int parkedRev = 0;

  /// What stands behind what on a tandem pad; null while no site has one.
  TandemStalls? tandem;

  /// Per building slot: the car on top of its home pool, or −1. The pool is
  /// a stack threaded through [poolNext], so a push and a pop are O(1) and
  /// the newest car leaves first (§0 Q3).
  Int32List _poolHead = Int32List(0);

  /// Cars parked, by where they stand.
  int lotCars = 0, kerbCars = 0, garagedCars = 0;

  int get capacity => pool.capacity;

  /// Cars parked anywhere.
  int get count => pool.liveCount;

  /// Whether [car] names a live row.
  bool isLive(int car) => pool.isLive(car);

  /// Grows the table to [newCapacity] rows. Every column is copied and live
  /// handles stay live. Only during warm-up or a rebuild (§2.1).
  void grow(int newCapacity) {
    final old = capacity;
    pool.grow(newCapacity);
    Uint8List u8(Uint8List a) => Uint8List(newCapacity)..setRange(0, old, a);
    Int32List i32(Int32List a) => Int32List(newCapacity)..setRange(0, old, a);
    where = u8(where);
    ownerKind = u8(ownerKind);
    kind = u8(kind);
    variant = u8(variant);
    side = u8(side);
    owner = i32(owner);
    building = i32(building);
    row = i32(row);
    stall = i32(stall);
    stallKey = i32(stallKey);
    edge = i32(edge);
    slot = i32(slot);
    claim = i32(claim);
    poolNext = i32(poolNext);
  }

  /// Parks a car on [stall] of site [row] of [building], keyed by
  /// [stallKey]. Returns its handle, or [SlotPool.none] when the table is
  /// full.
  int parkLot(
      {required int building,
      required int row,
      required int stall,
      required int stallKey,
      required CarOwnerKind ownerKind,
      required int owner,
      required int kind,
      required int variant}) {
    final car = _open(CarWhere.lot, building, ownerKind, owner, kind, variant);
    if (car < 0) return car;
    final i = SlotPool.slotOf(car);
    this.row[i] = row;
    this.stall[i] = stall;
    this.stallKey[i] = stallKey;
    lotCars++;
    return car;
  }

  /// Parks a car at kerb [slot] of road [edge], on [side] (D17 step 2).
  int parkKerb(
      {required int building,
      required int edge,
      required int slot,
      required int side,
      required CarOwnerKind ownerKind,
      required int owner,
      required int kind,
      required int variant}) {
    final car = _open(CarWhere.kerb, building, ownerKind, owner, kind, variant);
    if (car < 0) return car;
    final i = SlotPool.slotOf(car);
    this.edge[i] = edge;
    this.slot[i] = slot;
    this.side[i] = side;
    kerbCars++;
    return car;
  }

  /// Takes a car out of the world, still its owner's: nothing could place
  /// it (§7.5 D17 step 5).
  int garage(
      {required int building,
      required CarOwnerKind ownerKind,
      required int owner,
      required int kind,
      required int variant}) {
    final car =
        _open(CarWhere.garaged, building, ownerKind, owner, kind, variant);
    if (car < 0) return car;
    garagedCars++;
    return car;
  }

  /// Takes [car] off its stall, slot or garage and frees its row. A stale
  /// handle removes nothing.
  void remove(int car) {
    if (!pool.isLive(car)) return;
    final i = SlotPool.slotOf(car);
    switch (CarWhere.values[where[i]]) {
      case CarWhere.lot:
        lotCars--;
      case CarWhere.kerb:
        kerbCars--;
      case CarWhere.garaged:
        garagedCars--;
    }
    _unpool(i);
    pool.free(car);
    parkedRev++;
  }

  /// A home pool car of [buildingSlot] for an outbound commute: last in
  /// first out, an unblocked tandem stall first; −1 when the pool is empty.
  ///
  /// The car keeps standing where it is — a pooled car is taken when the
  /// trip is requested, not when it departs — and it keeps its place in the
  /// stack, marked taken, because it still stands in the way of whatever is
  /// behind it. [returnPooled] gives it back. When a tandem stall blocks
  /// every car left in the pool the newest goes anyway: it waits for its
  /// shuffle (§7.5) rather than leaving the home looking as though it had no
  /// car at all.
  int takePooled(int buildingSlot) {
    if (buildingSlot < 0 || buildingSlot >= _poolHead.length) {
      return SlotPool.none;
    }
    final head = _poolHead[buildingSlot];
    var newest = -1;
    for (var i = head; i >= 0; i = poolNext[i]) {
      if (claim[i] != unclaimed) continue;
      if (newest < 0) newest = i;
      if (!_blockedInPool(head, i)) return _take(i);
    }
    return newest < 0 ? SlotPool.none : _take(newest);
  }

  /// Puts [car] back in its building's pool, where it stood: the trip that
  /// took it never ran.
  void returnPooled(int car) {
    if (!pool.isLive(car)) return;
    final i = SlotPool.slotOf(car);
    if (claim[i] != takenClaim) return;
    claim[i] = unclaimed;
    parkedRev++;
  }

  /// Whether [car] still stands in its building's home pool.
  bool isPooled(int car) {
    if (!pool.isLive(car)) return false;
    final i = SlotPool.slotOf(car);
    return ownerKind[i] == CarOwnerKind.homePool.index &&
        claim[i] == unclaimed;
  }

  /// Cars [takePooled] could still hand out at [buildingSlot], newest
  /// first: a walk of the stack, skipping what a trip has taken.
  int pooledCount(int buildingSlot) {
    if (buildingSlot < 0 || buildingSlot >= _poolHead.length) return 0;
    var n = 0;
    for (var i = _poolHead[buildingSlot]; i >= 0; i = poolNext[i]) {
      if (claim[i] == unclaimed) n++;
    }
    return n;
  }

  /// The [n]th car [takePooled] could hand out at [buildingSlot], newest
  /// first, or [SlotPool.none]: for tests and the inspector.
  int pooledAt(int buildingSlot, int n) {
    if (buildingSlot < 0 || buildingSlot >= _poolHead.length) {
      return SlotPool.none;
    }
    var k = 0;
    for (var i = _poolHead[buildingSlot]; i >= 0; i = poolNext[i]) {
      if (claim[i] != unclaimed) continue;
      if (k++ == n) return pool.handleOf(i);
    }
    return SlotPool.none;
  }

  /// Moves [car] from its kerb slot to [slot] of [edge] on [side], where a
  /// relocation put it (a masked slot, a vanished stall: §7.5).
  void moveToKerb(int car, int edge, int slot, int side) {
    if (!pool.isLive(car)) return;
    final i = SlotPool.slotOf(car);
    _leaveWhere(i);
    where[i] = CarWhere.kerb.index;
    kerbCars++;
    this.edge[i] = edge;
    this.slot[i] = slot;
    this.side[i] = side;
    row[i] = -1;
    stall[i] = -1;
    stallKey[i] = 0;
    parkedRev++;
  }

  /// Moves [car] onto [stall] of site [row], keyed [stallKey]: where a site
  /// sync that kept the key put it again (§7.6 row 1).
  void moveToStall(int car, int row, int stall, int stallKey) {
    if (!pool.isLive(car)) return;
    final i = SlotPool.slotOf(car);
    _leaveWhere(i);
    where[i] = CarWhere.lot.index;
    lotCars++;
    this.row[i] = row;
    this.stall[i] = stall;
    this.stallKey[i] = stallKey;
    edge[i] = -1;
    slot[i] = -1;
    parkedRev++;
  }

  /// Takes [car] out of the world where it stands (§7.6 row 3: its site was
  /// demolished, or nothing could place it again).
  void moveToGarage(int car) {
    if (!pool.isLive(car)) return;
    final i = SlotPool.slotOf(car);
    _leaveWhere(i);
    where[i] = CarWhere.garaged.index;
    garagedCars++;
    row[i] = -1;
    stall[i] = -1;
    edge[i] = -1;
    slot[i] = -1;
    parkedRev++;
  }

  /// Every buffer by name into [into], for the allocation test (A13).
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.where'] = where;
    into['$name.ownerKind'] = ownerKind;
    into['$name.kind'] = kind;
    into['$name.variant'] = variant;
    into['$name.side'] = side;
    into['$name.owner'] = owner;
    into['$name.building'] = building;
    into['$name.row'] = row;
    into['$name.stall'] = stall;
    into['$name.stallKey'] = stallKey;
    into['$name.edge'] = edge;
    into['$name.slot'] = slot;
    into['$name.claim'] = claim;
    into['$name.poolNext'] = poolNext;
    into['$name.poolHead'] = _poolHead;
  }

  /// [hash] with every live car's row folded in, in slot order.
  ///
  /// [parkedRev] is left out on purpose: it counts how the cars got where
  /// they are, and a colony resumed from a save reaches the same parking
  /// with a different count (§14.3). The digest is the STATE.
  int digest(int hash) {
    var h = fnv1aU32(hash, pool.liveCount);
    for (var i = 0; i < pool.highWater; i++) {
      if (!pool.isSlotLive(i)) continue;
      h = fnv1aU32(h, i);
      h = fnv1aU32(h, where[i]);
      h = fnv1aU32(h, ownerKind[i]);
      h = fnv1aU32(h, owner[i]);
      h = fnv1aU32(h, building[i]);
      h = fnv1aU32(h, row[i]);
      h = fnv1aU32(h, stall[i]);
      h = fnv1aU32(h, stallKey[i]);
      h = fnv1aU32(h, edge[i]);
      h = fnv1aU32(h, slot[i]);
      h = fnv1aU32(h, side[i]);
      h = fnv1aU32(h, kind[i]);
      h = fnv1aU32(h, variant[i]);
      h = fnv1aU32(h, claim[i]);
    }
    return h;
  }

  // ---- Rows -----------------------------------------------------------------

  /// A new row of [w], with the columns every where shares set and the rest
  /// emptied; [SlotPool.none] when the table is full.
  int _open(CarWhere w, int building, CarOwnerKind ownerKind, int owner,
      int kind, int variant) {
    final car = pool.alloc();
    if (car == SlotPool.none) return car;
    final i = SlotPool.slotOf(car);
    where[i] = w.index;
    this.ownerKind[i] = ownerKind.index;
    this.owner[i] = owner;
    this.building[i] = building;
    this.kind[i] = kind;
    this.variant[i] = variant;
    row[i] = -1;
    stall[i] = -1;
    stallKey[i] = 0;
    edge[i] = -1;
    slot[i] = -1;
    side[i] = 0;
    claim[i] = unclaimed;
    poolNext[i] = -1;
    if (ownerKind == CarOwnerKind.homePool) _push(i);
    parkedRev++;
    return car;
  }

  /// Takes row [i] out of the count of where it stands, leaving [where] to
  /// the caller to set.
  void _leaveWhere(int i) {
    switch (CarWhere.values[where[i]]) {
      case CarWhere.lot:
        lotCars--;
      case CarWhere.kerb:
        kerbCars--;
      case CarWhere.garaged:
        garagedCars--;
    }
  }

  // ---- Home pools -----------------------------------------------------------

  /// Pushes row [i] on top of its building's pool.
  void _push(int i) {
    final b = building[i];
    if (b < 0) return;
    _ensureBuildings(b + 1);
    poolNext[i] = _poolHead[b];
    _poolHead[b] = i;
  }

  /// Takes row [i] off its building's pool, wherever in the stack it is.
  void _unpool(int i) {
    final b = building[i];
    if (b < 0 || b >= _poolHead.length) return;
    var prev = -1;
    for (var k = _poolHead[b]; k >= 0; k = poolNext[k]) {
      if (k == i) {
        if (prev < 0) {
          _poolHead[b] = poolNext[k];
        } else {
          poolNext[prev] = poolNext[k];
        }
        poolNext[i] = -1;
        return;
      }
      prev = k;
    }
  }

  /// Marks row [i] taken and hands it out.
  int _take(int i) {
    claim[i] = takenClaim;
    parkedRev++;
    return pool.handleOf(i);
  }

  /// Whether a car parked in the pool that starts at [head] stands between
  /// row [i] and the drive — a car a trip has already taken included, since
  /// it is still standing there. Pools are one home's cars — two, at most
  /// four — so the walk is short enough to make twice.
  bool _blockedInPool(int head, int i) {
    final t = tandem;
    if (t == null) return false;
    if (where[i] != CarWhere.lot.index) return false;
    final blocker = t.blockerOf(row[i], stall[i]);
    if (blocker < 0) return false;
    for (var k = head; k >= 0; k = poolNext[k]) {
      if (k == i) continue;
      if (where[k] != CarWhere.lot.index) continue;
      if (row[k] == row[i] && stall[k] == blocker) return true;
    }
    return false;
  }

  /// Room for [n] building slots' pool heads, every new one empty.
  void _ensureBuildings(int n) {
    final old = _poolHead.length;
    if (n <= old) return;
    var cap = old == 0 ? 256 : old;
    while (cap < n) {
      cap *= 2;
    }
    _poolHead = Int32List(cap)
      ..fillRange(old, cap, -1)
      ..setRange(0, old, _poolHead);
  }

  void _allocColumns(int n) {
    where = Uint8List(n);
    ownerKind = Uint8List(n);
    kind = Uint8List(n);
    variant = Uint8List(n);
    side = Uint8List(n);
    owner = Int32List(n);
    building = Int32List(n);
    row = Int32List(n);
    stall = Int32List(n);
    stallKey = Int32List(n);
    edge = Int32List(n);
    slot = Int32List(n);
    claim = Int32List(n);
    poolNext = Int32List(n);
  }
}
