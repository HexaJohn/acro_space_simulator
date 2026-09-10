// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The opening position of the city-builder mode.
///
/// Every assertion here is a thing that, if it broke, would make a new city
/// unplayable in a way the player could not diagnose: no port means nobody ever
/// arrives, a disconnected port means the same, and lots that front nothing
/// mean zoning does nothing.
void main() {
  CitySim founded(
          {CityStart difficulty = CityStart.standard,
          String body = 'earth'}) =>
      CityStarterKit.found(
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        config: CityConfig(bodyId: body, gridSize: 20),
        start: difficulty,
      );

  test('the colony opens with a crossroads and lots to zone', () {
    final city = founded();
    expect(city.layout.roads.length, greaterThanOrEqualTo(4),
        reason: 'two streets, each split at the crossing');
    expect(city.layout.autoParcels, isNotEmpty,
        reason: 'a street with no frontage cannot be zoned');
  });

  test('the spaceport is placed AND connected, so people can arrive', () {
    final city = founded();
    expect(city.hasSpaceport, isTrue);
    expect(city.popTrend, isNot('stable'),
        reason: 'a working port means immigration is possible');
  });

  test('difficulty sets the opening balance and the odds', () {
    for (final d in CityStart.values) {
      final city = founded(difficulty: d);
      expect(city.funds, d.funds);
      expect(city.stockOf(Commodity.ore), d.ore);
      expect(city.hostility, d.hostility);
      expect(city.bounty, d.bounty);
    }
    expect(founded(difficulty: CityStart.harsh).funds,
        lessThan(founded(difficulty: CityStart.relaxed).funds));
  });

  test('zoning the starter block grows buildings on it', () {
    final city = founded()..resTarget = 1.0;
    for (final lot in city.layout.autoParcels) {
      city.layout.setUse(lot.id, ParcelUse.residential);
    }
    for (var i = 0; i < 400; i++) {
      city.advanceParcelGrowth(0.1);
    }
    expect(city.grownParcels, isNotEmpty,
        reason: 'the starter streets must be rooted, or nothing is served');
  });

  test('founding does not pay out a milestone the colony has not earned', () {
    final city = founded();
    expect(city.milestonesReached, {0});
    expect(city.milestoneToasts, isEmpty);
    expect(city.funds, CityStart.standard.funds);
  });

  test('the opening stockpile survives the first tick', () {
    // Ore is capped at 200 without storage, and the tick sweeps the overflow
    // away — an opening grant handed to a colony with no depot is gone before
    // the player sees it. The kit's warehouse is what makes the number real.
    final city = founded();
    city.advance(1.0);
    expect(city.stockOf(Commodity.ore),
        greaterThan(CityStart.standard.ore * 0.9),
        reason: 'the cap sweep ate the opening ore — the kit needs storage');
  });

  test('a milestone grant is clipped to storage, and says so', () {
    final city = founded();
    city.stock[Commodity.ore] = city.stockCap; // the depot is already full
    city.population = 65;
    city.claimMilestones();
    final award = city.milestoneToasts.single;
    expect(award.ore, lessThan(award.milestone.oreGrant));
    expect(award.spilled, isTrue);
    expect(city.stockOf(Commodity.ore), lessThanOrEqualTo(city.stockCap));
  });

  test('the colony opens generating power, not dark', () {
    final city = founded();
    city.advance(1.0);
    expect(city.powerOut, greaterThan(0),
        reason: 'a colony with a port and no generation reads as broken');
  });

  test('the colony is not starving on its first minute', () {
    final city = founded();
    final start = city.population;
    for (var i = 0; i < 600; i++) {
      city.advance(0.1); // a minute of colony time
    }
    expect(city.starved, isFalse);
    expect(city.population, greaterThanOrEqualTo(start * 0.95),
        reason: 'the opening position must not be a death spiral');
  });

  test('the kit works on an airless world too', () {
    final city = founded(body: 'moon');
    expect(city.hasSpaceport, isTrue);
    expect(city.layout.autoParcels, isNotEmpty);
  });
}
