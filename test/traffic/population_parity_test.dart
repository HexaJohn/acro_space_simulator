// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_population.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/population_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'citizen_fixture.dart';

/// The population budgets, and the people they turn into
/// (docs/plans/agent-traffic.md §6.2, §6.6, §17.3 #20;
/// docs/plans/slice3-implementation.md §1.2, §1.4, §0).
///
/// `CitySim`'s growth arithmetic is fractional and a citizen is not, so the
/// whole of this package is about what happens to the part of a person that
/// is left over. Each test below is one way to lose one:
///
/// - a tenth of a migrant that is rounded away every tick and never arrives;
/// - a tenth that is counted once in the budget and again in the population;
/// - a cap that holds four arrivals back and then forgets them;
/// - an arrival the colony reconciled out of its own `population` that mints
///   a car nobody ever bought (§0, and the committed pre-citizens fixture);
/// - a legacy car handed to two people, or to nobody, for ever.
///
/// The last of those is exercised where it can be SEEN, in
/// `agents_codec_test.dart`: an adopted car and an unadopted one differ only
/// in what the next save writes.
void main() {
  tearDown(AgentTuning.reset);

  group('the ledger carries what is below one person', () {
    test('a colony gaining 0.3 people a tick gains one, and never two', () {
      final ledger = PopulationLedger();
      // Three ticks owe nine tenths of a person, which is nobody.
      for (var k = 0; k < 3; k++) {
        ledger.addMigration(0.3);
        expect(ledger.takeArrivals(8), 0, reason: 'after ${k + 1} ticks');
      }
      ledger.addMigration(0.3);
      expect(ledger.takeArrivals(8), 1,
          reason: 'the fourth tenth of a person completes the first arrival');
      expect(ledger.takeArrivals(8), 0,
          reason: 'and taking again in the same tick takes nobody twice');
      expect(ledger.migration, closeTo(0.2, 1e-9),
          reason: 'the remainder is carried, not rounded away');

      // Over a hundred ticks the colony owes thirty people, and every one of
      // them is either alive or still owed: the rounding is carried both
      // ways, so none is lost and none is invented.
      var got = 1;
      for (var k = 4; k < 100; k++) {
        ledger.addMigration(0.3);
        got += ledger.takeArrivals(8);
      }
      expect(got + ledger.migration, closeTo(30, 1e-9));
      expect(ledger.migration, greaterThanOrEqualTo(0));
      expect(ledger.migration, lessThan(1),
          reason: 'what is left over is a part of a person, never a whole '
              'one an uncapped take should have spent');
    });

    test('the population written back is the people plus what is left over',
        () {
      final ledger = PopulationLedger();
      ledger.addMigration(2.25);
      expect(ledger.takeArrivals(8), 2);
      ledger.addDeath(0.5);
      // Two people arrived, a quarter of one is still owed, and half a death
      // is owed against them: 2 live people read as 2 + 0.25 − 0.5.
      expect(ledger.writeBack(2), closeTo(1.75, 1e-9));
      expect(ledger.pendingFraction, closeTo(-0.25, 1e-9));
      expect(ledger.lastWritten, closeTo(1.75, 1e-9));

      // Nobody outside moved the population, so nothing reaches the external
      // budget — and asking twice does not invent a delta either.
      ledger.syncExternal(ledger.lastWritten);
      ledger.syncExternal(ledger.lastWritten);
      expect(ledger.external, 0);

      // A test (or a revolt, or a load) writing the field IS the only way in.
      ledger.syncExternal(11.75);
      expect(ledger.external, closeTo(10, 1e-9));
      expect(ledger.takeArrivals(4, external: true), 4);
      expect(ledger.takeArrivals(4), 0,
          reason: 'the external budget is not the migration budget: only a '
              'migration arrival draws a car (§0)');
    });

    test('a whole person the cap held back is not in the population', () {
      // §6.2: "the only lag is the spawn cap". A person still owed is a
      // person who does not exist yet, so `population` does not count them —
      // which is exactly what the parity test measures.
      final ledger = PopulationLedger();
      ledger.addMigration(10.5);
      expect(ledger.takeArrivals(4), 4);
      expect(ledger.migration, closeTo(6.5, 1e-9));
      expect(ledger.writeBack(4), closeTo(4.5, 1e-9));
      expect(ledger.takeArrivals(4), 4, reason: 'offered again next sync');
      expect(ledger.takeArrivals(4), 2, reason: 'and the last two after that');
      expect(ledger.migration, closeTo(0.5, 1e-9),
          reason: 'ten arrived, half a person is still owed');
    });

    test('departures come out of either budget, migration first', () {
      final ledger = PopulationLedger();
      ledger
        ..addMigration(-0.7)
        ..syncExternal(-0.6);
      expect(ledger.external, closeTo(-0.6, 1e-9));
      expect(ledger.takeDepartures(8), 1,
          reason: 'seven tenths owed by one budget and six by the other is '
              'one person leaving, not none');
      expect(ledger.migration, 0, reason: 'drawn down first');
      expect(ledger.external, closeTo(-0.3, 1e-9));
    });

    test('a save carries the budgets and what the ledger last wrote', () {
      final ledger = PopulationLedger()
        ..addMigration(2.5)
        ..addDeath(0.25)
        ..syncExternal(120);
      ledger.writeBack(117);
      final back = PopulationLedger()..restore(ledger.toJson());
      expect(back.migration, ledger.migration);
      expect(back.death, ledger.death);
      expect(back.external, ledger.external);
      expect(back.lastWritten, ledger.lastWritten);
      expect(back.pendingFraction, ledger.pendingFraction,
          reason: 'derived from the budgets, never read from the file');
      expect(back.digest(7), ledger.digest(7));

      // The load-bearing one: a colony resumed WITHOUT `last` would read its
      // whole population as an outside write and reconcile a second town.
      back.syncExternal(back.lastWritten);
      expect(back.external, ledger.external);
      final blind = PopulationLedger()..restore(null);
      expect(blind.isEmpty, isTrue);
      blind.syncExternal(120);
      expect(blind.external, 120,
          reason: 'a colony that has just switched the agents on DOES '
              'reconcile its whole population, through this budget (§14.4)');
    });
  });

  group('realisation spends the budgets', () {
    test('the arrival cap holds, and the remainder is not lost', () {
      final town = CitizenTown();
      final world = FakeCitizenWorld();
      town.ledger.addMigration(40);
      // An empty colony spawns `arrivalsMin` and no more, however many are
      // owed: §6.2's `max(4, 0.02·liveCount)`.
      expect(town.population.spawnCap, AgentTuning.arrivalsMin);
      town.population.realise(0, world, external: false);
      expect(town.citizens.liveCount, 4);
      expect(town.ledger.migration, 36, reason: 'the rest stays owed');

      // And it opens up as the colony grows: a town of four hundred takes
      // eight a sync, not four.
      for (var k = 0; k < 100; k++) {
        town.ledger.addMigration(40);
        town.population.realise(k * kUsPerSecond, world, external: false);
      }
      expect(town.citizens.liveCount, greaterThan(250));
      expect(town.population.spawnCap,
          (AgentTuning.arrivalsShare * town.citizens.liveCount).floor());
      expect(town.population.spawnCap,
          greaterThan(AgentTuning.arrivalsMin));
      expect(town.population.arrivals, town.citizens.liveCount,
          reason: 'nobody died or left, so every arrival is still here');
      expect(town.ledger.migration + town.citizens.liveCount, closeTo(4040, 1),
          reason: '101 syncs owed 40 people each: everyone who is not alive '
              'is still owed, and nobody was rounded away');
    });

    test('an arrival is placed at the home it was drawn for', () {
      final town = CitizenTown();
      final world = FakeCitizenWorld();
      town.ledger.addMigration(4);
      town.population.realise(0, world, external: false);
      expect(world.placedCitizen, hasLength(4));
      for (var k = 0; k < 4; k++) {
        final sl = SlotPool.slotOf(world.placedCitizen[k]);
        expect(town.citizens.home[sl], world.placedHome[k]);
        expect(town.citizens.state[sl], CitizenState.atHome.index,
            reason: 'movingIn resolves in the same sub-step (§0 Q6)');
      }
    });

    test('an external-budget citizen never mints a car', () {
      // §0's reconciliation rule, and the reason the committed v2 fixture
      // still loads with exactly the cars it was saved with: one
      // `city.advance` over a restored save must not invent a single row.
      final town = CitizenTown();
      final world = FakeCitizenWorld();
      town.ledger.syncExternal(40);
      town.population.realise(0, world, external: true);
      expect(town.citizens.liveCount, 4);
      expect(world.minted, isEmpty, reason: 'not one car (§0)');
      expect(world.adoptAsked, hasLength(4),
          reason: 'it asks its home for a legacy car instead');
      for (var k = 0; k < 4; k++) {
        final sl = SlotPool.slotOf(world.placedCitizen[k]);
        expect(town.citizens.car[sl], CitizenTable.carNone);
      }

      // A home WITH a legacy car standing at it hands it over — still not a
      // car minted, and still not a car moved.
      world.legacyAt.addAll(town.homes);
      town.ledger.syncExternal(80);
      town.population.realise(kUsPerSecond, world, external: true);
      expect(world.minted, isEmpty);
      expect(town.population.adopted, 4,
          reason: 'the four arrivals of this sync each took one');
      for (var k = 4; k < world.placedCitizen.length; k++) {
        expect(town.citizens.car[SlotPool.slotOf(world.placedCitizen[k])],
            isNot(CitizenTable.carNone));
      }

      // The migration budget is the other rule: it draws `carOwnership`.
      AgentTuning.carOwnership = 1;
      town.ledger.addMigration(4);
      town.population.realise(2 * kUsPerSecond, world, external: false);
      expect(world.minted, hasLength(4),
          reason: 'every migration arrival with a home draws a car (§6.6)');
    });

    test('a licence is drawn for every arrival, however it came', () {
      // The draw is made whether or not there is a home to park a car at, so
      // that a colony with no vacancy left makes the same draws as one with
      // room: the stream must not depend on the housing.
      AgentTuning.carOwnership = 0;
      final town = CitizenTown();
      final world = FakeCitizenWorld();
      town.ledger.addMigration(4);
      town.population.realise(0, world, external: false);
      expect(world.minted, isEmpty, reason: 'nobody owns a car at 0');
      for (final c in world.placedCitizen) {
        expect(town.citizens.flags[SlotPool.slotOf(c)] & CitizenFlags.hasLicence,
            0);
      }
      AgentTuning.carOwnership = 1;
      town.ledger.addMigration(4);
      town.population.realise(kUsPerSecond, world, external: false);
      for (var k = 4; k < world.placedCitizen.length; k++) {
        final sl = SlotPool.slotOf(world.placedCitizen[k]);
        expect(town.citizens.flags[sl] & CitizenFlags.hasLicence,
            CitizenFlags.hasLicence);
      }
    });

    test('emigration is the homeless, then the unemployed, then a draw', () {
      final town = CitizenTown();
      final world = FakeCitizenWorld();
      final homes = town.homes, jobs = town.jobs;
      expect(homes.length, greaterThan(2));
      expect(jobs, isNotEmpty);
      final housedAndEmployed = <int>[
        for (var k = 0; k < 3; k++)
          town.add(home: homes[k], work: jobs[k % jobs.length]),
      ];
      final unemployed = town.add(home: homes[homes.length - 1]);
      final homeless = town.add();

      town.ledger.addMigration(-1);
      town.population.realise(0, world, external: false);
      expect(world.gone, [homeless], reason: 'nothing to lose goes first');

      town.ledger.addMigration(-1);
      town.population.realise(0, world, external: false);
      expect(world.gone.last, unemployed, reason: 'then no job');

      town.ledger.addMigration(-1);
      town.population.realise(0, world, external: false);
      expect(housedAndEmployed, contains(world.gone.last),
          reason: 'and then somebody, drawn');
      expect(town.population.departures, 3);
      expect(town.citizens.liveCount, 2);
    });

    test('an emigrant takes their car out of the world with them', () {
      final town = CitizenTown();
      final world = FakeCitizenWorld();
      final c = town.add(home: town.homes[0], car: 77);
      town.ledger.addMigration(-1);
      town.population.realise(0, world, external: false);
      expect(world.gone, [c]);
      expect(world.released, [77],
          reason: 'a parked car nobody owns would stand on its stall for ever');
    });

    test('a death lands on a home and on BuildingTable.corpses', () {
      final town = CitizenTown();
      final world = _BuryingWorld(town);
      final home = town.homes[0];
      final resident = town.add(home: home, car: 42);
      town.sync();
      town.ledger.addDeath(1);
      town.population.realise(0, world, external: false);

      expect(world.corpses, [home]);
      expect(town.buildings.corpses[home], 1,
          reason: 'what slice 5\'s hearses come for (§6.2)');
      expect(world.released, [42]);
      expect(town.citizens.isLive(resident), isFalse);
      expect(town.population.deaths, 1);
    });

    test('a homeless death lands on the building they slept nearest', () {
      final town = CitizenTown();
      final world = _BuryingWorld(town);
      final near = town.homes[1];
      final c = town.add();
      town.citizens.sleepsNear[SlotPool.slotOf(c)] = near;
      town.sync();
      town.ledger.addDeath(1);
      town.population.realise(0, world, external: false);
      expect(world.corpses, [near], reason: '§6.2\'s homeless death, §9.2');
      expect(town.buildings.corpses[near], 1);
    });
  });

  group('a legacy car is adopted once, and only once (§0)', () {
    test('a carless resident of its owner building takes it, and nobody '
        'else ever does', () {
      final town = CitizenTown();
      final cars = ParkedCarTable(capacity: 8);
      final home = town.homes[0], work = town.jobs[0];
      // A T4a `commuter` row: its owner is a BUILDING slot — the home the
      // car came from — and it stands at the site its driver drove it to.
      final car = cars.parkLot(
          building: work,
          row: 0,
          stall: 0,
          stallKey: 11,
          ownerKind: CarOwnerKind.commuter,
          owner: home,
          kind: 0,
          variant: 0);
      final first = town.add(home: home);
      final second = town.add(home: home);

      expect(town.population.adoptLegacy(0, cars), 1);
      expect(town.population.adopted, 1);
      expect(town.population.legacyCars, 0, reason: 'none left standing');
      expect(cars.ownerKindOf(car), CarOwnerKind.citizen.index);
      expect(cars.ownerOf(car), first,
          reason: 'the oldest carless resident, in arrival order');
      expect(town.citizens.car[SlotPool.slotOf(first)], car);
      expect(town.citizens.car[SlotPool.slotOf(second)],
          CitizenTable.carNone);
      expect(town.citizens.state[SlotPool.slotOf(first)],
          CitizenState.atWork.index,
          reason: 'the car is not at their home, so they are where it is');
      final wake = town.citizens.wakeUs[SlotPool.slotOf(first)];
      expect(wake, greaterThanOrEqualTo(usOf(AgentTuning.commuteReturnMinS)
          .toDouble()));
      expect(wake,
          lessThanOrEqualTo(usOf(AgentTuning.commuteReturnMaxS).toDouble()));
      expect(cars.count, 1, reason: 'adoption moves no row and makes none');

      // Swept again: the car is a citizen's now, so it is neither offered
      // nor counted, and the second resident is still carless.
      expect(town.population.adoptLegacy(0, cars), 0);
      expect(town.population.adopted, 1);
      expect(cars.ownerOf(car), first);
      expect(town.citizens.car[SlotPool.slotOf(second)],
          CitizenTable.carNone);
    });

    test('a car at the home it belongs to leaves its owner where they are',
        () {
      final town = CitizenTown();
      final cars = ParkedCarTable(capacity: 8);
      final home = town.homes[0];
      final car = cars.parkLot(
          building: home,
          row: 0,
          stall: 0,
          stallKey: 3,
          ownerKind: CarOwnerKind.homePool,
          owner: home,
          kind: 0,
          variant: 0);
      final c = town.add(home: home, wakeUs: 1234);
      expect(town.population.adoptLegacy(0, cars), 1);
      expect(town.citizens.car[SlotPool.slotOf(c)], car);
      expect(town.citizens.state[SlotPool.slotOf(c)], CitizenState.atHome.index,
          reason: 'their car is at home with them: nothing about their day '
              'changed');
      expect(town.citizens.wakeUs[SlotPool.slotOf(c)], 1234);
    });

    test('a car nobody can take stands, and is offered again', () {
      final town = CitizenTown();
      final cars = ParkedCarTable(capacity: 8);
      final home = town.homes[0], other = town.homes[1];
      final car = cars.garage(
          building: home,
          ownerKind: CarOwnerKind.homePool,
          owner: home,
          kind: 0,
          variant: 0);
      // Nobody lives there yet.
      expect(town.population.adoptLegacy(0, cars), 0);
      expect(town.population.legacyCars, 1, reason: 'still standing (§0 Q3)');
      expect(cars.ownerKindOf(car), CarOwnerKind.homePool.index);
      expect(cars.ownerOf(car), home);

      // Somebody at ANOTHER home cannot take it either: the owner column
      // says which home the car is from, and that is the rule.
      town.add(home: other);
      expect(town.population.adoptLegacy(0, cars), 0);
      expect(town.population.legacyCars, 1);

      // And then somebody moves in.
      final c = town.add(home: home);
      expect(town.population.adoptLegacy(0, cars), 1);
      expect(town.population.legacyCars, 0);
      expect(cars.ownerOf(car), c);
    });

    test('the facade finds the same car this sweep would', () {
      // `CityAgents.adoptCarAt` and the sweep must agree about which car is
      // free, or a car could be owned twice. They are one rule.
      final cars = ParkedCarTable(capacity: 8);
      expect(CitizenPopulation.freeLegacyCarAt(cars, 3), SlotPool.none);
      final car = cars.garage(
          building: 3,
          ownerKind: CarOwnerKind.commuter,
          owner: 3,
          kind: 0,
          variant: 0);
      expect(CitizenPopulation.freeLegacyCarAt(cars, 3), car);
      expect(CitizenPopulation.freeLegacyCarAt(cars, 4), SlotPool.none);
      expect(CitizenPopulation.freeLegacyCarAt(cars, -1), SlotPool.none);
      cars.reown(car, CarOwnerKind.citizen, 900);
      expect(CitizenPopulation.freeLegacyCarAt(cars, 3), SlotPool.none,
          reason: 'a car a citizen owns is never a legacy car again');
    });
  });

  test('§17.3 #20: the citizens track the scalar model within 5%', () {
    // The parity §6.2 promises: ten agent-minutes of a growing town, with
    // `CitySim`'s own arithmetic on one side and the people on the other.
    // The scalar here plays E9 and E8 — a compounding migration rate and a
    // death rate — and adds only its DELTA to the ledger, as the tick does.
    final town = CitizenTown();
    final world = FakeCitizenWorld();
    town.populate(perHome: 2);
    final founded = town.citizens.liveCount;
    var model = founded.toDouble();
    expect(model, greaterThan(20), reason: 'a town, not a hamlet');
    town.ledger.writeBack(town.citizens.liveCount);

    const tickS = 0.5;
    const growthPerS = 0.004, deathPerS = 0.0005;
    var worst = 0.0;
    var us = 0;
    for (var step = 0; step * tickS < 600; step++) {
      // Step 15 and step 12 of the tick (§12.1): the budgets, never the
      // field.
      final grew = model * growthPerS * tickS;
      final died = model * deathPerS * tickS;
      model += grew - died;
      town.ledger
        ..addMigration(grew)
        ..addDeath(died);
      us = addClock(us, usOf(tickS));
      // Realisation runs on a whole second, as `_subStep` will (§5.2).
      if (step.isEven) {
        town.population.realise(us, world, external: false);
        town.population.realise(us, world, external: true);
      }
      final wrote = town.ledger.writeBack(town.citizens.liveCount);
      // Nobody outside the agents touched the population, so the external
      // budget must stay empty for the whole run: a write-back read back as
      // an outside write would double the town.
      town.ledger.syncExternal(wrote);
      expect(town.ledger.external, 0,
          reason: 'the write-back is not an outside write');
      final off = (town.citizens.liveCount - model).abs() / model;
      if (off > worst) worst = off;
    }

    expect(worst, lessThan(0.05),
        reason: 'the only lag is the spawn cap (§6.2): the citizens were '
            '${town.citizens.liveCount} against a model of '
            '${model.toStringAsFixed(1)}, worst gap '
            '${(worst * 100).toStringAsFixed(2)}%');
    expect(
        founded +
            town.population.arrivals -
            town.population.departures -
            town.population.deaths,
        town.citizens.liveCount,
        reason: 'every person is accounted for: the town it was founded '
            'with, plus who arrived, less who left and who died');
  });
}

/// A [FakeCitizenWorld] that actually buries its dead, so the test can see
/// `BuildingTable.corpses` move (§6.2: the corpse is the world's to record,
/// and slice 5's hearses come for it).
class _BuryingWorld extends FakeCitizenWorld {
  _BuryingWorld(this.town);

  final CitizenTown town;

  @override
  void corpseAt(int buildingSlot) {
    super.corpseAt(buildingSlot);
    town.buildings.corpses[buildingSlot] += 1;
  }
}
