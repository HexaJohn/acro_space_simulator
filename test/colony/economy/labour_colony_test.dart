// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The labour market in a live colony (docs/plans/dynamic-markets.md phase
/// 3): an engineer shortage starves the low bidders' floors of staff,
/// raises the engineering wage, and the tier wages reach every plant's books
/// and the cost solve; schools shift the skill mix; the market saves and
/// replays exactly.
///
/// The shortage: the fixture colony's 300 people at the settlers' skill mix
/// are 36 engineers (12%), and a Rocket Parts floor posts 32 engineering
/// jobs (its assembly and avionics benches, `skill_tiers.dart`), so one
/// plant is fully staffed and a second is short by 28 of its 32.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/labour_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/skill_tiers.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_integration/economy_fixture.dart';
import '../factory_integration/factory_colony_fixture.dart';

/// A fixture colony with two Rocket Parts floors, [a] and [b].
({CitySim sim, String a, String b}) twoRocketPlants() {
  final sim = economyColony();
  final a = placePlant(sim, 'rocketfactory');
  final b = placePlant(sim, 'rocketfactory');
  return (sim: sim, a: a, b: b);
}

/// Sets [site]'s rolling books to a [margin] (on a revenue of 100/s): what
/// its bid for scarce labour reads.
void setMargin(CitySim sim, String site, double margin) {
  final book = sim.firmBookOf(site)!;
  book
    ..revenuePerS = 100
    ..costPerS = 100 * (1 - margin)
    ..taxPerS = 0;
}

void main() {
  setUpAll(ensureFactoryCatalog);

  test('the rocket floor posts its engineers by recipe tier', () {
    final sim = economyColony();
    final lot = placePlant(sim, 'rocketfactory');
    final shares = sim.floorLabourShares(lot);
    // 32 bench jobs of 50 are engineering, the 18 handler operators skilled.
    expect(shares[SkillTier.engineering], closeTo(32 / 50, 1e-12));
    expect(shares[SkillTier.skilled], closeTo(18 / 50, 1e-12));
  });

  // In the shortage the books decide: the thriving firm is served first and
  // fully staffed, the losing one starves.
  test('low-paying plants are the first to go understaffed', () {
    final r = twoRocketPlants();
    runDays(r.sim, 1.01, specs: [specOf('rocketfactory')], inputs: 1e5);
    // The lower site id would win a tie; give the higher one the margin, so
    // the order is the books', not the ids'.
    final (lo, hi) = r.a.compareTo(r.b) < 0 ? (r.a, r.b) : (r.b, r.a);
    setMargin(r.sim, hi, 0.4);
    setMargin(r.sim, lo, -0.1);
    runDays(
      r.sim,
      2 * kEconTickS / 120,
      specs: [specOf('rocketfactory')],
      inputs: 1e5,
    );
    final rich = r.sim.labourShareOf(hi), poor = r.sim.labourShareOf(lo);
    // ignore: avoid_print
    print(
      'engineer shortage: the 40%-margin firm staffs '
      '${(rich * 100).toStringAsFixed(1)}%, the losing one '
      '${(poor * 100).toStringAsFixed(1)}%',
    );
    expect(rich, greaterThan(0.95));
    expect(poor, lessThan(0.25));
    // And the other way round once the books turn.
    setMargin(r.sim, hi, -0.1);
    setMargin(r.sim, lo, 0.4);
    runDays(
      r.sim,
      2 * kEconTickS / 120,
      specs: [specOf('rocketfactory')],
      inputs: 1e5,
    );
    expect(r.sim.labourShareOf(lo), greaterThan(0.95));
    expect(r.sim.labourShareOf(hi), lessThan(0.25));
  });

  // The state pays its fixed scale: a profitable private firm outbids it.
  test(
    'a state plant pays the government scale and loses to a thriving firm',
    () {
      final r = twoRocketPlants();
      final (lo, hi) = r.a.compareTo(r.b) < 0 ? (r.a, r.b) : (r.b, r.a);
      // The state takes the lower id, so only the bid can put it second.
      expect(r.sim.nationalise(lo), isTrue);
      runDays(r.sim, 1.01, specs: [specOf('rocketfactory')], inputs: 1e5);
      setMargin(r.sim, hi, 0.2);
      runDays(
        r.sim,
        2 * kEconTickS / 120,
        specs: [specOf('rocketfactory')],
        inputs: 1e5,
      );
      expect(r.sim.labourShareOf(hi), greaterThan(0.95));
      expect(r.sim.labourShareOf(lo), lessThan(0.25));
    },
  );

  // The shortage bids the engineering wage up over the month, and the
  // tier wages are what every plant's books and the cost solve charge.
  test('tier wages show up in the P&L and in costs', () {
    final r = twoRocketPlants();
    runDays(r.sim, 20, specs: [specOf('rocketfactory')], inputs: 1e5);
    final e = r.sim.colonyEconomy;
    final q = e.labour.ratioOf(SkillTier.engineering);
    // ignore: avoid_print
    print(
      'after 20 days short of engineers: engineering wage '
      '${q.toStringAsFixed(3)}× its anchor; skilled '
      '${e.labour.ratioOf(SkillTier.skilled).toStringAsFixed(3)}×',
    );
    expect(q, greaterThan(1.15), reason: 'posts for 64, 36 to fill them');
    expect(
      e.labour.ratioOf(SkillTier.skilled),
      lessThan(1),
      reason: 'skilled people are plentiful',
    );

    // The day's book was solved at the ratio the day opened with (the
    // close then stepped it, by at most the labour market's η).
    final book = r.sim.localPrices!;
    final bookRatio =
        book.wageOf(SkillTier.engineering) /
        (book.wagePerWorkerS * skillMultipleOf(SkillTier.engineering));
    expect(
      bookRatio,
      closeTo(q, q * kLabourParams.eta),
      reason: 'the book carries the market wage',
    );

    final pnl = e.lastPnl[r.a]!;
    expect(
      pnl.wagesByTier.keys,
      containsAll([SkillTier.engineering, SkillTier.skilled]),
    );
    var sum = 0.0;
    for (final v in pnl.wagesByTier.values) {
      sum += v;
    }
    expect(sum, closeTo(pnl.wages, 1e-9));
    // Engineers are 64% of the hours and at 2.8× the anchor and more, most
    // of the bill.
    expect(
      pnl.wagesByTier[SkillTier.engineering]!,
      greaterThan(pnl.wagesByTier[SkillTier.skilled]! * 3),
    );

    // The cost solve: dearer engineers make rocket parts dearer to make.
    final facts = r.sim.marketFacts();
    expect(facts.wageRatio[SkillTier.engineering], q);
    final earth = e.earthMarket.prices;
    MarketFacts at(double eng) => MarketFacts(
      bodyId: facts.bodyId,
      economy: facts.economy,
      population: 1000,
      atmosphere: facts.atmosphere,
      airDensity: facts.airDensity,
      surfacePressureKPa: facts.surfacePressureKPa,
      o2Harvestable: facts.o2Harvestable,
      wageRatio: {SkillTier.engineering: eng},
    );
    final cheap = solveLocalMarket(
      at(1),
      earthPrices: earth,
    ).localCost[Commodity.rocketParts]!;
    final dear = solveLocalMarket(
      at(2),
      earthPrices: earth,
    ).localCost[Commodity.rocketParts]!;
    // By the floor crew's engineers only: since `industrial_overhead.dart`
    // most of a rocket part's cost is tooling and overhead engineering, and
    // those hours are contracted at Earth's rate once the colony's own
    // engineers are dearer, so doubling the engineering wage moves the
    // cost by the floor's share (under 1%), not the 10% it did.
    expect(dear, greaterThan(cheap));
    expect(dear, lessThan(cheap * 1.1));
  });

  // Schools: the share of the colony they teach moves the skill mix.
  test('schools shift the colony\'s skill mix toward engineers', () {
    double engineers({required bool school}) {
      final sim = economyColony();
      placePlant(sim, 'steelmill');
      if (school) placePlant(sim, 'school');
      runDays(sim, 10.01, specs: [specOf('steelmill')], inputs: 1e5);
      if (school) expect(sim.educationCoverage, greaterThan(0.3));
      return sim.colonyEconomy.labour.mix[SkillTier.engineering]!;
    }

    final without = engineers(school: false);
    final withSchool = engineers(school: true);
    expect(without, closeTo(kUnschooledMix[SkillTier.engineering]!, 1e-3));
    expect(withSchool, greaterThan(without + 0.002));
  });

  test('the labour market saves and replays exactly', () {
    final r = twoRocketPlants();
    final spec = specOf('rocketfactory');
    runDays(r.sim, 3.5, specs: [spec], inputs: 1e5);
    final saved = r.sim.toJson();
    expect(saved['labour'], isNotNull);
    final loaded = reload(saved);
    String labour(CitySim s) =>
        jsonEncode(s.colonyEconomy.labour.toJsonOrNull());
    expect(labour(loaded), labour(r.sim));
    // And carries on as the unsaved colony does. To a part in a million,
    // not bit for bit: a reloaded colony's commute efficiency (its traffic
    // agents restart) differs in the sixth digit, and staffing follows it.
    runDays(r.sim, 2, specs: [spec], inputs: 1e5);
    runDays(loaded, 2, specs: [spec], inputs: 1e5);
    for (final t in SkillTier.values) {
      final a = r.sim.colonyEconomy.labour, b = loaded.colonyEconomy.labour;
      expect(b.ratioOf(t), closeTo(a.ratioOf(t), 1e-6), reason: t.name);
      expect(b.mix[t], closeTo(a.mix[t]!, 1e-9), reason: t.name);
    }

    // An old save has no labour market: it loads fresh (every wage at its
    // anchor, the mix at what the colony's schooling aims for) and prices
    // from its next close.
    final old = jsonDecode(jsonEncode(saved)) as Map<String, dynamic>
      ..remove('labour');
    final seeded = reload(old);
    expect(seeded.colonyEconomy.labour.isFresh, isTrue);
    expect(seeded.marketFacts().wageRatio[SkillTier.engineering], 1);
    runDays(seeded, 1.01, specs: [spec], inputs: 1e5);
    expect(seeded.colonyEconomy.labour.wages, isNotEmpty);
  });

  test('two colonies stepped alike keep identical labour markets', () {
    String run() {
      final r = twoRocketPlants();
      runDays(r.sim, 4.5, specs: [specOf('rocketfactory')], inputs: 1e5);
      return '${jsonEncode(r.sim.colonyEconomy.labour.toJsonOrNull())}|'
          '${economyJson(r.sim)}';
    }

    expect(run(), run());
  });
}
