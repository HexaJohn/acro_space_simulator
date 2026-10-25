// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Dynamic markets in a live colony (docs/plans/dynamic-markets.md phase 1):
/// revenue counts only what sells, the markets are saved, an old save is
/// seeded from today's model, and everything is deterministic.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/markets.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/plant_pnl.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_integration/economy_fixture.dart';
import '../factory_integration/factory_colony_fixture.dart';

/// A Martian colony with a private Steel Mill, fed. Mars because its steel
/// has no export floor (landing it on Earth costs more than it is worth),
/// so whether it sells is up to the colony.
({CitySim sim, String lot}) martianMill() {
  final sim = economyColony(bodyId: 'mars');
  final lot = placePlant(sim, 'steelmill');
  return (sim: sim, lot: lot);
}

/// Relative closeness.
Matcher near(double x, [double rel = 1e-9]) => closeTo(x, x.abs() * rel);

void main() {
  test('revenue is shipped × price × sell-through', () {
    final ledger = FactoryLedger()
      ..seconds = 100
      ..addShipped('steel', 70)
      ..addShipped('tubes', 20);
    const book = PriceBook(
        prices: {'steel': 30, 'tubes': 25}, wagePerWorkerS: 0, powerPerKJ: 0);
    final all = pnlFor(ledger, book,
        owner: const Ownership.state(), economy: EconomyKind.capitalism);
    final some = pnlFor(ledger, book,
        owner: const Ownership.state(),
        economy: EconomyKind.capitalism,
        sellThrough: const {'steel': 0.25});
    expect(all.revenue, 70 * 30 + 20 * 25);
    expect(some.revenue, 70 * 30 * 0.25 + 20 * 25, reason: 'tubes all sold');
    expect(some.logistics, all.logistics, reason: 'freight paid on all');

    // Sell-through from the smoothed flows: demand over supply, or 1 when
    // the good can be exported at a positive floor.
    final m = GoodMarket(price: 1, anchor: 1, demandPerS: 1, supplyPerS: 4);
    expect(sellThroughOf(m, exportable: false), 0.25);
    expect(sellThroughOf(m, exportable: true), 1);
    expect(
        sellThroughOf(GoodMarket(price: 1, anchor: 1, demandPerS: 9,
            supplyPerS: 3), exportable: false),
        1);
  });

  // The user's intent: a plant whose output nobody wants sees its price fall
  // and its margin shrink — on a month's scale, not overnight. A mill that
  // sold everything for 25 days loses its buyers: within days its sales
  // stop, but its rolling books and its price fall over weeks.
  test('an unwanted good\'s revenue falls, its price slides, no collapse',
      () {
    final r = martianMill();
    final sim = r.sim;
    final mill = specOf('steelmill');
    runDays(sim, 25, specs: [mill], inputs: 1e5);
    final before = sim.colonyEconomy.lastPnl[r.lot]!;
    final priceBefore = sim.localPrices!.price(Commodity.steel);
    final marginBefore = sim.firmBookOf(r.lot)!.margin;
    expect(sim.colonyEconomy.sellThrough[Commodity.steel], closeTo(1, 1e-3));
    expect(marginBefore, greaterThan(0));

    // Nobody buys steel any more: the mill's output is carted off unsold.
    runDays(sim, 3, specs: [mill], inputs: 1e5, wanted: false);
    final book3 = sim.firmBookOf(r.lot)!;
    expect(book3.margin, greaterThan(0), reason: 'no instant collapse');
    expect(book3.health, FirmHealth.healthy);
    expect(sim.colonyEconomy.sellThrough[Commodity.steel], lessThan(0.5),
        reason: 'but the sales are going');

    runDays(sim, 22, specs: [mill], inputs: 1e5, wanted: false);
    final after = sim.colonyEconomy.lastPnl[r.lot]!;
    final priceAfter = sim.localPrices!.price(Commodity.steel);
    expect(after.revenue, lessThan(before.revenue * 0.1),
        reason: 'revenue counts only what sells');
    expect(sim.firmBookOf(r.lot)!.margin, lessThan(marginBefore));
    // Month-scale: steel's step falls at most η (2.5%) a day, so 25 days
    // take it to roughly half, not to nothing.
    expect(priceAfter, lessThan(priceBefore * 0.75));
    expect(priceAfter, greaterThan(priceBefore * 0.3));
  });

  // Off-world, the only steel mill used to SET steel's price at its own
  // cost, pinning its margin at ~0.1%. Now supply and demand set the price:
  // a colony that takes every unit as it is made, with nothing on the
  // shelf, bids it above cost, and the mill's margin grows.
  test('an off-world mill\'s margin is no longer pinned at cost', () {
    final r = martianMill();
    runDays(r.sim, 30, specs: [specOf('steelmill')], inputs: 1e5);
    final book = r.sim.firmBookOf(r.lot)!;
    expect(book.margin, greaterThan(0.05),
        reason: 'margin ${book.margin.toStringAsFixed(3)}');
    expect(r.sim.localPrices!.price(Commodity.steel),
        greaterThan(r.sim.localMarket.localCost[Commodity.steel]! * 1.1));
  });

  test('a fresh colony\'s first prices are today\'s solved prices', () {
    final r = martianMill();
    runDays(r.sim, 0.5, specs: [specOf('steelmill')]);
    final expected = solveLocalMarket(r.sim.marketFacts());
    r.sim.closeEconomyDay();
    final got = r.sim.localPrices!;
    for (final c in r.sim.colonyEconomy.colonyMarket.goods.keys) {
      expect(got.price(c), near(expected.book.price(c)), reason: c);
    }
    expect(r.sim.colonyEconomy.colonyMarket.goods, isNotEmpty);
  });

  test('the markets round-trip through a save', () {
    final r = martianMill();
    final mill = specOf('steelmill');
    runDays(r.sim, 6.5, specs: [mill], inputs: 1e5);
    final json = r.sim.toJson();
    final econ = (json['plantEconomy'] as Map).cast<String, Object?>();
    expect(econ.keys, containsAll(['mkt', 'earthMkt', 'sell']));
    final loaded = reload(json);
    expect(economyJson(loaded), economyJson(r.sim));
    // And they carry on together. Not bit for bit: a floor's runtime state
    // isn't saved, so the reloaded mill's day differs in the last digits
    // (economy_persistence_test.dart allows 2% on the tax for the same
    // reason); the prices, which remember, stay within a millionth.
    runDays(r.sim, 6, specs: [mill], inputs: 1e5);
    runDays(loaded, 6, specs: [mill], inputs: 1e5);
    final a = r.sim.colonyEconomy, b = loaded.colonyEconomy;
    expect(b.colonyMarket.goods.keys, a.colonyMarket.goods.keys);
    for (final c in a.colonyMarket.goods.keys) {
      expect(b.colonyMarket.priceOf(c), near(a.colonyMarket.priceOf(c)!, 1e-6),
          reason: c);
    }
    for (final c in a.earthMarket.goods.keys) {
      expect(b.earthMarket.priceOf(c), near(a.earthMarket.priceOf(c)!, 1e-9),
          reason: c);
    }
  });

  // A save from before dynamic markets has neither market. It loads, and its
  // next day close seeds both from today's model: the colony at the solve's
  // own prices, Earth at the seed table. Nothing jumps on the day it loads.
  test('an old save is seeded from today\'s model', () {
    final r = martianMill();
    final mill = specOf('steelmill');
    runDays(r.sim, 4.5, specs: [mill], inputs: 1e5);
    final json = jsonDecode(jsonEncode(r.sim.toJson())) as Map<String, dynamic>;
    final econ = json['plantEconomy'] as Map<String, dynamic>;
    econ
      ..remove('mkt')
      ..remove('earthMkt')
      ..remove('sell')
      ..remove('imp')
      ..remove('made');
    // Older than learning curves too (docs/plans/dynamic-markets.md phase 2).
    json.remove('tech');
    final loaded = reload(json);
    expect(loaded.colonyEconomy.colonyMarket.isEmpty, isTrue);
    expect(loaded.colonyEconomy.earthMarket.isEmpty, isTrue);

    final expected = solveLocalMarket(loaded.marketFacts());
    loaded.closeEconomyDay();
    final e = loaded.colonyEconomy;
    expect(e.colonyMarket.goods, isNotEmpty);
    for (final c in e.colonyMarket.goods.keys) {
      expect(e.colonyMarket.priceOf(c), near(expected.book.price(c)),
          reason: c);
    }
    expect(e.earthMarket.goods, isNotEmpty);
    // From then on prices have memory: steel moves off its seed.
    final seeded = e.colonyMarket.priceOf(Commodity.steel)!;
    runDays(loaded, 5, specs: [mill], inputs: 1e5);
    expect(loaded.colonyEconomy.colonyMarket.priceOf(Commodity.steel),
        isNot(near(seeded, 1e-6)));
  });

  test('two colonies stepped alike keep identical markets', () {
    String run() {
      final sim = economyColony(bodyId: 'mars');
      placePlant(sim, 'steelmill');
      placePlant(sim, 'rocketfactory');
      final mill = specOf('steelmill');
      final parts = specOf('rocketfactory');
      // Steel wanted, rocket parts exported to Earth: both markets move.
      runDays(sim, 8, specs: [mill], inputs: 1e5, after: () {
        holdStock(sim, parts, inputs: 1e5, wanted: false);
        return false;
      });
      return economyJson(sim);
    }

    final a = run();
    final b = run();
    expect(a, b);
    expect(a, contains('"mkt"'));
    expect(a, contains('"earthMkt"'));
  });
}
