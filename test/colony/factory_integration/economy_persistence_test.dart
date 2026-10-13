// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The plant economy saves and replays exactly (docs/plans/factory-floors.md
/// §3 "Persistence"; the domain is deterministic): books, ownership, offers,
/// throttles, owed edits and the day clock survive a save, and two colonies
/// driven alike keep identical books.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/firm_policy.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

void main() {
  // A closed plant with its offer pending, a running firm with cash and a
  // floor edit still owed, mid-day: every piece of it comes back. Without
  // the save key a reload would reopen the closed plant, forget the offer,
  // and pay its next day's tax twice.
  test('the economy round-trips through a save', () {
    final r = starvedMill();
    final sim = r.sim;
    final refinery = specOf('refinery');
    final lot2 = placePlant(sim, 'refinery');
    runDays(sim, 1.4, specs: [refinery]);
    sim.population = kEconPopulation;
    sim.openFloor(lot2)!.hire(HandlerKind.forklift, 2);
    sim.closeFloor(lot2);
    expect(sim.pendingFirmOffers, hasLength(1));
    expect(sim.colonyEconomy.dayClockS, greaterThan(0));

    final loaded = reload(sim.toJson());
    expect(economyJson(loaded), economyJson(sim));
    expect(loaded.pendingFirmOffers.single.site, r.lot);
    expect(loaded.firmBookOf(r.lot)!.health, FirmHealth.closed);
    expect(loaded.floorThrottleOf(r.lot), 0);
    expect(loaded.ownerOf(lot2).firmId, sim.ownerOf(lot2).firmId);
    expect(loaded.firmBookOf(lot2)!.cash, sim.firmBookOf(lot2)!.cash);
    expect(loaded.corporateTaxRate, sim.corporateTaxRate);
    expect(loaded.pendingFloorInvestment, sim.pendingFloorInvestment);
    expect(loaded.colonyEconomy.stashed.keys, [lot2]);
    // The offer still resolves after the load.
    expect(loaded.resolveFirmOffer(r.lot, ClosureOption.sellToNewFirm), isTrue);
    expect(loaded.ownerOf(r.lot).firmId, isNot(sim.ownerOf(r.lot).firmId));
  });

  // Determinism: two colonies founded and driven alike — same plants, a
  // starving one and a fed one, across several day closes with layoffs and
  // a price solve each day — save byte-identical economies.
  test('two colonies stepped alike keep identical economies', () {
    String run() {
      final sim = economyColony();
      final lot = placePlant(sim, 'steelmill');
      placePlant(sim, 'gunfactory');
      sim.factoryFloors[lot]!.blueprint.roster
        ..clear()
        ..[HandlerKind.onFoot] = 1;
      // The mill gets no ore; the arms plant is fed (after each tick, so
      // ready for the next).
      final guns = specOf('gunfactory');
      holdStock(sim, guns);
      runDays(sim, 10.5, specs: [specOf('steelmill')], inputs: 0, after: () {
        holdStock(sim, guns);
        return false;
      });
      expect(sim.colonyEconomy.books, hasLength(2));
      return economyJson(sim);
    }

    final a = run();
    final b = run();
    expect(a, b);
    expect(a, contains('"thr"'), reason: 'the starving mill was cut');
  });

  // The day clock is saved, so a save mid-day doesn't restart the day
  // (which would let a player postpone a firm's close forever by saving).
  test('a save mid-day keeps the day clock', () {
    final sim = economyColony();
    placePlant(sim, 'refinery');
    runDays(sim, 0.5, specs: [specOf('refinery')]);
    final loaded = reload(sim.toJson());
    expect(loaded.colonyEconomy.dayClockS,
        closeTo(0.5 * kColonyDaySec, kEconTickS));
  });
}
