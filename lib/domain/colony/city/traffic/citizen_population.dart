// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Turning the population budgets into people (docs/plans/agent-traffic.md
/// §6.2, §6.6; docs/plans/slice3-implementation.md §1.4, §0).
///
/// [PopulationLedger] holds what is owed; this spends it. On each sub-step
/// that holds a whole person, [CitizenPopulation.realise] spawns arrivals,
/// removes emigrants and kills residents, and the world it does that in —
/// where a new citizen's car comes from, where a corpse lands, how a citizen
/// is placed at their home before there are walking trips — is [CitizenWorld],
/// implemented by the agents' facade. The split keeps this file free of the
/// site tables, and lets its tests drive a double.
///
/// Two rules from §0 are load-bearing, and both are about CARS:
///
/// - **Reconciliation never mints a car.** A citizen realised out of the
///   EXTERNAL budget — a load, a revolt, a test writing `population` — is not
///   an arrival: it adopts a free legacy car at its home ([CitizenWorld.adoptCarAt])
///   or owns none. Only a migration arrival draws `carOwnership`. Without
///   this, one `city.advance` over a restored save would invent cars and the
///   committed v2 fixture's `cars.count == saved.rows.length` would break.
/// - **A legacy car is never dropped and never owned twice.** A T4a car whose
///   owner is a BUILDING handle keeps its legacy kind and stands where it is
///   until a carless citizen of that building adopts it; it is re-saved
///   unchanged and offered again at every sync ([legacyCars]).
///
/// Spawns are capped at `max(4, 0.02·liveCount)` a sync (§6.2), so a colony
/// handed ten thousand people at once fills over the syncs after it rather
/// than in one frame; the rest stays in the budget.
///
/// **Package D owns the bodies.** P0 fixes this surface; the counters answer
/// 0 and [CitizenPopulation.realise] throws `UnimplementedError` until D
/// lands.
library;

import 'building_table.dart';
import 'citizen_match.dart';
import 'citizen_table.dart';
import 'population_ledger.dart';
import 'traffic_rng.dart';

/// What realisation needs of the world outside the citizen tables: the cars,
/// the placement and the corpses. Implemented by `CityAgents`' core.
abstract interface class CitizenWorld {
  /// A free legacy car standing at building slot [buildingSlot], re-owned by
  /// the citizen asking for it (`ParkedCarTable.reown`), or −1 when the home
  /// has none to give. The car does not move: adoption is a rewrite of two
  /// columns, never a park (§0).
  int adoptCarAt(int buildingSlot);

  /// A car drawn for [citizen] at home [buildingSlot] and parked there
  /// (§6.6): the home's lot if it has room, else a kerb slot within
  /// `homeCarRadiusM`, else garaged. Returns its handle, or −1.
  int mintCarAt(int citizen, int buildingSlot);

  /// [car]'s row leaves the world: its owner emigrated or died.
  void releaseCar(int car);

  /// Puts [citizen] at home [home] with no trip at all — the interim for
  /// §6.2's `movingIn` until slice 8 drives them in from a stub — and counts
  /// it in `stats.instantTrips` (§0 Q6).
  void placeAtHome(int citizen, int home);

  /// [citizen] has left the colony: whatever the facade holds for them goes.
  void leftTown(int citizen);

  /// A death at building slot [buildingSlot]: `BuildingTable.corpses += 1`,
  /// which slice 5's hearses serve (§6.2).
  void corpseAt(int buildingSlot);
}

/// Arrivals, departures and deaths. See the library comment.
class CitizenPopulation {
  CitizenPopulation(
      {required this.citizens,
      required this.buildings,
      required this.ledger,
      required this.match,
      required this.rng});

  final CitizenTable citizens;
  final BuildingTable buildings;
  final PopulationLedger ledger;
  final CitizenMatch match;

  /// Realisation's draws — car ownership, the emigrant pick — on a stream of
  /// their own.
  final TrafficRng rng;

  /// What has happened since the colony started: citizens spawned, emigrated
  /// and dead; legacy cars adopted; and legacy cars still standing unowned,
  /// re-offered at every sync (§0 Q3).
  int arrivals = 0, departures = 0, deaths = 0, adopted = 0, legacyCars = 0;

  /// Spends what the ledger holds, at agent time [nowUs], in [world].
  ///
  /// [external] says which budget this call is allowed to draw an ARRIVAL
  /// from: false for `migrationBudget` (which mints cars), true for the
  /// external budget (which never does). Departures and deaths are the same
  /// either way.
  void realise(int nowUs, CitizenWorld world, {required bool external}) =>
      throw UnimplementedError('slice 3 D: citizen_population.realise');

  /// [hash] with the counters and this stream's state folded in (§17.4).
  int digest(int hash) =>
      throw UnimplementedError('slice 3 D: citizen_population.digest');
}
