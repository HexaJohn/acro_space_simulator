// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Learning curves and invention, headless (docs/plans/dynamic-markets.md
/// phase 2, `learning.dart`): Wright's law, Earth's prices sliding down
/// world learning with no day-1 jump, spillover, local experience, the
/// invention timeline on a synthetic good, saving, and determinism.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/learning.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/markets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Steps [tech]'s world and [earth] [days] colony days, with a colony
/// selling [exportsPerS] (units/s) to Earth throughout.
void stepWorld(TechState tech, Market earth, int days,
    {Map<String, double> exportsPerS = const {}}) {
  for (var i = 0; i < days; i++) {
    tech.advanceWorldDay(exportsUnits: {
      for (final e in exportsPerS.entries) e.key: e.value * kColonyDaySec,
    });
    applyWorldTech(earth, tech);
    closeEarthDay(earth, exportsPerS: exportsPerS);
  }
}

/// A synthetic good Earth invents on day [day]: 1 t units, a $1M mature
/// cost, first lot 50 units, 20× first-unit premium, 20% learning, made at
/// 0.01 units/s at full depth.
const String kFusion = 'fusionCore';
TechCatalog fusionCatalog({double day = 100}) => TechCatalog({
      ...kTechSeeds,
      kFusion: TechSeed(
        learningRate: 0.20,
        firstUnitPremium: 20,
        inventionDay: day,
        firstLotUnits: 50,
        maturePrice: 1e6,
        worldOutputPerS: 0.01,
        inventEarlyResearch: 100000,
      ),
    });

/// Colony days in [years] game-years, whole.
int daysIn(double years) => (years * 365.25).round();

void main() {
  test('Wright\'s law: each doubling takes LR off the premium', () {
    const cat = TechCatalog.standard;
    for (final g in cat.goods) {
      final s = cat[g]!;
      if (!s.learns) continue;
      expect(s.exponent, closeTo(-math.log(1 - s.learningRate) / math.ln2, 1e-12));
      final q0 = cat.firstLot(g);
      // At the first lot the premium is P exactly; below it, never more.
      expect(cat.premiumAt(g, q0), closeTo(s.firstUnitPremium, 1e-9), reason: g);
      expect(cat.premiumAt(g, q0 / 10), closeTo(s.firstUnitPremium, 1e-9),
          reason: '$g: no premium above the first lot\'s');
      for (var k = 1; k <= 12; k++) {
        final ratio = cat.premiumAt(g, q0 * math.pow(2, k)) /
            cat.premiumAt(g, q0 * math.pow(2, k - 1));
        expect(ratio, closeTo(1 - s.learningRate, 1e-9), reason: '$g k=$k');
      }
    }
    // The unit cost is mature × (1 + premium): rocket parts on day 0 are
    // the seed, five times mature.
    final t = TechState();
    final mature = cat.maturePrice(Commodity.rocketParts)!;
    expect(t.earthUnitCost(Commodity.rocketParts),
        earthPrice(Commodity.rocketParts));
    expect(mature, closeTo(earthPrice(Commodity.rocketParts) / 5, 1e-6));
    expect(mature * (1 + cat.premiumAt(Commodity.rocketParts,
            cat.worldQAtStart(Commodity.rocketParts))),
        closeTo(earthPrice(Commodity.rocketParts), 1e-6));
  });

  test('water and oxygen have no premium; advanced goods a large one', () {
    const cat = TechCatalog.standard;
    for (final g in [Commodity.water, Commodity.oxygen]) {
      expect(cat[g]!.learns, isFalse, reason: g);
      expect(cat.premiumAt(g, 1), 0);
      expect(TechState().localCostMultiplier(g), 1);
    }
    for (final g in [Commodity.rocketParts, Commodity.missiles]) {
      expect(cat[g]!.firstUnitPremium, greaterThanOrEqualTo(10), reason: g);
      expect(cat.premiumAt(g, cat.worldQAtStart(g)), greaterThan(1),
          reason: '$g sits mid-curve with a large premium left');
    }
    // Every good in today's game exists from day 0.
    final t = TechState();
    for (final g in cat.goods) {
      expect(t.inventedOnEarth(g), isTrue, reason: g);
      expect(cat[g]!.inventionDay, lessThanOrEqualTo(0), reason: g);
    }
    expect(t.missingOnEarth, isEmpty);
    expect(t.unavailableHere, isEmpty);
  });

  test('day 0: Earth\'s market is exactly phase 1\'s seed', () {
    final a = seedEarthMarketFor(TechState());
    final b = seedEarthMarket();
    expect(a.goods.keys, b.goods.keys);
    for (final g in a.goods.keys) {
      expect(a.priceOf(g), b.priceOf(g), reason: g);
      expect(a.goods[g]!.anchor, b.goods[g]!.anchor, reason: g);
    }
  });

  // The user's intent: high-tech goods get cheaper as the world makes more.
  // Rocket parts and missiles slide down their curves over game years;
  // mature goods sit at cost; nothing jumps on day 1.
  test('world learning lowers Earth\'s high-tech prices over years', () {
    final tech = TechState();
    final earth = seedEarthMarketFor(tech);
    const goods = [Commodity.rocketParts, Commodity.missiles];
    final p0 = {for (final g in goods) g: earth.priceOf(g)!};
    final steel0 = earth.priceOf(Commodity.steel)!;
    final water0 = earth.priceOf(Commodity.water)!;

    stepWorld(tech, earth, 1);
    for (final g in goods) {
      final r = earth.priceOf(g)! / p0[g]!;
      expect(r, lessThanOrEqualTo(1), reason: '$g day 1');
      expect(r, greaterThan(0.999), reason: '$g: no day-1 jump');
    }

    final table = <String, List<double>>{for (final g in goods) g: [p0[g]!]};
    var day = 1;
    for (final y in const [1.0, 2.0, 5.0, 10.0]) {
      stepWorld(tech, earth, daysIn(y) - day);
      day = daysIn(y);
      for (final g in goods) {
        table[g]!.add(earth.priceOf(g)!);
      }
    }
    for (final g in goods) {
      final row = table[g]!;
      for (var i = 1; i < row.length; i++) {
        expect(row[i], lessThan(row[i - 1]), reason: '$g falls year on year');
      }
      // Tracks its anchor: the month-scale half-life lags a slow curve by
      // well under a percent.
      expect(earth.priceOf(g)!,
          closeTo(tech.earthUnitCost(g)!, tech.earthUnitCost(g)! * 0.01));
      // ignore: avoid_print
      print('Earth $g per unit, years 0/1/2/5/10: '
          '${row.map((p) => p.toStringAsFixed(0)).join(' / ')} '
          '(per kg: ${row.map((p) => (p / (g == Commodity.missiles ? 1000 : 100)).toStringAsFixed(0)).join(' / ')})');
    }
    expect(table[Commodity.rocketParts]!.last,
        lessThan(table[Commodity.rocketParts]!.first * 0.7));
    expect(table[Commodity.missiles]!.last,
        lessThan(table[Commodity.missiles]!.first * 0.8));
    // Mature goods barely move: steel a fraction of a percent in a decade,
    // water not at all.
    expect(earth.priceOf(Commodity.steel)!, closeTo(steel0, steel0 * 0.005));
    expect(earth.priceOf(Commodity.water)!, closeTo(water0, water0 * 1e-9));
  });

  test('a colony\'s exports to Earth speed the world\'s learning', () {
    final quiet = TechState(), busy = TechState();
    final e1 = seedEarthMarketFor(quiet), e2 = seedEarthMarketFor(busy);
    stepWorld(quiet, e1, 365);
    stepWorld(busy, e2, 365, exportsPerS: const {Commodity.rocketParts: 0.4});
    expect(busy.worldQOf(Commodity.rocketParts),
        closeTo(quiet.worldQOf(Commodity.rocketParts) + 0.4 * 365 * kColonyDaySec,
            1e-6));
    expect(busy.earthUnitCost(Commodity.rocketParts)!,
        lessThan(quiet.earthUnitCost(Commodity.rocketParts)!));
  });

  // Spillover: a colony that makes nothing still learns a little from the
  // world — φ of the world's progress since the first lot — so its premium
  // is 20^b times Earth's, and falls as the world's does.
  test('world knowledge spills over to a colony, slowly', () {
    final tech = TechState();
    final earth = seedEarthMarketFor(tech);
    const cat = TechCatalog.standard;
    for (final g in [Commodity.rocketParts, Commodity.steel]) {
      final s = cat[g]!;
      final earthPremium = cat.premiumAt(g, tech.worldQOf(g));
      final colonyPremium = tech.localCostMultiplier(g) - 1;
      final expected =
          earthPremium * math.pow(kWorldSpillover, -s.exponent).toDouble();
      // Not exact: Qeff adds the first lot back, a few percent less
      // premium for a young good (rocket parts' first lot is ~0.7% of the
      // world's output, so ~13% of what the colony counts of it).
      expect(colonyPremium, closeTo(expected, expected * 0.05), reason: g);
      expect(colonyPremium, lessThanOrEqualTo(expected), reason: g);
      expect(colonyPremium, greaterThan(earthPremium), reason: g);
    }
    final m0 = tech.localCostMultiplier(Commodity.rocketParts);
    stepWorld(tech, earth, daysIn(2));
    final m2 = tech.localCostMultiplier(Commodity.rocketParts);
    expect(m2, lessThan(m0), reason: 'the world learned; so did we, a bit');
    // Slowly: what the colony counts of the world's experience is a
    // twentieth of it (plus the first lot it starts from).
    expect(tech.effectiveQ(Commodity.rocketParts),
        lessThan(tech.worldQOf(Commodity.rocketParts) * 0.06));
  });

  test('local production lowers a colony\'s own cost', () {
    final tech = TechState();
    const g = Commodity.rocketParts;
    const cat = TechCatalog.standard;
    final m0 = tech.localCostMultiplier(g);
    // Double the colony's effective experience by making that much.
    tech.recordLocal({g: tech.effectiveQ(g)});
    final m1 = tech.localCostMultiplier(g);
    expect(m1, lessThan(m0));
    expect((m1 - 1) / (m0 - 1), closeTo(1 - cat[g]!.learningRate, 1e-9),
        reason: 'one doubling, LR off the premium');
    expect(tech.localQOf(g), greaterThan(0));
    // Earth's cost is the world's alone.
    expect(tech.earthUnitCost(g), earthPrice(g));
    // A good that doesn't learn records nothing.
    tech.recordLocal({Commodity.water: 1e6});
    expect(tech.localQ.containsKey(Commodity.water), isFalse);
  });

  test('invention: a good does not exist before its day on Earth', () {
    final tech = TechState(catalog: fusionCatalog());
    final earth = seedEarthMarketFor(tech);
    expect(tech.inventedOnEarth(kFusion), isFalse);
    expect(tech.availableHere(kFusion), isFalse);
    expect(tech.missingOnEarth, {kFusion});
    expect(tech.unavailableHere, {kFusion});
    expect(earth.goods.containsKey(kFusion), isFalse, reason: 'no source');
    expect(tech.earthUnitCost(kFusion), isNull);
    expect(tech.worldQOf(kFusion), 0);
    expect(tech.localCostMultipliers().containsKey(kFusion), isFalse);

    stepWorld(tech, earth, 99);
    expect(earth.goods.containsKey(kFusion), isFalse);
    expect(tech.daysUntilInvented(kFusion), 1);
    final invented = tech.advanceWorldDay();
    expect(invented, [kFusion]);
    applyWorldTech(earth, tech);
    closeEarthDay(earth);
    // Born at the dear end of its curve: mature × (1 + P).
    expect(tech.worldQOf(kFusion), 50);
    expect(earth.priceOf(kFusion), closeTo(1e6 * 21, 1));
    expect(tech.missingOnEarth, isEmpty);

    // Earth's new industry ramps up over five years; the price slides.
    final p100 = earth.priceOf(kFusion)!;
    stepWorld(tech, earth, 365);
    final p465 = earth.priceOf(kFusion)!;
    stepWorld(tech, earth, daysIn(5) - 365);
    final pRamped = earth.priceOf(kFusion)!;
    expect(p465, lessThan(p100));
    expect(pRamped, lessThan(p465));
    expect(pRamped, greaterThan(1e6), reason: 'never below mature cost');
    // ignore: avoid_print
    print('synthetic good on Earth: invented ${p100.toStringAsFixed(0)}, '
        '+1 yr ${p465.toStringAsFixed(0)}, +5 yr ${pRamped.toStringAsFixed(0)}');
  });

  test('inventing early costs research, more the earlier', () {
    final tech = TechState(catalog: fusionCatalog(day: 365.25 * 2));
    final cost = tech.inventEarlyCost(kFusion)!;
    expect(cost, closeTo(100000 * (1 + 2), 1e-6),
        reason: 'base × (1 + years early)');
    expect(tech.inventEarlyCost(Commodity.steel), isNull,
        reason: 'already invented');
    expect(tech.inventEarlyCost('nothing'), isNull);
    stepWorld(tech, seedEarthMarketFor(tech), daysIn(1));
    expect(tech.inventEarlyCost(kFusion)!, closeTo(100000 * 2, 100));

    expect(tech.markInventedEarly(kFusion), isTrue);
    expect(tech.availableHere(kFusion), isTrue);
    expect(tech.inventedOnEarth(kFusion), isFalse);
    expect(tech.missingOnEarth, {kFusion}, reason: 'still no import source');
    expect(tech.unavailableHere, isEmpty);
    expect(tech.inventEarlyCost(kFusion), isNull, reason: 'once');
    expect(tech.markInventedEarly(kFusion), isFalse);
    // The first mover makes it at the first lot's premium, until it learns.
    expect(tech.localCostMultiplier(kFusion), closeTo(21, 1e-9));
    expect(tech.localCostMultipliers()[kFusion], closeTo(21, 1e-9));
  });

  test('the learning state round-trips and carries on identically', () {
    final a = TechState(catalog: fusionCatalog(day: 30));
    final ea = seedEarthMarketFor(a);
    stepWorld(a, ea, 40);
    a.recordLocal({Commodity.rocketParts: 123.5, Commodity.electronics: 7});
    final json = jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>;
    final b = TechState(catalog: fusionCatalog(day: 30))..restore(json);
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    final eb = Market.fromJson(
        (jsonDecode(jsonEncode(ea.toJson())) as Map).cast<String, Object?>());
    stepWorld(a, ea, 50);
    stepWorld(b, eb, 50);
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    expect(jsonEncode(eb.toJson()), jsonEncode(ea.toJson()));

    // An old save has no learning state: day 0, every curve at its seed.
    final fresh = TechState()..restore(null);
    expect(fresh.isFresh, isTrue);
    expect(fresh.earthUnitCost(Commodity.missiles), earthPrice(Commodity.missiles));
  });

  test('two worlds stepped alike are identical', () {
    String run() {
      final t = TechState(catalog: fusionCatalog(day: 20));
      final e = seedEarthMarketFor(t);
      stepWorld(t, e, 200, exportsPerS: const {Commodity.missiles: 0.15});
      t.recordLocal({Commodity.missiles: 99});
      return '${jsonEncode(t.toJson())}|${jsonEncode(e.toJson())}';
    }

    expect(run(), run());
  });
}
