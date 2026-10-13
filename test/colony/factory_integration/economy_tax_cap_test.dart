// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// No one plant swamps the treasury (docs/plans/factory-floors.md §7 Q8:
/// corporate tax is real money). The Rocket Parts and Missile templates add
/// so much Earth-priced value that their tax converted to hundreds of §/s,
/// hundreds of times a colony's whole worker tax, and taxes, laws and road
/// upkeep stopped mattering. The treasury's take from each plant is bounded
/// at a few times what its own workers pay.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

void main() {
  for (final body in const ['earth', 'mars', 'moon']) {
    test('every template\'s corporate tax is bounded on $body', () {
      for (final type in kFactoryPlantTypes) {
        final sim = economyColony(bodyId: body);
        placePlant(sim, type);
        runDays(sim, 1.01, specs: [specOf(type)], inputs: 1e5);
        final workerTax = specOf(type).jobs *
            kCapHappiness *
            CitySim.defaultTaxRate *
            CitySim.taxPerWorkerPerSec *
            Economy.capitalism.fundsMult;
        expect(sim.colonyEconomy.corporateTaxFundsPerS,
            lessThanOrEqualTo(workerTax * kCorporateTaxWorkerMultiple + 1e-9),
            reason: '$type on $body');
      }
    });
  }

  // The cap binds the outliers only: a Steel Mill's tax is about its
  // workers' own and passes through whole.
  test('the cap leaves an ordinary plant\'s tax alone', () {
    final sim = economyColony();
    final lot = placePlant(sim, 'steelmill');
    runDays(sim, 1.01, specs: [specOf('steelmill')]);
    final pnl = sim.colonyEconomy.lastPnl[lot]!;
    expect(sim.colonyEconomy.corporateTaxFundsPerS,
        closeTo(pnl.tax * kCreditsToFunds / kColonyDaySec, 1e-6));
  });
}
