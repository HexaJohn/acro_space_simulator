// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The site half of a vehicle's row (docs/plans/t4a-implementation.md §1.2,
/// §1.4; site-access.md §7.4, D49).
///
/// Site elements are a separate id space: no site id ever enters
/// `VehicleTable.elem`. A vehicle inside a site has element −1 and state
/// `VehicleState.onSite`, and where it is lives here — its site row and
/// plan-local site lane — with its `VehicleTable.s` along that lane. A car
/// at the gate, at a throat or backing out keeps its road columns and
/// carries its site phase here too.
///
/// Indexed by vehicle SLOT, alongside the vehicle table, and grown with it
/// ([ensure]); a slot with no site business reads [SitePhase.none] and −1
/// everywhere ([clear]). Typed columns, no objects (§2.1).
library;

import 'dart:typed_data';

import 'traffic_rng.dart';
import 'vehicle_table.dart';

/// Where a vehicle is in its site business. Append-only: the column holds
/// the index, and the digest folds it.
enum SitePhase {
  /// No site business: a plain road vehicle.
  none,

  /// Held at `destS` by the arrival gate, its stall reserved (§7.4 step 4).
  gateHeld,

  /// Bound for a kerb slot ahead on its arrival edge (D17 step 2, §7.5).
  kerbBound,

  /// Inside a site, driving its site leg toward its stall.
  inbound,

  /// The scripted manoeuvre into its stall (§7.4 step 5).
  stallIn,

  /// The scripted manoeuvre out of its stall, departing (§7.4 departure
  /// step 3).
  stallOut,

  /// Inside a site, driving toward its out-join's throat.
  toThroat,

  /// Stopped at the throat, its front `throatStopM` inside the kerb line,
  /// asking `canJoin` (§7.4 departure steps 4–5).
  throatWait,

  /// A home car waiting in its stall for a back-out gap (§7.4 Home
  /// back-out).
  backOutWait,

  /// Reversing down the drive and swinging into its target lane.
  backOut,

  /// Stopped in its target lane to shift into drive (`shiftStopS`).
  shift,
}

/// The site columns, one row per vehicle slot. See the library comment.
class SiteVehicles {
  SiteVehicles(int capacity) {
    _alloc(capacity);
    for (var sl = 0; sl < capacity; sl++) {
      clear(sl);
    }
  }

  /// Its site row (`SiteTable`), plan-local site lane, the site lane its
  /// next hops lead to (a stall's or a join's target), and the join it came
  /// in by or leaves by: −1 when none.
  late Int32List row, lane, target, join;

  /// Leader and follower on its site element: slots, or −1.
  late Int32List sPrev, sNext;

  /// Whoever its parked car belongs to (opaque, with [ownerKind]: slice 3
  /// ports it), or −1.
  late Int32List owner;

  /// Milliseconds refused at the gate or waiting at a throat or for a gap:
  /// what the forced grants and the give-ups count against.
  ///
  /// Milliseconds, not microseconds, because this is the one clock in the
  /// site columns with no bound of its own: a car can be refused its gap for
  /// as long as the street stays busy. An `Int32List` of microseconds wraps
  /// negative after 35.8 minutes, which would disarm the forced grant and
  /// every give-up that reads it at the very moment they are needed most
  /// (traffic_time.dart, "clocks that only count up"). It is added to
  /// through `addClock`, so it never goes backwards either.
  late Int32List waitMs;

  /// The stall, kerb slot or claim unit it holds, or −1.
  late Int32List claim;

  /// [SitePhase] index, and the `CarOwnerKind` index of [owner].
  late Uint8List phase, ownerKind;

  /// Its progress 0..1 along a scripted manoeuvre (stall in or out, the
  /// back-out's reverse and swing).
  late Float32List manU;

  int get capacity => row.length;

  void _alloc(int n) {
    row = Int32List(n);
    lane = Int32List(n);
    target = Int32List(n);
    join = Int32List(n);
    sPrev = Int32List(n);
    sNext = Int32List(n);
    owner = Int32List(n);
    waitMs = Int32List(n);
    claim = Int32List(n);
    phase = Uint8List(n);
    ownerKind = Uint8List(n);
    manU = Float32List(n);
  }

  /// Grows to at least [capacity] rows, as the vehicle table grows: every
  /// row kept, the new ones clear. Never shrinks; allocates nothing when
  /// already big enough, so it may be called every sub-step.
  void ensure(int capacity) {
    final old = row.length;
    if (capacity <= old) return;
    Int32List i32(Int32List a) => Int32List(capacity)..setRange(0, old, a);
    Uint8List u8(Uint8List a) => Uint8List(capacity)..setRange(0, old, a);
    row = i32(row);
    lane = i32(lane);
    target = i32(target);
    join = i32(join);
    sPrev = i32(sPrev);
    sNext = i32(sNext);
    owner = i32(owner);
    waitMs = i32(waitMs);
    claim = i32(claim);
    phase = u8(phase);
    ownerKind = u8(ownerKind);
    manU = Float32List(capacity)..setRange(0, old, manU);
    for (var sl = old; sl < capacity; sl++) {
      clear(sl);
    }
  }

  /// [slot] with no site business: [SitePhase.none], −1 in every index
  /// column, zero time and progress. Whatever it held (a stall, a claim, a
  /// place on a site list) is its holder's to release first.
  void clear(int slot) {
    row[slot] = -1;
    lane[slot] = -1;
    target[slot] = -1;
    join[slot] = -1;
    sPrev[slot] = -1;
    sNext[slot] = -1;
    owner[slot] = -1;
    waitMs[slot] = 0;
    claim[slot] = -1;
    phase[slot] = 0;
    ownerKind[slot] = 0;
    manU[slot] = 0;
  }

  /// Every buffer kept from one sub-step to the next, by name into [into],
  /// for the allocation test (§15.2): none is replaced unless the vehicle
  /// table grows.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.row'] = row;
    into['$name.lane'] = lane;
    into['$name.target'] = target;
    into['$name.join'] = join;
    into['$name.sPrev'] = sPrev;
    into['$name.sNext'] = sNext;
    into['$name.owner'] = owner;
    into['$name.waitMs'] = waitMs;
    into['$name.claim'] = claim;
    into['$name.phase'] = phase;
    into['$name.ownerKind'] = ownerKind;
    into['$name.manU'] = manU;
  }

  /// [hash] with the site columns of every live vehicle of [t] that has
  /// site business folded in, in slot order: handle, then every column,
  /// the progress to its thousandth. A slot in [SitePhase.none] folds
  /// nothing, so a colony with no site traffic digests as before.
  int digest(int hash, VehicleTable t) {
    var h = hash;
    final hw = t.highWater < row.length ? t.highWater : row.length;
    for (var sl = 0; sl < hw; sl++) {
      if (!t.isSlotLive(sl) || phase[sl] == 0) continue;
      h = fnv1aU32(h, t.handleOf(sl));
      h = fnv1aU32(h, phase[sl] | ownerKind[sl] << 8);
      h = fnv1aU32(h, row[sl]);
      h = fnv1aU32(h, lane[sl]);
      h = fnv1aU32(h, target[sl]);
      h = fnv1aU32(h, join[sl]);
      h = fnv1aU32(h, sPrev[sl]);
      h = fnv1aU32(h, sNext[sl]);
      h = fnv1aU32(h, owner[sl]);
      h = fnv1aU32(h, waitMs[sl]);
      h = fnv1aU32(h, claim[sl]);
      h = fnv1aU32(h, (manU[sl] * 1000).round());
    }
    return h;
  }
}
