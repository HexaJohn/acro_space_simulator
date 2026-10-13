// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The only real money the plant economy moves (docs/plans/factory-floors.md
/// §7 Q8, Q10): corporate tax from private plants into `funds`, the state
/// plants' losses out as the industry deficit — both on the 1.7 Payoff line
/// and in `netFundsRate`, so the Budget drawer's Net is what the treasury
/// really does. Ownership follows the economy.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

/// Runs one tick and checks the treasury moved by exactly the net rate the
/// tick reports — the identity that puts every line of `netFundsRate`,
/// corporate tax and deficit included, on the Payoff line.
void expectFundsFollowNet(CitySim sim, List<String> types,
    {double inputs = 300}) {
  final before = sim.funds;
  runDays(sim, kEconTickS / kColonyDaySec,
      specs: [for (final t in types) specOf(t)], inputs: inputs);
  expect(sim.funds - before, closeTo(sim.netFundsRate * kEconTickS, 1e-9));
}

void main() {
  // A private plant's tax, from the day's books, is paid into funds over
  // the next day and is a line of the net rate.
  test('corporate tax reaches funds and appears in netFundsRate', () {
    final sim = economyColony();
    final lot = placePlant(sim, 'steelmill');
    expect(sim.corporateTaxRate, 0, reason: 'nothing booked before a day');
    runDays(sim, 1.01, specs: [specOf('steelmill')]);
    final pnl = sim.colonyEconomy.lastPnl[lot]!;
    expect(pnl.tax, greaterThan(0));
    expect(sim.corporateTaxRate,
        closeTo(pnl.tax * kCreditsToFunds / kColonyDaySec, 1e-6));
    expect(
        sim.netFundsRate,
        closeTo(
            sim.taxIncomeRate +
                sim.lawUpkeepRate -
                sim.roadUpkeepPaidRate +
                sim.corporateTaxRate,
            1e-12));
    expectFundsFollowNet(sim, ['steelmill']);
  });

  // The calibration of kCreditsToFunds (see its doc): a healthy templated
  // Steel Mill's corporate tax is the same order as the worker tax its 35
  // workers pay at a typical 60% happiness, the default tax and
  // capitalism's funds multiplier. Off by more than 2x either way and a
  // plant either doesn't matter to the budget or swamps it.
  test('kCreditsToFunds puts a Steel Mill\'s tax on its workers\' scale', () {
    final sim = economyColony();
    placePlant(sim, 'steelmill');
    runDays(sim, 1.01, specs: [specOf('steelmill')]);
    final workerTax = 35 *
        0.6 *
        CitySim.defaultTaxRate *
        CitySim.taxPerWorkerPerSec *
        Economy.capitalism.fundsMult;
    final ratio = sim.corporateTaxRate / workerTax;
    expect(ratio, inInclusiveRange(0.5, 2.0),
        reason: 'mill ${sim.corporateTaxRate} §/s vs workers $workerTax');
  });

  // Ownership follows the economy: socialism and communism build state
  // plants; capitalism and a free market private ones, each a fresh firm.
  test('a new plant\'s owner follows the economy', () {
    for (final e in Economy.values) {
      final sim = economyColony(economy: e);
      final lot = placePlant(sim, 'refinery');
      final owner = sim.factoryFloors[lot]!.owner!;
      final statist = e == Economy.socialism || e == Economy.communism;
      expect(owner.isState, statist, reason: e.name);
      if (!statist) expect(owner.firmId, startsWith('firm-$lot-'));
    }
  });

  // Communism: the plant is the state's; a losing floor loses money every
  // day, and that loss is charged to funds as the industry deficit. It
  // never lays off, idles or closes — the player runs it.
  test('a communist state plant never acts and its loss is the deficit', () {
    final sim = economyColony(economy: Economy.communism);
    final lot = placePlant(sim, 'steelmill');
    makeLosing(sim, lot);
    final roster = {...sim.factoryFloors[lot]!.blueprint.roster};
    runDays(sim, 10, specs: [specOf('steelmill')]);
    final pnl = sim.colonyEconomy.lastPnl[lot]!;
    expect(pnl.tax, 0);
    expect(pnl.preTax, lessThan(0));
    expect(sim.industryDeficitRate,
        closeTo(-pnl.preTax * kCreditsToFunds / kColonyDaySec, 1e-6));
    expect(sim.corporateTaxRate, 0);
    expect(sim.factoryFloors[lot]!.blueprint.roster, roster);
    expect(sim.floorThrottleOf(lot), 1);
    expect(sim.pendingFirmOffers, isEmpty);
    expect(
        sim.netFundsRate,
        closeTo(
            sim.taxIncomeRate +
                sim.lawUpkeepRate -
                sim.roadUpkeepPaidRate -
                sim.industryDeficitRate,
            1e-12));
    expectFundsFollowNet(sim, ['steelmill']);
  });

  // A private plant left over from capitalism is taken over at the first
  // day close under communism, which tolerates none.
  test('turning communist nationalises private plants at the day close', () {
    final sim = economyColony();
    final lot = placePlant(sim, 'refinery');
    expect(sim.ownerOf(lot).isState, isFalse);
    sim.economy = Economy.communism;
    runDays(sim, 1.01, specs: [specOf('refinery')]);
    expect(sim.ownerOf(lot).isState, isTrue);
    expect(sim.firmBookOf(lot)!.owner.isState, isTrue);
  });

  // The kill-switch and an empty colony: no plant, no money moves.
  test('a colony without plants pays and charges nothing', () {
    final sim = economyColony();
    runDays(sim, 2);
    expect(sim.corporateTaxRate, 0);
    expect(sim.industryDeficitRate, 0);
    expect(sim.toJson().containsKey('plantEconomy'), isFalse,
        reason: 'saves as it did before the economy');
  });
}
