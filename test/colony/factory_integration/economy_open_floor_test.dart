// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

/// Found in the wave-3 playtest: opening a plant's floor editor swapped its
/// warm aggregate rates for a COLD live floor (empty belts and buffers), so
/// the first minutes shipped nothing while wages and inputs ran on; one
/// economy day later the firm read distressed and cut to half throttle. A
/// player only looking at a healthy plant must not hurt its books.
void main() {
  test('opening a healthy plant floor does not distress its firm', () {
    final sim = economyColony();
    final spec = specOf('steelmill');
    final lot = placePlant(sim, 'steelmill');
    runDays(sim, 3, specs: [spec], inputs: 1e5);
    expect(sim.firmBookOf(lot)!.health, FirmHealth.healthy);

    expect(sim.openFloor(lot), isNotNull);
    runDays(sim, 3, specs: [spec], inputs: 1e5);
    expect(sim.firmBookOf(lot)!.health, FirmHealth.healthy,
        reason: 'looking at a running plant must not stall it');
    expect(sim.floorThrottleOf(lot), 1.0);
  });
}
