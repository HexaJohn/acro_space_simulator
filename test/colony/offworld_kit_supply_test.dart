// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The starter kit off Earth: a colony that lives on the player's supply
/// chain from its first day.
///
/// Founded bare on the Moon, the kit's town had no oxygen and nothing to make
/// it with, so nobody could ever arrive — a dead colony that read as a quiet
/// one. Now the kit stocks and books what the world withholds, and every
/// assertion here is one way that lifeline could be cut, mis-sized or
/// forgotten: the town must live on it, die without it, and stay dependent
/// because of it.
void main() {
  /// One colony day on the loyalty calendar (`CityLoyaltyTuning.daySec`).
  const day = 120.0;

  CitySim kit(String body,
          {CityStart start = CityStart.standard,
          Biome? biome,
          double? complexity}) =>
      quiet(CityStarterKit.found(
        bodies: fixtureBodies,
        config: CityConfig(
            bodyId: body, gridSize: 20, biome: biome, complexity: complexity),
        start: start,
      ));

  /// The kit with its starter block zoned and built: a town, not a crew.
  CitySim kitTown(String body, {CityStart start = CityStart.standard}) {
    final city = kit(body, start: start);
    zoneAll(city);
    buildAll(city);
    return city;
  }

  String portOf(CitySim city) => city.landingPads().first.$1.id;

  List<DeliverySchedule> runsOf(CitySim city) =>
      city.deliveries[portOf(city)] ?? const [];

  group('what the kit makes, and what it books', () {
    test('Earth founds as it always did: nothing booked, no air stocked', () {
      for (final start in CityStart.values) {
        for (final biome in [null, Biome.desert, Biome.volcano]) {
          final city = kit('earth', start: start, biome: biome);
          expect(CityStarterKit.shortfall(city), isEmpty,
              reason: '${start.name} $biome: Earth withholds nothing');
          expect(city.deliveries, isEmpty);
          expect(city.stock.containsKey(Commodity.oxygen), isFalse,
              reason: 'the sky is the larder');
        }
      }
    });

    test('the Moon, Mars and Venus grow their own; only the air is shipped',
        () {
      for (final body in ['moon', 'mars', 'venus']) {
        final city = kit(body);
        final need = CityStarterKit.shortfall(city);
        expect(need.keys, [Commodity.oxygen], reason: body);
        final pop = CityStarterKit.designPopulation(city);
        expect(need[Commodity.oxygen],
            closeTo(pop * CitySim.waterPerPersonPerSec * 1.25, 1e-9),
            reason: '$body: the whole town\'s air, a quarter over');

        final run = runsOf(city).single;
        expect(run.resource, Commodity.oxygen);
        expect(run.recurring, isTrue);
        expect(run.spareFuel, isTrue, reason: 'no colony fuel needed');
        expect(run.intervalSec, CityStarterKit.supplyIntervalSec);
        expect(city.landedPayloadOf(run),
            closeTo(need[Commodity.oxygen]! * run.intervalSec, 1e-6),
            reason: '$body: what lands, after the return burn, is a day');
        expect(city.bookedLifeImports()[Commodity.oxygen],
            closeTo(need[Commodity.oxygen]!, 1e-9));
      }
    });

    test('in Titan\'s twilight the kit cannot power its farm: all three fly',
        () {
      final city = kit('titan');
      final need = CityStarterKit.shortfall(city);
      expect(runsOf(city).map((r) => r.resource),
          [Commodity.oxygen, Commodity.water, Commodity.food],
          reason: 'booked in order of urgency');
      // The farm and pump run on a quarter of the power they draw, so the
      // freight brings the three quarters the dark costs, with headroom.
      final pop = CityStarterKit.designPopulation(city);
      expect(need[Commodity.water]! / 1.25,
          closeTo(pop * CitySim.waterPerPersonPerSec * 0.75, 1e-6));
      expect(
          runsOf(city).length / CityStarterKit.supplyIntervalSec,
          lessThanOrEqualTo(1 / CitySim.craftTotalSec),
          reason: 'three runs a day fit the kit\'s one pad');
    });

    test('below COMPLEXITY 0.3 the air is not managed, so none is shipped',
        () {
      final city = kit('moon', complexity: 0.2);
      expect(CityStarterKit.shortfall(city), isEmpty);
      expect(city.deliveries, isEmpty);
    });

    test('the difficulty still sets the opening position, air included', () {
      for (final start in CityStart.values) {
        // Not [kit]: that quiets the weather this test reads.
        final city = CityStarterKit.found(
          bodies: fixtureBodies,
          config: const CityConfig(bodyId: 'moon', gridSize: 20),
          start: start,
        );
        expect(city.funds, start.funds);
        expect(city.stockOf(Commodity.ore), start.ore);
        expect(city.stockOf(Commodity.food), start.supplies);
        expect(city.stockOf(Commodity.water), start.supplies);
        expect(city.stockOf(Commodity.oxygen), start.supplies,
            reason: 'the air is opening supply like the larder');
        expect(city.hostility, start.hostility);
        expect(city.bounty, start.bounty);
        // The bounty sizes the farm and pump, and so the town, and so the
        // freight that keeps it breathing.
        expect(
            CityStarterKit.shortfall(city)[Commodity.oxygen],
            closeTo(
                CityStarterKit.designPopulation(city) *
                    CitySim.waterPerPersonPerSec *
                    CityStarterKit.supplyHeadroom,
                1e-9));
      }
      expect(
          CityStarterKit.designPopulation(kit('moon', start: CityStart.harsh)),
          lessThan(CityStarterKit.designPopulation(
              kit('moon', start: CityStart.relaxed))));
    });
  });

  group('alive and stable for thirty colony days', () {
    for (final body in ['moon', 'mars', 'venus', 'titan']) {
      test('$body: the crew arrives and the kit town settles at its size', () {
        final crew = kit(body);
        run(crew, 30 * day);
        expect(crew.population, closeTo(CitySim.landerCrew, 1e-6),
            reason: 'the crew lands — the colony that never started');
        expect(crew.starved, isFalse);

        final town = kitTown(body);
        final design = CityStarterKit.designPopulation(town);
        run(town, 20 * day);
        final day20 = town.population;
        run(town, 10 * day);
        expect(town.population, greaterThan(0.9 * design),
            reason: '$body: the town the kit was built for');
        expect(town.population, closeTo(day20, 0.03 * day20),
            reason: '$body: settled, not sliding');
        expect(town.starved, isFalse);
        expect(town.foodSecurity, greaterThan(0.95));
        expect(town.stockOf(Commodity.oxygen), greaterThan(0),
            reason: 'the tank never ran dry');
      });
    }
  });

  group('the supply chain is the lifeline', () {
    test('cancelling the air run empties the town', () {
      final town = kitTown('moon');
      run(town, 20 * day);
      final before = town.population;
      final tank = town.stockOf(Commodity.oxygen);
      // As the delivery manager removes it.
      final runs = town.deliveries[portOf(town)]!;
      runs.removeWhere((r) => r.resource == Commodity.oxygen);
      if (runs.isEmpty) town.deliveries.remove(portOf(town));
      expect(town.bookedLifeImports(), isEmpty);
      run(town, 10 * day);
      expect(town.population, lessThan(0.25 * before),
          reason: 'with no air booked, the town can hold only what the '
              'tank keeps, and the tank is draining');
      expect(town.stockOf(Commodity.oxygen), lessThan(0.25 * tank));
    });

    test('a seized port cuts the air, and the trapped town suffocates', () {
      final town = kitTown('moon');
      run(town, 20 * day);
      final before = town.population;
      town.loyalty
        ..tuning = const CityLoyaltyTuning(independenceBar: 5)
        ..level = 0.05
        ..desperation = 0.5
        ..stage = LoyaltyStage.standoff
        ..portSeized = true
        ..impoundPending = true;
      expect(town.bookedLifeImports(), isEmpty,
          reason: 'the freight stops counting the moment the port is held');
      run(town, 10 * day);
      expect(town.loyalty.portSeized, isTrue);
      expect(town.loyalty.impounded.map((c) => c.resource),
          contains(Commodity.oxygen),
          reason: 'the next run was impounded');
      expect(town.stockOf(Commodity.oxygen), lessThan(1));
      expect(town.deathRate, greaterThan(0));
      expect(town.population, lessThan(0.75 * before),
          reason: 'shut in: they die where they stand');
    });

    test('misruled, the town stands off — it cannot breathe alone', () {
      final town = kitTown('moon');
      run(town, 20 * day);
      expect(town.loyalty.selfSufficiency, lessThan(0.1),
          reason: 'freight is not a local source');
      final t = town.colonyTimeS;
      town.loyalty.revolts.addAll([t, t, t]);
      run(town, 2);
      expect(town.loyalty.stage, LoyaltyStage.standoff);
      expect(town.loyalty.allegiance, Allegiance.colonial);
      expect(town.loyaltyWarnings().map((w) => w.text),
          contains(startsWith('Would secede, but cannot feed itself')));
    });

    test('the standing orders survive a save and a load, and keep it alive',
        () {
      final town = kitTown('titan');
      run(town, 10 * day);
      final loaded = CitySim.fromJson(
          jsonDecode(jsonEncode(town.toJson())) as Map<String, dynamic>,
          bodies: fixtureBodies);
      quiet(loaded);
      final a = runsOf(town), b = runsOf(loaded);
      expect(b, hasLength(a.length));
      for (var i = 0; i < a.length; i++) {
        expect(b[i].resource, a[i].resource);
        expect(b[i].amount, a[i].amount);
        expect(b[i].intervalSec, a[i].intervalSec);
        expect(b[i].timer, a[i].timer);
        expect(b[i].padIndex, a[i].padIndex);
        expect(b[i].spareFuel, a[i].spareFuel);
        expect(b[i].recurring, a[i].recurring);
      }
      final pop = loaded.population;
      run(loaded, 20 * day);
      expect(loaded.population, closeTo(pop, 0.05 * pop),
          reason: 'a load that dropped the orders suffocated the town');
    });

    test('an edited run is the player\'s, and saves as edited', () {
      final city = kit('moon');
      runsOf(city).single
        ..padIndex = 0
        ..spareFuel = false
        ..intervalSec = 60;
      final loaded = CitySim.fromJson(
          jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
          bodies: fixtureBodies);
      final run = runsOf(loaded).single;
      expect(run.padIndex, 0);
      expect(run.spareFuel, isFalse);
      expect(run.intervalSec, 60);
      expect(run.recurring, isTrue);
    });
  });
}
