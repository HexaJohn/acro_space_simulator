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
/// **Every pass starts at slot 0.** A budget that stops after 64 moves does
/// not leave a cursor behind: the citizens it housed are no longer homeless,
/// so the next pass finds the next 64 in the same slot order. That is what
/// makes ten syncs of 64 do the same work, to the same people, in the same
/// order, as one sync of 640 — the property the budget test pins.
///
/// **The occupancy counts are the match's to keep.** `BuildingTable` holds
/// `residents` and `workers`; the people themselves hang off
/// `CitizenTable`'s per-building lists. This class moves everyone, so it
/// keeps the counts in step as it goes — and rebuilds them from the citizens
/// whenever the world moved underneath it: a sync ran, a building was
/// cleared, or someone else spawned or removed a citizen (§6.2's
/// realisation). The rebuild is the same pass that turns out the residents
/// of a building that has gone, which it spots by the slot's HANDLE moving
/// on (§2.6's removal).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'building_table.dart';
import 'citizen_table.dart';
import 'slot_pool.dart';
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
      _metres(fromBuildingSlot, toBuildingSlot) / carMps;

  @override
  double footSkim(int fromBuildingSlot, int toBuildingSlot) =>
      footDetour * _metres(fromBuildingSlot, toBuildingSlot) / footMps;

  /// The straight line between two centroids, colony-local metres. A slot
  /// outside the table answers 0 rather than reading past its columns: the
  /// caller is asking about a building that has gone, and every candidate
  /// is gated on liveness before it is asked about.
  double _metres(int from, int to) {
    final n = buildings.capacity;
    if (from < 0 || to < 0 || from >= n || to >= n) return 0;
    final de = buildings.centroidE[to] - buildings.centroidE[from];
    final dn = buildings.centroidN[to] - buildings.centroidN[from];
    return math.sqrt(de * de + dn * dn);
  }
}

/// Housing, jobs and occupancy. See the library comment.
class CitizenMatch {
  CitizenMatch(this.citizens, this.buildings, this.rng)
      : skims = StraightLineSkims(buildings);

  /// Candidates within this many seconds of the best are a tie, and the tie
  /// is broken by [rng] and by nothing else (§6.3).
  static const double tieBandS = 30;

  final CitizenTable citizens;
  final BuildingTable buildings;

  /// The matching's draws — the vacancy a home is drawn by, the tie inside
  /// the 30 s band — on a stream of their own.
  final TrafficRng rng;

  /// How far apart two buildings are, by mode. The stand-in at first; T4b
  /// puts the zone skims here and nothing else here changes (§4.9).
  TripSkims skims;

  /// The handle each building slot held when the counts were last rebuilt,
  /// and one candidate's skim per slot while a job is being chosen. Both
  /// are sized by the building table's capacity and grow only with it, so
  /// nothing here is allocated once the colony is warm (§15.2).
  Int32List _handleAt = Int32List(0);
  Float64List _skim = Float64List(0);

  /// What the world looked like at that rebuild. Anything that could have
  /// moved a citizen or a building behind the match's back moves one of
  /// these, and the next question rebuilds the counts.
  int _syncAt = -1, _removalsAt = -1, _liveAt = -1, _highAt = -1;
  bool _seeded = false;

  /// A building slot with housing to spare, drawn weighted by vacancy in
  /// stable building order; −1 when the colony is full (§6.2's arrival).
  int drawVacantHome() {
    _reconcile();
    return buildings.drawVacantHome(rng);
  }

  /// Houses up to [maxMoves] homeless citizens, in citizen slot order.
  /// Returns how many moved (§6.3).
  ///
  /// Stops early when the colony has no vacancy left: the rest of the
  /// homeless wait for a sync that finds one, and the scan costs nothing
  /// more this time round.
  int rehouse(int maxMoves) {
    if (maxMoves <= 0) return 0;
    _reconcile();
    var moved = 0;
    for (var sl = 0; sl < citizens.highWater && moved < maxMoves; sl++) {
      if (!citizens.pool.isSlotLive(sl) || citizens.home[sl] >= 0) continue;
      final home = buildings.drawVacantHome(rng);
      if (home < 0) break;
      citizens.setHome(citizens.pool.handleOf(sl), home);
      buildings.residents[home]++;
      // They have a roof: where they used to sleep is nobody's question
      // now (§9.2 asks it of the homeless only).
      citizens.sleepsNear[sl] = -1;
      moved++;
    }
    _mark();
    return moved;
  }

  /// Matches up to [maxMatches] unemployed citizens who have a home, in slot
  /// order, each on their OWN mode's skim, ties inside 30 s broken by [rng]
  /// and by nothing else. Returns how many were hired (§6.3).
  int matchJobs(int maxMatches) {
    if (maxMatches <= 0) return 0;
    _reconcile();
    if (_vacantJobs() <= 0) return 0;
    var hired = 0;
    for (var sl = 0; sl < citizens.highWater && hired < maxMatches; sl++) {
      if (!citizens.pool.isSlotLive(sl)) continue;
      final home = citizens.home[sl];
      if (home < 0 || citizens.work[sl] >= 0) continue;
      final byCar = citizens.car[sl] != CitizenTable.carNone;
      final job = _bestJob(home, byCar);
      // Nothing their mode can reach: a car owner whose only vacancies sit
      // off the network waits, and the scan goes on to the next citizen.
      if (job < 0) continue;
      citizens.setWork(citizens.pool.handleOf(sl), job);
      buildings.workers[job]++;
      hired++;
    }
    _mark();
    return hired;
  }

  /// Evicts residents to homeless until `Σ residents ≤ Σ housing`, reverse
  /// arrival order. Returns how many were evicted (§6.2).
  ///
  /// Building by building, because the sum is the sum of the buildings: a
  /// home whose utilisation fell turns out the people who moved in last,
  /// and nobody else's home is touched.
  int evictOverHoused() {
    _reconcile();
    final b = buildings;
    var out = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      var over = b.residents[sl] - b.housing[sl];
      while (over > 0) {
        final c = citizens.newestResident(sl);
        if (c < 0) break;
        _unhouse(c, sl);
        b.residents[sl]--;
        over--;
        out++;
      }
    }
    _mark();
    return out;
  }

  /// Lays off workers until `Σ workers ≤ Σ jobs`, last hired first out.
  /// Returns how many lost their job (§6.3).
  int layOffOverStaffed() {
    _reconcile();
    final b = buildings;
    var out = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      var over = b.workers[sl] - b.jobs[sl];
      while (over > 0) {
        final c = citizens.newestWorker(sl);
        if (c < 0) break;
        citizens.setWork(c, -1);
        b.workers[sl]--;
        over--;
        out++;
      }
    }
    _mark();
    return out;
  }

  /// Who leaves town next (§6.2's departure order): the homeless first, then
  /// the unemployed, then a draw on [rng]; −1 when nobody can go.
  ///
  /// The first two tiers take the first such citizen in slot order and stop
  /// looking — there is nothing to choose between two people with nothing
  /// to lose, and a scan that stops at the first is the cheap one. Only the
  /// last tier draws, so that a full, employed colony does not always lose
  /// the same person.
  int pickEmigrant() {
    _reconcile();
    final n = citizens.highWater;
    for (var sl = 0; sl < n; sl++) {
      if (citizens.pool.isSlotLive(sl) && citizens.home[sl] < 0) {
        return citizens.pool.handleOf(sl);
      }
    }
    for (var sl = 0; sl < n; sl++) {
      if (citizens.pool.isSlotLive(sl) && citizens.work[sl] < 0) {
        return citizens.pool.handleOf(sl);
      }
    }
    return _anyone();
  }

  /// Who dies next: a resident picked in BUILDING order, weighted by
  /// residents (§6.2); −1 when the colony has nobody.
  ///
  /// Inside the building it is the newest resident, the end an eviction
  /// takes: §6.2 puts the weight on the building, and walking a list to a
  /// drawn position would cost the walk for a draw nobody can see. A colony
  /// of nothing but the homeless still loses someone — they die at the
  /// building they sleep nearest (§6.2's homeless death).
  int pickForDeath() {
    _reconcile();
    final b = buildings;
    var total = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (b.isSlotLive(sl)) total += b.residents[sl];
    }
    if (total > 0) {
      var r = rng.nextInt(total);
      for (var sl = 0; sl < b.highWater; sl++) {
        if (!b.isSlotLive(sl)) continue;
        r -= b.residents[sl];
        if (r >= 0) continue;
        final c = citizens.newestResident(sl);
        if (c >= 0) return c;
        break;
      }
    }
    return _anyone();
  }

  /// Every buffer the match keeps from one sync to the next, by name into
  /// [into], for the allocation gate (§15.2): once the building table has
  /// stopped growing, neither of them is replaced again.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.handleAt'] = _handleAt;
    into['$name.skim'] = _skim;
  }

  /// [hash] with the matching's own stream folded in: for `CityAgents`.
  ///
  /// The occupancy half of the building table rides here rather than in
  /// `BuildingTable.digest`, so that a colony without citizens digests to
  /// exactly the value it did before slice 3.
  int digest(int hash) {
    final b = buildings;
    var h = fnv1aU32(hash, b.highWater);
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      h = fnv1aU32(h, b.handleOf(sl));
      h = fnv1aU32(h, b.residents[sl]);
      h = fnv1aU32(h, b.workers[sl]);
      h = fnv1aU32(h, (b.corpses[sl] * 1e3).round());
    }
    final state = rng.toJson();
    for (var i = 0; i < state.length; i++) {
      h = fnv1aU32(h, state[i]);
    }
    return h;
  }

  // ---- The counts ------------------------------------------------------------

  /// Brings [BuildingTable.residents] and [BuildingTable.workers] back to
  /// what the citizens actually say, and turns out the occupants of any
  /// building that has gone.
  ///
  /// It runs only when something could have moved behind the match's back —
  /// a sync, a cleared lot, a citizen spawned or removed by §6.2's
  /// realisation — because the match's own moves keep the counts as they
  /// go. That makes the common sync four cheap questions and one pass over
  /// the town, not four passes.
  void _reconcile() {
    _room();
    if (_seeded &&
        _syncAt == buildings.syncs &&
        _removalsAt == buildings.removals &&
        _liveAt == citizens.liveCount &&
        _highAt == citizens.highWater) {
      return;
    }
    final b = buildings;
    for (var sl = 0; sl < b.highWater; sl++) {
      final now = b.isSlotLive(sl) ? b.handleOf(sl) : SlotPool.none;
      if (now == _handleAt[sl]) continue;
      // A slot we had a building on is holding another one, or none: that
      // building has gone, and its residents are homeless and its workers
      // unemployed (§2.6's removal). A slot we have never seen holds a
      // building nobody has moved into yet, or one an arrival was just
      // housed in — turning those out would evict the citizen §6.2 just
      // made.
      if (_handleAt[sl] != SlotPool.none) _clearOccupants(sl);
      _handleAt[sl] = now;
    }
    b.residents.fillRange(0, b.capacity, 0);
    b.workers.fillRange(0, b.capacity, 0);
    for (var sl = 0; sl < citizens.highWater; sl++) {
      if (!citizens.pool.isSlotLive(sl)) continue;
      final home = citizens.home[sl];
      if (home >= 0 && home < b.capacity) b.residents[home]++;
      final work = citizens.work[sl];
      if (work >= 0 && work < b.capacity) b.workers[work]++;
    }
    _mark();
  }

  /// Everyone whose home or job was the building on [sl], turned out. The
  /// loop is bounded by the town: `setHome` takes the citizen out of the
  /// building's list, so it ends on its own, and the bound is there so a
  /// list that did not would fail a test rather than hang one.
  void _clearOccupants(int sl) {
    var left = citizens.liveCount;
    while (left > 0) {
      final c = citizens.newestResident(sl);
      if (c < 0) break;
      _unhouse(c, sl);
      left--;
    }
    left = citizens.liveCount;
    while (left > 0) {
      final c = citizens.newestWorker(sl);
      if (c < 0) break;
      citizens.setWork(c, -1);
      left--;
    }
  }

  /// [c] out of building slot [sl] and onto the street, remembering where
  /// they slept if the building is still standing: a homeless citizen's
  /// ambulance and their death both go to `sleepsNear` (§6.2, §9.2).
  void _unhouse(int c, int sl) {
    citizens.setHome(c, -1);
    final row = SlotPool.slotOf(c);
    citizens.sleepsNear[row] = buildings.isSlotLive(sl) ? sl : -1;
  }

  /// Room for one entry per building slot in the match's own arrays. They
  /// grow with the table and never shrink, so a warm colony allocates
  /// nothing here.
  void _room() {
    final n = buildings.capacity;
    if (_handleAt.length >= n) return;
    final was = _handleAt;
    _handleAt = Int32List(n)..fillRange(0, n, SlotPool.none);
    _handleAt.setRange(0, was.length, was);
    _skim = Float64List(n);
  }

  /// The world as the counts now describe it.
  void _mark() {
    _syncAt = buildings.syncs;
    _removalsAt = buildings.removals;
    _liveAt = citizens.liveCount;
    _highAt = citizens.highWater;
    _seeded = true;
  }

  // ---- The job ---------------------------------------------------------------

  /// Jobs going anywhere, so a town with none is not scanned once per
  /// unemployed citizen.
  int _vacantJobs() {
    final b = buildings;
    var total = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (b.isSlotLive(sl) && b.served[sl] != 0) total += b.jobVacancy(sl);
    }
    return total;
  }

  /// The job a citizen at home slot [home] takes, or −1: the vacancy with
  /// the smallest skim ON THEIR OWN MODE (§6.3), with everything inside
  /// [tieBandS] of the best drawn between by [rng] — weighted by the
  /// vacancies each offers, because §6.3's candidate is a VACANCY and not a
  /// building, so a works with forty places is forty times the shop with
  /// one.
  ///
  /// Three passes over the buildings, with the skims kept in [_skim] so
  /// that each is computed once: the cost is one pass of distances per
  /// hire, which is why the hires are budgeted.
  int _bestJob(int home, bool byCar) {
    final b = buildings;
    final n = b.highWater;
    var best = double.infinity;
    for (var sl = 0; sl < n; sl++) {
      if (!_hiring(sl, byCar)) {
        _skim[sl] = double.infinity;
        continue;
      }
      final s = byCar ? skims.carSkim(home, sl) : skims.footSkim(home, sl);
      _skim[sl] = s;
      if (s < best) best = s;
    }
    if (best == double.infinity) return -1;
    final band = best + tieBandS;
    var total = 0, last = -1, seen = 0;
    for (var sl = 0; sl < n; sl++) {
      if (_skim[sl] > band) continue;
      total += b.jobVacancy(sl);
      last = sl;
      seen++;
    }
    // One candidate is no tie, and a draw nobody can observe would still
    // move the stream every other draw is taken from.
    if (seen <= 1) return last;
    var r = rng.nextInt(total);
    for (var sl = 0; sl < n; sl++) {
      if (_skim[sl] > band) continue;
      r -= b.jobVacancy(sl);
      if (r < 0) return sl;
    }
    return last;
  }

  /// Whether the building on [sl] has a job going that this citizen's mode
  /// can take.
  ///
  /// A car owner is matched on the driving time, so the job must be one a
  /// car can reach and leave again (§3.10's per-role reachability). A
  /// citizen on foot is held only to the colony's own network: the walk
  /// costs what §6.3's stand-in says it costs, and a job too far to walk to
  /// loses to a nearer one on its skim, which is exactly how §6.3 keeps a
  /// carless citizen out of a job only a car could reach.
  bool _hiring(int sl, bool byCar) {
    final b = buildings;
    if (!b.isSlotLive(sl) || b.served[sl] == 0) return false;
    if (b.jobVacancy(sl) <= 0) return false;
    return !byCar || b.reachable(sl);
  }

  /// Any live citizen, drawn uniformly; −1 in an empty colony.
  int _anyone() {
    final live = citizens.liveCount;
    if (live <= 0) return -1;
    var k = rng.nextInt(live);
    for (var sl = 0; sl < citizens.highWater; sl++) {
      if (!citizens.pool.isSlotLive(sl)) continue;
      if (k == 0) return citizens.pool.handleOf(sl);
      k--;
    }
    return -1;
  }
}
