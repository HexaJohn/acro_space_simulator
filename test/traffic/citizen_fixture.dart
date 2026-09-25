// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A town with citizens in it (docs/plans/agent-traffic.md §6;
/// docs/plans/slice3-implementation.md §1).
///
/// [CitizenTown] is `traffic_fixture.dart`'s town with the citizen half of
/// slice 3 built on top of it: a synced [BuildingTable], the [CitizenTable],
/// the [PopulationLedger], the matching and the realisation, each on its own
/// forked stream. It deliberately holds NO vehicles, planner or path queue —
/// a test that needs cars on roads wants `CityAgents` and `traffic_fixture`,
/// not this — so that a test about who lives where runs in milliseconds.
///
/// [FakeCitizenWorld] is the other half: the [CitizenWorld] realisation asks
/// for cars, placements and corpses through, writing down what it was asked
/// rather than doing it. Package D drives `CitizenPopulation.realise`
/// against it; package E checks the real core against the same script.
///
/// P0 built it; A, B, C and D extend it. It is deliberately thin: the homes
/// and jobs are the town's own buildings, in slot order, so two tests that
/// name `homes[0]` mean the same house.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_match.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_population.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/population_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';

import 'traffic_fixture.dart';

/// Salts of the fixture's sub-streams, so the matching's draws and the
/// realisation's never shift each other (§17.4).
const int _matchSalt = 0x4D415443; // 'MATC'
const int _peopleSalt = 0x50454F50; // 'PEOP'

/// A built town, its buildings, and the citizens living in them.
class CitizenTown {
  /// [on] is the colony to build on — a `town()` by default, every free
  /// street lot zoned and built, which gives homes and jobs in one place.
  CitizenTown({CitySim? on, int seed = 20260925})
      : city = on ?? town(),
        rng = TrafficRng(seed) {
    lg = LaneGraphBuilder.build(city.roadGraph);
    buildings = BuildingTable()..sync(city, lg);
    match = CitizenMatch(citizens, buildings, rng.fork(_matchSalt));
    population = CitizenPopulation(
      citizens: citizens,
      buildings: buildings,
      ledger: ledger,
      match: match,
      rng: rng.fork(_peopleSalt),
    );
  }

  /// The colony, its lanes, and the buildings the citizens live and work in.
  final CitySim city;
  late final LaneGraph lg;
  late final BuildingTable buildings;

  /// The stream the forks come off; give each subsystem its own.
  final TrafficRng rng;

  final CitizenTable citizens = CitizenTable();
  final PopulationLedger ledger = PopulationLedger();
  late final CitizenMatch match;
  late final CitizenPopulation population;

  /// Syncs the buildings again — after the test has zoned, built or cleared
  /// something — and makes room in the citizens' per-building lists for what
  /// the sync found.
  void sync() {
    buildings.sync(city, lg);
    citizens.ensureBuildings(buildings.highWater);
  }

  /// The building slots with housing, in slot order: `homes[0]` is the same
  /// house in every test that founds the same town.
  List<int> get homes => _slotsWhere((sl) => buildings.housing[sl] > 0);

  /// The building slots with jobs, in slot order.
  List<int> get jobs => _slotsWhere((sl) => buildings.jobs[sl] > 0);

  /// The building slot of lot [lotId], or −1.
  int buildingOf(String lotId) {
    final h = buildings.handleOfSite(lotId);
    return h == null ? -1 : SlotPool.slotOf(h);
  }

  /// A citizen living at building slot [home] and working at [work] (−1 for
  /// homeless or unemployed), owning no car and at home until [wakeUs].
  /// Returns the handle.
  int add(
          {int home = -1,
          int work = -1,
          int car = CitizenTable.carNone,
          CitizenState state = CitizenState.atHome,
          double wakeUs = 0,
          int flags = 0}) =>
      citizens.spawn(
          home: home,
          work: work,
          car: car,
          state: state,
          wakeUs: wakeUs,
          flags: flags);

  /// [perHome] citizens in each home of the town, each given a job from
  /// [jobs] in turn (none once the jobs run out, which is the unemployment
  /// §6.3 has to answer for). Returns their handles, in the order they were
  /// spawned.
  List<int> populate({int perHome = 1}) {
    final made = <int>[];
    final work = jobs;
    var next = 0;
    for (final home in homes) {
      for (var i = 0; i < perHome; i++) {
        made.add(add(
            home: home, work: work.isEmpty ? -1 : work[next++ % work.length]));
      }
    }
    return made;
  }

  List<int> _slotsWhere(bool Function(int slot) test) => [
        for (var sl = 0; sl < buildings.highWater; sl++)
          if (buildings.isSlotLive(sl) && test(sl)) sl,
      ];
}

/// The world realisation acts on, written down instead of acted on.
///
/// Every list is in the order it was asked for, so a test can assert the
/// SEQUENCE — a citizen adopted before one was minted for, a corpse on the
/// home a death was drawn from — and not merely the counts.
class FakeCitizenWorld implements CitizenWorld {
  /// Building slots [adoptCarAt] was asked about, and what each answered.
  final List<int> adoptAsked = <int>[];
  final List<int> minted = <int>[];
  final List<int> released = <int>[];
  final List<int> placedCitizen = <int>[];
  final List<int> placedHome = <int>[];
  final List<int> gone = <int>[];
  final List<int> corpses = <int>[];

  /// The next handle [mintCarAt] hands out; a fresh number each time, and
  /// nothing here is a real parked car.
  int nextCar = 1;

  /// Building slots with a free legacy car to adopt: the first entry for a
  /// slot is handed out and removed, as the real sweep hands out one car.
  final List<int> legacyAt = <int>[];

  @override
  int adoptCarAt(int buildingSlot) {
    adoptAsked.add(buildingSlot);
    final i = legacyAt.indexOf(buildingSlot);
    if (i < 0) return -1;
    legacyAt.removeAt(i);
    return nextCar++;
  }

  @override
  int mintCarAt(int citizen, int buildingSlot) {
    minted.add(citizen);
    return nextCar++;
  }

  @override
  void releaseCar(int car) => released.add(car);

  @override
  void placeAtHome(int citizen, int home) {
    placedCitizen.add(citizen);
    placedHome.add(home);
  }

  @override
  void leftTown(int citizen) => gone.add(citizen);

  @override
  void corpseAt(int buildingSlot) => corpses.add(buildingSlot);
}
