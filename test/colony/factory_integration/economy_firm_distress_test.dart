// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A failing firm, end to end through the colony (docs/plans/factory-floors.md
/// §7 Q11): it lays off, then idles stations, then closes, and the closed
/// plant is offered to the player to nationalise or sell.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/firm_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

void main() {
  // The whole ladder, in order, a firm-policy cooldown apart: without the
  // apply step each would be a decision nobody carried out; without the
  // order a losing firm would close with staff still on the books.
  test('a losing private plant lays off, idles, closes and is offered', () {
    final r = losingMill();
    final w = r.walk;
    expect(w.layoff, isNotNull, reason: 'the walker is let go');
    expect(w.idle, isNotNull, reason: 'then stations idle');
    expect(w.close, isNotNull, reason: 'then it closes');
    expect(w.layoff!, lessThan(w.idle!));
    expect(w.idle! - w.layoff!,
        greaterThanOrEqualTo(kFirmActionCooldownSec - kColonyDaySec));
    expect(w.close!, greaterThan(w.idle!));
    expect(w.close!, greaterThanOrEqualTo(kCloseGraceSec));

    final rec = r.sim.factoryFloors[r.lot]!;
    expect(rec.dirty, isTrue, reason: 'the thinner floor is re-measured');
    expect(r.sim.firmBookOf(r.lot)!.health, FirmHealth.closed);
    final offers = r.sim.pendingFirmOffers;
    expect(offers, hasLength(1));
    expect(offers.single.site, r.lot);
    expect(offers.single.options,
        [ClosureOption.nationalise, ClosureOption.sellToNewFirm]);
    // A closed plant employs nobody (from the next tick's job count; it
    // closed at the end of this one).
    runDays(r.sim, 0.01, specs: [specOf('steelmill')]);
    expect(r.sim.jobs, lessThanOrEqualTo(r.jobsBefore - 30));
  });

  // Nationalising reopens it as a state plant with fresh books; the state
  // never closes it again (its loss becomes the industry deficit).
  test('nationalising a closed plant reopens it under the state', () {
    final r = losingMill();
    final sim = r.sim;
    expect(sim.resolveFirmOffer(r.lot, ClosureOption.nationalise), isTrue);
    expect(sim.pendingFirmOffers, isEmpty);
    expect(sim.ownerOf(r.lot).isState, isTrue);
    expect(sim.factoryFloors[r.lot]!.owner!.isState, isTrue);
    expect(sim.floorThrottleOf(r.lot), 1);
    final book = sim.firmBookOf(r.lot)!;
    expect(book.health, FirmHealth.healthy);
    expect(book.cash, 0);
    // Still losing, and now a state plant: it never acts again, and its
    // loss is charged as the industry deficit.
    runDays(sim, 2, specs: [specOf('steelmill')]);
    expect(sim.floorThrottleOf(r.lot), 1);
    expect(sim.pendingFirmOffers, isEmpty);
    expect(sim.industryDeficitRate, greaterThan(0));
  });

  // Selling hands it to a NEW firm (a fresh id), fresh books, full throttle.
  test('selling a closed plant reopens it under a new firm', () {
    final r = losingMill();
    final sim = r.sim;
    final oldFirm = sim.ownerOf(r.lot).firmId;
    expect(sim.resolveFirmOffer(r.lot, ClosureOption.sellToNewFirm), isTrue);
    final owner = sim.ownerOf(r.lot);
    expect(owner.isState, isFalse);
    expect(owner.firmId, isNotNull);
    expect(owner.firmId, isNot(oldFirm));
    expect(sim.firmBookOf(r.lot)!.owner.firmId, owner.firmId);
    expect(sim.firmBookOf(r.lot)!.isClosed, isFalse);
    expect(sim.floorThrottleOf(r.lot), 1);
    expect(sim.pendingFirmOffers, isEmpty);
    // An answer with no offer pending is refused.
    expect(sim.resolveFirmOffer(r.lot, ClosureOption.nationalise), isFalse);
  });

  // Demolishing a closed plant withdraws its offer and drops its books: an
  // offer for a plant that no longer stands would nationalise rubble.
  test('demolishing a closed plant withdraws its offer', () {
    final r = losingMill();
    final sim = r.sim;
    sim.clearParcel(r.lot);
    expect(sim.pendingFirmOffers, isEmpty);
    expect(sim.firmBookOf(r.lot), isNull);
    expect(sim.floorThrottleOf(r.lot), 1);
  });

  // The site actions outside a closure: the player may take a running firm
  // over, and sell a state plant — but communism has no buyers.
  test('nationalise and privatise site actions', () {
    final sim = economyColony();
    final lot = placePlant(sim, 'refinery');
    expect(sim.ownerOf(lot).isState, isFalse);
    expect(sim.privatise(lot), isFalse, reason: 'already private');
    expect(sim.nationalise(lot), isTrue);
    expect(sim.ownerOf(lot).isState, isTrue);
    expect(sim.nationalise(lot), isFalse, reason: 'already the state\'s');
    expect(sim.privatise(lot), isTrue);
    expect(sim.ownerOf(lot).isState, isFalse);
    sim.nationalise(lot);
    sim.economy = Economy.communism;
    expect(sim.privatise(lot), isFalse);
  });
}
