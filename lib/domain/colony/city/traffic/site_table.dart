// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The site networks traffic drives: one row per building with a plan, its
/// stalls, its site elements and its next hops
/// (docs/plans/t4a-implementation.md §1.2, §1.3; site-access.md §7.5, §7.6,
/// §7.8 item 2, D49).
///
/// - **Rows.** A row per building slot whose plan traffic has synced, from
///   [SiteTable.rows]. The row keeps the plan and its [SiteLaneGraph] by
///   reference (sync-time objects), the plan's `rev`, the book slot (the
///   wire ordinal), `lotCap = stallCount` and `lotUsed` (parked cars plus
///   binding reservations, §7.5), and the offsets of its stalls, stall
///   orders, hops and elements in the flat columns below. A plan with no
///   network — a kerbside plan — gets NO row: §7.6 row 2 says so in as many
///   words, and `rowOfBuilding` answering −1 is what the arrival gate reads
///   as "no stalls here, go to D17 step 2".
/// - **Sync on `sitesRev`, never on `graphRev`** ([SiteTable.needsSync],
///   [SiteTable.sync]). A changed `rev` opens a NEW row and puts the old one
///   in LIMBO, so the [SiteChangeSink] can read both at once: the old row
///   still holds the parked cars and the lanes their movers are on, the new
///   row holds the plan they are moving to. Site elements are renumbered on
///   every sync (`elemBase[row] + planLocalLane`), so the caller relinks the
///   site mover after one. A limbo row is freed by [SiteTable.endStep] once
///   nobody is inside it. A plan that is not current reads kerbside for new
///   arrivals only (§0 Q5): [kRowNotCurrent], `lotCap` 0, and the cars
///   already inside keep driving the old immutable chunk.
/// - **Stalls.** Per stall a binding reservation (vehicle handle) and a
///   parked car, −1 when free, with a bitmap of both; per join the stall
///   order (by site path length from the join's in-lane, ties by index; on a
///   home pad deepest first, which is §7.5's tandem rule).
/// - **Hops.** `hop[hopBase + t * laneCount + lane]` is the next site lane
///   toward target `t`, the lane itself once the car is on a lane that
///   reaches it, and −1 when the target is unreachable. Targets are the
///   stalls and then the out-joins; the routing is a breadth-first walk of
///   the plan's links WITHOUT road links, because a road link means leaving
///   by the public road and coming back through a gate (§2.5).
/// - **sharedSingle units.** A maximal chain of `sharedSingle` segments —
///   on a home drive, `K→H→P` — is one claim unit, held whole and one
///   direction at a time (§7.4).
///
/// Everything a sub-step reads is allocation-free; a sync allocates.
library;

import 'dart:typed_data';

import '../site_access/site_access_constants.dart';
import '../site_access/site_access_plan.dart';
import '../site_access/site_lane_graph.dart';
import 'building_table.dart';
import 'lane_graph.dart';
import 'site_geometry.dart';
import 'site_plan_source.dart';
import 'slot_pool.dart';
import 'traffic_rng.dart';

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

/// What a sync decided about one row, held until the new layout stands so
/// the sink can read the old row and the new one together.
const int _pendRev = 0, _pendLostRole = 1, _pendGone = 2;

/// The synced site networks. See the library comment.
class SiteTable {
  SiteTable({int capacity = 256}) : rows = SlotPool(capacity) {
    _allocRows(capacity);
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

  /// Per row, the offsets §1.3 left to B to lay out: the plan's stall count
  /// (which `lotCap` is NOT, once a row is limbo or not current), and the
  /// first entry of the row in [targetLane], [unitClaimH] and friends, with
  /// how many claim units it has.
  late Int32List stallCount, targetBase, unitBase, unitCount;

  /// Per row: [kRowLive] | [kRowLimbo] | [kRowNotCurrent].
  late Uint8List rowFlags;

  /// Per stall (`stallBase[row] + stall`): the reserving vehicle's handle
  /// and the parked car, −1 when none.
  late Int32List stallRes, stallCar;

  /// The stall bitmap, 32 stalls a word by global stall index: a bit set
  /// for a car OR a binding reservation.
  late Uint32List stallBits;

  /// Per join (`orderBase[row] + join * stallCount + i`): stall indices by
  /// site path length from the join's in-lane, ties by index; a home pad
  /// deepest first. A join a car cannot come in by is still filled, in plain
  /// index order, so no caller has to check before it reads.
  late Int32List stallOrder;

  /// Per site element (`elemBase[row] + lane`): length (m), speed cap (m/s),
  /// its row, its list head, tail and count (vehicle slots, −1), and its
  /// `sharedSingle` claim unit (a GLOBAL unit index, −1 for none).
  late Float32List elemLen, elemVmax;
  late Int32List elemRow, elemHead, elemTail, elemCount, elemUnit;

  /// `hop[hopBase[row] + t * laneCount[row] + lane]`: the next site lane
  /// toward target `t`, −1 when unreachable. [targetLane] holds each row's
  /// targets' site lanes, [targetCount] of them a row from [targetBase].
  late Int32List hop, targetLane;

  /// Per `sharedSingle` claim unit: the claiming handle (−1), its direction,
  /// and how many hold it.
  late Int32List unitClaimH;
  late Uint8List unitClaimDir;
  late Int16List unitClaimers;

  /// Building slot → row, −1 with none.
  Int32List _rowOfBuilding = Int32List(0);

  /// What this sync saw, so rows nobody claimed are the demolished ones.
  Int32List _seen = Int32List(0);

  /// 1 where the row's content must be derived afresh rather than carried
  /// over from the last layout.
  Uint8List _fresh = Uint8List(0);

  /// The new layout, laid out before anything is filled: the totals decide
  /// the buffer sizes, and the old bases must stay readable while rows that
  /// did not change are copied across.
  Int32List _nElemBase = Int32List(0),
      _nStallBase = Int32List(0),
      _nOrderBase = Int32List(0),
      _nTargetBase = Int32List(0),
      _nHopBase = Int32List(0),
      _nUnitBase = Int32List(0),
      _nLaneCount = Int32List(0),
      _nTargetCount = Int32List(0),
      _nUnitCount = Int32List(0),
      _nStallCount = Int32List(0);

  /// The §7.6 cases this sync found, told to the sink once the new layout
  /// stands: kind, the old row and the new one.
  Int32List _pendKind = Int32List(0),
      _pendOld = Int32List(0),
      _pendNew = Int32List(0);
  int _pendCount = 0;

  // Sync scratch, grown to the widest plan seen and then reused.
  Int32List _revStart = Int32List(0),
      _revTo = Int32List(0),
      _queue = Int32List(0),
      _step = Int32List(0),
      _segUnit = Int32List(0),
      _nodeDeg = Int32List(0),
      _nodeA = Int32List(0),
      _nodeB = Int32List(0);
  Float64List _cost = Float64List(0), _key = Float64List(0);
  Uint8List _done = Uint8List(0);

  final List<SiteAccessChunk?> _chunk = <SiteAccessChunk?>[];
  int _chunkCount = 0;
  LaneGraph? _lg;
  int _syncedSitesRev = -1;
  int _stamp = 0;

  /// Syncs run, and rows opened, retired to limbo and freed, since the table
  /// was made: what the counters and the tests read.
  int syncs = 0, rowsOpened = 0, rowsLimboed = 0, rowsFreed = 0;

  /// The source's `sitesRev` at the last [sync]; −1 before the first.
  int get syncedSitesRev => _syncedSitesRev;

  /// Walk `0 <= row < highWater` for every row, in slot order.
  int get highWater => rows.highWater;

  /// Whether [row] is a row at all.
  bool isRowLive(int row) =>
      row >= 0 && row < rows.highWater && rows.isSlotLive(row);

  /// The row of building slot [buildingSlot], or −1 with none.
  int rowOfBuilding(int buildingSlot) =>
      buildingSlot >= 0 && buildingSlot < _rowOfBuilding.length
          ? _rowOfBuilding[buildingSlot]
          : -1;

  /// Whether [src] or the lane graph [lg] moved since the last [sync]:
  /// `sitesRev`, a chunk's identity, or the graph object.
  ///
  /// The book hands out a new list VIEW on every read, so the chunks are
  /// compared element by element; the list object says nothing.
  bool needsSync(SitePlanSource src, LaneGraph? lg) {
    if (_syncedSitesRev != src.sitesRev) return true;
    if (!identical(lg, _lg)) return true;
    final cs = src.chunks;
    if (cs.length != _chunkCount) return true;
    for (var i = 0; i < _chunkCount; i++) {
      if (!identical(cs[i], _chunk[i])) return true;
    }
    return false;
  }

  /// Brings the rows up to date with [src] for the buildings of [b] on
  /// [lg], telling [sink] each §7.6 case. Allocates; never in a sub-step's
  /// hot path.
  void sync(SitePlanSource src, BuildingTable b, LaneGraph? lg,
      SiteChangeSink sink) {
    syncs++;
    _stamp++;
    _pendCount = 0;
    if (_rowOfBuilding.length < b.capacity) {
      final was = _rowOfBuilding;
      _rowOfBuilding = Int32List(b.capacity)..fillRange(0, b.capacity, -1);
      _rowOfBuilding.setRange(0, was.length, was);
    }
    _fresh.fillRange(0, _fresh.length, 0);

    // 1. What each built site's row must become. The plan views allocate,
    //    which is why this runs on a site change and not in a sub-step.
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      _syncBuilding(src, b, lg, sl);
    }

    // 2. Rows nobody claimed: their building was demolished or cleared.
    for (var r = 0; r < rows.highWater; r++) {
      if (!rows.isSlotLive(r)) continue;
      if (rowFlags[r] & kRowLimbo != 0 || _seen[r] == _stamp) continue;
      final bs = building[r];
      if (bs >= 0 && bs < _rowOfBuilding.length && _rowOfBuilding[bs] == r) {
        _rowOfBuilding[bs] = -1;
      }
      _toLimbo(r);
      _pend(_pendGone, r, -1);
    }

    // 3. The new layout, then the contents: derived for the rows that
    //    changed, carried across for the rows that did not.
    _layout();
    _fill();

    // 4. Only now is both halves of every §7.6 case readable at once.
    for (var i = 0; i < _pendCount; i++) {
      final old = _pendOld[i], made = _pendNew[i];
      switch (_pendKind[i]) {
        case _pendRev:
          sink.siteRevChanged(old, made);
        case _pendLostRole:
          sink.siteLostRole(old, made);
        default:
          sink.siteGone(old);
      }
    }

    _syncedSitesRev = src.sitesRev;
    _lg = lg;
    _rememberChunks(src);
  }

  /// The first stall in [row]'s order for in-join [join] with neither a car
  /// nor a reservation, or −1: full, kerbside, not current, or no way in.
  ///
  /// A join with no LANE behind it answers nothing. [stallOrder] is filled
  /// for every join of the plan so a read never has to check first, but
  /// [_orders] puts a block in drive order only where an in-lane stands
  /// behind the join; the rest are left in plain index order, whose "first"
  /// stall is the first stall of no approach at all. Handing one back would
  /// give a caller that forgot to ask the plan a BINDING reservation at a
  /// gate no car can drive through — which is what R8's alley-backed plan
  /// invites: its street frontage is a kerbside `SiteJoinRole.none` join
  /// that exists to be a shopfront (site-access §2.3, §2.4 V4), and the lot
  /// fills from the alley alone (agent-traffic §3.10). The role is refused
  /// with it, so a roleless join that somehow carried a lane is refused too.
  ///
  /// What is NOT refused is an out-capable join that lost its in role: the
  /// stalls are still there and the GATE is what turns a car away (§7.6's
  /// lost-role case). A join past the plan's own joins has no order block at
  /// all — its offset runs into the next row's.
  int firstFreeStall(int row, int join) {
    if (!isRowLive(row)) return -1;
    if (rowFlags[row] & (kRowLimbo | kRowNotCurrent) != 0) return -1;
    final n = lotCap[row];
    if (n <= 0 || join < 0) return -1;
    final p = plan[row], g = lanes[row];
    if (p == null || g == null || join >= p.joinCount) return -1;
    if (g.inLane(join) < 0) return -1;
    if (!p.joinCanIn(join) && !p.joinCanOut(join)) return -1;
    final o = orderBase[row] + join * stallCount[row];
    final base = stallBase[row];
    for (var i = 0; i < n; i++) {
      final s = stallOrder[o + i];
      if (stallRes[base + s] < 0 && stallCar[base + s] < 0) return s;
    }
    return -1;
  }

  /// Reserves [stall] of [row] for vehicle [vehicle] (a handle), bindingly
  /// (D17); false when it is taken.
  bool reserve(int row, int stall, int vehicle) {
    final i = _stallIndex(row, stall);
    if (i < 0 || stallRes[i] >= 0 || stallCar[i] >= 0) return false;
    stallRes[i] = vehicle;
    _setBit(i);
    lotUsed[row]++;
    return true;
  }

  /// Drops the reservation on [stall] of [row].
  void unreserve(int row, int stall) {
    final i = _stallIndex(row, stall);
    if (i < 0 || stallRes[i] < 0) return;
    stallRes[i] = -1;
    if (stallCar[i] < 0) {
      _clearBit(i);
      lotUsed[row]--;
    }
  }

  /// Parks car [car] on [stall] of [row] (its reservation, if any, becomes
  /// the car).
  void occupy(int row, int stall, int car) {
    final i = _stallIndex(row, stall);
    if (i < 0) return;
    if (stallRes[i] < 0 && stallCar[i] < 0) lotUsed[row]++;
    stallRes[i] = -1;
    stallCar[i] = car;
    _setBit(i);
  }

  /// Empties [stall] of [row] of its car.
  void vacate(int row, int stall) {
    final i = _stallIndex(row, stall);
    if (i < 0 || stallCar[i] < 0) return;
    stallCar[i] = -1;
    if (stallRes[i] < 0) {
      _clearBit(i);
      lotUsed[row]--;
    }
  }

  /// Whether [stall] of [row] holds a car or a binding reservation.
  bool stallTaken(int row, int stall) {
    final i = _stallIndex(row, stall);
    return i >= 0 && stallBits[i >> 5] & (1 << (i & 31)) != 0;
  }

  /// The hop target index of [stall] of [row], and of out-join [join]:
  /// stalls are the first targets, in stall order, and the out-capable
  /// joins follow in join order. −1 when there is no such target.
  int stallTarget(int row, int stall) {
    if (!isRowLive(row) || stall < 0 || stall >= stallCount[row]) return -1;
    return stall;
  }

  int joinTarget(int row, int join) {
    if (!isRowLive(row) || join < 0) return -1;
    final g = lanes[row];
    final p = plan[row];
    if (g == null || p == null || join >= p.joinCount) return -1;
    if (!p.joinCanOut(join) || g.outLane(join) < 0) return -1;
    var t = stallCount[row];
    for (var j = 0; j < join; j++) {
      if (p.joinCanOut(j) && g.outLane(j) >= 0) t++;
    }
    return t;
  }

  /// The site lane after [lane] toward [target] in [row], or −1 when the
  /// target cannot be reached from there. A lane that reaches the target
  /// answers ITSELF, so a caller that drives while `nextLane != lane` stops
  /// exactly where the target is and never confuses "arrived" with "gone".
  /// The site mover's hot path: allocation-free, no map, no set.
  int nextLane(int row, int lane, int target) {
    if (row < 0 || row >= rows.highWater || lane < 0 || target < 0) return -1;
    final n = laneCount[row];
    if (lane >= n || target >= targetCount[row]) return -1;
    return hop[hopBase[row] + target * n + lane];
  }

  /// The site lane target [target] of [row] ends on: a stall's entry lane,
  /// or an out-join's out-lane. −1 when there is no such target.
  int laneOfTarget(int row, int target) {
    if (!isRowLive(row) || target < 0 || target >= targetCount[row]) return -1;
    return targetLane[targetBase[row] + target];
  }

  /// The stall of [row] whose key is [key], or −1 when gone (§7.5: parked
  /// cars follow their key across a `rev`).
  int stallIndexOfKey(int row, int key) {
    if (!isRowLive(row)) return -1;
    final p = plan[row];
    if (p == null) return -1;
    return p.stallIndexOfKey(key);
  }

  /// End of a sub-step: frees every limbo row nobody is inside any more.
  void endStep() {
    for (var r = 0; r < rows.highWater; r++) {
      if (!rows.isSlotLive(r)) continue;
      if (rowFlags[r] & kRowLimbo == 0 || inside[r] > 0) continue;
      _freeRow(r);
    }
  }

  /// Every buffer by name into [into], for the allocation test (A13).
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.building'] = building;
    into['$name.rev'] = rev;
    into['$name.bookSlot'] = bookSlot;
    into['$name.lotCap'] = lotCap;
    into['$name.lotUsed'] = lotUsed;
    into['$name.elemBase'] = elemBase;
    into['$name.laneCount'] = laneCount;
    into['$name.stallBase'] = stallBase;
    into['$name.orderBase'] = orderBase;
    into['$name.hopBase'] = hopBase;
    into['$name.targetCount'] = targetCount;
    into['$name.inside'] = inside;
    into['$name.stallCount'] = stallCount;
    into['$name.targetBase'] = targetBase;
    into['$name.unitBase'] = unitBase;
    into['$name.unitCount'] = unitCount;
    into['$name.rowFlags'] = rowFlags;
    into['$name.stallRes'] = stallRes;
    into['$name.stallCar'] = stallCar;
    into['$name.stallBits'] = stallBits;
    into['$name.stallOrder'] = stallOrder;
    into['$name.elemLen'] = elemLen;
    into['$name.elemVmax'] = elemVmax;
    into['$name.elemRow'] = elemRow;
    into['$name.elemHead'] = elemHead;
    into['$name.elemTail'] = elemTail;
    into['$name.elemCount'] = elemCount;
    into['$name.elemUnit'] = elemUnit;
    into['$name.hop'] = hop;
    into['$name.targetLane'] = targetLane;
    into['$name.unitClaimH'] = unitClaimH;
    into['$name.unitClaimDir'] = unitClaimDir;
    into['$name.unitClaimers'] = unitClaimers;
  }

  /// [hash] with every row's `rev`, stall bitmap and reservation owners
  /// folded in, in slot order (§7.8 item 11). A stall's reservation and
  /// parked car ARE its bit, so folding the pair folds the bitmap and says
  /// whose it is; nothing folded depends on where the layout put the row,
  /// so two runs that reached one state by different paths agree.
  ///
  /// A table with no rows folds nothing at all, so a colony without site
  /// plans digests exactly as it did before T4a.
  int digest(int hash) {
    var h = hash;
    var any = false;
    for (var r = 0; r < rows.highWater; r++) {
      if (!rows.isSlotLive(r)) continue;
      any = true;
      h = fnv1aU32(h, rows.handleOf(r));
      h = fnv1aU32(h, rev[r]);
      h = fnv1aU32(h, rowFlags[r]);
      h = fnv1aU32(h, bookSlot[r]);
      h = fnv1aU32(h, lotCap[r]);
      h = fnv1aU32(h, lotUsed[r]);
      final base = stallBase[r], n = stallCount[r];
      for (var i = 0; i < n; i++) {
        h = fnv1aU32(h, stallRes[base + i]);
        h = fnv1aU32(h, stallCar[base + i]);
      }
      final ub = unitBase[r], nu = unitCount[r];
      for (var u = 0; u < nu; u++) {
        h = fnv1aU32(h, unitClaimH[ub + u]);
        h = fnv1aU32(h, unitClaimDir[ub + u] | unitClaimers[ub + u] << 8);
      }
    }
    return any ? h : hash;
  }

  // ---- The sync, building by building -----------------------------------------

  void _syncBuilding(
      SitePlanSource src, BuildingTable b, LaneGraph? lg, int sl) {
    final id = b.siteId[sl];
    final np = src.planOf(id);
    final cur = _rowOfBuilding[sl];
    if (np == null || np.flags & kPlanNetwork == 0) {
      // No stalls to hold: a kerbside plan has no row at all (§7.6 row 2),
      // and a plan that went takes its row to limbo (row 3).
      if (cur < 0) return;
      _rowOfBuilding[sl] = -1;
      _toLimbo(cur);
      _pend(np == null ? _pendGone : _pendLostRole, cur, -1);
      return;
    }
    if (cur < 0) {
      final made = _open(sl, id, np, src, lg);
      _rowOfBuilding[sl] = made;
      return;
    }
    final was = plan[cur];
    if (was != null && rev[cur] == np.rev) {
      // V12's `rev` is a content hash of the geometry, so the same `rev` is
      // the same site down to the centimetre: the stalls, their order and
      // the hops all stand. Only the view is adopted — its graph resolution
      // (`joinRef`, `joinPiece`) may have moved under a re-resolution — and
      // the lane graph only where the chunk itself moved.
      if (!identical(was.chunk, np.chunk) || was.site != np.site) {
        plan[cur] = np;
        lanes[cur] = SiteLaneGraph.of(np);
      }
      bookSlot[cur] = src.slotOf(id);
      _setCurrent(cur, src, id, lg);
      _seen[cur] = _stamp;
      return;
    }
    final made = _open(sl, id, np, src, lg);
    _rowOfBuilding[sl] = made;
    _toLimbo(cur);
    _pend(_lostRole(was, np) ? _pendLostRole : _pendRev, cur, made);
  }

  /// A row for [id]'s new plan [np]: allocated, described, and marked for a
  /// fresh derivation in the fill pass.
  int _open(int buildingSlot, String id, SiteAccessPlan np, SitePlanSource src,
      LaneGraph? lg) {
    var h = rows.alloc();
    if (h == SlotPool.none) {
      _growRows();
      h = rows.alloc();
    }
    final r = SlotPool.slotOf(h);
    plan[r] = np;
    lanes[r] = SiteLaneGraph.of(np);
    building[r] = buildingSlot;
    rev[r] = np.rev;
    bookSlot[r] = src.slotOf(id);
    stallCount[r] = np.stallCount;
    lotUsed[r] = 0;
    inside[r] = 0;
    rowFlags[r] = kRowLive;
    _setCurrent(r, src, id, lg);
    _seen[r] = _stamp;
    _fresh[r] = 1;
    rowsOpened++;
    return r;
  }

  /// [kRowNotCurrent] and the capacity it implies: a plan queued for a check
  /// against the graph the cars drive advertises no stalls, so the arrival
  /// gate reads it kerbside (§0 Q5) while the cars inside it carry on.
  void _setCurrent(int r, SitePlanSource src, String id, LaneGraph? lg) {
    var f = rowFlags[r] & ~kRowNotCurrent;
    if (lg != null && !src.isCurrentFor(id, lg.graph)) f |= kRowNotCurrent;
    rowFlags[r] = f;
    lotCap[r] =
        f & (kRowNotCurrent | kRowLimbo) != 0 ? 0 : stallCount[r];
  }

  /// [r] keeps its plan, its stalls and its lanes, but takes no new car.
  void _toLimbo(int r) {
    if (rowFlags[r] & kRowLimbo != 0) return;
    rowFlags[r] |= kRowLimbo;
    lotCap[r] = 0;
    rowsLimboed++;
  }

  void _freeRow(int r) {
    final base = stallBase[r];
    for (var i = 0; i < stallCount[r]; i++) {
      stallRes[base + i] = -1;
      stallCar[base + i] = -1;
      _clearBit(base + i);
    }
    final ub = unitBase[r];
    for (var u = 0; u < unitCount[r]; u++) {
      unitClaimH[ub + u] = -1;
      unitClaimDir[ub + u] = 0;
      unitClaimers[ub + u] = 0;
    }
    plan[r] = null;
    lanes[r] = null;
    rowFlags[r] = 0;
    lotCap[r] = 0;
    lotUsed[r] = 0;
    inside[r] = 0;
    stallCount[r] = 0;
    targetCount[r] = 0;
    unitCount[r] = 0;
    building[r] = -1;
    rows.free(rows.handleOf(r));
    rowsFreed++;
  }

  /// Whether the joins of [b] lost what [a]'s could do: §7.6 row 2 rather
  /// than row 1. Compared by join SLOT, the identity a join keeps across a
  /// re-plan, never by its index in the plan.
  static bool _lostRole(SiteAccessPlan? a, SiteAccessPlan b) {
    if (a == null) return false;
    for (var j = 0; j < a.joinCount; j++) {
      if (a.joinKind(j) != SiteJoinKind.cut) continue;
      final slot = a.joinSlot(j);
      var at = -1;
      for (var k = 0; k < b.joinCount && at < 0; k++) {
        if (b.joinKind(k) == SiteJoinKind.cut && b.joinSlot(k) == slot) at = k;
      }
      if (at < 0) return true;
      if (a.joinCanIn(j) && !b.joinCanIn(at)) return true;
      if (a.joinCanOut(j) && !b.joinCanOut(at)) return true;
    }
    return false;
  }

  void _pend(int kind, int old, int made) {
    if (_pendCount >= _pendKind.length) {
      final n = _pendCount + 16;
      _pendKind = Int32List(n)..setRange(0, _pendCount, _pendKind);
      _pendOld = Int32List(n)..setRange(0, _pendCount, _pendOld);
      _pendNew = Int32List(n)..setRange(0, _pendCount, _pendNew);
    }
    _pendKind[_pendCount] = kind;
    _pendOld[_pendCount] = old;
    _pendNew[_pendCount] = made;
    _pendCount++;
  }

  void _rememberChunks(SitePlanSource src) {
    final cs = src.chunks;
    while (_chunk.length < cs.length) {
      _chunk.add(null);
    }
    for (var i = 0; i < cs.length; i++) {
      _chunk[i] = cs[i];
    }
    for (var i = cs.length; i < _chunk.length; i++) {
      _chunk[i] = null;
    }
    _chunkCount = cs.length;
  }

  // ---- The layout and the fill --------------------------------------------------

  /// Where every row's stalls, orders, elements, targets, hops and claim
  /// units go in the flat columns. Rows are laid out in SLOT order, so a
  /// sync that changed nothing lays everything out exactly where it was.
  void _layout() {
    var elemT = 0, stallT = 0, orderT = 0, targetT = 0, hopT = 0, unitT = 0;
    for (var r = 0; r < rows.highWater; r++) {
      if (!rows.isSlotLive(r)) continue;
      final p = plan[r];
      if (p == null) {
        _nLaneCount[r] = 0;
        _nStallCount[r] = 0;
        _nTargetCount[r] = 0;
        _nUnitCount[r] = 0;
        _nElemBase[r] = elemT;
        _nStallBase[r] = stallT;
        _nOrderBase[r] = orderT;
        _nTargetBase[r] = targetT;
        _nHopBase[r] = hopT;
        _nUnitBase[r] = unitT;
        continue;
      }
      final nL = 2 * p.segCount;
      final nS = p.stallCount;
      final nT = _fresh[r] == 1 ? nS + _outJoins(r, p) : targetCount[r];
      final nU = _fresh[r] == 1 ? _unitsOf(p) : unitCount[r];
      _nLaneCount[r] = nL;
      _nStallCount[r] = nS;
      _nTargetCount[r] = nT;
      _nUnitCount[r] = nU;
      _nElemBase[r] = elemT;
      _nStallBase[r] = stallT;
      _nOrderBase[r] = orderT;
      _nTargetBase[r] = targetT;
      _nHopBase[r] = hopT;
      _nUnitBase[r] = unitT;
      elemT += nL;
      stallT += nS;
      orderT += p.joinCount * nS;
      targetT += nT;
      hopT += nT * nL;
      unitT += nU;
    }
    _sizeFlat(elemT, stallT, orderT, targetT, hopT, unitT);
  }

  int _outJoins(int r, SiteAccessPlan p) {
    final g = lanes[r];
    if (g == null) return 0;
    var n = 0;
    for (var j = 0; j < p.joinCount; j++) {
      if (p.joinCanOut(j) && g.outLane(j) >= 0) n++;
    }
    return n;
  }

  /// The old flat columns, kept while the new ones are filled from them.
  Int32List _oStallRes = Int32List(0),
      _oStallCar = Int32List(0),
      _oStallOrder = Int32List(0),
      _oElemUnit = Int32List(0),
      _oHop = Int32List(0),
      _oTargetLane = Int32List(0),
      _oUnitClaimH = Int32List(0);
  Float32List _oElemLen = Float32List(0), _oElemVmax = Float32List(0);
  Uint8List _oUnitClaimDir = Uint8List(0);
  Int16List _oUnitClaimers = Int16List(0);

  void _sizeFlat(
      int elemT, int stallT, int orderT, int targetT, int hopT, int unitT) {
    _oStallRes = stallRes;
    _oStallCar = stallCar;
    _oStallOrder = stallOrder;
    _oElemUnit = elemUnit;
    _oElemLen = elemLen;
    _oElemVmax = elemVmax;
    _oHop = hop;
    _oTargetLane = targetLane;
    _oUnitClaimH = unitClaimH;
    _oUnitClaimDir = unitClaimDir;
    _oUnitClaimers = unitClaimers;
    stallRes = Int32List(stallT);
    stallCar = Int32List(stallT);
    stallBits = Uint32List((stallT + 31) >> 5);
    stallOrder = Int32List(orderT);
    elemLen = Float32List(elemT);
    elemVmax = Float32List(elemT);
    elemRow = Int32List(elemT);
    elemHead = Int32List(elemT)..fillRange(0, elemT, -1);
    elemTail = Int32List(elemT)..fillRange(0, elemT, -1);
    elemCount = Int32List(elemT);
    elemUnit = Int32List(elemT)..fillRange(0, elemT, -1);
    hop = Int32List(hopT)..fillRange(0, hopT, -1);
    targetLane = Int32List(targetT)..fillRange(0, targetT, -1);
    unitClaimH = Int32List(unitT)..fillRange(0, unitT, -1);
    unitClaimDir = Uint8List(unitT);
    unitClaimers = Int16List(unitT);
  }

  /// Every row's content: derived where the plan changed, carried over
  /// where it did not. Carrying over is what keeps a sync proportional to
  /// what moved rather than to the size of the colony — and it is what
  /// keeps a car parked and a claim held through a neighbour's re-plan.
  void _fill() {
    for (var r = 0; r < rows.highWater; r++) {
      if (!rows.isSlotLive(r)) continue;
      final p = plan[r];
      final g = lanes[r];
      if (p == null || g == null) continue;
      if (_fresh[r] == 1) {
        _derive(r, p, g);
      } else {
        _carry(r, p);
      }
    }
    for (var r = 0; r < rows.highWater; r++) {
      if (!rows.isSlotLive(r)) continue;
      laneCount[r] = _nLaneCount[r];
      stallCount[r] = _nStallCount[r];
      targetCount[r] = _nTargetCount[r];
      unitCount[r] = _nUnitCount[r];
      elemBase[r] = _nElemBase[r];
      stallBase[r] = _nStallBase[r];
      orderBase[r] = _nOrderBase[r];
      targetBase[r] = _nTargetBase[r];
      hopBase[r] = _nHopBase[r];
      unitBase[r] = _nUnitBase[r];
    }
  }

  /// [r]'s content copied from the last layout, with the claim units
  /// re-based: a unit is a global index, so it moves with the row.
  void _carry(int r, SiteAccessPlan p) {
    final oS = stallBase[r], nS = _nStallBase[r], n = stallCount[r];
    for (var i = 0; i < n; i++) {
      final res = _oStallRes[oS + i], car = _oStallCar[oS + i];
      stallRes[nS + i] = res;
      stallCar[nS + i] = car;
      if (res >= 0 || car >= 0) _setBit(nS + i);
    }
    final nOrder = p.joinCount * n;
    stallOrder.setRange(
        _nOrderBase[r], _nOrderBase[r] + nOrder, _oStallOrder, orderBase[r]);
    final oE = elemBase[r], nE = _nElemBase[r], nL = laneCount[r];
    final shift = _nUnitBase[r] - unitBase[r];
    for (var l = 0; l < nL; l++) {
      elemLen[nE + l] = _oElemLen[oE + l];
      elemVmax[nE + l] = _oElemVmax[oE + l];
      elemRow[nE + l] = r;
      final u = _oElemUnit[oE + l];
      elemUnit[nE + l] = u < 0 ? -1 : u + shift;
    }
    final nT = targetCount[r];
    targetLane.setRange(
        _nTargetBase[r], _nTargetBase[r] + nT, _oTargetLane, targetBase[r]);
    hop.setRange(_nHopBase[r], _nHopBase[r] + nT * nL, _oHop, hopBase[r]);
    final oU = unitBase[r], nU = _nUnitBase[r];
    for (var u = 0; u < unitCount[r]; u++) {
      unitClaimH[nU + u] = _oUnitClaimH[oU + u];
      unitClaimDir[nU + u] = _oUnitClaimDir[oU + u];
      unitClaimers[nU + u] = _oUnitClaimers[oU + u];
    }
  }

  /// [r]'s content derived from its plan: elements, claim units, stalls,
  /// hop targets, next hops and stall orders.
  void _derive(int r, SiteAccessPlan p, SiteLaneGraph g) {
    final nL = _nLaneCount[r], nS = _nStallCount[r], nT = _nTargetCount[r];
    final eB = _nElemBase[r], hB = _nHopBase[r], tB = _nTargetBase[r];
    _ensure(nL, g.linkCount, nS, p.nodeCount, p.segCount);

    // Elements. An absent lane keeps its id — the numbering is
    // `elemBase + planLocalLane` (§1.2) — and reads as a zero-length lane
    // nothing can be on.
    _units(p);
    for (var l = 0; l < nL; l++) {
      elemRow[eB + l] = r;
      if (g.present[l] == 0) continue;
      elemLen[eB + l] = SiteGeometry.laneLengthM(p, l);
      elemVmax[eB + l] = SiteGeometry.laneVmax(p, l);
      final u = _segUnit[SiteLaneGraph.segOf(l)];
      elemUnit[eB + l] = u < 0 ? -1 : _nUnitBase[r] + u;
    }

    // Stalls, and the targets: the stalls first, then the out-joins.
    final sB = _nStallBase[r];
    for (var i = 0; i < nS; i++) {
      stallRes[sB + i] = -1;
      stallCar[sB + i] = -1;
      targetLane[tB + i] = _stallEntryLane(p, g, i);
    }
    var t = nS;
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinCanOut(j) || g.outLane(j) < 0) continue;
      targetLane[tB + t] = g.outLane(j);
      t++;
    }

    _reverseLinks(g, nL);
    for (var k = 0; k < nT; k++) {
      _hopsTo(p, g, k, nL, hB, tB, nS);
    }
    _orders(r, p, g, nL, nS);
  }

  /// The lane a car drives up to reach [i]: its segment's forward lane
  /// where the stall may be entered that way, else the backward one. A
  /// stall on a two-way aisle is reachable from both, and [_hopsTo] seeds
  /// the walk with every direction it allows, so this is only which lane
  /// the mover is told to aim at.
  static int _stallEntryLane(SiteAccessPlan p, SiteLaneGraph g, int i) {
    final k = p.stallSeg(i);
    if (k < 0 || k >= p.segCount) return -1;
    final dirs = p.stallInDirs(i);
    final fwd = 2 * k, bwd = 2 * k + 1;
    if (dirs & kSiteDirFwd != 0 && g.present[fwd] == 1) return fwd;
    if (dirs & kSiteDirBwd != 0 && g.present[bwd] == 1) return bwd;
    if (g.present[fwd] == 1) return fwd;
    if (g.present[bwd] == 1) return bwd;
    return -1;
  }

  /// The links of [g] the other way round, road links left out: a next-hop
  /// table is a walk BACKWARD from the target, so every lane learns its one
  /// step toward it in a single pass.
  void _reverseLinks(SiteLaneGraph g, int nL) {
    _revStart.fillRange(0, nL + 1, 0);
    for (var l = 0; l < nL; l++) {
      if (g.present[l] == 0) continue;
      for (var i = g.linkStart[l]; i < g.linkStart[l + 1]; i++) {
        if (g.linkKind[i] == kSiteLinkRoad) continue;
        final b = g.linkTo[i];
        if (g.present[b] == 0) continue;
        _revStart[b + 1]++;
      }
    }
    for (var l = 0; l < nL; l++) {
      _revStart[l + 1] += _revStart[l];
    }
    _step.setRange(0, nL, _revStart);
    for (var l = 0; l < nL; l++) {
      if (g.present[l] == 0) continue;
      for (var i = g.linkStart[l]; i < g.linkStart[l + 1]; i++) {
        if (g.linkKind[i] == kSiteLinkRoad) continue;
        final b = g.linkTo[i];
        if (g.present[b] == 0) continue;
        _revTo[_step[b]++] = l;
      }
    }
  }

  /// `hop[... + t * nL + lane]` for target [t]: a breadth-first walk out of
  /// the target's lanes along the reversed links. Every lane a car may
  /// enter the target from is a source, so a stall a two-way aisle serves
  /// both ways is reached from either lane without a U-turn it does not
  /// need.
  void _hopsTo(SiteAccessPlan p, SiteLaneGraph g, int t, int nL, int hB,
      int tB, int nS) {
    final at = hB + t * nL;
    var head = 0, tail = 0;
    void seed(int lane) {
      if (lane < 0 || g.present[lane] == 0 || hop[at + lane] >= 0) return;
      hop[at + lane] = lane;
      _queue[tail++] = lane;
    }

    if (t < nS) {
      final k = p.stallSeg(t);
      if (k >= 0 && k < p.segCount) {
        final dirs = p.stallInDirs(t);
        if (dirs & kSiteDirFwd != 0) seed(2 * k);
        if (dirs & kSiteDirBwd != 0) seed(2 * k + 1);
        if (tail == 0) seed(targetLane[tB + t]);
      }
    } else {
      seed(targetLane[tB + t]);
    }
    while (head < tail) {
      final b = _queue[head++];
      for (var i = _revStart[b]; i < _revStart[b + 1]; i++) {
        final a = _revTo[i];
        if (hop[at + a] >= 0) continue;
        hop[at + a] = b;
        _queue[tail++] = a;
      }
    }
  }

  /// `stallOrder[join]` for every join: the stalls by how far a car coming
  /// in by that join drives to reach them (§7.4 step 2), ties by index.
  ///
  /// A home pad is ordered the other way — deepest first — because a tandem
  /// pad has to be filled from the back or the outer car blocks the inner
  /// one (§7.5). A side-by-side pad's two stalls are the same distance in,
  /// so the tie by index leaves them in plan order either way.
  void _orders(int r, SiteAccessPlan p, SiteLaneGraph g, int nL, int nS) {
    if (nS == 0) return;
    final deepFirst = p.program == SiteProgram.homeDriveway;
    final oB = _nOrderBase[r];
    for (var j = 0; j < p.joinCount; j++) {
      final at = oB + j * nS;
      for (var i = 0; i < nS; i++) {
        stallOrder[at + i] = i;
      }
      final from = g.inLane(j);
      if (from < 0 || !p.joinCanIn(j)) continue;
      _drive(p, g, nL, from);
      for (var i = 0; i < nS; i++) {
        _key[i] = _reach(p, g, i);
      }
      // Insertion sort: a plan holds at most `kMaxPlanStalls` stalls, this
      // runs once per join at sync, and a stable in-place sort over a typed
      // list costs nothing to read and never allocates a comparator.
      for (var i = 1; i < nS; i++) {
        final v = stallOrder[at + i];
        var k = i - 1;
        while (k >= 0 && _after(stallOrder[at + k], v, deepFirst)) {
          stallOrder[at + k + 1] = stallOrder[at + k];
          k--;
        }
        stallOrder[at + k + 1] = v;
      }
    }
  }

  /// Whether stall [a] belongs after [b]: unreachable stalls last, then by
  /// path length (the far end first on a home pad), then by index.
  bool _after(int a, int b, bool deepFirst) {
    final ka = _key[a], kb = _key[b];
    if (ka.isFinite != kb.isFinite) return !ka.isFinite;
    if (ka != kb) return deepFirst ? ka < kb : ka > kb;
    return a > b;
  }

  /// The driving distance from the start of lane [from] to the start of
  /// every lane, over the plan's links without road links (Dijkstra; a
  /// plan's lanes number in the tens, so the scan for the nearest is
  /// cheaper than a heap and has no tie to break).
  void _drive(SiteAccessPlan p, SiteLaneGraph g, int nL, int from) {
    _cost.fillRange(0, nL, double.infinity);
    _done.fillRange(0, nL, 0);
    _cost[from] = 0;
    for (;;) {
      var best = -1;
      var bestC = double.infinity;
      for (var l = 0; l < nL; l++) {
        if (_done[l] == 1 || _cost[l] >= bestC) continue;
        best = l;
        bestC = _cost[l];
      }
      if (best < 0) return;
      _done[best] = 1;
      final len = p.segLenM(SiteLaneGraph.segOf(best));
      for (var i = g.linkStart[best]; i < g.linkStart[best + 1]; i++) {
        if (g.linkKind[i] == kSiteLinkRoad) continue;
        final b = g.linkTo[i];
        if (g.present[b] == 0) continue;
        final c = bestC + len;
        if (c < _cost[b]) _cost[b] = c;
      }
    }
  }

  /// How far in stall [i] is, along whichever of its in-directions is
  /// nearest; `infinity` when no car can reach it from this join.
  double _reach(SiteAccessPlan p, SiteLaneGraph g, int i) {
    final k = p.stallSeg(i);
    if (k < 0 || k >= p.segCount) return double.infinity;
    final dirs = p.stallInDirs(i);
    final len = p.segLenM(k), s = p.stallS(i);
    var best = double.infinity;
    if (dirs & kSiteDirFwd != 0 && g.present[2 * k] == 1) {
      final c = _cost[2 * k] + s;
      if (c < best) best = c;
    }
    if (dirs & kSiteDirBwd != 0 && g.present[2 * k + 1] == 1) {
      final c = _cost[2 * k + 1] + (len - s);
      if (c < best) best = c;
    }
    return best;
  }

  /// `_segUnit[seg]`: the row-local `sharedSingle` claim unit of every
  /// segment, −1 for a segment that is not one, and the count of them.
  ///
  /// A unit is a maximal chain of `sharedSingle` segments — §7.4's "from the
  /// kerb node to the first two-way or turnaround node", which on a home
  /// drive is `K→H→P`. A node where exactly two such segments meet with no
  /// turnaround is inside a chain; anything else ends it.
  int _units(SiteAccessPlan p) {
    final nSeg = p.segCount, nNode = p.nodeCount;
    _segUnit.fillRange(0, nSeg, -1);
    _nodeDeg.fillRange(0, nNode, 0);
    var any = false;
    for (var k = 0; k < nSeg; k++) {
      if (p.segLaneMode(k) == SiteLaneMode.sharedSingle) {
        _segUnit[k] = k;
        any = true;
      }
      for (var e = 0; e < 2; e++) {
        final n = e == 0 ? p.segFrom(k) : p.segTo(k);
        if (n < 0 || n >= nNode) continue;
        if (_nodeDeg[n] == 0) {
          _nodeA[n] = k;
        } else if (_nodeDeg[n] == 1) {
          _nodeB[n] = k;
        }
        _nodeDeg[n]++;
      }
    }
    if (!any) return 0;
    for (var n = 0; n < nNode; n++) {
      if (_nodeDeg[n] != 2) continue;
      if (p.nodeTurnKind(n) != TurnaroundKind.none) continue;
      final a = _nodeA[n], b = _nodeB[n];
      if (_segUnit[a] < 0 || _segUnit[b] < 0) continue;
      final ra = _root(a), rb = _root(b);
      if (ra < rb) {
        _segUnit[rb] = ra;
      } else if (rb < ra) {
        _segUnit[ra] = rb;
      }
    }
    // Number the chains in the order their lowest segment appears, so the
    // same plan always numbers its units the same way.
    var count = 0;
    for (var k = 0; k < nSeg; k++) {
      if (_segUnit[k] == k) {
        _segUnit[k] = -2 - count;
        count++;
      }
    }
    for (var k = 0; k < nSeg; k++) {
      if (_segUnit[k] >= 0) _segUnit[k] = _segUnit[_root(k)];
    }
    for (var k = 0; k < nSeg; k++) {
      if (_segUnit[k] <= -2) _segUnit[k] = -2 - _segUnit[k];
    }
    return count;
  }

  /// How many claim units [p] has, without keeping the assignment: the
  /// layout has to know the size before the fill writes it.
  int _unitsOf(SiteAccessPlan p) {
    _ensure(2 * p.segCount, 0, p.stallCount, p.nodeCount, p.segCount);
    return _units(p);
  }

  int _root(int k) {
    var r = k;
    while (_segUnit[r] >= 0 && _segUnit[r] != r) {
      r = _segUnit[r];
    }
    return r;
  }

  // ---- Storage ------------------------------------------------------------------

  void _allocRows(int n) {
    plan = List<SiteAccessPlan?>.filled(n, null);
    lanes = List<SiteLaneGraph?>.filled(n, null);
    building = Int32List(n)..fillRange(0, n, -1);
    rev = Int32List(n);
    bookSlot = Int32List(n)..fillRange(0, n, -1);
    lotCap = Int32List(n);
    lotUsed = Int32List(n);
    elemBase = Int32List(n);
    laneCount = Int32List(n);
    stallBase = Int32List(n);
    orderBase = Int32List(n);
    hopBase = Int32List(n);
    targetCount = Int32List(n);
    inside = Int32List(n);
    stallCount = Int32List(n);
    targetBase = Int32List(n);
    unitBase = Int32List(n);
    unitCount = Int32List(n);
    rowFlags = Uint8List(n);
    _seen = Int32List(n);
    _fresh = Uint8List(n);
    _nElemBase = Int32List(n);
    _nStallBase = Int32List(n);
    _nOrderBase = Int32List(n);
    _nTargetBase = Int32List(n);
    _nHopBase = Int32List(n);
    _nUnitBase = Int32List(n);
    _nLaneCount = Int32List(n);
    _nTargetCount = Int32List(n);
    _nUnitCount = Int32List(n);
    _nStallCount = Int32List(n);
  }

  void _growRows() {
    final old = rows.capacity, n = old * 2;
    rows.grow(n);
    final pl = plan, la = lanes;
    final bu = building, rv = rev, bs = bookSlot, lc = lotCap, lu = lotUsed;
    final eb = elemBase, lcn = laneCount, sb = stallBase, ob = orderBase;
    final hb = hopBase, tc = targetCount, ins = inside, sc = stallCount;
    final tb = targetBase, ub = unitBase, uc = unitCount;
    final rf = rowFlags, se = _seen, fr = _fresh;
    _allocRows(n);
    plan.setRange(0, old, pl);
    lanes.setRange(0, old, la);
    building.setRange(0, old, bu);
    rev.setRange(0, old, rv);
    bookSlot.setRange(0, old, bs);
    lotCap.setRange(0, old, lc);
    lotUsed.setRange(0, old, lu);
    elemBase.setRange(0, old, eb);
    laneCount.setRange(0, old, lcn);
    stallBase.setRange(0, old, sb);
    orderBase.setRange(0, old, ob);
    hopBase.setRange(0, old, hb);
    targetCount.setRange(0, old, tc);
    inside.setRange(0, old, ins);
    stallCount.setRange(0, old, sc);
    targetBase.setRange(0, old, tb);
    unitBase.setRange(0, old, ub);
    unitCount.setRange(0, old, uc);
    rowFlags.setRange(0, old, rf);
    _seen.setRange(0, old, se);
    // A grow can happen part way through a sync, and the marks it has made
    // so far say which rows must be derived afresh: they survive it.
    _fresh.setRange(0, old, fr);
  }

  /// Room in the sync scratch for a plan of this size.
  void _ensure(int lanes, int links, int stalls, int nodes, int segs) {
    if (_revStart.length < lanes + 1) {
      _revStart = Int32List(lanes + 1);
      _queue = Int32List(lanes);
      _step = Int32List(lanes);
      _cost = Float64List(lanes);
      _done = Uint8List(lanes);
    }
    if (_revTo.length < links) _revTo = Int32List(links);
    if (_key.length < stalls) _key = Float64List(stalls);
    if (_nodeDeg.length < nodes) {
      _nodeDeg = Int32List(nodes);
      _nodeA = Int32List(nodes);
      _nodeB = Int32List(nodes);
    }
    if (_segUnit.length < segs) _segUnit = Int32List(segs);
  }

  int _stallIndex(int row, int stall) {
    if (!isRowLive(row) || stall < 0 || stall >= stallCount[row]) return -1;
    return stallBase[row] + stall;
  }

  void _setBit(int i) => stallBits[i >> 5] |= 1 << (i & 31);

  void _clearBit(int i) => stallBits[i >> 5] &= ~(1 << (i & 31));
}
