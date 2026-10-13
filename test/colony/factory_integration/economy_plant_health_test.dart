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
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

void main() {
  for (final type in kFactoryPlantTypes) {
    test('a templated private $type stays healthy for 30 colony days', () {
      final sim = economyColony();
      final spec = specOf(type);
      final lot = placePlant(sim, type);
      final roster = {...sim.factoryFloors[lot]!.blueprint.roster};
      runDays(sim, 30, specs: [spec]);

      final book = sim.firmBookOf(lot)!;
      expect(book.owner.isState, isFalse, reason: 'capitalism: a firm');
      expect(book.health, FirmHealth.healthy,
          reason: 'margin ${book.margin.toStringAsFixed(3)}');
      expect(book.profitPerS, greaterThan(0));
      // No cuts: the roster is the template's and every station runs.
      expect(sim.factoryFloors[lot]!.blueprint.roster, roster);
      expect(sim.floorThrottleOf(lot), 1);
      expect(sim.pendingFirmOffers, isEmpty);
      expect(book.cash, greaterThan(0), reason: 'retained profit');
    });
  }
}
