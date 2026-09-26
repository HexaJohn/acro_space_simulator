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
/// **The arithmetic, as built.** Every budget is a SIGNED count of people
/// owed, in people: positive is somebody arriving, negative is somebody
/// leaving, and [death] is positive for somebody dying. Whole people are
/// taken out by [takeArrivals], [takeDepartures] and [takeDeaths], and only
/// whole people; what is left over is carried, so a colony gaining 0.3 people
/// a tick gains its first on the fourth and never gains two. [writeBack]
/// then puts `liveCount + pendingFraction` on the colony, where
/// [pendingFraction] is the sum of the parts of the budgets BELOW one person:
/// `frac(migration) + frac(external) − frac(death)`. A whole person still
/// owed — one the arrival cap held back (§6.2) — is deliberately not in it,
/// so `population` follows the people who exist and the only lag is the cap,
/// which is what §17.3 #20's parity measures.
///
/// **Nothing is counted twice.** [syncExternal] sets [lastWritten] as well as
/// reading it, so an advance that realises nothing cannot take the same
/// outside write twice; [writeBack] sets it to what it wrote, so the next
/// [syncExternal] measures only what somebody else changed; and
/// [pendingFraction] is DERIVED from the budgets at every write-back rather
/// than accumulated, so it cannot drift away from them.
///
/// **The two arrival budgets are drawn separately** ([takeArrivals]'s
/// `external`), because §0's reconciliation rule turns on which one a citizen
/// came out of: a migration arrival draws `carOwnership` and may have a car
/// minted for it, and an external one — a load, a revolt, a test writing
/// `population` — never mints, it adopts or goes without.
library;

import 'traffic_rng.dart';

/// The population budgets. See the library comment.
class PopulationLedger {
  /// People owed by migration, mortality and outside writes, and the part of
  /// the count below one person; [lastWritten] is the population this ledger
  /// put on the colony, which is what [syncExternal] measures against.
  double migration = 0, death = 0, external = 0, pendingFraction = 0;
  double lastWritten = 0;

  /// Whether the ledger holds nothing at all: what a colony that has never
  /// had citizens reads, and the gate on writing a `ledger` block (§14.1), so
  /// a colony without them writes the bytes it wrote before slice 3.
  bool get isEmpty =>
      migration == 0 && death == 0 && external == 0 && lastWritten == 0;

  /// E9's migration delta for this tick (may be negative: emigration).
  void addMigration(double delta) {
    if (!delta.isFinite) return;
    migration += delta;
  }

  /// E8's [died] for this tick, always a positive number of people. A
  /// negative one is not a resurrection; it is a caller's mistake, and it is
  /// ignored rather than quietly turned into an arrival.
  void addDeath(double died) {
    if (!died.isFinite || died <= 0) return;
    death += died;
  }

  /// `ext = population − lastWritten` into [external]: whatever moved the
  /// colony's population that the agents did not (§6.2). Taken once, at the
  /// top of `agents.advance`.
  ///
  /// It moves [lastWritten] on as well. An advance that takes the delta and
  /// then realises nothing — agents paused, no whole person owed — must not
  /// read the same outside write again on the next one.
  void syncExternal(double population) {
    if (!population.isFinite) return;
    external += population - lastWritten;
    lastWritten = population;
  }

  /// Hands [people] back to the budget they were taken from: the realisation
  /// drew them and could not place them (a citizen table that is full, a
  /// colony with nowhere at all to put anyone). They stay owed, and the next
  /// sync offers them again.
  ///
  /// Not an outside write, so it never goes near [lastWritten]: it undoes a
  /// take of this ledger's own.
  void giveBack(int people, {required bool external}) {
    if (people <= 0) return;
    if (external) {
      this.external += people;
    } else {
      migration += people;
    }
  }

  /// Up to [cap] whole arrivals owed, taken out of ONE budget — [external]'s
  /// when `external` is set, [migration]'s otherwise — with the rest left
  /// owed.
  ///
  /// The two are separate because only a migration arrival draws
  /// `carOwnership` (§0's reconciliation rule); the realisation asks for
  /// migration first, so that a tick which can spawn only a few people spends
  /// the budget that mints before the one that adopts.
  int takeArrivals(int cap, {bool external = false}) {
    if (cap <= 0) return 0;
    final budget = external ? this.external : migration;
    final whole = _wholeOf(budget);
    final n = whole < cap ? whole : cap;
    if (n <= 0) return 0;
    if (external) {
      this.external = budget - n;
    } else {
      migration = budget - n;
    }
    return n;
  }

  /// Up to [cap] whole departures owed: the people a NEGATIVE budget holds,
  /// [migration]'s drawn down before [external]'s.
  ///
  /// The two are drawn as one pool, because a departure is a departure
  /// whichever budget owes it — half a person owed by each is one person
  /// leaving — and the draw-down is in a fixed order so two runs that owe the
  /// same halves leave the same budgets behind.
  int takeDepartures(int cap) {
    if (cap <= 0) return 0;
    final owed = (migration < 0 ? -migration : 0.0) +
        (external < 0 ? -external : 0.0);
    final whole = _wholeOf(owed);
    var n = whole < cap ? whole : cap;
    if (n <= 0) return 0;
    var left = n.toDouble();
    if (migration < 0) {
      final take = -migration < left ? -migration : left;
      migration += take;
      left -= take;
    }
    if (left > 0 && external < 0) external += left;
    return n;
  }

  /// Up to [cap] whole deaths owed.
  int takeDeaths(int cap) {
    if (cap <= 0) return 0;
    final whole = _wholeOf(death);
    final n = whole < cap ? whole : cap;
    if (n <= 0) return 0;
    death -= n;
    return n;
  }

  /// The population to write on the colony now: [liveCount] plus what is
  /// left below one person. Sets [lastWritten] to it, so the next
  /// [syncExternal] measures only what somebody else changed.
  double writeBack(int liveCount) {
    pendingFraction = _fracOf(migration) + _fracOf(external) - _fracOf(death);
    lastWritten = liveCount + pendingFraction;
    return lastWritten;
  }

  /// The `ledger` block of the save (§14.1).
  ///
  /// [lastWritten] rides with the budgets, and it is the load-bearing one: a
  /// colony resumed without it would measure its whole population as an
  /// outside write on the first [syncExternal] and reconcile a second town
  /// on top of the one it just restored. A block that carries no `last` —
  /// a pre-citizens save, or a colony that has just switched the agents on —
  /// reads 0 on purpose, which is exactly §14.4's "citizens reconciled from
  /// `population`, through the external budget".
  Map<String, Object?> toJson() => {
        'mig': migration,
        'death': death,
        'ext': external,
        'last': lastWritten,
      };

  /// Puts back what [toJson] wrote; anything else leaves the budgets empty,
  /// as a colony that never had a ledger reads.
  ///
  /// [pendingFraction] is re-derived rather than read, because it is not a
  /// budget of its own: it is what the other three hold below one person, and
  /// a save that disagreed with them would be a save that could drift.
  void restore(Object? json) {
    migration = 0;
    death = 0;
    external = 0;
    lastWritten = 0;
    pendingFraction = 0;
    if (json is! Map) return;
    migration = _numberOf(json['mig']);
    death = _numberOf(json['death']);
    external = _numberOf(json['ext']);
    lastWritten = _numberOf(json['last']);
    pendingFraction = _fracOf(migration) + _fracOf(external) - _fracOf(death);
  }

  /// [hash] with every budget folded in, to its millionth (§17.4).
  int digest(int hash) {
    var h = _fold(hash, migration);
    h = _fold(h, death);
    h = _fold(h, external);
    h = _fold(h, pendingFraction);
    return _fold(h, lastWritten);
  }

  /// The whole people [budget] holds, never negative: what a take may take.
  ///
  /// Saturating, like every clock here: a budget somebody wrote as a
  /// thousand million people is held at [_maxPeople] rather than converted
  /// out of the range an int holds. The takes cap it far below that anyway.
  static int _wholeOf(double budget) {
    if (!(budget >= 1)) return 0;
    if (!(budget < _maxPeople)) return _maxPeople;
    return budget.floor();
  }

  /// Where a budget and a folded population stop: inside 2^31, so neither
  /// ever leaves the range an `Int32List` cell and a web int agree on.
  static const int _maxPeople = 2000000000;

  /// The part of [budget] below one person, with its sign: 6.3 owes 0.3,
  /// −2.4 owes −0.4. Truncation and not a floor, so that the two signs are
  /// read the same way round — the whole people are what the takes remove,
  /// and this is what is left after them.
  static double _fracOf(double budget) =>
      budget.isFinite ? budget - budget.truncateToDouble() : 0;

  /// [json] as a finite number, or 0: a save is data, and a budget that came
  /// back as a string or a NaN would poison every sum after it.
  static double _numberOf(Object? json) {
    if (json is! num) return 0;
    final v = json.toDouble();
    return v.isFinite ? v : 0;
  }

  /// [hash] with [v] folded in as whole people and millionths.
  ///
  /// Two words, as `CitizenTable`'s clock fold is: a colony of a hundred
  /// thousand people times a million is past what 32 bits hold, and a digest
  /// that folded the product alone would read two populations a few thousand
  /// apart as one. Neither half is ever wider than the 32 bits the web has.
  static int _fold(int hash, double v) {
    if (!v.isFinite) return fnv1aU32(fnv1aU32(hash, 0), 0);
    final whole = v.truncateToDouble();
    if (!(whole > -_maxPeople && whole < _maxPeople)) {
      return fnv1aU32(
          fnv1aU32(hash, whole > 0 ? _maxPeople : -_maxPeople), 0);
    }
    return fnv1aU32(fnv1aU32(hash, whole.toInt()), ((v - whole) * 1e6).round());
  }
}
