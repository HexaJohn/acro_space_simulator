// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Who pays for editing a built floor (docs/plans/factory-floors.md §7 Q9):
/// the player designs any floor; a private firm builds only what pays back
/// within kFirmPaybackYears; the rest is an industrial subsidy from funds;
/// a state plant's edit is the treasury's; and an edit nobody can pay for
/// is undone. The ore is the physical kit in every case.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

/// Forklifts the edit buys: 5 × 0.8 ore of kit.
const int kForklifts = 5;

/// A Steel Mill that has run a day (its firm has cash and the colony has
/// prices), with [kForklifts] forklifts hired through the editor and the
/// editor closed: the edit is owed, not yet measured.
({CitySim sim, String lot, MeasuredRates before, Map<HandlerKind, int> roster,
    double oreOwed}) editedMill({Economy economy = Economy.capitalism}) {
  final sim = economyColony(economy: economy);
  final lot = placePlant(sim, 'steelmill');
  runDays(sim, 1.01, specs: [specOf('steelmill')]);
  final rec = sim.factoryFloors[lot]!;
  final before = rec.rates;
  final roster = {...rec.blueprint.roster};
  // Forklifts unlock at 300 people; the tick just run may have lost one.
  sim.population = kEconPopulation;
  final floor = sim.openFloor(lot)!;
  expect(floor.hire(HandlerKind.forklift, kForklifts).ok, isTrue);
  final out = sim.closeFloor(lot);
  expect(out.capexDelta, greaterThan(0));
  expect(sim.pendingFloorInvestment[lot], closeTo(out.capexDelta, 1e-9));
  return (
    sim: sim,
    lot: lot,
    before: before,
    roster: roster,
    oreOwed: out.capexDelta,
  );
}

/// [r] with [jobs] more job demand (negative: fewer), as the runner would
/// measure a layout that needs more or fewer people.
MeasuredRates withJobs(MeasuredRates r, double jobs) => MeasuredRates(
      inPerS: r.inPerS,
      outPerS: r.outPerS,
      powerKw: r.powerKw,
      jobs: r.jobs + jobs,
      seconds: 300,
    );

void main() {
  // Forklifts that free 10 workers save ~4 credits/s against a few hundred
  // credits of kit: a payback of minutes. The firm pays from its own cash;
  // the treasury doesn't move; the ore leaves stock as the kit.
  test('a private firm pays for an edit that pays back', () {
    final e = editedMill();
    final sim = e.sim;
    final cash = sim.firmBookOf(e.lot)!.cash;
    final funds = sim.funds;
    final ore = sim.stockOf(Commodity.ore);
    final capex = e.oreOwed * sim.localMarket.book.price(Commodity.ore);
    final rec = sim.factoryFloors[e.lot]!;
    expect(sim.applyFloorMeasure(e.lot, withJobs(e.before, -10), rev: rec.rev),
        isTrue);
    expect(sim.firmBookOf(e.lot)!.cash, closeTo(cash - capex, 1e-6));
    expect(sim.funds, funds);
    expect(sim.stockOf(Commodity.ore), closeTo(ore - e.oreOwed, 1e-9));
    expect(sim.pendingFloorInvestment.containsKey(e.lot), isFalse);
    expect(sim.colonyEconomy.stashed.containsKey(e.lot), isFalse);
    expect(sim.colonyEconomy.industrialSubsidyTotal, 0);
    expect(rec.blueprint.roster[HandlerKind.forklift],
        (e.roster[HandlerKind.forklift] ?? 0) + kForklifts);
  });

  // The same kit that saves nothing (it needs five more drivers) never pays
  // back, so the firm won't buy it: the treasury pays, as a subsidy the
  // Budget drawer shows.
  test('an edit that never pays back is subsidised from funds', () {
    final e = editedMill();
    final sim = e.sim;
    final cash = sim.firmBookOf(e.lot)!.cash;
    final funds = sim.funds;
    final ore = sim.stockOf(Commodity.ore);
    final subsidy = e.oreOwed *
        sim.localMarket.book.price(Commodity.ore) *
        kCreditsToFunds;
    final rec = sim.factoryFloors[e.lot]!;
    sim.applyFloorMeasure(e.lot, withJobs(e.before, kForklifts.toDouble()),
        rev: rec.rev);
    expect(sim.firmBookOf(e.lot)!.cash, cash, reason: 'the firm pays nothing');
    expect(sim.funds, closeTo(funds - subsidy, 1e-9));
    expect(sim.colonyEconomy.industrialSubsidyTotal, closeTo(subsidy, 1e-12));
    expect(sim.colonyEconomy.lastIndustrialSubsidy, closeTo(subsidy, 1e-12));
    expect(sim.stockOf(Commodity.ore), closeTo(ore - e.oreOwed, 1e-9));
    expect(rec.rates.jobs, e.before.jobs + kForklifts);
  });

  // An empty treasury can't subsidise it: the floor goes back to the layout
  // and rates it had before the edit, nothing is charged, and a notice
  // says why.
  test('an edit nobody can pay for is reverted', () {
    final e = editedMill();
    final sim = e.sim..funds = 0;
    final ore = sim.stockOf(Commodity.ore);
    final rec = sim.factoryFloors[e.lot]!;
    final revBefore = rec.rev;
    sim.applyFloorMeasure(e.lot, withJobs(e.before, kForklifts.toDouble()),
        rev: rec.rev);
    expect(rec.blueprint.roster, e.roster);
    expect(rec.rates.jobs, e.before.jobs);
    expect(rec.dirty, isFalse, reason: 'its old rates are good again');
    expect(rec.rev, greaterThan(revBefore),
        reason: 'a measurement of the edit still in flight is now stale');
    expect(sim.funds, 0);
    expect(sim.stockOf(Commodity.ore), ore);
    expect(sim.colonyEconomy.notices, hasLength(1));
    expect(sim.pendingFloorInvestment.containsKey(e.lot), isFalse);
  });

  // A state plant's edit is the treasury's, payback or not.
  test('a state plant\'s edit is paid by the treasury', () {
    final e = editedMill(economy: Economy.socialism);
    final sim = e.sim;
    expect(sim.ownerOf(e.lot).isState, isTrue);
    final funds = sim.funds;
    final cost = e.oreOwed *
        sim.localMarket.book.price(Commodity.ore) *
        kCreditsToFunds;
    final rec = sim.factoryFloors[e.lot]!;
    sim.applyFloorMeasure(e.lot, withJobs(e.before, -10), rev: rec.rev);
    expect(sim.funds, closeTo(funds - cost, 1e-9));
    expect(rec.blueprint.roster[HandlerKind.forklift],
        (e.roster[HandlerKind.forklift] ?? 0) + kForklifts);
  });

  // A measurement of a layout edited again since is stale: dropped, and
  // the edit stays owed until the current layout's result lands.
  test('a stale measurement settles nothing', () {
    final e = editedMill();
    final sim = e.sim;
    final rec = sim.factoryFloors[e.lot]!;
    expect(
        sim.applyFloorMeasure(e.lot, withJobs(e.before, -10),
            rev: rec.rev - 1),
        isFalse);
    expect(sim.pendingFloorInvestment[e.lot], closeTo(e.oreOwed, 1e-9));
    expect(sim.colonyEconomy.stashed.containsKey(e.lot), isTrue);
  });
}
