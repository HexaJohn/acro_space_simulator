// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The cars that are parked: on a lot stall, at a kerb slot, or garaged
/// (docs/plans/t4a-implementation.md §1.7; site-access.md §7.5, §14.1).
///
/// STUB (P0). Package D implements it; until then every method throws.
///
/// The contract D builds to:
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
library;

import 'dart:typed_data';

import 'slot_pool.dart';

/// Where a parked car sits. The SAVE INDEX: append-only (§14.1).
enum CarWhere { lot, kerb, garaged }

/// Whose car it is, opaquely. Append-only; slice 3 appends `citizen`.
enum CarOwnerKind { none, commuter, homePool }

/// The parked cars. See the library comment.
class ParkedCarTable {
  ParkedCarTable({int capacity = 16384}) : pool = SlotPool(capacity) {
    where = Uint8List(capacity);
    ownerKind = Uint8List(capacity);
    kind = Uint8List(capacity);
    variant = Uint8List(capacity);
    side = Uint8List(capacity);
    owner = Int32List(capacity);
    building = Int32List(capacity);
    row = Int32List(capacity);
    stall = Int32List(capacity);
    stallKey = Int32List(capacity);
    edge = Int32List(capacity);
    slot = Int32List(capacity);
    claim = Int32List(capacity);
    poolNext = Int32List(capacity);
  }

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

  /// Parks a car on [stall] of site [row] of [building], keyed by
  /// [stallKey]. Returns its handle.
  int parkLot(
          {required int building,
          required int row,
          required int stall,
          required int stallKey,
          required CarOwnerKind ownerKind,
          required int owner,
          required int kind,
          required int variant}) =>
      throw UnimplementedError('T4a D: ParkedCarTable.parkLot');

  /// Parks a car at kerb [slot] of road [edge], on [side] (D17 step 2).
  int parkKerb(
          {required int building,
          required int edge,
          required int slot,
          required int side,
          required CarOwnerKind ownerKind,
          required int owner,
          required int kind,
          required int variant}) =>
      throw UnimplementedError('T4a D: ParkedCarTable.parkKerb');

  /// Takes a car out of the world, still its owner's: nothing could place
  /// it (§7.5 D17 step 5).
  int garage(
          {required int building,
          required CarOwnerKind ownerKind,
          required int owner,
          required int kind,
          required int variant}) =>
      throw UnimplementedError('T4a D: ParkedCarTable.garage');

  /// Takes [car] off its stall, slot or garage and frees its row.
  void remove(int car) =>
      throw UnimplementedError('T4a D: ParkedCarTable.remove');

  /// A home pool car of [buildingSlot] for an outbound commute: last in
  /// first out, an unblocked tandem stall first; −1 when the pool is empty.
  int takePooled(int buildingSlot) =>
      throw UnimplementedError('T4a D: ParkedCarTable.takePooled');

  /// Every buffer by name into [into], for the allocation test (A13).
  void collectBuffers(Map<String, Object> into, String name) =>
      throw UnimplementedError('T4a D: ParkedCarTable.collectBuffers');

  /// [hash] with every live car's row folded in, in slot order.
  int digest(int hash) =>
      throw UnimplementedError('T4a D: ParkedCarTable.digest');
}
