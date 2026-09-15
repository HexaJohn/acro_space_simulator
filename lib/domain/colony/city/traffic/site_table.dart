// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The site networks traffic drives: one row per building with a plan, its
/// stalls, its site elements and its next hops
/// (docs/plans/t4a-implementation.md §1.2, §1.3; site-access.md §7.5, §7.6,
/// §7.8 item 2, D49).
///
/// STUB (P0). Package B implements it; until then every method throws and
/// the facade calls none of them.
///
/// The contract B builds to:
///
/// - **Rows.** A row per building slot whose plan traffic has synced, from
///   [SiteTable.rows]. The row keeps the plan and its [SiteLaneGraph] by
///   reference (sync-time objects), the plan's `rev`, the book slot (the
///   wire ordinal), `lotCap = stallCount` (0 for kerbside) and `lotUsed`
///   (parked cars plus binding reservations, §7.5), and the offsets of its
///   stalls, stall orders, hops and elements in the flat columns below.
/// - **Sync on `sitesRev`, never on `graphRev`** ([SiteTable.needsSync],
///   [SiteTable.sync]). A changed `rev` renumbers the row's site elements
///   (`elemBase[row] + planLocalLane`) and tells the [SiteChangeSink] which
///   §7.6 case applies; the caller then relinks the site mover. A row whose
///   plan went, but that cars still use, stays in LIMBO on its old immutable
///   chunk and is freed by [SiteTable.endStep] once empty. A plan that is
///   not current reads kerbside for new arrivals only (§0 Q5).
/// - **Stalls.** Per stall a binding reservation (vehicle handle) and a
///   parked car, −1 when free, with a bitmap of both; per in-join the
///   stall order (by site path length from the join's in-lane, ties by
///   index; on a home tandem pad deepest first).
/// - **Hops.** `hop[hopBase + t * laneCount + lane]` is the next site lane
///   toward target `t` (a stall's lane or an out-join's out-lane), −1 when
///   unreachable, by a BFS over the plan's links without road links.
/// - **sharedSingle units.** Per claim unit, the claiming handle, the
///   direction and the claimer count (§7.4).
///
/// Everything a sub-step reads is allocation-free; a sync allocates.
library;

import 'dart:typed_data';

import '../site_access/site_access_plan.dart';
import '../site_access/site_lane_graph.dart';
import 'building_table.dart';
import 'lane_graph.dart';
import 'site_plan_source.dart';
import 'slot_pool.dart';

/// Bits of [SiteTable.rowFlags]: the row is in use ([kRowLive]); its plan
/// went but cars still use it ([kRowLimbo]); its plan is not current for
/// the graph, so new arrivals read it kerbside ([kRowNotCurrent]).
const int kRowLive = 1;
const int kRowLimbo = 2;
const int kRowNotCurrent = 4;

/// Told what a site sync changed under the vehicles and parked cars
/// (site-access.md §7.6). Implemented by the facade (package E).
abstract interface class SiteChangeSink {
  /// §7.6 row 1: the plan of [oldRow]'s building changed `rev` with its
  /// joins unchanged; its new row is [newRow]. Snap the movers inside it,
  /// remap parked cars by `stallKey`.
  void siteRevChanged(int oldRow, int newRow);

  /// §7.6 row 2: a join of [oldRow]'s plan lost its in or out role, or the
  /// plan became kerbside; [newRow] is its new row, or −1 when it has no
  /// network row now (kerbside).
  void siteLostRole(int oldRow, int newRow);

  /// §7.6 row 3: [oldRow]'s building was demolished or cleared. Its movers
  /// go to limbo on the old plan; its parked cars are garaged.
  void siteGone(int oldRow);
}

/// The synced site networks. See the library comment.
class SiteTable {
  SiteTable({int capacity = 256}) : rows = SlotPool(capacity) {
    plan = List<SiteAccessPlan?>.filled(capacity, null);
    lanes = List<SiteLaneGraph?>.filled(capacity, null);
    building = Int32List(capacity);
    rev = Int32List(capacity);
    bookSlot = Int32List(capacity);
    lotCap = Int32List(capacity);
    lotUsed = Int32List(capacity);
    elemBase = Int32List(capacity);
    laneCount = Int32List(capacity);
    stallBase = Int32List(capacity);
    orderBase = Int32List(capacity);
    hopBase = Int32List(capacity);
    targetCount = Int32List(capacity);
    inside = Int32List(capacity);
    rowFlags = Uint8List(capacity);
    stallRes = Int32List(0);
    stallCar = Int32List(0);
    stallBits = Uint32List(0);
    stallOrder = Int32List(0);
    elemLen = Float32List(0);
    elemVmax = Float32List(0);
    elemRow = Int32List(0);
    elemHead = Int32List(0);
    elemTail = Int32List(0);
    elemCount = Int32List(0);
    elemUnit = Int32List(0);
    hop = Int32List(0);
    targetLane = Int32List(0);
    unitClaimH = Int32List(0);
    unitClaimDir = Uint8List(0);
    unitClaimers = Int16List(0);
  }

  /// The rows and their generations.
  final SlotPool rows;

  /// Per row: the plan view and its site lane graph (sync-time objects,
  /// held by reference; a limbo row keeps its old ones).
  late List<SiteAccessPlan?> plan;
  late List<SiteLaneGraph?> lanes;

  /// Per row: the building slot; the plan's `rev`; the book slot (the wire
  /// ordinal); `lotCap` and `lotUsed` (§7.5); the first site element and the
  /// plan's lane count; the offsets of its stalls, stall orders and hops;
  /// its hop targets; the vehicles inside it.
  late Int32List building,
      rev,
      bookSlot,
      lotCap,
      lotUsed,
      elemBase,
      laneCount,
      stallBase,
      orderBase,
      hopBase,
      targetCount,
      inside;

  /// Per row: [kRowLive] | [kRowLimbo] | [kRowNotCurrent].
  late Uint8List rowFlags;

  /// Per stall (`stallBase[row] + stall`): the reserving vehicle's handle
  /// and the parked car, −1 when none.
  late Int32List stallRes, stallCar;

  /// The stall bitmap, 32 stalls a word by global stall index: a bit set
  /// for a car OR a binding reservation.
  late Uint32List stallBits;

  /// Per in-join (`orderBase[row] + join * stallCount + i`): stall indices by
  /// site path length from the join's in-lane, ties by index; a home tandem
  /// pad deepest first.
  late Int32List stallOrder;

  /// Per site element (`elemBase[row] + lane`): length (m), speed cap (m/s),
  /// its row, its list head, tail and count (vehicle slots, −1), and its
  /// `sharedSingle` claim unit (−1 for none).
  late Float32List elemLen, elemVmax;
  late Int32List elemRow, elemHead, elemTail, elemCount, elemUnit;

  /// `hop[hopBase[row] + t * laneCount[row] + lane]`: the next site lane
  /// toward target `t`, −1 when unreachable. [targetLane] holds each row's
  /// targets' site lanes, [targetCount] of them a row (B lays out its
  /// offset).
  late Int32List hop, targetLane;

  /// Per `sharedSingle` claim unit: the claiming handle (−1), its direction,
  /// and how many hold it.
  late Int32List unitClaimH;
  late Uint8List unitClaimDir;
  late Int16List unitClaimers;

  /// The source's `sitesRev` at the last [sync]; −1 before the first.
  int get syncedSitesRev => -1;

  /// The row of building slot [buildingSlot], or −1 with none.
  int rowOfBuilding(int buildingSlot) =>
      throw UnimplementedError('T4a B: SiteTable.rowOfBuilding');

  /// Whether [src] or the lane graph [lg] moved since the last [sync]:
  /// `sitesRev`, a chunk's identity, or the graph object.
  bool needsSync(SitePlanSource src, LaneGraph? lg) =>
      throw UnimplementedError('T4a B: SiteTable.needsSync');

  /// Brings the rows up to date with [src] for the buildings of [b] on
  /// [lg], telling [sink] each §7.6 case. Allocates; never in a sub-step's
  /// hot path.
  void sync(SitePlanSource src, BuildingTable b, LaneGraph? lg,
          SiteChangeSink sink) =>
      throw UnimplementedError('T4a B: SiteTable.sync');

  /// The first stall in [row]'s order for in-join [join] with neither a car
  /// nor a reservation, or −1: full, kerbside or not current.
  int firstFreeStall(int row, int join) =>
      throw UnimplementedError('T4a B: SiteTable.firstFreeStall');

  /// Reserves [stall] of [row] for vehicle [vehicle] (a handle), bindingly
  /// (D17); false when it is taken.
  bool reserve(int row, int stall, int vehicle) =>
      throw UnimplementedError('T4a B: SiteTable.reserve');

  /// Drops the reservation on [stall] of [row].
  void unreserve(int row, int stall) =>
      throw UnimplementedError('T4a B: SiteTable.unreserve');

  /// Parks car [car] on [stall] of [row] (its reservation, if any, becomes
  /// the car).
  void occupy(int row, int stall, int car) =>
      throw UnimplementedError('T4a B: SiteTable.occupy');

  /// Empties [stall] of [row] of its car.
  void vacate(int row, int stall) =>
      throw UnimplementedError('T4a B: SiteTable.vacate');

  /// The hop target index of [stall] of [row], and of out-join [join].
  int stallTarget(int row, int stall) =>
      throw UnimplementedError('T4a B: SiteTable.stallTarget');
  int joinTarget(int row, int join) =>
      throw UnimplementedError('T4a B: SiteTable.joinTarget');

  /// The site lane after [lane] toward [target] in [row], or −1. The site
  /// mover's hot path: allocation-free.
  int nextLane(int row, int lane, int target) =>
      throw UnimplementedError('T4a B: SiteTable.nextLane');

  /// The stall of [row] whose key is [key], or −1 when gone (§7.5: parked
  /// cars follow their key across a `rev`).
  int stallIndexOfKey(int row, int key) =>
      throw UnimplementedError('T4a B: SiteTable.stallIndexOfKey');

  /// End of a sub-step: frees every limbo row nobody is inside any more.
  void endStep() => throw UnimplementedError('T4a B: SiteTable.endStep');

  /// Every buffer by name into [into], for the allocation test (A13).
  void collectBuffers(Map<String, Object> into, String name) =>
      throw UnimplementedError('T4a B: SiteTable.collectBuffers');

  /// [hash] with every live row's `rev`, stall bitmap and reservation owners
  /// folded in (§7.8 item 11).
  int digest(int hash) => throw UnimplementedError('T4a B: SiteTable.digest');
}
