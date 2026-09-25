// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Who lives where and who works where (docs/plans/agent-traffic.md §6.2's
/// invariants and §6.3; docs/plans/slice3-implementation.md §1.3).
///
/// Housing and jobs are matched once per building sync, a bounded number at
/// a time (`AgentTuning.rehousePerSync`, `AgentTuning.jobMatchPerSync`), in
/// citizen slot order, so a colony that grows a thousand homes in one tick
/// spreads the matching over the syncs after it rather than stopping the
/// frame. Two invariants hold after every sync, and the property test checks
/// them:
///
/// - `Σ residents ≤ Σ housing` — excess residents are evicted to homeless in
///   REVERSE arrival order;
/// - `Σ workers ≤ Σ jobs` — excess workers are laid off, last hired first
///   out.
///
/// **The skim is the citizen's own mode** (§6.3): a car owner is matched on
/// the driving time, everyone else on the walking time, so nobody is given a
/// job only a car could reach. [TripSkims] is that question behind an
/// interface, because T4b swaps the straight-line stand-in for real zone
/// skims (§4.9) and nothing else here changes when it does.
///
/// **Package B owns the bodies**, and `building_table.dart`'s occupancy
/// columns with them. P0 fixes this surface; the constructors work and
/// everything else throws `UnimplementedError` until B lands.
library;

import 'building_table.dart';
import 'citizen_table.dart';
import 'traffic_rng.dart';

/// The travel time between two buildings, by mode, in agent seconds.
///
/// Answers even while it is not [ready] — the stand-in always is — so a
/// colony whose skims are still being built matches on what it has rather
/// than leaving everyone unemployed until they arrive.
abstract interface class TripSkims {
  /// Whether the real skims are built; false while a T4b table is filling.
  bool get ready;

  /// Seconds from building slot [fromBuildingSlot] to [toBuildingSlot] by
  /// car.
  double carSkim(int fromBuildingSlot, int toBuildingSlot);

  /// The same on foot (and, from slice 4, by transit: the better of the two).
  double footSkim(int fromBuildingSlot, int toBuildingSlot);
}

/// §6.3's stand-in until the zone skims land: the straight line between two
/// centroids, divided by [carMps] for a car owner and by [footMps] for
/// everyone else, with [footDetour] for the fact that nobody walks through
/// the blocks.
final class StraightLineSkims implements TripSkims {
  StraightLineSkims(this.buildings);

  /// Metres a second, and the walking detour factor (§6.3).
  static const double carMps = 12;
  static const double footMps = 1.3;
  static const double footDetour = 1.35;

  /// Where the centroids come from.
  final BuildingTable buildings;

  /// Always: a straight line needs nothing built.
  @override
  bool get ready => true;

  @override
  double carSkim(int fromBuildingSlot, int toBuildingSlot) =>
      throw UnimplementedError('slice 3 B: straight_line_skims.carSkim');

  @override
  double footSkim(int fromBuildingSlot, int toBuildingSlot) =>
      throw UnimplementedError('slice 3 B: straight_line_skims.footSkim');
}

/// Housing, jobs and occupancy. See the library comment.
class CitizenMatch {
  CitizenMatch(this.citizens, this.buildings, this.rng)
      : skims = StraightLineSkims(buildings);

  final CitizenTable citizens;
  final BuildingTable buildings;

  /// The matching's draws — the vacancy a home is drawn by, the tie inside
  /// the 30 s band — on a stream of their own.
  final TrafficRng rng;

  /// How far apart two buildings are, by mode. The stand-in at first; T4b
  /// puts the zone skims here and nothing else here changes (§4.9).
  TripSkims skims;

  /// A building slot with housing to spare, drawn weighted by vacancy in
  /// stable building order; −1 when the colony is full (§6.2's arrival).
  int drawVacantHome() =>
      throw UnimplementedError('slice 3 B: citizen_match.drawVacantHome');

  /// Houses up to [maxMoves] homeless citizens, in citizen slot order.
  /// Returns how many moved (§6.3).
  int rehouse(int maxMoves) =>
      throw UnimplementedError('slice 3 B: citizen_match.rehouse');

  /// Matches up to [maxMatches] unemployed citizens who have a home, in slot
  /// order, each on their OWN mode's skim, ties inside 30 s broken by [rng]
  /// and by nothing else. Returns how many were hired (§6.3).
  int matchJobs(int maxMatches) =>
      throw UnimplementedError('slice 3 B: citizen_match.matchJobs');

  /// Evicts residents to homeless until `Σ residents ≤ Σ housing`, reverse
  /// arrival order. Returns how many were evicted (§6.2).
  int evictOverHoused() =>
      throw UnimplementedError('slice 3 B: citizen_match.evictOverHoused');

  /// Lays off workers until `Σ workers ≤ Σ jobs`, last hired first out.
  /// Returns how many lost their job (§6.3).
  int layOffOverStaffed() =>
      throw UnimplementedError('slice 3 B: citizen_match.layOffOverStaffed');

  /// Who leaves town next (§6.2's departure order): the homeless first, then
  /// the unemployed, then a draw on [rng]; −1 when nobody can go.
  int pickEmigrant() =>
      throw UnimplementedError('slice 3 B: citizen_match.pickEmigrant');

  /// Who dies next: a resident picked in BUILDING order, weighted by
  /// residents (§6.2); −1 when the colony has nobody.
  int pickForDeath() =>
      throw UnimplementedError('slice 3 B: citizen_match.pickForDeath');

  /// [hash] with the matching's own stream folded in: for `CityAgents`.
  int digest(int hash) =>
      throw UnimplementedError('slice 3 B: citizen_match.digest');
}
