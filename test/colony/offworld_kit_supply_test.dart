// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
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
          final why = '${start.name} $biome';
          final config =
              CityConfig(bodyId: 'earth', gridSize: 20, biome: biome);
          // Not [kit]: quieting is no part of the founding being pinned.
          final city = CityStarterKit.found(
              bodies: fixtureBodies, config: config, start: start);
          expect(CityStarterKit.shortfall(city), isEmpty,
              reason: '$why: Earth withholds nothing');
          expect(city.deliveries, isEmpty);
          // The whole larder, exactly: a bare colony's, with the opening
          // balance the kit has always set, and nothing else.
          final bare = CitySim.found(start.configure(config),
              bodies: fixtureBodies);
          expect(
              city.stock,
              {
                ...bare.stock,
                Commodity.ore: start.ore,
                Commodity.food: start.supplies,
                Commodity.water: start.supplies,
              },
              reason: '$why: the sky is the larder');
          expect(city.stock.containsKey(Commodity.oxygen), isFalse);
          // And it saves as it always has, founded and once advanced.
          for (var tick = 0; tick < 2; tick++) {
            final saved = city.toJson();
            expect(saved.containsKey('deliveries'), isFalse, reason: why);
            expect(saved.containsKey('inbound'), isFalse, reason: why);
            city.advance(0.5);
          }
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
      // freight brings the three quarters the dark costs — no more, or the
      // town grows into the air's headroom (see the settling test).
      final pop = CityStarterKit.designPopulation(city);
      expect(need[Commodity.water],
          closeTo(pop * CitySim.waterPerPersonPerSec * 0.75, 1e-6));
      expect(need[Commodity.oxygen],
          closeTo(pop * CitySim.waterPerPersonPerSec * 1.25, 1e-6),
          reason: 'the air alone flies a quarter over');
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
    for (final body in ['moon', 'mars', 'venus', 'titan', 'europa', 'ceres']) {
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
        // Watched tick by tick: freight lands a lump a day, so a tank that
        // runs dry before the next one shows only between looks.
        final booked = town.bookedLifeImports().keys.toList();
        final low = {for (final c in booked) c: double.infinity};
        var peak = 0.0;
        for (var i = 0; i < 10 * day / 0.5; i++) {
          town.advance(0.5);
          for (final c in booked) {
            low[c] = math.min(low[c]!, town.stockOf(c));
          }
          peak = math.max(peak, town.population);
        }
        expect(town.population, greaterThan(0.9 * design),
            reason: '$body: the town the kit was built for');
        expect(peak, lessThan(1.05 * design),
            reason: '$body: and no bigger — the headroom is spare, not '
                'room to grow into');
        expect(town.population, closeTo(day20, 0.03 * day20),
            reason: '$body: settled, not sliding');
        expect(town.starved, isFalse);
        expect(town.foodSecurity, greaterThan(0.95));
        for (final c in booked) {
          expect(low[c], greaterThan(0),
              reason: '$body: the $c tank never ran dry between runs');
        }
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

    test('a run on its way down survives a save, and lands after the load',
        () {
      final town = kitTown('moon');
      run(town, 5 * day);
      bool inbound(LandedCraft c) =>
          !c.isRelief && !c.granted && c.resource != null;
      // The window the save fell into: the run sent, its schedule rearmed
      // for tomorrow, its cargo not yet down.
      var guard = 0;
      while (!town.craft.any(inbound) && guard++ < 1000) {
        town.advance(0.5);
      }
      final craft = town.craft.singleWhere(inbound);
      expect(runsOf(town).single.timer,
          greaterThan(CityStarterKit.supplyIntervalSec - 10),
          reason: 'already rearmed: the run will not fly again today');
      final loaded = quiet(CitySim.fromJson(
          jsonDecode(jsonEncode(town.toJson())) as Map<String, dynamic>,
          bodies: fixtureBodies));
      final back = loaded.craft.singleWhere(inbound);
      expect(back.site, craft.site);
      expect(back.padIndex, craft.padIndex);
      expect(back.resource, craft.resource);
      expect(back.payload, craft.payload);
      expect(back.phase, craft.phase);
      run(town, 10);
      run(loaded, 10);
      expect(loaded.craft.where(inbound), isEmpty, reason: 'it landed');
      expect(loaded.stockOf(Commodity.oxygen),
          closeTo(town.stockOf(Commodity.oxygen), 1.0),
          reason: 'a load that dropped it lost a day\'s air');
    });
  });

  group('counted as it lands', () {
    test('a crowded port counts the pads its dispatcher gives the air', () {
      final city = kit('titan');
      final air = runsOf(city).first;
      expect(air.resource, Commodity.oxygen);
      // A player's ore run every 30 s, after the kit's: more than the one
      // pad can turn round, so the port is booked past its pads.
      runsOf(city).add(DeliverySchedule(
          resource: Commodity.ore, intervalSec: 30, amount: 200)
        ..recurring = true);
      final counted = city.bookedLifeImports()[Commodity.oxygen]!;
      expect(
          counted,
          closeTo(
              city.landedPayloadOf(air) /
                  (air.intervalSec + CitySim.craftTotalSec),
              1e-9),
          reason: 'the dispatcher flies the runs in list order, so the air '
              'keeps its pad — and waits a turn-round for it');
      // What really comes: the air landed between the first run down and
      // the last, over the time between them.
      final seen = <LandedCraft>{};
      final landings = <double>[];
      var landed = 0.0;
      for (var i = 1; i <= 20 * day / 0.5; i++) {
        city.advance(0.5);
        for (final c in city.craft) {
          if (c.granted && c.resource == Commodity.oxygen && seen.add(c)) {
            if (landings.isNotEmpty) landed += c.payload;
            landings.add(i * 0.5);
          }
        }
      }
      expect(landings.length, greaterThan(10));
      final perSec = landed / (landings.last - landings.first);
      expect(counted, lessThanOrEqualTo(perSec),
          reason: 'never counts air that does not come');
      expect(counted, greaterThan(0.85 * perSec),
          reason: 'the ore\'s share is cut from the ore, not from the air');
    });

    test('a run behind one that takes every pad counts nothing', () {
      final city = kit('moon');
      runsOf(city).insert(
          0,
          DeliverySchedule(
              resource: Commodity.ore, intervalSec: 30, amount: 200)
            ..recurring = true);
      expect(city.bookedLifeImports(), isEmpty);
      final before = city.stockOf(Commodity.oxygen);
      run(city, 3 * day);
      expect(city.stockOf(Commodity.oxygen), lessThanOrEqualTo(before),
          reason: 'and none comes');
    });

    test('a load bigger than the store counts what the store keeps', () {
      final city = kit('moon');
      final air = runsOf(city).single..amount = 4000;
      expect(city.landedPayloadOf(air), greaterThan(city.stockCap));
      expect(city.bookedLifeImports()[Commodity.oxygen],
          closeTo(city.stockCap / air.intervalSec, 1e-9),
          reason: 'the rest spills on the apron');
    });

    test('a town grown to its air run never breathes out of an empty tank',
        () {
      final city = kit('moon');
      // Water, food and power to spare, so only the air run sets the size.
      final lots = freeLots(city);
      final pump = kUtilCatalog.firstWhere((s) => s.type == 'aquifer');
      final farm = kUtilCatalog.firstWhere((s) => s.label == 'Farm');
      final solar = kUtilCatalog.firstWhere((s) => s.type == 'solar');
      for (final (i, spec) in [pump, pump, farm, farm, solar, solar].indexed) {
        city.placeOnParcel(lots[i].id, spec);
      }
      zoneAll(city, const [ParcelUse.residential]);
      buildAll(city, density: Density.high);
      run(city, 20 * day);
      final air = city.bookedLifeImports()[Commodity.oxygen]!;
      final perPerson = CitySim.waterPerPersonPerSec * (1 - city.airO2);
      var dry = 0;
      var peak = 0.0;
      for (var i = 0; i < 10 * day / 0.5; i++) {
        city.advance(0.5);
        if (city.stockOf(Commodity.oxygen) <= 0) dry++;
        peak = math.max(peak, city.population);
      }
      expect(peak, greaterThan(0.95 * air / perPerson),
          reason: 'the town did grow to its freight');
      expect(peak, lessThan(1.01 * air / perPerson),
          reason: 'the lump just landed is tomorrow\'s air, not room to grow');
      expect(dry, 0, reason: 'so the tank never empties before a run');
    });

    test('an empty tank is a shortage, whatever is booked', () {
      final town = kitTown('moon');
      run(town, 20 * day);
      expect(town.foodSecurity, greaterThan(0.95));
      // The air run is late, and the tank is dry.
      town.craft.removeWhere((c) => !c.granted);
      runsOf(town).single.timer = 60;
      town.stock[Commodity.oxygen] = 0;
      run(town, 10);
      expect(town.bookedLifeImports()[Commodity.oxygen], greaterThan(0),
          reason: 'still booked');
      expect(town.foodSecurity, lessThan(0.5),
          reason: 'freight still in orbit feeds nobody');
      expect(town.deathRate, greaterThan(0));
    });
  });
}
