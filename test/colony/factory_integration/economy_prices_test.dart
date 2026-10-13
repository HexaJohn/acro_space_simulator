// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's local prices come from the colony itself
/// (docs/plans/factory-floors.md §3 "Prices are local and derived"): the
/// MarketFacts are read off the running CitySim, never built by hand, and
/// solved once per colony day.
library;

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

CitySim starter(String body) => CityStarterKit.found(
      bodies: fixtureBodies(),
      config: CityConfig(bodyId: body),
      start: CityStart.relaxed,
    )
      ..hostility = 0
      ..pinPopulation = true;

void main() {
  // The question that shaped the price model: oxygen is cheap on Earth and
  // dear on Mars. Asked of two real starter colonies after one colony day,
  // through the facts CitySim builds — if the sky, the body or the biome
  // stopped reaching the solver, Mars would price oxygen like Earth.
  test('oxygen costs more in a Martian starter colony than an Earth one', () {
    final earth = starter('earth');
    final mars = starter('mars');
    expect(earth.localPrices, isNull, reason: 'no day has closed yet');
    for (var t = 0.0; t < kColonyDaySec; t += kEconTickS) {
      earth.advance(kEconTickS);
      mars.advance(kEconTickS);
    }
    final pe = earth.localPrices!.price(Commodity.oxygen);
    final pm = mars.localPrices!.price(Commodity.oxygen);
    expect(pe, closeTo(earthPrice(Commodity.oxygen), 1e-9),
        reason: 'an Earth colony trades at Earth prices');
    expect(pm, greaterThan(pe * 10), reason: 'Mars $pm vs Earth $pe');
    // Made locally by electrolysis, not landed from Earth.
    expect(pm, lessThan(mars.localPrices!.importCeiling[Commodity.oxygen]!));
    expect(mars.localMarket.sourceOf[Commodity.oxygen], isNot('import'));
  });

  // The facts are the sim's: its body, its economy by name, its sky's gases
  // under the formula keys the solver reads ('O2'), and every power plant's
  // factor here. A wrong key would silently read Earth's air as airless.
  test('market facts are read off the colony', () {
    final earth = starter('earth')..economy = Economy.socialism;
    final mars = starter('mars');
    final fe = earth.marketFacts();
    final fm = mars.marketFacts();
    expect(fe.bodyId, 'earth');
    expect(fe.economy, EconomyKind.socialism);
    expect(fe.atmosphere['O2'], closeTo(0.21, 0.01));
    expect(fm.atmosphere['CO2'], greaterThan(0.9));
    expect(fe.surfacePressureKPa, closeTo(101.3, 2));
    expect(fm.o2Harvestable, isFalse);
    expect(fm.powerFactors['solar'], closeTo(mars.powerFactor('solar'), 1e-12));
    expect(fm.powerFactors['wind'], closeTo(mars.powerFactor('wind'), 1e-12));
    expect(fm.population, mars.population.round());
  });

  // Scarcity reads the colony's real flows: what its people eat, and what
  // its plants make through their floors (a floor plant skips the flat
  // recipe, so without the floor path's flows its output would be invisible
  // to the market). Against a twin without the plant, because the starter
  // spaceport lands fuel too.
  test('demand and supply accumulate from the tick, floors included', () {
    final refinery = specOf('refinery');
    final sim = economyColony();
    final twin = economyColony();
    placePlant(sim, 'refinery');
    runDays(sim, 0.5, specs: [refinery]);
    runDays(twin, 0.5, specs: [refinery]);
    final f = sim.marketFacts();
    final t = twin.marketFacts();
    expect(f.demandPerS[Commodity.food],
        greaterThanOrEqualTo(
            sim.population * CitySim.foodPerPersonPerSec * 0.99));
    expect((f.supplyPerS[Commodity.fuel] ?? 0) - (t.supplyPerS[Commodity.fuel] ?? 0),
        closeTo(0.4 * sim.bountyMult * sim.eventProductionMult, 0.02),
        reason: 'the refinery floor lands 0.4 fuel/s, times the bounty');
    expect((f.demandPerS[Commodity.ore] ?? 0) - (t.demandPerS[Commodity.ore] ?? 0),
        closeTo(1.0, 0.05),
        reason: 'and draws 1 ore/s');
  });

  // Solved once a day and cached: a day close re-solves, and the day's flows
  // start over so each day's scarcity is that day's.
  test('the day close solves prices and starts a fresh day', () {
    final sim = economyColony();
    runDays(sim, 1);
    expect(sim.localPrices, isNotNull);
    expect(sim.colonyEconomy.dayClockS, lessThan(kColonyDaySec));
    final first = sim.localPrices;
    runDays(sim, 1);
    expect(identical(sim.localPrices, first), isFalse);
  });
}
