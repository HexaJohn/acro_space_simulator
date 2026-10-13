// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A floor open in the editor smokes as much as it works
/// (docs/plans/factory-floors.md §3 "Coupling to the colony"). The live sim
/// reports no share, so its smoke is the colony's throttle — and the firm's
/// own: a plant its firm idled or closed works less (its port's shares
/// carry the firm throttle), and must smoke less too.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

/// A staffed colony with a Steel Mill whose floor is open (live), its
/// firm's throttle set to [throttle], after one tick: its emission rate.
double liveEmission(double throttle) {
  final sim = economyColony();
  final lot = placePlant(sim, 'steelmill');
  sim.colonyEconomy.throttle[lot] = throttle;
  expect(sim.openFloor(lot), isNotNull);
  sim.advance(0.5);
  expect(sim.floorThrottleOf(lot), throttle);
  return sim.emissionRate;
}

void main() {
  test('a live floor smokes at its firm\'s throttle', () {
    final open = liveEmission(1);
    final closed = liveEmission(0);
    final idled = liveEmission(0.5);
    expect(closed, lessThan(open), reason: 'a closed plant makes no smoke');
    expect(idled, lessThan(open));
    expect(idled, greaterThan(closed));
    // Exactly linear in the throttle: the mill's share halves.
    expect(open - idled, closeTo(idled - closed, 1e-9));
  });

  // Sanity for the comparison: the mill smokes at all.
  test('the Steel Mill pollutes', () {
    expect(specOf('steelmill').pollution, greaterThan(0));
  });
}
