// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The daily tâtonnement (docs/plans/dynamic-markets.md §3, phase 1): its
/// speed is the user's (§7.5: most goods close half the gap to equilibrium
/// in about one in-game month), it does not oscillate, and its bounds hold.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/markets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stock that is exactly the target cover at [demandPerS]: no stock signal.
double atTarget(double demandPerS) =>
    kTargetCoverDays * demandPerS * kColonyDaySec;

/// A market in balance at its anchor (1 credit), demand and supply [flow].
GoodMarket balanced({double flow = 1}) => GoodMarket(
    price: 1,
    anchor: 1,
    stock: atTarget(flow),
    demandPerS: flow,
    supplyPerS: flow);

/// [days] closes of [m] at [demand] / [supply], stock held at exactly the
/// target cover of the SMOOTHED demand the close will see (so the stock
/// term stays silent and the flows alone move the price); returns ln p
/// after each.
List<double> run(GoodMarket m, GoodClassParams p, int days,
    {required double demand, required double supply}) {
  final out = <double>[];
  for (var d = 0; d < days; d++) {
    final smoothed =
        m.demandPerS + (demand - m.demandPerS) * flowSmoothingWeight;
    closeGoodDay(
        m,
        GoodDay(
            demandPerS: demand,
            supplyPerS: supply,
            stock: atTarget(smoothed),
            anchor: 1),
        p);
    out.add(math.log(m.price));
  }
  return out;
}

void main() {
  // η is derived, not tuned: (1 − 2^(−1/(H − τ))) / ε for the class
  // half-life H and the flow smoothing's delay τ.
  test('every class η follows from its half-life', () {
    for (final c in GoodClass.values) {
      final p = kGoodClassParams[c]!;
      expect(
          math.pow(1 - p.eta * p.elasticity,
              p.halfLifeDays - kFlowSmoothingDays),
          closeTo(0.5, 1e-12),
          reason: c.name);
      // Month-scale: no class faster than 2 weeks, none slower than 2 months.
      expect(p.halfLifeDays, inInclusiveRange(14, 60), reason: c.name);
      // Stable discrete step (no cobweb): η·ε well under 1.
      expect(p.eta * p.elasticity, lessThan(0.1), reason: c.name);
    }
    // Most goods: a month. Steel is the default class.
    expect(kGoodClassParams[goodClassOf(Commodity.steel)]!.halfLifeDays, 30);
  });

  // A step change in demand: the price approaches the new equilibrium and
  // halves its log distance to it in about the class half-life, counted
  // from the step (what a player sees). And the tâtonnement's own speed,
  // measured once the 3-day flow smoothing has caught up (from day 10), is
  // the step half-life H − τ the derivation promises.
  for (final c in GoodClass.values) {
    test('a demand step closes half the gap in ~its half-life (${c.name})',
        () {
      final p = kGoodClassParams[c]!;
      final m = balanced();
      // +25% demand at fixed supply: equilibrium where 1.25·q^−εd = q^εs.
      const step = 1.25;
      final target = math.log(step) / p.elasticity;
      final h = p.halfLifeDays.round();
      final lnP = run(m, p, 10 + 3 * h, demand: step, supply: 1);
      double gap(int day) => target - lnP[day - 1];
      // From day 10, H − τ days close half the remaining gap (±10%).
      final t = p.stepHalfLifeDays.round();
      expect(gap(10 + t) / gap(10), closeTo(0.5, 0.05), reason: c.name);
      // From the step: half the gap on day H, give or take 3.
      final halfDay = [for (var d = 1; d <= lnP.length; d++) d]
          .firstWhere((d) => gap(d) <= target / 2);
      expect(halfDay, inInclusiveRange(h - 3, h + 3),
          reason: '${c.name}: half the gap on day $halfDay');
      // Approaches from below and never overshoots.
      for (var d = 1; d <= lnP.length; d++) {
        expect(lnP[d - 1], lessThanOrEqualTo(target + 1e-12));
      }
    });
  }

  test('steel (the month default) halves a demand step in 30 ± 3 days', () {
    final p = paramsOf(Commodity.steel);
    final m = balanced();
    final target = math.log(1.25) / p.elasticity;
    final lnP = run(m, p, 60, demand: 1.25, supply: 1);
    final halfDay = [for (var d = 1; d <= 60; d++) d]
        .firstWhere((d) => target - lnP[d - 1] <= target / 2);
    expect(halfDay, inInclusiveRange(27, 33));
  });

  // Cobweb guard 1: a big step (demand ×4, supply ×¼ the next day) and
  // back. The price moves monotonically toward each equilibrium and never
  // past it: no oscillation, no blow-up.
  test('a big step and back neither oscillates nor blows up', () {
    final p = paramsOf(Commodity.food); // the fastest class
    final m = balanced();
    final up = run(m, p, 200, demand: 4, supply: 1);
    for (var i = 1; i < up.length; i++) {
      expect(up[i], greaterThanOrEqualTo(up[i - 1] - 1e-12),
          reason: 'monotone rise, day $i');
    }
    final down = run(m, p, 400, demand: 1, supply: 1);
    for (var i = 1; i < down.length; i++) {
      expect(down[i], lessThanOrEqualTo(down[i - 1] + 1e-12),
          reason: 'monotone fall, day $i');
      expect(down[i], greaterThanOrEqualTo(-1e-9), reason: 'no undershoot');
    }
    expect(down.last, closeTo(0, 0.01), reason: 'back to the anchor');
  });

  // Cobweb guard 2: supply that answers price with a fortnight's lag, at
  // unit elasticity on top of the market's own (a plant that expands on
  // last fortnight's price) — the classic cobweb set-up. The swings must
  // die out, not grow, and the price must stay bounded throughout.
  test('lagged, over-responsive supply damps out (no cobweb)', () {
    for (final c in GoodClass.values) {
      final p = kGoodClassParams[c]!;
      final m = balanced();
      final history = <double>[];
      const lag = 14;
      for (var d = 0; d < 720; d++) {
        final past = d >= lag ? history[d - lag] : 0.0;
        // Demand stepped up 50%; supply chases the price of a fortnight ago.
        final supply = math.exp(past);
        closeGoodDay(
            m,
            GoodDay(
                demandPerS: 1.5,
                supplyPerS: supply,
                stock: atTarget(1.5),
                anchor: 1),
            p);
        expect(m.price.isFinite && m.price > 0, isTrue);
        expect(math.log(m.price).abs(), lessThan(1), reason: 'bounded');
        history.add(math.log(m.price));
      }
      double swing(int from, int to) {
        final s = history.sublist(from, to);
        return s.reduce(math.max) - s.reduce(math.min);
      }

      expect(swing(540, 720), lessThanOrEqualTo(swing(60, 240) + 1e-9),
          reason: '${c.name}: swings must not grow');
      expect(swing(540, 720), lessThan(0.05), reason: '${c.name} settles');
    }
  });

  test('prices stay positive and finite, the day move clamped, the bounds '
      'held', () {
    final p = paramsOf(Commodity.rations);
    // Nobody wants it, years on end, a pile in stock.
    final glut = GoodMarket(price: 5, anchor: 5, stock: 1e6, supplyPerS: 10);
    var last = math.log(glut.price);
    for (var d = 0; d < 5000; d++) {
      closeGoodDay(
          glut,
          const GoodDay(demandPerS: 0, supplyPerS: 10, stock: 1e6, anchor: 5),
          p);
      final now = math.log(glut.price);
      expect(glut.price.isFinite && glut.price > 0, isTrue);
      expect((now - last).abs(), lessThanOrEqualTo(kMaxDailyLogStep + 1e-12));
      last = now;
    }
    expect(glut.price, closeTo(5 * kPriceFloorFraction, 1e-9),
        reason: 'decays to scrap value, not to zero');

    // Everybody wants it, nobody makes it, no port: capped at the cost
    // ceiling.
    final dear = GoodMarket(price: 5, anchor: 5);
    for (var d = 0; d < 5000; d++) {
      closeGoodDay(
          dear,
          const GoodDay(
              demandPerS: 10, supplyPerS: 0, stock: 0, anchor: 5, unitCost: 4),
          p);
      expect(dear.price.isFinite && dear.price > 0, isTrue);
    }
    expect(dear.price, closeTo(4 * kCostCeilingMultiple, 1e-9));

    // A corrupt state recovers to the anchor instead of trading at NaN.
    final bad = GoodMarket(price: double.nan, anchor: 3);
    closeGoodDay(bad, const GoodDay(demandPerS: 1, supplyPerS: 1, anchor: 3),
        p);
    expect(bad.price, closeTo(3, 1e-12));
  });

  test('a seed is the old model\'s price and the day\'s flows', () {
    final g = seedGood(
        42,
        const GoodDay(
            demandPerS: 2, supplyPerS: 3, stock: 7, anchor: 40));
    expect(g.price, 42);
    expect(g.anchor, 40);
    expect(g.demandPerS, 2);
    expect(g.supplyPerS, 3);
    expect(g.stock, 7);
    expect(seedGood(0, const GoodDay(demandPerS: 0, supplyPerS: 0, anchor: 9))
        .price, 9);
    // Every market good the solve prices has a class.
    for (final c in marketGoods()) {
      expect(kGoodClassParams[goodClassOf(c)], isNotNull, reason: c);
    }
  });
}
