// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Kerb parking slots along the road (docs/plans/t4a-implementation.md
/// §1.7; site-access.md §7.1, §7.5 D17 step 2).
///
/// STUB (P0). Package D implements it; until then every method throws.
///
/// The contract D builds to:
///
/// - **Slots** are laid out along the RIGHT kerb of every edge that allows
///   kerb parking (§7.1's caps; a one-way street gets both kerbs), from the
///   lane graph and nothing else: they move only when the graph is rebuilt.
/// - **Masks** ([applyMasks]): a slot inside a live plan's cut mask is not
///   a parking place. The mask comes from [KerbMask], which wraps the road
///   side's `KerbCuts.parkingBlocked` — there is no local formula (§0 Q1).
///   Masks are applied again on `sitesRev`, and a car on a slot that became
///   masked relocates, as a car on a vanished stall does.
/// - **Reservations** ([reserveAhead]) are BINDING, as a stall's are: D17
///   step 2 takes the first unmasked free slot ahead on the arrival edge
///   within `AgentTuning.kerbAheadM`, and the car drives a one-element leg
///   to it.
library;

import 'kerb_mask.dart';
import 'lane_graph.dart';
import 'site_table.dart';

/// The kerb slots. See the library comment.
class KerbTable {
  /// Lays the slots out along [lg]'s kerbs (§7.1 caps, the right kerb; a
  /// one-way street's both kerbs). Every slot is new: the caller replaces
  /// the parked cars' slots from their `(edge, t)`.
  void bind(LaneGraph lg) => throw UnimplementedError('T4a D: KerbTable.bind');

  /// Masks every slot [mask] blocks for a live plan of [sites] on [lg]
  /// (§7.5). Called again whenever `sitesRev` moves.
  void applyMasks(SiteTable sites, LaneGraph lg, KerbMask mask) =>
      throw UnimplementedError('T4a D: KerbTable.applyMasks');

  /// Reserves the first free, unmasked slot in [lane] ahead of [fromT]
  /// travel metres, within `AgentTuning.kerbAheadM` on this edge, for
  /// [vehicle] (a handle); −1 when there is none (D17 step 2).
  int reserveAhead(int lane, double fromT, int vehicle) =>
      throw UnimplementedError('T4a D: KerbTable.reserveAhead');

  /// The nearest free, unmasked slot to [t] on [edge] on [side]: where a
  /// tandem shuffle puts the outer car (§7.5); −1 when there is none.
  int nearestFree(int edge, double t, int side) =>
      throw UnimplementedError('T4a D: KerbTable.nearestFree');

  /// Slot [s]'s road edge, travel arc along it, and the lane beside it.
  int slotEdge(int s) => throw UnimplementedError('T4a D: KerbTable.slotEdge');
  double slotT(int s) => throw UnimplementedError('T4a D: KerbTable.slotT');
  int slotLane(int s) => throw UnimplementedError('T4a D: KerbTable.slotLane');

  /// Parks [car] on slot [s], and empties it again.
  void occupy(int s, int car) =>
      throw UnimplementedError('T4a D: KerbTable.occupy');
  void release(int s) => throw UnimplementedError('T4a D: KerbTable.release');

  /// Every buffer by name into [into], for the allocation test (A13).
  void collectBuffers(Map<String, Object> into, String name) =>
      throw UnimplementedError('T4a D: KerbTable.collectBuffers');

  /// [hash] with every slot's occupant and mask folded in.
  int digest(int hash) => throw UnimplementedError('T4a D: KerbTable.digest');
}
