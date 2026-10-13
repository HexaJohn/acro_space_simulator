// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A template plant must be a going concern (docs/plans/factory-floors.md
/// §3 "Ownership and money": private firms "must still be able to make
/// money and afford the labor, logistics, materials").
///
/// Engagement with floors is optional (§7 Q1/Q6), so the plant a player
/// never opens has to survive on its own. If one of these fails, the derived
/// prices make that plant structurally unprofitable: fix the calibration
/// (this test found the Earth ore and rations prices, `earth_market.dart`),
/// never the test.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

void main() {
  // Every world, not just Earth: Earth's prices are pinned to the Earth
  // market, which hid that off-world the price-setting plant ran at a loss
  // by construction (no freight or wear in its cost, and a "glut" read
  // into every good nothing in the colony drew as a flow).
  for (final body in const ['earth', 'mars', 'moon']) {
    for (final type in kFactoryPlantTypes) {
      test('a templated private $type on $body stays healthy for 30 days',
          () {
        final sim = economyColony(bodyId: body);
        final spec = specOf(type);
        final lot = placePlant(sim, type);
        final roster = {...sim.factoryFloors[lot]!.blueprint.roster};
        // Its inputs held well stocked (a month's cover or more): a plant
        // fed from a colony that is itself starving pays famine prices for
        // them, which is the colony's story, not the template's.
        runDays(sim, 30, specs: [spec], inputs: kWellStocked);
        expectHealthy(sim, lot, roster);
        expect(sim.firmBookOf(lot)!.profitPerS, greaterThan(0));
        expect(sim.firmBookOf(lot)!.cash, greaterThan(0),
            reason: 'retained profit');
      });
    }
  }

  // A full warehouse is the colony's stall, not the firm's loss: with no
  // consumer for its goods, a plant's output piles up to the storage cap
  // and is refused. Its staff stand down and the day books nothing — it
  // used to book full wages against no revenue, and every such firm laid
  // off to nothing.
  for (final type in kFactoryPlantTypes) {
    test('a $type whose goods pile up stays healthy for 60 days', () {
      final sim = economyColony();
      final spec = specOf(type);
      final lot = placePlant(sim, type);
      final roster = {...sim.factoryFloors[lot]!.blueprint.roster};
      runDays(sim, 60, specs: [spec], emptyOutputs: false);
      for (final c in spec.outputs.keys) {
        expect(sim.stockOf(c), greaterThan(0), reason: 'goods piled up');
      }
      expectHealthy(sim, lot, roster);
    });
  }
}

/// Units of each input the off-Earth runs hold: far beyond a month of the
/// colony's draw, so no input reads as scarce.
const double kWellStocked = 1e5;

/// No cuts, no offer: the roster is the template's and every station runs.
void expectHealthy(CitySim sim, String lot, Map<HandlerKind, int> roster) {
  final book = sim.firmBookOf(lot)!;
  expect(book.owner.isState, isFalse, reason: 'capitalism: a firm');
  expect(book.health, FirmHealth.healthy,
      reason: 'margin ${book.margin.toStringAsFixed(3)}');
  expect(sim.factoryFloors[lot]!.blueprint.roster, roster);
  expect(sim.floorThrottleOf(lot), 1);
  expect(sim.pendingFirmOffers, isEmpty);
}
