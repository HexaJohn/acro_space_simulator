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
    // The declaration's tick, then days 3, 6 and 9.
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
