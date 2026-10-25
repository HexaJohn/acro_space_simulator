// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// No one plant swamps the treasury (docs/plans/factory-floors.md §7 Q8:
/// corporate tax is real money).
///
/// This was a HARD cap at 4× a plant's workers' tax, because revenue
/// counted every unit shipped at Earth's fixed price and the Rocket Parts
/// and Missile templates converted to hundreds of §/s. Since dynamic markets
/// (docs/plans/dynamic-markets.md §3 "Corporate tax needs no cap") revenue
/// counts only what sells and prices fall under a glut, so the bound is a
/// generous SAFETY ceiling with a smooth saturation
/// (`kCorporateTaxSafetyMultiple`, `softTaxCeiling`). The old ≤ 4× bound
/// would contradict that on purpose, so these tests pin the new one.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/industrial_overhead.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

void main() {
  for (final body in const ['earth', 'mars', 'moon']) {
    test('every template\'s corporate tax is under its safety ceiling on '
        '$body', () {
      for (final type in kFactoryPlantTypes) {
        final sim = economyColony(bodyId: body);
        placePlant(sim, type);
        runDays(sim, 1.01, specs: [specOf(type)], inputs: 1e5);
        // Its staff: the floor's jobs and, for an advanced plant, the
        // overhead engineers its books pay (`industrial_overhead.dart`).
        final staff = specOf(type).jobs + overheadJobsOf(type);
        final workerTax = staff *
            kCapHappiness *
            CitySim.defaultTaxRate *
            CitySim.taxPerWorkerPerSec *
            Economy.capitalism.fundsMult;
        expect(sim.colonyEconomy.corporateTaxFundsPerS,
            lessThanOrEqualTo(workerTax * kCorporateTaxSafetyMultiple),
            reason: '$type on $body');
      }
    });
  }

  // The ceiling saturates smoothly: equal to the raw tax to first order,
  // increasing, never above the ceiling, and with no kink (its slope falls
  // continuously from 1 toward 0).
  test('the safety ceiling is smooth, increasing and bounded', () {
    const ceiling = 10.0;
    expect(softTaxCeiling(0, ceiling), 0);
    expect(softTaxCeiling(-5, ceiling), 0);
    expect(softTaxCeiling(5, 0), 0);
    expect(softTaxCeiling(0.01, ceiling), closeTo(0.01, 1e-5));
    var last = 0.0, lastSlope = 1.0;
    for (var raw = 0.5; raw <= 200; raw *= 1.5) {
      final v = softTaxCeiling(raw, ceiling);
      expect(v, greaterThan(last), reason: 'increasing at $raw');
      expect(v, lessThan(ceiling + 1e-12), reason: 'bounded at $raw');
      expect(v, lessThanOrEqualTo(raw), reason: 'never more than owed');
      // Numerical slope, which must fall smoothly (no step at the old cap).
      const h = 1e-4;
      final slope =
          (softTaxCeiling(raw + h, ceiling) - softTaxCeiling(raw - h, ceiling)) /
              (2 * h);
      expect(slope, lessThanOrEqualTo(lastSlope + 1e-9));
      expect(slope, greaterThanOrEqualTo(0));
      last = v;
      lastSlope = slope;
    }
    expect(softTaxCeiling(1e6, ceiling), closeTo(ceiling, 1e-9));
  });

  // The ceiling barely touches an ordinary plant: a Steel Mill's tax is about
  // its workers' own, a thirtieth of the ceiling, and passes through within
  // 2% (the saturation's first-order shave, raw/(2·ceiling) ≈ 1.7%). Exactly
  // the formula, so nothing else shaves it.
  test('the ceiling leaves an ordinary plant\'s tax nearly whole', () {
    final sim = economyColony();
    final lot = placePlant(sim, 'steelmill');
    runDays(sim, 1.01, specs: [specOf('steelmill')]);
    final pnl = sim.colonyEconomy.lastPnl[lot]!;
    final raw = pnl.tax * kCreditsToFunds / kColonyDaySec;
    expect(sim.colonyEconomy.corporateTaxFundsPerS,
        closeTo(softTaxCeiling(raw, sim.corporateTaxCeilingFor(lot)), 1e-9));
    expect(sim.colonyEconomy.corporateTaxFundsPerS,
        closeTo(raw, raw * 0.02));
  });
}
