// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Trade bounds and the world market (docs/plans/dynamic-markets.md §3
/// "Arbitrage bounds", "Earth is a market like any other").
///
/// A colony with a working port can't hold a price outside its import
/// ceiling and export floor for long; one without floats free, so a siege
/// or a closed port really does send prices soaring. Earth is seeded once
/// from `kEarthPricePerKg` and then moves on world supply and demand.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/commodity_mass.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/markets.dart';
import 'package:flutter_test/flutter_test.dart';

/// [days] closes of a good bid up (demand 10, supply 1, empty shelves) or
/// dumped (demand 0, supply 10, a pile) against a [lo, hi] band.
List<double> bid(
  GoodMarket m,
  int days, {
  required bool open,
  required bool shortage,
  double lo = 50,
  double hi = 150,
}) {
  final p = paramsOf(Commodity.steel);
  final out = <double>[];
  for (var d = 0; d < days; d++) {
    closeGoodDay(
        m,
        GoodDay(
          demandPerS: shortage ? 10 : 0,
          supplyPerS: shortage ? 1 : 10,
          stock: shortage ? 0 : 1e6,
          anchor: 100,
          unitCost: 100,
          importCeiling: hi,
          exportFloor: lo,
          arbitrage: open,
        ),
        p);
    out.add(m.price);
  }
  return out;
}

void main() {
  final eta = paramsOf(Commodity.steel).eta;

  test('port open: a shortage stays under the import ceiling', () {
    final prices = bid(GoodMarket(price: 100, anchor: 100), 365,
        open: true, shortage: true);
    // Held within one day's push of the ceiling (arbitrage halves the
    // excess every day; the step pushes at most η).
    for (final p in prices) {
      expect(p, lessThanOrEqualTo(150 * math.exp(eta) + 1e-9));
    }
    expect(prices.last, greaterThan(150 * 0.99), reason: 'and does reach it');
  });

  test('port closed: the same shortage soars past the ceiling', () {
    final prices = bid(GoodMarket(price: 100, anchor: 100), 365,
        open: false, shortage: true);
    final over = prices.indexWhere((p) => p > 150 * 1.5);
    expect(over, greaterThan(0), reason: 'well past the old ceiling');
    // Month-scale, not overnight: past ×1.5 of the ceiling only after weeks.
    expect(over, greaterThan(14));
    // Until the colony would rather build it: 10× its unit cost.
    expect(prices.last, closeTo(100 * kCostCeilingMultiple, 1e-6));
  });

  test('port open: a glut stays over the export floor; closed it sinks', () {
    final open = bid(GoodMarket(price: 100, anchor: 100), 365,
        open: true, shortage: false);
    for (final p in open) {
      expect(p, greaterThanOrEqualTo(50 * math.exp(-eta) - 1e-9));
    }
    final closed = bid(GoodMarket(price: 100, anchor: 100), 365,
        open: false, shortage: false);
    expect(closed.last, lessThan(50 * 0.5));
    expect(closed.last, greaterThan(0));
  });

  test('a price far out of band comes back over days, not one night', () {
    final m = GoodMarket(price: 1500, anchor: 100); // a siege just lifted
    final prices = bid(m, 30, open: true, shortage: false, lo: 50, hi: 150);
    for (var i = 1; i < prices.length; i++) {
      expect(math.log(prices[i - 1] / prices[i]),
          lessThanOrEqualTo(kMaxDailyLogStep + 1e-12));
    }
    expect(prices[2], greaterThan(150), reason: 'still out after two days');
    expect(prices.last, lessThan(150 * math.exp(eta)), reason: 'in band');
  });

  // The same through the colony close, with the real Δv band on Mars: rocket
  // parts with no local recipe (no population to unlock one), wanted and
  // not made.
  test('a Martian colony\'s rocket parts: port open in band, closed soaring',
      () {
    LocalMarket solve(bool port) => solveLocalMarket(MarketFacts(
          bodyId: 'mars',
          economy: EconomyKind.capitalism,
          demandPerS: const {Commodity.rocketParts: 1},
          canExport: port,
        ));
    for (final port in const [true, false]) {
      final solved = solve(port);
      final hi = solved.book.importCeiling[Commodity.rocketParts]!;
      final facts = MarketFacts(
        bodyId: 'mars',
        economy: EconomyKind.capitalism,
        demandPerS: const {Commodity.rocketParts: 1},
        canExport: port,
      );
      final colony = Market();
      final seen = <double>[];
      for (var d = 0; d < 200; d++) {
        final close = closeColonyMarket(colony, solved, facts);
        seen.add(close.book.price(Commodity.rocketParts));
      }
      expect(seen.first, closeTo(solved.book.price(Commodity.rocketParts), 1e-9),
          reason: 'seeded at the solve\'s price');
      final adv = paramsOf(Commodity.rocketParts).eta;
      if (port) {
        for (final p in seen) {
          expect(p, lessThanOrEqualTo(hi * math.exp(adv) + 1e-6));
        }
      } else {
        expect(seen.last, greaterThan(hi * 1.5),
            reason: 'no port, no ceiling: a closed colony bids it up');
      }
    }
  });

  group('Earth', () {
    test('is seeded once from kEarthPricePerKg, and holds without trade', () {
      final earth = seedEarthMarket();
      for (final c in marketGoods()) {
        final p = earthPrice(c);
        if (!isShippable(c) || !(p > 0)) {
          expect(earth.goods[c], isNull, reason: c);
          continue;
        }
        expect(earth.priceOf(c), p, reason: c);
        expect(earth.goods[c]!.anchor, p, reason: c);
      }
      for (var d = 0; d < 365; d++) {
        closeEarthDay(earth);
      }
      for (final e in earth.goods.entries) {
        expect(e.value.price, closeTo(earthPrice(e.key), earthPrice(e.key) * 1e-9),
            reason: e.key);
      }
    });

    // Rocket parts, the advanced class: world depth 200 kg/s, 2 units/s. A
    // buyer taking another half of the world's trade (1 unit/s) bids it up
    // toward 1.5^(1/1.5) ≈ 1.31× and lets it slide back when it stops; a
    // seller flooding it pushes it down. Earth is a market like any other.
    test('moves with world supply and demand, and reverts to its anchor', () {
      final earth = seedEarthMarket();
      final seed = earthPrice(Commodity.rocketParts);
      final w = worldFlowPerS(Commodity.rocketParts);
      final demand = {Commodity.rocketParts: w / 2};
      final eq = math.pow(1.5, 1 / paramsOf(Commodity.rocketParts).elasticity);
      for (var d = 0; d < 90; d++) {
        closeEarthDay(earth, importsPerS: demand);
      }
      final after90 = earth.priceOf(Commodity.rocketParts)! / seed;
      expect(after90, greaterThan(1.15));
      expect(after90, lessThan(eq));
      // Half the log gap closed in about the class half-life (40 days):
      // after 90 days, more than three quarters of it.
      expect(math.log(after90) / math.log(eq), greaterThan(0.75));
      // Steel didn't move: nobody traded it.
      expect(earth.priceOf(Commodity.steel), closeTo(earthPrice(Commodity.steel), 1e-12));
      // The buyer leaves: back toward the seed.
      for (var d = 0; d < 365; d++) {
        closeEarthDay(earth);
      }
      expect(earth.priceOf(Commodity.rocketParts)! / seed, closeTo(1, 0.01));
      // A seller doubling world supply drives it down.
      for (var d = 0; d < 90; d++) {
        closeEarthDay(earth, exportsPerS: {Commodity.rocketParts: w});
      }
      expect(earth.priceOf(Commodity.rocketParts)! / seed, lessThan(0.75));
    });

    // Colonies trade against Earth's LIVE price: the solve's import ceiling
    // follows it, not the seed table.
    test('a colony\'s import ceiling follows Earth\'s live price', () {
      const facts = MarketFacts(bodyId: 'mars', economy: EconomyKind.capitalism);
      final seeded = solveLocalMarket(facts);
      final live = {
        for (final e in seedEarthMarket().prices.entries)
          e.key: e.key == Commodity.rocketParts ? e.value * 2 : e.value,
      };
      final moved = solveLocalMarket(facts, earthPrices: live);
      final rp = earthPrice(Commodity.rocketParts);
      expect(
          moved.book.importCeiling[Commodity.rocketParts]! -
              seeded.book.importCeiling[Commodity.rocketParts]!,
          closeTo(rp, rp * 1e-9));
      expect(moved.book.importCeiling[Commodity.steel],
          seeded.book.importCeiling[Commodity.steel]);
    });
  });
}
