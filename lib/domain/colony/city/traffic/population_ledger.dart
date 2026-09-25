// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The four fractional budgets between `CitySim`'s population and the
/// citizens (docs/plans/agent-traffic.md §6.2, §12.1; §14.1;
/// docs/plans/slice3-implementation.md §1.2).
///
/// `CitySim.population` stays the number every reader reads — milestones,
/// tax, research, RCI, the HUD, the laws — and the citizens are what it
/// COUNTS once `agents.ownsPopulation` is on. The two meet here, because the
/// tick's own growth arithmetic is fractional and a citizen is not: a tenth
/// of a migrant waits in a budget until nine more join it.
///
/// - [migration] is fed by E9, which computes today's target and rate exactly
///   as it always did and adds only the DELTA.
/// - [death] is fed by E8's `died`.
/// - [external] is everything else that moved `population` — a revolt, a
///   disaster, a relief crew, a test writing `city.population = 200`, a load:
///   `ext = population − lastWritten`, taken once at the top of each
///   `agents.advance` ([syncExternal]). It is the ONLY way an outside write
///   reaches the citizens.
/// - [pendingFraction] is what is left of the budgets below one person, and
///   is written back with the live count so nothing is lost to rounding.
///
/// **The one-tick contract** (§6.2, §12.1): within one `CitySim.advance`,
/// mortality and migration write the LEDGER, not `population`;
/// `agents.advance` realises them later in the same tick and writes
/// `population = citizens.liveCount + pendingFraction` at its end
/// ([writeBack]). Everything `CitySim` reads from the agents is still the
/// previous advance's.
///
/// **Package D owns the bodies.** P0 fixes this surface; the fields answer 0
/// and everything else throws `UnimplementedError` until D lands.
library;

/// The population budgets. See the library comment.
class PopulationLedger {
  /// People owed by migration, mortality and outside writes, and the part of
  /// the count below one person; [lastWritten] is the population this ledger
  /// put on the colony, which is what [syncExternal] measures against.
  double migration = 0, death = 0, external = 0, pendingFraction = 0;
  double lastWritten = 0;

  /// E9's migration delta for this tick (may be negative: emigration).
  void addMigration(double delta) =>
      throw UnimplementedError('slice 3 D: population_ledger.addMigration');

  /// E8's [died] for this tick, always a positive number of people.
  void addDeath(double died) =>
      throw UnimplementedError('slice 3 D: population_ledger.addDeath');

  /// `ext = population − lastWritten` into [external]: whatever moved the
  /// colony's population that the agents did not (§6.2). Taken once, at the
  /// top of `agents.advance`.
  void syncExternal(double population) =>
      throw UnimplementedError('slice 3 D: population_ledger.syncExternal');

  /// Up to [cap] whole arrivals owed, taken out of the budgets; the rest
  /// stays owed. Migration is drawn before the external budget, because only
  /// a migration arrival draws `carOwnership` (§0's reconciliation rule).
  int takeArrivals(int cap) =>
      throw UnimplementedError('slice 3 D: population_ledger.takeArrivals');

  /// Up to [cap] whole departures owed.
  int takeDepartures(int cap) =>
      throw UnimplementedError('slice 3 D: population_ledger.takeDepartures');

  /// Up to [cap] whole deaths owed.
  int takeDeaths(int cap) =>
      throw UnimplementedError('slice 3 D: population_ledger.takeDeaths');

  /// The population to write on the colony now: [liveCount] plus what is
  /// left below one person. Sets [lastWritten] to it, so the next
  /// [syncExternal] measures only what somebody else changed.
  double writeBack(int liveCount) =>
      throw UnimplementedError('slice 3 D: population_ledger.writeBack');

  /// The `ledger` block of the save (§14.1).
  Map<String, Object?> toJson() =>
      throw UnimplementedError('slice 3 D: population_ledger.toJson');

  /// Puts back what [toJson] wrote; anything else leaves the budgets empty,
  /// as a colony that never had a ledger reads.
  void restore(Object? json) =>
      throw UnimplementedError('slice 3 D: population_ledger.restore');

  /// [hash] with every budget folded in, to its millionth (§17.4).
  int digest(int hash) =>
      throw UnimplementedError('slice 3 D: population_ledger.digest');
}
