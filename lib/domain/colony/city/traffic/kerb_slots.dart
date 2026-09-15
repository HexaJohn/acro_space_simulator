// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Kerb parking slots along the road (docs/plans/t4a-implementation.md
/// §1.7; site-access.md §7.1, §7.5 D17 step 2).
///
/// - **Slots** are laid out along the RIGHT kerb of every edge that allows
///   kerb parking (§7.1's caps; a one-way street gets both kerbs), from the
///   lane graph and nothing else: they move only when the graph is rebuilt.
/// - **Masks** ([KerbTable.applyMasks]): a slot inside a live plan's cut
///   mask is not a parking place. The mask comes from [KerbMask], which
///   wraps the road side's `KerbCuts.parkingBlocked` — there is no local
///   formula (§0 Q1). Masks are applied again on `sitesRev`, and a car on a
///   slot that became masked relocates, as a car on a vanished stall does:
///   it is put on [KerbTable.relocateCar] for the facade to move.
/// - **Reservations** ([KerbTable.reserveAhead]) are BINDING, as a stall's
///   are: D17 step 2 takes the first unmasked free slot ahead on the arrival
///   edge within `AgentTuning.kerbAheadM`, and the car drives a one-element
///   leg to it. A reserved slot is nobody else's from that moment, so a car
///   never finds its slot taken (§7.3).
///
/// Slots are held in one flat run per edge — the right kerb's ascending,
/// then (one-way only) the left kerb's — so an edge's slots are a contiguous
/// range and every search is a walk of typed columns. A slot's arc is its
/// edge's TRAVEL arc, the frame the vehicles and the access points use; the
/// conversion to the canonical index arc the cuts live in belongs to the
/// mask (§5.5), and happens nowhere else.
library;

import 'dart:typed_data';

import 'kerb_mask.dart';
import 'lane_graph.dart';
import 'site_table.dart';
import 'traffic_rng.dart';
import 'traffic_tuning.dart';

/// §7.1's kerb slots: one every [kKerbSlotPitchM] metres, the first centred
/// [kKerbSlotFirstM] + half a pitch past the stop bar behind, with
/// [kKerbEndClearM] of the edge left clear across the two ends.
const double kKerbSlotPitchM = 6.5;
const double kKerbSlotFirstM = 6.0;
const double kKerbEndClearM = 12.0;

/// The kerb slots. See the library comment.
class KerbTable {
  /// Slots of edge `e` are `_edgeStart[e] .. _edgeStart[e + 1] − 1`, of
  /// which the first `_edgeRight[e]` are on the right kerb of travel and the
  /// rest (a one-way road only) on the left.
  Int32List _edgeStart = Int32List(1);
  Int32List _edgeRight = Int32List(0);

  /// Per slot: its edge, the lane beside it, the car parked on it and the
  /// vehicle that holds it (−1 for none).
  Int32List _edge = Int32List(0),
      _lane = Int32List(0),
      _car = Int32List(0),
      _res = Int32List(0);

  /// Per slot: its travel arc along its edge, metres.
  Float64List _t = Float64List(0);

  /// Per slot: 1 on the right kerb of travel, 0 on the left; 1 while a live
  /// plan's cut masks it.
  Uint8List _side = Uint8List(0), _masked = Uint8List(0);

  /// Cars whose slot became masked under them, for the facade to move.
  Int32List _relocate = Int32List(0);
  int _relocateCount = 0;

  /// The graph the slots are laid out on.
  LaneGraph? _lg;

  /// The site table's `sitesRev` at the last [applyMasks]; −1 before it.
  int _maskedSitesRev = -1;

  /// Slots on every edge together.
  int get slotCount => _edge.length;

  /// The `sitesRev` the masks were taken from; −1 before the first
  /// [applyMasks].
  int get maskedSitesRev => _maskedSitesRev;

  /// Lays the slots out along [lg]'s kerbs (§7.1 caps, the right kerb; a
  /// one-way street's both kerbs). Every slot is new: the caller replaces
  /// the parked cars' slots from their `(edge, t)`.
  void bind(LaneGraph lg) {
    _lg = lg;
    final nE = lg.edgeCount;
    _edgeStart = Int32List(nE + 1);
    _edgeRight = Int32List(nE);
    var total = 0;
    for (var e = 0; e < nE; e++) {
      _edgeStart[e] = total;
      final cap = _capOf(lg, e);
      _edgeRight[e] = cap;
      // A one-way road's single edge owns BOTH kerbs (§7.1); a two-way
      // road's edges own their own right kerb each.
      total += lg.edgeReverse[e] < 0 ? cap * 2 : cap;
    }
    _edgeStart[nE] = total;
    _edge = Int32List(total);
    _lane = Int32List(total);
    _car = Int32List(total)..fillRange(0, total, -1);
    _res = Int32List(total)..fillRange(0, total, -1);
    _t = Float64List(total);
    _side = Uint8List(total);
    _masked = Uint8List(total);
    _relocate = Int32List(total);
    _relocateCount = 0;
    _maskedSitesRev = -1;
    for (var e = 0; e < nE; e++) {
      final cap = _edgeRight[e];
      if (cap == 0) continue;
      final s0 = lg.edgeLaneS0[e] + kKerbSlotFirstM;
      final right = lg.laneOf(e, 0);
      // The left kerb of a one-way road is served by its innermost lane
      // (§7.3 step 2: lane 0 → the right kerb, lane L − 1 → the left).
      final oneWay = lg.edgeReverse[e] < 0;
      final left = lg.laneOf(e, lg.edgeLaneCount[e] - 1);
      var at = _edgeStart[e];
      for (var i = 0; i < cap; i++) {
        _edge[at] = e;
        _t[at] = s0 + (i + 0.5) * kKerbSlotPitchM;
        _side[at] = 1;
        _lane[at] = right;
        at++;
      }
      if (!oneWay) continue;
      for (var i = 0; i < cap; i++) {
        _edge[at] = e;
        _t[at] = s0 + (i + 0.5) * kKerbSlotPitchM;
        _side[at] = 0;
        _lane[at] = left;
        at++;
      }
    }
  }

  /// Masks every slot [mask] blocks for a live plan of [sites] on [lg]
  /// (§7.5). Called again whenever `sitesRev` moves.
  ///
  /// A slot that a cut has just covered, with a car standing on it, puts
  /// that car on the relocation list: the mask is a home back-out's swing
  /// path, and a car left in it would block every departure (§5.5). A
  /// BINDING reservation is not broken — a car on its way keeps the slot it
  /// was promised — but when it parks, [occupy] puts it on the list at once.
  void applyMasks(SiteTable sites, LaneGraph lg, KerbMask mask) {
    final old = _lg;
    // A graph that shares the slots' structure — a refresh of its controls —
    // keeps every edge and lane id, so the slots stand; any other graph is
    // laid out afresh before it is masked.
    if (old != null && lg.sharesStructureWith(old)) {
      _lg = lg;
    } else {
      bind(lg);
    }
    for (var s = 0; s < _edge.length; s++) {
      final blocked = mask.parkingBlocked(_edge[s], _t[s], _side[s] == 1);
      if (blocked && _masked[s] == 0 && _car[s] >= 0) _markRelocate(_car[s]);
      _masked[s] = blocked ? 1 : 0;
    }
    _maskedSitesRev = sites.syncedSitesRev;
  }

  /// Reserves the first free, unmasked slot in [lane] ahead of [fromT]
  /// travel metres, within `AgentTuning.kerbAheadM` on this edge, for
  /// [vehicle] (a handle); −1 when there is none (D17 step 2).
  ///
  /// The kerbs a lane serves are §7.3 step 2's: lane 0 the right kerb, and
  /// on a one-way road lane `L − 1` the left kerb as well — which on a
  /// one-lane one-way street is the same lane serving both.
  int reserveAhead(int lane, double fromT, int vehicle) {
    final lg = _lg;
    if (lg == null || lane < 0 || lane >= lg.laneCount) return -1;
    final e = lg.laneEdge[lane];
    final n = _edgeStart[e + 1] - _edgeStart[e];
    if (n == 0) return -1;
    final k = lg.laneIdx[lane];
    final oneWay = lg.edgeReverse[e] < 0;
    final servesRight = k == 0;
    final servesLeft = oneWay && k == lg.edgeLaneCount[e] - 1;
    final far = fromT + AgentTuning.kerbAheadM;
    var best = -1;
    var bestT = 0.0;
    for (var s = _edgeStart[e]; s < _edgeStart[e + 1]; s++) {
      if (_side[s] == 1 ? !servesRight : !servesLeft) continue;
      final t = _t[s];
      if (t < fromT || t > far) continue;
      if (!_isFree(s)) continue;
      if (best < 0 || t < bestT) {
        best = s;
        bestT = t;
      }
    }
    if (best >= 0) _res[best] = vehicle;
    return best;
  }

  /// The nearest free, unmasked slot to [t] on [edge] on [side]: where a
  /// tandem shuffle puts the outer car (§7.5); −1 when there is none.
  int nearestFree(int edge, double t, int side) {
    if (edge < 0 || edge + 1 >= _edgeStart.length) return -1;
    var best = -1;
    var bestD = 0.0;
    for (var s = _edgeStart[edge]; s < _edgeStart[edge + 1]; s++) {
      if (_side[s] != side) continue;
      if (!_isFree(s)) continue;
      final d = (_t[s] - t).abs();
      if (best < 0 || d < bestD) {
        best = s;
        bestD = d;
      }
    }
    return best;
  }

  /// Slot [s]'s road edge, travel arc along it, and the lane beside it.
  int slotEdge(int s) => _edge[s];
  double slotT(int s) => _t[s];
  int slotLane(int s) => _lane[s];

  /// Slot [s]'s kerb: 1 right of its edge's travel, 0 left of it.
  int slotSide(int s) => _side[s];

  /// The car parked on slot [s], the vehicle that holds it, and whether a
  /// live plan's cut masks it (−1 for none).
  int carOf(int s) => _car[s];
  int reservationOf(int s) => _res[s];
  bool isMasked(int s) => _masked[s] == 1;

  /// Whether slot [s] is unmasked, empty and unreserved.
  bool isFree(int s) => _isFree(s);

  /// The first slot of [edge] and one past its last; the first
  /// [rightCount] of them are on the right kerb of travel.
  int slotStart(int edge) => _edgeStart[edge];
  int slotEnd(int edge) => _edgeStart[edge + 1];
  int rightCount(int edge) => _edgeRight[edge];

  /// §7.1's `kerbCap`: slots on [edge], both kerbs of a one-way road
  /// together.
  int capOf(int edge) => _edgeStart[edge + 1] - _edgeStart[edge];

  /// Slots of [edge] with a car or a binding reservation on them (§2.7's
  /// `kerbUsed`).
  int usedOf(int edge) {
    var n = 0;
    for (var s = _edgeStart[edge]; s < _edgeStart[edge + 1]; s++) {
      if (_car[s] >= 0 || _res[s] >= 0) n++;
    }
    return n;
  }

  /// Parks [car] on slot [s], and empties it again.
  void occupy(int s, int car) {
    _car[s] = car;
    _res[s] = -1;
    if (_masked[s] == 1) _markRelocate(car);
  }

  void release(int s) {
    _car[s] = -1;
    _res[s] = -1;
  }

  /// Cars a mask moved off their slot and nobody has moved yet, oldest
  /// first ([relocateCar]), and the list emptied once they have been.
  int get relocateCount => _relocateCount;
  int relocateCar(int i) => _relocate[i];
  void clearRelocations() => _relocateCount = 0;

  /// Every buffer by name into [into], for the allocation test (A13).
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.edgeStart'] = _edgeStart;
    into['$name.edgeRight'] = _edgeRight;
    into['$name.edge'] = _edge;
    into['$name.lane'] = _lane;
    into['$name.car'] = _car;
    into['$name.res'] = _res;
    into['$name.t'] = _t;
    into['$name.side'] = _side;
    into['$name.masked'] = _masked;
    into['$name.relocate'] = _relocate;
  }

  /// [hash] with every slot's occupant and mask folded in.
  int digest(int hash) {
    var h = fnv1aU32(hash, _edge.length);
    for (var s = 0; s < _edge.length; s++) {
      if (_car[s] < 0 && _res[s] < 0 && _masked[s] == 0) continue;
      h = fnv1aU32(h, s);
      h = fnv1aU32(h, _car[s]);
      h = fnv1aU32(h, _res[s]);
      h = fnv1aU32(h, _masked[s]);
    }
    return h;
  }

  /// §7.1's capacity for [e]: the lanes' own span, which is the edge less
  /// the stop bars at its two ends, with 12 m left clear across them.
  ///
  /// Kerb slots exist only where the road parks at the kerb, which is not a
  /// highway's shoulder ([kEdgeParking] carries both rules) and not a sealed
  /// road, whose kerb is a pressure wall. An outside connection's sink edge
  /// is not road at all.
  int _capOf(LaneGraph lg, int e) {
    if (e >= lg.roadEdgeCount) return 0;
    if (!lg.hasFlag(e, kEdgeParking) || lg.hasFlag(e, kEdgeSealed)) return 0;
    final span = lg.edgeLaneS1[e] - lg.edgeLaneS0[e] - kKerbEndClearM;
    if (span <= 0) return 0;
    return span ~/ kKerbSlotPitchM;
  }

  bool _isFree(int s) => _car[s] < 0 && _res[s] < 0 && _masked[s] == 0;

  /// Puts [car] on the relocation list, once.
  void _markRelocate(int car) {
    for (var i = 0; i < _relocateCount; i++) {
      if (_relocate[i] == car) return;
    }
    if (_relocateCount >= _relocate.length) {
      final cap = _relocate.isEmpty ? 16 : _relocate.length * 2;
      _relocate = Int32List(cap)..setRange(0, _relocateCount, _relocate);
    }
    _relocate[_relocateCount++] = car;
  }
}
