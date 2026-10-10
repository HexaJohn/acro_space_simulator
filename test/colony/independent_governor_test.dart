// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/independent_governor.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The independent governor (docs/plans/colony-secession.md §4, phase 2): a
/// seceded colony's own council, deliberately dumb, that keeps it alive and
/// growing slowly — and that never touches a colony still the player's.
void main() {
  const day = 120.0; // the loyalty calendar's day, colony seconds

  /// Declare [city] independent now, as `CityLoyalty._secede` would.
  void secede(CitySim city) {
    city.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..independentAtS = city.colonyTimeS
      ..independenceCauses = 'no orders for 50 days';
  }

  int zonedLots(CitySim city) => city.layout.autoParcels
      .where((p) => p.use != ParcelUse.unzoned)
      .length;

  Iterable<CityBuildingSpec> built(CitySim city) =>
      city.buildingParcels().map((e) => e.$2);

  int farms(CitySim city) => built(city)
      .where((s) => (s.outputs[Commodity.food] ?? 0) > 0 &&
          CitySim.isLifeSupport(s))
      .length;

  test('it keeps a seceded Earth town alive and slowly growing', () {
    final city = starterKit();
    run(city, 2 * day);
    secede(city);
    final pop0 = city.population;
    final zoned0 = zonedLots(city);
    var lowest = pop0;
    for (var d = 0; d < 40; d++) {
      run(city, day);
      if (city.population < lowest) lowest = city.population;
    }
    expect(city.loyalty.allegiance, Allegiance.independent);
    expect(lowest, greaterThan(0.5 * pop0), reason: 'never withers');
    expect(city.population, greaterThan(pop0 + 5),
        reason: 'it grows: ${city.population} from $pop0');
    expect(zonedLots(city), greaterThan(zoned0),
        reason: 'the council zoned lots to grow into');
    expect(city.governorLog.map((a) => a.kind),
        contains(GovernorActKind.zone));
    expect(city.starved, isFalse);
  });

  test('it builds a farm when food runs short', () {
    final city = starterKit();
    run(city, 2 * day);
    // A disaster took the farm.
    final farmLot = city.buildingParcels()
        .firstWhere((e) => e.$2.label == 'Farm')
        .$1
        .id;
    city.clearParcel(farmLot);
    expect(farms(city), 0);
    secede(city);
    final ore0 = city.stockOf(Commodity.ore);
    run(city, 3 * day + 1); // the first sitting
    expect(farms(city), 1, reason: city.governorLog.map((a) => a.text).join('; '));
    final act = city.governorLog
        .firstWhere((a) => a.kind == GovernorActKind.lifeSupport);
    expect(act.text, contains('Farm'));
    expect(act.text, contains('food'));
    expect(city.stockOf(Commodity.ore), lessThanOrEqualTo(ore0 - act.oreSpent + 1),
        reason: 'paid for out of its own store');
  });

  /// Every act the governor logs while [city] runs [days] days, one day a
  /// run: the log itself is bounded, so it is drained as it goes.
  List<GovernorAct> actsOver(CitySim city, int days) {
    final all = <GovernorAct>[];
    for (var d = 0; d < days; d++) {
      run(city, day);
      all.addAll(city.governorLog);
      city.governorLog.clear();
    }
    return all;
  }

  test('with the power out it builds a generator, not dark farms', () {
    final city = starterKit();
    run(city, 2 * day);
    // The Solar Farm, the town's only generator, burned.
    for (final e in city.buildingParcels().toList()) {
      if (e.$2.powerOutput > 0) city.clearParcel(e.$1.id);
    }
    city.stock[Commodity.ore] = 700;
    secede(city);
    final lifeBefore = built(city).where(CitySim.isLifeSupport).length;
    final acts = actsOver(city, 30);
    final log = acts.map((a) => '${a.kind.name}: ${a.text}').join('; ');
    final firstPower = acts.indexWhere((a) => a.kind == GovernorActKind.power);
    expect(firstPower, isNot(-1), reason: log);
    expect(
        acts.take(firstPower).where((a) => a.kind == GovernorActKind.lifeSupport),
        isEmpty,
        reason: 'nothing built that could not run: $log');
    expect(city.powerOut, greaterThan(0));
    expect(city.lifeThrottle, greaterThan(0), reason: log);
    // It answered the cause, then stopped: not a building a sitting.
    final lifeAfter = built(city).where(CitySim.isLifeSupport).length;
    expect(lifeAfter - lifeBefore, lessThanOrEqualTo(3), reason: log);
    expect(city.stockOf(Commodity.ore), greaterThan(400), reason: log);
  });

  test('a water-starved town gets its pump before another thirsty farm', () {
    final city = starterKit();
    run(city, 2 * day);
    for (final e in city.buildingParcels().toList()) {
      if ((e.$2.outputs[Commodity.water] ?? 0) > 0) city.clearParcel(e.$1.id);
    }
    city.stock[Commodity.water] = 0;
    city.stock[Commodity.ore] = 400;
    city.lifeThrottle = 1; // power and hands to spare
    secede(city);
    final acts = city.governIndependent(localNet: const {});
    final build = acts.firstWhere((a) => a.oreSpent > 0,
        orElse: () => throw TestFailure('built nothing: '
            '${acts.map((a) => a.text).join('; ')}'));
    expect(build.kind, GovernorActKind.lifeSupport);
    expect(build.text, contains('water'), reason: build.text);
    expect(build.text, isNot(contains('built a Farm')), reason: build.text);
    expect(
        built(city).where((s) => (s.outputs[Commodity.water] ?? 0) > 0),
        isNotEmpty);
  });

  test('hands, not buildings: a short-staffed farm gets no twin', () {
    final city = starterKit();
    run(city, 2 * day);
    secede(city);
    city.stock[Commodity.ore] = 400;
    final farms0 = farms(city);
    // The farm and pump are built and powered, but there are not the people
    // to work them: another farm is more jobs for the same few hands.
    city.lifeThrottle = 0.3;
    final acts = city.governIndependent(localNet: const {});
    expect(acts.where((a) => a.kind == GovernorActKind.lifeSupport), isEmpty,
        reason: acts.map((a) => a.text).join('; '));
    expect(farms(city), farms0);
  });

  test('a flat colony with no water source builds the water, not farms', () {
    final city = foundFlat();
    city.ignoreUnlocks = true;
    city.stock[Commodity.ore] = 400;
    // A road along one edge, a generator, homes, and a farm with nothing to
    // water it.
    final hy = city.hubKey ~/ city.grid;
    for (var x = 0; x < city.grid; x++) {
      final k = hy * city.grid + x;
      if (k != city.hubKey) city.addRoad(k);
    }
    final solar = kUtilCatalog.firstWhere((s) => s.type == 'solar');
    final farm = kUtilCatalog.firstWhere((s) => s.label == 'Farm');
    city.placeUtil((hy + 1) * city.grid + 1, solar);
    city.placeUtil((hy + 1) * city.grid + 4, farm);
    city.recompute();
    run(city, 5);
    city.population = 40;
    city.lifeThrottle = 1;
    secede(city);
    final acts = <GovernorAct>[];
    for (var i = 0; i < 3; i++) {
      acts.addAll(city.governIndependent(localNet: const {}));
    }
    final builds = acts.where((a) => a.kind == GovernorActKind.lifeSupport);
    expect(builds, isNotEmpty, reason: acts.map((a) => a.text).join('; '));
    expect(builds.first.text, contains('water'),
        reason: builds.map((a) => a.text).join('; '));
    expect(builds.where((a) => a.text.startsWith('built a Farm')), isEmpty,
        reason: builds.map((a) => a.text).join('; '));
  });

  // The cross-lane seam (terraforming phase 2 × secession phase 2): an
  // Atmospheric Harvester stands idle under a sky its intakes have thinned
  // below 2% oxygen, so the council must not count it as oxygen made.
  test('harvesters under a sky thinned past 2% oxygen are not counted', () {
    final mars = fixtureBodies.firstWhere((b) => b.id.value == 'mars');
    final city = foundFlat();
    city.ignoreUnlocks = true;
    city.stock[Commodity.ore] = 400;
    final hy = city.hubKey ~/ city.grid;
    for (var x = 0; x < city.grid; x++) {
      final k = hy * city.grid + x;
      if (k != city.hubKey) city.addRoad(k);
    }
    CityBuildingSpec spec(String type) =>
        kUtilCatalog.firstWhere((s) => s.type == type);
    city.placeUtil((hy + 1) * city.grid + 1, spec('fusion'));
    // Built while the sky held oxygen enough to pull: on its nameplate, one
    // harvester covers forty colonists' breath (2.0/s against 1.2/s).
    city.placeUtil((hy + 1) * city.grid + 4, spec('o2harvester'));
    city.body = mars; // ... which harvesting has since thinned to bare Mars
    city.recompute();
    run(city, 5);
    city.population = 40;
    city.lifeThrottle = 1;
    expect(city.o2Harvestable, isFalse);
    expect(city.o2NeedPerSec, greaterThan(1.0),
        reason: 'bare Mars covers almost none of a breath');
    secede(city);
    final acts = <GovernorAct>[];
    for (var i = 0; i < 3; i++) {
      acts.addAll(city.governIndependent(localNet: const {
        Commodity.food: 1e3,
        Commodity.water: 1e3,
        Commodity.oxygen: 0,
      }));
    }
    final builds = acts.where((a) => a.kind == GovernorActKind.lifeSupport);
    final log = acts.map((a) => a.text).join('; ');
    expect(builds, isNotEmpty,
        reason: 'the idle harvester is no oxygen made: $log');
    expect(builds.where((a) => a.text.contains('Harvester')), isEmpty,
        reason: 'and another would stand idle too: $log');
  });

  /// Every life commodity in plenty: a sitting then goes past life support.
  const plenty = {
    Commodity.food: 1e3,
    Commodity.water: 1e3,
    Commodity.oxygen: 1e3,
  };

  group('the tax', () {
    CitySim seceded() {
      final city = starterKit();
      run(city, 2 * day);
      secede(city);
      expect(city.economy.taxControllable, isTrue);
      return city;
    }

    test('a content colony raises it, a step a sitting, to the ceiling', () {
      final city = seceded();
      city.taxRate = 0;
      city.happiness = 0.9;
      final rates = <double>[];
      for (var i = 0; i < 12; i++) {
        city.governIndependent(localNet: plenty);
        rates.add(city.taxRate);
      }
      var was = 0.0;
      for (final r in rates) {
        expect(r - was, inInclusiveRange(0, city.governorTuning.taxStep + 1e-9),
            reason: '$rates');
        was = r;
      }
      expect(rates[0], closeTo(0.05, 1e-9));
      expect(rates.last, closeTo(city.governorTuning.maxTax, 1e-9));
    });

    test('a sullen colony lowers it, a step a sitting, to nothing', () {
      final city = seceded();
      city.taxRate = 0.3;
      city.happiness = 0.1;
      city.governIndependent(localNet: plenty);
      expect(city.taxRate, closeTo(0.25, 1e-9));
      for (var i = 0; i < 10; i++) {
        city.governIndependent(localNet: plenty);
      }
      expect(city.taxRate, closeTo(0, 1e-9));
    });

    test('it stops at the rate that leaves the mood bearable', () {
      final city = seceded();
      final penalty = city.economy.taxHappinessPenalty;
      city.taxRate = 0.1;
      // The mood 0.02 of tax above bearable: the ideal rate is 0.12.
      city.happiness = city.governorTuning.bearableMood + 0.02 * penalty;
      city.governIndependent(localNet: plenty);
      expect(city.taxRate, closeTo(0.12, 1e-9), reason: 'not a full step past');
      // At the bearable mood it holds.
      city.happiness = city.governorTuning.bearableMood;
      city.governIndependent(localNet: plenty);
      expect(city.taxRate, closeTo(0.12, 1e-9));
    });
  });

  test('past the waste line with nothing taking garbage, a landfill', () {
    final city = starterKit();
    run(city, 2 * day);
    secede(city);
    city.stock[Commodity.ore] = 400;
    bool takesGarbage() =>
        built(city).any((s) => s.inputs.containsKey(Commodity.garbage));
    expect(takesGarbage(), isFalse);
    city.wasteBacklog = 0.2; // under the line
    city.governIndependent(localNet: plenty);
    expect(takesGarbage(), isFalse);
    city.wasteBacklog = 0.5;
    final acts = city.governIndependent(localNet: plenty);
    expect(acts.map((a) => a.kind), contains(GovernorActKind.waste),
        reason: acts.map((a) => a.text).join('; '));
    expect(takesGarbage(), isTrue);
    // One is enough: it does not build a second while the backlog drains.
    final n = built(city)
        .where((s) => s.inputs.containsKey(Commodity.garbage))
        .length;
    city.governIndependent(localNet: plenty);
    expect(
        built(city).where((s) => s.inputs.containsKey(Commodity.garbage)),
        hasLength(n));
  });

  test('past the corpse line with no deathcare, a cemetery', () {
    final city = starterKit();
    run(city, 2 * day);
    secede(city);
    city.stock[Commodity.ore] = 400;
    bool hasDeathcare() => built(city).any((s) => s.deathcareRate > 0);
    expect(hasDeathcare(), isFalse);
    city.corpses = 2.5; // under max(3, 2% of a handful)
    city.governIndependent(localNet: plenty);
    expect(hasDeathcare(), isFalse);
    city.corpses = 10;
    final acts = city.governIndependent(localNet: plenty);
    expect(acts.map((a) => a.kind), contains(GovernorActKind.deathcare),
        reason: acts.map((a) => a.text).join('; '));
    expect(hasDeathcare(), isTrue);
  });

  group('zoning', () {
    CitySim seceded() {
      final city = starterKit();
      run(city, 2 * day);
      secede(city);
      return city;
    }

    int zonedFor(CitySim city, ParcelUse u) =>
        city.layout.autoParcels.where((p) => p.use == u).length;

    test('the use with the most demand against what is zoned for it', () {
      final city = seceded();
      // Four shops already standing: commercial has the higher raw demand
      // but the lower demand per lot zoned for it.
      for (final lot in freeLots(city).take(4)) {
        city.layout.setUse(lot.id, ParcelUse.commercial);
        city.grownParcels[lot.id] = 1.0;
      }
      city
        ..resTarget = 0.5
        ..comTarget = 0.9
        ..indTarget = 0.0;
      final res0 = zonedFor(city, ParcelUse.residential);
      final com0 = zonedFor(city, ParcelUse.commercial);
      final acts = city.governIndependent(localNet: plenty);
      expect(acts.map((a) => a.text), contains('zoned 2 residential lots'));
      expect(zonedFor(city, ParcelUse.residential), res0 + 2);
      expect(zonedFor(city, ParcelUse.commercial), com0);
      // Below the growth line no use is zoned at all.
      city
        ..resTarget = 0.1
        ..comTarget = 0.1;
      expect(
          city
              .governIndependent(localNet: plenty)
              .where((a) => a.kind == GovernorActKind.zone),
          isEmpty);
    });

    test('lots stuck on the line hold back their own use, not the others',
        () {
      final city = seceded();
      // Two shop lots zoned and stalled: the shops' demand sits on the
      // growth line, so they grow a hair and decay a hair, never built.
      var stuck = 0;
      for (final lot in freeLots(city)) {
        if (stuck == 2) break;
        if (!city.layout.setUse(lot.id, ParcelUse.commercial)) continue;
        city.grownParcels[lot.id] = 0.01;
        stuck++;
      }
      expect(stuck, 2);
      city
        ..resTarget = 0.35
        ..comTarget = 0.21
        ..indTarget = 0.0;
      final com0 = zonedFor(city, ParcelUse.commercial);
      final acts = city.governIndependent(localNet: plenty);
      expect(acts.map((a) => a.text), contains('zoned 2 residential lots'),
          reason: 'the homes are wanted: ${acts.map((a) => a.text)}');
      // And the stalled shops' cap still holds for shops.
      city
        ..resTarget = 0.0
        ..comTarget = 0.9;
      for (var i = 0; i < 3; i++) {
        city.governIndependent(localNet: plenty);
      }
      expect(zonedFor(city, ParcelUse.commercial), com0);
    });
  });

  test('a new plot never covers a zoned or built street lot', () {
    final city = starterKit();
    run(city, 2 * day);
    secede(city);
    // A town of homes, half of them grown, around the starter farm.
    final lots = freeLots(city).take(40).toList();
    for (var i = 0; i < lots.length; i++) {
      city.layout.setUse(lots[i].id, ParcelUse.residential);
      if (i.isEven) city.grownParcels[lots[i].id] = 1.0;
    }
    String state(Parcel p) => '${p.use.name}|'
        '${city.parcelBuildings[p.id]?.label}|${city.grownParcels[p.id]}';
    final before = {
      for (final p in city.layout.autoParcels)
        if (p.use != ParcelUse.unzoned ||
            city.parcelBuildings.containsKey(p.id) ||
            city.grownParcels.containsKey(p.id))
          p.id: state(p),
    };
    expect(before.length, greaterThanOrEqualTo(lots.length));
    final plots0 = city.layout.manualParcels.length;
    // More mouths than the farm and pump feed, with power and hands for a
    // new building: the farm's water comes first, on a plot of its own.
    city.population = 200;
    city.lifeThrottle = 1;
    city.stock[Commodity.ore] = 400;
    final acts = city.governIndependent(localNet: const {});
    final build = acts.where((a) => a.oreSpent > 0).toList();
    expect(build, hasLength(1), reason: acts.map((a) => a.text).join('; '));
    expect(city.layout.manualParcels.length, plots0 + 1,
        reason: 'staked a new plot: ${build.single.text}');
    final after = {for (final p in city.layout.autoParcels) p.id: state(p)};
    for (final e in before.entries) {
      expect(after[e.key], e.value, reason: 'lot ${e.key} kept as it was');
    }
  });

  test('it never overspends: no build below its reserve, nothing negative',
      () {
    final city = starterKit();
    run(city, 2 * day);
    final farmLot = city.buildingParcels()
        .firstWhere((e) => e.$2.label == 'Farm')
        .$1
        .id;
    city.clearParcel(farmLot);
    secede(city);
    // Not enough for the cheapest life support (a 35-ore pump) and the
    // reserve.
    city.stock[Commodity.ore] = 44;
    final funds0 = city.funds;
    final acts = city.governIndependent(localNet: const {});
    expect(acts.where((a) => a.oreSpent > 0), isEmpty,
        reason: 'the cheapest costs 35 and the reserve is 10');
    expect(city.stockOf(Commodity.ore), 44);
    expect(city.funds, funds0, reason: 'the council spends no money');
    // Many sittings with every commodity short: it spends what it has, one
    // build a sitting, and stops at the reserve.
    city.stock[Commodity.ore] = 120;
    var spent = 0.0;
    for (var i = 0; i < 12; i++) {
      for (final a in city.governIndependent(localNet: const {})) {
        spent += a.oreSpent;
      }
      expect(city.stockOf(Commodity.ore),
          greaterThanOrEqualTo(city.governorTuning.oreReserve - 1e-9));
    }
    expect(spent, greaterThan(0));
    expect(spent, lessThanOrEqualTo(120 - 10 + 1e-9));
  });

  test('it does nothing for a colonial colony', () {
    final a = starterKit();
    run(a, 2 * day);
    final farmLot = a.buildingParcels()
        .firstWhere((e) => e.$2.label == 'Farm')
        .$1
        .id;
    a.clearParcel(farmLot);
    final before = jsonEncode(a.toJson());
    expect(a.governIndependent(localNet: const {}), isEmpty);
    expect(jsonEncode(a.toJson()), before);
    run(a, 10 * day);
    expect(a.governorLog, isEmpty);
    expect(farms(a), 0, reason: 'nobody rebuilt the player\'s farm');
  });

  test('it sits on its calendar: every few days, the same after a load', () {
    final city = starterKit();
    run(city, 2 * day);
    secede(city);
    city.governorTuning = const IndependentGovernorTuning(periodDays: 3);
    run(city, 10 * day);
    final sittings = city.governorLog.map((a) => a.atS).toSet();
    // The declaration's tick, then days 3, 6 and 9 — and at least one of
    // them did something, or the phase check below proves nothing.
    expect(sittings, isNotEmpty);
    expect(sittings.length, lessThanOrEqualTo(4));
    for (final s in sittings) {
      final since = (s - city.loyalty.independentAtS!) / day;
      expect(since - (since / 3).round() * 3, closeTo(0, 0.01));
    }
    // Through a save: the declaration, its causes and so the calendar
    // survive, and the copy sits when the original does.
    final copy = CitySim.fromJson(
        jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
        bodies: fixtureBodies);
    expect(copy.loyalty.independentAtS, city.loyalty.independentAtS);
    expect(copy.loyalty.independenceCauses, 'no orders for 50 days');
    copy.governorTuning = const IndependentGovernorTuning(periodDays: 3);
    run(copy, 6 * day);
    expect(copy.governorLog, isNotEmpty, reason: 'the copy is governed');
    for (final a in copy.governorLog) {
      final since = (a.atS - copy.loyalty.independentAtS!) / day;
      expect(since - (since / 3).round() * 3, closeTo(0, 0.01),
          reason: 'on the original calendar, not restarted at the load');
    }
  });
}
